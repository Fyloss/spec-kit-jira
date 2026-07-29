#!/usr/bin/env bats
# T061 [004] — Exercises the mock's optional createmetaFields route selection
# (mock-server.ps1:61) end to end: research R4 branch 2 (priority field WITH
# allowedValues) is otherwise only unit-tested against the fixture file
# directly (test_discovery_priorities.bats), never through the mock's HTTP
# route the fixture is actually served from.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  SCENARIO="${CONF}/scenarios/us8-reconcile-priority-allowed-discovery.json"
  TMP="$(mktemp -d)"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
}

teardown() {
  rm -rf "${TMP}"
}

@test "config persists only the allowedValues-restricted priorities via the mock's createmetaFields route (R4 branch 2)" {
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  local localj
  localj="$(config_yaml_to_json "${TMP}/out-bash/workdir/.specify/jira/config.local.yml")"
  [ "$(jq -cS '.resolved_ids.COMP.priorities' <<< "${localj}")" = '{"Critical":"1","Medium":"3"}' ]
}

@test "both ports resolve the allowedValues-restricted priorities byte-identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash" > /dev/null
  bash "${HARNESS}" "${SCENARIO}" powershell "${TMP}/out-ps" > /dev/null
  run diff "${TMP}/out-bash/stdout" "${TMP}/out-ps/stdout"
  [ "$status" -eq 0 ]
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/calls.log" "${TMP}/out-ps/calls.log"
  [ "$status" -eq 0 ]
}
