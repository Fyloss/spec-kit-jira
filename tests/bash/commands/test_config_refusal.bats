#!/usr/bin/env bats
# T036/T040 [US2] — Config-time refusal of an impossible mapping (FR-007).
#
# A team-managed project supports only an Epic parent and Sub-task children
# (research §3). Declaring a hierarchy level ABOVE Epic is impossible and MUST be
# refused at config time with EXIT_CONFIG (4), naming the offending level and the
# project style. The "Epic" tier is identified from the DISCOVERED binding (the
# top non-subtask hierarchy level), never a compiled-in name (Constitution VII).
# Company-managed projects carry no such restriction. Persistence of the chosen
# strategies is by logical name. The PowerShell port refuses identically.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/commands"
  PS_CMD="${ROOT}/.specify/extensions/jira/scripts/powershell/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  TEAM_BINDING='{"style":"team_managed","issue_types":[{"logical_name":"Epic","id":"10200","subtask":false,"hierarchy_level":1},{"logical_name":"Story","id":"10201","subtask":false,"hierarchy_level":0},{"logical_name":"Sub-task","id":"10202","subtask":true,"hierarchy_level":-1}]}'
  COMPANY_BINDING='{"style":"company_managed","issue_types":[{"logical_name":"Initiative","id":"10100","subtask":false,"hierarchy_level":2},{"logical_name":"Deliverable","id":"10101","subtask":false,"hierarchy_level":1},{"logical_name":"Story","id":"10102","subtask":false,"hierarchy_level":0}]}'
}

@test "refuses a team-managed level above Epic with exit 4, naming the level and style" {
  run config_validate_mapping team_managed '["Initiative","Epic","Story"]' "${TEAM_BINDING}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"Initiative"* ]]
  [[ "$output" == *"team_managed"* ]]
}

@test "accepts a valid team-managed Epic/Story hierarchy" {
  run config_validate_mapping team_managed '["Epic","Story"]' "${TEAM_BINDING}"
  [ "$status" -eq 0 ]
}

@test "does not restrict a company-managed multi-level hierarchy" {
  run config_validate_mapping company_managed '["Initiative","Deliverable","Story"]' "${COMPANY_BINDING}"
  [ "$status" -eq 0 ]
}

@test "persists epic/task strategy and link type by logical name" {
  run config_project_mapping COMP company_managed per_repo linked_story "blocks"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "COMP" ]
  [ "$(jq -r '.epic_strategy' <<< "$output")" = "per_repo" ]
  [ "$(jq -r '.task_strategy' <<< "$output")" = "linked_story" ]
  [ "$(jq -r '.link_type' <<< "$output")" = "blocks" ]
}

@test "refuses linked_story without a link type (exit 4)" {
  run config_project_mapping TEAM team_managed per_feature linked_story
  [ "$status" -eq 4 ]
}

@test "the PowerShell port refuses the level-above-Epic identically (NFR-1)" {
  run config_validate_mapping team_managed '["Initiative","Epic","Story"]' "${TEAM_BINDING}"
  local bash_status="$status"
  local ps_status
  ps_status="$(pwsh -NoProfile -Command "
    Import-Module '${PS_CMD}/Config.psm1' -Force
    \$c = Test-JiraMappingValidity -Style 'team_managed' -HierarchyJson '[\"Initiative\",\"Epic\",\"Story\"]' -BindingJson '${TEAM_BINDING}'
    [Console]::Out.Write(\$c)
  ")"
  [ "$bash_status" -eq 4 ]
  [ "$ps_status" -eq 4 ]
}
