#!/usr/bin/env bats
# T059 [US6] — a run creating all three tiers, each carrying a defaulted
# field, asks ONE consolidated confirmation covering all three — never one
# per tier (FR-040).

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

  # The specification tier has no custom field of its own; the story tier
  # carries one required, defaultable field (Business Owner) alongside the
  # task tier's own (Definition of Done) — every tier that can create this
  # run has a defaulted field riding along.
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
        - logical_name: "Business Owner"
          field_id: "customfield_50022"
      "40705":
        - logical_name: "Summary"
          field_id: "summary"
        - logical_name: "Definition of Done"
          field_id: "customfield_50011"
    defaultable_fields:
      "40704":
        - logical_name: "Business Owner"
          field_id: "customfield_50022"
          schema_type: "string"
          required: true
          defaultable: true
          allowed_values: []
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
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
  local cfg; cfg="$(mock_write_config '{"projects":{"TASKM":"company"},"issueTypeStyle":{"TASKM":"taskm"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # Recorded directly (bypassing the live-discovery ceremony, whose
  # ask-scope is not this test's concern) — both the story's and the task's
  # required fields have a recorded team default.
  local map='{"TASKM":{"Story":{"Business Owner":"Platform Team"},"Sub-task":{"Definition of Done":"Shipped and documented"}}}'
  _config_field_defaults_write "${JIRA_CONFIG_DIR}/config.yml" "${map}" "false" > /dev/null
}

teardown() {
  mock_stop
}

@test "FR-040 — a run creating all three tiers, each carrying a defaulted field, asks one consolidated confirmation naming every tier's field" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "confirmation-pending" ]
  [ "$(jq -r '[.fields[] | select(.label=="Business Owner")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.fields[] | select(.label=="Definition of Done")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.creations_pending' <<< "$output")" -eq 3 ]

  run mock_calls
  [ "$(grep -c '^POST /rest/api/3/issue$' <<< "$output")" -eq 0 ]
}

@test "FR-040 — resuming with --accept-defaults creates all three tiers in the same run, with no second question" {
  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status // "ok"' <<< "$output")" != "confirmation-pending" ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 1 ]

  run mock_calls
  [ "$(grep -c '^POST /rest/api/3/issue$' <<< "$output")" -eq 3 ]
}
