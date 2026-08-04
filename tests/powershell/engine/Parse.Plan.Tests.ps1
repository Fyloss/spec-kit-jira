# T089 [Phase 7, US5] — plan.md's summary prose, PowerShell side. Mirror of
# tests/bash/engine/test_parse_plan.bats. Cross-port parity is proven there.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Parse.psm1') -Force

    $script:Plan = @'
# Implementation Plan: Billing Invoices

**Branch**: `001-billing`

## Summary

The sink drops the parent today. This plan makes the parent real.

A second paragraph adds more context.

## Technical Context

Language: Bash and PowerShell.
'@
}

Describe 'Get-JiraParsedPlanSummary' {
    It 'extracts the Summary section as a named heading plus one paragraph per paragraph' {
        $blocks = Get-JiraParsedPlanSummary -Text $script:Plan | ConvertFrom-Json
        @($blocks | Where-Object { $_.type -eq 'heading' -and $_.spans[0].text -eq 'Implementation Plan' }).Count | Should -Be 1
        $paras = @($blocks | Where-Object { $_.type -eq 'paragraph' })
        $paras.Count | Should -Be 2
        $paras[0].spans[0].text | Should -Be 'The sink drops the parent today. This plan makes the parent real.'
        $paras[1].spans[0].text | Should -Be 'A second paragraph adds more context.'
    }

    It 'stops at the next heading (Technical Context never leaks in)' {
        $out = Get-JiraParsedPlanSummary -Text $script:Plan
        $out | Should -Not -Match 'Technical Context'
        $out | Should -Not -Match 'Bash and PowerShell'
    }

    It 'a plan with no Summary section yields no blocks (FR-028)' {
        $plan = "# Implementation Plan: X`n`n## Technical Context`n`nSomething.`n"
        (Get-JiraParsedPlanSummary -Text $plan) | Should -Be '[]'
    }

    It 'empty plan content yields no blocks and no error (a feature folder with no implementation plan)' {
        (Get-JiraParsedPlanSummary -Text '') | Should -Be '[]'
    }
}
