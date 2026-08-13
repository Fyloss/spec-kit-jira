#!/usr/bin/env bats
# T146/T148/T150 [Phase 11, US9] — budgets B1-B3 (contract transition-
# resolution.md §1/§2, 024 spawn-budget.md §4): a ticket failing any of D1-D5
# never costs an availability read (B1); the round-trip count never grows
# one-for-one with a large due set under branch C (B2); the external-process
# count is unchanged when the due set doubles, measured in a run separate
# from any timing run (B3, research R4).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-bound-story-due"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-declared-mapping/spec.md"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-declared-mapping"
}

teardown() {
  mock_stop
}

@test "B1 (D1) -- no hook event: zero availability requests" {
  mock_start "${MOCK}/configs/comp-bound-story-due-seed.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(grep -c 'transitions' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "B1 (D4) -- already at the declared step: zero availability requests" {
  mock_start "${MOCK}/configs/comp-bound-story-due-seed.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(grep -c 'transitions' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "B1 (D5, Flagged) -- an impediment-marked ticket costs zero availability requests" {
  mock_start "${MOCK}/configs/comp-bound-story-due-seed.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"Flagged":[{"value":"Impediment"}]}}' > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(grep -c 'transitions' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "B2 -- under branch C, requests grow with the DUE set, never with unqualifying tickets outside it" {
  # 60 stories are all due; the round-trip count is exactly 60 (one GET per
  # due ticket, branch C's own budget -- research R1) never 61 (the parent,
  # which is NOT due this event) and never some multiple of 60.
  local fixture60="${ROOT}/tests/conformance/fixtures/repo-with-sixty-stories-due"
  local work60="${BATS_TEST_TMPDIR}/repo60"
  cp -R "${fixture60}" "${work60}"
  local spec60="${work60}/specs/001-widget/spec.md"
  export JIRA_CONFIG_DIR="${work60}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-widget"
  mock_start "${MOCK}/configs/tasks-sixty-transitions.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${spec60}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.transitioned' <<< "$output")" -eq 60 ]
  [ "$(grep -c '^GET .*/transitions?expand=' "${MOCK_CALLLOG}")" -eq 60 ]
}

@test "B3 -- the external-process count is unchanged when the due set doubles (024 spawn-budget §4, C4.2)" {
  # A SEPARATE run from any timing run (research R4): counting the shim
  # itself costs a process call per invocation, so this test never asserts
  # duration, only the shimmed-tool tally, across two SEPARATE reconcile
  # invocations of differently-sized due sets.
  local helpers="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${helpers}/spawn_count.bash"
  local shim_dir="${BATS_TMPDIR}/aw_transitions_budget_shims_$$"
  local count_file_30="${BATS_TMPDIR}/aw_transitions_budget_count30_$$.log"
  local count_file_60="${BATS_TMPDIR}/aw_transitions_budget_count60_$$.log"

  local fixture60="${ROOT}/tests/conformance/fixtures/repo-with-sixty-stories-due"

  # 30-ticket due set: a fresh copy of the same fixture with the LAST 30
  # story markers stripped from spec.md, so half the due set is absent.
  local work30="${BATS_TEST_TMPDIR}/repo30"
  cp -R "${fixture60}" "${work30}"
  local spec30="${work30}/specs/001-widget/spec.md"
  # Keep the parent + the first 30 stories only (TASKS-2..TASKS-31); drop
  # every "### User Story" block for stories 31-60.
  awk '
    /^### User Story 31 /{stop=1}
    !stop {print}
  ' "${spec30}" > "${spec30}.tmp" && mv "${spec30}.tmp" "${spec30}"

  export JIRA_CONFIG_DIR="${work30}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-widget"
  mock_start "${MOCK}/configs/tasks-sixty-transitions.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  # The counting shim's "real curl" MUST resolve to the mock's own curl
  # shim (mock_start's own PATH-prepended fake), never the system's —
  # built only now, after mock_start, or every request in this run
  # silently escapes to the real network instead of the mock.
  helper_spawn_count_setup "${shim_dir}" "${count_file_30}"

  PATH="${shim_dir}:${PATH}" run cmd_reconcile reconcile "${spec30}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.transitioned' <<< "$output")" -eq 30 ]
  mock_stop

  # 60-ticket due set: the SAME fixture, unmodified, a fresh mock instance.
  local work60="${BATS_TEST_TMPDIR}/repo60b"
  cp -R "${fixture60}" "${work60}"
  local spec60="${work60}/specs/001-widget/spec.md"
  export JIRA_CONFIG_DIR="${work60}/.specify/jira"
  mock_start "${MOCK}/configs/tasks-sixty-transitions.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  helper_spawn_count_setup "${shim_dir}" "${count_file_60}"

  PATH="${shim_dir}:${PATH}" run cmd_reconcile reconcile "${spec60}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.transitioned' <<< "$output")" -eq 60 ]

  local c30 c60
  c30="$(helper_spawn_count_total "${count_file_30}")"
  c60="$(helper_spawn_count_total "${count_file_60}")"
  # Neither zero (the run genuinely shells out) nor doubled: growth stays
  # sub-linear in the due-set size (decode-once shape, T155).
  [ "${c30}" -gt 0 ]
  [ "${c60}" -gt 0 ]
  [ "${c60}" -lt $((c30 * 2)) ]

  rm -rf "${shim_dir}" "${count_file_30}" "${count_file_60}"
}
