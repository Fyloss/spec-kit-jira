#!/usr/bin/env bats
# T029 [US4] — Reinstall/upgrade preservation (FR-020).
#
# Drives the us4-reinstall-preserves-config scenario through the real dispatcher
# on both ports and asserts:
#   1. the committed config.yml and gitignored config.local.yml survive the run
#      byte-for-byte (no script path may touch .specify/jira/), and
#   2. the post-run repository tree is byte-identical across ports (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  SCENARIO="${CONF}/scenarios/us4-reinstall-preserves-config.json"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-config"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "config.yml + config.local.yml survive a benign run byte-for-byte (FR-020)" {
  run bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash"
  [ "$status" -eq 0 ]
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  run diff "${FIXTURE}/.specify/jira/config.yml" "${TMP}/out-bash/workdir/.specify/jira/config.yml"
  [ "$status" -eq 0 ]
  run diff "${FIXTURE}/.specify/jira/config.local.yml" "${TMP}/out-bash/workdir/.specify/jira/config.local.yml"
  [ "$status" -eq 0 ]
}

@test "post-run repository tree is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash" > /dev/null
  bash "${HARNESS}" "${SCENARIO}" powershell "${TMP}/out-ps" > /dev/null
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/exit" "${TMP}/out-ps/exit"
  [ "$status" -eq 0 ]
}
