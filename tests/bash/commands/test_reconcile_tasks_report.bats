#!/usr/bin/env bats
# T075-T077 [US4] — tasks that belong to no user story are reported, never
# invented into Jira: an unattributed task (FR-028), a dangling one attributed
# to a story ordinal the specification does not contain (FR-004), and both
# collapsing to one WARNING when the run fires inside a lifecycle hook
# (FR-026).

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
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  mock_stop
}

_mock_configs() {
  mock_write_config '{"projects":{"TASKP":"t"}}'
}

@test "T075 — an unattributed task is never mirrored and is named individually by task_ref with its reason (FR-028)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  # T001 carries no [US<N>] tag and sits under "## Phase 1: Setup", which is
  # not a "## Phase …: User Story <N>" heading — unattributed, not dangling.
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.tasks.skipped' <<< "$output")" -eq 1 ]
  local note; note="$(jq -r '.notes[] | select(startswith("T001 "))' <<< "$output")"
  [ -n "${note}" ]
  [[ "${note}" == *"no story attribution"* ]]
  [[ "${note}" == *"not mirrored"* ]]
  # No Jira issue was ever invented to host it: exactly the parent, the
  # story, and T002's own sub-task were created.
  local calls; calls="$(mock_calls | grep -c '^POST /rest/api/3/issue$')"
  [ "${calls}" -eq 3 ]
}

@test "T076 — a task attributed to a story ordinal the specification does not contain creates nothing, is reported, and every other task still mirrors (FR-004)" {
  printf -- '- [ ] T003 [US9] A dangling task\n' >> "${TASKS}"
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  # T001 (unattributed) and T003 (dangling) are both skipped; T002 still
  # mirrors normally.
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.tasks.skipped' <<< "$output")" -eq 2 ]
  local note; note="$(jq -r '.notes[] | select(startswith("T003 "))' <<< "$output")"
  [ -n "${note}" ]
  [[ "${note}" == *"User Story 9"* ]]
  [[ "${note}" == *"does not contain"* ]]
  [[ "${note}" == *"not mirrored"* ]]
  # Nothing invented to host T003, and T002's own sub-task still mirrored.
  local calls; calls="$(mock_calls | grep -c '^POST /rest/api/3/issue$')"
  [ "${calls}" -eq 3 ]
  grep -q "task=.*ticket=TASKP-3" "${TASKS}"
}

@test "T077 — under a lifecycle hook, the unattributed and dangling reports collapse to one WARNING and the host command still succeeds (FR-026)" {
  printf -- '- [ ] T003 [US9] A dangling task\n' >> "${TASKS}"
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(grep -c '^WARNING: ' <<< "$output")" -eq 1 ]
  local json_line; json_line="$(grep '^{' <<< "$output")"
  [ "$(jq -r '.counts.tasks.skipped' <<< "${json_line}")" -eq 2 ]
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
}
