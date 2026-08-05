#!/usr/bin/env bats
# T081 (012, US5) — discovery_task_transition reads a sub-task's available
# transitions and selects a destination by statusCategory alone (FR-030): no
# status name is ever assumed or hard-coded, in either direction.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/discovery.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  mock_start "${MOCK}/configs/task-transitions.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
}

@test "exactly one done-category destination is selected as the transition" {
  run discovery_task_transition TASKS-1 forward
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transition_id' <<< "$output")" = "31" ]
  [ "$(jq -r '.withheld_field' <<< "$output")" = "null" ]
  [ "$(jq -r '.candidates | length' <<< "$output")" -eq 1 ]
}

@test "no done-category destination selects nothing and reports zero candidates" {
  run discovery_task_transition TASKS-2 forward
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transition_id' <<< "$output")" = "null" ]
  [ "$(jq -r '.candidates | length' <<< "$output")" -eq 0 ]
}

@test "two or more done-category destinations select nothing, both reported" {
  run discovery_task_transition TASKS-3 forward
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transition_id' <<< "$output")" = "null" ]
  [ "$(jq -r '.candidates | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.candidates | map(.name) | sort | join(",")' <<< "$output")" = "Annulé,Fait" ]
}

@test "the sole destination gated by a required field is withheld and named, never sent" {
  run discovery_task_transition TASKS-4 forward
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transition_id' <<< "$output")" = "null" ]
  [ "$(jq -r '.withheld_field.logical_name' <<< "$output")" = "Résolution" ]
  [ "$(jq -r '.withheld_field.field_id' <<< "$output")" = "resolution" ]
}

@test "backward direction selects the not-done destination, for operator-authorised reverts" {
  run discovery_task_transition TASKS-2 backward
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transition_id' <<< "$output")" = "21" ]
}

@test "a task already at a done-category destination has no not-done candidate backward" {
  run discovery_task_transition TASKS-1 backward
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transition_id' <<< "$output")" = "null" ]
  [ "$(jq -r '.candidates | length' <<< "$output")" -eq 0 ]
}
