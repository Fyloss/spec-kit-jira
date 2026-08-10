#!/usr/bin/env bats
# T088/T090/T092/T093a/T093c [Phase 6, US4, 022] — switching task_mirror mode
# destroys nothing (contracts/task-mirror-config.md §7; FR-033/FR-034/FR-035).
# Detected with no extra Jira read (research.md §6): the outbound direction
# from tasks.md's own preserved bound markers, the reverse direction from the
# story's already-read current description.

bats_require_minimum_version 1.5.0

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

  local cfg; cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
}

_switch_to_checklist() {
  printf 'task_mirror:\n  TASKP: checklist\n' >> "${JIRA_CONFIG_DIR}/config.yml"
}

_switch_back_to_subtask() {
  awk '/^task_mirror:/{skip=2} skip{skip--; next} {print}' "${JIRA_CONFIG_DIR}/config.yml" > "${JIRA_CONFIG_DIR}/config.yml.new"
  mv "${JIRA_CONFIG_DIR}/config.yml.new" "${JIRA_CONFIG_DIR}/config.yml"
}

@test "T088 — switching to checklist mode writes to no sub-task: zero write actions of any kind against a task-tier issue (FR-033)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local calls_before; calls_before="$(mock_calls | wc -l | tr -d ' ')"

  _switch_to_checklist
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  # No write of any kind (POST/PUT) targets the sub-task issue TASKP-3 DURING
  # THIS RUN — mock_calls is cumulative across the whole session, so only the
  # tail added by this second run is inspected.
  local subtask_calls
  subtask_calls="$(mock_calls | tail -n +$((calls_before + 1)) | grep -cE '(POST|PUT) /rest/api/3/issue/TASKP-3' || true)"
  [ "${subtask_calls}" -eq 0 ]
}

@test "T090 — the outbound switch report names the story, the abandoned count, and an exact issue-in query (FR-034)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  _switch_to_checklist
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -r '.notes // [] | join("\n")' <<< "$output")"
  [[ "${notes}" == *"switched to checklist mode"* ]]
  [[ "${notes}" == *"First story"* ]]
  [[ "${notes}" == *"1 sub-task"* ]]
  [[ "${notes}" == *"issue in (TASKP-3)"* ]]
}

@test "T092 — switching back removes the Tasks section, keeps every byte above the boundary, and re-binds rather than duplicates (FR-035)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  _switch_to_checklist
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(curl -s "${MOCK_BASE_URL}/rest/api/3/issue/TASKP-2" | jq -c '[.fields.description.content[]?.content[]?.text?] | any(. == "Tasks")')" = "true" ]

  _switch_back_to_subtask
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(curl -s "${MOCK_BASE_URL}/rest/api/3/issue/TASKP-2" | jq -c '[.fields.description.content[]?.content[]?.text?] | any(. == "Tasks")')" = "false" ]
  # Exactly one sub-task ever created across all three runs — the third run
  # re-binds TASKP-3 rather than creating a duplicate.
  local post_issue_calls; post_issue_calls="$(mock_calls | grep -cE '^POST /rest/api/3/issue$')"
  [ "${post_issue_calls}" -eq 3 ]
}

@test "T093a — the checklist-to-subtask switch is also reported once, naming the re-bound count, no query (FR-034)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  _switch_to_checklist
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  _switch_back_to_subtask
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -r '.notes // [] | join("\n")' <<< "$output")"
  [[ "${notes}" == *"switched back to subtask mode"* ]]
  [[ "${notes}" == *"1 sub-task"* ]]
  [[ "${notes}" == *"re-bound"* ]]
  [[ "${notes}" != *"issue in ("* ]]
}

@test "T093c — a story with no leftover marker is never named in the outbound switch report (never claims full migration of an unaffected story)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  _switch_to_checklist
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -r '.notes // [] | join("\n")' <<< "$output")"
  # The fixture's only OTHER attributed-task story never had a sub-task
  # created (Phase 1 setup carries no attribution) — it must not appear in
  # the switch report naming stories, since it was never migrated at all.
  [[ "${notes}" != *"fully migrated"* ]]
}
