#!/usr/bin/env bats
# T048 [US3] — The config ceremony's gitignore effect (FR-019).
#
# The ceremony verifies the repository .gitignore covers the gitignored config
# layer — config.local.yml, .env, and the NEW personal.yml — appending only the
# missing lines, idempotently. The effect reports created|written|unchanged|
# skipped; a second run reports `unchanged` with a byte-identical .gitignore.

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
  {
    printf 'projects:\n'
    printf '  - key: TEAM\n'
    printf '    epic_strategy: per_repo\n'
    printf '    task_strategy: subtask\n'
    printf 'routing_default: TEAM\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

boot() {
  local cfg
  cfg="$(mktemp)"
  printf '%s' '{"projects":{"TEAM":"team"}}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "an absent .gitignore is created with the three managed lines (FR-019)" {
  boot
  run cmd_config config --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.gitignore.status' <<< "$output")" = "created" ]
  grep -qx '.specify/jira/personal.yml' "${WORK}/.gitignore"
  grep -qx '.specify/jira/config.local.yml' "${WORK}/.gitignore"
  grep -qx '.specify/jira/.env' "${WORK}/.gitignore"
}

@test "only missing lines are appended to an existing .gitignore (written)" {
  printf 'node_modules/\n.specify/jira/config.local.yml\n' > "${WORK}/.gitignore"
  boot
  run cmd_config config --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.gitignore.status' <<< "$output")" = "written" ]
  # The pre-existing content survives; the missing lines were appended once.
  grep -qx 'node_modules/' "${WORK}/.gitignore"
  [ "$(grep -cx '.specify/jira/config.local.yml' "${WORK}/.gitignore")" -eq 1 ]
  grep -qx '.specify/jira/personal.yml' "${WORK}/.gitignore"
}

@test "a second run reports unchanged with a byte-identical .gitignore (idempotent)" {
  boot
  run cmd_config config --json
  [ "$status" -eq 0 ]
  cp "${WORK}/.gitignore" "${WORK}/gitignore-1"
  run cmd_config config --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.gitignore.status' <<< "$output")" = "unchanged" ]
  run cmp "${WORK}/gitignore-1" "${WORK}/.gitignore"
  [ "$status" -eq 0 ]
}

@test "--dry-run computes the status without touching the file" {
  boot
  run cmd_config config --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.gitignore.status' <<< "$output")" = "created" ]
  [ ! -f "${WORK}/.gitignore" ]
}
