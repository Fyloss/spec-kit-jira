# T092 — Dedicated SC-007 leak test (ELIMINATORY NFR-3), PowerShell side. Mirror of
# tests/bash/lib/test_token_leak.bats. Drives the full dispatcher at maximum
# verbosity (-Verbose) as a child process, folding every stream into one capture,
# and asserts the resolved token never appears anywhere.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $script:Entry = Join-Path $Root '.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1'
    $script:MockDir = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
}

Describe 'Credential leak guard (SC-007)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        $script:Spec = Join-Path $Work 'spec.md'
        @(
            '# Feature Specification: Leak Guard', '', 'A spec that mirrors to Jira.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a user', '- **When** they act', '- **Then** it works'
        ) -join "`n" | Set-Content -LiteralPath $Spec -NoNewline
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ0123456789'
        $env:JIRA_NO_SLEEP = '1'
        $env:JIRA_MAX_ATTEMPTS = '1'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'PROJ'
        $script:Mock = $null
    }
    AfterEach {
        if ($script:Mock) { Stop-JiraMock -Mock $script:Mock }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'never surfaces the token in a full reconcile at max verbosity (SC-007)' {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $pwshPath = (Get-Process -Id $PID).Path
        $out = & $pwshPath -NoProfile -File $Entry reconcile --verbose --json $Spec *>&1 | Out-String
        $out | Should -Not -Match 'RAWSECRETXYZ0123456789'
    }
}
