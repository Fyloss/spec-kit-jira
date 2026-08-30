#!/usr/bin/env bats
# T036/T040 [US2] — Config-time refusal of an impossible mapping (FR-007).
#
# A team-managed project supports only an Epic parent and Sub-task children
# (research §3). Declaring a hierarchy level ABOVE Epic is impossible and MUST be
# refused at config time with EXIT_CONFIG (4), naming the offending level and the
# project style. The "Epic" tier is identified from the DISCOVERED binding (the
# top non-subtask hierarchy level), never a compiled-in name (Constitution VII).
# Company-managed projects carry no such restriction. Persistence of the chosen
# strategies is by logical name. The PowerShell port refuses identically.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  PS_CMD="${ROOT}/scripts/powershell/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  TEAM_BINDING='{"style":"team_managed","issue_types":[{"logical_name":"Epic","id":"10200","subtask":false,"hierarchy_level":1},{"logical_name":"Story","id":"10201","subtask":false,"hierarchy_level":0},{"logical_name":"Sub-task","id":"10202","subtask":true,"hierarchy_level":-1}]}'
  COMPANY_BINDING='{"style":"company_managed","issue_types":[{"logical_name":"Initiative","id":"10100","subtask":false,"hierarchy_level":2},{"logical_name":"Deliverable","id":"10101","subtask":false,"hierarchy_level":1},{"logical_name":"Story","id":"10102","subtask":false,"hierarchy_level":0}]}'
}

@test "refuses a team-managed level above Epic with exit 4, naming the level and style" {
  run config_validate_mapping team_managed '["Initiative","Epic","Story"]' "${TEAM_BINDING}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"Initiative"* ]]
  [[ "$output" == *"team_managed"* ]]
}

@test "accepts a valid team-managed Epic/Story hierarchy" {
  run config_validate_mapping team_managed '["Epic","Story"]' "${TEAM_BINDING}"
  [ "$status" -eq 0 ]
}

@test "does not restrict a company-managed multi-level hierarchy" {
  run config_validate_mapping company_managed '["Initiative","Deliverable","Story"]' "${COMPANY_BINDING}"
  [ "$status" -eq 0 ]
}

@test "persists key and style by logical name" {
  run config_project_mapping COMP company_managed
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "COMP" ]
  [ "$(jq -r '.style' <<< "$output")" = "company_managed" ]
}

@test "the PowerShell port refuses the level-above-Epic identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  run config_validate_mapping team_managed '["Initiative","Epic","Story"]' "${TEAM_BINDING}"
  local bash_status="$status"
  local ps_status
  ps_status="$(pwsh -NoProfile -Command "
    Import-Module '${PS_CMD}/Config.psm1' -Force
    \$c = Test-JiraMappingValidity -Style 'team_managed' -HierarchyJson '[\"Initiative\",\"Epic\",\"Story\"]' -BindingJson '${TEAM_BINDING}'
    [Console]::Out.Write(\$c)
  ")"
  [ "$bash_status" -eq 4 ]
  [ "$ps_status" -eq 4 ]
}

# =============================================================================
# T052 [030, US2] — the §6 ordering rule: a malformed FILE setting refuses
# even when the environment holds a valid one (contracts/connection-
# settings.md §6). config_load validates the file unconditionally; the
# chokepoint only ever SEEDS an unset variable, so a bad file is never masked
# by a good environment value.
# =============================================================================

@test "T052 — a malformed base_url in config.yml refuses even with a valid SPEC_KIT_JIRA_BASE_URL exported" {
  local dir; dir="$(mktemp -d)"
  cat > "${dir}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
routing_default: PROJ
base_url: "https://team.atlassian.net/"
YAML
  export SPEC_KIT_JIRA_BASE_URL="https://valid.example.invalid"
  JIRA_CONFIG_DIR="${dir}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"base_url is invalid"* ]]
  unset SPEC_KIT_JIRA_BASE_URL
  rm -rf "${dir}"
}

@test "T052 — a malformed email in personal.yml refuses even with a valid JIRA_EMAIL exported" {
  local dir; dir="$(mktemp -d)"
  cat > "${dir}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
routing_default: PROJ
YAML
  printf 'email: not-an-address\n' > "${dir}/personal.yml"
  export JIRA_EMAIL="valid@example.com"
  JIRA_CONFIG_DIR="${dir}" run config_personal_load "${dir}" '{}'
  [ "$status" -eq 4 ]
  [[ "$output" == *"email is invalid"* ]]
  unset JIRA_EMAIL
  rm -rf "${dir}"
}

# =============================================================================
# 034 T027/T029/T030 [US3] — the withdrawn flag and the withdrawn key.
# =============================================================================
#
# Both refusals are produced by paths that ALREADY EXISTED. Nothing was added to
# obtain them (SC-004), and that is the point: the extension has exactly one
# operator, so there was no installed base for a dedicated retired-key rule or a
# bespoke message to spare. The key leaves the accepted set and the schema's
# existing unknown-key refusal handles whatever remains.
#
# The key test asserts the MESSAGE, not only the exit code. A refactor that
# dropped the file path from the report would keep the code green while losing
# the only part an operator can act on.

@test "034 — --enable-hook is refused as an unknown flag, naming it (FR-004, US3 AC1)" {
  run cmd_config config --enable-hook after_specify
  [ "$status" -ne 0 ]
  [[ "$output" == *"--enable-hook"* ]]
  # The EXISTING unknown-flag path, not a bespoke "this was retired" message.
  [[ "$output" == *"unknown"* || "$output" == *"unrecognised"* || "$output" == *"unrecognized"* ]]
}

@test "034 — a config.local.yml declaring hooks is refused, naming key and file (FR-005, SC-004)" {
  local dir
  dir="$(mktemp -d)"
  printf 'projects:\n  - key: PROJ\nrouting_default: PROJ\n' > "${dir}/config.yml"
  printf 'hooks:\n  disabled:\n    - after_specify\n' > "${dir}/config.local.yml"
  JIRA_CONFIG_DIR="${dir}" run config_load "${dir}"
  [ "$status" -eq 4 ]
  # Names the key...
  [[ "$output" == *"hooks"* ]]
  # ...and the file it is in. Both halves matter to an operator.
  [[ "$output" == *"config.local.yml"* ]]
  rm -rf "${dir}"
}

@test "034 — a config.local.yml declaring none of the withdrawn keys still validates (US3 AC3)" {
  local dir
  dir="$(mktemp -d)"
  printf 'projects:\n  - key: PROJ\nrouting_default: PROJ\n' > "${dir}/config.yml"
  printf 'site_alias: prod\n' > "${dir}/config.local.yml"
  JIRA_CONFIG_DIR="${dir}" run config_load "${dir}"
  [ "$status" -eq 0 ]
  rm -rf "${dir}"
}
