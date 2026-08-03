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
}

Describe 'Get-JiraMissingBridgeEntry' {
    It 'returns empty for a present-but-non-executable Bash entry point (C6.3)' {
        # PowerShell never had an executable-bit clause (research R4) — this pins
        # the already-correct behaviour rather than reproducing a defect.
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        $fake = Join-Path $work 'fake-root'
        New-Item -ItemType Directory -Path (Join-Path $fake 'scripts/bash') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fake 'scripts/powershell') -Force | Out-Null
        $bashEntry = Join-Path $fake 'scripts/bash/spec-kit-jira.sh'
        Set-Content -LiteralPath $bashEntry -Value '#!/usr/bin/env bash'
        if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod a-x $bashEntry }
        Set-Content -LiteralPath (Join-Path $fake 'scripts/powershell/spec-kit-jira.ps1') -Value ''
        try {
            Get-JiraMissingBridgeEntry -ExtensionRoot $fake | Should -BeExactly ''
        }
        finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
    }
}
