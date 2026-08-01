#!/usr/bin/env bats
# T015/T016 [Phase 2] — spec FR-003a: a binding written before this feature
# (issue_types as a name-to-id map, no child_type/parent_type) is refused
# with its OWN message — the binding predates parent support — never the
# "project has not been bound yet" text, and the refusal happens before the
# first GET (quickstart Step 3b, contracts/hierarchy-resolution.md §1/§6).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-stale-binding"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-billing/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-billing"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
}

teardown() {
  mock_stop
}

@test "a stale binding refuses with its own message, exit 4, zero writes" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"predates parent support"* ]]
  [[ "$output" != *"has not been bound yet"* ]]

  run mock_calls
  [ -z "$output" ]
}

@test "under a hook the refusal downgrades to one WARNING and exit 0 (FR-032)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_HOOK_CONTEXT="after_specify"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(grep -c '^WARNING: ' <<< "$output")" -eq 1 ]
  [[ "$output" == *"predates parent support"* ]]
}
