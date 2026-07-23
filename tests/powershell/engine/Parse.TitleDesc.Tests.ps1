# T050 [US3] — Engine parser, PowerShell side. Mirror of
# tests/bash/engine/test_parse_title_desc.bats. Cross-port byte-parity is proven
# in the bats test; here we assert the port's own behaviour (FR-013–FR-018).

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../.specify/extensions/jira/scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Parse.psm1') -Force
}

Describe 'Get-JiraParsedTitle' {
    It 'prefers an explicit Title: line' {
        Get-JiraParsedTitle -Text "Title: The Chosen Title`n# An H1" -FolderSlug '001-x' | Should -Be 'The Chosen Title'
    }
    It 'falls back to the first H1' {
        Get-JiraParsedTitle -Text "# Feature Specification: Rich Tickets`n## Summary`nignore" -FolderSlug '001-x' | Should -Be 'Rich Tickets'
    }
    It 'falls back to a user-story section title' {
        Get-JiraParsedTitle -Text "### User Story 3 - Rich, reliable content (Priority: P1)`nbody" -FolderSlug '001-x' | Should -Be 'Rich, reliable content'
    }
    It 'falls back to the first non-empty paragraph' {
        Get-JiraParsedTitle -Text "`nA plain sentence of need.`nmore" -FolderSlug '001-x' | Should -Be 'A plain sentence of need.'
    }
    It 'falls back to the humanised folder slug last' {
        Get-JiraParsedTitle -Text '' -FolderSlug '001-jira-reconcile-engine' | Should -Be 'jira reconcile engine'
    }
    It 'never derives the title from a ## Summary' {
        $t = Get-JiraParsedTitle -Text "# Real Title`n## Summary`nSummary derived title" -FolderSlug '001-x'
        $t | Should -Be 'Real Title'
        $t | Should -Not -BeLike '*Summary*'
    }
}

Describe 'Get-JiraParsedDescription' {
    It 'is a non-empty structured block tree' {
        $d = Get-JiraParsedDescription -Text "# T`n`nWe need a reconcile bridge for specs." | ConvertFrom-Json
        @($d.blocks).Count | Should -BeGreaterOrEqual 1
    }
    It 'is never empty even with no prose and no ## Summary' {
        $d = Get-JiraParsedDescription -Text "# Only A Title" | ConvertFrom-Json
        @($d.blocks).Count | Should -BeGreaterOrEqual 1
        ($d.blocks | Where-Object { $_.text.Length -gt 0 }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Get-JiraParsedAcceptance' {
    It 'extracts a one-clause-per-line scenario' {
        $a = Get-JiraParsedAcceptance -Text "- **Given** a signed-in user`n- **When** they open the board`n- **Then** widgets load" | ConvertFrom-Json
        @($a).Count | Should -Be 1
        $a[0].given[0] | Should -Be 'a signed-in user'
        $a[0].then[0] | Should -Be 'widgets load'
    }
    It 'extracts an inline scenario' {
        $a = Get-JiraParsedAcceptance -Text 'Given a user When they click Then it opens' | ConvertFrom-Json
        @($a).Count | Should -Be 1
        $a[0].then[0] | Should -Be 'it opens'
    }
    It 'yields an empty array when no Gherkin' {
        Get-JiraParsedAcceptance -Text 'just prose' | Should -Be '[]'
    }
}

Describe 'Get-JiraParsedDesign' {
    It 'extracts a Figma link and UX guidance' {
        $d = Get-JiraParsedDesign -Text "## Design`nUse the blue accent.`nSee https://www.figma.com/file/abc/Board" | ConvertFrom-Json
        @($d | Where-Object { $_.kind -eq 'figma_link' }).Count | Should -BeGreaterOrEqual 1
        @($d | Where-Object { $_.kind -eq 'guidance' }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Get-JiraParsedPriority / Estimation' {
    It 'extracts P1' { Get-JiraParsedPriority -Text '### US (Priority: P1)' | Should -Be 'P1' }
    It 'defaults to P2' { Get-JiraParsedPriority -Text 'no priority' | Should -Be 'P2' }
    It 'extracts an estimation number' { Get-JiraParsedEstimation -Text 'Estimation: 5' | Should -Be '5' }
    It 'is null when undeclared' { Get-JiraParsedEstimation -Text 'no estimate' | Should -Be 'null' }
}
