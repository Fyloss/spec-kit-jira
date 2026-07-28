#!/usr/bin/env bats
# T028 [US4] — Config storage layer: two-layer load/merge, schema validation,
# credential-shape rejection (FR-023, exit 4), and the single-source version
# reader (FR-021/022, SC-006).
#
# The config files are YAML but no `yq` is available at runtime (deps are
# curl/jq/git), so lib/config.sh parses the controlled config subset itself.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  PS_LIB="${ROOT}/scripts/powershell/lib"
  EXT_YML="${ROOT}/extension.yml"
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
  expected="$(grep -E '^[[:space:]]+version:' "${EXT_YML}" | head -n1 | sed -E 's/^[[:space:]]+version:[[:space:]]*//')"
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

@test "config_load keeps sibling projects when a local override touches only one" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
  - key: OPS
    style: team_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: PROJ
YAML
  cat > "${DIR}/config.local.yml" <<'YAML'
overrides:
  projects:
    - key: PROJ
      epic_strategy: per_feature
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects | length' <<< "${output}")" -eq 2 ]
  [ "$(jq -r '.projects[0].key' <<< "${output}")" = "PROJ" ]
  [ "$(jq -r '.projects[0].epic_strategy' <<< "${output}")" = "per_feature" ]
  [ "$(jq -r '.projects[0].style' <<< "${output}")" = "company_managed" ]
  [ "$(jq -r '.projects[1].key' <<< "${output}")" = "OPS" ]
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

# --- Adoption section (003 T003) ---------------------------------------------

# Write a team config.yml carrying an `adoption:` section into $DIR.
write_team_with_adoption() {
  cat > "${DIR}/config.yml" <<YAML
projects:
  - key: ADO
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: ADO
adoption:
  enabled: ${1-true}
  label_prefix: "${2-speckit-adopt:}"
YAML
}

@test "config_load accepts an adoption section (003 T003, FR-001)" {
  write_team_with_adoption
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  [[ "$output" != *"unknown top-level key"* ]]
  [ "$(jq -r '.adoption.enabled' <<< "${output}")" = "true" ]
  [ "$(jq -r '.adoption.label_prefix' <<< "${output}")" = "speckit-adopt:" ]
}

@test "config_load treats an absent adoption section as disabled (003 FR-001)" {
  write_valid_team
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
  [ "$(jq -r '.adoption.enabled // false' <<< "${output}")" = "false" ]
}

# --- adoption schema rules (003 T033, FR-002) --------------------------------

@test "config_load refuses an adoption.enabled that is not a boolean (003 T033)" {
  write_team_with_adoption "maybe"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"adoption.enabled"* ]]
}

@test "config_load refuses an empty adoption.label_prefix (003 T033, FR-002)" {
  write_team_with_adoption true ""
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"adoption.label_prefix"* ]]
}

@test "config_load refuses a whitespace-bearing adoption.label_prefix (003 T033, FR-002)" {
  write_team_with_adoption true "speckit adopt:"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"adoption.label_prefix"* ]]
  [[ "$output" == *"whitespace"* ]]
}

@test "config_load refuses an unknown key inside the adoption section (003 T033)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: ADO
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: ADO
adoption:
  enabled: true
  mystery: nope
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"unknown adoption key"* ]]
}

@test "an over-long prefix is refused before any search, exit 4 (003 T033, FR-002)" {
  # The 255-character label limit is checked against the LONGEST suffix the
  # folders in scope imply, which only the engine knows — so the rule lives
  # there and runs before discovery, never after it.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/engine/adoption.sh"
  local long
  long="$(printf 'p%.0s' $(seq 1 250))"
  run adoption_validate_prefix "${long}" 20
  [ "$status" -eq 4 ]
  [[ "$output" == *"255"* ]]
}

@test "the shipped template documents the adoption section (003 T033, FR-002, XVI)" {
  local tpl="${ROOT}/templates/config.yml.template"
  # The section exists, carries both keys, and is self-documented with prose
  # comments explaining the opt-in and the three label forms.
  local json
  json="$(config_yaml_to_json "${tpl}")"
  [ "$(jq -r '.adoption.enabled' <<< "${json}")" = "false" ]
  [ "$(jq -r '.adoption.label_prefix' <<< "${json}")" = "speckit-adopt:" ]
  grep -q '^adoption:' "${tpl}"
  grep -q '^  # Turn adoption on' "${tpl}"
  grep -q 'speckit-adopt:007-invoice-export ' "${tpl}"
  grep -q 'speckit-adopt:007-invoice-export:us2' "${tpl}"
  grep -q 'speckit-adopt:007  ' "${tpl}"
  grep -q 'short form' "${tpl}"
  grep -q 'never guesses' "${tpl}"
  # And the template still loads and validates as a whole.
  cp "${tpl}" "${DIR}/config.yml"
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
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

@test "an apostrophe map key (e.g. a Won't Do status) survives the YAML round-trip" {
  # Regression (002 US1): the writer emits discovered status names verbatim and
  # a name like "Won't Do" is a legal map key; the reader must not stop the
  # mapping there — keys sorted after it (style, style_source) were dropped.
  printf '%s' '{"resolved_ids":{"TEAM":{"statuses":{"Done":"13","Won'\''t Do":"14"},"style":"team_managed","style_source":"api"}}}' \
    | config_to_yaml > "${DIR}/local.yml"
  json="$(config_yaml_to_json "${DIR}/local.yml")"
  [ "$(printf '%s' "${json}" | jq -r '.resolved_ids.TEAM.statuses["Won'\''t Do"]')" = "14" ]
  [ "$(printf '%s' "${json}" | jq -r '.resolved_ids.TEAM.style')" = "team_managed" ]
  [ "$(printf '%s' "${json}" | jq -r '.resolved_ids.TEAM.style_source')" = "api" ]
}
