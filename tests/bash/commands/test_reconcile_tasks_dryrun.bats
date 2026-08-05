#!/usr/bin/env bats
# T035a [US1] — FR-024's dry-run preview claims for the task tier: every
# sub-task it would create or update names its parent story, its summary and
# its description, and the run writes nothing. Uses repo-with-tasks (three
# stories) rather than the single-story repo-with-task-tier fixture, because
# naming the RIGHT parent story only becomes a real claim once more than one
# story exists in the same run — with one story, the fields.parent.key
# placeholder ("<resolved at apply time>") would look correct by accident.
#
# FR-024's "every transition it would perform" clause is deliberately not
# covered here: neither port resolves a task-tier transition yet (tasks.md
# Phase 8 header note) — that capability, and its dry-run preview, belongs to
# US5 (T081-T088), not to this US1-scoped file.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-tasks"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-widget/spec.md"
  TASKS="${WORK}/specs/001-widget/tasks.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222 3333333333333333 4444444444444444 5555555555555555 6666666666666666 7777777777777777 8888888888888888 9999999999999999 bbbbbbbbbbbbbbbb cccccccccccccccc dddddddddddddddd eeeeeeeeeeeeeeee ffffffffffffffff 0000000000000000"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-widget"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
}

teardown() {
  mock_stop
}

_mock_configs() {
  mock_write_config '{"projects":{"TASKS":"company"}}'
}

@test "a --dry-run preview names the parent story of every sub-task it would create, across more than one story" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local before; before="$(cat "${TASKS}")"
  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.actions[] | select(.role=="story")] | length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '[.actions[] | select(.role=="task")] | length' <<< "$output")" -eq 6 ]

  local by_story
  by_story="$(jq -c '
    ([.actions[] | select(.role=="story")] | map({(.local_id): .body.fields.summary}) | add) as $stories
    | [.actions[] | select(.role=="task") | {task: .body.fields.summary, story: $stories[.parent_local_id]}]
  ' <<< "$output")"
  [ "$(jq -r --arg s "Implement the widget creation endpoint" '[.[] | select(.task==$s)][0].story' <<< "${by_story}")" = "Create a widget" ]
  [ "$(jq -r --arg s "Add validation" '[.[] | select(.task | contains($s))][0].story' <<< "${by_story}")" = "Create a widget" ]
  [ "$(jq -r --arg s "Implement the widget rename endpoint" '[.[] | select(.task==$s)][0].story' <<< "${by_story}")" = "Rename a widget" ]
  [ "$(jq -r --arg s "Add rename validation" '[.[] | select(.task==$s)][0].story' <<< "${by_story}")" = "Rename a widget" ]
  [ "$(jq -r --arg s "Implement the widget delete endpoint" '[.[] | select(.task==$s)][0].story' <<< "${by_story}")" = "Delete a widget" ]

  local after; after="$(cat "${TASKS}")"
  [ "${before}" = "${after}" ]
  # 017's duplicate probe is a read-only GET fired in the planning pass, so a
  # --dry-run over a specification with no parent marker legitimately reaches
  # the double. The dry-run invariant is zero WRITES, not zero requests.
  run mock_calls
  [ "$(grep -cE '^(POST|PUT|DELETE) ' <<< "$output")" -eq 0 ]
}

@test "a --dry-run preview shows the summary and description of a created sub-task" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  local action
  action="$(jq -c '[.actions[] | select(.role=="task" and (.body.fields.summary | contains("Implement the widget creation endpoint")))][0]' <<< "$output")"
  [ "$(jq -r '.body.fields.summary' <<< "${action}")" = "Implement the widget creation endpoint" ]
  local desc
  desc="$(jq -c '.body.fields.description' <<< "${action}")"
  [[ "${desc}" == *"Implement the widget creation endpoint"* ]]
  [[ "${desc}" == *"Identifier: T003"* ]]
  [[ "${desc}" == *"Attribution: User Story 1"* ]]
}

@test "a --dry-run preview shows an update it would perform, with its summary and description" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  sed -i.bak 's/^- \[ \] T003 \[US1\] Implement the widget creation endpoint$/- [ ] T003 [US1] Implement the widget creation endpoint with strict validation/' "${TASKS}"
  rm -f "${TASKS}.bak"
  local before; before="$(cat "${TASKS}")"
  : > "${MOCK_CALLLOG}"

  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  local action
  action="$(jq -c '[.actions[] | select(.role=="task" and .method=="PUT")][0]' <<< "$output")"
  [[ "$(jq -r '.url' <<< "${action}")" == *"TASKS-5"* ]]
  [[ "$(jq -r '.body.fields.summary' <<< "${action}")" == *"strict validation"* ]]
  [[ "$(jq -c '.body.fields.description' <<< "${action}")" == *"strict validation"* ]]

  local after; after="$(cat "${TASKS}")"
  [ "${before}" = "${after}" ]
  # Dry-run's own recognition pass GETs each already-created ticket to detect
  # drift (that is how it knows T003 changed) — only a POST/PUT is a write.
  run mock_calls
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    [[ "${line}" == GET\ * ]]
  done <<< "$output"
}

@test "the dry-run action set for the task tier is identical to the real run's, over the same starting state (Constitution XI)" {
  # Two separate cmd_reconcile calls in the same bats process each consume
  # SPEC_KIT_JIRA_ID_SOURCE from wherever the last call left off, so raw
  # local_id/parent_local_id values are a positional artifact, not part of
  # the action set's meaning — the comparison resolves each task's
  # parent_local_id to its own run's story SUMMARY instead, which is exactly
  # what FR-024's "parent story" claim is about.
  local by_story_jq='([.actions[] | select(.role=="story")] | map({(.local_id): .body.fields.summary}) | add) as $stories | [.actions[] | select(.role=="task") | {summary: .body.fields.summary, issuetype: .body.fields.issuetype.id, story: $stories[.parent_local_id]}] | sort_by(.summary)'

  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  local dry_tasks dry_count
  dry_tasks="$(jq -cS "${by_story_jq}" <<< "$output")"
  dry_count="$(jq -r '.counts.tasks.created' <<< "$output")"

  local work2="${BATS_TEST_TMPDIR}/repo-real"
  cp -R "${FIXTURE}" "${work2}"
  export JIRA_CONFIG_DIR="${work2}/.specify/jira"
  run cmd_reconcile reconcile "${work2}/specs/001-widget/spec.md" --json
  [ "$status" -eq 0 ]
  local real_tasks real_count
  real_tasks="$(jq -cS "${by_story_jq}" <<< "$output")"
  real_count="$(jq -r '.counts.tasks.created' <<< "$output")"

  [ "${dry_count}" -eq "${real_count}" ]
  [ "${dry_tasks}" = "${real_tasks}" ]
}

@test "the PowerShell port names the same parent story for every created sub-task (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}" powershell
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local ps_out
  ps_out="$(SPEC_KIT_JIRA_REPO="acme/app" SPEC_KIT_JIRA_SPEC_SLUG="001-widget" SPEC_KIT_JIRA_ID_SOURCE="${SPEC_KIT_JIRA_ID_SOURCE}" \
    JIRA_CONFIG_DIR="${JIRA_CONFIG_DIR}" JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    SPEC_KIT_JIRA_BASE_URL="${SPEC_KIT_JIRA_BASE_URL}" \
    pwsh -NoProfile -Command "
      Import-Module '${ROOT}/scripts/powershell/commands/Reconcile.psm1' -Force
      [void](Invoke-JiraReconcile -Arguments @('reconcile','${SPEC}','--dry-run','--json'))
    " 2>/dev/null)"

  local by_story
  by_story="$(jq -c '
    ([.actions[] | select(.role=="story")] | map({(.local_id): .body.fields.summary}) | add) as $stories
    | [.actions[] | select(.role=="task") | {task: .body.fields.summary, story: $stories[.parent_local_id]}]
  ' <<< "${ps_out}")"
  [ "$(jq -r --arg s "Implement the widget delete endpoint" '[.[] | select(.task==$s)][0].story' <<< "${by_story}")" = "Delete a widget" ]
}
