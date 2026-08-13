#!/usr/bin/env bats
# T076 [Phase 6, US4] — back-compatibility guarantees B1/B2 (contract
# role-lifecycle-config.md §6): a committed role-blind mapping (every key a
# lifecycle event, written before roles existed) keeps its current meaning
# for the story role untouched, AND upgrading never starts moving a
# specification-tier parent on the strength of that mapping — it normalises
# to an EMPTY `specification` map (FR-020), so the parent's own target is
# always "" and its lifecycle-safety entry is never evaluated against any
# step. Landed as its own command-level file (this fixture and mock setup
# match test_reconcile_second_event.bats's split precedent) rather than
# tests/bash/lib/test_config_phase_status_map.bats, which is config.sh-only
# (no mock, no cmd_reconcile).

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

  # Role-blind: every key a lifecycle event, exactly as a project committed
  # this before 023 shipped roles at all.
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

@test "T076 -- a role-blind mapping never moves or evaluates the parent, and the story's own behaviour is untouched (B1/B2)" {
  # Put the parent somewhere a real specification-role mapping WOULD treat
  # as advanced-beyond-target and warn about, if the parent were ever
  # evaluated at all — proving it genuinely never is.
  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"Building","statusCategory":{"key":"indeterminate"}}}}' > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]

  # B2: the parent is never read for transitions, never moved, and no
  # warning ever names it — its target is always "" under a role-blind
  # mapping, so drift is never even evaluated for it.
  [ "$(grep -c 'COMP-1/transitions' "${MOCK_CALLLOG}")" -eq 0 ]
  [ "$(jq -e '[.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-1/transitions"))] | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings | join(" ")' <<< "$output")" != *"COMP-1"* ]]

  # B1: the story's own declared-step behaviour is exactly what a
  # role-blind mapping has always produced — the headline case, unaffected.
  [ "$(jq -e '.actions[] | select(.url | endswith("/rest/api/3/issue/COMP-2/transitions")) | .body.transition.id' <<< "$output")" = '"101"' ]
  [ "$(jq -r '.counts.transitioned' <<< "$output")" -eq 1 ]
}
