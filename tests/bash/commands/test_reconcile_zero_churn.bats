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
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null # back-fills the provenance label once

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
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null # back-fills the provenance label once

  sed -i.bak 's/As a customer, I want to export every invoice in a date range\./As a customer, I want to export every invoice in a chosen date range./' "${SPEC}"

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq 2 ]
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-3$' "${MOCK_CALLLOG}")" -eq 1 ]
  # 018, US3: the story's whole-object update always carries `summary`, so the
  # write is followed by exactly one identity-property PUT recording it.
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-3/properties/spec-kit-jira$' "${MOCK_CALLLOG}")" -eq 1 ]
  [ "$(grep -cE '^(POST|PUT) ' "${MOCK_CALLLOG}")" -eq 2 ]
}

@test "spec.md is byte-identical after an unchanged re-run" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null # back-fills the provenance label once
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
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 4 ]
  run cmp "${SPEC}" "${BATS_TEST_TMPDIR}/before-any-run.md"
  [ "$status" -eq 0 ]
  # The one read this run makes: the duplicate probe (017, US4) predicting
  # the parent's creation. Read-only — zero writes either way.
  run mock_calls
  [ "$(grep -c 'search/jql' <<< "$output")" -eq 1 ]
  [ "$(grep -cE '^(POST|PUT) ' <<< "$output")" -eq 0 ]
}

@test "a human-origin ticket's churn is computed on the managed section alone: its prose above the panel is never rewritten (T072)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  local story_id
  story_id="$(grep -oE 'story=[0-9a-f]{16} ticket=COMP-2' "${SPEC}" | grep -oE '^story=[0-9a-f]{16}' | cut -d= -f2)"
  local spec_ref='{"repo":"local/repo","spec_slug":"001-billing-invoices","folder":"x"}'

  # Declare COMP-2 human-origin (as a colleague's own ticket would carry it),
  # with no prose yet: this run wraps it in the managed panel for the first
  # time — a one-time, legitimate churn, not the behaviour under test.
  identity_write "COMP-2" "${spec_ref}" human "${story_id}" > /dev/null
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  # Now a human adds a note above the panel, exactly as a PO would in Jira.
  local current_desc human_desc
  current_desc="$(jira_request GET "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2?fields=description")"
  human_desc="$(jq -cn --argjson d "$(jq -c '.fields.description' <<< "${current_desc}")" \
    '{type:"doc", version:1, content:([{type:"paragraph", content:[{type:"text", text:"Human note above the panel."}]}] + $d.content)}')"
  jira_request PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    "$(jq -cn --argjson d "${human_desc}" '{fields:{description:$d}}')" > /dev/null

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-2$' "${MOCK_CALLLOG}")" -eq 0 ]

  run curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2"
  [ "$(jq -r '.fields.description.content[0].content[0].text' <<< "$output")" = "Human note above the panel." ]
}

@test "T080 — a second reconcile over the declared-hierarchy fixture issues ZERO writes of every kind" {
  local work="${BATS_TEST_TMPDIR}/repo-declared-hierarchy-churn"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-declared-hierarchy" "${work}"
  local spec="${work}/specs/001-consumer-onboarding/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-consumer-onboarding"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
  mock_start "${MOCK}/configs/consumer-hierarchy.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  cmd_reconcile reconcile "${spec}" --json > /dev/null
  cmd_reconcile reconcile "${spec}" --json > /dev/null # back-fills the provenance label once

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq 2 ]
  [ "$(grep -cE '^(POST|PUT) ' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "T056 [016, US3] — a ticket carrying a pre-feature description heals once, then stays quiet (FR-011, FR-012, SC-004)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # Give story 1's overview a Markdown construct so a pre-feature (raw-syntax)
  # description differs from what the current renderer produces.
  sed -i.bak 's/As a customer, I want to export one invoice as a PDF\./As a customer, I want to export one invoice as a PDF, per **FR-012**./' "${SPEC}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  # Simulate a ticket written by the pre-016 renderer: the intro paragraph
  # carries the raw Markdown as one unmarked text node instead of a bold span.
  local current raw healed
  current="$(jira_request GET "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2?fields=description" | jq -c '.fields.description')"
  raw='As a customer, I want to export one invoice as a PDF, per **FR-012**.'
  healed="$(jq -c --arg raw "${raw}" \
    '.content[0] = {type:"paragraph", content:[{type:"text", text:$raw}]}' <<< "${current}")"
  jira_request PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    "$(jq -cn --argjson d "${healed}" '{fields:{description:$d}}')" > /dev/null

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 1 ]
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-2$' "${MOCK_CALLLOG}")" -eq 1 ]
  [ "$(grep -cE '^(POST|PUT) ' "${MOCK_CALLLOG}")" -eq 1 ]

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(grep -cE '^(POST|PUT) ' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "the PowerShell port shows the identical zero-churn signature (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  # A native pwsh HTTP client cannot reach the curl shim's sentinel
  # MOCK_BASE_URL, so this cross-port test uses the real pwsh server.
  mock_start "${MOCK}/configs/default.json" powershell
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local pwork="${BATS_TEST_TMPDIR}/repo-ps"
  cp -R "${FIXTURE}" "${pwork}"
  local pspec="${pwork}/specs/001-billing-invoices/spec.md"

  JIRA_CONFIG_DIR="${pwork}/.specify/jira" pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Reconcile.psm1' -Force
      \$null = Invoke-JiraReconcile -Arguments @('reconcile','--json','${pspec}')
    " > /dev/null 2>/dev/null

  JIRA_CONFIG_DIR="${pwork}/.specify/jira" pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Reconcile.psm1' -Force
      \$null = Invoke-JiraReconcile -Arguments @('reconcile','--json','${pspec}')
    " > /dev/null 2>/dev/null # back-fills the provenance label once

  local second
  second="$(JIRA_CONFIG_DIR="${pwork}/.specify/jira" pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Reconcile.psm1' -Force
      \$null = Invoke-JiraReconcile -Arguments @('reconcile','--json','${pspec}')
    " 2>/dev/null)"
  [ "$(jq -r '.counts.skipped' <<< "${second}")" -eq 3 ]
  [ "$(jq -r '.counts.updated' <<< "${second}")" -eq 0 ]
}
