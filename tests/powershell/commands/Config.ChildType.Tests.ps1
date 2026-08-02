# T038 [Phase 4, US1] — mirror of tests/bash/commands/test_config_child_type.bats.
# The ceremony's child-type closed question (research R1/R2, contract §2):
# derived when the child level holds one candidate; asked (--child-type) and
# recorded operator when it holds several.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Write-TestConfig {
        param([string]$Key)
        $lines = @('projects:', "  - key: $Key", "routing_default: $Key")
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
    }

    function Invoke-ConfigCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($sw)
        try { $code = Invoke-JiraConfig -Arguments $CmdArgs }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }

    function Read-LocalBinding {
        (ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | ConvertFrom-Json
    }
}

Describe 'Config child-type resolution' {
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

    It 'derives the child type when the level holds one candidate (SAFe: Story alone)' {
        Write-TestConfig 'SAFE'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/safe.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        $local = Read-LocalBinding
        $local.resolved_ids.SAFE.child_type.logical_name | Should -Be 'Story'
        $local.resolved_ids.SAFE.child_type.source | Should -Be 'derived'
        $local.resolved_ids.SAFE.parent_type.logical_name | Should -Be 'Feature'
    }

    It 'asks (via --child-type) when the level holds several candidates (company: Story vs Defect)' {
        Write-TestConfig 'COMP'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match 'the story level'
        $r.Out | Should -Match 'holds more than one issue type'

        $r2 = Invoke-ConfigCaptured @('config', '--child-type', 'COMP=Defect', '--json')
        $r2.ExitCode | Should -Be 0
        $local = Read-LocalBinding
        $local.resolved_ids.COMP.child_type.logical_name | Should -Be 'Defect'
        $local.resolved_ids.COMP.child_type.source | Should -Be 'operator'
    }

    It 'an unrecognised --child-type answer refuses, naming the candidates' {
        Write-TestConfig 'COMP'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r = Invoke-ConfigCaptured @('config', '--child-type', 'COMP=Epic', '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match 'which this project does not offer at that tier'
    }
}
