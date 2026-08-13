#!/usr/bin/env bats
# T084 [Phase 6, US4] — isolation rules I4/I7 (contract role-lifecycle-
# config.md §5): a `task` mapping advances unchecked sub-tasks whose task
# is unchecked in `subtask` mode, matched by destination NAME (the same
# resolution engine the story tier uses, contract transition-resolution.md
# §1-§4) — a genuinely new due set, disjoint from 012's done-driven
# completion pass by construction (I7: a CHECKED task always outranks the
# mapping, since the two due sets partition on the `done` bit).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-task-tier"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-feature/spec.md"
  TASKS="${WORK}/specs/001-feature/tasks.md"

  # A per-role mapping declaring `task` alone: after_plan -> "In Progress".
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: TASKP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      task:
        after_specify: "To Do"
        after_plan: "In Progress"
routing_default: TASKP
YAML

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
}

teardown() {
  mock_stop
}

# TASKP-3 is the sub-task a fresh run mirrors T002 as (repo-with-task-tier).
# It offers one ungated name-based move to "In Progress" — the task role's
# own declared step — alongside the unrelated category-based moves 012's
# completion pass already exercises.
_mock_configs() {
  mock_write_config '{"projects":{"TASKP":"t"},"transitions":{"TASKP-3":[
    {"id":"41","name":"Start","to":{"name":"In Progress"},"fields":{}},
    {"id":"31","name":"Terminé","to":{"statusCategory":{"key":"done"}},"fields":{}}
  ]}}'
}

@test "T084 -- an unchecked task with a declared step moves the sub-task by name, counted with the task tier's own tally" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(jq -e '.actions[] | select(.url | endswith("/rest/api/3/issue/TASKP-3/transitions")) | .body.transition.id' <<< "$output")" = '"41"' ]
  [ "$(jq -r '.counts.tasks.transitioned' <<< "$output")" -eq 1 ]
  # Never folded into the specification/story tier's own counter.
  [ "$(jq -r '.counts.transitioned // 0' <<< "$output")" -eq 0 ]
}

@test "T084 -- I7: a CHECKED task outranks the mapping -- the completion pass runs, the mapping's own due set does not" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  sed -i.bak 's/^- \[ \] T002 /- [x] T002 /' "${TASKS}"
  rm -f "${TASKS}.bak"

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  # The completion pass's own forward move (done-category, id 31) fires...
  [ "$(jq -e '.actions[] | select(.url | endswith("/rest/api/3/issue/TASKP-3/transitions")) | .body.transition.id' <<< "$output")" = '"31"' ]
  # ... and the role-mapping's own move (id 41, "In Progress") never does:
  # exactly one transition POST was ever issued for TASKP-3 (the GET
  # available-transitions read is discovery_task_transition's own, a
  # DIFFERENT read than the role mapping's transitions_load/get pair, and
  # the only one this scenario should ever cost).
  [ "$(grep -c '^POST.*TASKP-3/transitions$' "${MOCK_CALLLOG}")" -eq 1 ]
}

@test "T084 -- a task already at its declared step asks the tracker nothing about it" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/TASKP-3" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}}' > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(grep -c 'TASKP-3/transitions' "${MOCK_CALLLOG}")" -eq 0 ]
  [ "$(jq -r '.counts.tasks.transitioned // 0' <<< "$output")" -eq 0 ]
}
