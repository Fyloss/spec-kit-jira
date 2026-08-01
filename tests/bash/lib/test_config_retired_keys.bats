#!/usr/bin/env bats
# T021/T022/T029/T032a [Phase 3, US4] — `epic_strategy`, `task_strategy` and
# `link_type` are retired (spec FR-030/FR-031). A team configuration
# declaring none of them validates cleanly; one declaring any of them is
# refused with exit 4, one error per occurrence naming the key, the project
# index and the file. The validator's unknown-key check does not reach
# inside `projects[]` (research R10), so this needs an explicit rule — it is
# not a free consequence of deleting the old validation.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

_write_team_config() {
  printf '%s\n' "$@" > "${WORK}/config.yml"
}

@test "a team configuration declaring none of the three retired keys validates cleanly" {
  _write_team_config \
    'projects:' \
    '  - key: COMP' \
    '    style: company_managed' \
    'routing_default: COMP'
  run config_load "${WORK}"
  [ "$status" -eq 0 ]
}

@test "a configuration declaring epic_strategy is refused, naming the key, project index and file" {
  _write_team_config \
    'projects:' \
    '  - key: COMP' \
    '    style: company_managed' \
    '    epic_strategy: per_repo' \
    'routing_default: COMP'
  run config_load "${WORK}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"epic_strategy"* ]]
  [[ "$output" == *"projects[0]"* ]]
  [[ "$output" == *"${WORK}/config.yml"* ]]
}

@test "a configuration declaring all three retired keys is refused with one error per occurrence" {
  _write_team_config \
    'projects:' \
    '  - key: COMP' \
    '    style: company_managed' \
    '    epic_strategy: per_repo' \
    '    task_strategy: linked_story' \
    '    link_type: blocks' \
    'routing_default: COMP'
  run config_load "${WORK}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"epic_strategy"* ]]
  [[ "$output" == *"task_strategy"* ]]
  [[ "$output" == *"link_type"* ]]
}

@test "task_strategy=linked_story with no link_type is refused for declaring task_strategy, not for a missing link_type" {
  _write_team_config \
    'projects:' \
    '  - key: COMP' \
    '    style: company_managed' \
    '    task_strategy: linked_story' \
    'routing_default: COMP'
  run config_load "${WORK}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"task_strategy"* ]]
  [[ "$output" != *"is required when task_strategy"* ]]
}

@test "T032a — grep proves the three keys are gone from scripts, templates, commands and docs, outside the retirement rule" {
  run bash -c "grep -rn 'epic_strategy\\|task_strategy\\|link_type\\|SPEC_KIT_JIRA_EPIC_STRATEGY' '${ROOT}/scripts' '${ROOT}/templates' '${ROOT}/commands' '${ROOT}/README.md' '${ROOT}/INSTALL.md' 2>/dev/null | grep -v 'retired\\|no longer uses'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
