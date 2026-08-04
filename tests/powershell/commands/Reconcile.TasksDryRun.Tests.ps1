# T035a [US1] — mirror of tests/bash/commands/test_reconcile_tasks_dryrun.bats.
# FR-024's dry-run preview claims for the task tier: every sub-task it would
# create or update names its parent story, its summary and its description,
# and the run writes nothing. Uses repo-with-tasks (three stories) rather
# than the single-story repo-with-task-tier fixture, because naming the
# RIGHT parent story only becomes a real claim once more than one story
# exists in the same run.
#
# FR-024's "every transition it would perform" clause is deliberately not
# covered here: neither port resolves a task-tier transition yet (tasks.md
# Phase 8 header note) — that belongs to US5 (T081-T088), not to this
# US1-scoped file.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-tasks'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222 3333333333333333 4444444444444444 5555555555555555 6666666666666666 7777777777777777 8888888888888888 9999999999999999 bbbbbbbbbbbbbbbb cccccccccccccccc dddddddddddddddd eeeeeeeeeeeeeeee ffffffffffffffff 0000000000000000'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-widget'
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

    function Get-ByStory {
        param($Obj)
        $stories = @{}
        foreach ($s in ($Obj.actions | Where-Object { $_.role -eq 'story' })) {
            $stories[$s.local_id] = $s.body.fields.summary
        }
        return $Obj.actions | Where-Object { $_.role -eq 'task' } | ForEach-Object {
            [pscustomobject]@{ Task = $_.body.fields.summary; Story = $stories[$_.parent_local_id] }
        }
    }
}

Describe 'Invoke-JiraReconcile --dry-run — the task tier (012)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-widget/spec.md'
        $script:Tasks = Join-Path $script:Work 'specs/001-widget/tasks.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"TASKS":"company"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'names the parent story of every sub-task it would create, across more than one story' {
        $before = Get-Content -Raw -LiteralPath $script:Tasks
        $obj = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        @($obj.actions | Where-Object { $_.role -eq 'story' }).Count | Should -Be 3
        @($obj.actions | Where-Object { $_.role -eq 'task' }).Count | Should -Be 6

        $byStory = Get-ByStory -Obj $obj
        ($byStory | Where-Object { $_.Task -eq 'Implement the widget creation endpoint' })[0].Story | Should -Be 'Create a widget'
        ($byStory | Where-Object { $_.Task -like 'Add validation*' })[0].Story | Should -Be 'Create a widget'
        ($byStory | Where-Object { $_.Task -eq 'Implement the widget rename endpoint' })[0].Story | Should -Be 'Rename a widget'
        ($byStory | Where-Object { $_.Task -eq 'Add rename validation' })[0].Story | Should -Be 'Rename a widget'
        ($byStory | Where-Object { $_.Task -eq 'Implement the widget delete endpoint' })[0].Story | Should -Be 'Delete a widget'

        (Get-Content -Raw -LiteralPath $script:Tasks) | Should -Be $before
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -Be 0
    }

    It 'shows the summary and description of a created sub-task' {
        $obj = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        $action = ($obj.actions | Where-Object { $_.role -eq 'task' -and $_.body.fields.summary -like '*Implement the widget creation endpoint*' })[0]
        $action.body.fields.summary | Should -Be 'Implement the widget creation endpoint'
        $desc = ($action.body.fields.description | ConvertTo-Json -Depth 100 -Compress)
        $desc | Should -Match 'Implement the widget creation endpoint'
        $desc | Should -Match 'Identifier: T003'
        $desc | Should -Match 'Attribution: User Story 1'
    }

    It 'shows an update it would perform, with its summary and description' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $content = Get-Content -Raw -LiteralPath $script:Tasks
        $content = $content -replace '- \[ \] T003 \[US1\] Implement the widget creation endpoint', '- [ ] T003 [US1] Implement the widget creation endpoint with strict validation'
        [System.IO.File]::WriteAllText($script:Tasks, $content, (New-Object System.Text.UTF8Encoding($false)))
        $before = Get-Content -Raw -LiteralPath $script:Tasks
        Clear-Content -LiteralPath $script:M.CallLog

        $obj = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        $action = ($obj.actions | Where-Object { $_.role -eq 'task' -and $_.method -eq 'PUT' })[0]
        $action.url | Should -Match 'TASKS-5'
        $action.body.fields.summary | Should -Match 'strict validation'
        ($action.body.fields.description | ConvertTo-Json -Depth 100 -Compress) | Should -Match 'strict validation'

        (Get-Content -Raw -LiteralPath $script:Tasks) | Should -Be $before
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -notlike 'GET *' }).Count | Should -Be 0
    }

    It "the dry-run action set for the task tier is identical to the real run's, over the same starting state (Constitution XI)" {
        $dryObj = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        $dryTasks = Get-ByStory -Obj $dryObj | Sort-Object Task
        $dryCount = $dryObj.counts.tasks.created

        $work2 = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work2
        $env:JIRA_CONFIG_DIR = Join-Path $work2 '.specify/jira'
        $realObj = Invoke-Captured @('reconcile', (Join-Path $work2 'specs/001-widget/spec.md'), '--json') | ConvertFrom-Json
        $realTasks = Get-ByStory -Obj $realObj | Sort-Object Task
        $realCount = $realObj.counts.tasks.created

        $realCount | Should -Be $dryCount
        ($realTasks | ConvertTo-Json -Depth 100 -Compress) | Should -Be ($dryTasks | ConvertTo-Json -Depth 100 -Compress)
    }
}
