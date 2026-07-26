# T024 [US2] — Degraded mode: loud, provisional, write-free (FR-008/FR-009).
# Pester twin of tests/bash/commands/test_config_degraded.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Config.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_NO_SLEEP = '1'

    function Invoke-ConfigCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $code = Invoke-JiraConfig -Arguments $CmdArgs }
        finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }
}

Describe 'Config degraded mode' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $lines = @('projects:', '  - key: TEAM', '    epic_strategy: per_repo', '    task_strategy: subtask', 'routing_default: TEAM')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        Push-Location $Work
        git init -q -b main
        git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
        git branch 'ijt-12/invoice-export'
        git branch 'wex-3/onboarding'
        git branch 'feature/unrelated'
        $script:M = $null
    }
    AfterEach {
        Pop-Location
        if ($M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'degrades on a missing base URL: exit 0, one warning, provisional proposals, zero writes' {
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        @($r.Err -split "`n" | Where-Object { $_ -match '^WARNING:' }).Count | Should -Be 1
        $r.Err | Should -Match 'SPEC_KIT_JIRA_BASE_URL'
        $obj = $r.Out.Trim() | ConvertFrom-Json
        @($obj.provisional).Count | Should -Be 2
        $obj.provisional[0].team_prefix | Should -Be 'ijt'
        $obj.provisional[0].provisional | Should -BeTrue
        $obj.provisional[1].team_prefix | Should -Be 'wex'
        $obj.rerun_guidance | Should -Not -BeNullOrEmpty
        $obj.effects.discovery.status | Should -Be 'skipped'
        (Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
        (Test-Path (Join-Path $Work '.specify/extensions.yml')) | Should -BeFalse
        (Test-Path (Join-Path $Work 'README.md')) | Should -BeFalse
    }

    It 'leaves an existing config.local.yml byte-identical (FR-009)' {
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $localf = Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml'
        [System.IO.File]::WriteAllText($localf, "site_alias: prod`n")
        $before = [System.IO.File]::ReadAllBytes($localf)
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        [System.IO.File]::ReadAllBytes($localf) | Should -Be $before
    }

    It 'never degrades on defined-but-wrong credentials: auth exit (research §4)' {
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, '{"fault":{"status":401}}')
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $env:JIRA_API_TOKEN = 'WRONGTOKEN'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 3
        (Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
    }

    It 'performs zero Jira calls in a degraded run' {
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, '{"projects":{"TEAM":"team"}}')
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }
}
