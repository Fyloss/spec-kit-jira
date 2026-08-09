#!/usr/bin/env bats
# T021a [Phase 4, US2] — the remaining contracts/run-state.md §9 fail-open and
# first-run rows that T020/T021 do not cover: an `inputs` member appearing or
# disappearing (tasks.md), the very first run of all, and two `--on-drift`
# modes never sharing a state.
#
# The state file's path — `.specify/jira/state/<feature-dir>.json`
# (data-model.md §1) — is fixed by this fixture's feature directory,
# `001-billing-invoices`.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  STATE_REL=".specify/jira/state/001-billing-invoices.json"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "T021a — tasks.md appearing invalidates the recorded state" {
  bash "${HARNESS}" "${CONF}/scenarios/us021-state-tasks-appeared.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ -s "${TMP}/out/calls.log.2" ]
  jq empty "${TMP}/out/workdir/${STATE_REL}"
  jq -e '.inputs["tasks.md"]' "${TMP}/out/workdir/${STATE_REL}" > /dev/null
}

@test "T021a — tasks.md disappearing invalidates the recorded state" {
  bash "${HARNESS}" "${CONF}/scenarios/us021-state-tasks-deleted.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ -s "${TMP}/out/calls.log.2" ]
  jq empty "${TMP}/out/workdir/${STATE_REL}"
  ! jq -e '.inputs["tasks.md"]' "${TMP}/out/workdir/${STATE_REL}" > /dev/null
}

@test "T021a — the first run of all records fresh state" {
  bash "${HARNESS}" "${CONF}/scenarios/us021-state-first-run.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
  [ -s "${TMP}/out/calls.log" ]
  [ -f "${TMP}/out/workdir/${STATE_REL}" ]
  jq empty "${TMP}/out/workdir/${STATE_REL}"
}

@test "T021a — --on-drift=abort and --on-drift=proceed do not share a state" {
  bash "${HARNESS}" "${CONF}/scenarios/us021-state-ondrift-changed.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ -s "${TMP}/out/calls.log.2" ]
  jq empty "${TMP}/out/workdir/${STATE_REL}"
  [ "$(jq -r '.on_drift' "${TMP}/out/workdir/${STATE_REL}")" = "proceed" ]
}
