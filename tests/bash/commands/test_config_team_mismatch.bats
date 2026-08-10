#!/usr/bin/env bats
# T077 [US2] — Connected-run mismatch surfacing (FR-009, analyze remediation A1).
#
# When the committed config declares a `teams:` catalogue, a connected run
# checks each declared team's project against the accessible-projects list and
# emits one named warning per team whose project matches no accessible project
# (a provisional, branch-derived value may have been accepted into the
# catalogue). Warn, never block. Without a catalogue, no extra read happens.

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
  # write_config [teams:true|false]
  {
    printf 'projects:\n'
    printf '  - key: IJT\n'
    printf 'routing_default: IJT\n'
    if [ "${1:-true}" = "true" ]; then
      printf 'teams:\n'
      printf '  - id: ijt\n'
      printf '    project: IJT\n'
      printf '    folder_prefix: "ijt-"\n'
      printf '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
      printf '  - id: wex\n'
      printf '    project: WEX\n'
      printf '    folder_prefix: "wex-"\n'
      printf '    branch_pattern: "wex-<ID>/<FEATURE_NAME>"\n'
    fi
  } > "${JIRA_CONFIG_DIR}/config.yml"
}

boot() {
  local cfg
  cfg="$(mktemp)"
  printf '%s' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "a catalogue team whose project is not accessible produces one named warning (FR-009)" {
  write_config true
  boot '{"projects":{"IJT":"team"}}'
  run --separate-stderr cmd_config config --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^WARNING:')" -eq 1 ]
  [[ "$stderr" == *"team 'wex'"* ]]
  [[ "$stderr" == *"WEX"* ]]
  [ "$(jq -r '.counts.warnings' <<< "$output")" -eq 1 ]
  # The run still binds normally (warn, never block).
  [ -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "all catalogue teams accessible: zero warnings" {
  write_config true
  boot '{"projects":{"IJT":"team","WEX":"team"}}'
  run --separate-stderr cmd_config config --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^WARNING:' || true)" -eq 0 ]
  [ "$(jq -r '.counts.warnings' <<< "$output")" -eq 0 ]
}

@test "no catalogue declared: no project/search call at all" {
  write_config false
  boot '{"projects":{"IJT":"team"}}'
  run cmd_config config --json
  [ "$status" -eq 0 ]
  ! mock_calls | grep -q 'project/search'
}
