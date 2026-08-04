# T093 [US5] — wiring the completion pass (contract §6) into
# Invoke-JiraReconcile: a checked task transitions its already-recognised
# sub-task to whichever status the project classifies as done, counted on
# its own summary line — never folded into created/updated (research R5).
# An unchecked task whose sub-task a person completed in Jira is reported
# by key and never moved backward unless the run is authorised with
# --on-drift=proceed (FR-032). Completion is never read back into
# tasks.md (FR-033). Mirror of tests/bash/commands/test_reconcile_task_completion.bats.

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

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }

    # TASKP-3 is the sub-task a fresh run mirrors T002 as (repo-with-task-tier).
    # It offers one done-category destination (31) and one not-done destination
    # (21), so both the forward and the authorised-backward path are exercised
    # without a second mock config.
    function New-MockConfigPath {
        return (Write-JiraMockConfig -Json '{"projects":{"TASKP":"t"},"transitions":{"TASKP-3":[
            {"id":"31","name":"Terminé","to":{"statusCategory":{"key":"done"}},"fields":{}},
            {"id":"21","name":"À faire","to":{"statusCategory":{"key":"new"}},"fields":{}}
        ]}}')
    }
}

Describe 'Invoke-JiraReconcile — the task tier completion pass' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $script:Tasks = Join-Path $script:Work 'specs/001-feature/tasks.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        $cfgPath = New-MockConfigPath
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'transitions a checked task''s sub-task, counted on its own summary line' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        (Get-Content -Raw -LiteralPath $script:Tasks) -replace '(?m)^- \[ \] T002 ', '- [x] T002 ' |
            Set-Content -LiteralPath $script:Tasks -NoNewline

        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks.transitioned | Should -Be 1
        $r.counts.tasks.updated | Should -Be 0
        $r.counts.tasks.created | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue/TASKP-3/transitions' }).Count | Should -Be 1
        ($r.actions | Where-Object { $_.url -eq '/rest/api/3/issue/TASKP-3/transitions' }).body.transition.id | Should -Be '31'
    }

    It 'issues zero reads and zero transitions once Jira already reflects the done-category status (FR-031)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        (Get-Content -Raw -LiteralPath $script:Tasks) -replace '(?m)^- \[ \] T002 ', '- [x] T002 ' |
            Set-Content -LiteralPath $script:Tasks -NoNewline
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/TASKP-3" `
            -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"Terminé","statusCategory":{"key":"done"}}}}' | Out-Null

        $before = (Get-JiraMockCallLog -Mock $script:M).Count
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks.transitioned | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Select-Object -Skip $before | Where-Object { $_ -like '*/transitions' }).Count | Should -Be 0
    }

    It 'reports an unchecked task whose sub-task a person completed by key and never moves it backward without authorisation (FR-032)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/TASKP-3" `
            -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"Terminé","statusCategory":{"key":"done"}}}}' | Out-Null

        $before = (Get-JiraMockCallLog -Mock $script:M).Count
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks.transitioned | Should -Be 0
        ($r.warnings -join ' ') | Should -BeLike '*TASKP-3*'
        @(Get-JiraMockCallLog -Mock $script:M | Select-Object -Skip $before | Where-Object { $_ -like '*/transitions' }).Count | Should -Be 0
        (Get-Content -Raw -LiteralPath $script:Tasks) | Should -Match '(?m)^- \[ \] T002 '
    }

    It 'never checks its task off in tasks.md, byte-for-byte, when a sub-task is completed in Jira (T086, FR-033)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $before = Get-Content -Raw -LiteralPath $script:Tasks

        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/TASKP-3" `
            -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"Terminé","statusCategory":{"key":"done"}}}}' | Out-Null

        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        (Get-Content -Raw -LiteralPath $script:Tasks) | Should -Be $before
    }

    It 'creates and transitions a task checked before its sub-task ever existed, in the same run (Edge Cases, T084)' {
        (Get-Content -Raw -LiteralPath $script:Tasks) -replace '(?m)^- \[ \] T002 ', '- [x] T002 ' |
            Set-Content -LiteralPath $script:Tasks -NoNewline

        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks.created | Should -Be 1
        $r.counts.tasks.transitioned | Should -Be 1
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue/TASKP-3/transitions' }).Count | Should -Be 1
        ($r.actions | Where-Object { $_.url -eq '/rest/api/3/issue/TASKP-3/transitions' }).body.transition.id | Should -Be '31'
        (Get-Content -Raw -LiteralPath $script:Tasks) | Should -Match 'ticket=TASKP-3'
    }

    It 'pulls the diverged sub-task backward under --on-drift=proceed and still reports the divergence (FR-032)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/TASKP-3" `
            -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"Terminé","statusCategory":{"key":"done"}}}}' | Out-Null

        $r = Invoke-Captured @('reconcile', $script:Spec, '--json', '--on-drift=proceed') | ConvertFrom-Json
        $r.counts.tasks.transitioned | Should -Be 1
        ($r.actions | Where-Object { $_.url -eq '/rest/api/3/issue/TASKP-3/transitions' }).body.transition.id | Should -Be '21'
        ($r.warnings -join ' ') | Should -BeLike '*TASKP-3*'
    }
}
