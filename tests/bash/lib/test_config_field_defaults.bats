#!/usr/bin/env bats
# T013 [Phase 2, 011] — reading and validating `field_defaults` (research R1,
# data-model.md §1, contract §2). `field_defaults` is a top-level key,
# project -> issue-type -> label -> value, with a per-project `ask` switch.
# Schema validation runs on every read, whoever wrote the entry (contract
# §2.6): a hand-written entry is checked exactly like a ceremony-written one.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
  DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${DIR}"
}

write_valid_team_with_field_defaults() {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: CONSUMER
    style: company_managed
routing_default: CONSUMER
field_defaults:
  CONSUMER:
    ask: true
    Epic:
      Business Owner: "Platform Team"
      Program Increment: "PI-2026-Q3"
YAML
}

@test "the field_defaults key parses without error" {
  write_valid_team_with_field_defaults
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  [ "$(jq -r '.field_defaults.CONSUMER.Epic."Business Owner"' <<< "$output")" = "Platform Team" ]
}

@test "config_field_defaults_for reads one project's map, ask included" {
  write_valid_team_with_field_defaults
  local cfg; JIRA_CONFIG_DIR="${DIR}" cfg="$(config_load)"
  run config_field_defaults_for CONSUMER "${cfg}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ask' <<< "$output")" = "true" ]
  [ "$(jq -r '.Epic."Business Owner"' <<< "$output")" = "Platform Team" ]
}

@test "config_field_defaults_for defaults ask to true when absent" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: CONSUMER
    style: company_managed
routing_default: CONSUMER
field_defaults:
  CONSUMER:
    Epic:
      Business Owner: "Platform Team"
YAML
  local cfg; JIRA_CONFIG_DIR="${DIR}" cfg="$(config_load)"
  run config_field_defaults_for CONSUMER "${cfg}"
  [ "$(jq -r '.ask' <<< "$output")" = "true" ]
}

@test "config_field_defaults_for returns an empty map for a project with no field_defaults entry" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: CONSUMER
    style: company_managed
routing_default: CONSUMER
YAML
  local cfg; JIRA_CONFIG_DIR="${DIR}" cfg="$(config_load)"
  run config_field_defaults_for CONSUMER "${cfg}"
  [ "$(jq -r '.ask' <<< "$output")" = "true" ]
  [ "$(jq -r 'keys | length' <<< "$output")" -eq 1 ]
}

@test "an undeclared project key under field_defaults is refused, zero writes (exit 4)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: CONSUMER
    style: company_managed
routing_default: CONSUMER
field_defaults:
  UNDECLARED:
    Epic:
      Team: "Payments"
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"field_defaults.UNDECLARED"* ]]
  [[ "$output" == *"not declared"* ]]
}

@test "an empty default value is refused, zero writes (exit 4, FR-008)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: CONSUMER
    style: company_managed
routing_default: CONSUMER
field_defaults:
  CONSUMER:
    Epic:
      Team: ""
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"field_defaults.CONSUMER.Epic.Team"* ]]
}

@test "a non-scalar default value is refused, zero writes (exit 4)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: CONSUMER
    style: company_managed
routing_default: CONSUMER
field_defaults:
  CONSUMER:
    Epic:
      Team:
        - a
        - b
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"field_defaults.CONSUMER.Epic.Team"* ]]
}

@test "T042 — config_field_defaults_yaml renders the whole map, keys sorted at every level" {
  run config_field_defaults_yaml '{"FD":{"ask":true,"Epic":{"Program Increment":"PI-2026-Q3","Business Owner":"Platform Team"}}}'
  [ "$status" -eq 0 ]
  local expected
  expected='"field_defaults":
  "FD":
    "Epic":
      "Business Owner": "Platform Team"
      "Program Increment": "PI-2026-Q3"
    "ask": true'
  [ "$output" = "${expected}" ]
}

@test "T042 — config_field_defaults_yaml renders an empty map" {
  run config_field_defaults_yaml '{}'
  [ "$status" -eq 0 ]
  [ "$output" = '"field_defaults": {}' ]
}

@test "T042 — config_field_defaults_yaml defaults to an empty map when called with no argument" {
  run config_field_defaults_yaml
  [ "$status" -eq 0 ]
  [ "$output" = '"field_defaults": {}' ]
}

@test "T042 — the field_defaults YAML text is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local map='{"FD":{"ask":false,"Epic":{"Business Owner":"Platform Team"},"Story":{"Team":"Payments"}}}'
  bash_out="$(config_field_defaults_yaml "${map}")"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${ROOT}/scripts/powershell/lib/Config.psm1' -Force; [Console]::Out.Write((Get-JiraFieldDefaultsYaml -MapJson '${map}'))")"
  [ "$bash_out" = "$ps_out" ]
}

@test "a credential-shaped field_defaults value is STILL caught by the existing scan — NOT exempted like privacy.* (research R7, Principle IV)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: CONSUMER
    style: company_managed
routing_default: CONSUMER
field_defaults:
  CONSUMER:
    Epic:
      Owner: "person@example.com"
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"credential"* ]]
  [[ "$output" != *"person@example.com"* ]]
}
