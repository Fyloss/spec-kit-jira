# T045 [US3] — The feature command. Pester twin of
# tests/bash/commands/test_feature.bats (contracts/feature-cli-contract.md).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Feature.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"10201","priority_ids":{"P1":"1","P2":"2","P3":"3"},"estimation_field_id":null}'

    function Write-TeamsConfig {
        $lines = @(
            'projects:', '  - key: IJT', '    epic_strategy: per_repo', '    task_strategy: subtask',
            'routing_default: IJT', 'teams:',
            '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"',
            '  - id: wex', '    project: WEX', '    folder_prefix: "wex-"', '    branch_pattern: "wex-<ID>/<FEATURE_NAME>"'
        )
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
    }

    function Select-Team {
        param([string]$Id)
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: $Id`n")
    }

    function Start-TestMock {
        param([string]$ConfigJson)
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, $ConfigJson)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }

    function Invoke-FeatureCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $code = Invoke-JiraFeature -Arguments $CmdArgs }
        finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }
}

Describe 'Feature command' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        Write-TeamsConfig
        $script:M = $null
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'passes through with {active:false} and zero Jira calls when no team is selected (FR-017)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeFalse
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'stops with a located error on an invalid personal file (exit 4)' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: zzz`n")
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 4
        $r.Err | Should -Match 'personal\.yml'
    }

    It 'attaches a mentioned same-team ticket and computes the names' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team","WEX":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.team | Should -Be 'ijt'
        $obj.ticket.number | Should -Be '42'
        $obj.ticket.action | Should -Be 'attached'
        $obj.branch_name | Should -Be 'ijt-42/invoice-export'
        $obj.short_name | Should -Be 'ijt-invoice-export'
    }

    It 'requires confirmation for a cross-team ticket without --use-team (FR-014)' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team","WEX":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'WEX-7', '--json', 'onboarding')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.confirmation_required.ticket | Should -Be 'WEX-7'
        $obj.confirmation_required.ticket_team | Should -Be 'wex'
        $obj.confirmation_required.selected_team | Should -Be 'ijt'
    }

    It 'confirms the cross-team convention via --use-team, personal file untouched' {
        Select-Team 'ijt'
        $before = [System.IO.File]::ReadAllBytes((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'))
        Start-TestMock '{"projects":{"IJT":"team","WEX":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'WEX-7', '--use-team', 'wex', '--json', 'onboarding')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.team | Should -Be 'wex'
        $obj.branch_name | Should -Be 'wex-7/onboarding'
        [System.IO.File]::ReadAllBytes((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml')) | Should -Be $before
    }

    It 'creates a ticket in the effective team project when none is mentioned (FR-013)' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.ticket.key | Should -Be 'IJT-123'
        $obj.ticket.action | Should -Be 'created'
        $obj.branch_name | Should -Be 'ijt-123/invoice-export'
    }

    It 'falls back non-blocking with exactly one warning when Jira is unreachable (FR-016)' {
        Select-Team 'ijt'
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.active | Should -BeFalse
        @($obj.warnings).Count | Should -Be 1
        @($r.Err -split "`n" | Where-Object { $_ -match '^WARNING:' }).Count | Should -Be 1
    }

    It 'stays fail-closed on a mentioned-key read failure (exit 2)' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'NOPE-1', '--json', 'external')
        $r.ExitCode | Should -Be 2
    }

    It 'predicts would-create in --dry-run with zero writes' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
        $r = Invoke-FeatureCaptured @('feature', '--dry-run', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.ticket.action | Should -Be 'would-create'
        $obj.branch_name | Should -Be $null
        $obj.short_name | Should -Be 'ijt-invoice-export'
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'applies and reports a personal override (FR-012)' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: ijt`noverride:`n  folder_prefix: `"special-`"`n  branch_pattern: `"special-<ID>/<FEATURE_NAME>`"`n")
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.override_used | Should -BeTrue
        $obj.branch_name | Should -Be 'special-42/invoice-export'
    }
}
