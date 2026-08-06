# T072 [016, US1] — FR-017: a task's own text is author prose, so the neutral
# reader emits its description as marked spans rather than the raw string
# feature 012 shipped. Mirror of tests/bash/engine/test_tasks_parse_markdown.bats.
# Cross-port parity is proven in bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    $TasksParseModule = Join-Path $EngineDir 'TasksParse.psm1'
}

Describe 'ConvertTo-JiraTasksParseDocument — Markdown in task text (016, FR-017)' {
    BeforeEach { Import-Module $TasksParseModule -Force }

    It 'a task description block is a paragraph carrying spans, never a raw string' {
        $out = ConvertTo-JiraTasksParseDocument -Text "- [ ] T001 Plain text with no markup at all`n" | ConvertFrom-Json -Depth 100
        $block = $out.tasks[0].description.blocks[0]
        $block.type | Should -Be 'paragraph'
        $block.PSObject.Properties.Name | Should -Contain 'spans'
        $block.PSObject.Properties.Name | Should -Not -Contain 'text'
    }

    It 'a backtick-quoted path becomes a monospace span' {
        $doc = "- [ ] T014 Implement the parser in ``scripts/bash/engine/tasks_parse.sh```n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json -Depth 100
        $mono = @($out.tasks[0].description.blocks[0].spans | Where-Object { $_.marks.kind -contains 'monospace' })
        $mono.Count | Should -Be 1
        $mono[0].text | Should -Be 'scripts/bash/engine/tasks_parse.sh'
    }

    It 'bold, strikethrough and link marks all reach the task description' {
        $doc = "- [ ] T003 Render **bold** and ~~gone~~ and [guide](https://example.invalid/g)`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json -Depth 100
        $spans = $out.tasks[0].description.blocks[0].spans
        @($spans | Where-Object { $_.marks.kind -contains 'bold' }).Count | Should -Be 1
        @($spans | Where-Object { $_.marks.kind -contains 'strikethrough' }).Count | Should -Be 1
        $link = @($spans | Where-Object { $_.marks.kind -contains 'link' })[0]
        $link.marks[0].href | Should -Be 'https://example.invalid/g'
    }

    It 'no Markdown delimiter survives in any span text (FR-002, SC-001)' {
        $doc = "- [ ] T002 Render **bold** and ``code`` and ~~gone~~`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json -Depth 100
        $joined = -join @($out.tasks[0].description.blocks[0].spans | ForEach-Object { $_.text })
        # `*` is the -BeLike wildcard, so a LITERAL asterisk must be bracketed.
        $joined | Should -Not -BeLike '*[*][*]*'
        $joined | Should -Not -BeLike '*`*'
        $joined | Should -Not -BeLike '*~~*'
    }

    It 'the title field keeps its raw markup — summaries are plain text (FR-018)' {
        $doc = "- [ ] T004 Implement the parser in ``engine/tasks_parse.sh```n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json -Depth 100
        $out.tasks[0].title | Should -Be 'Implement the parser in `engine/tasks_parse.sh`'
    }

    It 'an unbalanced delimiter degrades to literal text without failing (FR-005)' {
        $doc = "- [ ] T005 A lone ** delimiter and an unclosed [label( here`n"
        $out = ConvertTo-JiraTasksParseDocument -Text $doc | ConvertFrom-Json -Depth 100
        $joined = -join @($out.tasks[0].description.blocks[0].spans | ForEach-Object { $_.text })
        # The unclosed `**` survives as literal text rather than opening a span.
        $joined | Should -BeLike '*[*][*]*'
    }

    It 'a CRLF tasks.md yields the same blocks as the LF original (FR-015)' {
        $lf = ConvertTo-JiraTasksParseDocument -Text "- [ ] T006 Implement ``a/b.sh`` with **bold**`n"
        $crlf = ConvertTo-JiraTasksParseDocument -Text "- [ ] T006 Implement ``a/b.sh`` with **bold**`r`n"
        ($lf | ConvertFrom-Json -Depth 100).tasks[0].description | ConvertTo-Json -Depth 100 -Compress |
            Should -Be (($crlf | ConvertFrom-Json -Depth 100).tasks[0].description | ConvertTo-Json -Depth 100 -Compress)
    }
}
