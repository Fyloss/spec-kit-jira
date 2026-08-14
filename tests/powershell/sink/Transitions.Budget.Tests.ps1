# T147/T149/T156 [Phase 11, US9] — budgets B1-B3 (contract transition-
# resolution.md §1/§2, 024 spawn-budget.md §4). Mirror of
# tests/bash/sink/test_transitions_budget.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-bound-story-due'
    $Fixture60 = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-sixty-stories-due'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

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

Describe 'Invoke-JiraReconcile — availability-read budgets (B1/B2)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-declared-mapping/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-declared-mapping'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/comp-bound-story-due-seed.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'B1 (D1) -- no hook event: zero availability requests' {
        Clear-Content -LiteralPath $script:M.CallLog
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'transitions' }).Count | Should -Be 0
    }

    It 'B1 (D4) -- already at the declared step: zero availability requests' {
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
        try { $null = Invoke-Captured @('reconcile', $script:Spec, '--json') } finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
        try { $null = Invoke-Captured @('reconcile', $script:Spec, '--json') } finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'transitions' }).Count | Should -Be 0
    }

    It 'B1 (D5, Flagged) -- an impediment-marked ticket costs zero availability requests' {
        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" `
            -ContentType 'application/json' `
            -Body '{"fields":{"Flagged":[{"value":"Impediment"}]}}' | Out-Null
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try { $null = Invoke-Captured @('reconcile', $script:Spec, '--json') } finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'transitions' }).Count | Should -Be 0
    }
}

Describe 'Invoke-JiraReconcile — round-trip budget at scale (B2)' {
    It 'B2 -- under branch C, requests grow with the DUE set, never with unqualifying tickets outside it' {
        # 60 stories are all due; the round-trip count is exactly 60 (one GET
        # per due ticket, branch C's own budget -- research R1) never 61 (the
        # parent, which is NOT due this event) and never some multiple of 60.
        $work60 = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture60 $work60
        $spec60 = Join-Path $work60 'specs/001-widget/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work60 '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-widget'
        $m = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/tasks-sixty-transitions.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $m.BaseUrl
        try {
            $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
            $r = Invoke-Captured @('reconcile', $spec60, '--json') | ConvertFrom-Json
            [int]$r.counts.transitioned | Should -Be 60
            @(Get-JiraMockCallLog -Mock $m | Where-Object { $_ -match '^GET .*/transitions\?expand=' }).Count | Should -Be 60
        }
        finally {
            Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
            Stop-JiraMock -Mock $m
        }
    }
}

# B3 (024 spawn-budget.md §4, C4.2 — external-process count unchanged when
# the due set doubles): PATH-interposed process counting has no PowerShell
# equivalent test in this repo for ANY prior feature (024 included) — every
# structured operation Invoke-JiraReconcile performs (ConvertFrom-Json,
# ConvertTo-Json, string building) runs IN-PROCESS on this port; there is no
# per-ticket external tool this due-set loop could spawn N times the way the
# bash port's per-key `jq`/`json_canonical` calls could. B3 is therefore
# vacuously satisfied by construction on this port — T156 records that
# verification here rather than adding a counting test with nothing to count.
