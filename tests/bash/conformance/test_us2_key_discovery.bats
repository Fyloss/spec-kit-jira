#!/usr/bin/env bats
# T026/T027/T028 [US2] — Key discovery, placeholder refusal, degraded mode.
#
# Drives the three US2 scenarios through the real dispatchers on both ports and
# asserts content + cross-port byte-parity:
#   - us2-list-projects: paginated project/search call sequence, closed-question
#     error listing the accessible projects, exit 4.
#   - us2-placeholder-key-refusal: PROJ placeholder + team-shaped branch =>
#     exit 4 and no branch-derived value anywhere in the output.
#   - us2-degraded-mode: empty base URL => exit 0, provisional proposals,
#     re-run guidance, zero writes, ZERO mock calls.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

both_ports() {
  bash "${HARNESS}" "${CONF}/scenarios/$1" bash "${TMP}/out-bash" > /dev/null
  bash "${HARNESS}" "${CONF}/scenarios/$1" powershell "${TMP}/out-ps" > /dev/null
}

parity() {
  run diff "${TMP}/out-bash/exit" "${TMP}/out-ps/exit"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/stdout" "${TMP}/out-ps/stdout"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/stderr" "${TMP}/out-ps/stderr"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/calls.log" "${TMP}/out-ps/calls.log"
  [ "$status" -eq 0 ]
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
}

@test "list-projects: paginated search sequence + closed-question error (T026)" {
  bash "${HARNESS}" "${CONF}/scenarios/us2-list-projects.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  # The paginated call sequence was recorded (pageSize 2 over 3 projects).
  [ "$(grep -c 'project/search' "${TMP}/out-bash/calls.log")" -eq 2 ]
  # The error surface lists the accessible projects and the re-run command.
  grep -q 'no usable project key' "${TMP}/out-bash/stderr"
  grep -q 'COMP' "${TMP}/out-bash/stderr"
  grep -q 'TEAM' "${TMP}/out-bash/stderr"
  grep -q 'AMBI' "${TMP}/out-bash/stderr"
  grep -q 'spec-kit-jira config <KEY>' "${TMP}/out-bash/stderr"
}

@test "list-projects is byte-identical across ports (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-list-projects.json
  parity
}

@test "placeholder refusal: exit 4, no branch-derived value in the output (T027)" {
  bash "${HARNESS}" "${CONF}/scenarios/us2-placeholder-key-refusal.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  # The checked-out wex-99 branch never leaks into stdout or stderr.
  ! grep -q 'wex' "${TMP}/out-bash/stdout"
  ! grep -q 'wex' "${TMP}/out-bash/stderr"
  [ ! -f "${TMP}/out-bash/workdir/.specify/jira/config.local.yml" ]
}

@test "placeholder refusal is byte-identical across ports (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-placeholder-key-refusal.json
  parity
}

@test "degraded mode: exit 0, provisional proposals, guidance, zero writes, zero calls (T028)" {
  bash "${HARNESS}" "${CONF}/scenarios/us2-degraded-mode.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '.provisional | length' "${TMP}/out-bash/stdout")" -eq 1 ]
  [ "$(jq -r '.provisional[0].team_prefix' "${TMP}/out-bash/stdout")" = "ijt" ]
  [ "$(jq -r '.provisional[0].provisional' "${TMP}/out-bash/stdout")" = "true" ]
  [ "$(jq -r '.rerun_guidance | length > 0' "${TMP}/out-bash/stdout")" = "true" ]
  grep -q 'WARNING' "${TMP}/out-bash/stderr"
  grep -q 'SPEC_KIT_JIRA_BASE_URL' "${TMP}/out-bash/stderr"
  [ ! -f "${TMP}/out-bash/workdir/.specify/jira/config.local.yml" ]
  # Zero Jira calls reached the mock.
  [ ! -s "${TMP}/out-bash/calls.log" ]
}

@test "degraded mode is byte-identical across ports (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-degraded-mode.json
  parity
}
