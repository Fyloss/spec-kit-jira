# T032 [US1] — Task summary/description rendering, PowerShell side. Mirror of
# tests/bash/sink/test_adf_task.bats. Cross-port parity is proven in bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    $script:Task = @'
{
  "local_id": "3f8a1c02d94b7e65",
  "task_ref": "T014",
  "title": "Implement the neutral task parser in scripts/bash/engine/tasks_parse.sh",
  "description": {"blocks": [{"type":"paragraph","spans":[{"text":"Implement the neutral task parser","marks":[]}]}]},
  "attribution": {"story_ordinal": 1, "source": "tag"},
  "phase": "Phase 3: User Story 1",
  "parallel": true,
  "files": ["scripts/bash/engine/tasks_parse.sh"],
  "depends_on": ["T012"],
  "done": false,
  "marker": {"state":"assigned","id":"3f8a1c02d94b7e65","ticket":"","lines":[41]}
}
'@
}

Describe 'Get-JiraAdfTaskSummary' {
    It 'a short title passes through unchanged' {
        Get-JiraAdfTaskSummary -Title 'Short title' | Should -Be 'Short title'
    }

    It 'an over-long title is shortened deterministically to 255 chars' {
        $long = 'x' * 400
        $a = Get-JiraAdfTaskSummary -Title $long
        $b = Get-JiraAdfTaskSummary -Title $long
        $a | Should -Be $b
        $a.Length | Should -Be 255
        $a | Should -BeLike '*…'
    }

    It 'a title within the limit is returned byte-for-byte' {
        $exact = 'x' * 255
        Get-JiraAdfTaskSummary -Title $exact | Should -Be $exact
    }
}

Describe 'ConvertTo-JiraAdfTaskDescription' {
    It 'carries the identifier, phase, attribution, parallel-safety, files and dependencies' {
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson $script:Task | ConvertFrom-Json -Depth 100
        $json = $d | ConvertTo-Json -Depth 100 -Compress
        $json | Should -BeLike '*Identifier: T014*'
        $json | Should -BeLike '*Phase 3: User Story 1*'
        $json | Should -BeLike '*User Story 1*'
        $json | Should -BeLike '*Parallel-safe: yes*'
        $json | Should -BeLike '*scripts/bash/engine/tasks_parse.sh*'
        $json | Should -BeLike '*Depends on: T012*'
    }

    It 'carries the full untruncated text even when the summary is shortened' {
        # The engine puts the task's full text in BOTH title and description
        # blocks; the sink shortens only the summary (016 FR-017 moved the body
        # to blocks).
        $long = 'x' * 400
        $task = $script:Task | ConvertFrom-Json
        $task.title = $long
        $task.description.blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = $long; marks = @() }) })
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson ($task | ConvertTo-Json -Depth 100 -Compress)
        $d | Should -BeLike "*$long*"
    }

    It 'an unattributed task says so' {
        $task = $script:Task | ConvertFrom-Json
        $task.attribution = [ordered]@{ story_ordinal = $null; source = 'none' }
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson ($task | ConvertTo-Json -Depth 100 -Compress)
        $d | Should -BeLike '*Attribution: none*'
    }

    It 'an unparallel task says no' {
        $task = $script:Task | ConvertFrom-Json
        $task.parallel = $false
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson ($task | ConvertTo-Json -Depth 100 -Compress)
        $d | Should -BeLike '*Parallel-safe: no*'
    }

    It 'no files and no dependencies produce no such bullet' {
        $task = $script:Task | ConvertFrom-Json
        $task.files = @()
        $task.depends_on = @()
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson ($task | ConvertTo-Json -Depth 100 -Compress)
        $d | Should -Not -BeLike '*Files:*'
        $d | Should -Not -BeLike '*Depends on:*'
    }

    It 'renders a valid ADF doc envelope' {
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson $script:Task | ConvertFrom-Json
        $d.type | Should -Be 'doc'
        $d.version | Should -Be 1
        , $d.content | Should -BeOfType [System.Object[]]
    }
}

# T073 [016, US1] — FR-017/FR-018. Mirror of tests/bash/sink/test_adf_task_markdown.bats.
Describe 'ConvertTo-JiraAdfTaskDescription — Markdown marks (016, FR-017)' {
    BeforeAll {
        $script:MarkedTask = @'
{
  "local_id": "3f8a1c02d94b7e65",
  "task_ref": "T014",
  "title": "Implement the parser in `engine/tasks_parse.sh` with **bold**",
  "description": {"blocks": [{"type":"paragraph","spans":[
    {"text":"Implement the parser in ","marks":[]},
    {"text":"engine/tasks_parse.sh","marks":[{"kind":"monospace"}]},
    {"text":" with ","marks":[]},
    {"text":"bold","marks":[{"kind":"bold"}]}
  ]}]},
  "attribution": {"story_ordinal": 1, "source": "tag"},
  "phase": "Phase 3: User Story 1",
  "parallel": true,
  "files": ["engine/tasks_parse.sh"],
  "depends_on": ["T012"],
  "done": false,
  "marker": {"state":"assigned","id":"3f8a1c02d94b7e65","ticket":"","lines":[41]}
}
'@
    }

    It 'renders a monospace span as an ADF code mark' {
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson $script:MarkedTask | ConvertFrom-Json -Depth 100
        $coded = @($d.content[0].content | Where-Object { $_.PSObject.Properties.Name -contains 'marks' -and $_.marks.type -contains 'code' })
        $coded.Count | Should -Be 1
        $coded[0].text | Should -Be 'engine/tasks_parse.sh'
    }

    It 'renders a bold span as an ADF strong mark' {
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson $script:MarkedTask | ConvertFrom-Json -Depth 100
        $strong = @($d.content[0].content | Where-Object { $_.PSObject.Properties.Name -contains 'marks' -and $_.marks.type -contains 'strong' })
        $strong[0].text | Should -Be 'bold'
    }

    It 'leaves no Markdown delimiter in the rendered body (SC-001)' {
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson $script:MarkedTask | ConvertFrom-Json -Depth 100
        $body = -join @($d.content[0].content | ForEach-Object { $_.text })
        # `*` is the -BeLike wildcard, so a LITERAL asterisk must be bracketed.
        $body | Should -Not -BeLike '*`*'
        $body | Should -Not -BeLike '*[*][*]*'
    }

    It 'reads description.blocks rather than the raw title' {
        $task = $script:MarkedTask | ConvertFrom-Json -Depth 100
        $task.description.blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'FROM THE BLOCKS'; marks = @() }) })
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson ($task | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -Depth 100
        $d.content[0].content[0].text | Should -Be 'FROM THE BLOCKS'
    }

    It 'keeps bridge-composed metadata bullets plain, with no marks (FR-018)' {
        $d = ConvertTo-JiraAdfTaskDescription -TaskJson $script:MarkedTask | ConvertFrom-Json -Depth 100
        $bullets = $d.content[-1]
        $bullets.type | Should -Be 'bulletList'
        $marked = @($bullets.content | ForEach-Object { $_.content } | ForEach-Object { $_.content } |
                Where-Object { $_.PSObject.Properties.Name -contains 'marks' })
        $marked.Count | Should -Be 0
    }
}
