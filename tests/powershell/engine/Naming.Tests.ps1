# T041 [US3] — Pure naming engine (FR-015). Pester twin of
# tests/bash/engine/test_naming.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $script:EngineFile = Join-Path $Root 'scripts/powershell/engine/Naming.psm1'
    Import-Module $EngineFile -Force
}

Describe 'Naming engine' {
    It 'strips the project-key prefix of an opaque key' {
        Get-JiraTicketNumber -Key 'IJT-42' | Should -Be '42'
        Get-JiraTicketNumber -Key 'AB_C2-1234' | Should -Be '1234'
    }

    It 'leaves a non-key-shaped value untouched' {
        Get-JiraTicketNumber -Key '42' | Should -Be '42'
    }

    It 'substitutes <ID> and <FEATURE_NAME>' {
        Expand-JiraBranchPattern -Pattern 'ijt-<ID>/<FEATURE_NAME>' -Id '42' -FeatureName 'invoice-export' | Should -Be 'ijt-42/invoice-export'
        Expand-JiraBranchPattern -Pattern 'team/x-<ID>_<FEATURE_NAME>' -Id '7' -FeatureName 'onboarding' | Should -Be 'team/x-7_onboarding'
    }

    It 'builds a folder-safe slug from a description' {
        Get-JiraFeatureSlug -Description 'Invoice Export' | Should -Be 'invoice-export'
        Get-JiraFeatureSlug -Description '  Fix: rounding (v2)  ' | Should -Be 'fix-rounding-v2'
    }

    It 'never duplicates the folder prefix (FR-015)' {
        Get-JiraShortName -FolderPrefix 'ijt-' -Slug 'invoice-export' | Should -Be 'ijt-invoice-export'
        Get-JiraShortName -FolderPrefix 'ijt-' -Slug 'ijt-invoice-export' | Should -Be 'ijt-invoice-export'
    }

    It 'keeps the folder component flat while patterns may create git hierarchy' {
        (Expand-JiraBranchPattern -Pattern 'ijt-<ID>/<FEATURE_NAME>' -Id '42' -FeatureName 'x') | Should -Match '/'
        (Get-JiraShortName -FolderPrefix 'ijt-' -Slug 'x') | Should -Not -Match '/'
    }

    It 'contains no issue-key-shaped text in the engine file (Constitution VIII)' {
        # The Get-Jira* prefix is the established engine-module convention
        # (Parse/Drift/Interchange); the boundary forbids Atlassian-specific
        # identifiers and issue-key-shaped literals, not the module prefix.
        $content = Get-Content -Raw -LiteralPath $EngineFile
        # -CMatch mirrors the bats twin's case-sensitive grep: an issue key is
        # upper-case by definition; lower-case regex literals are legitimate.
        $content | Should -Not -CMatch '[A-Z][A-Z0-9_]+-[0-9]+'
        $content | Should -Not -Match '(?i)atlassian|createmeta'
    }
}
