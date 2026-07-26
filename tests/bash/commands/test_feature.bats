#!/usr/bin/env bats
# T044 [US3] — The feature command (contracts/feature-cli-contract.md).
#
# Deterministic ticket-first naming: no team selected => {active:false} exit 0
# with zero side effects; invalid personal file => exit 4 located error;
# cross-team mentioned ticket without --use-team => confirmation_required exit 0
# zero writes; --use-team accepts only catalogue ids and never touches the
# personal file; non-catalogue-project ticket => proceed/stop confirmation; no
# key => guarded create; Jira unreachable or create refused => {active:false} +
# exactly one warning exit 0 (FR-016); --dry-run predicts with zero writes;
# override_used reported.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/feature.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"10201","priority_ids":{"P1":"1","P2":"2","P3":"3"},"estimation_field_id":null}'
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  write_teams_config
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

write_teams_config() {
  {
    printf 'projects:\n'
    printf '  - key: IJT\n'
    printf '    epic_strategy: per_repo\n'
    printf '    task_strategy: subtask\n'
    printf 'routing_default: IJT\n'
    printf 'teams:\n'
    printf '  - id: ijt\n'
    printf '    project: IJT\n'
    printf '    folder_prefix: "ijt-"\n'
    printf '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
    printf '  - id: wex\n'
    printf '    project: WEX\n'
    printf '    folder_prefix: "wex-"\n'
    printf '    branch_pattern: "wex-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
}

select_team() {
  printf 'team: %s\n' "$1" > "${JIRA_CONFIG_DIR}/personal.yml"
}

boot() {
  local cfg
  cfg="$(mktemp)"
  printf '%s' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "no team selected: {active:false}, exit 0, zero Jira calls (FR-017)" {
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "false" ]
  [ -z "$(mock_calls)" ]
}

@test "no config.yml at all: {active:false}, exit 0" {
  rm -f "${JIRA_CONFIG_DIR}/config.yml"
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "false" ]
}

@test "a missing description is a usage error (exit 1)" {
  select_team ijt
  run cmd_feature feature --json
  [ "$status" -eq 1 ]
}

@test "an invalid personal file stops with a located error (exit 4)" {
  printf 'team: zzz\n' > "${JIRA_CONFIG_DIR}/personal.yml"
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 4 ]
  [[ "$output" == *"personal.yml"* ]]
  [[ "$output" == *"ijt"* ]]
}

@test "a mentioned same-team ticket is validated and attached: names computed (FR-013/FR-015)" {
  select_team ijt
  boot '{"projects":{"IJT":"team","WEX":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "true" ]
  [ "$(jq -r '.team' <<< "$output")" = "ijt" ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "IJT-42" ]
  [ "$(jq -r '.ticket.number' <<< "$output")" = "42" ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "attached" ]
  [ "$(jq -r '.branch_name' <<< "$output")" = "ijt-42/invoice-export" ]
  [ "$(jq -r '.short_name' <<< "$output")" = "ijt-invoice-export" ]
  [ "$(jq -r '.override_used' <<< "$output")" = "false" ]
}

@test "a cross-team ticket without --use-team requires confirmation (FR-014)" {
  select_team ijt
  boot '{"projects":{"IJT":"team","WEX":"team"}}'
  run cmd_feature feature WEX-7 --json "onboarding"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.confirmation_required.ticket' <<< "$output")" = "WEX-7" ]
  [ "$(jq -r '.confirmation_required.ticket_team' <<< "$output")" = "wex" ]
  [ "$(jq -r '.confirmation_required.selected_team' <<< "$output")" = "ijt" ]
}

@test "--use-team wex confirms the cross-team convention; personal file untouched (FR-014)" {
  select_team ijt
  cp "${JIRA_CONFIG_DIR}/personal.yml" "${WORK}/personal-before"
  boot '{"projects":{"IJT":"team","WEX":"team"}}'
  run cmd_feature feature WEX-7 --use-team wex --json "onboarding"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.team' <<< "$output")" = "wex" ]
  [ "$(jq -r '.branch_name' <<< "$output")" = "wex-7/onboarding" ]
  [ "$(jq -r '.short_name' <<< "$output")" = "wex-onboarding" ]
  run cmp "${WORK}/personal-before" "${JIRA_CONFIG_DIR}/personal.yml"
  [ "$status" -eq 0 ]
}

@test "--use-team accepts only catalogue ids (exit 4)" {
  select_team ijt
  run cmd_feature feature --use-team nope --json "invoice export"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unknown team"* ]]
}

@test "a ticket in no catalogue project asks the proceed/stop confirmation" {
  select_team ijt
  boot '{"projects":{"IJT":"team","EXT":"company"}}'
  run cmd_feature feature EXT-9 --json "external work"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.confirmation_required.ticket' <<< "$output")" = "EXT-9" ]
  [ "$(jq -r '.confirmation_required.ticket_team' <<< "$output")" = "null" ]
}

@test "no mentioned key: a ticket is created in the effective team's project (FR-013)" {
  select_team ijt
  boot '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "IJT-123" ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "created" ]
  [ "$(jq -r '.branch_name' <<< "$output")" = "ijt-123/invoice-export" ]
  mock_calls | grep -q 'POST /rest/api/3/issue'
}

@test "Jira unreachable at create time: {active:false} + exactly one warning, exit 0 (FR-016)" {
  select_team ijt
  unset SPEC_KIT_JIRA_BASE_URL
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  local summary
  summary="$(printf '%s\n' "$output" | grep -v '^WARNING:')"
  [ "$(jq -r '.active' <<< "${summary}")" = "false" ]
  [ "$(jq -r '.warnings | length' <<< "${summary}")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^WARNING:')" -eq 1 ]
}

@test "a create refusal falls back non-blocking too (FR-016)" {
  select_team ijt
  boot '{"projects":{"IJT":"team"},"faults":{"IJT":{"status":500}}}'
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  local summary
  summary="$(printf '%s\n' "$output" | grep -v '^WARNING:')"
  [ "$(jq -r '.active' <<< "${summary}")" = "false" ]
  [ "$(jq -r '.warnings | length' <<< "${summary}")" -eq 1 ]
}

@test "a mentioned-key read failure stays fail-closed (exit 2, never fallback)" {
  select_team ijt
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature NOPE-1 --json "external"
  [ "$status" -eq 2 ]
}

@test "--dry-run predicts would-attach with zero writes" {
  select_team ijt
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --dry-run --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "would-attach" ]
  [ "$(jq -r '.branch_name' <<< "$output")" = "ijt-42/invoice-export" ]
  ! mock_calls | grep -q 'POST'
  ! mock_calls | grep -q 'PUT'
}

@test "--dry-run predicts would-create without a POST" {
  select_team ijt
  boot '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
  run cmd_feature feature --dry-run --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "would-create" ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "null" ]
  [ "$(jq -r '.branch_name' <<< "$output")" = "null" ]
  [ "$(jq -r '.short_name' <<< "$output")" = "ijt-invoice-export" ]
  [ -z "$(mock_calls)" ]
}

@test "a personal override applies and is reported (FR-012)" {
  {
    printf 'team: ijt\n'
    printf 'override:\n'
    printf '  folder_prefix: "special-"\n'
    printf '  branch_pattern: "special-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/personal.yml"
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.override_used' <<< "$output")" = "true" ]
  [ "$(jq -r '.branch_name' <<< "$output")" = "special-42/invoice-export" ]
  [ "$(jq -r '.short_name' <<< "$output")" = "special-invoice-export" ]
}

@test "the prefix is never duplicated when the description already carries it (FR-015)" {
  select_team ijt
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "ijt invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.short_name' <<< "$output")" = "ijt-invoice-export" ]
  [[ "$(jq -r '.short_name' <<< "$output")" != *"ijt-ijt-"* ]]
}
