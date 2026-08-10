#!/usr/bin/env bats
# T012/T013a [Phase 2, 022] — the task-tier gate split (research.md §6): the
# single `task_type_id != ""` condition splits into three independent ones.
# tasks.md is read in both modes; durable identifiers are assigned, and
# sub-task writes are planned, in `subtask` mode only. An absent tasks.md is
# a silent no-op in both modes (spec Edge Cases).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-task-tier"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-feature/spec.md"
  TASKS="${WORK}/specs/001-feature/tasks.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
}

teardown() {
  mock_stop
}

_mock_configs() {
  mock_write_config '{"projects":{"TASKP":"t"}}'
}

_record_checklist_mode() {
  printf 'task_mirror:\n  TASKP: checklist\n' >> "${JIRA_CONFIG_DIR}/config.yml"
}

@test "checklist mode reads tasks.md and names an unattributed task, same as subtask mode (FR-022)" {
  _record_checklist_mode
  # T001 sits under "## Phase 1: Setup" in the fixture, which carries no
  # "User Story N" heading and no [US1] tag on the line itself — it is
  # unattributed by construction, in either mode.
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"T001"* ]]
  [[ "$output" == *"carries no story attribution"* ]]
}

@test "checklist mode assigns no durable identifier into tasks.md (FR-031)" {
  _record_checklist_mode
  local before; before="$(cat "${TASKS}")"
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local after; after="$(cat "${TASKS}")"
  [ "${before}" = "${after}" ]
  ! grep -q "speckit-jira task=" "${TASKS}"
}

@test "checklist mode plans zero sub-task writes and reports no counts.tasks (FR-007)" {
  _record_checklist_mode
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks' <<< "$output")" = "null" ]
  local task_issue_calls
  task_issue_calls="$(mock_calls | grep -c '^POST /rest/api/3/issue$')"
  # Exactly 2: the parent and the story — never a third for the task tier.
  [ "${task_issue_calls}" -eq 2 ]
}

@test "subtask mode is unaffected by the gate split — identifiers assigned, sub-task planned (baseline)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 1 ]
  grep -q "speckit-jira task=" "${TASKS}"
  local task_issue_calls
  task_issue_calls="$(mock_calls | grep -c '^POST /rest/api/3/issue$')"
  [ "${task_issue_calls}" -eq 3 ]
}

@test "an absent tasks.md is a silent no-op in checklist mode (spec Edge Cases)" {
  _record_checklist_mode
  rm -f "${TASKS}"
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks' <<< "$output")" = "null" ]
  [ "$(jq -r '(.warnings // []) | length' <<< "$output")" -eq 0 ]
}

@test "an absent tasks.md is a silent no-op in subtask mode, unchanged from before this feature" {
  rm -f "${TASKS}"
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks' <<< "$output")" = "null" ]
  [ "$(jq -r '(.warnings // []) | length' <<< "$output")" -eq 0 ]
}

@test "T033: a dry run prints each planned checklist per story with every entry's text and state, and writes nothing (FR-037)" {
  _record_checklist_mode
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json --dry-run
  [ "$status" -eq 0 ]
  local desc_content
  desc_content="$(jq -c '[.actions[] | select(.role=="story")][0].body.fields.description.content' <<< "$output")"
  [[ "$(jq -c . <<< "${desc_content}")" == *'"text":"Tasks"'* ]]
  [[ "$(jq -c . <<< "${desc_content}")" == *'"☐ "'* ]]
  [[ "$(jq -c . <<< "${desc_content}")" == *'Implement the first story'* ]]
  local calls; calls="$(mock_calls | grep -cE '^(POST|PUT) ' || true)"
  [ "${calls}" -eq 0 ]
}

@test "T086: a project with no recorded mode is unaffected by the switch-report code path — no note, ordinary subtask reconciliation (FR-002, SC-008)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -r '.notes // [] | join("\n")' <<< "$output")"
  [[ "${notes}" != *"switched to checklist mode"* ]]
  [[ "${notes}" != *"switched back to subtask mode"* ]]
}

@test "T094: checklist mode with a task role also declared reports it once as recorded and not consumed, and creates no sub-task (FR-007, spec Edge Cases)" {
  _record_checklist_mode
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -r '.notes // [] | join("\n")' <<< "$output")"
  [[ "${notes}" == *"a task role is declared but task_mirror is 'checklist'"* ]]
  [[ "${notes}" == *"recorded, not consumed"* ]]
  local task_issue_calls
  task_issue_calls="$(mock_calls | grep -c '^POST /rest/api/3/issue$')"
  [ "${task_issue_calls}" -eq 2 ]
}
