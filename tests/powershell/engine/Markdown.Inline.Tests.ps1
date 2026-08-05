# T007/T021/T023 [US1] — Inline tokenizer, PowerShell side.
# Mirror of tests/bash/engine/test_markdown_inline.bats. Cross-port agreement
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

Describe 'ConvertTo-JiraMarkdownInlineSpans — Part E worked examples' {
    It 'E1 — **FR-012** applies: one bold span' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '**FR-012** applies')
        $exp = Get-Norm '[{"text":"FR-012","marks":[{"kind":"bold"}]},{"text":" applies","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'E2 — code span protects its interior and gets monospace' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text 'run `reconcile --dry-run`')
        $exp = Get-Norm '[{"text":"run ","marks":[]},{"text":"reconcile --dry-run","marks":[{"kind":"monospace"}]}]'
        $got | Should -Be $exp
    }

    It 'E3 — a valid link renders as a link mark, target hidden' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text 'see [guide](https://ex.invalid/s)')
        $exp = Get-Norm '[{"text":"see ","marks":[]},{"text":"guide","marks":[{"kind":"link","href":"https://ex.invalid/s"}]}]'
        $got | Should -Be $exp
    }

    It 'E4 — an unsafe target degrades to label (target), no link mark (FR-006)' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text 'see [guide](../local.md)')
        $exp = Get-Norm '[{"text":"see guide (../local.md)","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'E5 — italic (star and underscore) and strikethrough' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '*a*, _b_, ~~c~~')
        $exp = Get-Norm '[{"text":"a","marks":[{"kind":"italic"}]},{"text":", ","marks":[]},{"text":"b","marks":[{"kind":"italic"}]},{"text":", ","marks":[]},{"text":"c","marks":[{"kind":"strikethrough"}]}]'
        $got | Should -Be $exp
    }

    It 'E6 — backslash-escaped asterisks stay literal (C1)' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '\*not bold\*')
        $exp = Get-Norm '[{"text":"*not bold*","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'E7 — 2 * 3 * 4 stays literal (C9.1: space follows the opener)' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '2 * 3 * 4')
        $exp = Get-Norm '[{"text":"2 * 3 * 4","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'E8 — parse_description_blocks survives with zero marks (C9.3)' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text 'parse_description_blocks')
        $exp = Get-Norm '[{"text":"parse_description_blocks","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'E9 — a code span nested in bold keeps both marks' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '**bold with `code` inside**')
        $exp = Get-Norm '[{"text":"bold with ","marks":[{"kind":"bold"}]},{"text":"code","marks":[{"kind":"bold"},{"kind":"monospace"}]},{"text":" inside","marks":[{"kind":"bold"}]}]'
        $got | Should -Be $exp
    }

    It 'E10 — an unclosed bold delimiter stays fully literal (C9.4)' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '**unclosed')
        $exp = Get-Norm '[{"text":"**unclosed","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'E11 — asterisks inside a code span are never bold (C2)' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '`**not bold**`')
        $exp = Get-Norm '[{"text":"**not bold**","marks":[{"kind":"monospace"}]}]'
        $got | Should -Be $exp
    }

    It 'E12 — an image renders as its alt text, no mark (FR-010)' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '![diagram](x.png)')
        $exp = Get-Norm '[{"text":"diagram","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'E13 — an autolink renders the URL as a link span (C3)' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '<https://ex.invalid>')
        $exp = Get-Norm '[{"text":"https://ex.invalid","marks":[{"kind":"link","href":"https://ex.invalid"}]}]'
        $got | Should -Be $exp
    }

    It 'E14 — a raw HTML tag is discarded, inner text kept (C10)' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '<b>text</b>')
        $exp = Get-Norm '[{"text":"text","marks":[]}]'
        $got | Should -Be $exp
    }
}

Describe 'ConvertTo-JiraMarkdownInlineSpans — C9 delimiter rules' {
    It 'C9.1 — opener must be followed by non-whitespace' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '* not emphasis *')
        $exp = Get-Norm '[{"text":"* not emphasis *","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'C9.2 — the nearest valid closer wins' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '*a* b *c*')
        $exp = Get-Norm '[{"text":"a","marks":[{"kind":"italic"}]},{"text":" b ","marks":[]},{"text":"c","marks":[{"kind":"italic"}]}]'
        $got | Should -Be $exp
    }

    It 'C9.3 — underscore inside an identifier never opens emphasis' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text 'customfield_10011')
        $exp = Get-Norm '[{"text":"customfield_10011","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'C9.3 — a standalone underscore-wrapped word still emphasises' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text 'a _word_ here')
        $exp = Get-Norm '[{"text":"a ","marks":[]},{"text":"word","marks":[{"kind":"italic"}]},{"text":" here","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'C9.4 — no closer means every delimiter char is literal' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text 'a _b')
        $exp = Get-Norm '[{"text":"a _b","marks":[]}]'
        $got | Should -Be $exp
    }

    It 'C9.6 — depth cap of 8 bounds pathological nesting deterministically' {
        $input = 'x'
        1..9 | ForEach-Object { $input = "*$input*" }
        { ConvertTo-JiraMarkdownInlineSpans -Text $input } | Should -Not -Throw
    }
}

Describe 'ConvertTo-JiraMarkdownInlineSpans — D1-D3 emission invariants' {
    It 'D1 — adjacent equal-mark spans merge into one' {
        $out = ConvertTo-JiraMarkdownInlineSpans -Text '[a](https://ex.invalid)[b](https://ex.invalid)' | ConvertFrom-Json -Depth 20
        $out.Count | Should -Be 1
        $out[0].text | Should -Be 'ab'
        $out[0].marks[0].href | Should -Be 'https://ex.invalid'
    }

    It 'D2 — marks is always present and sorted alphabetically by kind' {
        $out = ConvertTo-JiraMarkdownInlineSpans -Text '**_~~x~~_**' | ConvertFrom-Json -Depth 20
        ($out[0].marks | ForEach-Object { $_.kind }) -join ',' | Should -Be 'bold,italic,strikethrough'
    }

    It 'D3 — an empty inline collapses to []' {
        ConvertTo-JiraMarkdownInlineSpans -Text '' | Should -Be '[]'
    }
}

Describe 'ConvertTo-JiraMarkdownInlineSpans — T085 non-ASCII inside a formatted span (spec Edge Cases)' {
    It 'accented characters, CJK and emoji inside a bold span survive byte-for-byte' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '**café 日本語 🎉**')
        $exp = Get-Norm '[{"text":"café 日本語 🎉","marks":[{"kind":"bold"}]}]'
        $got | Should -Be $exp
    }

    It 'non-ASCII inside a code span survives byte-for-byte' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '`café 日本語 🎉`')
        $exp = Get-Norm '[{"text":"café 日本語 🎉","marks":[{"kind":"monospace"}]}]'
        $got | Should -Be $exp
    }

    It 'non-ASCII inside a link label survives byte-for-byte' {
        $got = Get-Norm (ConvertTo-JiraMarkdownInlineSpans -Text '[café 日本語 🎉](https://ex.invalid/s)')
        $exp = Get-Norm '[{"text":"café 日本語 🎉","marks":[{"kind":"link","href":"https://ex.invalid/s"}]}]'
        $got | Should -Be $exp
    }
}
