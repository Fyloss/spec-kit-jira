#!/usr/bin/env bats
# T007 [Phase 1] — The regression test required by the repository's bug-fix
# policy: reconcile a specification twice against the mocked Jira double and
# assert the SECOND run creates nothing. Before the fix this is red — the
# reported defect — for the documented reason: `plan_writes` has no way to
# know a ticket already exists, so every run plans every story as a creation.
#
# T021/T022 [Phase 3, US1] extend this file with the run-sequence tests: a
# ticket is never created for a story whose identifier is unrecorded, an
# unwritable spec.md exits 4 with zero writes, and the `creating`
# fail-closed window (research R8).

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
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-billing-invoices"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
}

teardown() {
  mock_stop
}

@test "a second run creates NOTHING: one story, one ticket, not two (the reported defect)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 4 ]

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "the specification carries one marker per story after the first run, matching the ticket" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  run grep -c 'speckit-jira story=' "${SPEC}"
  [ "$output" -eq 3 ]
  run grep -c 'speckit-jira story=[0-9a-f]\{16\} ticket=COMP-[1-9][0-9]* -->' "${SPEC}"
  [ "$output" -eq 3 ]
}

@test "the full call log shows exactly 4 creation POSTs across two runs, not 8" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  run mock_calls
  [ "$(grep -c '^POST /rest/api/3/issue$' <<< "$output")" -eq 4 ]
}

@test "the PowerShell port: a second run against its own mock instance creates nothing" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  # A native pwsh HTTP client cannot reach the curl shim's sentinel
  # MOCK_BASE_URL, so this cross-port test uses the real pwsh server.
  mock_start "${MOCK}/configs/default.json" powershell
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local pwork="${BATS_TEST_TMPDIR}/repo-ps2"
  cp -R "${FIXTURE}" "${pwork}"
  local pspec="${pwork}/specs/001-billing-invoices/spec.md"

  local first second
  first="$(JIRA_CONFIG_DIR="${pwork}/.specify/jira" pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Reconcile.psm1' -Force
      \$null = Invoke-JiraReconcile -Arguments @('reconcile','--json','${pspec}')
    " 2>/dev/null)"
  : > "${MOCK_CALLLOG}"
  second="$(JIRA_CONFIG_DIR="${pwork}/.specify/jira" pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Reconcile.psm1' -Force
      \$null = Invoke-JiraReconcile -Arguments @('reconcile','--json','${pspec}')
    " 2>/dev/null)"
  [ "$(jq -r '.counts.created' <<< "${second}")" -eq 0 ]
  run mock_calls
  [ "$(grep -c '^POST /rest/api/3/issue$' <<< "$output")" -eq 0 ]
}

# =============================================================================
# T024 [US1.5, FR-006, SC-005] — reordering and retitling never swap tickets.
# =============================================================================

@test "reordering and retitling stories between runs never swaps tickets" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 4 ]

  # Reorder (move story 3 above story 1) and retitle story 2, keeping each
  # marker line with its story.
  local reordered="${BATS_TEST_TMPDIR}/reordered.md"
  awk '
    BEGIN { RS="### User Story" }
    NR==1 { header=$0; next }
    { blocks[NR-1] = "### User Story" $0 }
    END {
      printf "%s", header
      printf "\n%s", blocks[3]
      printf "\n%s", blocks[2]
      printf "\n%s", blocks[1]
    }
  ' "${SPEC}" | sed 's/Export a date range/Export a date range (renamed)/' > "${reordered}"
  cp "${reordered}" "${SPEC}"

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")" -eq 0 ]

  # Each ticket still holds the content of the story whose marker names it —
  # not the story that now sits in its old POSITION.
  run curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-3"
  [ "$(jq -r '.fields.summary' <<< "$output")" = "Export a date range (renamed)" ]
}

# --- 019, T044: contract §5.5, FR-018, SC-005 on all three tiers -----------
@test "019, T044 — origin bridge, no-boundary description: the first run replaces the region, the second reports 0/0 and issues no PUT" {
  local work="${BATS_TEST_TMPDIR}/repo-pre-release-migration-idempotent"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-pre-release-migration" "${work}"
  local spec="${work}/specs/001-feature/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_ID_SOURCE
  mock_start "${MOCK}/configs/preserve-pre-release.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${spec}" --json
  local first_status="$status" first_output="$output"
  [ "${first_status}" -eq 0 ]
  local pre1; pre1="$(jq -c '.actions[] | select(.url | endswith("PRE-1"))' <<< "${first_output}")"
  [ "$(jq -r '.body.fields.description.content[0].content[0].text' <<< "${pre1}")" = "Synced from spec-kit — do not edit below this line" ]

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(grep -cE '^PUT ' "${MOCK_CALLLOG}")" -eq 0 ]
}

# --- 022, T121: checklist-mode renumber produces zero writes (FR-017) ------
@test "022, T121 — checklist mode: renumbering T0xx with text, order and checked state unchanged issues zero writes on the second reconcile" {
  local work="${BATS_TEST_TMPDIR}/repo-checklist-renumber"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-task-tier" "${work}"
  local spec="${work}/specs/001-feature/spec.md"
  local tasks="${work}/specs/001-feature/tasks.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
  printf 'task_mirror:\n  TASKP: checklist\n' >> "${JIRA_CONFIG_DIR}/config.yml"

  local cfg; cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.checklists.created' <<< "$output")" -eq 1 ]

  # Regenerate tasks.md the way /speckit-tasks would: every T0nn shifts up by
  # one, text/order/checked state unchanged.
  sed -i.bak 's/^- \[ \] T001 /- [ ] T101 /; s/^- \[ \] T002 /- [ ] T102 /' "${tasks}"
  rm -f "${tasks}.bak"

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.checklists.unchanged' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.checklists.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.checklists.updated' <<< "$output")" -eq 0 ]
  [ "$(grep -vE 'issue/bulkfetch' "${MOCK_CALLLOG}" | grep -cE '^(POST|PUT) ')" -eq 0 ]
}
