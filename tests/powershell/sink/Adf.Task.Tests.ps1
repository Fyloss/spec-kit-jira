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
  "description": {"blocks": [{"type":"paragraph","text":"Implement the neutral task parser"}]},
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
        $long = 'x' * 400
        $task = $script:Task | ConvertFrom-Json
        $task.title = $long
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
