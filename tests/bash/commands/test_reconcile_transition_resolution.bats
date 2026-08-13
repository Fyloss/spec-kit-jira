#!/usr/bin/env bats
# T040/T041 [Phase 4, US1] — a declared step actually moves a ticket, end to
# end through reconcile: transitions.sh's read feeds plan_lifecycle's
# resolution, and each of the four outcomes (contracts/
# transition-resolution.md §3/§4) is observable from cmd_reconcile's own
# output and recorded call sequence — not just the module in isolation
# (test_transitions.bats covers that).

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
      after_plan: "In Progress"
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

  mock_start "${MOCK}/configs/comp-transitions.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
}

teardown() {
  mock_stop
}

@test "an ungated declared step actually moves the ticket, once, and counts it" {
  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(jq -e '.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-2/transitions")) | .body.transition.id' <<< "$output")" = '"101"' ]
  [ "$(jq -r '.counts.transitioned' <<< "$output")" -ge 1 ]
  [ "$(grep -c '^GET /rest/api/3/issue/COMP-2/transitions' "${MOCK_CALLLOG}")" -eq 1 ]
}

@test "two candidates onto the declared step move nothing and warn, naming both" {
  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(jq -e '[.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-3/transitions"))] | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings | join(" ")' <<< "$output")" == *"COMP-3"* ]]
}

@test "a gated declared step moves nothing and names the withheld field" {
  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(jq -e '[.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-4/transitions"))] | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings | join(" ")' <<< "$output")" == *"Resolution"* ]]
}

@test "a second run under the same event moves nothing more — idempotent (Z2)" {
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.transitioned' <<< "$output")" -eq 0 ]
}

# T040: once COMP-2 stands at its declared step, a run under the SAME event
# asks the tracker nothing about it — no availability read at all, not even
# one that resolves to no-op — and raises no warning for it (FR-008,
# contract §7 Z1).
@test "a ticket already at its declared step asks the tracker nothing about it" {
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(grep -c '^GET /rest/api/3/issue/COMP-2/transitions' "${MOCK_CALLLOG}")" -eq 0 ]
  [[ "$(jq -r '.warnings | join(" ")' <<< "$output")" != *"COMP-2"* ]]
}

@test "T109 -- an ambiguous or gated outcome never suppresses that ticket's own content update, and never suppresses another ticket's move (U2/U3)" {
  # A genuine content diff for COMP-3 and COMP-4's own stories -- otherwise
  # their PUT is zero-churn (unchanged since setup's own creation run) and
  # this test would prove nothing about content survival.
  sed -i.bak 's/export every invoice in a date range/export every invoice in a date range as a bundle/' "${SPEC}"
  sed -i.bak 's/a clear message when export is temporarily unavailable/a clear message when export is temporarily unavailable for maintenance/' "${SPEC}"
  rm -f "${SPEC}.bak"

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  # COMP-3 (ambiguous) and COMP-4 (gated) still receive their content PUT.
  [ "$(jq -e '[.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-3")) | select(.method == "PUT")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -e '[.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-4")) | select(.method == "PUT")] | length' <<< "$output")" -eq 1 ]
  # COMP-2's own move (a clean outcome) still fires in the SAME run —
  # neither COMP-3's ambiguous nor COMP-4's gated outcome suppresses it.
  [ "$(jq -e '.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-2/transitions")) | .body.transition.id' <<< "$output")" = '"101"' ]
}

@test "T111 -- an exhausted availability read fails closed for the WHOLE specification, zero content writes, exit code F2 (contract §2)" {
  # setup()'s own $SPEC already carries real markers recorded against
  # setup()'s own mock instance (mock A) -- restarting the mock (fresh,
  # blank state) against that SAME file would refuse as an unrecognised
  # identity, not exercise the fault this test is about. A genuinely fresh
  # work directory keeps this test's own mock instance the only one its
  # markers were ever recorded against.
  mock_stop
  local work2="${BATS_TEST_TMPDIR}/repo-faulted"
  cp -R "${FIXTURE}" "${work2}"
  local spec2="${work2}/specs/001-billing-invoices/spec.md"
  cp "${WORK}/.specify/jira/config.yml" "${work2}/.specify/jira/config.yml"
  export JIRA_CONFIG_DIR="${work2}/.specify/jira"

  local cfg; cfg="$(mock_write_config '{"projects":{"COMP":"company"},"transitions":{"COMP-2":[{"id":"101","name":"Start","to":{"name":"In Progress"},"fields":{}}]},"faults":{"issue/COMP-2/transitions":{"status":400}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${spec2}" --json > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${spec2}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 2 ]
  [[ "$output" == *"COMP-2"* ]]
  # Fail-closed for the WHOLE specification -- not even the OTHER tickets'
  # already-decided content writes reach the tracker (reads -- recognition's
  # own bulkfetch prefetch, and the failing availability read itself -- are
  # not writes, and are expected).
  [ "$(grep -vc 'bulkfetch\|transitions?expand' "${MOCK_CALLLOG}")" -eq 0 ]
}
