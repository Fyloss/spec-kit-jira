#!/usr/bin/env bats
# T007 [US1] — Style resolution in the config ceremony (FR-001/FR-002/FR-003).
#
# Per configured project, in order: unambiguous API signal (persisted with
# style_source "api") -> operator answer via the repeatable --style KEY=VALUE
# flag or a committed declaration (persisted with style_source "operator") ->
# fail closed: exit 4 (EXIT_CONFIG), ZERO writes, stderr naming the project key,
# the missing/contradictory signal, and the two valid values. A committed
# `style` conflicting with an unambiguous API signal re-enters the ambiguous
# branch. The run summary audits style + style_source per project (FR-003).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

write_config() {
  # write_config <key> [style-line]
  {
    printf 'projects:\n'
    printf '  - key: %s\n' "$1"
    [ -n "${2:-}" ] && printf '    style: %s\n' "$2"
    printf '    epic_strategy: per_repo\n'
    printf '    task_strategy: subtask\n'
    printf 'routing_default: %s\n' "$1"
  } > "${JIRA_CONFIG_DIR}/config.yml"
}

boot() {
  # boot <mock-projects-json>
  local cfg
  cfg="$(mktemp)"
  printf '{"projects":%s}' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "a bad --style value is a usage error (exit 1)" {
  write_config AMBI
  run cmd_config config --style AMBI=weird --json
  [ "$status" -eq 1 ]
}

@test "--style with no value is a usage error (exit 1)" {
  write_config AMBI
  run cmd_config config --style
  [ "$status" -eq 1 ]
}

@test "an unambiguous API signal persists with style_source api (resolution rung 1)" {
  write_config TEAM
  boot '{"TEAM":"team"}'
  run cmd_config config --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.TEAM.style' <<< "${localj}")" = "team_managed" ]
  [ "$(jq -r '.resolved_ids.TEAM.style_source' <<< "${localj}")" = "api" ]
}

@test "the API signal wins over a --style flag when unambiguous (api before operator)" {
  write_config TEAM
  boot '{"TEAM":"team"}'
  run cmd_config config --style TEAM=company_managed --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.TEAM.style' <<< "${localj}")" = "team_managed" ]
  [ "$(jq -r '.resolved_ids.TEAM.style_source' <<< "${localj}")" = "api" ]
}

@test "ambiguous without --style fails closed: exit 4, zero writes, located stderr (FR-002)" {
  write_config AMBI
  boot '{"AMBI":"ambiguous"}'
  run cmd_config config --json
  [ "$status" -eq 4 ]
  # stderr (in $output via run's merge) names the project, the signal problem,
  # and both valid --style values.
  [[ "$output" == *"AMBI"* ]]
  [[ "$output" == *"no unambiguous style signal"* ]]
  [[ "$output" == *"--style AMBI=company_managed"* ]]
  [[ "$output" == *"--style AMBI=team_managed"* ]]
  # Zero writes: no local binding, no hook registration, no README block.
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
  [ ! -f "${WORK}/.specify/extensions.yml" ]
  [ ! -f "${WORK}/README.md" ]
}

@test "a contradictory payload is ambiguous too (FR-002)" {
  write_config CONTRA
  boot '{"CONTRA":"contradictory"}'
  run cmd_config config --json
  [ "$status" -eq 4 ]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "--style resolves the ambiguity with style_source operator (resolution rung 2)" {
  write_config AMBI
  boot '{"AMBI":"ambiguous"}'
  run cmd_config config --style AMBI=team_managed --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.AMBI.style' <<< "${localj}")" = "team_managed" ]
  [ "$(jq -r '.resolved_ids.AMBI.style_source' <<< "${localj}")" = "operator" ]
}

@test "a committed style declaration resolves an ambiguous payload as operator" {
  write_config AMBI team_managed
  boot '{"AMBI":"ambiguous"}'
  run cmd_config config --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.AMBI.style' <<< "${localj}")" = "team_managed" ]
  [ "$(jq -r '.resolved_ids.AMBI.style_source' <<< "${localj}")" = "operator" ]
}

@test "a committed style conflicting with an unambiguous API signal is ambiguous (never silently overridden)" {
  write_config TEAM company_managed
  boot '{"TEAM":"team"}'
  run cmd_config config --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"TEAM"* ]]
  [[ "$output" == *"committed style conflicts with the API signal"* ]]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "--style resolves a committed-vs-API conflict with operator provenance" {
  write_config TEAM company_managed
  boot '{"TEAM":"team"}'
  run cmd_config config --style TEAM=team_managed --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.TEAM.style' <<< "${localj}")" = "team_managed" ]
  [ "$(jq -r '.resolved_ids.TEAM.style_source' <<< "${localj}")" = "operator" ]
}

@test "the run summary audits style + style_source per project (FR-003)" {
  write_config TEAM
  boot '{"TEAM":"team"}'
  run cmd_config config --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.discovery.projects.TEAM.style' <<< "$output")" = "team_managed" ]
  [ "$(jq -r '.effects.discovery.projects.TEAM.style_source' <<< "$output")" = "api" ]
}
