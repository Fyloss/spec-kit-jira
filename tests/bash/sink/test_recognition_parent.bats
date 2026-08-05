#!/usr/bin/env bats
# T054/T055/T056 [Phase 5, US2] — Parent recognition: the decision table of
# contracts/hierarchy-resolution.md §7, the inconclusive-read fault matrix,
# and the 404-recreation notice.

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
SPEC_PATH="specs/001-billing/spec.md"

_seed_config() {
  local marker="$1"
  cat > "${BATS_TEST_TMPDIR}/cfg.json" << EOF
{"issues": {"COMP-412": {"summary": "S", "properties": {"spec-kit-jira": ${marker}}}}}
EOF
  printf '%s' "${BATS_TEST_TMPDIR}/cfg.json"
}

# --- T054: every row of the decision table ----------------------------------

@test "absent: no read, state new, no story planning implication here" {
  local minfo='{"state":"absent","id":"","lines":[]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "new" ]
}

@test "assigned: no read, state new" {
  local minfo='{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "new" ]
}

@test "creating: no read, state blocked, reason parent-key-unrecorded" {
  local minfo='{"state":"creating","id":"3f2a91c04b7e6d18","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "blocked" ]
  [ "$(jq -r '.reason' <<< "$output")" = "parent-key-unrecorded" ]
  [[ "$(jq -r '.detail' <<< "$output")" == *"creating"* ]]
}

@test "malformed: no read, state blocked, reason parent-marker-malformed" {
  local minfo='{"state":"malformed","id":"3f2a91c04b7e6d18","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "blocked" ]
  [ "$(jq -r '.reason' <<< "$output")" = "parent-marker-malformed" ]
  [[ "$(jq -r '.detail' <<< "$output")" == *"line 2"* ]]
}

@test "duplicate: no read, state blocked, reason parent-marker-duplicate, every line named" {
  local minfo='{"state":"duplicate","id":"","lines":[2,7]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "blocked" ]
  [ "$(jq -r '.reason' <<< "$output")" = "parent-marker-duplicate" ]
  [[ "$(jq -r '.detail' <<< "$output")" == *"2, 7"* ]]
}

@test "bound + ok + role:parent + same repo/spec_slug: state bound, key and current carried" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","role":"parent"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "bound" ]
  [ "$(jq -r '.key' <<< "$output")" = "COMP-412" ]
  [ "$(jq -r '.current.summary' <<< "$output")" = "S" ]
  [ "$(jq -r '.origin' <<< "$output")" = "bridge" ]
}

@test "018, T038 — a bound parent surfaces last_summary from the identity marker; a legacy marker omits it" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","role":"parent","summary":"The Epic, renamed"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.last_summary' <<< "$output")" = "The Epic, renamed" ]

  mock_stop
  cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","role":"parent"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("last_summary")' <<< "$output")" = "false" ]
}

@test "bound + ok + different spec_slug: state blocked, reason parent-claimed-by-other" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"999-other","role":"parent"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "blocked" ]
  [ "$(jq -r '.reason' <<< "$output")" = "parent-claimed-by-other" ]
  [[ "$(jq -r '.detail' <<< "$output")" == *"999-other"* ]]
}

@test "bound + ok + no identity property at all: state blocked, reason parent-identity-unverifiable" {
  local cfg; cfg="$(_seed_config 'null')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "blocked" ]
  [ "$(jq -r '.reason' <<< "$output")" = "parent-identity-unverifiable" ]
}

@test "bound + ok + identity present but no role field: state blocked, reason parent-identity-unverifiable, never treated as a parent" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","story":"1111111111111111"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "blocked" ]
  [ "$(jq -r '.reason' <<< "$output")" = "parent-identity-unverifiable" ]
}

# --- T055: an inconclusive read is NEVER downgraded to "no parent exists" --

@test "T055: 401 on the parent read -> exit 3, zero stdout, never downgraded" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"faults": {"issue/COMP-412": {"status": 401}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "T055: exhausted 429 on the parent read -> exit 2, zero stdout" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"faults": {"issue/COMP-412": {"status": 429, "retryAfter": 0}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "T055: network drop on the parent read -> exit 2, zero stdout" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"faults": {"issue/COMP-412": {"network": true}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# --- T056: a recorded parent returning 404 is re-created, not a failure ----

@test "T056: 404 on the parent read: state new, the former key carried for the recreation notice" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"faults": {"issue/COMP-412": {"status": 404}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = "new" ]
  [ "$(jq -r '.recreated_from.key' <<< "$output")" = "COMP-412" ]
}

# --- T021 [017, US2] — labels are read and unique-normalised -----------------

@test "017 — the parent recognition read requests labels and current.labels is unique-normalised" {
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","role":"parent"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-412" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"labels":["zeta","alpha","alpha"]}}' > /dev/null

  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.current.labels | join(",")' <<< "$output")" = "alpha,zeta" ]
}

# --- Cross-port parity -------------------------------------------------------

@test "the PowerShell port decides the same outcome for every row (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local cfg; cfg="$(_seed_config '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","role":"parent"}')"
  # A native pwsh HTTP client cannot reach the curl shim's sentinel
  # MOCK_BASE_URL, so this cross-port test uses the real pwsh server.
  mock_start "${cfg}" powershell
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local minfo='{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
  local b; b="$(recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "${SPEC_PATH}")"
  local p; p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/Recognition.psm1' -Force
    [Console]::Out.Write((Invoke-JiraRecognitionParentRun -MarkerInfoJson '${minfo}' -SpecRefJson '${SPEC_REF}' -ProjectKey 'COMP' -SpecPath '${SPEC_PATH}').Json)")"
  [ "${b}" = "${p}" ]
}
