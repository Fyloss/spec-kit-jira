# T013/T013b [Phase 2, 022] — mirror of tests/bash/commands/test_reconcile_task_mirror_gate.bats.

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

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }

    function Add-TaskMirrorChecklist {
        Add-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -Value "task_mirror:`n  TASKP: checklist`n"
    }
}

Describe 'Invoke-JiraReconcile — the task-tier gate split' {
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
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'checklist mode reads tasks.md and names an unattributed task, same as subtask mode (FR-022)' {
        Add-TaskMirrorChecklist
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $out | Should -Match 'T001'
        $out | Should -Match 'carries no story attribution'
    }

    It 'checklist mode assigns no durable identifier into tasks.md (FR-031)' {
        Add-TaskMirrorChecklist
        $before = Get-Content -Raw -LiteralPath $script:Tasks
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $after = Get-Content -Raw -LiteralPath $script:Tasks
        $after | Should -Be $before
        $after | Should -Not -Match 'speckit-jira task='
    }

    It 'checklist mode plans zero sub-task writes and reports no counts.tasks (FR-007)' {
        Add-TaskMirrorChecklist
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks | Should -Be $null
        $calls = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' })
        $calls.Count | Should -Be 2
    }

    It 'subtask mode is unaffected by the gate split — identifiers assigned, sub-task planned (baseline)' {
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks.created | Should -Be 1
        (Get-Content -Raw -LiteralPath $script:Tasks) | Should -Match 'speckit-jira task='
        $calls = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' })
        $calls.Count | Should -Be 3
    }

    It 'an absent tasks.md is a silent no-op in checklist mode (spec Edge Cases)' {
        Add-TaskMirrorChecklist
        Remove-Item -LiteralPath $script:Tasks
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks | Should -Be $null
        $r.warnings | Should -Be $null
    }

    It 'an absent tasks.md is a silent no-op in subtask mode, unchanged from before this feature' {
        Remove-Item -LiteralPath $script:Tasks
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks | Should -Be $null
        $r.warnings | Should -Be $null
    }

    It 'T033a: a dry run prints each planned checklist per story with every entry text and state, and writes nothing (FR-037)' {
        Add-TaskMirrorChecklist
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json', '--dry-run')
        $r = $out | ConvertFrom-Json -Depth 100
        $storyAction = @($r.actions | Where-Object { $_.role -eq 'story' })[0]
        $descJson = ConvertTo-Json $storyAction.body.fields.description.content -Depth 20 -Compress
        $descJson | Should -Match 'Tasks'
        $descJson | Should -Match ([regex]::Escape([char]0x2610 + ' '))
        $descJson | Should -Match 'Implement the first story'
        $calls = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' })
        $calls.Count | Should -Be 0
    }

    It 'T086: a project with no recorded mode is unaffected by the switch-report code path — no note, ordinary subtask reconciliation (FR-002, SC-008)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $notes = ($out | ConvertFrom-Json -Depth 100).notes -join "`n"
        $notes | Should -Not -Match ([regex]::Escape('switched to checklist mode'))
        $notes | Should -Not -Match ([regex]::Escape('switched back to subtask mode'))
    }

    It 'T094a: checklist mode with a task role also declared reports it once as recorded and not consumed, and creates no sub-task (FR-007, spec Edge Cases)' {
        Add-TaskMirrorChecklist
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $r = $out | ConvertFrom-Json -Depth 100
        $notes = $r.notes -join "`n"
        $notes | Should -Match ([regex]::Escape("a task role is declared but task_mirror is 'checklist'"))
        $notes | Should -Match ([regex]::Escape('recorded, not consumed'))
        $calls = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' })
        $calls.Count | Should -Be 2
    }
}
