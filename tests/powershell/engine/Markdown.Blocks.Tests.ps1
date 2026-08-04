# T044/T046 [US2] — Block segmentation, PowerShell side.
# Mirror of tests/bash/engine/test_markdown_blocks.bats. Cross-port agreement
# proven in bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Markdown.psm1') -Force
    Import-Module (Join-Path $EngineDir '../lib/Output.psm1') -Force

    function Get-Norm($Json) {
        # The product's own canonical form (recursively key-sorted), so a test
        # literal's key order never matters — only the real one.
        return (ConvertTo-JiraCanonicalJson -Json $Json)
    }
}

Describe 'ConvertTo-JiraMarkdownBlocks — Part B block segmentation' {
    It 'B1 — a fenced code block is verbatim, no inline tokenization (FR-007)' {
        $doc = "``````bash`necho **not bold**`n``````"
        $got = Get-Norm (ConvertTo-JiraMarkdownBlocks -Text $doc)
        $exp = Get-Norm '[{"type":"code","text":"echo **not bold**"}]'
        $got | Should -Be $exp
    }

    It 'B1 — an unclosed fence still emits its content' {
        $doc = "```````nline one`nline two"
        $got = Get-Norm (ConvertTo-JiraMarkdownBlocks -Text $doc)
        $exp = Get-Norm '[{"type":"code","text":"line one\nline two"}]'
        $got | Should -Be $exp
    }

    It 'B2 — an ATX heading carries its level and tokenized text' {
        $got = Get-Norm (ConvertTo-JiraMarkdownBlocks -Text '### Design **Notes**')
        $exp = Get-Norm '[{"type":"heading","level":3,"spans":[{"text":"Design ","marks":[]},{"text":"Notes","marks":[{"kind":"bold"}]}]}]'
        $got | Should -Be $exp
    }

    It 'B3 — bullet items accumulate into one bullet_list, nesting flattened' {
        $doc = "- a`n  - nested b`n- c"
        $out = ConvertTo-JiraMarkdownBlocks -Text $doc | ConvertFrom-Json -Depth 20
        $out[0].type | Should -Be 'bullet_list'
        $out[0].items.Count | Should -Be 3
    }

    It 'B4 — ordered items accumulate into ordered_list; source numbering is discarded' {
        $doc = "5. first`n1. second"
        $out = ConvertTo-JiraMarkdownBlocks -Text $doc | ConvertFrom-Json -Depth 20
        $out[0].type | Should -Be 'ordered_list'
        $out[0].items[0][0].text | Should -Be 'first'
        $out[0].items[1][0].text | Should -Be 'second'
    }

    It "B5 — a blockquote's prefix is stripped and the remainder re-segments" {
        $got = Get-Norm (ConvertTo-JiraMarkdownBlocks -Text '> a quoted paragraph')
        $exp = Get-Norm '[{"type":"paragraph","spans":[{"text":"a quoted paragraph","marks":[]}]}]'
        $got | Should -Be $exp
    }

    It 'B5 — a blockquoted heading still segments as a heading' {
        $got = Get-Norm (ConvertTo-JiraMarkdownBlocks -Text '> ## Quoted Heading')
        $exp = Get-Norm '[{"type":"heading","level":2,"spans":[{"text":"Quoted Heading","marks":[]}]}]'
        $got | Should -Be $exp
    }

    It "B6 — a table's delimiter row is dropped; cells join with an em dash" {
        $doc = "| H1 | H2 |`n| --- | --- |`n| a | b |"
        $got = Get-Norm (ConvertTo-JiraMarkdownBlocks -Text $doc)
        $exp = Get-Norm '[{"type":"paragraph","spans":[{"text":"H1 — H2","marks":[]}]},{"type":"paragraph","spans":[{"text":"a — b","marks":[]}]}]'
        $got | Should -Be $exp
    }

    It 'B7 — a blank line closes the open block; consecutive blanks collapse' {
        $doc = "para one`n`n`npara two"
        $got = Get-Norm (ConvertTo-JiraMarkdownBlocks -Text $doc)
        $exp = Get-Norm '[{"type":"paragraph","spans":[{"text":"para one","marks":[]}]},{"type":"paragraph","spans":[{"text":"para two","marks":[]}]}]'
        $got | Should -Be $exp
    }

    It 'B8 — paragraph lines join with a single space' {
        $doc = "line one`nline two"
        $got = Get-Norm (ConvertTo-JiraMarkdownBlocks -Text $doc)
        $exp = Get-Norm '[{"type":"paragraph","spans":[{"text":"line one line two","marks":[]}]}]'
        $got | Should -Be $exp
    }

    It 'B8 — a list ends at the first non-matching line (no lazy continuation)' {
        $doc = "- item a`nnot a list item"
        $out = ConvertTo-JiraMarkdownBlocks -Text $doc | ConvertFrom-Json -Depth 20
        $out[0].type | Should -Be 'bullet_list'
        $out[0].items.Count | Should -Be 1
        $out[1].type | Should -Be 'paragraph'
    }
}

Describe 'ConvertTo-JiraMarkdownBlocks — B9 selection cap worked example (data-model.md §4)' {
    It 'a heading rides free, does not consume cap budget' {
        $doc = "## Overview`nSome intro prose.`n- item a`n- item b"
        $out = ConvertTo-JiraMarkdownBlocks -Text $doc | ConvertFrom-Json -Depth 20
        $out.Count | Should -Be 3
        $out[0].type | Should -Be 'heading'
        $out[1].type | Should -Be 'paragraph'
        $out[2].type | Should -Be 'bullet_list'
    }
}
