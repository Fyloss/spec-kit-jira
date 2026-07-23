#!/usr/bin/env bats
# T028 [US4] — Config storage layer: two-layer load/merge, schema validation,
# credential-shape rejection (FR-023, exit 4), and the single-source version
# reader (FR-021/022, SC-006).
#
# The config files are YAML but no `yq` is available at runtime (deps are
# curl/jq/git), so lib/config.sh parses the controlled config subset itself.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/lib"
  PS_LIB="${ROOT}/.specify/extensions/jira/scripts/powershell/lib"
  EXT_YML="${ROOT}/.specify/extensions/jira/extension.yml"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
  DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${DIR}"
}

# Write a minimal valid team config.yml into $DIR.
write_valid_team() {
  cat > "${DIR}/config.yml" <<'YAML'
# Team config (committable, credential-free).
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
    issue_types:
      Epic: "10001"
      Story: "10002"
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
routing:
  - match:
      folder_prefix: "billing-"
    project: PROJ
routing_default: PROJ
privacy:
  allowlist:
    - support.example.atlassian.net
YAML
}

# --- Version single-source (T032) -------------------------------------------

@test "config_extension_version reads the version field from extension.yml" {
  run config_extension_version
  [ "$status" -eq 0 ]
  # Must equal the literal in extension.yml — the single source of truth.
  expected="$(grep -E '^version:' "${EXT_YML}" | sed -E 's/^version:[[:space:]]*//')"
  [ "$output" = "${expected}" ]
}

@test "config_assert_single_version_source rejects a stray version marker (FR-022)" {
  mkdir -p "${DIR}"
  printf '0.9.9\n' > "${DIR}/VERSION"
  JIRA_CONFIG_DIR="${DIR}" run config_assert_single_version_source
  [ "$status" -eq 4 ]
  [[ "$output" == *"VERSION"* ]]
}

@test "config_assert_single_version_source passes when no stray marker exists" {
  JIRA_CONFIG_DIR="${DIR}" run config_assert_single_version_source
  [ "$status" -eq 0 ]
}

# --- YAML subset parsing -----------------------------------------------------

@test "config_yaml_to_json parses mappings, sequences, and quoted scalars" {
  write_valid_team
  json="$(config_yaml_to_json "${DIR}/config.yml")"
  [ "$(printf '%s' "${json}" | jq -r '.routing_default')" = "PROJ" ]
  [ "$(printf '%s' "${json}" | jq -r '.projects[0].style')" = "company_managed" ]
  [ "$(printf '%s' "${json}" | jq -r '.projects[0].issue_types.Epic')" = "10001" ]
  [ "$(printf '%s' "${json}" | jq -r '.projects[0].priority_map.P2')" = "Medium" ]
  [ "$(printf '%s' "${json}" | jq -r '.routing[0].match.folder_prefix')" = "billing-" ]
  [ "$(printf '%s' "${json}" | jq -r '.privacy.allowlist[0]')" = "support.example.atlassian.net" ]
}

@test "config_yaml_to_json coerces true/false to JSON booleans" {
  cat > "${DIR}/c.yml" <<'YAML'
generation:
  design_section: false
YAML
  json="$(config_yaml_to_json "${DIR}/c.yml")"
  [ "$(printf '%s' "${json}" | jq -r '.generation.design_section')" = "false" ]
  [ "$(printf '%s' "${json}" | jq -r '.generation.design_section | type')" = "boolean" ]
}

# --- Valid load --------------------------------------------------------------

@test "config_load accepts a valid team config (exit 0) and emits merged JSON" {
  write_valid_team
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${output}" | jq -r '.routing_default')" = "PROJ" ]
}

@test "config_load merges config.local overrides over the team config" {
  write_valid_team
  cat > "${DIR}/config.local.yml" <<'YAML'
site_alias: prod
overrides:
  routing_default: OTHER
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${output}" | jq -r '.routing_default')" = "OTHER" ]
}

@test "config_load fails when config.yml is absent (exit 4)" {
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
}

# --- Credential-shape rejection (FR-023, exit 4) -----------------------------

@test "config_load rejects an ATATT token shape in the team layer (exit 4)" {
  write_valid_team
  cat >> "${DIR}/config.yml" <<'YAML'
site_url: ATATT3xFfGF0secrettoken
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"credential"* ]]
  # The secret value itself is NEVER echoed (NFR-3).
  [[ "$output" != *"ATATT3xFfGF0secrettoken"* ]]
}

@test "config_load rejects a real *.atlassian.net host as a coordinate (exit 4)" {
  write_valid_team
  cat > "${DIR}/config.local.yml" <<'YAML'
overrides:
  site: acme.atlassian.net
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"credential"* ]]
}

@test "config_load rejects an email address shape (exit 4)" {
  write_valid_team
  cat >> "${DIR}/config.yml" <<'YAML'
owner: someone@example.com
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
}

@test "config_load does NOT scan privacy.allowlist for atlassian hosts (FR-053)" {
  # support.example.atlassian.net lives under privacy.allowlist in the valid
  # fixture; the allowlist is exempt from credential-shape scanning.
  write_valid_team
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

# --- Schema validation -------------------------------------------------------

@test "config_load rejects a missing routing_default (exit 4)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"routing_default"* ]]
}

@test "config_load rejects an invalid project style enum (exit 4)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: bespoke
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"style"* ]]
}

@test "config_load requires link_type when task_strategy is linked_story (exit 4)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: linked_story
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"link_type"* ]]
}

@test "config_load rejects an unknown top-level key (exit 4)" {
  write_valid_team
  cat >> "${DIR}/config.yml" <<'YAML'
mystery: value
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"unknown"* ]]
}

# --- Cross-port parity -------------------------------------------------------

@test "config_yaml_to_json is byte-identical across ports" {
  write_valid_team
  bash_json="$(config_yaml_to_json "${DIR}/config.yml")"
  ps_json="$(pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Config.psm1' -Force
    [Console]::Out.Write((ConvertFrom-JiraConfigYaml -Path '${DIR}/config.yml'))
  ")"
  [ "$bash_json" = "$ps_json" ]
}

@test "config_extension_version is byte-identical across ports" {
  bash_v="$(config_extension_version)"
  ps_v="$(pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Config.psm1' -Force
    [Console]::Out.Write((Get-JiraExtensionVersion))
  ")"
  [ "$bash_v" = "$ps_v" ]
}
