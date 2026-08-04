#!/usr/bin/env bats
# T077 [US8] — Incremental re-bind + per-project identity scope (FR-043, FR-044).
#
# The config command iterates over every mapped project and is incrementally
# re-runnable: adding a project to config.yml and re-running binds ONLY that new
# project and leaves every previously-bound project's resolved-id mapping untouched
# (byte-identical). Because each project's resolved ids land under its own key,
# two teams on distinct projects never collide (per-project identity scope).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  PS_CMD="${ROOT}/scripts/powershell/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/../lib/config.sh"
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

# write_config <project-block> — write a config.yml with the supplied projects.
write_config() {
  cat > "${JIRA_CONFIG_DIR}/config.yml" <<EOF
projects:
$1
routing_default: "COMP"
EOF
}

boot() {
  # backend defaults to the curl shim; the NFR-1 cross-port test below opts
  # into the real pwsh server, since a native pwsh HTTP client cannot reach
  # the shim's sentinel MOCK_BASE_URL (contracts/mock-driver.md).
  mock_start "${MOCK}/configs/default.json" "${1:-bash}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "adding a project binds only that one and leaves existing mappings untouched (FR-043)" {
  boot
  # First run: only COMP is configured.
  write_config '  - key: COMP
    style: company_managed'
  run cmd_config config --child-type COMP=Story --child-type TEAM=Story --json
  [ "$status" -eq 0 ]
  local before after
  before="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '(.resolved_ids.COMP.issue_types[] | select(.logical_name=="Story") | .id)' <<< "$before")" = "10102" ]
  [ "$(jq -r '.resolved_ids | has("TEAM")' <<< "$before")" = "false" ]

  # Second run: add TEAM alongside COMP.
  write_config '  - key: COMP
    style: company_managed
  - key: TEAM
    style: team_managed'
  run cmd_config config --child-type COMP=Story --child-type TEAM=Story --json
  [ "$status" -eq 0 ]
  after="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"

  # TEAM is now bound...
  [ "$(jq -r '.resolved_ids | has("TEAM")' <<< "$after")" = "true" ]
  # ...and COMP's mapping is byte-for-byte unchanged (untouched).
  [ "$(jq -cS '.resolved_ids.COMP' <<< "$before")" = "$(jq -cS '.resolved_ids.COMP' <<< "$after")" ]
}

@test "each project's ids are scoped under its own key so two projects never collide (FR-044)" {
  boot
  write_config '  - key: COMP
    style: company_managed
  - key: TEAM
    style: team_managed'
  run cmd_config config --child-type COMP=Story --child-type TEAM=Story --json
  [ "$status" -eq 0 ]
  local json
  json="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  # Company- and team-managed ids live under distinct keys — no shared namespace.
  [ "$(jq -r '(.resolved_ids.COMP.issue_types[] | select(.logical_name=="Story") | .id)' <<< "$json")" = "10102" ]
  [ "$(jq -r '(.resolved_ids.TEAM.issue_types[] | select(.logical_name=="Story") | .id)' <<< "$json")" != "null" ]
  [ "$(jq -r '(.resolved_ids.COMP.issue_types[] | select(.logical_name=="Story") | .id) != (.resolved_ids.TEAM.issue_types[] | select(.logical_name=="Story") | .id)' <<< "$json")" = "true" ]
}

@test "a project removed from the local layer by hand is re-bound but others preserved" {
  boot
  write_config '  - key: COMP
    style: company_managed'
  cmd_config config --child-type COMP=Story --child-type TEAM=Story --json > /dev/null
  # Inject an operator-authored key into the local layer; it must survive the merge.
  local injected
  injected="$(jq -cS '. + {site_alias: "prod"}' <<< "$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")")"
  printf '%s' "$injected" | config_to_yaml > "${JIRA_CONFIG_DIR}/config.local.yml"

  cmd_config config --child-type COMP=Story --child-type TEAM=Story --json > /dev/null
  local json
  json="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.site_alias' <<< "$json")" = "prod" ]
  [ "$(jq -r '(.resolved_ids.COMP.issue_types[] | select(.logical_name=="Story") | .id)' <<< "$json")" = "10102" ]
}

@test "a resolved label containing a double quote survives an incremental run untouched, not re-resolved (013 FR-005)" {
  boot
  # Pre-seed COMP as already resolved from a prior ceremony, with a logical_name
  # containing a double quote — recorded escaped, as the writer would leave it.
  cat > "${JIRA_CONFIG_DIR}/config.local.yml" <<'YAML'
resolved_ids:
  COMP:
    issue_types:
      - logical_name: "Platform \"legacy\""
        id: "10199"
        hierarchy_level: "0"
        subtask: false
YAML
  # Only TEAM is configured this run — COMP is not touched.
  cat > "${JIRA_CONFIG_DIR}/config.yml" <<'EOF'
projects:
  - key: TEAM
    style: team_managed
routing_default: "TEAM"
EOF
  run cmd_config config --child-type TEAM=Story --json
  [ "$status" -eq 0 ]
  local json
  json="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.COMP.issue_types[0].logical_name' <<< "$json")" = 'Platform "legacy"' ]
  [ "$(jq -r '.resolved_ids.COMP.issue_types[0].id' <<< "$json")" = "10199" ]
}

@test "the PowerShell port binds incrementally byte-identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  boot powershell
  local cfg='  - key: COMP
    style: company_managed
  - key: TEAM
    style: team_managed'
  write_config "${cfg}"
  cmd_config config --child-type COMP=Story --child-type TEAM=Story --json > /dev/null
  cp "${JIRA_CONFIG_DIR}/config.local.yml" "${WORK}/local-bash"

  local pswork
  pswork="$(mktemp -d)"
  mkdir -p "${pswork}/.specify/jira"
  cp "${JIRA_CONFIG_DIR}/config.yml" "${pswork}/.specify/jira/config.yml"
  SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" JIRA_CONFIG_DIR="${pswork}/.specify/jira" \
    JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Config.psm1' -Force
      [void](Invoke-JiraConfig -Arguments @('config','--child-type','COMP=Story','--child-type','TEAM=Story','--json'))
    " > /dev/null
  run diff "${WORK}/local-bash" "${pswork}/.specify/jira/config.local.yml"
  [ "$status" -eq 0 ]
  rm -rf "${pswork}"
}
