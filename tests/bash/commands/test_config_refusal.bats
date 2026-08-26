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
# T061 [003 US6] — An unreadable hook registry (FR-024)
# =============================================================================
#
# The rule this encodes is a rule about honesty. When the extension cannot read
# the registry it has NO evidence about the hooks, so saying "your hooks are
# missing" would be a confident, false, and expensive claim — it would send the
# operator to reinstall an extension whose hooks are fine. FR-024 requires the
# opposite: name the file, say what defeated the reader where that is
# determinable, and make no claim about the hooks at all.
#
# Two unreadable states are distinguished in prose, because they call for
# different actions: a genuinely broken file needs repairing, while valid YAML
# using a construct outside this reader's restricted subset needs rewriting in
# the subset (or nothing at all, if another tool owns that section).
#
# The run is a DEGRADED one — no base URL, so no Jira call — because the hooks
# effect is computed before the degraded check and needs no connection at all.

# _refusal_work — a scratch repository with a committed config and no Jira
# connection. Returns with WORK / JIRA_CONFIG_DIR exported.
_refusal_work() {
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  {
    printf 'projects:\n'
    printf '  - key: TEAM\n'
    printf 'routing_default: TEAM\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  unset SPEC_KIT_JIRA_BASE_URL
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
}

# _refusal_registry <line...> — write the registry under test.
_refusal_registry() {
  printf '%s\n' "$@" > "${SPEC_KIT_JIRA_EXTENSIONS_YML}"
}

# _refusal_summary — the --json summary alone. A degraded run also emits its
# single WARNING on stderr, which bats' `run` folds into $output.
_refusal_summary() {
  grep '^{' <<< "$output"
}

@test "an unreadable registry names the FILE as the cause and writes nothing (FR-024)" {
  _refusal_work
  _refusal_registry 'hooks:' '  after_plan:' '   - broken' '     : : :'
  local before
  before="$(shasum -a 256 < "${SPEC_KIT_JIRA_EXTENSIONS_YML}")"
  run cmd_config config --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.hooks.status' <<< "$(_refusal_summary)")" = "unreadable" ]
  [[ "$(jq -r '.effects.hooks.detail' <<< "$(_refusal_summary)")" == *"extensions.yml"* ]]
  [ "$(shasum -a 256 < "${SPEC_KIT_JIRA_EXTENSIONS_YML}")" = "${before}" ]
  rm -rf "${WORK}"
}

@test "an unreadable registry does NOT report the events as missing (FR-024)" {
  _refusal_work
  _refusal_registry 'hooks:' '  after_plan:' '   - broken' '     : : :'
  run cmd_config config --json
  # It must not tell the operator to reinstall over a file it merely failed to
  # parse — the install would not fix it, and the hooks may be perfectly fine.
  [[ "$(jq -r '.effects.hooks.detail' <<< "$(_refusal_summary)")" != *"specify extension add"* ]]
  [[ "$(jq -r '.effects.hooks.detail' <<< "$(_refusal_summary)")" == *"no claim is made about the hooks"* ]]
  rm -rf "${WORK}"
}

@test "a YAML anchor is distinguished in prose and NAMED (FR-024, Edge Cases)" {
  # Valid YAML, outside this reader's subset. The distinction matters: this file
  # is not broken, and telling the operator it is would send them to fix nothing.
  _refusal_work
  _refusal_registry 'defaults: &defaults' '  enabled: true' 'hooks:' '  after_plan:' '    - extension: jira-mirror'
  run cmd_config config --json
  [ "$(jq -r '.effects.hooks.status' <<< "$(_refusal_summary)")" = "unreadable" ]
  [[ "$(jq -r '.effects.hooks.detail' <<< "$(_refusal_summary)")" == *"anchor"* ]]
  rm -rf "${WORK}"
}

@test "a flow collection is distinguished in prose and NAMED (FR-024, Edge Cases)" {
  _refusal_work
  _refusal_registry 'hooks:' '  after_plan: [{extension: jira-mirror, command: speckit.jira.reconcile}]'
  run cmd_config config --json
  [[ "$(jq -r '.effects.hooks.detail' <<< "$(_refusal_summary)")" == *"flow collection"* ]]
  rm -rf "${WORK}"
}

@test "an unreadable registry never stops the rest of the ceremony (FR-015)" {
  # The hooks effect is one of four. A file we cannot read is a report, not a
  # reason to abandon the run.
  _refusal_work
  _refusal_registry 'hooks:' '  after_plan:' '   - broken' '     : : :'
  run cmd_config config --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.rerun_guidance' <<< "$(_refusal_summary)")" != "null" ]
  rm -rf "${WORK}"
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
