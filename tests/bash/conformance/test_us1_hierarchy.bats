#!/usr/bin/env bats
# T039/T040/T041 [Phase 4, US1] — Conformance: hierarchy resolution on
# non-default Jira instances, its two refusals, and the stale-binding
# refusal, driven through the real dispatcher.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "T039 — French project: children carry the resolved child type id, no code difference" {
  bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-french.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
  # Every STORY action carries the child type; the one parent action (Phase
  # 5, US2) legitimately carries the PARENT type instead, so it is excluded
  # from this check.
  [ "$(jq -r '[.actions[] | select(.role=="story") | .body.fields.issuetype.id] | unique | join(",")' "${TMP}/out/stdout")" = "10302" ]
}

@test "T039 — SAFe project: children carry the resolved child type id" {
  bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-safe.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
  [ "$(jq -r '[.actions[] | select(.role=="story") | .body.fields.issuetype.id] | unique | join(",")' "${TMP}/out/stdout")" = "10403" ]
}

@test "T040 — no-parent-level: exit 4, zero writes, candidates named" {
  bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-no-parent-level.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "4" ]
  [[ "$(cat "${TMP}/out/stderr")" == *"FLAT"* ]]
  [[ "$(cat "${TMP}/out/stderr")" == *"Story"* ]]
  [ ! -f "${TMP}/out/workdir/.specify/jira/config.local.yml" ]
}

@test "T040 — parent-level-ambiguous: exit 4, zero writes, every candidate named" {
  bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-ambiguous.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "4" ]
  [[ "$(cat "${TMP}/out/stderr")" == *"Capability"* ]]
  [[ "$(cat "${TMP}/out/stderr")" == *"Feature"* ]]
  [ ! -f "${TMP}/out/workdir/.specify/jira/config.local.yml" ]
}

@test "T041 — a pre-feature binding refuses legibly, never as 'not bound yet'" {
  bash "${HARNESS}" "${CONF}/scenarios/us1-binding-shape-stale.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "4" ]
  [[ "$(cat "${TMP}/out/stderr")" == *"predates parent support"* ]]
  [[ "$(cat "${TMP}/out/stderr")" != *"has not been bound yet"* ]]
  [ ! -s "${TMP}/out/calls.log" ]
}
