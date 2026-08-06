# T009 [018] — The migration split (research R3, contract §3, data-model.md §2).
# Mirror of tests/bash/engine/test_managed_migration.bats. Pure structural array
# comparison: no marker, no tracker vocabulary.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Engine = Join-Path $Root 'scripts/powershell/engine'
    Import-Module (Join-Path $Engine 'ManagedSection.psm1') -Force
    $script:Managed = '[{"type":"paragraph","content":[{"type":"text","text":"managed body"}]}]'
}

Describe 'Managed-section suffix split' {
    It 'yields an empty prefix on an exact match' {
        $r = Split-JiraManagedSectionSuffix -ManagedJson $Managed -ContentJson $Managed | ConvertFrom-Json
        $r.matched | Should -BeTrue
        @($r.prefix).Count | Should -Be 0
    }

    It 'yields everything before the matched suffix when a human prefix is present' {
        $existing = @'
[
  {"type":"paragraph","content":[{"type":"text","text":"Human note."}]},
  {"type":"paragraph","content":[{"type":"text","text":"managed body"}]}
]
'@
        $r = Split-JiraManagedSectionSuffix -ManagedJson $Managed -ContentJson $existing | ConvertFrom-Json
        $r.matched | Should -BeTrue
        @($r.prefix).Count | Should -Be 1
        $r.prefix[0].content[0].text | Should -Be 'Human note.'
    }

    It 'preserves the whole existing array as the prefix on no match' {
        $existing = '[{"type":"paragraph","content":[{"type":"text","text":"unrelated content"}]}]'
        $r = Split-JiraManagedSectionSuffix -ManagedJson $Managed -ContentJson $existing | ConvertFrom-Json
        $r.matched | Should -BeFalse
        @($r.prefix).Count | Should -Be 1
        $r.prefix[0].content[0].text | Should -Be 'unrelated content'
    }
}
