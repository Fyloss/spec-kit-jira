#!/usr/bin/env bats
# T041 [US4] — A team-managed project mirrors as correctly as a
# company-managed one: both styles declare a project, an issue type
# belonging to that project, and no attribute the project does not accept
# (FR-026–FR-031, SC-011–SC-013).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/reconcile.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="test-token-value"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-two-styles"
  export JIRA_CONFIG_DIR="${FIXTURE}/.specify/jira"
  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PROJECT_KEY
  unset SPEC_KIT_JIRA_PLAN_CONTEXT
}

_run_billing() {
  SPEC_KIT_JIRA_SPEC_SLUG="001-billing-invoices" \
    run cmd_reconcile reconcile --dry-run --json "${FIXTURE}/specs/billing-001-invoices/spec.md"
}

_run_infra() {
  SPEC_KIT_JIRA_SPEC_SLUG="001-infra-pipeline" \
    run cmd_reconcile reconcile --dry-run --json "${FIXTURE}/specs/infra-001-pipeline/spec.md"
}

@test "both styles declare the project, unconditionally (FR-026)" {
  _run_billing
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[1].body.fields.project.key' <<< "$output")" = "COMP" ]

  _run_infra
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[1].body.fields.project.key' <<< "$output")" = "TEAM" ]
}

@test "each payload declares an issue type belonging to that project, never the other's (FR-027, SC-013)" {
  _run_billing
  [ "$(jq -r '.actions[1].body.fields.issuetype.id' <<< "$output")" = "10004" ]

  _run_infra
  [ "$(jq -r '.actions[1].body.fields.issuetype.id' <<< "$output")" = "20002" ]
}

@test "the team-managed payload declares no priority, and the run still succeeds (FR-029, SC-012)" {
  _run_infra
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[1].body.fields | has("priority")' <<< "$output")" = "false" ]
}

@test "the company-managed payload declares a priority (contrast case)" {
  _run_billing
  [ "$(jq -r '.actions[1].body.fields | has("priority")' <<< "$output")" = "true" ]
}
