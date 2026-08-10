#!/usr/bin/env bats
# T101/T103 [Phase 7, US5, 022] — checklist mode requires no `task` role and
# no sub-task issue type at all (FR-005, SC-007). The project's binding is
# resolved fresh through the config ceremony against a mock offering no
# Sub-task-level issue type, so `roles.task` is genuinely absent — not merely
# unconsulted.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-config"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1

  WORK="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${WORK}"
  cp -R "${FIXTURE}/.specify" "${WORK}/.specify"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"

  local cfg; cfg="$(mock_write_config '{"projects":{"COMP":"company"},"issueTypeStyle":{"COMP":"notask"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_config config --child-type COMP=Story --json > /dev/null

  mkdir -p "${WORK}/specs/001-feature"
  SPEC="${WORK}/specs/001-feature/spec.md"
  TASKS="${WORK}/specs/001-feature/tasks.md"
  {
    printf '# Feature Specification: No Subtask Demo\n\n'
    printf 'We need a working task tier without any sub-task type.\n\n'
    printf '### User Story 1 - The first story (Priority: P1)\n\n'
    printf 'As a user, I want the first story.\n\n'
    printf -- '- **Given** a thing\n- **When** it happens\n- **Then** it works\n'
  } > "${SPEC}"
  {
    printf '# Tasks\n\n## Phase 3: User Story 1\n\n'
    printf -- "- [ ] T001 [US1] Implement the first story's feature\n"
  } > "${TASKS}"

  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
}

teardown() {
  mock_stop
}

@test "T101: no resolved task role at all — the config ceremony resolved no task role" {
  local localj; localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.COMP.roles | has("task")' <<< "${localj}")" = "false" ]
}

@test "T101: checklist mode mirrors the full task list with no refusal, no missing-type warning (FR-005, SC-007)" {
  printf 'task_mirror:\n  COMP: checklist\n' >> "${JIRA_CONFIG_DIR}/config.yml"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.checklists.created' <<< "$output")" -eq 1 ]
  [[ "$(jq -r '.warnings | join("\n")' <<< "$output")" != *"sub-task"* ]]
  [[ "$(jq -r '.warnings | join("\n")' <<< "$output")" != *"issue type"* ]]
  [[ "$(jq -r '.notes | join("\n")' <<< "$output")" == "" ]]
}

@test "T103: the same project in subtask mode still produces feature 012's existing behaviour — no task tier at all, no conflation" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks' <<< "$output")" = "null" ]
  [ "$(jq -r '.counts.checklists' <<< "$output")" = "null" ]
  [[ "$(jq -r '.warnings | join("\n")' <<< "$output")" != *"sub-task"* ]]
}
