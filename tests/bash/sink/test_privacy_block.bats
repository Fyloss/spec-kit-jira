#!/usr/bin/env bats
# T047/T048/T049 [US11] — Privacy guard BLOCK tier (FR-052, Constitution IV/IX).
#
# Before EVERY write, a pre-write guard blocks on an exact match of a known
# site/project coordinate, the ATATT token prefix, or a real non-documentation
# *.atlassian.net host — producing ZERO writes and the dedicated exit code 9.
# Precision over recall: the guard matches these specific shapes, never the
# generic email/UUID shapes (those are the P3 WARN tier). The offending value is
# never echoed (only the reason). The PowerShell port blocks identically (NFR-1).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/privacy_guard.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

# --- Guard unit: the three BLOCK shapes -------------------------------------

@test "blocks on an ATATT token prefix (exit 9), never echoing the value" {
  run privacy_guard_scan 'see token ATATT3xFfGF0abcdef for access'
  [ "$status" -eq 9 ]
  [[ "$output" != *"ATATT3xFfGF0abcdef"* ]]   # the value is never echoed (NFR-3)
}

@test "blocks on a real *.atlassian.net host (exit 9)" {
  run privacy_guard_scan 'mirror of https://acme-corp.atlassian.net/browse/X'
  [ "$status" -eq 9 ]
}

@test "blocks on an exact known coordinate (exit 9)" {
  run privacy_guard_scan 'internal ref ACME-PROD site' '["ACME-PROD site"]'
  [ "$status" -eq 9 ]
}

@test "passes ordinary content — precision over recall (exit 0)" {
  run privacy_guard_scan 'Add the billing feature; contact team@example.com; id 550e8400-e29b-41d4-a716-446655440000' '[]'
  [ "$status" -eq 0 ]
}

# --- Fail-open regressions: case bypass + allowlist shredding ----------------

@test "blocks a MiXeD-case Atlassian host — DNS hosts are case-insensitive (FR-052)" {
  run privacy_guard_scan 'see https://Acme.Atlassian.Net/browse/PROJ-1'
  [ "$status" -eq 9 ]
}

@test "an allowlist entry overlapping the token shape never disables token detection (FR-052)" {
  run privacy_guard_scan 'see token ATATT3xFfGF0abcdef for access' '[]' '["ATAT"]'
  [ "$status" -eq 9 ]
}

@test "an allowlist entry matching a SUBSTRING of a real host never neutralises it (FR-052)" {
  run privacy_guard_scan 'leak acme-corp.atlassian.net' '[]' '["corp.atlassian.net"]'
  [ "$status" -eq 9 ]
}

@test "an allowlist entry overlapping a known coordinate never disables its detection (FR-052)" {
  run privacy_guard_scan 'internal ref ACME-PROD site' '["ACME-PROD site"]' '["ACME"]'
  [ "$status" -eq 9 ]
}

@test "an allowlisted domain still exempts its own hosts, any case (FR-053 preserved)" {
  run privacy_guard_scan 'see OurCo.Atlassian.Net/wiki/spaces/OPS' '[]' '["ourco.atlassian.net"]'
  [ "$status" -eq 0 ]
}

# --- Apply path: the mandatory pre-write gate (zero writes on block) ---------

@test "apply_writes blocks before any write and performs ZERO writes (exit 9)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local actions='[{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue","body":{"fields":{"summary":"leak acme-corp.atlassian.net"}}}]'
  run apply_writes "${actions}"
  [ "$status" -eq 9 ]
  # Zero writes: the mock recorded no calls at all.
  run mock_calls
  [ -z "$output" ]
}

@test "T10 [017] — a BLOCK-tier string reachable through the labels array is caught before any write (exit 9)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local actions='[{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue","body":{"fields":{"summary":"Add the billing feature","labels":["speckit-001-x","leak acme-corp.atlassian.net"]}}}]'
  run apply_writes "${actions}"
  [ "$status" -eq 9 ]
  run mock_calls
  [ -z "$output" ]
}

@test "apply_writes lets a clean write through (no gap for legitimate writes)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local actions='[{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue","body":{"fields":{"summary":"Add the billing feature"}}}]'
  run apply_writes "${actions}"
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"POST /rest/api/3/issue"* ]]
}

# --- T058 [Phase 5, US2]: the parent's payload passes the SAME pre-write ---
# gate, before any write for the whole specification (research R8, FR-036) --

@test "T058: a blocked parent payload yields ZERO writes for the whole specification, including its stories" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{
    "parent": {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
               "body":{"fields":{"summary":"leak acme-corp.atlassian.net"}}, "local_id":"aaaaaaaaaaaaaaaa", "role":"parent"},
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
                 "body":{"fields":{"summary":"Add the billing feature"}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local spec_ref='{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
  local spec_file="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Title\n' > "${spec_file}"
  # 015 T025, rule O4 (contract §4.2/data-model.md §5): the confirmed-creation
  # outcome is NOT printed on this pre-write privacy-guard return — separate
  # stdout/stderr so the guard's own reason (stderr) is never mistaken for the
  # outcome's absence (stdout).
  run --separate-stderr apply_writes_with_recognition "${plan}" "${spec_ref}" "${spec_file}"
  [ "$status" -eq 9 ]
  [ -z "$output" ]
  run mock_calls
  [ -z "$output" ]
}

@test "015 T025 (rule O4) — a blocked STORY payload (clean parent) also prints no outcome on stdout" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{
    "parent": {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
               "body":{"fields":{"summary":"The Epic"}}, "local_id":"aaaaaaaaaaaaaaaa", "role":"parent"},
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
                 "body":{"fields":{"summary":"leak acme-corp.atlassian.net"}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local spec_ref='{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
  local spec_file="${BATS_TEST_TMPDIR}/spec_story_block.md"
  printf '# Title\n' > "${spec_file}"
  run --separate-stderr apply_writes_with_recognition "${plan}" "${spec_ref}" "${spec_file}"
  [ "$status" -eq 9 ]
  [ -z "$output" ]
  run mock_calls
  [ -z "$output" ]
}

@test "T058: a clean parent and clean stories are written through (no gap for legitimate writes)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{
    "parent": {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
               "body":{"fields":{"summary":"The Epic"}}, "local_id":"aaaaaaaaaaaaaaaa", "role":"parent"},
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
                 "body":{"fields":{"summary":"Add the billing feature","parent":{"key":"<resolved at apply time>"}}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local spec_ref='{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
  local spec_file="${BATS_TEST_TMPDIR}/spec2.md"
  printf '# Title\n' > "${spec_file}"
  run apply_writes_with_recognition "${plan}" "${spec_ref}" "${spec_file}"
  [ "$status" -eq 0 ]
  run mock_calls
  [ "$(grep -c '^POST /rest/api/3/issue$' <<< "$output")" -eq 2 ]
}

# --- 018, T016: the narrowed scan scope (contract §5, FR-024a) -------------
# A *.atlassian.net host present ONLY in the preserved human prefix must not
# block the run — it is a verbatim round-trip, read from this ticket and
# written back to it, so it cannot leak anything the tracker does not already
# hold. The SAME host in a node the mirror composes (the managed region) must
# still block, with the same exit code and zero writes, exactly as today.

@test "a *.atlassian.net host present only in the preserved human prefix does not block the run" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local marker desc actions
  marker="$(adf_managed_marker)"
  desc="$(jq -cn --arg m "${marker}" '{type:"doc", version:1, content:[
    {type:"paragraph", content:[{type:"text", text:"see mirror of https://acme-corp.atlassian.net/browse/X"}]},
    {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
    {type:"paragraph", content:[{type:"text", text:"managed body, composed by the mirror"}]}
  ]}')"
  actions="$(jq -cn --arg u "${MOCK_BASE_URL}/rest/api/3/issue/PROJ-1" --argjson d "${desc}" \
    '[{method:"PUT", url:$u, body:{fields:{description:$d}}}]')"
  run apply_writes "${actions}"
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"PUT /rest/api/3/issue/PROJ-1"* ]]
}

@test "the same host in a node the mirror composes still blocks with zero writes" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local marker desc actions
  marker="$(adf_managed_marker)"
  desc="$(jq -cn --arg m "${marker}" '{type:"doc", version:1, content:[
    {type:"paragraph", content:[{type:"text", text:"an ordinary human note"}]},
    {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
    {type:"paragraph", content:[{type:"text", text:"leak acme-corp.atlassian.net"}]}
  ]}')"
  actions="$(jq -cn --arg u "${MOCK_BASE_URL}/rest/api/3/issue/PROJ-1" --argjson d "${desc}" \
    '[{method:"PUT", url:$u, body:{fields:{description:$d}}}]')"
  run apply_writes "${actions}"
  [ "$status" -eq 9 ]
  run mock_calls
  [ -z "$output" ]
}

# --- Cross-port parity ------------------------------------------------------

@test "the PowerShell port blocks the same three shapes identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local ps
  ps="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/PrivacyGuard.psm1' -Force
    \$a = Test-JiraPrivacyBlock -Payload 'ATATT3xFfGF0abc'
    \$b = Test-JiraPrivacyBlock -Payload 'x acme-corp.atlassian.net y'
    \$c = Test-JiraPrivacyBlock -Payload 'ref ACME-PROD site' -KnownCoordinatesJson '[\"ACME-PROD site\"]'
    \$d = Test-JiraPrivacyBlock -Payload 'Add the billing feature'
    [Console]::Out.Write(\"\$a\$b\$c\$d\")
  ")"
  [ "$ps" = "9990" ]
}
