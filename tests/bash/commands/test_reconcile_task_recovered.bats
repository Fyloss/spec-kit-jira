#!/usr/bin/env bats
# T058 [US6] — once the ONLY reason a task tier was withheld is a
# defaultable field, recording its default and reconciling again creates
# exactly the withheld sub-tasks, moving the issue count by precisely that
# number, with no cleanup, no flag beyond the ordinary recorded-default
# confirmation, and nothing else changed (FR-039).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-subtask-mandatory-field"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-feature/spec.md"
  TASKS="${WORK}/specs/001-feature/tasks.md"

  # This scenario's task type has exactly ONE unmet field — Definition of
  # Done, which is defaultable — and no undefaultable one, so recording its
  # default is enough to make the tier fully recoverable (unlike the
  # withheld-forever case test_reconcile_task_withheld.bats exercises).
  cat > "${WORK}/.specify/jira/config.local.yml" << 'YAML'
resolved_ids:
  TASKM:
    style: company_managed
    issue_types:
      - logical_name: "Epic"
        id: "40701"
        hierarchy_level: "1"
        subtask: false
      - logical_name: "Story"
        id: "40704"
        hierarchy_level: "0"
        subtask: false
      - logical_name: "Sub-task"
        id: "40705"
        hierarchy_level: "-1"
        subtask: true
    roles:
      specification:
        logical_name: "Epic"
        id: "40701"
        hierarchy_level: "1"
        subtask: false
        source: declared
      story:
        logical_name: "Story"
        id: "40704"
        hierarchy_level: "0"
        subtask: false
        source: declared
      task:
        logical_name: "Sub-task"
        id: "40705"
        hierarchy_level: "-1"
        subtask: true
        source: declared
    child_type:
      logical_name: "Story"
      id: "40704"
      source: declared
    parent_type:
      logical_name: "Epic"
      id: "40701"
      source: declared
    required_fields:
      "40701":
        - logical_name: "Summary"
          field_id: "summary"
      "40704":
        - logical_name: "Summary"
          field_id: "summary"
      "40705":
        - logical_name: "Summary"
          field_id: "summary"
        - logical_name: "Definition of Done"
          field_id: "customfield_50011"
    defaultable_fields:
      "40705":
        - logical_name: "Definition of Done"
          field_id: "customfield_50011"
          schema_type: "string"
          required: true
          defaultable: true
          allowed_values: []
    parent_link_available:
      "40704": true
      "40705": true
    priorities:
      Highest: "1"
      Medium: "3"
      Low: "4"
    statuses:
      To Do: "10000"
    estimation_field_id: null
YAML

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  # 4 ids: the parent, the story, and one per tasks.md task line (T001's
  # unattributed setup task still gets a marker even though it is never
  # mirrored — same pool sizing as test_reconcile_tasks.bats).
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222 3333333333333333"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
  local cfg; cfg="$(mock_write_config '{"projects":{"TASKM":"company"},"issueTypeStyle":{"TASKM":"taskm"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
}

@test "T058 — recording the sole missing default and reconciling again creates exactly the withheld sub-task, moving the count by precisely one, with nothing else changed" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 0 ]

  run mock_calls
  local posts_before; posts_before="$(grep -c '^POST /rest/api/3/issue$' <<< "$output")"
  [ "${posts_before}" -eq 2 ]

  run cmd_config config TASKM --field-default 'TASKM=Sub-task=Definition of Done=Shipped and documented' --json
  [ "$status" -eq 0 ]

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 1 ]

  # The call log is cumulative for the whole test (no mock_reset seam) — the
  # count must have moved by exactly one, on top of the two POSTs already
  # made by the first run above.
  run mock_calls
  local posts_after; posts_after="$(grep -c '^POST /rest/api/3/issue$' <<< "$output")"
  [ "$((posts_after - posts_before))" -eq 1 ]
}
