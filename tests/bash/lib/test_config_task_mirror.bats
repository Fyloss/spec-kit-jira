#!/usr/bin/env bats
# T006/T010 [Phase 2, 022] — the `task_mirror` top-level setting
# (data-model.md §1, contract/task-mirror-config.md §1-2): a per-project
# choice of how the task tier reaches Jira, `subtask` or `checklist`.
# Absence is a third state, not a default — config_task_mirror_for returns
# the empty string for it.

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

_write_team_config() {
  printf '%s\n' "$@" > "${DIR}/config.yml"
}

# --- refusals (contract §2) ---

@test "task_mirror must be a mapping" {
  _write_team_config \
    'projects:' \
    '  - key: CONSUMER' \
    '    style: company_managed' \
    'routing_default: CONSUMER' \
    'task_mirror: checklist'
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"task_mirror must be a mapping"* ]]
}

@test "task_mirror names an undeclared project key, refused" {
  _write_team_config \
    'projects:' \
    '  - key: CONSUMER' \
    '    style: company_managed' \
    'routing_default: CONSUMER' \
    'task_mirror:' \
    '  UNDECLARED: checklist'
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"task_mirror.UNDECLARED"* ]]
  [[ "$output" == *"not declared in projects[]"* ]]
}

@test "task_mirror value outside subtask|checklist is refused, zero writes" {
  _write_team_config \
    'projects:' \
    '  - key: CONSUMER' \
    '    style: company_managed' \
    'routing_default: CONSUMER' \
    'task_mirror:' \
    '  CONSUMER: checklists'
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"task_mirror.CONSUMER"* ]]
  [[ "$output" == *"checklists"* ]]
  [[ "$output" == *"subtask"* ]]
  [[ "$output" == *"checklist"* ]]
}

@test "task_strategy stays refused as retired even with task_mirror declared (FR-006)" {
  _write_team_config \
    'projects:' \
    '  - key: CONSUMER' \
    '    style: company_managed' \
    '    task_strategy: linked_story' \
    'routing_default: CONSUMER' \
    'task_mirror:' \
    '  CONSUMER: checklist'
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"task_strategy"* ]]
}

@test "a valid task_mirror mapping validates cleanly" {
  _write_team_config \
    'projects:' \
    '  - key: CONSUMER' \
    '    style: company_managed' \
    '  - key: PLATFORM' \
    '    style: company_managed' \
    'routing_default: CONSUMER' \
    'task_mirror:' \
    '  CONSUMER: checklist' \
    '  PLATFORM: subtask'
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

# --- resolution (contract §7, six-row table incl. both absent rows) ---

@test "config_task_mirror_for returns checklist when recorded" {
  _write_team_config \
    'projects:' \
    '  - key: CONSUMER' \
    '    style: company_managed' \
    'routing_default: CONSUMER' \
    'task_mirror:' \
    '  CONSUMER: checklist'
  local cfg; JIRA_CONFIG_DIR="${DIR}" cfg="$(config_load)"
  run config_task_mirror_for CONSUMER "${cfg}"
  [ "$status" -eq 0 ]
  [ "$output" = "checklist" ]
}

@test "config_task_mirror_for returns subtask when recorded" {
  _write_team_config \
    'projects:' \
    '  - key: CONSUMER' \
    '    style: company_managed' \
    'routing_default: CONSUMER' \
    'task_mirror:' \
    '  CONSUMER: subtask'
  local cfg; JIRA_CONFIG_DIR="${DIR}" cfg="$(config_load)"
  run config_task_mirror_for CONSUMER "${cfg}"
  [ "$output" = "subtask" ]
}

@test "config_task_mirror_for returns empty for a project with no entry, task_mirror key present" {
  _write_team_config \
    'projects:' \
    '  - key: CONSUMER' \
    '    style: company_managed' \
    '  - key: PLATFORM' \
    '    style: company_managed' \
    'routing_default: CONSUMER' \
    'task_mirror:' \
    '  PLATFORM: subtask'
  local cfg; JIRA_CONFIG_DIR="${DIR}" cfg="$(config_load)"
  run config_task_mirror_for CONSUMER "${cfg}"
  [ "$output" = "" ]
}

@test "config_task_mirror_for returns empty when task_mirror key is entirely absent" {
  _write_team_config \
    'projects:' \
    '  - key: CONSUMER' \
    '    style: company_managed' \
    'routing_default: CONSUMER'
  local cfg; JIRA_CONFIG_DIR="${DIR}" cfg="$(config_load)"
  run config_task_mirror_for CONSUMER "${cfg}"
  [ "$output" = "" ]
}
