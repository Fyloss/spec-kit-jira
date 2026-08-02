#!/usr/bin/env bats
# T006/T007/T029/T030/T032/T038 [Phase 4, US1] — The ceremony's role mapping
# (010, contracts/role-mapping.md): declared -> operator -> derived, over all
# three roles (specification, story, task) in ONE pass. The consumer fixture
# (two issue types at hierarchy level 1, thirteen at level 0) previously
# refused with `parent-level-ambiguous` before the story tier was ever
# examined — the "ordering trap" this feature repairs (research R1).

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
  # $1 = extra indented lines under the project entry (may be empty)
  {
    printf 'projects:\n'
    printf '  - key: CONSUMER\n'
    [[ -n "${1:-}" ]] && printf '%s\n' "$1"
    printf 'routing_default: CONSUMER\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
}

boot() {
  mock_start "${MOCK}/configs/consumer-hierarchy.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "T006/T007 — an undeclared, unanswered mapping reports BOTH ambiguous tiers in one run" {
  _write_config ""
  boot

  run cmd_config config --json
  [ "$status" -eq 4 ]
  # The specification tier (level 1: Epic, Service Category)...
  [[ "$output" == *"the specification level"* ]]
  [[ "$output" == *"Epic"* ]]
  [[ "$output" == *"Service Category"* ]]
  # ...AND the story tier (level 0: thirteen candidates) — BOTH reported
  # together, not just the first one encountered (the ordering trap, R1).
  [[ "$output" == *"the story level"* ]]
  [[ "$output" == *"Story"* ]]
  [[ "$output" == *"Defect"* ]]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "T029 — a declared hierarchy resolves both tiers with source: declared" {
  _write_config '    hierarchy:
      specification: Epic
      story: Story'
  boot

  run cmd_config config --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.specification.logical_name' <<< "${localj}")" = "Epic" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.specification.source' <<< "${localj}")" = "declared" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.story.logical_name' <<< "${localj}")" = "Story" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.story.source' <<< "${localj}")" = "declared" ]
  # Dual-written for the reconcile path (research R5, unchanged this release).
  [ "$(jq -r '.resolved_ids.CONSUMER.child_type.logical_name' <<< "${localj}")" = "Story" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.parent_type.logical_name' <<< "${localj}")" = "Epic" ]
}

@test "T030 — an operator answer (--issue-type) resolves both tiers with source: operator" {
  _write_config ""
  boot

  run cmd_config config --issue-type CONSUMER=specification=Epic --issue-type CONSUMER=story=Story --json
  [ "$status" -eq 0 ]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.specification.logical_name' <<< "${localj}")" = "Epic" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.specification.source' <<< "${localj}")" = "operator" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.story.logical_name' <<< "${localj}")" = "Story" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.story.source' <<< "${localj}")" = "operator" ]
}

@test "T032 — declaring an unknown issue type name refuses, naming the offered candidates" {
  _write_config '    hierarchy:
      specification: NoSuchType
      story: Story'
  boot

  run cmd_config config --json
  [ "$status" -eq 4 ]
  [[ "$output" == *'"NoSuchType"'* ]]
  [[ "$output" == *"which this project does not offer at that tier"* ]]
  [[ "$output" == *"Epic"* ]]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "T032 — declaring a sub-task type for specification refuses as a subtask misuse, not an unknown type" {
  _write_config '    hierarchy:
      specification: "Sous-tâche"
      story: Story'
  boot

  run cmd_config config --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"which is a sub-task type in this project"* ]]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "T038 — the operator's declared config.yml round-trips through --json unresolved_roles when only one tier is declared" {
  _write_config '    hierarchy:
      specification: Epic'
  boot

  run cmd_config config --json
  [ "$status" -eq 4 ]
  # The unresolved story tier surfaces as structured JSON (contract §6.2) even
  # though specification resolved cleanly from config.yml.
  [[ "$output" == *'"unresolved_roles"'* ]]
  [[ "$output" == *'"role":"story"'* ]]
}

@test "T064/T065 — a declared task role validates, persists, reports §7.4, and creates zero sub-tasks" {
  _write_config '    hierarchy:
      specification: Epic
      story: Story
      task: "Sous-tâche"'
  boot

  run cmd_config config --json
  [ "$status" -eq 0 ]
  # §7.4 — recorded, not mirrored yet, never a warning, exit still 0.
  [[ "$output" == *'task is recorded as "Sous-tâche" but is not mirrored yet'* ]]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.task.logical_name' <<< "${localj}")" = "Sous-tâche" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.task.source' <<< "${localj}")" = "declared" ]
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.task.subtask' <<< "${localj}")" = "true" ]
}

@test "T064 — an undeclared task role produces no roles.task, no note, and no refusal" {
  _write_config '    hierarchy:
      specification: Epic
      story: Story'
  boot

  run cmd_config config --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"task is recorded as"* ]]
  local localj
  localj="$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "$(jq -r '.resolved_ids.CONSUMER.roles | has("task")' <<< "${localj}")" = "false" ]
}

@test "T089 — the unresolved-role refusal never reads stdin; it cannot hang the hook or --json paths" {
  _write_config ""
  boot

  # A closed stdin: any attempted read fails immediately rather than blocking.
  # If the ceremony ever tried to prompt, this run would fail or hang instead
  # of completing with its ordinary exit code (FR-008, research R7).
  run cmd_config config --json <&-
  [ "$status" -eq 4 ]
  [[ "$output" == *'"unresolved_roles"'* ]]
}
