# T078 [US2] — Connected-run mismatch surfacing (FR-009). Pester twin of
# tests/bash/commands/test_config_team_mismatch.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Config.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Write-TestConfig {
        param([bool]$Teams = $true)
        $lines = @('projects:', '  - key: IJT', 'routing_default: IJT')
        if ($Teams) {
            $lines += @('teams:',
                '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"',
                '  - id: wex', '    project: WEX', '    folder_prefix: "wex-"', '    branch_pattern: "wex-<ID>/<FEATURE_NAME>"')
        }
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

Describe 'Connected-run team mismatch surfacing' {
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

    It 'warns once per catalogue team whose project is not accessible (FR-009)' {
        Write-TestConfig -Teams $true
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        @($r.Err -split "`n" | Where-Object { $_ -match '^WARNING:' }).Count | Should -Be 1
        $r.Err | Should -Match "team 'wex'"
        ($r.Out.Trim() | ConvertFrom-Json).counts.warnings | Should -Be 1
        (Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeTrue
    }

    It 'emits zero warnings when every catalogue team is accessible' {
        Write-TestConfig -Teams $true
        Start-TestMock '{"projects":{"IJT":"team","WEX":"team"}}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        @($r.Err -split "`n" | Where-Object { $_ -match '^WARNING:' }).Count | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).counts.warnings | Should -Be 0
    }

    It 'performs no project/search call without a catalogue' {
        Write-TestConfig -Teams $false
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-ConfigCaptured @('config', '--json')
        $r.ExitCode | Should -Be 0
        (Get-JiraMockCallLog -Mock $M) -join "`n" | Should -Not -Match 'project/search'
    }
}
