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

@test "034 — a retired disable record is REFUSED, with zero requests and the state file untouched" {
  # This test used to assert the opposite: that a lifecycle event recorded as
  # disabled produced exit 0 with no output at all. 034 retired that record —
  # `hooks.disabled` left config.local.yml's accepted key set — so the same
  # fixture now falls to the schema's pre-existing unknown-key refusal.
  #
  # What the placement claim still needs, and still gets: the refusal happens
  # BEFORE the state phase. Zero requests, and the recorded state document is
  # byte-identical afterwards — the run never reached the code that reads it.
  STATE_REL=".specify/jira/state/001-billing-invoices.json"
  FIXTURE="${CONF}/fixtures/repo-with-disabled-event/${STATE_REL}"
  bash "${HARNESS}" "${CONF}/scenarios/us021b-retired-disable-record.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "4" ]
  [ ! -s "${TMP}/out/calls.log" ]
  # The refusal names the key and the file (FR-005, SC-004).
  grep -q 'hooks' "${TMP}/out/stderr"
  grep -q 'config.local.yml' "${TMP}/out/stderr"
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
