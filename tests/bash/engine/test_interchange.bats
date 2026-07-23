#!/usr/bin/env bats
# T020 — Neutral-interchange schema validation (Constitution VIII).
# Valid docs pass; invalid docs fail with an error and DRIVE ZERO WRITES.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/engine"
  PS_ENGINE="${ROOT}/.specify/extensions/jira/scripts/powershell/engine"
  VALID="${ROOT}/tests/conformance/fixtures/neutral-valid.json"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/interchange.sh"
}

@test "a well-formed neutral document validates" {
  run interchange_validate < "${VALID}"
  [ "$status" -eq 0 ]
}

@test "wrong schema_version is rejected" {
  run bash -c "jq '.schema_version=\"2.0\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema_version"* ]]
}

@test "a malformed spec_slug is rejected" {
  run bash -c "jq '.spec_ref.spec_slug=\"bad slug\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spec_slug"* ]]
}

@test "an invalid project_key is rejected" {
  run bash -c "jq '.routing.project_key=\"proj-1\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project_key"* ]]
}

@test "an empty stories array is rejected" {
  run bash -c "jq '.stories=[]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stories"* ]]
}

@test "an invalid priority is rejected" {
  run bash -c "jq '.stories[0].priority_logical=\"P9\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"priority"* ]]
}

@test "invalid JSON input is rejected, not crashed" {
  run bash -c "printf 'not json' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
}

@test "both ports agree on validity for the same inputs" {
  for mutation in '.' '.schema_version="2.0"' '.routing.project_key="bad-key"' '.stories=[]'; do
    doc="$(jq -c "${mutation}" "${VALID}")"
    if printf '%s' "${doc}" | interchange_validate 2> /dev/null; then bash_ok=0; else bash_ok=1; fi
    if printf '%s' "${doc}" | pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Interchange.psm1' -Force; if (Test-JiraInterchange ([Console]::In.ReadToEnd())) { exit 0 } else { exit 1 }" 2> /dev/null; then ps_ok=0; else ps_ok=1; fi
    [ "${bash_ok}" = "${ps_ok}" ]
  done
}
