# T032/T035c/T057 [Phase 3/4, US1/US2, 022] — mirror of
# tests/bash/sink/test_plan_apply_checklist.bats and
# tests/bash/sink/test_plan_apply_checklist_drift.bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    # PlanApply imports Adf with -Force internally, which re-scopes Adf out of the
    # session; import the directly-called Adf LAST so its functions resolve.
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    Import-Module (Join-Path $SinkDir '../../engine/ManagedSection.psm1') -Force
    # -Global, and LAST: nested -Force imports re-scope Output.psm1 out of the session.
    Import-Module (Join-Path $SinkDir '../../lib/Output.psm1') -Force -Global
    $script:Marker = Get-JiraManagedMarker

    $script:DocWithTasks = '{
      "routing": {"project_key":"COMP"},
      "epic": {"title":"The Epic", "local_id":"3f2a91c04b7e6d18",
        "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
        "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},
      "stories": [
        {"local_id":"s1","title":"A story","description":{"blocks":[]},"priority_logical":"P1",
         "tasks":[{"title":"Do a thing","done":true,"phase":null}]}
      ]
    }'

    function New-ExistingWithChecklist {
        param([string] $Glyph)
        $obj = [ordered]@{
            type = 'doc'; version = 1
            content = @(
                [ordered]@{ type = 'paragraph'; content = @([ordered]@{ type = 'text'; text = $script:Marker; marks = @([ordered]@{ type = 'strong' }) }) }
                [ordered]@{ type = 'heading'; attrs = [ordered]@{ level = 3 }; content = @([ordered]@{ type = 'text'; text = 'Tasks' }) }
                [ordered]@{ type = 'bulletList'; content = @(
                    [ordered]@{ type = 'listItem'; content = @([ordered]@{ type = 'paragraph'; content = @([ordered]@{type='text';text=$Glyph}, [ordered]@{type='text';text='Do a thing'}) }) }
                ) }
            )
        }
        return (ConvertTo-Json $obj -Depth 20 -Compress)
    }

    function New-CtxFor {
        param([string] $ExistingJson, [string] $RecordedDigest)
        $obj = [ordered]@{
            base_url = 'https://mock'; story_type_id = '10002'; parent_type_id = '10101'
            parent_local_id = '3f2a91c04b7e6d18'; priority_ids = @{}; task_mirror = 'checklist'
            tickets = @{ s1 = 'COMP-9' }; ticket_descriptions = @{ s1 = ($ExistingJson | ConvertFrom-Json -Depth 100) }
            ticket_origins = @{ s1 = 'bridge' }
        }
        if ($RecordedDigest -ne '') { $obj['ticket_last_checklists'] = @{ s1 = $RecordedDigest } }
        return (ConvertTo-Json $obj -Depth 20 -Compress)
    }
}

Describe 'Get-JiraPlanWriteSet — checklist mode' {
    It "the story's planned description carries the Tasks section (FR-007)" {
        $ctx = '{"base_url":"https://mock","story_type_id":"10002","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18","priority_ids":{},"task_mirror":"checklist"}'
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocWithTasks -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $r.stories[0].method | Should -Be 'POST'
        $content = ConvertTo-Json $r.stories[0].body.fields.description.content -Depth 20 -Compress
        $content | Should -Match 'Tasks'
        $content | Should -Match 'Do a thing'
    }

    It 'subtask mode (or unrecorded): no Tasks section rendered' {
        $ctx = '{"base_url":"https://mock","story_type_id":"10002","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18","priority_ids":{}}'
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocWithTasks -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $content = ConvertTo-Json $r.stories[0].body.fields.description.content -Depth 20 -Compress
        $content | Should -Not -Match 'Tasks'
    }
}

Describe 'Get-JiraPlanWriteSet — checklist drift (contract §6)' {
    It 'no record means no warning' {
        $existing = New-ExistingWithChecklist -Glyph ([char]0x2610 + ' ')
        $ctx = New-CtxFor -ExistingJson $existing -RecordedDigest ''
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocWithTasks -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $r.warnings | Should -Be $null
    }

    It 'current matches recorded: writes silently' {
        $existing = New-ExistingWithChecklist -Glyph ([char]0x2611 + ' ')
        $existingObj = $existing | ConvertFrom-Json -Depth 100
        $managed = (Split-JiraManagedSectionPanel -Marker $script:Marker -ContentJson (ConvertTo-Json @($existingObj.content) -Depth 20 -Compress) | ConvertFrom-Json -Depth 100).managed
        $currentNodes = Get-JiraAdfChecklistSlice -ManagedJson (ConvertTo-Json @($managed) -Depth 20 -Compress)
        $recorded = Get-JiraAdfChecklistNodesDigest -NodesJson $currentNodes
        $ctx = New-CtxFor -ExistingJson $existing -RecordedDigest $recorded
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocWithTasks -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $r.warnings | Should -Be $null
    }

    It 'genuine drift: one named warning, entry still rewritten from tasks.md' {
        $existing = New-ExistingWithChecklist -Glyph ([char]0x2610 + ' ')
        $reworded = [ordered]@{
            type='doc'; version=1
            content=@(
                [ordered]@{type='paragraph'; content=@([ordered]@{type='text';text=$script:Marker;marks=@([ordered]@{type='strong'})})}
                [ordered]@{type='heading'; attrs=[ordered]@{level=3}; content=@([ordered]@{type='text';text='Tasks'})}
                [ordered]@{type='bulletList'; content=@([ordered]@{type='listItem';content=@([ordered]@{type='paragraph';content=@([ordered]@{type='text';text='☑ Do a thing (reworded)'})})})}
            )
        }
        $rewordedJson = ConvertTo-Json $reworded -Depth 20 -Compress
        $rewordedObj = $rewordedJson | ConvertFrom-Json -Depth 100
        $rewordedManaged = (Split-JiraManagedSectionPanel -Marker $script:Marker -ContentJson (ConvertTo-Json @($rewordedObj.content) -Depth 20 -Compress) | ConvertFrom-Json -Depth 100).managed
        $rewordedNodes = Get-JiraAdfChecklistSlice -ManagedJson (ConvertTo-Json @($rewordedManaged) -Depth 20 -Compress)
        $recorded = Get-JiraAdfChecklistNodesDigest -NodesJson $rewordedNodes
        $ctx = New-CtxFor -ExistingJson $existing -RecordedDigest $recorded
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocWithTasks -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        @($r.warnings).Count | Should -Be 1
        $r.warnings[0] | Should -Match 'COMP-9'
        $r.warnings[0] | Should -Match 'checklist'
        $content = ConvertTo-Json $r.stories[0].body.fields.description.content -Depth 20 -Compress
        $content | Should -Match ([regex]::Escape([char]0x2611 + ' '))
    }
}

Describe 'Get-JiraPlanWriteSet — checklist counts (data-model.md §4)' {
    It 'T034b: created, updated, unchanged, and entries_completed across three runs' {
        $docDoneTrue = $script:DocWithTasks | ConvertFrom-Json -Depth 100
        $docDoneTrue.stories[0].tasks[0].done = $true
        $docDoneTrueJson = ConvertTo-Json $docDoneTrue -Depth 20 -Compress

        $ctxCreate = '{"base_url":"https://mock","story_type_id":"10002","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18","priority_ids":{},"task_mirror":"checklist"}'
        $r1 = Get-JiraPlanWriteSet -NeutralDocJson $docDoneTrueJson -PlanContextJson $ctxCreate | ConvertFrom-Json -Depth 100
        $r1.checklist_counts.created | Should -Be 1
        $r1.checklist_counts.entries_completed | Should -Be 0

        $existingIncomplete = [ordered]@{
            type = 'doc'; version = 1
            content = @(
                [ordered]@{type='paragraph'; content=@([ordered]@{type='text';text=$script:Marker;marks=@([ordered]@{type='strong'})})}
                [ordered]@{type='heading'; attrs=[ordered]@{level=3}; content=@([ordered]@{type='text';text='Tasks'})}
                [ordered]@{type='bulletList'; content=@([ordered]@{type='listItem';content=@([ordered]@{type='paragraph';content=@([ordered]@{type='text';text='☐ '},[ordered]@{type='text';text='An old title'})})})}
            )
        }
        $ctxUpdate = New-CtxFor -ExistingJson (ConvertTo-Json $existingIncomplete -Depth 20 -Compress) -RecordedDigest ''
        $r2 = Get-JiraPlanWriteSet -NeutralDocJson $docDoneTrueJson -PlanContextJson $ctxUpdate | ConvertFrom-Json -Depth 100
        $r2.checklist_counts.updated | Should -Be 1
        $r2.checklist_counts.entries_completed | Should -Be 1

        $existingMatch = (ConvertTo-JiraManagedAdfDocument -ContentJson (ConvertTo-Json $docDoneTrue.stories[0] -Depth 20 -Compress) -Mode 'checklist' | ConvertFrom-Json -Depth 100).doc
        $ctxUnchanged = New-CtxFor -ExistingJson (ConvertTo-Json $existingMatch -Depth 20 -Compress) -RecordedDigest ''
        $r3 = Get-JiraPlanWriteSet -NeutralDocJson $docDoneTrueJson -PlanContextJson $ctxUnchanged | ConvertFrom-Json -Depth 100
        $r3.checklist_counts.unchanged | Should -Be 1
        $r3.checklist_counts.entries_completed | Should -Be 0
    }
}
