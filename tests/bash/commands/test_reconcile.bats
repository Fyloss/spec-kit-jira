#!/usr/bin/env bats
# T059 [US3] — The reconcile command: engine -> sink -> summary, BLOCK-guarded.
# Every created Story has a ladder title and a non-empty structured description,
# and Gherkin criteria whenever the spec has any — including specs with no
# `## Summary` section (SC-002). The estimation is create-only (FR-018). The
# --dry-run report is exactly the planned action set (FR-033); the PowerShell
# port emits an identical summary (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  PS_CMD="${ROOT}/scripts/powershell/commands"
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

@test "an invalid SPEC_KIT_JIRA_LIFECYCLE maps to the config exit code with an actionable error (FR-032)" {
  # Through the REAL dispatcher (live `set -euo pipefail`): an unguarded jq
  # failure used to kill the process with a raw exit code and no error message.
  SPEC_KIT_JIRA_LIFECYCLE='{not json' \
    run bash "${ROOT}/scripts/bash/spec-kit-jira.sh" reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"SPEC_KIT_JIRA_LIFECYCLE"* ]]
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

@test "a bare relative spec filename resolves from the cwd in both ports (NFR-1)" {
  # dirname of a bare filename is '.' in the Bash port; the PowerShell port's
  # Split-Path -Parent yields '' for the same input (and for a root-level path),
  # which must resolve identically instead of failing the interchange schema.
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(cd "${BATS_TEST_TMPDIR}" && cmd_reconcile reconcile --dry-run --json with.md)"
  p="$(cd "${BATS_TEST_TMPDIR}" && \
       SPEC_KIT_JIRA_BASE_URL='https://mock' SPEC_KIT_JIRA_SPEC_SLUG='001-feature' \
       SPEC_KIT_JIRA_REPO='acme/app' SPEC_KIT_JIRA_PROJECT_KEY='PROJ' \
       pwsh -NoProfile -Command "
        Import-Module '${PS_CMD}/Reconcile.psm1' -Force
        \$null = Invoke-JiraReconcile -Arguments @('reconcile','--dry-run','--json','with.md')")"
  [ -n "${b}" ]
  [ "${b}" = "${p}" ]
}

# --- adoption reporting (003 T110, FR-018) -----------------------------------

# adopted_ctx <existing-description-json> — a plan context describing one
# ADOPTED ticket: an existing key, the human origin adoption stamps, and its
# current description.
adopted_ctx() {
  jq -cn --argjson d "${1}" '
    {tickets:{s1:"ADO-1"}, ticket_origins:{s1:"human"}, ticket_descriptions:{s1:$d}}'
}

@test "the first reconcile after adoption reports the ticket and what was ADDED (FR-018)" {
  # A hand-written description with no managed panel yet: the panel is about to
  # be added below it for the first time.
  local existing
  existing='{"type":"doc","version":1,"content":[
    {"type":"paragraph","content":[{"type":"text","text":"PO handwritten note."}]}]}'
  SPEC_KIT_JIRA_PLAN_CONTEXT="$(adopted_ctx "${existing}")" \
    run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.adopted | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.adopted[0].ticket' <<< "$output")" = "ADO-1" ]
  [[ "$(jq -r '.adopted[0].action' <<< "$output")" == *"adopted ticket"* ]]
  [[ "$(jq -r '.adopted[0].action' <<< "$output")" == *"added below the existing description"* ]]
  [[ "$(jq -r '.adopted[0].action' <<< "$output")" == *"nothing outside it was touched"* ]]
}

@test "a later reconcile reports the panel as UPDATED, not added (FR-018)" {
  # The same ticket once the panel exists: the wording must not claim a second
  # addition.
  local marker existing
  marker="$(adf_managed_marker)"
  existing="$(jq -cn --arg m "${marker}" '
    {type:"doc", version:1, content:[
      {type:"paragraph", content:[{type:"text", text:"PO handwritten note."}]},
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"paragraph", content:[{type:"text", text:"previous managed body"}]}]}')"
  SPEC_KIT_JIRA_PLAN_CONTEXT="$(adopted_ctx "${existing}")" \
    run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.adopted[0].action' <<< "$output")" == *"updated"* ]]
  [[ "$(jq -r '.adopted[0].action' <<< "$output")" != *"added below"* ]]
}

@test "the first reconcile after adoption adds NOTHING outside the managed panel (SC-002)" {
  local existing
  existing='{"type":"doc","version":1,"content":[
    {"type":"paragraph","content":[{"type":"text","text":"PO handwritten note."}]}]}'
  SPEC_KIT_JIRA_PLAN_CONTEXT="$(adopted_ctx "${existing}")" \
    run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  local desc
  desc="$(jq -c '.actions[0].body.fields.description' <<< "$output")"
  # The human paragraph is still the FIRST node, byte-for-byte.
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "PO handwritten note." ]
  # And the run performs no create, no transition and no second write.
  [ "$(jq -r '[.actions[] | select(.method != "PUT")] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.actions | length' <<< "$output")" -eq 1 ]
}

@test "a bridge-created ticket is NOT reported as adopted, and the key is absent" {
  local existing
  existing='{"type":"doc","version":1,"content":[]}'
  SPEC_KIT_JIRA_PLAN_CONTEXT="$(jq -cn --argjson d "${existing}" '
    {tickets:{s1:"ADO-1"}, ticket_origins:{s1:"bridge-created"}, ticket_descriptions:{s1:$d}}')" \
    run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("adopted")' <<< "$output")" = "false" ]
}

@test "a reconcile with no adopted ticket keeps its summary key-for-key unchanged" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("adopted")' <<< "$output")" = "false" ]
}

@test "the adoption report reaches the DEFAULT prose output, not only --json (XVI)" {
  local existing
  existing='{"type":"doc","version":1,"content":[
    {"type":"paragraph","content":[{"type":"text","text":"PO handwritten note."}]}]}'
  SPEC_KIT_JIRA_PLAN_CONTEXT="$(adopted_ctx "${existing}")" \
    run cmd_reconcile reconcile --dry-run "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adopted:"* ]]
  [[ "$output" == *"ADO-1: adopted ticket"* ]]
}

@test "the adoption report is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local existing ctx bash_out ps_out ps_abs
  existing='{"type":"doc","version":1,"content":[
    {"type":"paragraph","content":[{"type":"text","text":"PO handwritten note."}]}]}'
  ctx="$(adopted_ctx "${existing}")"
  bash_out="$(SPEC_KIT_JIRA_PLAN_CONTEXT="${ctx}" cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}")"
  ps_abs="$(cd "${PS_CMD}" && pwd)"
  ps_out="$(SPEC_KIT_JIRA_PLAN_CONTEXT="${ctx}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/Reconcile.psm1' -Force
    [void](Invoke-JiraReconcile -Arguments @('reconcile','--dry-run','--json','${SPEC_WITH}'))
  ")"
  [ "$(jq -c '.adopted' <<< "${bash_out}")" = "$(jq -c '.adopted' <<< "${ps_out}")" ]
}
