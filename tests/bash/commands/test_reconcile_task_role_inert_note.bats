#!/usr/bin/env bats
# T098 [Phase 6, US4] — isolation rules I4/I5 (contract role-lifecycle-
# config.md §5): a DECLARED `task` mapping that currently has no effect
# (checklist mode, or no task role resolved at all) produces exactly ONE
# note per run — never a warning, never per ticket. An EMPTY mapping stays
# silent (I2's general rule) — declaring nothing is not the same as
# declaring something inert.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-task-tier"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
}

teardown() {
  mock_stop
}

@test "T098 -- a declared task mapping under checklist mode produces exactly one inert note, zero writes to the mapping's own effect" {
  local work="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-feature/spec.md"
  cat > "${work}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: TASKP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      task:
        after_specify: "To Do"
        after_plan: "In Progress"
routing_default: TASKP
task_mirror:
  TASKP: checklist
YAML

  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${spec}" --json > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${spec}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  local inert_notes
  inert_notes="$(jq -c '[.notes[] | select(contains("task-role lifecycle mapping"))]' <<< "$output")"
  [ "$(jq 'length' <<< "${inert_notes}")" -eq 1 ]
  [[ "$(jq -r '.[0]' <<< "${inert_notes}")" == *"mirrored as a checklist"* ]]
  # Never a warning.
  [[ "$(jq -r '.warnings | join(" ")' <<< "$output")" != *"task-role lifecycle mapping"* ]]
}

@test "T100 -- a sub-task abandoned by a switch to checklist mode never enters the mapping's move set, even with a declared step" {
  local work="${BATS_TEST_TMPDIR}/repo-abandoned"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-feature/spec.md"

  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # First run in `subtask` mode (the fixture's own default): binds TASKP-3,
  # its marker recorded in tasks.md.
  cmd_reconcile reconcile "${spec}" --json > /dev/null

  # Switch to checklist mode. The task role ALSO declares a step for this
  # event — a mapping that LOOKS active is exactly the case I6 guards:
  # TASKP-3's marker is still in tasks.md, its ticket still in the
  # tracker, but the mirror abandoned it the moment mode switched.
  cat > "${work}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: TASKP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      task:
        after_specify: "To Do"
        after_plan: "In Progress"
routing_default: TASKP
task_mirror:
  TASKP: checklist
YAML

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${spec}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(grep -c 'TASKP-3' "${MOCK_CALLLOG}")" -eq 0 ]
  [ "$(jq -e '[.actions[] | select(.url | contains("TASKP-3"))] | length' <<< "$output")" -eq 0 ]
  # The switch's own note still fires (022, unrelated to I6's own claim).
  [[ "$(jq -r '.notes | join(" ")' <<< "$output")" == *"switched to checklist mode"* ]]
}

@test "T098 -- an empty task mapping stays silent (I2), no inert note" {
  local work="${BATS_TEST_TMPDIR}/repo-empty"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-feature/spec.md"
  # No phase_status_map declared at all -- the task role resolves to an
  # empty map, which I2 says is never moved, never warned about, and
  # (I5's own scope) never NOTED either.

  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${spec}" --json > /dev/null

  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${spec}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(jq -e '[(.notes // [])[] | select(contains("task-role lifecycle mapping"))] | length' <<< "$output")" -eq 0 ]
}
