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
