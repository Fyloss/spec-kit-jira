#!/usr/bin/env bats
# T059/T067 [Phase 5, US2] — The parent's description carries the overview
# prose, a named Success Criteria section and a named Out of Scope section
# as prose (data-model.md §7) — and NO list of user stories (spec FR-011).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/parse.sh"
}

_epic_wrapper() {
  local slug="${2:-001-billing}"
  printf '%s' "$1" | parse_spec "${slug}"
}

DOC=$'# Feature Specification: Billing Invoices\n\nWe need to let customers export their invoices.\n\nThis unlocks self-service billing support.\n\n### User Story 1 - Export a single invoice (Priority: P1)\n\nAs a customer I want to export.\n\n### User Story 2 - Bulk export (Priority: P2)\n\nAs a customer I want to export many.\n\n## Success Criteria *(mandatory)*\n\n### Measurable Outcomes\n\n- **SC-001**: A customer exports an invoice in under 5 seconds.\n- **SC-002**: Support tickets about missing invoices drop by half.\n\n## Out of Scope\n\n- **Refunds.** Refund processing is handled by a separate system.\n- **Bulk import.** Importing invoices is not covered.\n'

@test "the epic description gains a named Success Criteria section as a bullet list, SC-00N labels stripped" {
  run _epic_wrapper "${DOC}"
  [ "$status" -eq 0 ]
  local blocks; blocks="$(jq -c '.epic.description.blocks' <<< "$output")"
  [ "$(jq -r '[.[] | select(.type=="heading" and .text=="Success Criteria")] | length' <<< "${blocks}")" -eq 1 ]
  local items; items="$(jq -c '[.[] | select(.type=="bullet_list")][0].items' <<< "${blocks}")"
  [[ "$(jq -r '.[0]' <<< "${items}")" == "A customer exports an invoice in under 5 seconds." ]]
  [[ "$(jq -r '.[1]' <<< "${items}")" == "Support tickets about missing invoices drop by half." ]]
  # No SC-00N label survives.
  [[ "$(jq -c . <<< "${blocks}")" != *"SC-001"* ]]
}

@test "the epic description gains a named Out of Scope section as a bullet list" {
  run _epic_wrapper "${DOC}"
  [ "$status" -eq 0 ]
  local blocks; blocks="$(jq -c '.epic.description.blocks' <<< "$output")"
  [ "$(jq -r '[.[] | select(.type=="heading" and .text=="Out of Scope")] | length' <<< "${blocks}")" -eq 1 ]
  local items; items="$(jq -c '[.[] | select(.type=="bullet_list")][1].items' <<< "${blocks}")"
  [[ "$(jq -r '.[0]' <<< "${items}")" == *"Refunds."* ]]
  [[ "$(jq -r '.[1]' <<< "${items}")" == *"Bulk import."* ]]
}

@test "the epic description carries no list of user stories (FR-011)" {
  run _epic_wrapper "${DOC}"
  [ "$status" -eq 0 ]
  [[ "$(jq -c '.epic' <<< "$output")" != *"Export a single invoice"* ]]
  [[ "$(jq -c '.epic' <<< "$output")" != *"Bulk export (Priority"* ]]
}

@test "a specification with neither section is unaffected (no empty heading, no error)" {
  local doc; doc=$'# Only A Title\n\nSome prose.\n\n### User Story 1 - A (Priority: P1)\n\nBody.\n'
  run _epic_wrapper "${doc}" "001-x"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.epic.description.blocks[] | select(.type=="heading")] | length' <<< "$output")" -eq 0 ]
}

@test "the PowerShell port extracts the same epic sections (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(printf '%s' "${DOC}" | parse_spec 001-billing | jq -c '.epic')"
  p="$(printf '%s' "${DOC}" | pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/Parse.psm1' -Force
    \$doc = [Console]::In.ReadToEnd()
    [Console]::Out.Write((Get-JiraParsedSpec -Text \$doc -FolderSlug '001-billing'))" | jq -c '.epic')"
  [ "${b}" = "${p}" ]
}
