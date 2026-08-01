#!/usr/bin/env bats
# T021 [US2] — Project-key sourcing in a connected run (FR-004/FR-005/FR-006).
#
# The bound key comes exclusively from: positional argument -> committed config
# (the literal PROJ placeholder counts as unset) -> the closed question over the
# discovered accessible-projects list (unattended: exit 4 whose error describes
# that path). An unknown key propagates the transport's fail-closed exit with
# NO substitution. Git state plays no role in any of this.

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
  # write_config <key>
  {
    printf 'projects:\n'
    printf '  - key: %s\n' "$1"
    printf 'routing_default: %s\n' "$1"
  } > "${JIRA_CONFIG_DIR}/config.yml"
}

boot() {
  local cfg
  cfg="$(mktemp)"
  printf '%s' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "a positional PROJECT_KEY is validated by the first discovery read and bound" {
  write_config PROJ
  boot '{"projects":{"TEAM":"team"}}'
  run cmd_config config TEAM --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids | has("TEAM")' <<< "${localj}")" = "true" ]
}

@test "an unknown key fails closed with the transport's exit and NO substitution (FR-006)" {
  write_config PROJ
  boot '{"projects":{"TEAM":"team"},"faults":{"NOPE":{"status":404}}}'
  run cmd_config config NOPE --json
  [ "$status" -eq 2 ]
  # Nothing was bound in place of the failed key.
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "the literal PROJ placeholder counts as unset (FR-005)" {
  write_config PROJ
  boot '{"projects":{"COMP":"company","TEAM":"team"}}'
  run cmd_config config --json
  [ "$status" -eq 4 ]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "unattended with no usable key: exit 4, the error describes the closed-question path" {
  write_config PROJ
  boot '{"projects":{"COMP":"company","TEAM":"team"}}'
  run cmd_config config --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"no usable project key"* ]]
  [[ "$output" == *"placeholder"* ]]
  # The error lists the accessible projects the closed question offers.
  [[ "$output" == *"COMP"* ]]
  [[ "$output" == *"TEAM"* ]]
  [[ "$output" == *".specify/extensions/jira/scripts/bash/spec-kit-jira.sh config <KEY>"* ]]
}

@test "a committed non-placeholder key still binds without an argument" {
  write_config TEAM
  boot '{"projects":{"TEAM":"team"}}'
  run cmd_config config --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids | has("TEAM")' <<< "${localj}")" = "true" ]
}
