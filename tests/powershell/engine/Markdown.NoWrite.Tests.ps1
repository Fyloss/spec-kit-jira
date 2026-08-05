# T088 [016, Phase 8] — mirror of tests/bash/engine/test_markdown_no_write.bats.
# A module-property guard: engine/markdown.sh and its PowerShell mirror
# Markdown.psm1 open no file for writing (FR-000, quickstart.md §8). FR-000
# claims the ABSENCE of a write path, and one passing reconcile scenario
# cannot prove absence — this checks the property of the module directly, so
# a future edit that adds a write path fails here rather than going unnoticed.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $BashMod = Join-Path $Root 'scripts/bash/engine/markdown.sh'
    $PsMod = Join-Path $Root 'scripts/powershell/engine/Markdown.psm1'

    # Matches the shape a real write takes (`> "${f}"`, `>> '/tmp/x'`) — `>`
    # flanked by whitespace on both sides, immediately followed by a quote or
    # `$` sigil — while leaving the markdown grammar's own quoted '>'
    # character (the blockquote marker, matched and compared as data
    # throughout this module) alone.
    $script:RedirectPattern = '[\s]>{1,2}[\s]+[''"\$]'

    function Test-NoRedirect([string] $Path) {
        $content = Get-Content -Raw -LiteralPath $Path
        return -not ($content -match $script:RedirectPattern)
    }
}

Describe 'Markdown module — no file-write operation' {
    It 'engine/markdown.sh opens no file for writing' {
        Test-Path $BashMod | Should -BeTrue
        Test-NoRedirect $BashMod | Should -BeTrue
        (Get-Content -Raw -LiteralPath $BashMod) | Should -Not -Match '\btee\b|\bcp\b\s|\bmv\b\s'
    }

    It 'engine/Markdown.psm1 opens no file for writing' {
        Test-Path $PsMod | Should -BeTrue
        Test-NoRedirect $PsMod | Should -BeTrue
        (Get-Content -Raw -LiteralPath $PsMod) | Should -Not -Match 'Out-File|Set-Content|Add-Content|StreamWriter|WriteAllText|WriteAllBytes|Copy-Item|Move-Item|New-Item\s+-ItemType\s+File'
    }

    It 'the guard itself catches a planted write (sanity check)' {
        $planted = Join-Path $TestDrive 'planted.sh'
        'echo hi > "${some_file}"' | Set-Content -NoNewline -Path $planted
        Test-NoRedirect $planted | Should -BeFalse
    }
}
