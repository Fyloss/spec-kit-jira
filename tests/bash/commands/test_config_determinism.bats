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
  # backend defaults to the curl shim; the NFR-1 cross-port test below opts
  # into the real pwsh server, since a native pwsh HTTP client cannot reach
  # the shim's sentinel MOCK_BASE_URL (contracts/mock-driver.md).
  mock_start "${MOCK}/configs/default.json" "${1:-bash}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "config --json emits a valid machine-readable run summary (FR-002)" {
  boot
  run --separate-stderr cmd_config config --child-type COMP=Story --json
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

# =============================================================================
# T020/T039/T079 [Phase 3/5, US1/US3] — role-mapping determinism (contract
# §5.2): a second ceremony run over unchanged inputs writes byte-identical
# YAML and emits no question; supersession is a ONE-TIME convergence, so a
# third run over the now-converged state emits no note either.
# =============================================================================

_role_mapping_boot() {
  MOCK="${ROOT}/tests/conformance/mock-jira"
  mock_start "${MOCK}/configs/consumer-hierarchy.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  RWORK="$(mktemp -d)"
  mkdir -p "${RWORK}/.specify/jira"
  JIRA_CONFIG_DIR="${RWORK}/.specify/jira"
  export JIRA_CONFIG_DIR
}

@test "T020 — a second run over a declared, unchanged mapping writes byte-identical YAML and asks no question" {
  _role_mapping_boot
  {
    printf 'projects:\n'
    printf '  - key: CONSUMER\n'
    printf '    hierarchy:\n'
    printf '      specification: Epic\n'
    printf '      story: Story\n'
    printf 'routing_default: CONSUMER\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"

  run cmd_config config --json
  [ "$status" -eq 0 ]
  cp "${JIRA_CONFIG_DIR}/config.local.yml" "${RWORK}/local1"

  run cmd_config config --json
  [ "$status" -eq 0 ]
  [[ "$output" != *'"unresolved_roles"'* ]]
  run diff "${RWORK}/local1" "${JIRA_CONFIG_DIR}/config.local.yml"
  [ "$status" -eq 0 ]
  rm -rf "${RWORK}"
}

@test "T039/T082 — a committed declaration supersedes a recorded operator answer, once, then converges" {
  _role_mapping_boot
  {
    printf 'projects:\n'
    printf '  - key: CONSUMER\n'
    printf 'routing_default: CONSUMER\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"

  # Run 1: the operator answers once. Both roles persist with source: operator.
  run cmd_config config --issue-type CONSUMER=specification=Epic --issue-type CONSUMER=story=Story --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.specification.source' <<< "${localj}")" = "operator" ]

  # Run 2: config.yml now declares a DIFFERENT specification type. The
  # declaration outranks the recorded operator answer (§3, step 1 > step 2);
  # the binding converges, and the run names both types (§7.2).
  {
    printf 'projects:\n'
    printf '  - key: CONSUMER\n'
    printf '    hierarchy:\n'
    printf '      specification: Service Category\n'
    printf '      story: Story\n'
    printf 'routing_default: CONSUMER\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"

  run cmd_config config --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'specification is declared as "Service Category" in config.yml; the local answer "Epic" was superseded.'* ]]
  cp "${JIRA_CONFIG_DIR}/config.local.yml" "${RWORK}/local2"
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.specification.logical_name' <<< "${localj}")" = "Service Category" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.specification.source' <<< "${localj}")" = "declared" ]

  # Run 3: the same declaration, now converged. No note, byte-identical YAML.
  run cmd_config config --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"was superseded"* ]]
  run diff "${RWORK}/local2" "${JIRA_CONFIG_DIR}/config.local.yml"
  [ "$status" -eq 0 ]
  rm -rf "${RWORK}"
}

@test "the PowerShell port writes a byte-identical config.local.yml (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  boot powershell
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
