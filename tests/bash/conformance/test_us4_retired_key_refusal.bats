#!/usr/bin/env bats
# T025 [Phase 3, US4] — Conformance: a team configuration declaring a retired
# key refuses with exit 4 on a direct invocation, naming the key; under a
# hook the same case emits exactly one WARNING and returns 0 (quickstart
# Step 11). Both ports agree byte for byte.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  SCENARIO="${CONF}/scenarios/us4-retired-key-refusal.json"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "exit 4 direct, naming the retired key, zero writes" {
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  [[ "$(cat "${TMP}/out-bash/stderr")" == *"epic_strategy"* ]]
  [ ! -s "${TMP}/out-bash/calls.log" ]
}

@test "under a hook: exactly one WARNING and exit 0" {
  SPEC_KIT_JIRA_HOOK_CONTEXT="after_specify" \
    bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-hook" > /dev/null
  [ "$(cat "${TMP}/out-hook/exit")" = "0" ]
  [ "$(grep -c '^WARNING: ' "${TMP}/out-hook/stderr")" -eq 1 ]
  [[ "$(cat "${TMP}/out-hook/stderr")" == *"epic_strategy"* ]]
}

@test "byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash" > /dev/null
  bash "${HARNESS}" "${SCENARIO}" powershell "${TMP}/out-ps" > /dev/null
  run diff "${TMP}/out-bash/exit" "${TMP}/out-ps/exit"
  [ "$status" -eq 0 ]
}
