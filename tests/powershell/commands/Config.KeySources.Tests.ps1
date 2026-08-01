# T022 [US2] — Project-key sourcing in a connected run (FR-004/FR-005/FR-006).
# Pester twin of tests/bash/commands/test_config_key_sources.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Write-TestConfig {
        param([string]$Key)
        $lines = @('projects:', "  - key: $Key", "routing_default: $Key")
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
    }

    function Start-TestMock {
        param([string]$ConfigJson)
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, $ConfigJson)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }

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

Describe 'Config key sourcing' {
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

    It 'binds a positional PROJECT_KEY validated by the first discovery read' {
        Write-TestConfig 'PROJ'
        Start-TestMock '{"projects":{"TEAM":"team"}}'
        $r = Invoke-ConfigCaptured @('config', 'TEAM', '--json')
        $r.ExitCode | Should -Be 0
        $local = (ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | ConvertFrom-Json
        $local.resolved_ids.TEAM | Should -Not -BeNullOrEmpty
    }

    It 'fails closed on an unknown key with no substitution (FR-006)' {
        Write-TestConfig 'PROJ'
        Start-TestMock '{"projects":{"TEAM":"team"},"faults":{"NOPE":{"status":404}}}'
        $r = Invoke-ConfigCaptured @('config', 'NOPE', '--json')
        $r.ExitCode | Should -Be 2
        (Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
    }

    It 'treats the literal PROJ placeholder as unset and describes the closed-question path (FR-005)' {
        Write-TestConfig 'PROJ'
        Start-TestMock '{"projects":{"COMP":"company","TEAM":"team"}}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 4
        $r.Err | Should -Match 'no usable project key'
        $r.Err | Should -Match 'COMP'
        $r.Err | Should -Match 'TEAM'
        (Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
    }

    It 'binds a committed non-placeholder key without an argument' {
        Write-TestConfig 'TEAM'
        Start-TestMock '{"projects":{"TEAM":"team"}}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $local = (ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | ConvertFrom-Json
        $local.resolved_ids.TEAM | Should -Not -BeNullOrEmpty
    }
}
