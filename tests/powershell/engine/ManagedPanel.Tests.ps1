# T074 [US7] — Origin-discriminated managed-panel splice (engine, neutral).
# Mirror of tests/bash/engine/test_managed_panel.bats. The marker is a parameter;
# nodes are treated as opaque JSON. Split an existing description into the human
# prefix (preserved verbatim) and the previously-written managed section
# (FR-038/FR-039).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Engine = Join-Path $Root '.specify/extensions/jira/scripts/powershell/engine'
    Import-Module (Join-Path $Engine 'ManagedSection.psm1') -Force
    $script:Marker = 'Synced from spec-kit — do not edit below this line'
    $script:HumanDesc = @'
[
  {"type":"paragraph","content":[{"type":"text","text":"Human intro line."}]},
  {"type":"paragraph","content":[{"type":"text","text":"Second human note."}]},
  {"type":"paragraph","content":[{"type":"text","text":"Synced from spec-kit — do not edit below this line","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"MANAGED BODY"}]}
]
'@
}

Describe 'Managed-panel split' {
    It 'splits an existing description into human prefix and managed section at the marker' {
        $r = Split-JiraManagedSectionPanel -Marker $Marker -ContentJson $HumanDesc | ConvertFrom-Json
        $r.had_marker | Should -BeTrue
        @($r.prefix).Count | Should -Be 2
        $r.prefix[0].content[0].text | Should -Be 'Human intro line.'
        $r.prefix[1].content[0].text | Should -Be 'Second human note.'
        @($r.managed).Count | Should -Be 2
        $r.managed[0].content[0].text | Should -BeLike '*do not edit below this line*'
    }

    It 'treats the whole array as human prefix when no marker is present' {
        $plain = '[{"type":"paragraph","content":[{"type":"text","text":"only human text"}]}]'
        $r = Split-JiraManagedSectionPanel -Marker $Marker -ContentJson $plain | ConvertFrom-Json
        $r.had_marker | Should -BeFalse
        @($r.prefix).Count | Should -Be 1
        @($r.managed).Count | Should -Be 0
    }

    It 'yields an empty prefix and no managed section for an empty description' {
        $r = Split-JiraManagedSectionPanel -Marker $Marker -ContentJson '[]' | ConvertFrom-Json
        $r.had_marker | Should -BeFalse
        @($r.prefix).Count | Should -Be 0
    }
}
