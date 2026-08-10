# T025/T028/T030/T030a [Phase 3, US1, 022] — mirror of tests/bash/sink/test_adf_checklist.bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    # -Global, and LAST: Adf.psm1's nested -Force import re-scopes Output.psm1
    # out of the session.
    Import-Module (Join-Path $SinkDir '../../lib/Output.psm1') -Force -Global

    function New-ContentWithTasks {
        return @'
{
  "description": {"blocks": []},
  "tasks": [
    {"title": "Do the first thing", "done": false, "phase": "Phase 1: Setup", "task_ref": "T001", "local_id": "t1", "files": ["a.sh"], "depends_on": [], "parallel": true},
    {"title": "Do the second thing", "done": true, "phase": "Phase 1: Setup", "task_ref": "T002", "local_id": "t2"},
    {"title": "Unphased work", "done": false, "phase": null, "task_ref": "T003", "local_id": "t3"},
    {"title": "Phase two item", "done": false, "phase": "Phase 2: Story", "task_ref": "T004", "local_id": "t4"}
  ]
}
'@
    }
}

Describe 'Get-JiraAdfChecklistNode' {
    It 'structure: one Tasks heading, one group per phase in first-appearance order, no-phase group leads' {
        $nodes = Get-JiraAdfChecklistNode -ContentJson (New-ContentWithTasks)
        $nodes[0].type | Should -Be 'heading'
        $nodes[0].content[0].text | Should -Be 'Tasks'
        $nodes[1].type | Should -Be 'bulletList'
        @($nodes[1].content).Count | Should -Be 1
        $nodes[2].type | Should -Be 'paragraph'
        $nodes[2].content[0].text | Should -Be 'Phase 1: Setup'
        $nodes[3].type | Should -Be 'bulletList'
        @($nodes[3].content).Count | Should -Be 2
        $nodes[4].content[0].text | Should -Be 'Phase 2: Story'
        @($nodes[5].content).Count | Should -Be 1
        @($nodes).Count | Should -Be 6
    }

    It 'the no-phase group carries no phase paragraph' {
        $nodes = Get-JiraAdfChecklistNode -ContentJson (New-ContentWithTasks)
        $texts = @($nodes | Where-Object { $_.type -eq 'paragraph' } | ForEach-Object { $_.content[0].text })
        $texts | Should -Not -Contain $null
    }

    It 'a story with zero attributed tasks renders no section at all (FR-021)' {
        $nodes = Get-JiraAdfChecklistNode -ContentJson '{"description":{"blocks":[]},"tasks":[]}'
        @($nodes).Count | Should -Be 0
        $nodes = Get-JiraAdfChecklistNode -ContentJson '{"description":{"blocks":[]}}'
        @($nodes).Count | Should -Be 0
    }

    It 'two stories holding tasks whose text is identical each render their own entry, never deduplicated' {
        $contentA = '{"description":{"blocks":[]},"tasks":[{"title":"Same text","done":false,"phase":null}]}'
        $nodesA = Get-JiraAdfChecklistNode -ContentJson $contentA
        $nodesB = Get-JiraAdfChecklistNode -ContentJson $contentA
        (ConvertTo-Json $nodesA -Depth 20 -Compress) | Should -Be (ConvertTo-Json $nodesB -Depth 20 -Compress)
        @($nodesA[1].content).Count | Should -Be 1
    }

    It 'an entry carries none of task_ref, local_id, files, depends_on, parallel or the phase text (FR-017)' {
        $nodes = Get-JiraAdfChecklistNode -ContentJson (New-ContentWithTasks)
        $all = ConvertTo-Json $nodes -Depth 20 -Compress
        $all | Should -Not -Match 'T001'
        $all | Should -Not -Match '"t1"'
        $all | Should -Not -Match 'a\.sh'
        $all | Should -Not -Match 'local_id'
        $all | Should -Not -Match 'depends_on'
        $all | Should -Not -Match 'parallel'
    }

    It "an entry's text renders the Markdown subset exactly as a sub-task description body does for the same line (FR-023)" {
        $content = '{"description":{"blocks":[]},"tasks":[{"title":"A **bold** word","done":false,"phase":null}]}'
        $nodes = Get-JiraAdfChecklistNode -ContentJson $content
        $entrySpans = $nodes[1].content[0].content[0].content
        $entrySpans[0].text | Should -Be ([char]0x2610 + ' ')
        $json = ConvertTo-Json $entrySpans -Depth 20 -Compress
        $json | Should -Match 'strong'
        $json | Should -Match 'bold'
    }

    It 'done: true renders complete, done: false renders incomplete (FR-025)' {
        $nodes = Get-JiraAdfChecklistNode -ContentJson (New-ContentWithTasks)
        $phase1Glyphs = @($nodes[3].content | ForEach-Object { $_.content[0].content[0].text })
        $phase1Glyphs[0] | Should -Be ([char]0x2610 + ' ')
        $phase1Glyphs[1] | Should -Be ([char]0x2611 + ' ')
    }

    It 'no entry or checklist node carries an identity attribute' {
        $nodes = Get-JiraAdfChecklistNode -ContentJson (New-ContentWithTasks)
        (ConvertTo-Json $nodes -Depth 20 -Compress) | Should -Not -Match 'localId'
    }

    It 'normalisation strips attrs.localId and nothing else, on nodes and on entries' {
        $nodes = '[{"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"Tasks"}]},
                   {"type":"bulletList","attrs":{"localId":"abc"},"content":[{"type":"listItem","attrs":{"localId":"z"},"content":[]}]}]'
        $normalised = ConvertTo-JiraAdfChecklistNormalized -NodesJson $nodes
        $normalised | Should -Not -Match 'localId'
        $parsed = $normalised | ConvertFrom-Json -Depth 100
        # a sibling attribute survives: the heading keeps its level
        $parsed[0].attrs.level | Should -Be 3
        # and the emptied attrs object is left in place, not deleted with its key
        $parsed[1].PSObject.Properties.Name | Should -Contain 'attrs'
        $parsed[1].content[0].PSObject.Properties.Name | Should -Contain 'attrs'
    }

    It 'the nodes digest of a rendered checklist matches the cross-port pin' {
        # The digest is written into the story's identity stamp, so the two ports
        # must agree byte-for-byte or every alternating run reports phantom drift.
        # The bash mirror pins the SAME constant.
        $content = '{"description":{"blocks":[]},"tasks":[{"title":"Do a thing","done":false,"phase":null}]}'
        $nodes = ConvertTo-JiraJsonValue (Get-JiraAdfChecklistNode -ContentJson $content)
        Get-JiraAdfChecklistNodesDigest -NodesJson $nodes | Should -Be '53aeb0a57962fae37ed64e0f8aa4cefc6a0d98f4'
    }
}
