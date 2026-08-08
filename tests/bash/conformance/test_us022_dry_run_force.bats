#!/usr/bin/env bats
# T022 [Phase 4, US2] — Conformance: contracts/run-state.md §3 decision-table
# rows for --dry-run and --force, and invariant S6 (a dry run predicts the
# real run exactly, because it never reads or writes the state document).
#
# The --force assertions are genuinely red today: `--force` is not yet a
# recognized flag, so the CLI parser rejects it before any guard or phase
# runs (`scripts/bash/lib/cli.sh`'s `--*) error="unknown flag: $1"` fallthrough).
# The --dry-run assertions are forward-looking regression guards, not
# red-before-green fixes: no code path writes or short-circuits on state for
# ANY run yet, so they are trivially green today by omission. They exist to
# fail the moment a future implementation gets --dry-run's bypass wrong.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "T022 — dry-run never short-circuits, even on a matching state the prior run just recorded" {
  bash "${HARNESS}" "${CONF}/scenarios/us022-dry-run-full-preview.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ -s "${TMP}/out/calls.log.2" ]
  [ "$(jq -r '.short_circuited // false' "${TMP}/out/stdout.2")" = "false" ]
}

@test "T022 — dry-run on a spec with no recorded state writes no state document" {
  bash "${HARNESS}" "${CONF}/scenarios/us022-dry-run-no-write.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
  [ ! -e "${TMP}/out/workdir/.specify/jira/state/001-billing-invoices.json" ]
}

@test "T022 — force bypasses the read on both runs and records state after each success" {
  bash "${HARNESS}" "${CONF}/scenarios/us022-force-bypasses-and-records.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.1")" = "0" ]
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ -s "${TMP}/out/calls.log.1" ]
  [ -s "${TMP}/out/calls.log.2" ]
  [ -e "${TMP}/out/workdir/.specify/jira/state/001-billing-invoices.json" ]
  jq -e . "${TMP}/out/workdir/.specify/jira/state/001-billing-invoices.json" > /dev/null
}
