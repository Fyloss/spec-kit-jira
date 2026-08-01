#!/usr/bin/env bats
# T089 [Phase 7, US5] — plan.md's summary prose extracted as neutral content
# blocks: a named heading plus a paragraph per paragraph under `## Summary`
# (data-model.md §7, spec FR-026/FR-027/FR-028).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/parse.sh"
}

_plan_wrapper() {
  printf '%s' "$1" | parse_plan_summary
}

PLAN=$'# Implementation Plan: Billing Invoices\n\n**Branch**: `001-billing`\n\n## Summary\n\nThe sink drops the parent today. This plan makes the parent real.\n\nA second paragraph adds more context.\n\n## Technical Context\n\nLanguage: Bash and PowerShell.\n'

@test "extracts the Summary section as a named heading plus one paragraph per paragraph" {
  run _plan_wrapper "${PLAN}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[] | select(.type=="heading" and .text=="Implementation Plan")] | length' <<< "$output")" -eq 1 ]
  local paras; paras="$(jq -c '[.[] | select(.type=="paragraph")]' <<< "$output")"
  [ "$(jq 'length' <<< "${paras}")" -eq 2 ]
  [[ "$(jq -r '.[0].text' <<< "${paras}")" == "The sink drops the parent today. This plan makes the parent real." ]]
  [[ "$(jq -r '.[1].text' <<< "${paras}")" == "A second paragraph adds more context." ]]
}

@test "stops at the next heading (Technical Context never leaks in)" {
  run _plan_wrapper "${PLAN}"
  [[ "$output" != *"Technical Context"* ]]
  [[ "$output" != *"Bash and PowerShell"* ]]
}

@test "a plan with no Summary section yields no blocks (FR-028)" {
  local plan; plan=$'# Implementation Plan: X\n\n## Technical Context\n\nSomething.\n'
  run _plan_wrapper "${plan}"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "empty plan content yields no blocks and no error (a feature folder with no implementation plan)" {
  run _plan_wrapper ""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "the PowerShell port extracts the same plan blocks (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(printf '%s' "${PLAN}" | parse_plan_summary)"
  p="$(printf '%s' "${PLAN}" | pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/Parse.psm1' -Force
    \$doc = [Console]::In.ReadToEnd()
    [Console]::Out.Write((Get-JiraParsedPlanSummary -Text \$doc))")"
  [ "${b}" = "${p}" ]
}
