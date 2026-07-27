# T008 [US1] — Style resolution in the config ceremony (FR-001/FR-002/FR-003).
# Pester twin of tests/bash/commands/test_config_style.bats: api signal ->
# operator (--style / committed declaration) -> fail closed exit 4 with zero
# writes; committed-vs-API conflict re-enters the ambiguous branch; the summary
# audits style + style_source per project.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $script:Mock = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Write-TestConfig {
        param([string]$Key, [string]$Style = '')
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('projects:')
        $lines.Add("  - key: $Key")
        if ($Style) { $lines.Add("    style: $Style") }
        $lines.Add('    epic_strategy: per_repo')
        $lines.Add('    task_strategy: subtask')
        $lines.Add("routing_default: $Key")
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
    }

    function Start-TestMock {
        param([string]$ProjectsJson)
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, "{`"projects`":$ProjectsJson}")
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }

    function Invoke-ConfigCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $code = Invoke-JiraConfig -Arguments $CmdArgs }
        finally { [Console]::SetOut($orig) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }

    function Read-LocalBinding {
        (ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | ConvertFrom-Json
    }
}

Describe 'Config style resolution matrix' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = $null
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'treats a bad --style value as a usage error (exit 1)' {
        Write-TestConfig 'AMBI'
        $r = Invoke-ConfigCaptured @('config', '--style', 'AMBI=weird', '--json')
        $r.ExitCode | Should -Be 1
    }

    It 'persists an unambiguous API signal with style_source api' {
        Write-TestConfig 'TEAM'
        Start-TestMock '{"TEAM":"team"}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $local = Read-LocalBinding
        $local.resolved_ids.TEAM.style | Should -Be 'team_managed'
        $local.resolved_ids.TEAM.style_source | Should -Be 'api'
    }

    It 'fails closed on ambiguity without --style: exit 4, zero writes' {
        Write-TestConfig 'AMBI'
        Start-TestMock '{"AMBI":"ambiguous"}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 4
        (Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
        (Test-Path (Join-Path $Work '.specify/extensions.yml')) | Should -BeFalse
        (Test-Path (Join-Path $Work 'README.md')) | Should -BeFalse
    }

    It 'resolves ambiguity via --style with style_source operator' {
        Write-TestConfig 'AMBI'
        Start-TestMock '{"AMBI":"ambiguous"}'
        $r = Invoke-ConfigCaptured @('config', '--style', 'AMBI=team_managed', '--json')
        $r.ExitCode | Should -Be 0
        $local = Read-LocalBinding
        $local.resolved_ids.AMBI.style | Should -Be 'team_managed'
        $local.resolved_ids.AMBI.style_source | Should -Be 'operator'
    }

    It 'resolves an ambiguous payload from a committed declaration as operator' {
        Write-TestConfig 'AMBI' 'team_managed'
        Start-TestMock '{"AMBI":"ambiguous"}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $local = Read-LocalBinding
        $local.resolved_ids.AMBI.style | Should -Be 'team_managed'
        $local.resolved_ids.AMBI.style_source | Should -Be 'operator'
    }

    It 'treats a committed style conflicting with an unambiguous API signal as ambiguous' {
        Write-TestConfig 'TEAM' 'company_managed'
        Start-TestMock '{"TEAM":"team"}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 4
        (Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
    }

    It 'audits style + style_source per project in the run summary (FR-003)' {
        Write-TestConfig 'TEAM'
        Start-TestMock '{"TEAM":"team"}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.effects.discovery.projects.TEAM.style | Should -Be 'team_managed'
        $obj.effects.discovery.projects.TEAM.style_source | Should -Be 'api'
    }

    It 'audits style + style_source in the DEFAULT (prose) summary (FR-003, T098)' {
        # FR-003 asks the run summary to state the provenance so a wrong binding
        # can be audited; prose is the default output, so --json must not be the
        # only way to see it.
        Write-TestConfig 'TEAM'
        Start-TestMock '{"TEAM":"team"}'
        $r = Invoke-ConfigCaptured @('config')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeLike '*    TEAM: team_managed (api)*'
    }

    It 'reports operator provenance in the prose audit too (FR-003, T098)' {
        Write-TestConfig 'AMBI'
        Start-TestMock '{"AMBI":"ambiguous"}'
        $r = Invoke-ConfigCaptured @('config', '--style', 'AMBI=team_managed')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeLike '*    AMBI: team_managed (operator)*'
    }
}
