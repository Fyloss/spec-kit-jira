#!/usr/bin/env bats
# T059 [US3] — The reconcile command: engine -> sink -> summary, BLOCK-guarded.
# Every created Story has a ladder title and a non-empty structured description,
# and Gherkin criteria whenever the spec has any — including specs with no
# `## Summary` section (SC-002). The estimation is create-only (FR-018). The
# --dry-run report is exactly the planned action set (FR-033); the PowerShell
# port emits an identical summary (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/commands"
  PS_CMD="${ROOT}/.specify/extensions/jira/scripts/powershell/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_PROJECT_KEY="PROJ"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT

  SPEC_WITH="${BATS_TEST_TMPDIR}/with.md"
  printf '%s\n' \
    '# Feature Specification: Rich Tickets' '' 'We need a reconcile bridge for specs.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' 'Estimation: 5' '' \
    '- **Given** a signed-in user' '- **When** they open the board' '- **Then** the widgets load' \
    > "${SPEC_WITH}"

  SPEC_NOSUMMARY="${BATS_TEST_TMPDIR}/nosummary.md"
  printf '%s\n' '# Only A Title' > "${SPEC_NOSUMMARY}"
}

@test "dry-run plans a create with a ladder title and rich ADF description" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[0].method' <<< "$output")" = "POST" ]
  [ "$(jq -r '.actions[0].body.fields.summary' <<< "$output")" = "The core story" ]
  # Non-empty structured description as an ADF doc with the Gherkin panel.
  [ "$(jq -r '.actions[0].body.fields.description.type' <<< "$output")" = "doc" ]
  [ "$(jq '[.actions[0].body.fields.description.content[] | select(.type=="panel")] | length' <<< "$output")" -eq 1 ]
}

@test "a spec with NO ## Summary still yields a non-empty description (SC-002)" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC_NOSUMMARY}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[0].body.fields.summary' <<< "$output")" = "Only A Title" ]
  [ "$(jq '[.actions[0].body.fields.description.content[] | select(.type=="paragraph")] | length' <<< "$output")" -ge 1 ]
}

@test "an update never re-sends the estimation (FR-018)" {
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"estimation_field_id":"customfield_30044","tickets":{"s1":"ABC-1"}}'
  run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[0].method' <<< "$output")" = "PUT" ]
  [ "$(jq 'has("customfield_30044") | not' <<< "$(jq -c '.actions[0].body.fields' <<< "$output")")" = "true" ]
}

@test "a create writes the estimation to the discovered field (FR-018)" {
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"estimation_field_id":"customfield_30044"}'
  run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$(jq -r '.actions[0].body.fields.customfield_30044' <<< "$output")" = "5" ]
}

@test "the PowerShell port emits an identical dry-run summary (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}")"
  p="$(SPEC_KIT_JIRA_BASE_URL='https://mock' SPEC_KIT_JIRA_SPEC_SLUG='001-feature' \
       SPEC_KIT_JIRA_REPO='acme/app' SPEC_KIT_JIRA_PROJECT_KEY='PROJ' \
       pwsh -NoProfile -Command "
        Import-Module '${PS_CMD}/Reconcile.psm1' -Force
        \$null = Invoke-JiraReconcile -Arguments @('reconcile','--dry-run','--json','${SPEC_WITH}')")"
  [ "${b}" = "${p}" ]
}
