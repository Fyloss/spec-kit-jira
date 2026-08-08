#!/usr/bin/env bats
# T023 [Phase 4, US2] — Conformance: contracts/run-state.md §4/§9 rows "a run
# that warned / stopped at a pending confirmation / failed records no state".
#
# Forward-looking regression guards, not red-before-green fixes: no code path
# writes state on ANY outcome yet (the state phase is still the empty
# `timing_phase_begin "state"`/`timing_phase_end "state"` placeholder), so
# these are trivially green today by omission. They exist to fail the moment
# T031's record-on-success wiring records state on an outcome it must not.
#
# Reuses three pre-existing scenarios rather than adding new ones, since the
# only new assertion each needs is "no state file exists afterward":
# sc008-task-tier-boundary (warns, exit 0), us2-field-defaults-question
# (ends in confirmation-pending on its second run, exit 0), us6-fail-closed
# (a 401 fault fails the run, exit 3).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "T023 — a run that ends with a warning records no state" {
  bash "${HARNESS}" "${CONF}/scenarios/sc008-task-tier-boundary.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
  [ "$(jq -r '.counts.warnings' "${TMP}/out/stdout")" -gt 0 ]
  [ ! -e "${TMP}/out/workdir/.specify/jira/state/001-feature.json" ]
}

@test "T023 — a run that ends in a pending confirmation records no state" {
  bash "${HARNESS}" "${CONF}/scenarios/us2-field-defaults-question.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ "$(jq -r '.status' "${TMP}/out/stdout.2")" = "confirmation-pending" ]
  [ ! -e "${TMP}/out/workdir/.specify/jira/state/001-reporting.json" ]
}

@test "T023 — a failed run records no state" {
  bash "${HARNESS}" "${CONF}/scenarios/us6-fail-closed.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" != "0" ]
  [ ! -e "${TMP}/out/workdir/.specify/jira/state/001-feature.json" ]
}
