#!/usr/bin/env bats
# T058a [US6] — a created sub-task's field values are attributed to their
# source — recorded team default, operator answer for this run, or
# bridge-supplied — in the run summary and in the --dry-run preview, through
# feature 011's existing reporting surface with no sub-task-specific one
# added (FR-042).

bats_require_minimum_version 1.5.0

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

@test "FR-042 — a sub-task creation's recorded team default is attributed to its source in the run summary" {
  run cmd_config config TASKM --field-default 'TASKM=Sub-task=Definition of Done=Shipped and documented' --json
  [ "$status" -eq 0 ]

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -c '.notes' <<< "$output")"
  [ "$(jq -r '[.[] | select(contains("Definition of Done") and contains("sent from team-config"))] | length' <<< "${notes}")" -eq 1 ]
  [[ "${notes}" != *"customfield_"* ]]
}

@test "FR-042 — an operator-answer override applied to a sub-task creation is attributed to its source, with the promotion command, in the run summary" {
  run cmd_config config TASKM --field-default 'TASKM=Sub-task=Definition of Done=Shipped and documented' --json
  [ "$status" -eq 0 ]

  run cmd_reconcile reconcile "${SPEC}" --field-value 'TASKM=Sub-task=Definition of Done=Override Value' --accept-defaults --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -c '.notes' <<< "$output")"
  [ "$(jq -r '[.[] | select(contains("Definition of Done") and contains("sent from operator-answer"))] | length' <<< "${notes}")" -eq 1 ]
  [ "$(jq -r "[.[] | select(contains(\"--field-default 'TASKM=Sub-task=Definition of Done=Override Value'\"))] | length" <<< "${notes}")" -eq 1 ]
}

@test "FR-042 — the dry-run preview attributes a sub-task creation's field the same way, before anything is written" {
  run cmd_config config TASKM --field-default 'TASKM=Sub-task=Definition of Done=Shipped and documented' --json
  [ "$status" -eq 0 ]

  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -c '.notes' <<< "$output")"
  [ "$(jq -r '[.[] | select(contains("Definition of Done") and contains("sent from team-config"))] | length' <<< "${notes}")" -eq 1 ]
  [ "$(jq -r '[.[] | select(contains("this is a preview"))] | length' <<< "${notes}")" -eq 1 ]

  run mock_calls
  [ "$(grep -c '^POST /rest/api/3/issue$' <<< "$output")" -eq 0 ]
}

@test "FR-042 — a bridge-supplied field on a sub-task creation (never recorded, never answered) earns no provenance line" {
  run cmd_config config TASKM --field-default 'TASKM=Sub-task=Definition of Done=Shipped and documented' --json
  [ "$status" -eq 0 ]

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -c '.notes' <<< "$output")"
  [[ "${notes}" != *"sent from bridge"* ]]
  [[ "${notes}" != *"\"Summary\""* ]]
}
