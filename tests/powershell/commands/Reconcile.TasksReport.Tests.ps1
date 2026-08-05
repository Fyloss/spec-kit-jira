# T075-T077 [US4] — tasks that belong to no user story are reported, never
# invented into Jira: an unattributed task (FR-028), a dangling one attributed
# to a story ordinal the specification does not contain (FR-004), and both
# collapsing to one WARNING when the run fires inside a lifecycle hook
# (FR-026). Mirror of tests/bash/commands/test_reconcile_tasks_report.bats.
# Cross-port parity is proven in bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-task-tier'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue

    function Invoke-Captured {
        # Mirrors bats' `run`: stdout and stderr merged into one string, since
        # WARNING lines (FR-016) are written to stderr, not the --json summary.
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

Describe 'Invoke-JiraReconcile — unattributed and dangling task reporting' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $script:Tasks = Join-Path $script:Work 'specs/001-feature/tasks.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"TASKP":"t"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }

    It 'T075 — an unattributed task is never mirrored and is named individually by task_ref with its reason (FR-028)' {
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $r = $out | ConvertFrom-Json
        $r.counts.tasks.created | Should -Be 1
        $r.counts.tasks.skipped | Should -Be 1
        $note = $r.notes | Where-Object { $_ -like 'T001 *' }
        $note | Should -Not -BeNullOrEmpty
        $note | Should -Match 'no story attribution'
        $note | Should -Match 'not mirrored'
        $calls = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' })
        $calls.Count | Should -Be 3
    }

    It 'T076 — a task attributed to a story ordinal the specification does not contain creates nothing, is reported, and every other task still mirrors (FR-004)' {
        Add-Content -LiteralPath $script:Tasks -Value "`n- [ ] T003 [US9] A dangling task"
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $r = $out | ConvertFrom-Json
        $r.counts.tasks.created | Should -Be 1
        $r.counts.tasks.skipped | Should -Be 2
        $note = $r.notes | Where-Object { $_ -like 'T003 *' }
        $note | Should -Not -BeNullOrEmpty
        $note | Should -Match 'User Story 9'
        $note | Should -Match 'does not contain'
        $note | Should -Match 'not mirrored'
        $calls = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' })
        $calls.Count | Should -Be 3
        (Get-Content -Raw -LiteralPath $script:Tasks) | Should -Match 'task=.*ticket=TASKP-3'
    }

    It 'T077 — under a lifecycle hook, the unattributed and dangling reports collapse to one WARNING and the host command still succeeds (FR-026)' {
        Add-Content -LiteralPath $script:Tasks -Value "`n- [ ] T003 [US9] A dangling task"
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $script:code | Should -Be 0
        @([regex]::Matches($out, 'WARNING:')).Count | Should -Be 1
        $jsonLine = ($out -split "`n" | Where-Object { $_ -match '^\{' }) -join "`n"
        $r = $jsonLine | ConvertFrom-Json
        $r.counts.tasks.skipped | Should -Be 2
    }
}
