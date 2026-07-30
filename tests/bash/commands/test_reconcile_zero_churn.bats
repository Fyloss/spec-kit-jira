#!/usr/bin/env bats
# T033-T036 [Phase 4, US2] — recognition is not enough: an unchanged re-run
# over a mirrored corpus must issue NO write of any kind, and spec.md must be
# byte-identical. Zero churn is computed on the managed section alone for a
# human-origin ticket, and --dry-run predicts identifiers without assigning
# them.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  PS_CMD="${ROOT}/scripts/powershell/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-billing-invoices/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
}

teardown() {
  mock_stop
}

@test "an unchanged re-run issues ZERO POST and ZERO PUT, skipped equals the story count" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq 3 ]
  [ "$(jq -r '.counts.recognised' <<< "$output")" -eq 3 ]
  [ "$(grep -cE '^(POST|PUT) ' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "a change to one story out of several produces exactly one PUT, naming that story's ticket" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  sed -i.bak 's/As a customer, I want to export every invoice in a date range\./As a customer, I want to export every invoice in a chosen date range./' "${SPEC}"

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq 2 ]
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-2$' "${MOCK_CALLLOG}")" -eq 1 ]
  [ "$(grep -cE '^(POST|PUT) ' "${MOCK_CALLLOG}")" -eq 1 ]
}

@test "spec.md is byte-identical after an unchanged re-run" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  cp "${SPEC}" "${BATS_TEST_TMPDIR}/before.md"

  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  run cmp "${SPEC}" "${BATS_TEST_TMPDIR}/before.md"
  [ "$status" -eq 0 ]
}

@test "--dry-run writes neither Jira nor spec.md" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cp "${SPEC}" "${BATS_TEST_TMPDIR}/before-any-run.md"

  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 3 ]
  run cmp "${SPEC}" "${BATS_TEST_TMPDIR}/before-any-run.md"
  [ "$status" -eq 0 ]
  run mock_calls
  [ -z "$output" ]
}

@test "the PowerShell port shows the identical zero-churn signature (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local pwork="${BATS_TEST_TMPDIR}/repo-ps"
  cp -R "${FIXTURE}" "${pwork}"
  local pspec="${pwork}/specs/001-billing-invoices/spec.md"

  JIRA_CONFIG_DIR="${pwork}/.specify/jira" pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Reconcile.psm1' -Force
      \$null = Invoke-JiraReconcile -Arguments @('reconcile','--json','${pspec}')
    " > /dev/null 2>/dev/null

  local second
  second="$(JIRA_CONFIG_DIR="${pwork}/.specify/jira" pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Reconcile.psm1' -Force
      \$null = Invoke-JiraReconcile -Arguments @('reconcile','--json','${pspec}')
    " 2>/dev/null)"
  [ "$(jq -r '.counts.skipped' <<< "${second}")" -eq 3 ]
  [ "$(jq -r '.counts.updated' <<< "${second}")" -eq 0 ]
}
