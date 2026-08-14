#!/usr/bin/env bats
# T021, T023, T025 [Phase 3, US2] — the event that fired actually reaches
# the mirror (contract lifecycle-event.md). The read half of the machinery:
# COMP-2's own drift warning is filtered out of the fixture's unrelated
# noise (COMP-3/COMP-4 unreachable warnings once a target is declared for
# them too, and a stray "markers found in files" note the fixture always
# raises) so only the wording that actually resolves an event's own step
# is asserted on.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-billing-invoices/spec.md"

  # Six distinct declared steps, one per after-event, in canonical
  # lifecycle-event order (contract lifecycle-event.md §1).
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      after_specify: "To Do"
      after_clarify: "Clarified"
      after_plan: "Planned"
      after_tasks: "Tasked"
      after_implement: "Implemented"
      after_analyze: "Analyzed"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
YAML

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE

  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  # COMP-2 (the first story) stands at "Analyzed" — after_analyze's own
  # declared step and the LAST in canonical order, so it is "ahead" of
  # every other event's target and only even with its own.
  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"Analyzed","statusCategory":{"key":"indeterminate"}}}}' > /dev/null
}

teardown() {
  mock_stop
}

# comp2_drift_warning <run-json> — COMP-2's own "advanced Jira-side" drift
# warning, isolated from the fixture's unrelated noise (COMP-3/COMP-4's own
# unreachable-transition warnings, and the stray "markers found" note).
comp2_drift_warning() {
  jq -r '[.warnings[] | select(startswith("ticket advanced"))] | join(" ")' <<< "$1"
}

# T021: each of the six after-events resolves its OWN event's step and no
# other — six distinct outcomes (contract §6). COMP-2 sitting fixed at
# "Analyzed" is ahead of every target but its own, so five runs each name a
# DIFFERENT target in its drift warning and the sixth (its own event) warns
# not at all.
@test "T021 -- each of the six after-events resolves its own declared step, six distinct outcomes" {
  declare -A target=(
    [after_specify]="To Do"
    [after_clarify]="Clarified"
    [after_plan]="Planned"
    [after_tasks]="Tasked"
    [after_implement]="Implemented"
    [after_analyze]="Analyzed"
  )
  local event
  for event in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
    export SPEC_KIT_JIRA_HOOK_EVENT="${event}"
    run cmd_reconcile reconcile "${SPEC}" --json
    unset SPEC_KIT_JIRA_HOOK_EVENT
    [ "$status" -eq 0 ]
    local warn; warn="$(comp2_drift_warning "$output")"
    if [[ "${event}" == "after_analyze" ]]; then
      # Its own event: current already equals target, no drift, no warning.
      [ -z "${warn}" ]
    else
      [[ "${warn}" == *"\"${target[${event}]}\""* ]]
      # Never any of the OTHER five targets' names leaking into this run's
      # drift warning — proves the resolved step belongs to THIS event alone.
      local other
      for other in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
        [[ "${other}" == "${event}" || "${other}" == "after_analyze" ]] && continue
        [[ "${warn}" != *"\"${target[${other}]}\""* ]]
      done
    fi
  done
}

# T023: no event set (a direct invocation) — no drift rule is evaluated
# (target resolves ""), nothing is asked of the tracker about available
# moves, and no lifecycle warning of any kind is raised for any ticket
# (contract §4, invariant E1).
@test "T023 -- with no event set, no drift rule is evaluated and nothing is asked of the tracker" {
  : > "${MOCK_CALLLOG}"
  unset SPEC_KIT_JIRA_HOOK_EVENT
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -e '[.warnings[] | select(startswith("ticket") or startswith("Story ticket") or contains("was not moved"))] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -e 'has("counts") and (.counts | has("transitioned") | not)' <<< "$output")" = "true" ]
  [ "$(grep -c 'transitions' "${MOCK_CALLLOG}")" -eq 0 ]
}

# T025: an event value outside the closed set of six behaves exactly as no
# event at all — zero availability reads, zero lifecycle warnings, and
# crucially never a CONFIG refusal (invariant E2): the caller's vocabulary
# is not the team's configuration, so an unrecognised event is not an error.
@test "T025 -- an unrecognised event value behaves as no event: zero reads, zero warnings, never a config refusal" {
  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT="after_launch_party"
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(jq -e '[.warnings[] | select(startswith("ticket") or startswith("Story ticket") or contains("was not moved"))] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -e 'has("counts") and (.counts | has("transitioned") | not)' <<< "$output")" = "true" ]
  [ "$(grep -c 'transitions' "${MOCK_CALLLOG}")" -eq 0 ]
}
