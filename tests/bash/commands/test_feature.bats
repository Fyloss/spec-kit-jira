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

# --- 029 Phase 5 — told what to configure, instead of silence (US6) --------

@test "US6: no config.yml + a mentioned ticket names the file and the command (FR-026)" {
  rm -f "${JIRA_CONFIG_DIR}/config.yml"
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "false" ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *".specify/jira/config.yml"* ]]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"/speckit.jira.config"* ]]
}

@test "US6: an unreadable config.yml + a mentioned ticket names the file and the command (FR-026)" {
  printf '  bad: [unterminated\n' > "${JIRA_CONFIG_DIR}/config.yml"
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "false" ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *".specify/jira/config.yml"* ]]
}

@test "US6: an empty teams: catalogue + a mentioned ticket names the file and the command (FR-026)" {
  { printf 'projects:\n  - key: IJT\nrouting_default: IJT\nteams: []\n'; } > "${JIRA_CONFIG_DIR}/config.yml"
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "false" ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *".specify/jira/config.yml"* ]]
}

@test "US6: a catalogue exists but no team selected + a mentioned ticket names personal.yml, not config.yml (FR-026)" {
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "false" ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *".specify/jira/personal.yml"* ]]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"your own"* ]]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"/speckit.jira.config"* ]]
}

@test "US6: the same four states with NO mention stay byte-identical to the baseline (FR-028)" {
  rm -f "${JIRA_CONFIG_DIR}/config.yml"
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$output" = '{"active":false}' ]

  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$output" = '{"active":false}' ]
}

@test "US6: neither missing-configuration report issues a Jira request or fails the host command (FR-027)" {
  rm -f "${JIRA_CONFIG_DIR}/config.yml"
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ -z "$(mock_calls)" ]

  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ -z "$(mock_calls)" ]
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
  run cmd_feature feature IJT-42 --reuse no --json "invoice export"
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
  run cmd_feature feature WEX-7 --use-team wex --reuse no --json "onboarding"
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

# --- 027 US5: C-1/C-6 — the ordinary run is untouched -----------------------

@test "C-1: an invocation with neither designator flag is byte-identical to the current release" {
  select_team ijt
  boot '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$output" = '{"active":true,"branch_name":"ijt-123/invoice-export","override_used":false,"short_name":"ijt-invoice-export","team":"ijt","ticket":{"action":"created","key":"IJT-123","number":"123"},"warnings":[]}' ]
  [ "$(mock_calls)" = "$(printf 'POST /rest/api/3/issue\nPUT /rest/api/3/issue/IJT-123/properties/spec-kit-jira')" ]
}

@test "C-6: Jira unreachable, no designators, still {active:false} + exactly one warning, exit 0" {
  select_team ijt
  unset SPEC_KIT_JIRA_BASE_URL
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
  run cmd_feature feature IJT-42 --dry-run --reuse no --json "invoice export"
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
  run cmd_feature feature IJT-42 --reuse no --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.override_used' <<< "$output")" = "true" ]
  [ "$(jq -r '.branch_name' <<< "$output")" = "special-42/invoice-export" ]
  [ "$(jq -r '.short_name' <<< "$output")" = "special-invoice-export" ]
}

@test "the prefix is never duplicated when the description already carries it (FR-015)" {
  select_team ijt
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --reuse no --json "ijt invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.short_name' <<< "$output")" = "ijt-invoice-export" ]
  [[ "$(jq -r '.short_name' <<< "$output")" != *"ijt-ijt-"* ]]
}

# --- T087: feature prose (default, non---json) output ------------------------
# The prose renderer is feature-shaped: never the run-summary renderer (whose
# jq reads yield "Command: null" garbage on feature payloads).

@test "prose: pass-through renders exactly 'Feature: inactive' (T087)" {
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature "invoice export"
  [ "$status" -eq 0 ]
  [ "$output" = "Feature: inactive" ]
}

@test "prose: dry-run create renders the feature shape (T087)" {
  boot '{"projects":{"IJT":"team"}}'
  select_team ijt
  run cmd_feature feature --dry-run "invoice export"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Feature: active (team: ijt)" ]
  [ "${lines[1]}" = "Ticket: — (would-create)" ]
  [ "${lines[2]}" = "Branch: —" ]
  [ "${lines[3]}" = "Folder: ijt-invoice-export" ]
  [ "${lines[4]}" = "Override used: false" ]
}

@test "prose: fallback renders inactive plus the warning line (T087)" {
  boot '{"projects":{"IJT":"team"},"fault":{"network":true}}'
  select_team ijt
  run cmd_feature feature "invoice export"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Feature: inactive"* ]]
  [[ "$output" == *"Warning:"* ]]
  [[ "$output" != *"Command: null"* ]]
}

@test "T101: Principle XVI sweep — every message class this feature adds names the problem, the issue, and a copy-pasteable next step (FR-018, FR-023, FR-026)" {
  # 1. the reuse question
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"In Progress\"}}}}"
  run cmd_feature feature IJT-40 "invoice export"
  [[ "$output" == *"Feature: reuse decision required"* ]]
  [[ "$output" == *"IJT-40"* ]]
  [[ "$output" == *"Answers: --reuse"* ]]

  # 2. the which-issues question (fires only when no hierarchy is declared)
  {
    printf 'projects:\n  - key: IJT\n'
    printf 'routing_default: IJT\nteams:\n  - id: ijt\n    project: IJT\n    folder_prefix: "ijt-"\n    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-40 --reuse yes "invoice export"
  [[ "$output" == *"IJT-40"* ]]
  [[ "$output" == *"Answers:"* ]]
  [[ "$output" == *"--parent"* ]]
  write_hierarchy_config

  # 3. the halted warning
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"Done\"}}}}"
  run cmd_feature feature IJT-40 "invoice export"
  [[ "$output" == *"Halted: IJT-40"* ]]
  [[ "$output" == *"--reuse no, reopen it, or name another"* ]]

  # 4. the extras notice (Drafted: line)
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-41\":{\"summary\":\"B\",\"issuetype\":{\"name\":\"Story\"},\"status\":{\"name\":\"To Do\"}}}}"
  run cmd_feature feature IJT-41 "invoice export"
  [[ "$output" == *"Drafted:"* ]]
  [[ "$output" == *"beneath the same Epic"* ]]

  # 5/6. the two configuration reports
  rm -f "${JIRA_CONFIG_DIR}/config.yml"
  run cmd_feature feature IJT-42 --json "invoice export"
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *".specify/jira/config.yml"* ]]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"/speckit.jira.config"* ]]
  write_hierarchy_config
  rm -f "${JIRA_CONFIG_DIR}/personal.yml"
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export"
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *".specify/jira/personal.yml"* ]]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"/speckit.jira.config"* ]]

  # 7/8/9. the three usage errors
  select_team ijt
  write_hierarchy_config
  run cli_parse feature --reuse maybe --json "invoice export"
  [[ "$(grep '^exit=' <<< "$output")" = "exit=1" ]]
  run cmd_feature feature --reuse no --json "invoice export"
  [ "$status" -eq 1 ]
  [[ "$output" == *"never posed"* ]]
  run cmd_feature feature --parent IJT-40 --reuse no --json "invoice export"
  [ "$status" -eq 1 ]
  [[ "$output" == *"contradicts"* ]]

  # 10. the role-mismatch refusal: misplaced (FR-022)
  local issues_misplaced='{"IJT-40":{"summary":"S1","description":"d","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"id":"1","name":"Story"},"project":{"key":"IJT"}},"IJT-41":{"summary":"S2","description":"d","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"id":"1","name":"Story"},"project":{"key":"IJT"}}}'
  boot "{\"issues\":${issues_misplaced}}"
  run cmd_feature feature --json --parent IJT-40 --story IJT-41 "invoice export"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-ROLE"* ]]
  [[ "$output" == *"IJT-40"* ]]

  # 11. the role-mismatch refusal: unmapped-as-parent (FR-039)
  local issues_unmapped='{"IJT-99":{"summary":"Legacy","description":"d","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"id":"1","name":"Bug"},"project":{"key":"IJT"}},"IJT-11":{"summary":"S2","description":"d","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"id":"1","name":"Story"},"project":{"key":"IJT"}}}'
  boot "{\"issues\":${issues_unmapped}}"
  run cmd_feature feature --json --parent IJT-99 --story IJT-11 "invoice export"
  [ "$status" -ne 0 ]
  [[ "$output" == *"IJT-99"* ]]
  [[ "$output" == *"container"* ]]
  [[ "$output" == *"--parent"* ]]
}

@test "T131/T132: the fallback message never claims a ticket will be attached later, names the cause, and states a fresh create follows (FR-041)" {
  select_team ijt
  boot '{"projects":{"IJT":"team"},"fault":{"network":true}}'
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  local summary
  summary="$(printf '%s\n' "$output" | grep -v '^WARNING:')"
  local warning
  warning="$(jq -r '.warnings[0]' <<< "${summary}")"
  [[ "${warning}" != *"will attach it later"* ]]
  [[ "${warning}" == *"Jira is unreachable"* ]]
  [[ "${warning}" == *"new issue"* ]]
}

@test "T131/T132: a credentials rejection is named as its own cause (FR-041)" {
  select_team ijt
  boot '{"projects":{"IJT":"team"},"faults":{"IJT":{"status":401}}}'
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  local summary
  summary="$(printf '%s\n' "$output" | grep -v '^WARNING:')"
  local warning
  warning="$(jq -r '.warnings[0]' <<< "${summary}")"
  [[ "${warning}" == *"credentials"* ]]
  [[ "${warning}" != *"will attach it later"* ]]
}

@test "prose: cross-team confirmation renders the closed question (T087)" {
  boot '{"projects":{"IJT":"team","WEX":"team"}}'
  select_team ijt
  run cmd_feature feature WEX-7 "invoice export"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Feature: confirmation required" ]
  [ "${lines[1]}" = "Ticket: WEX-7 (team: wex)" ]
  [ "${lines[2]}" = "Selected team: ijt" ]
}

# --- 029 T005/T081/T012 — mention grammar, conditional field set, --reuse --

@test "mention gate: a bare key at the leading positional is detected" {
  run _feat_detect_mentions IJT-42 invoice export
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].key' <<< "$output")" = "IJT-42" ]
  [ "$(jq -r '.[0].raw' <<< "$output")" = "IJT-42" ]
}

@test "mention gate: a /browse/ URL at the leading positional is detected (FR-032)" {
  run _feat_detect_mentions "https://jira.example.com/browse/IJT-42" invoice export
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].key' <<< "$output")" = "IJT-42" ]
}

@test "mention gate: a selectedIssue= URL at the leading positional is detected (FR-032)" {
  run _feat_detect_mentions "https://jira.example.com/jira/software/c/projects/IJT/boards/1?selectedIssue=IJT-42" invoice export
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].key' <<< "$output")" = "IJT-42" ]
}

@test "mention gate: a URL reducing to nothing key-shaped is NOT a mention" {
  run _feat_detect_mentions "https://example.com/nothing/here" invoice export
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 0 ]
}

@test "mention gate: an ordinary word closes the gate — nothing further is examined, even a later key (contract §4 last row)" {
  run _feat_detect_mentions ticket "https://jira.example.com/browse/IJT-2241"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 0 ]
}

@test "mention gate: once open, every remaining key-shaped token is detected in argv order (FR-034)" {
  run _feat_detect_mentions IJT-40 see IJT-99 for background
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[0].key' <<< "$output")" = "IJT-40" ]
  [ "$(jq -r '.[1].key' <<< "$output")" = "IJT-99" ]
}

@test "mention gate: once open, a key and a link mix freely, in argv order" {
  run _feat_detect_mentions IJT-40 "https://jira.example.com/browse/IJT-99" background
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[1].key' <<< "$output")" = "IJT-99" ]
}

@test "mention gate: COVID-19 is detected like any other key once the gate is open" {
  run _feat_detect_mentions IJT-40 COVID-19
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[1].key' <<< "$output")" = "COVID-19" ]
}

@test "mention gate: no arguments detects nothing" {
  run _feat_detect_mentions
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a mentioned browser URL as the leading positional is validated and attached, like a bare key (FR-032, mention-grammar §4)" {
  select_team ijt
  boot '{"projects":{"IJT":"team","WEX":"team"}}'
  run cmd_feature feature "https://jira.example.com/browse/IJT-42" --reuse no --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "IJT-42" ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "attached" ]
  [ "$(jq -r '.branch_name' <<< "$output")" = "ijt-42/invoice-export" ]
}

@test "T064: no message class echoes a supplied URL verbatim — only the reduced key ever appears (Principle IX)" {
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"To Do\"}}}}"
  run cmd_feature feature "https://jira.example.com/browse/IJT-40" --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reuse_required.issues[0].key' <<< "$output")" = "IJT-40" ]
  [[ "$output" != *"jira.example.com"* ]]
  [[ "$output" != *"/browse/"* ]]
}

@test "--reuse yes/no are accepted; an invalid value is a usage error naming both (FR-009, FR-016)" {
  parsed="$(cli_parse feature --reuse yes --json "invoice export")"
  [ "$(grep '^reuse=' <<< "${parsed}")" = "reuse=yes" ]
  parsed="$(cli_parse feature --reuse no --json "invoice export")"
  [ "$(grep '^reuse=' <<< "${parsed}")" = "reuse=no" ]
  run cli_parse feature --reuse maybe --json "invoice export"
  [ "$(grep '^exit=' <<< "$output")" = "exit=1" ]
  [[ "$output" == *"yes"* && "$output" == *"no"* ]]
}

@test "--reuse absent means unanswered — the reuse= line is empty" {
  parsed="$(cli_parse feature --json "invoice export")"
  [ "$(grep '^reuse=' <<< "${parsed}")" = "reuse=" ]
}

# --- 029 Phase 3 — the reuse question itself (US1/US7/US9) -----------------

write_hierarchy_config() {
  {
    printf 'projects:\n'
    printf '  - key: IJT\n'
    printf '    hierarchy:\n'
    printf '      specification: Epic\n'
    printf '      story: Story\n'
    printf '    halted_statuses:\n'
    printf '      - Done\n'
    printf 'routing_default: IJT\n'
    printf 'teams:\n'
    printf '  - id: ijt\n'
    printf '    project: IJT\n'
    printf '    folder_prefix: "ijt-"\n'
    printf '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
}

@test "T015/regression: a mentioned key with no designator MUST NOT reach a silent naming (FR-001)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" = "true" ]
  [[ "$output" != *'"action":"attached"'* ]]
}

@test "the reuse question names key/summary/type/status, offers two answers, zero writes, exit 0 (FR-002-005)" {
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework the export pipeline\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"In Progress\"}}}}"
  run cmd_feature feature IJT-40 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reuse_required.issues[0].key' <<< "$output")" = "IJT-40" ]
  [ "$(jq -r '.reuse_required.issues[0].summary' <<< "$output")" = "Rework the export pipeline" ]
  [ "$(jq -r '.reuse_required.issues[0].type' <<< "$output")" = "Epic" ]
  [ "$(jq -r '.reuse_required.issues[0].status' <<< "$output")" = "In Progress" ]
  [ "$(jq -r '.reuse_required.issues[0].role' <<< "$output")" = "specification" ]
  ! mock_calls | grep -qE 'POST|PUT'
}

@test "the question omits branch_name and short_name, even as null (FR-031)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("branch_name")' <<< "$output")" = "false" ]
  [ "$(jq -r 'has("short_name")' <<< "$output")" = "false" ]
}

@test "an unresolvable mentioned key keeps today's fail-closed exit, no question (FR-006/FR-007)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature NOPE-1 --json "invoice export"
  [ "$status" -eq 2 ]
}

@test "a designator present suppresses the question (FR-006)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --parent IJT-40 --json "invoice export"
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" != "true" ]
}

@test "an unmapped type is proposed as a Story, never refused, needs no parent (FR-036, R11)" {
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-99\":{\"summary\":\"Legacy importer\",\"issuetype\":{\"name\":\"Bug\"},\"status\":{\"name\":\"To Do\"}}}}"
  run cmd_feature feature IJT-99 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reuse_required.issues[0].role' <<< "$output")" = "story" ]
  [ "$(jq -r '.reuse_required.issues[0].unmapped' <<< "$output")" = "true" ]
}

@test "a halted status is flagged in the question, naming the three ways on (FR-033)" {
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"Done\"}}}}"
  run cmd_feature feature IJT-40 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reuse_required.issues[0].halted' <<< "$output")" = "true" ]
  run cmd_feature feature IJT-40 "invoice export"
  [[ "$output" == *'REF-TERMINAL'* ]]
}

@test "an empty configured halted list never warns" {
  select_team ijt
  {
    printf 'projects:\n  - key: IJT\n    hierarchy:\n      specification: Epic\n      story: Story\n'
    printf 'routing_default: IJT\nteams:\n  - id: ijt\n    project: IJT\n    folder_prefix: "ijt-"\n    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"Done\"}}}}"
  run cmd_feature feature IJT-40 --json "invoice export"
  [ "$(jq -r '.reuse_required.issues[0].halted' <<< "$output")" = "false" ]
}

@test "multi-issue detection: three keys produce three proposal lines, one bulkfetch, argv order (FR-034)" {
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"A\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"To Do\"}},\"IJT-41\":{\"summary\":\"B\",\"issuetype\":{\"name\":\"Story\"},\"status\":{\"name\":\"To Do\"}},\"IJT-99\":{\"summary\":\"C\",\"issuetype\":{\"name\":\"Bug\"},\"status\":{\"name\":\"To Do\"}}}}"
  run cmd_feature feature IJT-40 IJT-41 IJT-99 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq '.reuse_required.issues | length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '.reuse_required.issues[0].key' <<< "$output")" = "IJT-40" ]
  [ "$(jq -r '.reuse_required.issues[1].key' <<< "$output")" = "IJT-41" ]
  [ "$(jq -r '.reuse_required.issues[2].key' <<< "$output")" = "IJT-99" ]
  [ "$(mock_calls | grep -c 'bulkfetch')" -eq 1 ]
}

@test "no hierarchy declared: no role proposed, the question asks for explicit designators (FR-035)" {
  select_team ijt
  {
    printf 'projects:\n  - key: IJT\n'
    printf 'routing_default: IJT\nteams:\n  - id: ijt\n    project: IJT\n    folder_prefix: "ijt-"\n    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reuse_required.issues[0].role' <<< "$output")" = "null" ]
  [ "$(jq -r '.reuse_required.declines_to.specification' <<< "$output")" = "null" ]
}

@test "--accept-defaults suppresses the question and proceeds as create-new would, stating the assumed answer (FR-013/FR-014)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --accept-defaults --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "attached" ]
  [ "$(jq -r '.warnings[0]' <<< "$output")" = "the reuse question was suppressed by --accept-defaults; assumed answer: create new" ]
}

@test "--reuse no proceeds as today's run from here on, byte-identical (FR-010)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --reuse no --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "attached" ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 0 ]
  mock_calls | grep -q 'GET /rest/api/3/issue/IJT-42?fields=project$'
}

@test "--reuse yes with no designator and NO declared hierarchy falls back to the which-issues follow-up (FR-029, FR-035)" {
  select_team ijt
  {
    printf 'projects:\n  - key: IJT\n'
    printf 'routing_default: IJT\nteams:\n  - id: ijt\n    project: IJT\n    folder_prefix: "ijt-"\n    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --reuse yes --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_issues_required")' <<< "$output")" = "true" ]
  [[ "$output" != *'"action":"attached"'* ]]
  ! mock_calls | grep -qE 'POST|PUT'
}

@test "--reuse yes with no designator auto-accepts the derived proposal: routes into the designator path, byte-identical to typing --parent/--story (FR-029, US3 AC1)" {
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework the export pipeline\",\"description\":\"Body text\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"In Progress\"},\"project\":{\"key\":\"IJT\"}}}}"
  run cmd_feature feature IJT-40 --reuse yes --json "invoice export"
  local auto_out="$status:$output"
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework the export pipeline\",\"description\":\"Body text\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"In Progress\"},\"project\":{\"key\":\"IJT\"}}}}"
  run cmd_feature feature --parent IJT-40 --json "invoice export"
  local direct_out="$status:$output"
  [ "$auto_out" = "$direct_out" ]
  [ "$(jq -r 'has("reuse_issues_required")' <<< "${auto_out#*:}")" != "true" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'
}

@test "--reuse yes with no designator, an unmapped-type issue is attached as story, no parent required (FR-029, FR-036, FR-038)" {
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-99\":{\"summary\":\"Legacy importer\",\"description\":\"Body text\",\"issuetype\":{\"name\":\"Bug\"},\"status\":{\"name\":\"To Do\"},\"project\":{\"key\":\"IJT\"}}}}"
  run cmd_feature feature IJT-99 --reuse yes --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_issues_required")' <<< "$output")" != "true" ]
  [ "$(jq -r 'has("seed_material")' <<< "$output")" = "true" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'
}

@test "--reuse yes with the mentioned ticket itself among the reused issues: no special case, no double resolution (US3 AC2)" {
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework\",\"description\":\"Body text\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"In Progress\"},\"project\":{\"key\":\"IJT\"}}}}"
  run cmd_feature feature IJT-40 --reuse yes --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "IJT-40" ]
}

# --- 029 Phase 4 — usage-error rows (T029/T102, FR-015) --------------------

@test "an answer supplied with neither a mention nor a designator is a usage error (FR-015 first clause)" {
  select_team ijt
  write_hierarchy_config
  run cmd_feature feature --reuse no --json "invoice export"
  [ "$status" -eq 1 ]
  [[ "$output" == *"never posed"* ]]
}

@test "--reuse no together with designators is a usage error naming the contradiction (FR-015 second clause)" {
  select_team ijt
  write_hierarchy_config
  run cmd_feature feature --reuse no --parent IJT-40 --json "invoice export"
  [ "$status" -eq 1 ]
  [[ "$output" == *"contradicts"* ]]
}

@test "--reuse yes together with designators is accepted in silence — redundancy is not an error (FR-015)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature --reuse yes --parent "A new epic" --json "invoice export"
  [ "$status" -eq 0 ]
  [[ "$output" != *"contradicts"* ]]
  [[ "$output" != *"never posed"* ]]
}

@test "an answered invocation never re-poses the question (FR-011)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --reuse no --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" != "true" ]
}

@test "T055: with no --accept-defaults and no terminal attached, the question still fires — no TTY probe suppresses it (research R3)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export" < /dev/null
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" = "true" ]
}

@test "T100: the naming step never reads stdin — held open or closed, output is byte-identical (FR-021)" {
  select_team ijt
  write_hierarchy_config
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --json "invoice export" < /dev/null
  local closed_status="$status" closed_out="$output"

  run cmd_feature feature IJT-42 --json "invoice export" < <(sleep 5 && printf 'unrelated\n')
  [ "$status" -eq "$closed_status" ]
  [ "$output" = "$closed_out" ]
}

@test "repeating an incomplete --reuse yes (no hierarchy declared) is idempotent: three byte-identical results, no state written (FR-030)" {
  select_team ijt
  {
    printf 'projects:\n  - key: IJT\n'
    printf 'routing_default: IJT\nteams:\n  - id: ijt\n    project: IJT\n    folder_prefix: "ijt-"\n    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  boot '{"projects":{"IJT":"team"}}'
  run cmd_feature feature IJT-42 --reuse yes --json "invoice export"
  local first="$output"
  run cmd_feature feature IJT-42 --reuse yes --json "invoice export"
  local second="$output"
  run cmd_feature feature IJT-42 --reuse yes --json "invoice export"
  local third="$output"
  [ "$first" = "$second" ]
  [ "$second" = "$third" ]
  [ "$(jq -r 'has("reuse_issues_required")' <<< "$first")" = "true" ]
  [ ! -d "${JIRA_CONFIG_DIR}/state" ]
}

@test "prose: the reuse question renders Detected/Attach/Answers lines" {
  select_team ijt
  write_hierarchy_config
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework the export pipeline\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"In Progress\"}}}}"
  run cmd_feature feature IJT-40 "invoice export"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Feature: reuse decision required" ]
  [[ "${lines[1]}" == "Detected: IJT-40 (Epic, In Progress) Rework the export pipeline" ]]
  [[ "$output" == *"Attach"*"?"* ]]
  [[ "$output" == *"Answers: --reuse yes"* ]]
}
