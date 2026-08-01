#!/usr/bin/env bats
# The conformance harness is hermetic: a scenario's outcome is decided by the
# scenario, never by whatever SPEC_KIT_JIRA_* / JIRA_* variables the caller
# happened to be holding when it invoked the harness.
#
# Regression. tests/powershell/lib/TokenLeak.Tests.ps1 exports
# SPEC_KIT_JIRA_PROJECT_KEY=PROJ (the shipped placeholder) in a BeforeEach and
# never clears it. Pester discovers lib/ immediately before conformance/ on the
# Linux CI host — but after commands/, whose Reconcile.* files scrub that same
# variable, on the author's macOS host. Every reconcile scenario therefore
# refused with the placeholder-key message (exit 4, zero writes) instead of
# mirroring: four red conformance tests in CI, green locally, and nothing in
# either log naming the cause.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "an ambient SPEC_KIT_JIRA_PROJECT_KEY never reaches the port" {
  # PROJ is the shipped placeholder: if it reaches the port, reconcile refuses
  # with exit 4 before its first Jira call instead of mirroring.
  export SPEC_KIT_JIRA_PROJECT_KEY=PROJ
  bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-french.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
  [ "$(jq -r '[.actions[] | select(.role=="story") | .body.fields.issuetype.id] | unique | join(",")' "${TMP}/out/stdout")" = "10302" ]
}

@test "an ambient SPEC_KIT_JIRA_PLAN_CONTEXT never rewrites the creation context" {
  # The override is read wholesale (FR-013), so a leaked one silently replaces
  # every id the persisted binding resolved.
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"99999"}'
  bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-french.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
  [ "$(jq -r '[.actions[] | select(.role=="story") | .body.fields.issuetype.id] | unique | join(",")' "${TMP}/out/stdout")" = "10302" ]
}

@test "an ambient SPEC_KIT_JIRA_HOOK_CONTEXT never downgrades a refusal" {
  # Under a hook every refusal becomes one WARNING and exit 0 — which would
  # turn the stale-binding scenario's exit 4 into a pass that proves nothing.
  export SPEC_KIT_JIRA_HOOK_CONTEXT=after_specify
  bash "${HARNESS}" "${CONF}/scenarios/us1-binding-shape-stale.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "4" ]
  [[ "$(cat "${TMP}/out/stderr")" == *"predates parent support"* ]]
}

@test "an ambient JIRA_CONFIG_DIR never redirects the port away from the workdir" {
  export JIRA_CONFIG_DIR="${TMP}/elsewhere"
  mkdir -p "${JIRA_CONFIG_DIR}"
  bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-french.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
}

@test "SPEC_KIT_JIRA_HARNESS_ENV is the one channel that still reaches the port" {
  # The scrub has to leave a deliberate override a way through, or every test
  # that varies one variable across two runs of one scenario needs a second
  # scenario file.
  SPEC_KIT_JIRA_HARNESS_ENV="SPEC_KIT_JIRA_PROJECT_KEY=PROJ" \
    bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-french.json" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "4" ]
  [[ "$(cat "${TMP}/out/stderr")" == *"shipped placeholder"* ]]
}

@test "a malformed SPEC_KIT_JIRA_HARNESS_ENV entry fails the run rather than being ignored" {
  SPEC_KIT_JIRA_HARNESS_ENV="not-a-pair" run bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-french.json" bash "${TMP}/out"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not KEY=VALUE"* ]]
}

@test "the harness's own entry-point override still reaches it" {
  # The scrub is by prefix, so the variables the HARNESS itself is configured
  # with have to be exempt or this file passes while the harness is unusable.
  export SPEC_KIT_JIRA_ENTRY_BASH="${TMP}/does-not-exist.sh"
  run bash "${HARNESS}" "${CONF}/scenarios/us1-hierarchy-french.json" bash "${TMP}/out"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"entry point not found"* ]]
}
