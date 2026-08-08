#!/usr/bin/env bats
# T021 [Phase 4, US2] — Conformance: every doubt about the recorded run-state
# document fails open to a full reconcile (contracts/run-state.md §3, §8
# invariants S1/S7/S8) — a corrupt document, a stale extension_version, and a
# config.yml edit must never be trusted or silently repaired; the second run
# must complete a full reconcile and re-record fresh state.
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

@test "T021 — a corrupt state document does not survive a full reconcile" {
  bash "${HARNESS}" "${CONF}/scenarios/us021-state-corrupt.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ -s "${TMP}/out/calls.log.2" ]
  jq empty "${TMP}/out/workdir/${STATE_REL}"
}

@test "T021 — a stale extension_version does not survive a full reconcile" {
  bash "${HARNESS}" "${CONF}/scenarios/us021-state-version-changed.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ -s "${TMP}/out/calls.log.2" ]
  jq empty "${TMP}/out/workdir/${STATE_REL}"
  [ "$(jq -r '.extension_version' "${TMP}/out/workdir/${STATE_REL}")" != "0.0.0-t021-sentinel" ]
}

@test "T021 — an edited config.yml does not survive a full reconcile" {
  bash "${HARNESS}" "${CONF}/scenarios/us021-state-config-changed.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit.2")" = "0" ]
  [ -s "${TMP}/out/calls.log.2" ]
  jq empty "${TMP}/out/workdir/${STATE_REL}"
}
