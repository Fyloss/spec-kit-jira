# T031 [US1] — Get-JiraPlanTaskWriteSet: one POST per attributed task carrying
# local_id, parent_local_id, role:"task" and the parent placeholder; never a
# POST under the specification-level issue (FR-007); a story with no task
# planning nothing extra (FR-010); contract §4.
# Mirror of tests/bash/sink/test_plan_writes_tasks.bats. Cross-port parity
# is proven there via pwsh.
#
# 018, T027: Get-JiraPlanTaskWriteSet now returns {actions, warnings} rather
# than a bare array (the boundary's own malformed/migrated-warned warnings
# need a channel) — every test below reads $result.actions.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force

    $script:Task1 = '{
      "local_id":"1111111111111111","task_ref":"T014","title":"Implement the parser",
      "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Implement the parser","marks":[]}]}]},
      "attribution":{"story_ordinal":1,"source":"tag"},"phase":"Phase 3","parallel":true,
      "files":[],"depends_on":[],"done":false,
      "marker":{"state":"assigned","id":"1111111111111111","ticket":"","lines":[10]}
    }'

    $script:DocOneTask = '{
      "routing":{"project_key":"COMP"},
      "epic":{"title":"Epic","local_id":"e1","marker":{"state":"assigned","id":"e1","lines":[1]},
              "description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}},
      "stories":[
        {"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","spans":[{"text":"need","marks":[]}]}]},
         "priority_logical":"P1","tasks":[' + $script:Task1 + ']}
      ]
    }'

    $script:DocNoTasks = '{
      "routing":{"project_key":"COMP"},
      "epic":{"title":"Epic","local_id":"e1","marker":{"state":"assigned","id":"e1","lines":[1]},
              "description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}},
      "stories":[
        {"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","spans":[{"text":"need","marks":[]}]}]},
         "priority_logical":"P1"}
      ]
    }'

    $script:CtxCreate = '{"base_url":"https://mock","task_type_id":"10099","tickets":{}}'

    # 018, T027: a fixture meant to isolate a NON-migration churn (a pure
    # content change, or a pure label back-fill) must seed ticket_current's
    # description already inside the boundary — otherwise the first touch of
    # a legacy (marker-less) description also migrates, which is its own,
    # separately-tested behaviour.
    function script:AlreadyMigratedTaskDesc {
        (ConvertTo-JiraManagedTaskAdfDocument -TaskJson $script:Task1 | ConvertFrom-Json -Depth 100).doc
    }
}

Describe 'Get-JiraPlanTaskWriteSet' {
    It 'one POST per attributed task, carrying local_id, parent_local_id, role and the parent placeholder' {
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $script:CtxCreate | ConvertFrom-Json -Depth 100).actions
        @($result).Count | Should -Be 1
        $result[0].method | Should -Be 'POST'
        $result[0].url | Should -Be 'https://mock/rest/api/3/issue'
        $result[0].local_id | Should -Be '1111111111111111'
        $result[0].parent_local_id | Should -Be 's1'
        $result[0].role | Should -Be 'task'
        $result[0].body.fields.parent.key | Should -Be '<resolved at apply time>'
        $result[0].body.fields.issuetype.id | Should -Be '10099'
    }

    It 'a story with no task plans nothing extra (FR-010)' {
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocNoTasks -ContextJson $script:CtxCreate | ConvertFrom-Json -Depth 100).actions
        @($result).Count | Should -Be 0
    }

    It 'never a POST under the specification-level issue — the URL is always the collection endpoint' {
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $script:CtxCreate | ConvertFrom-Json -Depth 100).actions
        $result[0].url | Should -Not -BeLike '*/issue/e1*'
    }

    It "the summary is the task's title (untruncated when short)" {
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $script:CtxCreate | ConvertFrom-Json -Depth 100).actions
        $result[0].body.fields.summary | Should -Be 'Implement the parser'
    }

    It 'an over-long title produces a deterministically shortened summary with the full text in the description' {
        $long = 'x' * 400
        $task = $script:Task1 | ConvertFrom-Json -Depth 100
        # TasksParse derives title and description blocks from the SAME text, so
        # a fixture that moves one must move the other (016 FR-017).
        $task.title = $long
        $task.description.blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = $long; marks = @() }) })
        $doc = $script:DocOneTask | ConvertFrom-Json -Depth 100
        $doc.stories[0].tasks = @($task)
        $docJson = $doc | ConvertTo-Json -Depth 100 -Compress
        $result = (Get-JiraPlanTaskWriteSet -DocJson $docJson -ContextJson $script:CtxCreate | ConvertFrom-Json -Depth 100).actions
        $result[0].body.fields.summary.Length | Should -Be 255
        $descJson = $result[0].body.fields.description | ConvertTo-Json -Depth 100 -Compress
        $descJson | Should -BeLike "*$long*"
    }

    It 'an already-bound task with unchanged content plans nothing (zero churn)' {
        $desc = AlreadyMigratedTaskDesc
        $ctx = [ordered]@{
            base_url = 'https://mock'
            task_type_id = '10099'
            tickets = [ordered]@{ '1111111111111111' = 'COMP-9' }
            ticket_current = [ordered]@{ '1111111111111111' = [ordered]@{ summary = 'Implement the parser'; description = $desc } }
        } | ConvertTo-Json -Depth 100 -Compress
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $ctx | ConvertFrom-Json -Depth 100).actions
        @($result).Count | Should -Be 0
    }

    It 'an already-bound task whose text changed plans a PUT carrying only the differing fields' {
        $task = $script:Task1 | ConvertFrom-Json -Depth 100
        $task.title = 'Implement the parser, reworded'
        $task.description.blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'Implement the parser, reworded'; marks = @() }) })
        $doc = $script:DocOneTask | ConvertFrom-Json -Depth 100
        $doc.stories[0].tasks = @($task)
        $docJson = $doc | ConvertTo-Json -Depth 100 -Compress

        $desc = AlreadyMigratedTaskDesc
        $ctx = [ordered]@{
            base_url = 'https://mock'
            task_type_id = '10099'
            tickets = [ordered]@{ '1111111111111111' = 'COMP-9' }
            ticket_current = [ordered]@{ '1111111111111111' = [ordered]@{ summary = 'Implement the parser'; description = $desc } }
        } | ConvertTo-Json -Depth 100 -Compress

        $result = (Get-JiraPlanTaskWriteSet -DocJson $docJson -ContextJson $ctx | ConvertFrom-Json -Depth 100).actions
        @($result).Count | Should -Be 1
        $result[0].method | Should -Be 'PUT'
        $result[0].url | Should -Be 'https://mock/rest/api/3/issue/COMP-9'
        $result[0].body.fields.summary | Should -Be 'Implement the parser, reworded'
        # A title change moves the summary, and also the description's own
        # first paragraph (the task's full, untruncated title) — so both
        # fields legitimately differ here; the fields-that-differ contrast
        # is FR-019's phase-only case below, which changes the description
        # alone.
        ($result[0].body.fields.PSObject.Properties.Name -contains 'description') | Should -Be $true
    }

    It 'an already-bound task whose description-affecting content changed plans a PUT carrying only the description (FR-019)' {
        $task = $script:Task1 | ConvertFrom-Json -Depth 100
        $task.phase = 'Phase 4'
        $doc = $script:DocOneTask | ConvertFrom-Json -Depth 100
        $doc.stories[0].tasks = @($task)
        $docJson = $doc | ConvertTo-Json -Depth 100 -Compress

        $desc = AlreadyMigratedTaskDesc
        $ctx = [ordered]@{
            base_url = 'https://mock'
            task_type_id = '10099'
            tickets = [ordered]@{ '1111111111111111' = 'COMP-9' }
            ticket_current = [ordered]@{ '1111111111111111' = [ordered]@{ summary = 'Implement the parser'; description = $desc } }
        } | ConvertTo-Json -Depth 100 -Compress

        $result = (Get-JiraPlanTaskWriteSet -DocJson $docJson -ContextJson $ctx | ConvertFrom-Json -Depth 100).actions
        @($result).Count | Should -Be 1
        $result[0].method | Should -Be 'PUT'
        ($result[0].body.fields.PSObject.Properties.Name -contains 'description') | Should -Be $true
        ($result[0].body.fields.PSObject.Properties.Name -contains 'summary') | Should -Be $false
    }

    It 'an already-bound task whose summary drifted on the Jira side carries a named warning identifying the ticket and the field (018, T049; contract summary-record.md §4)' {
        # Predates 018: summary used to be named by the GENERIC per-field
        # warning (FR-020) on any divergence, unconditionally. It is now
        # carved out of that mechanism exactly like description and labels
        # — an ordinary, un-drifted retitle (no recorded value yet) is
        # silent (FR-018), and a genuine drift (a recorded value that
        # disagrees with what Jira holds) is named through the summary
        # record's OWN warning channel instead.
        $task = $script:Task1 | ConvertFrom-Json -Depth 100
        $task.title = 'Implement the parser, reworded'
        $doc = $script:DocOneTask | ConvertFrom-Json -Depth 100
        $doc.stories[0].tasks = @($task)
        $docJson = $doc | ConvertTo-Json -Depth 100 -Compress

        $desc = AlreadyMigratedTaskDesc
        $ctx = [ordered]@{
            base_url = 'https://mock'
            task_type_id = '10099'
            tickets = [ordered]@{ '1111111111111111' = 'COMP-9' }
            ticket_current = [ordered]@{ '1111111111111111' = [ordered]@{ summary = "A human's rename"; description = $desc } }
            ticket_last_summaries = [ordered]@{ '1111111111111111' = 'Implement the parser' }
        } | ConvertTo-Json -Depth 100 -Compress

        $result = Get-JiraPlanTaskWriteSet -DocJson $docJson -ContextJson $ctx | ConvertFrom-Json -Depth 100
        ($result.actions[0].PSObject.Properties.Name -contains 'warning') | Should -BeFalse
        ($result.actions[0].body.fields.PSObject.Properties.Name -contains 'summary') | Should -BeFalse
        ($result.warnings -join ' ') | Should -BeLike '*COMP-9*'
        ($result.warnings -join ' ') | Should -BeLike '*summary*'
    }

    It 'a creation with no project or issue type refuses (zero writes)' {
        $ctx = '{"base_url":"https://mock","tickets":{}}'
        { Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $ctx } | Should -Throw
    }

    It 'several tasks under different stories each carry their own parent_local_id' {
        $task2 = $script:Task1 | ConvertFrom-Json -Depth 100
        $task2.local_id = '2222222222222222'
        $doc = $script:DocOneTask | ConvertFrom-Json -Depth 100
        $story2 = [ordered]@{
            local_id = 's2'
            title = 'B'
            description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'n'; marks = @() }) }) }
            priority_logical = 'P2'
            tasks = @($task2)
        }
        $doc.stories = @($doc.stories) + $story2
        $docJson = $doc | ConvertTo-Json -Depth 100 -Compress

        $result = (Get-JiraPlanTaskWriteSet -DocJson $docJson -ContextJson $script:CtxCreate | ConvertFrom-Json -Depth 100).actions
        @($result).Count | Should -Be 2
        $result[0].parent_local_id | Should -Be 's1'
        $result[1].parent_local_id | Should -Be 's2'
    }

    # -----------------------------------------------------------------
    # 017 FR-009 on 012's task tier — twin of test_plan_writes_tasks.bats.
    # -----------------------------------------------------------------

    It '017 [US2] a created sub-task carries the provenance label passed by the caller' {
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $script:CtxCreate -TaskLabel 'speckit-001-x' | ConvertFrom-Json -Depth 100).actions
        @($result[0].body.fields.labels) | Should -Be @('speckit-001-x')
    }

    It '017 [US2] no label argument leaves the created sub-task payload without a labels key at all' {
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $script:CtxCreate | ConvertFrom-Json -Depth 100).actions
        $result[0].body.fields.PSObject.Properties.Name | Should -Not -Contain 'labels'
    }

    It '017 [US2] a bound sub-task missing its label is back-filled by a PUT carrying labels alone' {
        $desc = AlreadyMigratedTaskDesc
        $ctx = [ordered]@{
            base_url = 'https://mock'
            task_type_id = '10099'
            tickets = [ordered]@{ '1111111111111111' = 'COMP-9' }
            ticket_current = [ordered]@{ '1111111111111111' = [ordered]@{ summary = 'Implement the parser'; description = $desc; labels = @() } }
        } | ConvertTo-Json -Depth 100 -Compress
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $ctx -TaskLabel 'speckit-001-x' | ConvertFrom-Json -Depth 100).actions
        @($result).Count | Should -Be 1
        $result[0].method | Should -Be 'PUT'
        @($result[0].body.fields.PSObject.Properties.Name) | Should -Be @('labels')
        @($result[0].body.fields.labels) | Should -Be @('speckit-001-x')
        # A pure back-fill is not drift: no FR-020 divergence warning.
        $result[0].PSObject.Properties.Name | Should -Not -Contain 'warning'
    }

    It '017 [US2] the label is merged with labels already on the sub-task, never replacing them' {
        $desc = AlreadyMigratedTaskDesc
        $ctx = [ordered]@{
            base_url = 'https://mock'
            task_type_id = '10099'
            tickets = [ordered]@{ '1111111111111111' = 'COMP-9' }
            ticket_current = [ordered]@{ '1111111111111111' = [ordered]@{ summary = 'Implement the parser'; description = $desc; labels = @('ops', 'zeta') } }
        } | ConvertTo-Json -Depth 100 -Compress
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $ctx -TaskLabel 'speckit-001-x' | ConvertFrom-Json -Depth 100).actions
        @($result[0].body.fields.labels) | Should -Be @('ops', 'speckit-001-x', 'zeta')
    }

    It '017 [US2] a sub-task that already carries its label plans nothing (zero churn)' {
        $desc = AlreadyMigratedTaskDesc
        $ctx = [ordered]@{
            base_url = 'https://mock'
            task_type_id = '10099'
            tickets = [ordered]@{ '1111111111111111' = 'COMP-9' }
            ticket_current = [ordered]@{ '1111111111111111' = [ordered]@{ summary = 'Implement the parser'; description = $desc; labels = @('speckit-001-x') } }
        } | ConvertTo-Json -Depth 100 -Compress
        $result = (Get-JiraPlanTaskWriteSet -DocJson $script:DocOneTask -ContextJson $ctx -TaskLabel 'speckit-001-x' | ConvertFrom-Json -Depth 100).actions
        @($result).Count | Should -Be 0
    }

    It '017 [US2] real content drift still names its divergent field, and labels are never named' {
        $desc = AlreadyMigratedTaskDesc
        $task = $script:Task1 | ConvertFrom-Json -Depth 100
        $task.title = 'Implement the parser, reworded'
        $doc = $script:DocOneTask | ConvertFrom-Json -Depth 100
        $doc.stories[0].tasks = @($task)
        $docJson = $doc | ConvertTo-Json -Depth 100 -Compress
        $ctx = [ordered]@{
            base_url = 'https://mock'
            task_type_id = '10099'
            tickets = [ordered]@{ '1111111111111111' = 'COMP-9' }
            ticket_current = [ordered]@{ '1111111111111111' = [ordered]@{ summary = 'Implement the parser'; description = $desc; labels = @() } }
        } | ConvertTo-Json -Depth 100 -Compress
        $fullResult = Get-JiraPlanTaskWriteSet -DocJson $docJson -ContextJson $ctx -TaskLabel 'speckit-001-x' | ConvertFrom-Json -Depth 100
        $result = $fullResult.actions
        # 018, T027: description's OWN divergence is reported through the
        # boundary's warnings, not this per-field one. 018, T049: summary's
        # own divergence is reported through the summary record's own
        # mechanism (here, silently — no record exists yet, FR-018) —
        # neither is named by the generic per-field warning, and no OTHER
        # field diverges (labels are never named either), so this action
        # carries no generic warning at all.
        ($result[0].PSObject.Properties.Name -contains 'warning') | Should -Be $false
        $result[0].body.fields.summary | Should -Be 'Implement the parser, reworded'
        ($result[0].body.fields.PSObject.Properties.Name -contains 'description') | Should -Be $true
        @($result[0].body.fields.labels) | Should -Be @('speckit-001-x')
        $warningsMember = $fullResult.PSObject.Properties['warnings']
        if ($null -ne $warningsMember) { @($warningsMember.Value).Count | Should -Be 0 }
    }

}
