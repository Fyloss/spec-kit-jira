# 018, T023 [US2] — the boundary's four remaining behaviours, proven through
# the FULL write-planning functions (Get-JiraPlanWriteSet, Get-JiraPlanTaskWriteSet)
# across every tier. Mirror of tests/bash/sink/test_preserve_boundary.bats.
#   - preservation across parent, story and sub-task (FR-007)
#   - an edit confined to the prefix produces zero writes (FR-009)
#   - a deleted managed region is restored in full (FR-008)
#   - a duplicated delimiter warns by ticket key and writes no description,
#     while every other field of that ticket still reconciles (FR-012)

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $script:Marker = Get-JiraManagedMarker

    function script:HumanDesc([string] $PrefixText, [object[]] $Managed) {
        $content = [System.Collections.Generic.List[object]]::new()
        $content.Add([ordered]@{ type = 'paragraph'; content = @(@{ type = 'text'; text = $PrefixText }) })
        $content.Add([ordered]@{ type = 'paragraph'; content = @(@{ type = 'text'; text = $script:Marker; marks = @(@{ type = 'strong' }) }) })
        foreach ($n in $Managed) { $content.Add($n) }
        return [ordered]@{ type = 'doc'; version = 1; content = $content }
    }

    function script:TwoMarkerDesc([object[]] $Managed) {
        $content = [System.Collections.Generic.List[object]]::new()
        $content.Add([ordered]@{ type = 'paragraph'; content = @(@{ type = 'text'; text = $script:Marker; marks = @(@{ type = 'strong' }) }) })
        foreach ($n in $Managed) { $content.Add($n) }
        $content.Add([ordered]@{ type = 'paragraph'; content = @(@{ type = 'text'; text = $script:Marker; marks = @(@{ type = 'strong' }) }) })
        foreach ($n in $Managed) { $content.Add($n) }
        return [ordered]@{ type = 'doc'; version = 1; content = $content }
    }

    $script:Doc = '{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
      "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2",
                  "description":{"blocks":[{"type":"paragraph","text":"Story body."}]}}]}'

    $script:DocParentOnly = '{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
      "stories":[]}'

    $script:DocParentOnlyChanged = '{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","text":"Epic overview, revised."}]}},
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

Describe 'FR-007 — preservation across parent, story and sub-task' {
    It 'the story tier preserves the human prefix verbatim' {
        $managed = @((ConvertTo-JiraAdfDocument -ContentJson '{"description":{"blocks":[{"type":"paragraph","text":"Story body."}]}}' | ConvertFrom-Json -Depth 100).content)
        $existing = HumanDesc 'A PO wrote this on the story.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_local_id`":`"3f2a91c04b7e6d18`",`"tickets`":{`"s1`":`"PROJ-1`"},`"ticket_descriptions`":{`"s1`":$existingJson}}"
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r.stories[0].body.fields.description
        $desc.content[0].content[0].text | Should -Be 'A PO wrote this on the story.'
    }

    It 'the parent tier preserves the human prefix verbatim' {
        $managed = @((ConvertTo-JiraAdfDocument -ContentJson '{"description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}}' | ConvertFrom-Json -Depth 100).content)
        $existing = HumanDesc 'A PO wrote this on the epic.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocParentOnlyChanged -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r.parent.body.fields.description
        $desc.content[0].content[0].text | Should -Be 'A PO wrote this on the epic.'
        (ConvertTo-Json -InputObject $desc -Depth 100 -Compress) | Should -BeLike '*Epic overview, revised.*'
    }

    It 'the sub-task tier preserves the human prefix verbatim' {
        $managed = @((ConvertTo-JiraAdfTaskDescription -TaskJson $script:Task | ConvertFrom-Json -Depth 100).content)
        $existing = HumanDesc 'A PO wrote this on the sub-task.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $task = $script:Task | ConvertFrom-Json -Depth 100
        $task.title = 'Do the thing, reworded'
        $doc = $script:DocWithTask | ConvertFrom-Json -Depth 100
        $doc.stories[0].tasks = @($task)
        $docJson = $doc | ConvertTo-Json -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"task_type_id`":`"10099`",`"tickets`":{`"1111111111111111`":`"PROJ-9`"},`"ticket_current`":{`"1111111111111111`":{`"summary`":`"Do the thing`",`"description`":$existingJson}}}"
        $r = (Get-JiraPlanTaskWriteSet -DocJson $docJson -ContextJson $ctx | ConvertFrom-Json -Depth 100).actions
        $desc = $r[0].body.fields.description
        $desc.content[0].content[0].text | Should -Be 'A PO wrote this on the sub-task.'
        (ConvertTo-Json -InputObject $desc -Depth 100 -Compress) | Should -BeLike '*Do the thing, reworded*'
    }
}

Describe 'FR-009 — an edit confined to the prefix produces zero writes' {
    It "a sub-task's prefix-only edit produces zero writes" {
        $managed = @((ConvertTo-JiraAdfTaskDescription -TaskJson $script:Task | ConvertFrom-Json -Depth 100).content)
        $existing = HumanDesc 'EDITED note by the PO.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"task_type_id`":`"10099`",`"tickets`":{`"1111111111111111`":`"PROJ-9`"},`"ticket_current`":{`"1111111111111111`":{`"summary`":`"Do the thing`",`"description`":$existingJson}}}"
        $r = (Get-JiraPlanTaskWriteSet -DocJson $script:DocWithTask -ContextJson $ctx | ConvertFrom-Json -Depth 100).actions
        @($r).Count | Should -Be 0
    }

    It "the parent's prefix-only edit produces zero writes" {
        $managed = @((ConvertTo-JiraAdfDocument -ContentJson '{"description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}}' | ConvertFrom-Json -Depth 100).content)
        $existing = HumanDesc 'A DIFFERENT human note.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:DocParentOnly -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $r.parent | Should -Be $null
    }
}

Describe 'FR-008 — a deleted managed region is restored in full' {
    It 'a story missing its managed region entirely has it restored in full' {
        $existing = [ordered]@{
            type = 'doc'; version = 1
            content = @(
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'PO note.' }) },
                @{ type = 'paragraph'; content = @(@{ type = 'text'; text = $script:Marker; marks = @(@{ type = 'strong' }) }) }
            )
        }
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_local_id`":`"3f2a91c04b7e6d18`",`"tickets`":{`"s1`":`"PROJ-1`"},`"ticket_descriptions`":{`"s1`":$existingJson}}"
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r.stories[0].body.fields.description
        $desc.content[0].content[0].text | Should -Be 'PO note.'
        (ConvertTo-Json -InputObject $desc -Depth 100 -Compress) | Should -BeLike '*Story body.*'
    }
}

Describe 'FR-012 — a duplicated delimiter warns and writes no description' {
    It 'a story with two boundary markers warns by key, writes no description, but still updates other fields' {
        $managed = @((ConvertTo-JiraAdfDocument -ContentJson '{"description":{"blocks":[{"type":"paragraph","text":"Story body."}]}}' | ConvertFrom-Json -Depth 100).content)
        $existing = TwoMarkerDesc $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_local_id`":`"3f2a91c04b7e6d18`",`"tickets`":{`"s1`":`"PROJ-1`"},`"ticket_descriptions`":{`"s1`":$existingJson},`"priority_ids`":{`"P2`":`"2`"}}"
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        ($r.stories[0].body.fields.PSObject.Properties.Name -contains 'description') | Should -BeFalse
        $r.stories[0].body.fields.summary | Should -Be 'Story One'
        $r.stories[0].body.fields.priority.id | Should -Be '2'
        ($r.warnings -join ' ') | Should -BeLike '*PROJ-1*'
    }

    It 'a sub-task with two boundary markers warns by key, writes no description, but still updates the summary' {
        $managed = @((ConvertTo-JiraAdfTaskDescription -TaskJson $script:Task | ConvertFrom-Json -Depth 100).content)
        $existing = TwoMarkerDesc $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $task = $script:Task | ConvertFrom-Json -Depth 100
        $task.title = 'Do the thing, reworded'
        $doc = $script:DocWithTask | ConvertFrom-Json -Depth 100
        $doc.stories[0].tasks = @($task)
        $docJson = $doc | ConvertTo-Json -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"task_type_id`":`"10099`",`"tickets`":{`"1111111111111111`":`"PROJ-9`"},`"ticket_current`":{`"1111111111111111`":{`"summary`":`"Do the thing`",`"description`":$existingJson}}}"
        $result = (Get-JiraPlanTaskWriteSet -DocJson $docJson -ContextJson $ctx | ConvertFrom-Json -Depth 100)
        $r = $result.actions
        ($r[0].body.fields.PSObject.Properties.Name -contains 'description') | Should -BeFalse
        $r[0].body.fields.summary | Should -Be 'Do the thing, reworded'
        ($result.warnings -join ' ') | Should -BeLike '*PROJ-9*'
    }
}

Describe 'T069 (FR-011) — an oversized-description rejection retries without it' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'retries without the description, warns once by key, and every other field still reconciles' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PRSV-2":{"summary":"Old summary"}},"faults":{"PRSV-2":{"status":400,"errors":{"description":"The description field exceeds the maximum length of 32767 characters."},"ifFieldPresent":"description"}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $desc = [ordered]@{ type = 'doc'; version = 1; content = @(@{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'managed body' }) }) }
        $descJson = ConvertTo-Json -InputObject $desc -Depth 100 -Compress
        $plan = "{`"parent`":null,`"stories`":[{`"method`":`"PUT`",`"url`":`"$($script:M.BaseUrl)/rest/api/3/issue/PRSV-2`",`"body`":{`"fields`":{`"summary`":`"New summary`",`"description`":$descJson}}}]}"
        $specFile = Join-Path $TestDrive 'spec_t069.md'

        $sw = [System.IO.StringWriter]::new()
        $origErr = [Console]::Error
        [Console]::SetError($sw)
        try { $result = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $plan -SpecRefJson '{}' -SpecFile $specFile }
        finally { [Console]::SetError($origErr) }

        $result.ExitCode | Should -Be 0
        $sw.ToString() | Should -BeLike '*PRSV-2*'
        $sw.ToString() | Should -BeLike '*description*'
        (Get-JiraMockIssueField -Mock $script:M -Key 'PRSV-2' -Path 'fields.summary') | Should -Be 'New summary'
        (Get-JiraMockIssueField -Mock $script:M -Key 'PRSV-2' -Path 'fields.description') | Should -Be $null
        $calls = (Get-JiraMockCallLog -Mock $script:M) | Where-Object { $_ -eq 'PUT /rest/api/3/issue/PRSV-2' }
        @($calls).Count | Should -Be 2
    }
}
