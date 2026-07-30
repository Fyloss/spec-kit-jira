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

@test "config_load rejects a phase_status_map that is not a mapping to status names (exit 4, T074)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
    phase_status_map: "not-a-mapping"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"phase_status_map"* ]]
}

@test "config_load accepts a valid phase_status_map and halted_statuses (T074)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
    halted_statuses:
      - "Blocked"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

@test "config_load rejects a halted_statuses that is neither a list nor a string (exit 4, T074)" {
  cat > "${DIR}/config.yml" <<'YAML'
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
    halted_statuses:
      count: 3
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"halted_statuses"* ]]
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

# =============================================================================
# T008 [003] — The operator disable record (FR-007, FR-029, data-model)
# =============================================================================
#
# `specify extension add` writes `enabled: true` unconditionally on every
# install and upgrade (research R5), so the hook registry cannot carry the
# operator's decision across a reinstall. The decision is recorded HERE instead,
# in the gitignored local binding, which lives outside .specify/extensions/ and
# therefore survives (Constitution V). The registry is never edited to match —
# that would be a write, and FR-022 forbids it.

@test "reading an absent disable record yields the empty set" {
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}

@test "reading a local binding with no hooks key yields the empty set" {
  printf 'site_alias: "prod"\n' > "${DIR}/config.local.yml"
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}

@test "a written disable record round-trips" {
  run config_hooks_disabled_add after_implement "${DIR}"
  [ "$status" -eq 0 ]
  [ "$output" = "recorded" ]
  [ "$(config_hooks_disabled_read "${DIR}")" = '["after_implement"]' ]
}

@test "recording an already-recorded event is unchanged, and never duplicates it" {
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  run config_hooks_disabled_add after_implement "${DIR}"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
  [ "$(config_hooks_disabled_read "${DIR}" | jq 'length')" -eq 1 ]
}

@test "the record is ordered so two runs write byte-identical bytes (FR-003)" {
  config_hooks_disabled_add after_tasks "${DIR}" > /dev/null
  config_hooks_disabled_add after_clarify "${DIR}" > /dev/null
  [ "$(config_hooks_disabled_read "${DIR}")" = '["after_clarify","after_tasks"]' ]
}

@test "an unknown event name is reported and IGNORED rather than failing the run" {
  # The file is human-editable; a typo must not break mirroring (data-model).
  printf 'hooks:\n  disabled:\n    - after_implement\n    - after_typo\n' > "${DIR}/config.local.yml"
  # `run` folds stderr into $output, so read the value through a plain
  # substitution and the report through a separate, stderr-only run.
  [ "$(config_hooks_disabled_read "${DIR}" 2> /dev/null)" = '["after_implement"]' ]
  # The report goes to stderr, naming the offending value.
  run bash -c "source '${LIB_DIR}/config.sh'; config_hooks_disabled_read '${DIR}' 2>&1 >/dev/null"
  [[ "$output" == *"after_typo"* ]]
}

@test "recording an unknown event name is reported and does not fail the run" {
  run config_hooks_disabled_add not_an_event "${DIR}"
  [ "$status" -eq 0 ]
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}

@test "--dry-run predicts the record write without performing it (Constitution XI)" {
  run config_hooks_disabled_add after_plan "${DIR}" true
  [ "$status" -eq 0 ]
  [ "$output" = "recorded" ]
  [ ! -f "${DIR}/config.local.yml" ]
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}

@test "releasing an event clears it from the record (FR-007, FR-029)" {
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  config_hooks_disabled_add after_plan "${DIR}" > /dev/null
  run config_hooks_disabled_remove after_implement "${DIR}"
  [ "$status" -eq 0 ]
  [ "$output" = "released" ]
  [ "$(config_hooks_disabled_read "${DIR}")" = '["after_plan"]' ]
}

@test "releasing an unrecorded event is a no-op reported as such" {
  run config_hooks_disabled_remove after_implement "${DIR}"
  [ "$status" -eq 0 ]
  [ "$output" = "unrecorded" ]
}

@test "--dry-run predicts the release without performing it (Constitution XI)" {
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  run config_hooks_disabled_remove after_implement "${DIR}" true
  [ "$status" -eq 0 ]
  [ "$output" = "released" ]
  [ "$(config_hooks_disabled_read "${DIR}")" = '["after_implement"]' ]
}

@test "the record preserves the operator's site_alias and overrides" {
  printf 'overrides:\n  routing_default: OPS\nsite_alias: "prod"\n' > "${DIR}/config.local.yml"
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  json="$(config_yaml_to_json "${DIR}/config.local.yml")"
  [ "$(jq -r '.site_alias' <<< "$json")" = "prod" ]
  [ "$(jq -r '.overrides.routing_default' <<< "$json")" = "OPS" ]
  [ "$(jq -r '.hooks.disabled[0]' <<< "$json")" = "after_implement" ]
}

@test "schema validation accepts the hooks key in the local binding (T012)" {
  write_valid_team
  printf 'hooks:\n  disabled:\n    - after_implement\n' > "${DIR}/config.local.yml"
  run config_load "${DIR}"
  [ "$status" -eq 0 ]
}

@test "an empty collection survives the YAML round-trip — the writer is a fixed point of the reader" {
  # Regression (003 T010): config_to_yaml emits `key: []` and `key: {}` for empty
  # collections, but the reader returned them as the STRINGS "[]" and "{}". The
  # module header claims the writer is "a FIXED POINT of the reader", and it was
  # not. The hook-registry reader tripped over it: a registry carrying
  # `after_plan: []` — which is what our own serialiser writes — classified as
  # unreadable instead of as an event with no entries.
  printf '%s' '{"a":[],"b":{},"c":"x"}' | config_to_yaml > "${DIR}/rt.yml"
  json="$(config_yaml_to_json "${DIR}/rt.yml")"
  [ "$(jq -r '.a | type' <<< "$json")" = "array" ]
  [ "$(jq -r '.a | length' <<< "$json")" -eq 0 ]
  [ "$(jq -r '.b | type' <<< "$json")" = "object" ]
  [ "$(jq -r '.b | length' <<< "$json")" -eq 0 ]
  [ "$(jq -r '.c' <<< "$json")" = "x" ]
}

@test "a quoted [] is still a STRING — only the bare flow form is a collection" {
  printf 'a: "[]"\nb: "{}"\n' > "${DIR}/q.yml"
  json="$(config_yaml_to_json "${DIR}/q.yml")"
  [ "$(jq -r '.a | type' <<< "$json")" = "string" ]
  [ "$(jq -r '.b | type' <<< "$json")" = "string" ]
}

@test "a block sequence at its parent key's indentation is read (003 T010 regression)" {
  # THE registry-reading bug. PyYAML — which is what `specify extension add`
  # serialises the hook registry with — emits block sequences at the SAME
  # indentation as their parent key, not indented under it. Both forms are valid
  # YAML and the second is PyYAML's default:
  #
  #     hooks:
  #       before_specify:
  #       - extension: jira        <- indent 2, same as the key
  #
  # This reader required a GREATER indent, so it stopped at the key and returned
  # null for its value. The consequence was not subtle: the hook registry of every
  # real installation parsed as `{"installed":null}`, so hook health reported the
  # file unreadable on a perfectly healthy repository.
  printf '%s\n' \
    'installed:' \
    '- jira' \
    'settings:' \
    '  auto_execute_hooks: true' \
    'hooks:' \
    '  before_specify:' \
    '  - extension: jira' \
    '    command: speckit.jira.feature' \
    '    enabled: true' \
    '  after_plan:' \
    '  - extension: jira' \
    '    command: speckit.jira.reconcile' \
    > "${DIR}/pyyaml.yml"
  json="$(config_yaml_to_json "${DIR}/pyyaml.yml")"
  [ "$(jq -r '.installed[0]' <<< "$json")" = "jira" ]
  [ "$(jq -r '.settings.auto_execute_hooks' <<< "$json")" = "true" ]
  [ "$(jq -r '.hooks.before_specify | length' <<< "$json")" -eq 1 ]
  [ "$(jq -r '.hooks.before_specify[0].command' <<< "$json")" = "speckit.jira.feature" ]
  [ "$(jq -r '.hooks.before_specify[0].enabled' <<< "$json")" = "true" ]
  [ "$(jq -r '.hooks.after_plan[0].command' <<< "$json")" = "speckit.jira.reconcile" ]
}

@test "both sequence indentations produce the SAME parse — the forms are equivalent" {
  printf '%s\n' 'hooks:' '  after_plan:' '  - command: a' '  - command: b' > "${DIR}/flat.yml"
  printf '%s\n' 'hooks:' '  after_plan:' '    - command: a' '    - command: b' > "${DIR}/deep.yml"
  [ "$(config_yaml_to_json "${DIR}/flat.yml")" = "$(config_yaml_to_json "${DIR}/deep.yml")" ]
}

@test "an EMPTY local binding is tolerated, not a config error (003 T013)" {
  # Releasing the last held event leaves the local binding with nothing in it, so
  # the writer emits an empty document. Reading that back must be a no-op, not a
  # refusal — otherwise clearing the last disabled hook would break every
  # subsequent run of the ceremony.
  write_valid_team
  printf '\n' > "${DIR}/config.local.yml"
  run config_load "${DIR}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.routing_default' <<< "$output")" = "PROJ" ]
}

@test "releasing the last held event leaves a loadable local binding (003 T012)" {
  write_valid_team
  config_hooks_disabled_add after_implement "${DIR}" > /dev/null
  config_hooks_disabled_remove after_implement "${DIR}" > /dev/null
  run config_load "${DIR}"
  [ "$status" -eq 0 ]
  [ "$(config_hooks_disabled_read "${DIR}")" = "[]" ]
}
