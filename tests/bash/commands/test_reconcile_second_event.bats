#!/usr/bin/env bats
# T058, T060, T062, T063a, T064 [Phase 5, US3] — a second lifecycle event
# over unchanged files still advances the board end to end through
# reconcile (contracts/run-state-v2.md). Landed as its own file rather than
# appended to tests/bash/lib/test_run_state.bats: that file is
# module-level only (run_state_compose/matches/record in isolation, no
# mock, no cmd_reconcile) — these are command-level, end-to-end tests,
# matching the split precedent tasks.md already records for T032/T033.
#
# A dedicated minimal fixture, built inline rather than copied from
# repo-with-mirrored-spec: that fixture carries a stray spec-reordered.md
# which raises a warning on EVERY run (018's own coverage), and S10 (a run
# raising any warning records no state) means the short-circuit these
# tests are ABOUT could never once engage against it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${WORK}/.specify/jira" "${WORK}/specs/001-billing-invoices"
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

  cat > "${WORK}/.specify/jira/config.local.yml" << 'YAML'
resolved_ids:
  COMP:
    style: company_managed
    issue_types:
      - logical_name: "Epic"
        id: "10001"
        hierarchy_level: "1"
        subtask: false
      - logical_name: "Story"
        id: "10004"
        hierarchy_level: "0"
        subtask: false
    child_type:
      logical_name: "Story"
      id: "10004"
      source: derived
    parent_type:
      logical_name: "Epic"
      id: "10001"
      source: derived
    required_fields:
      "10001":
        - logical_name: "Summary"
          field_id: "summary"
      "10004":
        - logical_name: "Summary"
          field_id: "summary"
    parent_link_available:
      "10004": true
    priorities:
      Highest: "1"
      Medium: "3"
      Low: "4"
    statuses:
      To Do: "10000"
    estimation_field_id: "customfield_20011"
YAML

  cat > "${SPEC}" << 'MD'
# Feature Specification: Billing Invoices

We need to let customers export their invoices.

### User Story 1 - Export a single invoice (Priority: P1)

As a customer, I want to export one invoice as a PDF.

- **Given** a signed-in customer viewing an invoice
- **When** they choose Export
- **Then** a PDF download starts

### User Story 2 - Export a date range (Priority: P2)

As a customer, I want to export every invoice in a date range.

- **Given** a signed-in customer on the invoices page
- **When** they pick a start and end date and choose Export
- **Then** a zip of PDFs download starts
MD

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

# T058: reconcile under after_specify (COMP-2 already stands at "To Do",
# its declared step — Z1, zero move; state IS recorded, since this run
# raises no warning), then under after_plan with spec.md and tasks.md
# byte-identical to the first run. The second run must NOT be
# short-circuited by the run-state document (the event itself changed) and
# the ticket must stand at the plan event's step afterward.
@test "T058 -- a second event over byte-identical files is not short-circuited, and the ticket reaches the second event's step" {
  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  unset SPEC_KIT_JIRA_HOOK_EVENT

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  # Not short-circuited: the call log is non-empty and the transition for
  # COMP-2's own declared move actually fires.
  [ "$(wc -l < "${MOCK_CALLLOG}")" -gt 0 ]
  [ "$(jq -e '.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-2/transitions")) | .body.transition.id' <<< "$output")" = '"101"' ]
}

# T060: touching only plan.md (a file spec.md/tasks.md's own hash never
# covers) still produces a full reconcile, and the parent's Implementation
# Plan section actually reaches Jira — the live content defect research
# §R4 documents on unpatched code.
@test "T060 -- adding plan.md alone produces a full reconcile, and its Implementation Plan section reaches the parent" {
  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  cat > "${WORK}/specs/001-billing-invoices/plan.md" << 'MD'
# Implementation Plan: Billing Invoices

## Summary

Export invoices as PDF files using the existing billing service.
MD

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${MOCK_CALLLOG}")" -gt 0 ]
  [[ "$(jq -r '.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-1")) | .body.fields.description' <<< "$output")" == *"Implementation Plan"* ]]
  [[ "$(jq -r '.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-1")) | .body.fields.description' <<< "$output")" == *"Export invoices as PDF files"* ]]
}

# T062: three assertions — the SAME event fired twice over genuinely
# unchanged inputs still short-circuits with an empty call log (the
# promise this whole phase must not break), deleting plan.md invalidates
# the state in the OTHER direction (present -> absent is also a change),
# and a schema-1 document (pre-023) produces a full reconcile on its first
# read under this release.
@test "T062 -- the same event twice short-circuits, plan.md deletion invalidates, and a schema-1 document forces a full reconcile" {
  cat > "${WORK}/specs/001-billing-invoices/plan.md" << 'MD'
# Implementation Plan: Billing Invoices

## Summary

Export invoices as PDF files using the existing billing service.
MD
  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  # Same event, same files, immediate repeat: short-circuits with an
  # empty call log.
  : > "${MOCK_CALLLOG}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  [ "$(wc -l < "${MOCK_CALLLOG}")" -eq 0 ]

  # Deleting plan.md is a change too (present -> absent), not just the
  # other way around: the next run under the same event is NOT
  # short-circuited.
  rm -f "${WORK}/specs/001-billing-invoices/plan.md"
  : > "${MOCK_CALLLOG}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  [ "$(wc -l < "${MOCK_CALLLOG}")" -gt 0 ]

  # A schema-1 recorded document (pre-023, no hook_event/plan.md keys) is
  # never trusted as a match: the next run under an event is a full
  # reconcile, never a short-circuit.
  local state_file; state_file="$(run_state_path "${SPEC}")"
  jq -c 'del(.hook_event) | .schema = 1' "${state_file}" > "${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"
  : > "${MOCK_CALLLOG}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$(wc -l < "${MOCK_CALLLOG}")" -gt 0 ]
}

# T063a: after_analyze is the one event of the six that changes no hashed
# input of its own (no plan.md/tasks.md dependency) — it still performs a
# FULL reconcile the first time it fires against a given input state
# (its own hook_event value is itself part of the comparison), and
# short-circuits on an immediate repeat of that same event.
@test "T063a -- after_analyze costs a full reconcile once, then short-circuits on an immediate repeat" {
  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_analyze
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  [ "$(wc -l < "${MOCK_CALLLOG}")" -gt 0 ]

  : > "${MOCK_CALLLOG}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$(wc -l < "${MOCK_CALLLOG}")" -eq 0 ]
}

# T064 / S10: a run that raises any warning records no state, so an
# unresolvable move is reconsidered — never silently accepted as "handled"
# — by the very next run. COMP-3 has two candidates onto "In Progress" in
# comp-transitions.json — an ambiguous outcome that always warns.
@test "T064 -- a run raising a warning records no state (S10)" {
  # setup()'s own no-event creation run raised no warning and DID record
  # state — clear it so this run's own "records no state" is unambiguous
  # rather than an artefact of a prior run's document still sitting there.
  local state_file; state_file="$(run_state_path "${SPEC}")"
  rm -f "${state_file}"

  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$(jq '.warnings | length' <<< "$output")" -ge 1 ]
  [ ! -f "${state_file}" ]
}
