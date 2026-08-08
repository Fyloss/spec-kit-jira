# T092 — Dedicated SC-007 leak test (ELIMINATORY NFR-3), PowerShell side. Mirror of
# tests/bash/lib/test_token_leak.bats. Drives the full dispatcher at maximum
# verbosity (-Verbose) as a child process, folding every stream into one capture,
# and asserts the resolved token never appears anywhere.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $script:Entry = Join-Path $Root 'scripts/powershell/spec-kit-jira.ps1'
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
        # Every variable the BeforeEach set, cleared. Pester shares ONE process
        # across the whole suite, so anything left here is inherited by every
        # later file and by every child process those files spawn. This block
        # once leaked SPEC_KIT_JIRA_PROJECT_KEY=PROJ — the shipped placeholder
        # — into tests/powershell/conformance, where four scenarios then
        # refused with the placeholder-key message instead of mirroring. It was
        # invisible on hosts that discover commands/ (whose Reconcile.* files
        # scrub that variable) after lib/, and red on the ones that do not.
        foreach ($name in @(
                'JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_NO_SLEEP', 'JIRA_MAX_ATTEMPTS',
                'SPEC_KIT_JIRA_SPEC_SLUG', 'SPEC_KIT_JIRA_PROJECT_KEY', 'SPEC_KIT_JIRA_BASE_URL',
                'SPEC_KIT_JIRA_TIMING')) {
            Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
        }
    }

    It 'never surfaces the token in a full reconcile at max verbosity (SC-007)' {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $pwshPath = (Get-Process -Id $PID).Path
        $out = & $pwshPath -NoProfile -File $Entry reconcile --verbose --json $Spec *>&1 | Out-String
        $out | Should -Not -Match 'RAWSECRETXYZ0123456789'
    }

    It 'T010 — neither the token nor its base64 Authorization value leaks with timing and tracing both on (contracts/timing-report.md T7)' {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $env:SPEC_KIT_JIRA_TIMING = '1'
        $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($env:JIRA_EMAIL):$($env:JIRA_API_TOKEN)"))
        $pwshPath = (Get-Process -Id $PID).Path
        $out = & $pwshPath -NoProfile -File $Entry reconcile --verbose --json $Spec *>&1 | Out-String
        $out | Should -Not -Match 'RAWSECRETXYZ0123456789'
        $out | Should -Not -Match ([regex]::Escape($basic))
        $out | Should -Match 'timing: '
    }

    It 'T040 — neither the raw token nor its base64 Authorization value is written anywhere in the post-run tree, including the state document' {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $MockDir 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($env:JIRA_EMAIL):$($env:JIRA_API_TOKEN)"))
        $pwshPath = (Get-Process -Id $PID).Path
        & $pwshPath -NoProfile -File $Entry reconcile --json $Spec *>&1 | Out-Null
        $hits = Get-ChildItem -Path $Work -Recurse -File | Select-String -Pattern 'RAWSECRETXYZ0123456789', ([regex]::Escape($basic))
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'T076 — the existing credential scan covers the new hierarchy key (010, FR-003)' {
    BeforeAll {
        Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    }

    It 'refuses a token-shaped value under projects[].hierarchy.story, exit 4, never echoed' {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    hierarchy:`n      story: ATATT3xFfGF0secrettoken`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'credential'
        ($r.Errors -join "`n") | Should -Not -Match 'ATATT3xFfGF0secrettoken'
        Remove-Item -Recurse -Force $d
    }

    It 'refuses a host-shaped value under projects[].hierarchy.story, exit 4' {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    hierarchy:`n      story: acme.atlassian.net`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'credential'
        Remove-Item -Recurse -Force $d
    }
}
