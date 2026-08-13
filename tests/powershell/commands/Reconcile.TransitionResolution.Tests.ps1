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

    It 'T110 -- an ambiguous or gated outcome never suppresses that ticket''s own content update, and never suppresses another ticket''s move (U2/U3)' {
        # A genuine content diff for COMP-3 and COMP-4's own stories --
        # otherwise their PUT is zero-churn (unchanged since BeforeEach's
        # own creation run) and this test would prove nothing about
        # content survival.
        $content = (Get-Content -Raw -LiteralPath $script:Spec) `
            -replace 'export every invoice in a date range', 'export every invoice in a date range as a bundle' `
            -replace 'a clear message when export is temporarily unavailable', 'a clear message when export is temporarily unavailable for maintenance'
        Set-Content -NoNewline -Path $script:Spec -Value $content

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        # COMP-3 (ambiguous) and COMP-4 (gated) still receive their content PUT.
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-3') -and $_.method -eq 'PUT' }).Count | Should -Be 1
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-4') -and $_.method -eq 'PUT' }).Count | Should -Be 1
        # COMP-2's own move (a clean outcome) still fires in the SAME run --
        # neither COMP-3's ambiguous nor COMP-4's gated outcome suppresses it.
        $t = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-2/transitions') })
        $t.Count | Should -Be 1
        [string]$t[0].body.transition.id | Should -Be '101'
    }

    It 'T112 -- an exhausted availability read fails closed for the WHOLE specification, zero content writes, exit code F2 (contract §2)' {
        # BeforeEach's own $script:Spec already carries real markers
        # recorded against BeforeEach's own mock instance -- restarting the
        # mock (fresh, blank state) against that SAME file would refuse as
        # an unrecognised identity, not exercise the fault this test is
        # about. A genuinely fresh work directory keeps this test's own
        # mock instance the only one its markers were ever recorded
        # against.
        Stop-JiraMock -Mock $script:M
        $work2 = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work2
        $spec2 = Join-Path $work2 'specs/001-billing-invoices/spec.md'
        Copy-Item -Path (Join-Path $script:Work '.specify/jira/config.yml') -Destination (Join-Path $work2 '.specify/jira/config.yml') -Force
        $env:JIRA_CONFIG_DIR = Join-Path $work2 '.specify/jira'

        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"transitions":{"COMP-2":[{"id":"101","name":"Start","to":{"name":"In Progress"},"fields":{}}]},"faults":{"issue/COMP-2/transitions":{"status":400}}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $spec2, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        $out = ''
        try { $out = Invoke-Captured @('reconcile', $spec2, '--json') } finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        [int]$script:code | Should -Be 2
        $out | Should -Match 'COMP-2'
        # Fail-closed for the WHOLE specification -- not even the OTHER
        # tickets' already-decided content writes reach the tracker (reads
        # -- recognition's own bulkfetch prefetch, and the failing
        # availability read itself -- are not writes, and are expected).
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -notmatch 'bulkfetch' -and $_ -notmatch 'transitions\?expand' }).Count | Should -Be 0
    }
}
