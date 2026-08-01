#!/usr/bin/env bats
# T042 [US1] — Determinism + machine-readable ceremony (FR-001, FR-002, SC-004).
#
# Every step of the config ceremony is an API read, a config read, or a closed
# enumerated question — never a model judgement. The observable proxies:
#   1. the run performs ONLY reads against Jira (no create/update during config),
#   2. `--json` emits a machine-readable run summary (run-summary.schema.json),
#   3. two runs against an unchanged project write a byte-identical
#      config.local.yml (the resolved-id table), on this port and across ports.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  PS_CMD="${ROOT}/scripts/powershell/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-config"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  cp -R "${FIXTURE}/.specify" "${WORK}/.specify"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

boot() {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "config --json emits a valid machine-readable run summary (FR-002)" {
  boot
  run cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.schema_version' <<< "$output")" = "1.0" ]
  [ "$(jq -r '.command' <<< "$output")" = "config" ]
  [ "$(jq -r '.exit_code' <<< "$output")" = "0" ]
}

@test "the ceremony reads only — no create/update Jira calls during config (FR-001)" {
  boot
  cmd_config config --child-type COMP=Story --json > /dev/null
  run mock_calls
  # Every recorded call is a read (GET); a config run never mutates Jira.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == GET\ * ]]
  done <<< "$output"
}

@test "two runs against an unchanged project write a byte-identical config.local.yml (FR-003)" {
  boot
  cmd_config config --child-type COMP=Story --json > "${WORK}/run1"
  cp "${JIRA_CONFIG_DIR}/config.local.yml" "${WORK}/local1"
  cmd_config config --child-type COMP=Story --json > "${WORK}/run2"
  cp "${JIRA_CONFIG_DIR}/config.local.yml" "${WORK}/local2"
  # The persisted resolved-id table is byte-identical on re-run (the FR-003 artifact).
  run diff "${WORK}/local1" "${WORK}/local2"
  [ "$status" -eq 0 ]
  # The idempotency signal: the second run reports discovery as unchanged (zero churn).
  [ "$(jq -r '.effects.discovery.status' "${WORK}/run1")" = "written" ]
  [ "$(jq -r '.effects.discovery.status' "${WORK}/run2")" = "unchanged" ]
}

@test "the resolved-id table preserves the discovered ids by logical name" {
  boot
  cmd_config config --child-type COMP=Story --json > /dev/null
  local json
  json="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  # New list shape (008 T014a): issue_types is a list of
  # {logical_name, id, hierarchy_level, subtask}, not a name-to-id map.
  [ "$(jq -r '.resolved_ids.COMP.issue_types[] | select(.logical_name=="Story") | .id' <<< "$json")" = "10102" ]
  [ "$(jq -r '.resolved_ids.COMP.priorities.Critical' <<< "$json")" = "1" ]
  [ "$(jq -r '.resolved_ids.COMP.statuses.Backlog' <<< "$json")" = "1" ]
  # The operator-authored local layer (site_alias, overrides) is preserved.
  [ "$(jq -r '.site_alias' <<< "$json")" = "prod" ]
}

@test "the PowerShell port writes a byte-identical config.local.yml (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  boot
  cmd_config config --child-type COMP=Story --json > /dev/null
  cp "${JIRA_CONFIG_DIR}/config.local.yml" "${WORK}/local-bash"

  local pswork
  pswork="$(mktemp -d)"
  cp -R "${FIXTURE}/.specify" "${pswork}/.specify"
  SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" JIRA_CONFIG_DIR="${pswork}/.specify/jira" \
    JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Config.psm1' -Force
      [void](Invoke-JiraConfig -Arguments @('config','--child-type','COMP=Story','--json'))
    " > /dev/null
  run diff "${WORK}/local-bash" "${pswork}/.specify/jira/config.local.yml"
  [ "$status" -eq 0 ]
  rm -rf "${pswork}"
}
