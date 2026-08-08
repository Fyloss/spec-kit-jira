#!/usr/bin/env bats
# T093 [US5] — wiring the completion pass (contract §6) into cmd_reconcile: a
# checked task transitions its already-recognised sub-task to whichever
# status the project classifies as done, counted on its own summary line —
# never folded into created/updated (research R5). An unchecked task whose
# sub-task a person completed in Jira is reported by key and never moved
# backward unless the run is authorised with --on-drift=proceed (FR-032).
# Completion is never read back into tasks.md (FR-033).

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
# It offers one done-category destination (31) and one not-done destination
# (21), so both the forward and the authorised-backward path are exercised
# without a second mock config.
_mock_configs() {
  mock_write_config '{"projects":{"TASKP":"t"},"transitions":{"TASKP-3":[
    {"id":"31","name":"Terminé","to":{"statusCategory":{"key":"done"}},"fields":{}},
    {"id":"21","name":"À faire","to":{"statusCategory":{"key":"new"}},"fields":{}}
  ]}}'
}

@test "a task checked off transitions its sub-task, counted on its own summary line" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  sed -i.bak 's/^- \[ \] T002 /- [x] T002 /' "${TASKS}"
  rm -f "${TASKS}.bak"
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.transitioned' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.tasks.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 0 ]
  [ "$(grep -c '^POST /rest/api/3/issue/TASKP-3/transitions$' "${MOCK_CALLLOG}")" -eq 1 ]
  [ "$(jq -r '.actions[] | select(.url=="/rest/api/3/issue/TASKP-3/transitions") | .body.transition.id' <<< "$output")" = "31" ]
}

@test "a re-run after Jira already reflects the done-category status issues zero reads and zero transitions (FR-031)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  sed -i.bak 's/^- \[ \] T002 /- [x] T002 /' "${TASKS}"
  rm -f "${TASKS}.bak"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/TASKP-3" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"Terminé","statusCategory":{"key":"done"}}}}' > /dev/null

  : > "${MOCK_CALLLOG}"
  # --force: this run's local inputs are unchanged since the prior run, so
  # without --force the state short-circuit (021) would skip Jira entirely —
  # this test's point is that a genuine reconcile reads Jira and still finds
  # zero work, not that the short-circuit fires.
  run cmd_reconcile reconcile "${SPEC}" --json --force
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.transitioned' <<< "$output")" -eq 0 ]
  [ "$(grep -c '/transitions$' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "an unchecked task whose sub-task a person completed reports the divergence by key and never moves it backward without authorisation (FR-032)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/TASKP-3" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"Terminé","statusCategory":{"key":"done"}}}}' > /dev/null

  : > "${MOCK_CALLLOG}"
  # --force: same rationale as FR-031's re-run above — this test exercises
  # the divergence-reporting logic itself, not the state short-circuit.
  run cmd_reconcile reconcile "${SPEC}" --json --force
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.transitioned' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings | join(" ")' <<< "$output")" == *"TASKP-3"* ]]
  [ "$(grep -c '/transitions$' "${MOCK_CALLLOG}")" -eq 0 ]
  grep -q '^- \[ \] T002 ' "${TASKS}"
}

@test "a sub-task completed in Jira never checks its task off in tasks.md, byte-for-byte (T086, FR-033)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  local before; before="$(cat "${TASKS}")"

  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/TASKP-3" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"Terminé","statusCategory":{"key":"done"}}}}' > /dev/null

  # --force: without it this run's unchanged local inputs would trigger the
  # state short-circuit (021), which trivially never writes tasks.md for a
  # reason unrelated to FR-033 — force a genuine reconcile so the assertion
  # below actually exercises the "never checks off" logic.
  run cmd_reconcile reconcile "${SPEC}" --json --force
  [ "$status" -eq 0 ]
  [ "$(cat "${TASKS}")" = "${before}" ]
}

@test "a task checked before its sub-task ever existed is created and transitioned in the same run (Edge Cases, T084)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  sed -i.bak 's/^- \[ \] T002 /- [x] T002 /' "${TASKS}"
  rm -f "${TASKS}.bak"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.tasks.transitioned' <<< "$output")" -eq 1 ]
  [ "$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")" -ge 1 ]
  [ "$(grep -c '^POST /rest/api/3/issue/TASKP-3/transitions$' "${MOCK_CALLLOG}")" -eq 1 ]
  [ "$(jq -r '.actions[] | select(.url=="/rest/api/3/issue/TASKP-3/transitions") | .body.transition.id' <<< "$output")" = "31" ]
  grep -q 'ticket=TASKP-3' "${TASKS}"
}

@test "under --on-drift=proceed the diverged sub-task is pulled backward and the divergence is still reported (FR-032)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/TASKP-3" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"Terminé","statusCategory":{"key":"done"}}}}' > /dev/null

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json --on-drift=proceed
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.transitioned' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.actions[] | select(.url=="/rest/api/3/issue/TASKP-3/transitions") | .body.transition.id' <<< "$output")" = "21" ]
  [[ "$(jq -r '.warnings | join(" ")' <<< "$output")" == *"TASKP-3"* ]]
}
