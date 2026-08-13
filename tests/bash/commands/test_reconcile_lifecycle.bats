#!/usr/bin/env bats
# T046-T050 [Phase 6, US4] — recognition feeds the safety rules: drift and
# Flagged now engage against REAL recognised state (not only the
# SPEC_KIT_JIRA_LIFECYCLE override), while no ticket's status is ever moved
# (research R9).

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

  # This project declares a phase->status map (Phase 6, US4): after_specify
  # maps to "To Do", after_plan to "In Progress". Rewritten wholesale
  # (rather than appended) so the new keys land INSIDE the existing "- key:
  # COMP" project entry, not as a dangling top-level YAML fragment.
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
    halted_statuses:
      - "Blocked"
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
  # 023: the parent now gets its own entry in the SAME lifecycle-context
  # `tickets` map stories key into (role "specification", by local_id) — a
  # 3-item source wraps (index 3 % 3 == 0) and hands the epic the SAME
  # local_id as the first story, so its entry silently overwrites COMP-2's.
  # A 4th distinct id keeps every local_id unique.
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
}

teardown() {
  mock_stop
}

@test "a mapped ticket advanced beyond the event's phase raises a named drift warning, content still reconciles (FR-031)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  # Advance COMP-2 (the first story; COMP-1 is now the parent) to "In
  # Progress" — a status the phase map DOES declare (for after_plan), so
  # it classifies "mapped" and is comparable in the declared order —
  # ahead of what after_specify's "To Do" implies.
  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}}' > /dev/null

  sed -i.bak 's/export one invoice as a PDF/export one invoice as a PDF file/' "${SPEC}"

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq '.warnings | length' <<< "$output")" -ge 1 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"In Progress"* ]]
  # Content still reconciles (FR-031): only the STATUS TRANSITION is
  # withheld — reconcile never issues transitions at all in this release
  # (R9), so the content PUT proceeds normally.
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-2$' "${MOCK_CALLLOG}")" -eq 1 ]
  unset SPEC_KIT_JIRA_HOOK_EVENT
}

@test "a halted ticket has its content write suppressed and a named warning" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"Blocked","statusCategory":{"key":"indeterminate"}}}}' > /dev/null

  sed -i.bak 's/export one invoice as a PDF/export one invoice as a PDF file/' "${SPEC}"

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"halted"* ]]
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-2$' "${MOCK_CALLLOG}")" -eq 0 ]
  unset SPEC_KIT_JIRA_HOOK_EVENT
}

@test "a Flagged ticket has its transition withheld, is surfaced, and no flag write is emitted" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-3" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"Flagged":[{"value":"Impediment"}]}}' > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.warnings | join(" ")' <<< "$output")" == *"Flagged"* ]]
  [ "$(grep -c 'Flagged' "${MOCK_CALLLOG}")" -eq 0 ]
  unset SPEC_KIT_JIRA_HOOK_EVENT
}

# T054: this pin predates 023, which now DOES move a ticket's status for a
# project that declares a mapping (superseded by the "headline" scenario
# covered elsewhere). What stays true is the FR-026 bound this test now
# asserts: a project declaring NO phase_status_map issues zero transition
# reads — `due_idx` is never populated absent a declared target (research
# §R9's original no-op default, still exercised for the undeclared case).
@test "a project declaring no phase_status_map issues zero transition requests" {
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
YAML

  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  unset SPEC_KIT_JIRA_HOOK_EVENT
  run mock_calls
  [ "$(grep -c 'transitions' <<< "$output")" -eq 0 ]
}

@test "under SPEC_KIT_JIRA_HOOK_CONTEXT every recognition failure exits 0 with exactly one WARNING" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"faults": {"issue/COMP-1": {"status": 401}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # Seed COMP-1 as already bound (config.local-style override) so the
  # SECOND run's recognition read actually hits the faulted path.
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>/dev/null || true

  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(grep -c 'WARNING:' <<< "$output")" -eq 1 ]
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
}

# =============================================================================
# T085 [Phase 9] — every §6 role-mapping refusal downgrades to one WARNING
# with exit 0 under hook context (010, contract §6, FR-020, Constitution III)
# =============================================================================

@test "T085 — a §6 role-mapping refusal (inverted ordering) exits 4 directly, and downgrades to one WARNING under a hook" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  # Inject an inverted `roles` block into the persisted binding — impossible
  # to produce via the config ceremony, but representative of a hand-edited
  # or pre-010 binding upgraded by hand (§8 re-validation).
  local localf="${JIRA_CONFIG_DIR}/config.local.yml"
  local injected
  injected="$(jq -cS '.resolved_ids.COMP.roles = {
      specification: {logical_name: "Story", id: "10004", hierarchy_level: "0", subtask: false, source: "declared"},
      story: {logical_name: "Epic", id: "10001", hierarchy_level: "1", subtask: false, source: "declared"}
    }' <<< "$(config_yaml_to_json "${localf}")")"
  printf '%s' "${injected}" | config_to_yaml > "${localf}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"reconcile: project COMP: specification names"* ]]

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(grep -c '^WARNING: ' <<< "$output")" -eq 1 ]
  [[ "$output" == *"is not above story"* ]]
  unset SPEC_KIT_JIRA_HOOK_CONTEXT

  run mock_calls
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    [[ "${line}" == GET\ * ]]
  done <<< "$output"
}

@test "the PowerShell port also suppresses content for a halted ticket and names it (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  # A native pwsh HTTP client cannot reach the curl shim's sentinel
  # MOCK_BASE_URL, so this cross-port test uses the real pwsh server.
  mock_start "${MOCK}/configs/default.json" powershell
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local pwork="${BATS_TEST_TMPDIR}/repo-ps"
  cp -R "${FIXTURE}" "${pwork}"
  cat > "${pwork}/.specify/jira/config.yml" << 'YAML'
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
    halted_statuses:
      - "Blocked"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
YAML
  local pspec="${pwork}/specs/001-billing-invoices/spec.md"

  JIRA_CONFIG_DIR="${pwork}/.specify/jira" pwsh -NoProfile -Command "
      Import-Module '${ROOT}/scripts/powershell/commands/Reconcile.psm1' -Force
      \$null = Invoke-JiraReconcile -Arguments @('reconcile','--json','${pspec}')
    " > /dev/null 2>/dev/null

  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"Blocked","statusCategory":{"key":"indeterminate"}}}}' > /dev/null
  sed -i.bak 's/export one invoice as a PDF/export one invoice as a PDF file/' "${pspec}"

  : > "${MOCK_CALLLOG}"
  local out
  out="$(JIRA_CONFIG_DIR="${pwork}/.specify/jira" SPEC_KIT_JIRA_HOOK_EVENT=after_specify pwsh -NoProfile -Command "
      Import-Module '${ROOT}/scripts/powershell/commands/Reconcile.psm1' -Force
      \$null = Invoke-JiraReconcile -Arguments @('reconcile','--json','${pspec}')
    " 2>/dev/null)"
  [[ "$(jq -r '.warnings[0]' <<< "${out}")" == *"halted"* ]]
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-2$' "${MOCK_CALLLOG}")" -eq 0 ]
}
