#!/usr/bin/env bats
# T054 [US6] — the field-defaults ceremony's ask-scope follows the declared
# roles: a `task` role joins the specification and story types on the same
# closed-question terms; with no `task` role the ceremony asks nothing about
# any sub-task type (FR-035).

bats_require_minimum_version 1.5.0

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

_write_config() {
  # $1 = extra indented lines under the project entry (may be empty)
  {
    printf 'projects:\n'
    printf '  - key: CONSUMER\n'
    [[ -n "${1:-}" ]] && printf '%s\n' "$1"
    printf 'routing_default: CONSUMER\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
}

boot() {
  # The consumer fixture's Sous-tâche type (id 10716) is overridden here to
  # carry a required, defaultable field — nothing else about the project
  # changes.
  local cfg
  cfg="$(mock_write_config '{"projects":{"CONSUMER":"company"},"issueTypeStyle":{"CONSUMER":"consumer"},"createmetaFields":{"10716":"consumer-task-mandatory"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "T054 — a declared task role asks about the sub-task type's required field, by its Jira label (FR-035)" {
  _write_config '    hierarchy:
      specification: Epic
      story: Story
      task: "Sous-tâche"'
  boot

  run --separate-stderr cmd_config config CONSUMER --json
  [ "$status" -eq 0 ]
  [[ "${stderr}" == *"Definition of Done"* ]]
  [[ "${stderr}" == *"--field-default 'CONSUMER=Sous-tâche=Definition of Done=<value>'"* ]]
}

@test "T054 — with no task role declared, the ceremony asks nothing about any sub-task type (FR-035)" {
  _write_config '    hierarchy:
      specification: Epic
      story: Story'
  boot

  run --separate-stderr cmd_config config CONSUMER --json
  [ "$status" -eq 0 ]
  [[ "${stderr}" != *"Definition of Done"* ]]
  [[ "${stderr}" != *"Sous-tâche"* ]]
}
