# T010 — Prerequisite-check tests (NFR-4): pwsh 7+, curl/jq/git.
# Mirror of tests/bash/lib/test_prereq.bats. The returned integer is the port's
# exit-equivalent; diagnostics go to the warning stream.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Prereq.psm1') -Force
}

Describe 'Test-JiraPrereq' {
    It 'returns 0 on a fully-provisioned host' {
        Test-JiraPrereq | Should -Be 0
    }

    It 'returns 5 when the PowerShell major version is below 7' {
        Test-JiraPrereq -PwshMajorOverride 5 | Should -Be 5
    }

    It 'names pwsh 7 explicitly on an old PowerShell' {
        Test-JiraPrereq -PwshMajorOverride 5 -WarningVariable warn -WarningAction SilentlyContinue | Out-Null
        ($warn -join "`n") | Should -Match '7'
    }

    It 'returns 5 when a required command is missing' {
        Test-JiraPrereq -ForceMissing @('git') -WarningAction SilentlyContinue | Should -Be 5
    }

    It 'names the missing command in the diagnostic' {
        Test-JiraPrereq -ForceMissing @('git') -WarningVariable warn -WarningAction SilentlyContinue | Out-Null
        ($warn -join "`n") | Should -Match 'git'
    }

    It 'passes on a host without the SecretManagement module — the vault rung is never a prerequisite (T071, Constitution IV v1.3.0)' {
        # This host has no SecretManagement module installed, and Prereq.psm1
        # has no dependency on Credentials.psm1 or Get-Secret — the vault rung
        # cannot block prereq_check because nothing here ever checks for it.
        Get-Command Get-Secret -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Test-JiraPrereq | Should -Be 0
    }
}
