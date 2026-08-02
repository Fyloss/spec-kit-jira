#!/usr/bin/env bats
# T019/T020/T043/T056 — Recognition: the marker verification decision table,
# the fault matrix, and the diagnostics catalogue's privacy discipline.
# contracts/recognition-contract.md.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/recognition.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export JIRA_MAX_ATTEMPTS=1
}

teardown() {
  mock_stop
}

SPEC_REF='{"repo":"acme/app","spec_slug":"001-billing","folder":"specs/001-billing"}'

_seed_config() {
  # A mock config seeding COMP-1 already bound and carrying the given marker.
  local marker="$1"
  cat > "${BATS_TEST_TMPDIR}/cfg.json" << EOF
{"issues": {"COMP-1": {"summary": "S", "properties": {"spec-kit-jira": ${marker}}}}}
EOF
  printf '%s' "${BATS_TEST_TMPDIR}/cfg.json"
}

@test "bound: marker's repo/spec_slug/story all match — recognised" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","story":"1111111111111111"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.bound["1111111111111111"].key' <<< "$output")" = "COMP-1" ]
  [ "$(jq '.new | length' <<< "$output")" -eq 0 ]
  [ "$(jq '.blocked | length' <<< "$output")" -eq 0 ]
}

@test "marker-mismatch: story present, matches a SIBLING story of this same spec, not this one" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","story":"9999999999999999"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}},{"local_id":"9999999999999999","marker":{"state":"absent"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.blocked[0].reason' <<< "$output")" = "marker-mismatch" ]
}

@test "orphan: stamped identifier matches no story of the specification" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","story":"deadbeefdeadbeef"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.blocked[0].reason' <<< "$output")" = "orphan" ]
}

@test "claimed-by-other: repo names another repository (spec_slug alone never blocks — durability across a rename, US3)" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"other/app","spec_slug":"001-billing","story":"1111111111111111"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.blocked[0].reason' <<< "$output")" = "claimed-by-other" ]
}

@test "a spec_slug mismatch alone (same repo, matching story id) is bound, not blocked — durability across a rename (US3, FR-017)" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing-renamed","story":"1111111111111111"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq '.blocked | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.bound["1111111111111111"].key' <<< "$output")" = "COMP-1" ]
}

@test "duplicate-claim on two stories: an identifier appears on two markers (parse-level)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"aaaa111122223333","marker":{"state":"duplicate","lines":[2,3]}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.blocked[0].reason' <<< "$output")" = "duplicate-claim" ]
}

@test "duplicate-claim on two keys: two recorded keys resolving to one ticket" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}},{"local_id":"2222222222222222","marker":{"state":"bound","id":"2222222222222222","ticket":"COMP-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq '[.blocked[] | select(.reason=="duplicate-claim")] | length' <<< "$output")" -eq 2 ]
}

@test "a ticket with no marker at all is never adopted" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"UNSEEDED-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "UNSEEDED" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.blocked[0].reason' <<< "$output")" = "marker-mismatch" ]
}

@test "story=<id> alone (no ticket) is new" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"assigned","id":"1111111111111111"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.new[0]' <<< "$output")" = "1111111111111111" ]
}

@test "story=<id> creating fails closed for that story only (key-unrecorded)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"creating","id":"1111111111111111"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.blocked[0].reason' <<< "$output")" = "key-unrecorded" ]
}

# --- Fault matrix: zero creation, every read failure fails the run closed ---

@test "401 on the recognition read -> exit 3, zero writes" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"faults": {"issue/COMP-1": {"status": 401}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "exhausted 429 on the recognition read -> exit 2, zero writes" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"faults": {"issue/COMP-1": {"status": 429, "retryAfter": 0}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "network drop on the recognition read -> exit 2, zero writes" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"faults": {"issue/COMP-1": {"network": true}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "404 on the recognition read: ticket re-created with a notice (not a failure)" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"faults": {"issue/COMP-999": {"status": 404}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-999"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.new[0]' <<< "$output")" = "1111111111111111" ]
}

# --- Privacy: diagnostics name no host, token, or account id ----------------

@test "no diagnostic contains the mock host" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"002-other","story":"1111111111111111"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [[ "$output" != *"127.0.0.1"* ]]
  [[ "$output" != *"RAWSECRETXYZ"* ]]
}

# --- Cross-port parity -------------------------------------------------------

@test "the PowerShell port produces an identical recognition result (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","story":"1111111111111111"}')"
  # A native pwsh HTTP client cannot reach the curl shim's sentinel
  # MOCK_BASE_URL, so this cross-port test uses the real pwsh server.
  mock_start "${cfg}" powershell
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
  local b p
  b="$(recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/Recognition.psm1' -Force
    [Console]::Out.Write((Invoke-JiraRecognitionRun -StoriesJson '${stories}' -SpecRefJson '${SPEC_REF}' -ProjectKey 'COMP' -SpecPath 'spec.md').Json)")"
  [ "${b}" = "${p}" ]
}

@test "T056: every diagnostic reason's wording matches the catalogue and leaks nothing, at --verbose" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"other/app","spec_slug":"999-x","story":"9999999999999999"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[
    {"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}},
    {"local_id":"2222222222222222","marker":{"state":"malformed","id":"2222222222222222","lines":[7]}},
    {"local_id":"aaaa111122223333","marker":{"state":"duplicate","lines":[10,11]}},
    {"local_id":"3333333333333333","marker":{"state":"creating","id":"3333333333333333"}}
  ]'
  run recognition_run "${stories}" "${SPEC_REF}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  local reasons; reasons="$(jq -r '[.blocked[].reason] | sort | join(",")' <<< "$output")"
  [ "${reasons}" = "claimed-by-other,duplicate-claim,key-unrecorded,marker-malformed" ]
  # Every detail names the story and a copy-pasteable remedy (Constitution
  # XVI), and none leaks the site host, a token, or an account id
  # (Constitution IV) — including the verbose-adjacent full JSON dump.
  local all_details; all_details="$(jq -r '.blocked[].detail' <<< "$output")"
  [[ "${all_details}" != *"${MOCK_BASE_URL#http://}"* ]]
  [[ "${all_details}" != *"RAWSECRETXYZ"* ]]
  [[ "${all_details}" != *"127.0.0.1"* ]]
  [[ "$(jq -c '.' <<< "$output")" != *"127.0.0.1"* ]]
}
