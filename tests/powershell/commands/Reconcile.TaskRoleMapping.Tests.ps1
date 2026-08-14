# T085 [Phase 6, US4] — isolation rules I4/I7, PowerShell port. Mirror of
# tests/bash/commands/test_reconcile_task_role_mapping.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-task-tier'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    $script:ConfigYaml = @'
projects:
  - key: TASKP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      task:
        after_specify: "To Do"
        after_plan: "In Progress"
routing_default: TASKP
'@

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }

    # TASKP-3 is the sub-task a fresh run mirrors T002 as (repo-with-task-tier).
    # It offers one ungated name-based move to "In Progress" — the task
    # role's own declared step — alongside the unrelated category-based
    # move 012's completion pass already exercises.
    function New-MockConfigPath {
        return (Write-JiraMockConfig -Json '{"projects":{"TASKP":"t"},"transitions":{"TASKP-3":[
            {"id":"41","name":"Start","to":{"name":"In Progress"},"fields":{}},
            {"id":"31","name":"Terminé","to":{"statusCategory":{"key":"done"}},"fields":{}}
        ]}}')
    }
}

Describe 'Invoke-JiraReconcile — the task role''s own declared mapping (I4/I7)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $script:Tasks = Join-Path $script:Work 'specs/001-feature/tasks.md'
        Set-Content -NoNewline -Path (Join-Path $script:Work '.specify/jira/config.yml') -Value $script:ConfigYaml
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        $cfgPath = New-MockConfigPath
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T085 -- an unchecked task with a declared step moves the sub-task by name, counted with the task tier''s own tally' {
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        $t = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/TASKP-3/transitions') })
        $t.Count | Should -Be 1
        [string]$t[0].body.transition.id | Should -Be '41'
        $r.counts.tasks.transitioned | Should -Be 1
        # Never folded into the specification/story tier's own counter
        # (present with 0, since the `task` role also declares a step for
        # this event — data-model.md §5's "at least one role" condition).
        [int]$r.counts.transitioned | Should -Be 0
    }

    It 'T085 -- I7: a CHECKED task outranks the mapping -- the completion pass runs, the mapping''s own due set does not' {
        (Get-Content -Raw -LiteralPath $script:Tasks) -replace '(?m)^- \[ \] T002 ', '- [x] T002 ' |
            Set-Content -LiteralPath $script:Tasks -NoNewline

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        # The completion pass's own forward move (done-category, id 31) fires...
        $t = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/TASKP-3/transitions') })
        $t.Count | Should -Be 1
        [string]$t[0].body.transition.id | Should -Be '31'
        # ... and the role-mapping's own move (id 41, "In Progress") never
        # does: exactly one transition POST was ever issued for TASKP-3.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue/TASKP-3/transitions' }).Count | Should -Be 1
    }

    It 'T085 -- a task already at its declared step asks the tracker nothing about it' {
        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/TASKP-3" `
            -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}}' | Out-Null

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'TASKP-3/transitions' }).Count | Should -Be 0
        $r.counts.tasks.transitioned | Should -Be 0
    }
}
