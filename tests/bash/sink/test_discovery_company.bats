#!/usr/bin/env bats
# T033/T037 [US2] — Company-managed (classic) discovery.
#
# Style is detected FIRST (research §1); the per-style, scheme-based path then
# discovers issue types, statuses + categories, priorities, fields, the ranked
# estimation candidates, and the flagged field (research §2/§15). Every value is
# carried by LOGICAL name, resolved from the API — no literal Atlassian default
# is compiled in (Constitution VII). The PowerShell port must emit a byte-
# identical binding for identical inputs (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/discovery.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

boot() {
  # backend defaults to the curl shim; the NFR-1 cross-port test below opts
  # into the real pwsh server, since a native pwsh HTTP client cannot reach
  # the shim's sentinel MOCK_BASE_URL (contracts/mock-driver.md).
  mock_start "${MOCK}/configs/default.json" "${1:-bash}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "detects the classic project style as company_managed (research §1)" {
  boot
  run discover_binding COMP
  [ "$status" -eq 0 ]
  [ "$(jq -r .style <<< "$output")" = "company_managed" ]
}

@test "the style call is the FIRST Jira call (detect style before anything)" {
  boot
  discover_binding COMP > /dev/null
  run mock_calls
  first="$(printf '%s\n' "$output" | head -n1)"
  [ "$first" = "GET /rest/api/3/project/COMP" ]
}

@test "discovers issue types with hierarchy levels from createmeta (research §2)" {
  boot
  run discover_binding COMP
  [ "$(jq -r '.issue_types | length' <<< "$output")" -eq 5 ]
  [ "$(jq -r '.issue_types[] | select(.logical_name=="Initiative") | .id' <<< "$output")" = "10100" ]
  [ "$(jq -r '.issue_types[] | select(.logical_name=="Initiative") | .hierarchy_level' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.issue_types[] | select(.logical_name=="Sub-task") | .subtask' <<< "$output")" = "true" ]
}

@test "seeds status categories from statusCategory (research §4)" {
  boot
  run discover_binding COMP
  [ "$(jq -r '.statuses | length' <<< "$output")" -eq 5 ]
  [ "$(jq -r '.statuses[] | select(.name=="Backlog") | .status_category' <<< "$output")" = "new" ]
  [ "$(jq -r '.statuses[] | select(.name=="Building") | .status_category' <<< "$output")" = "indeterminate" ]
  [ "$(jq -r '.statuses[] | select(.name=="Shipped") | .status_category' <<< "$output")" = "done" ]
}

@test "ranks the project's own estimation field, never a global default (research §3)" {
  boot
  run discover_binding COMP
  [ "$(jq -r '.estimation_candidates[0].id' <<< "$output")" = "customfield_20011" ]
  [ "$(jq -r '.estimation_candidates[0].logical_name' <<< "$output")" = "T-Shirt Estimate" ]
  # The candidate is proposed with a score, never silently assumed.
  [ "$(jq -r '.estimation_candidates[0].score' <<< "$output")" -gt 0 ]
}

@test "discovers the flagged field by shape, not an assumed id (research §15)" {
  boot
  run discover_binding COMP
  [ "$(jq -r '.flagged_field.id' <<< "$output")" = "customfield_20044" ]
  [ "$(jq -r '.flagged_field.logical_name' <<< "$output")" = "Impediment" ]
}

@test "discovers priorities by logical name" {
  boot
  run discover_binding COMP
  [ "$(jq -r '.priorities | length' <<< "$output")" -eq 4 ]
  [ "$(jq -r '.priorities[0].logical_name' <<< "$output")" = "Critical" ]
}

@test "a fail-closed read (404) yields the mapped exit code and zero output" {
  mock_start "${MOCK}/configs/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run discover_binding MISSING
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "the PowerShell port emits a byte-identical binding (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  boot powershell
  run discover_binding COMP
  [ "$status" -eq 0 ]
  local bash_out="$output"
  local ps_out
  ps_out="$(SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    pwsh -NoProfile -Command "
      Import-Module '${PS_SINK}/Discovery.psm1' -Force
      [Console]::Out.Write((Get-JiraDiscoveryBinding -ProjectKey 'COMP'))
    ")"
  [ "$bash_out" = "$ps_out" ]
}
