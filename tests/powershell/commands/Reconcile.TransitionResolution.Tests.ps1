# T033/T040a [Phase 4, US1] — a declared step actually moves a ticket, end
# to end through reconcile, PowerShell side. Mirror of
# tests/bash/commands/test_reconcile_transition_resolution.bats. This is
# the failing test the whole feature turned green (quickstart §1).

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    $script:ConfigYaml = @'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
'@

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out
        $oe = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
        return $sw.ToString() + $se.ToString()
    }
}

Describe 'Invoke-JiraReconcile — a declared step actually moves a ticket' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        Set-Content -NoNewline -Path (Join-Path $script:Work '.specify/jira/config.yml') -Value $script:ConfigYaml
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/comp-transitions.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'an ungated declared step actually moves the ticket, once, and counts it' {
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        $transitionAction = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-2/transitions') })
        $transitionAction.Count | Should -Be 1
        [string]$transitionAction[0].body.transition.id | Should -Be '101'
        [int]$r.counts.transitioned | Should -BeGreaterOrEqual 1
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^GET /rest/api/3/issue/COMP-2/transitions' }).Count | Should -Be 1
    }

    It 'two candidates onto the declared step move nothing and warn, naming both' {
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-3/transitions') }).Count | Should -Be 0
        (@($r.warnings) -join ' ') | Should -Match 'COMP-3'
    }

    It 'a gated declared step moves nothing and names the withheld field' {
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-4/transitions') }).Count | Should -Be 0
        (@($r.warnings) -join ' ') | Should -Match 'Resolution'
    }

    It 'a second run under the same event moves nothing more — idempotent (Z2)' {
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
            Clear-Content -LiteralPath $script:M.CallLog
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        [int]$r.counts.transitioned | Should -Be 0
    }

    It 'a ticket already at its declared step asks the tracker nothing about it' {
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
            Clear-Content -LiteralPath $script:M.CallLog
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^GET /rest/api/3/issue/COMP-2/transitions' }).Count | Should -Be 0
        (@($r.warnings) -join ' ') | Should -Not -Match 'COMP-2'
    }
}
