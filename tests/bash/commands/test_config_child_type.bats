#!/usr/bin/env bats
# T038 [Phase 4, US1] — the ceremony's child-type closed question (research
# R1/R2, contract §2): derived and recorded `source: derived` when the child
# hierarchy level holds one candidate; asked (via --child-type) and recorded
# `source: operator` when it holds several — mirroring `style` /
# `style_source` exactly. The parent type is always derived and persisted
# alongside it.

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
  {
    printf 'projects:\n'
    printf '  - key: %s\n' "$1"
    printf 'routing_default: %s\n' "$1"
  } > "${JIRA_CONFIG_DIR}/config.yml"
}

@test "derives the child type when the level holds one candidate (SAFe: Story alone)" {
  _write_config SAFE
  mock_start "${MOCK}/configs/safe.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_config config --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.SAFE.child_type.logical_name' <<< "${localj}")" = "Story" ]
  [ "$(jq -r '.resolved_ids.SAFE.child_type.source' <<< "${localj}")" = "derived" ]
  [ "$(jq -r '.resolved_ids.SAFE.parent_type.logical_name' <<< "${localj}")" = "Feature" ]
  [ "$(jq -r '.resolved_ids.SAFE.parent_type.source' <<< "${localj}")" = "derived" ]
}

@test "asks (via --child-type) when the level holds several candidates (company: Story vs Defect)" {
  _write_config COMP
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_config config --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"child level holds more than one issue type"* ]]
  [[ "$output" == *"Story"* ]]
  [[ "$output" == *"Defect"* ]]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]

  run cmd_config config --child-type COMP=Defect --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.COMP.child_type.logical_name' <<< "${localj}")" = "Defect" ]
  [ "$(jq -r '.resolved_ids.COMP.child_type.source' <<< "${localj}")" = "operator" ]
}

@test "an unrecognised --child-type answer refuses, naming the candidates" {
  _write_config COMP
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_config config --child-type COMP=Epic --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"names no candidate at the child level"* ]]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "the PowerShell port resolves the child type identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  _write_config SAFE
  mock_start "${MOCK}/configs/safe.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_config config --json > /dev/null
  cp "${JIRA_CONFIG_DIR}/config.local.yml" "${WORK}/local-bash"

  local pswork
  pswork="$(mktemp -d)"
  mkdir -p "${pswork}/.specify/jira"
  cp "${JIRA_CONFIG_DIR}/config.yml" "${pswork}/.specify/jira/config.yml"
  SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" JIRA_CONFIG_DIR="${pswork}/.specify/jira" \
    JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    pwsh -NoProfile -Command "
      Import-Module '${ROOT}/scripts/powershell/commands/Config.psm1' -Force
      [void](Invoke-JiraConfig -Arguments @('config','--json'))
    " > /dev/null
  run diff "${WORK}/local-bash" "${pswork}/.specify/jira/config.local.yml"
  [ "$status" -eq 0 ]
  rm -rf "${pswork}"
}
