# 018, T041 [US3] — mirror of tests/bash/sink/test_summary_record.bats
# (contracts/summary-record.md §2/§3/§4): the whole decision table plus the
# §3 normalisation rule, across every tier.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    $script:Marker = Get-JiraManagedMarker

    function script:StoryCtx([string] $CurrentSummary, [string] $RecordedSummary, [string] $OnDrift = 'abort') {
        $managed = @((ConvertTo-JiraAdfDocument -ContentJson '{"description":{"blocks":[{"type":"paragraph","text":"Story body."}]}}' | ConvertFrom-Json -Depth 100).content)
        $content = [System.Collections.Generic.List[object]]::new()
        $content.Add([ordered]@{ type = 'paragraph'; content = @(@{ type = 'text'; text = $script:Marker; marks = @(@{ type = 'strong' }) }) })
        foreach ($n in $managed) { $content.Add($n) }
        $existing = [ordered]@{ type = 'doc'; version = 1; content = $content }
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = [ordered]@{
            base_url            = 'https://mock'
            parent_type_id      = '10101'
            tickets             = [ordered]@{ s1 = 'PROJ-1' }
            ticket_descriptions = [ordered]@{ s1 = ($existingJson | ConvertFrom-Json -Depth 100) }
            ticket_summaries    = [ordered]@{ s1 = $CurrentSummary }
            ticket_origins      = [ordered]@{ s1 = 'bridge' }
            on_drift            = $OnDrift
            priority_ids        = [ordered]@{ P2 = '2' }
        }
        if (-not [string]::IsNullOrEmpty($RecordedSummary)) { $ctx['ticket_last_summaries'] = [ordered]@{ s1 = $RecordedSummary } }
        return (ConvertTo-Json -InputObject $ctx -Depth 100 -Compress)
    }

    function script:ParentCtx([string] $CurrentSummary, [string] $RecordedSummary, [string] $OnDrift = 'abort') {
        $managed = @((ConvertTo-JiraAdfDocument -ContentJson '{"description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}}' | ConvertFrom-Json -Depth 100).content)
        $content = [System.Collections.Generic.List[object]]::new()
        $content.Add([ordered]@{ type = 'paragraph'; content = @(@{ type = 'text'; text = $script:Marker; marks = @(@{ type = 'strong' }) }) })
        foreach ($n in $managed) { $content.Add($n) }
        $existing = [ordered]@{ type = 'doc'; version = 1; content = $content }
        $ctx = [ordered]@{
            base_url       = 'https://mock'
            parent_type_id = '10101'
            parent_key     = 'PROJ-1'
            parent_current = [ordered]@{ summary = $CurrentSummary; description = $existing }
            parent_origin  = 'bridge'
            tickets        = [ordered]@{}
            on_drift       = $OnDrift
        }
        if (-not [string]::IsNullOrEmpty($RecordedSummary)) { $ctx['parent_last_summary'] = $RecordedSummary }
        return (ConvertTo-Json -InputObject $ctx -Depth 100 -Compress)
    }

    $script:Doc = '{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
      "stories":[{"local_id":"s1","title":"Story One, revised","priority_logical":"P2",
                  "description":{"blocks":[{"type":"paragraph","text":"Story body."}]}}]}'

    $script:DocParentOnly = '{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic, revised","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
      "stories":[]}'

    $script:Task = '{"local_id":"1111111111111111","task_ref":"T001","title":"Do the thing",
       "description":{"blocks":[{"type":"paragraph","text":"Do the thing"}]},
       "attribution":{"story_ordinal":1,"source":"tag"},"phase":"Phase 1","parallel":false,
       "files":[],"depends_on":[],"done":false,
       "marker":{"state":"assigned","id":"1111111111111111","ticket":"","lines":[10]}}'

    $script:DocWithTask = '{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"e1","marker":{"state":"assigned","id":"e1","lines":[1]},
              "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
      "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2",
                  "description":{"blocks":[{"type":"paragraph","text":"Story body."}]},
                  "tasks":[' + $script:Task + ']}]}'
}

Describe 'Get-JiraPlanSummaryDriftStatus — the pure decision function' {
    It 'no record: sends the desired summary, never warns' {
        (Get-JiraPlanSummaryDriftStatus -CurrentSummary 'Old Title' -RecordedSummary '' -DesiredSummary 'New Title' -OnDrift 'abort').summary | Should -Be 'New Title'
    }

    It 'record equal to current: silent retitle' {
        (Get-JiraPlanSummaryDriftStatus -CurrentSummary 'The Epic' -RecordedSummary 'The Epic' -DesiredSummary 'The Epic, revised' -OnDrift 'abort').summary | Should -Be 'The Epic, revised'
    }

    It 'record differs from current (abort, default): omits the summary' {
        (Get-JiraPlanSummaryDriftStatus -CurrentSummary "A human's rename" -RecordedSummary 'The Epic' -DesiredSummary 'The Epic, revised' -OnDrift 'abort').summary | Should -BeNullOrEmpty
    }

    It '--on-drift=proceed restores the specification title' {
        (Get-JiraPlanSummaryDriftStatus -CurrentSummary "A human's rename" -RecordedSummary 'The Epic' -DesiredSummary 'The Epic, revised' -OnDrift 'proceed').summary | Should -Be 'The Epic, revised'
    }

    It 'a whitespace-only difference between current and recorded never triggers omission' {
        (Get-JiraPlanSummaryDriftStatus -CurrentSummary '  The   Epic ' -RecordedSummary 'The Epic' -DesiredSummary 'The Epic, revised' -OnDrift 'abort').summary | Should -Be 'The Epic, revised'
    }

    It "a human's rename that already matches the specification's title is never treated as drift" {
        (Get-JiraPlanSummaryDriftStatus -CurrentSummary 'The Epic, revised' -RecordedSummary 'The Epic' -DesiredSummary 'The Epic, revised' -OnDrift 'abort').summary | Should -Be 'The Epic, revised'
    }
}

Describe 'T041 — story tier via Get-JiraPlanWriteSet' {
    It 'no record means no warning, the summary is sent (FR-018)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson (StoryCtx 'Story One' '') | ConvertFrom-Json -Depth 100
        $r.stories[0].body.fields.summary | Should -Be 'Story One, revised'
        $warningsMember = $r.PSObject.Properties['warnings']
        if ($null -ne $warningsMember) { @($warningsMember.Value).Count | Should -Be 0 }
    }

    It 'record equal to current means a silent retitle (FR-017)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson (StoryCtx 'Story One' 'Story One') | ConvertFrom-Json -Depth 100
        $r.stories[0].body.fields.summary | Should -Be 'Story One, revised'
    }

    It 'record different (abort, default) omits the field and warns by ticket and field name (FR-015)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson (StoryCtx "A human's rename" 'Story One') | ConvertFrom-Json -Depth 100
        ($r.stories[0].body.fields.PSObject.Properties.Name -contains 'summary') | Should -BeFalse
        ($r.warnings -join ' ') | Should -BeLike '*PROJ-1*'
        ($r.warnings -join ' ') | Should -BeLike '*summary*'
    }

    It 'every other field of a drifted ticket still reconciles' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson (StoryCtx "A human's rename" 'Story One') | ConvertFrom-Json -Depth 100
        $r.stories[0].body.fields.priority.id | Should -Be '2'
    }

    It '--on-drift=proceed restores the specification title and is an ordinary update (FR-016)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson (StoryCtx "A human's rename" 'Story One' 'proceed') | ConvertFrom-Json -Depth 100
        $r.stories[0].body.fields.summary | Should -Be 'Story One, revised'
    }

    It 'a whitespace-only difference between current and recorded never warns' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson (StoryCtx '  Story   One ' 'Story One') | ConvertFrom-Json -Depth 100
        $r.stories[0].body.fields.summary | Should -Be 'Story One, revised'
        $warningsMember = $r.PSObject.Properties['warnings']
        if ($null -ne $warningsMember) { @($warningsMember.Value).Count | Should -Be 0 }
    }
}

Describe 'T041 — parent tier via Get-JiraPlanWriteSet' {
    It 'record different (abort, default) omits the field and warns (FR-015)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocParentOnly -PlanContextJson (ParentCtx "A human's rename" 'The Epic') | ConvertFrom-Json -Depth 100
        ($r.parent.body.fields.PSObject.Properties.Name -contains 'summary') | Should -BeFalse
        ($r.warnings -join ' ') | Should -BeLike '*PROJ-1*'
    }

    It '--on-drift=proceed restores the specification title (FR-016)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocParentOnly -PlanContextJson (ParentCtx "A human's rename" 'The Epic' 'proceed') | ConvertFrom-Json -Depth 100
        $r.parent.body.fields.summary | Should -Be 'The Epic, revised'
    }
}

Describe 'T041 — task tier via Get-JiraPlanTaskWriteSet' {
    It 'record different (abort, default) omits the field and warns (FR-015, §5)' {
        $managed = @((ConvertTo-JiraAdfTaskDescription -TaskJson $script:Task | ConvertFrom-Json -Depth 100).content)
        $content = [System.Collections.Generic.List[object]]::new()
        $content.Add([ordered]@{ type = 'paragraph'; content = @(@{ type = 'text'; text = $script:Marker; marks = @(@{ type = 'strong' }) }) })
        foreach ($n in $managed) { $content.Add($n) }
        $existing = [ordered]@{ type = 'doc'; version = 1; content = $content }
        $ctx = [ordered]@{
            base_url             = 'https://mock'
            task_type_id         = '10099'
            tickets              = [ordered]@{ '1111111111111111' = 'PROJ-9' }
            ticket_current       = [ordered]@{ '1111111111111111' = [ordered]@{ summary = "A human's rename"; description = $existing } }
            ticket_summaries     = [ordered]@{ '1111111111111111' = "A human's rename" }
            ticket_last_summaries = [ordered]@{ '1111111111111111' = 'Do the thing' }
            ticket_origins       = [ordered]@{ '1111111111111111' = 'bridge' }
            on_drift             = 'abort'
        }
        $ctxJson = ConvertTo-Json -InputObject $ctx -Depth 100 -Compress
        $r = Get-JiraPlanTaskWriteSet -DocJson $script:DocWithTask -ContextJson $ctxJson | ConvertFrom-Json -Depth 100
        ($r.actions[0].body.fields.PSObject.Properties.Name -contains 'summary') | Should -BeFalse
        ($r.warnings -join ' ') | Should -BeLike '*PROJ-9*'
    }
}

Describe 'T041 — FR-019: a fully settled parent produces zero writes' {
    It 'nothing changed, including summary' {
        $ctx = ParentCtx 'The Epic' 'The Epic'
        $docUnchanged = '{"routing":{"project_key":"COMP"},
          "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
                  "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
                  "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
          "stories":[]}'
        $r = Get-JiraPlanWriteSet -NeutralDocJson $docUnchanged -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $r.parent | Should -Be $null
    }
}
