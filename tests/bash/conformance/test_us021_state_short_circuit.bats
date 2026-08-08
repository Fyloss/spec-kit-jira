#!/usr/bin/env bats
# T020 [Phase 4, US2] — Conformance: a second reconcile over an unchanged
# specification short-circuits on the run-state document (contracts/run-state.md,
# invariant T8 of contracts/timing-report.md §3).
#
# `calls.log.2` (run-scenario.sh, 021/US2) is the SECOND run's own slice of the
# shared, cumulative mock log — never the log-so-far, which still carries the
# first run's ticket creation.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  SCENARIO="${CONF}/scenarios/us021-state-unchanged.json"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "T020 — the second run issues zero requests, exits 0, and names the short-circuit" {
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ ! -s "${TMP}/out/calls.log.2" ]
  [ "$(jq -r '.short_circuited' "${TMP}/out/stdout.2")" = "true" ]
}

@test "T032 — the short-circuit summary names the file that recorded it" {
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out" > /dev/null
  [[ "$(jq -r '.state_file' "${TMP}/out/stdout.2")" == *"/state/"*".json" ]]
}

@test "T020/T8 — with the timing mode on, the second run's stderr carries only prereq, state, and total" {
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out" > /dev/null
  [ "$(grep -c '^timing: ' "${TMP}/out/stderr.2")" -eq 3 ]
  [[ "$(sed -n '1p' "${TMP}/out/stderr.2")" == "timing: prereq"* ]]
  [[ "$(sed -n '2p' "${TMP}/out/stderr.2")" == "timing: state"* ]]
  [[ "$(sed -n '3p' "${TMP}/out/stderr.2")" == "timing: total"* ]]
}
