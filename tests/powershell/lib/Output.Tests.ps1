# T016 — Run-summary rendering, PowerShell side.
# Mirror of tests/bash/lib/test_output.bats. Cross-port byte-parity proven in bats.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Output.psm1') -Force
}

Describe 'New-JiraSummaryJson' {
    It 'emits canonical JSON with required keys' {
        $json = New-JiraSummaryJson -Command reconcile -Created 1 -Updated 2 -ExitCode 0
        $o = $json | ConvertFrom-Json
        $o.schema_version | Should -Be '1.0'
        $o.command | Should -Be 'reconcile'
        $o.counts.created | Should -Be 1
        $o.counts.updated | Should -Be 2
        $o.exit_code | Should -Be 0
    }

    It 'sorts keys canonically (command first)' {
        (New-JiraSummaryJson -Command config) | Should -Match '^\{"command":'
    }
}

Describe 'ConvertTo-JiraSummaryProse' {
    It 'shows counts and exit' {
        $json = New-JiraSummaryJson -Command reconcile -Created 1 -Updated 2 -Skipped 3
        $prose = ConvertTo-JiraSummaryProse $json
        $prose | Should -Match 'reconcile'
        $prose | Should -Match 'Created: 1'
        $prose | Should -Match 'Updated: 2'
        $prose | Should -Match 'Exit: 0'
    }

    It 'marks a dry-run in the prose' {
        $json = New-JiraSummaryJson -Command reconcile -DryRun $true
        (ConvertTo-JiraSummaryProse $json) | Should -Match 'dry-run'
    }
}
