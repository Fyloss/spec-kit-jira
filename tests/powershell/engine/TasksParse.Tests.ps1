# T017/T021/T024 [Phase 2] — The neutral tasks.md reader, PowerShell side.
# Mirror of tests/bash/engine/test_tasks_parse.bats. Cross-port parity is
# proven in bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    $TasksParseModule = Join-Path $EngineDir 'TasksParse.psm1'
}

Describe 'ConvertTo-JiraTasksParseDocument' {
    BeforeEach { Import-Module $TasksParseModule -Force }

    It 'the file is absent (empty text) yields an empty list, no report' {
        $out = ConvertTo-JiraTasksParseDocument -Text '' | ConvertFrom-Json
        $out.tasks.Count | Should -Be 0
        $out.skipped.Count | Should -Be 0
    }

    It 'a file with no recognisable task yields an empty list' {
        $doc = "# Tasks`n`nNothing here.`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $out.tasks.Count | Should -Be 0
    }

    It 'recognises the checkbox, task ref, [P], [US<N>], text, files, and depends-on' {
        $doc = "## Phase 3: Foo`n`n- [ ] T014 [P] [US1] Implement the parser in ``scripts/bash/engine/tasks_parse.sh`` (depends on T012, T013)`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $task = $out.tasks[0]
        $task.task_ref | Should -Be 'T014'
        $task.done | Should -Be $false
        $task.parallel | Should -Be $true
        $task.attribution.story_ordinal | Should -Be 1
        $task.attribution.source | Should -Be 'tag'
        $task.files[0] | Should -Be 'scripts/bash/engine/tasks_parse.sh'
        ($task.depends_on -join ',') | Should -Be 'T012,T013'
        $task.title | Should -Be 'Implement the parser in `scripts/bash/engine/tasks_parse.sh`'
    }

    It 'checked box: done is true' {
        $doc = "- [x] T001 Something already finished`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $out.tasks[0].done | Should -Be $true
    }

    It 'continuation lines belong to the task' {
        $doc = "- [ ] T001 Add the endpoint to the mock in`n      ``tests/x/mock-server.ps1``, returning results.`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $out.tasks[0].title | Should -BeLike '*returning results.*'
        $out.tasks[0].files[0] | Should -Be 'tests/x/mock-server.ps1'
    }

    It 'continuation collection stops at a blank line' {
        $doc = "## Phase 1: Setup`n`n- [ ] T001 First task`n      continuation of first`n`n- [ ] T002 Second task`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $out.tasks.Count | Should -Be 2
        $out.tasks[0].title | Should -BeLike '*continuation of first*'
        $out.tasks[1].title | Should -Not -BeLike '*continuation of first*'
    }

    It 'a marker line right after the task line is excluded from continuation content' {
        $doc = "- [ ] T001 First task with more`n<!-- speckit-jira task=1111111111111111 -->`n      continuation text.`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $out.tasks[0].title | Should -BeLike '*continuation text.*'
        $out.tasks[0].title | Should -Not -BeLike '*speckit-jira*'
        $out.tasks[0].marker.state | Should -Be 'assigned'
        $out.tasks[0].local_id | Should -Be '1111111111111111'
    }

    It 'attribution falls back to the enclosing Phase ... User Story <N> heading' {
        $doc = "## Phase 3: User Story 1 - A team that works in sub-tasks (Priority: P1)`n`n- [ ] T001 Untagged task`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $out.tasks[0].attribution.story_ordinal | Should -Be 1
        $out.tasks[0].attribution.source | Should -Be 'heading'
    }

    It 'neither tag nor heading names a story -> unattributed' {
        $doc = "## Phase 1: Setup`n`n- [ ] T001 Untagged task`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $out.tasks[0].attribution.source | Should -Be 'none'
    }

    It 'the [US<N>] tag wins over the enclosing heading' {
        $doc = "## Phase 3: User Story 1 - Foo (Priority: P1)`n`n- [ ] T001 [US2] Tagged task`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $out.tasks[0].attribution.story_ordinal | Should -Be 2
    }

    It 'a task whose text is empty once markup is removed produces no entry and is reported' {
        $doc = "- [ ] T001 [P] [US1]`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json
        $out.tasks.Count | Should -Be 0
        $out.skipped[0].task_ref | Should -Be 'T001'
        $out.skipped[0].reason | Should -Be 'empty title'
    }
}
