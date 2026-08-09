#!/usr/bin/env bats
# T021b [Phase 4, US2] — contracts/run-state.md §9 FR-027 placement rows: the
# dispatch guard and the target guard both fire before the state phase, so a
# disabled lifecycle event and a rejected target behave exactly as they do
# today — even with a plausible run-state document already recorded for the
# feature directory, that document must never be read, written, or moved.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "T021b — a disabled lifecycle event exits 0 silently, with zero requests, state file untouched" {
  STATE_REL=".specify/jira/state/001-billing-invoices.json"
  FIXTURE="${CONF}/fixtures/repo-with-disabled-event/${STATE_REL}"
  bash "${HARNESS}" "${CONF}/scenarios/us021b-disabled-event.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
  [ ! -s "${TMP}/out/calls.log" ]
  [ ! -s "${TMP}/out/stdout" ]
  [ ! -s "${TMP}/out/stderr" ]
  diff "${FIXTURE}" "${TMP}/out/workdir/${STATE_REL}"
}

@test "T021b — a rejected target exits 1 with zero requests, state file untouched" {
  STATE_REL=".specify/jira/state/001-test-page.json"
  FIXTURE="${CONF}/fixtures/repo-with-plan-artifact/${STATE_REL}"
  bash "${HARNESS}" "${CONF}/scenarios/us021b-rejected-target.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "1" ]
  [ ! -s "${TMP}/out/calls.log" ]
  diff "${FIXTURE}" "${TMP}/out/workdir/${STATE_REL}"
}
