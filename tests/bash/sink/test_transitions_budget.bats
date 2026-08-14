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

@test "B3 -- transitions_load's own jq spawn count is constant, never one-for-one with the due set (024 spawn-budget §4, C4.2, T155)" {
  # Isolated from the network entirely (mirroring test_plan_apply_spawn_budget.bats's
  # own convention of testing the pure function directly): jira_request is
  # stubbed to return a canned response instantly, so the ONLY jq spawns
  # counted here are transitions_load's OWN parsing step, decoupled from
  # jira_request's own per-call overhead (credential/header building, which
  # scales with N regardless of this feature and is out of T155's scope).
  local helpers="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${helpers}/spawn_count.bash"
  local shim_dir="${BATS_TMPDIR}/aw_transitions_load_shims_$$"
  local count_file_30="${BATS_TMPDIR}/aw_transitions_load_count30_$$.log"
  local count_file_60="${BATS_TMPDIR}/aw_transitions_load_count60_$$.log"
  helper_spawn_count_setup "${shim_dir}" "${count_file_30}"

  local -a keys30=() keys60=()
  local i
  for ((i = 1; i <= 30; i++)); do keys30+=("STORY-${i}"); done
  for ((i = 1; i <= 60; i++)); do keys60+=("STORY-${i}"); done

  local stub='
    source "'"${ROOT}"'/scripts/bash/sink/jira/transitions.sh"
    jira_request() { printf "%s" "{\"transitions\":[{\"id\":\"101\",\"name\":\"Start\",\"to\":{\"name\":\"In Progress\"},\"fields\":{}}]}"; }
    transitions_load "$@" > /dev/null
  '
  PATH="${shim_dir}:${PATH}" bash -c "${stub}" _ "${keys30[@]}"
  helper_spawn_count_setup "${shim_dir}" "${count_file_60}"
  PATH="${shim_dir}:${PATH}" bash -c "${stub}" _ "${keys60[@]}"

  # T155's decode-once shape: transitions_load's PARSING step spawns `jq` a
  # CONSTANT number of times for the whole due set (one call decoding the
  # whole array), never one pair per ticket — so doubling the due set from
  # 30 to 60 costs single-digit additional `jq` spawns, never 30 more.
  local jq30 jq60
  jq30="$(helper_spawn_count_for "${count_file_30}" jq)"
  jq60="$(helper_spawn_count_for "${count_file_60}" jq)"
  [ "${jq30}" -gt 0 ]
  [ "${jq60}" -gt 0 ]
  [ "$((jq60 - jq30))" -lt 5 ]

  rm -rf "${shim_dir}" "${count_file_30}" "${count_file_60}"
}

@test "B3 (T183, Phase 14, Convergence) -- the WHOLE due-set resolution pass grows sub-linearly, not one-for-one, with the due set" {
  # The B3 test above isolates transitions_load's OWN parsing step, with
  # jira_request stubbed before plan_lifecycle's due-set resolution loop
  # ever runs — T182's decode-once fix to THAT loop (transitions_get,
  # transitions_resolve, the outer `.outcome` read, and the kept/warns
  # appends) is invisible to it. This test calls plan_lifecycle directly —
  # the same PURE-function isolation style as test_lifecycle_safety.bats —
  # over a synthetic due set of 30, then 60, tickets ALL resolving to
  # "move" (contract transition-resolution.md §6 B3), asserting the total
  # jq spawn count across the WHOLE pass (transitions_load's decode PLUS
  # the resolution loop PLUS one _plan_transition_action call per moved
  # ticket) stays well under doubling — the same "sub-linear, not
  # one-for-one" bar T150 established for the pre-T182 implementation,
  # never a stricter near-constant bound: _plan_transition_action's own
  # per-ticket cost (building each real POST body) is inherent, shared
  # with two other call sites, and out of T182's scope by design.
  local helpers="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${helpers}/spawn_count.bash"
  local shim_dir="${BATS_TMPDIR}/aw_plan_lifecycle_shims_$$"
  local count_file_30="${BATS_TMPDIR}/aw_plan_lifecycle_count30_$$.log"
  local count_file_60="${BATS_TMPDIR}/aw_plan_lifecycle_count60_$$.log"

  local n
  for n in 30 60; do
    local -a actions=() tickets=()
    local i
    for ((i = 1; i <= n; i++)); do
      actions+=("{\"method\":\"PUT\",\"url\":\"http://h/rest/api/3/issue/STORY-${i}\",\"body\":{\"fields\":{\"summary\":\"New ${i}\"}}}")
      tickets+=("\"s${i}\":{\"key\":\"STORY-${i}\",\"status\":\"To Do\",\"category\":\"mapped\",\"target\":\"In Progress\",\"role\":\"story\",\"flagged\":false,\"blockers\":[]}")
    done
    local doc_stories="[" j
    for ((j = 1; j <= n; j++)); do
      [ "$j" -gt 1 ] && doc_stories+=","
      doc_stories+="{\"local_id\":\"s${j}\"}"
    done
    doc_stories+="]"
    local doc="{\"stories\":${doc_stories}}"
    local acts_json; acts_json="[$(
      IFS=,
      echo "${actions[*]}"
    )]"
    local tickets_json; tickets_json="{$(
      IFS=,
      echo "${tickets[*]}"
    )}"
    local lc="{\"order\":{\"story\":[\"To Do\",\"In Progress\"]},\"base_url\":\"http://h\",\"tickets\":${tickets_json}}"

    local count_file="${BATS_TMPDIR}/aw_plan_lifecycle_count${n}_$$.log"
    helper_spawn_count_setup "${shim_dir}" "${count_file}"

    local stub='
      source "'"${ROOT}"'/scripts/bash/sink/jira/plan_apply.sh"
      jira_request() { printf "%s" "{\"transitions\":[{\"id\":\"101\",\"name\":\"Start\",\"to\":{\"name\":\"In Progress\"},\"fields\":{}}]}"; }
      plan_lifecycle "$1" "$2" "$3" > /dev/null
    '
    PATH="${shim_dir}:${PATH}" bash -c "${stub}" _ "${acts_json}" "${doc}" "${lc}"
  done

  local jq30 jq60
  jq30="$(helper_spawn_count_for "${count_file_30}" jq)"
  jq60="$(helper_spawn_count_for "${count_file_60}" jq)"
  [ "${jq30}" -gt 0 ]
  [ "${jq60}" -gt 0 ]
  # Sub-linear: doubling the due set must not double the jq spawn count.
  [ "${jq60}" -lt "$((jq30 * 2))" ]

  rm -rf "${shim_dir}" "${count_file_30}" "${count_file_60}"
}
