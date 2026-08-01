# T077 [US8] — Incremental re-bind + per-project identity scope, PowerShell side.
# Mirror of tests/bash/commands/test_config_incremental.bats. Cross-port byte
# agreement is proven in bats; here we assert the incremental semantics: adding a
# project binds ONLY that one and leaves existing mappings untouched (FR-043); each
# project's ids are scoped under its own key so two projects never collide (FR-044).

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

    $script:CompProject = @'
  - key: COMP
    style: company_managed
'@ + "`n"
    $script:TeamProject = @'
  - key: TEAM
    style: team_managed
'@ + "`n"
    function Write-TeamConfig([string] $Projects) {
        $body = "projects:`n" + $Projects + "routing_default: `"COMP`"`n"
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), $body, (New-Object System.Text.UTF8Encoding($false)))
    }
    function Invoke-ConfigSilently {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--child-type', 'TEAM=Story', '--json')) }
        finally { [Console]::SetOut($orig) }
    }
    function Get-LocalObject {
        return (ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | ConvertFrom-Json
    }
}

Describe 'Config incremental re-bind' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $M
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'adds a project without touching an existing mapping (FR-043)' {
        Write-TeamConfig $CompProject
        Invoke-ConfigSilently
        $before = Get-LocalObject
        ($before.resolved_ids.COMP.issue_types | Where-Object { $_.logical_name -eq "Story" }).id | Should -Be '10102'
        ($before.resolved_ids.PSObject.Properties.Name -contains 'TEAM') | Should -BeFalse
        $compBefore = $before.resolved_ids.COMP | ConvertTo-Json -Depth 20 -Compress

        Write-TeamConfig ($CompProject + $TeamProject)
        Invoke-ConfigSilently
        $after = Get-LocalObject
        ($after.resolved_ids.PSObject.Properties.Name -contains 'TEAM') | Should -BeTrue
        ($after.resolved_ids.COMP | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $compBefore
    }

    It 'scopes each project under its own key so two projects never collide (FR-044)' {
        Write-TeamConfig ($CompProject + $TeamProject)
        Invoke-ConfigSilently
        $obj = Get-LocalObject
        ($obj.resolved_ids.COMP.issue_types | Where-Object { $_.logical_name -eq "Story" }).id | Should -Be '10102'
        ($obj.resolved_ids.TEAM.issue_types | Where-Object { $_.logical_name -eq "Story" }).id | Should -Not -BeNullOrEmpty
        ($obj.resolved_ids.COMP.issue_types | Where-Object { $_.logical_name -eq "Story" }).id | Should -Not -Be ($obj.resolved_ids.TEAM.issue_types | Where-Object { $_.logical_name -eq "Story" }).id
    }
}
