# T005 [019] — The ownership decision (contracts/ownership-decision.md §1).
# Mirror of tests/bash/engine/test_managed_ownership.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Engine = Join-Path $Root 'scripts/powershell/engine'
    Import-Module (Join-Path $Engine 'ManagedSection.psm1') -Force
    $script:Marker = 'Synced from spec-kit — do not edit below this line'
    $script:Managed = '[{"type":"paragraph","content":[{"type":"text","text":"managed body"}]}]'
}

Describe 'Managed-section ownership split' {
    It 'row 1: marker occurs more than once is malformed regardless of ownership' {
        $existing = "[
          {`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"$Marker`",`"marks`":[{`"type`":`"strong`"}]}]},
          {`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"$Marker`",`"marks`":[{`"type`":`"strong`"}]}]}
        ]"
        $r = Split-JiraManagedSectionOwnership -Marker $Marker -ManagedJson $Managed -Ownership 'self' -ExistingJson $existing | ConvertFrom-Json
        $r.status | Should -Be 'malformed'
        ($r.PSObject.Properties.Name -contains 'prefix') | Should -BeFalse
    }

    It 'row 2: marker occurs exactly once keeps the prefix above it, status ok' {
        $existing = "[
          {`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"Human note.`"}]},
          {`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"$Marker`",`"marks`":[{`"type`":`"strong`"}]}]},
          {`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"old managed body`"}]}
        ]"
        $r = Split-JiraManagedSectionOwnership -Marker $Marker -ManagedJson $Managed -Ownership 'other' -ExistingJson $existing | ConvertFrom-Json
        $r.status | Should -Be 'ok'
        @($r.prefix).Count | Should -Be 1
        $r.prefix[0].content[0].text | Should -Be 'Human note.'
    }

    It 'row 3: marker absent, ownership self yields an empty prefix, status ok' {
        $existing = '[{"type":"paragraph","content":[{"type":"text","text":"whatever the mirror wrote before"}]}]'
        $r = Split-JiraManagedSectionOwnership -Marker $Marker -ManagedJson $Managed -Ownership 'self' -ExistingJson $existing | ConvertFrom-Json
        $r.status | Should -Be 'ok'
        @($r.prefix).Count | Should -Be 0
    }

    It 'row 4a: marker absent, ownership other, suffix matches — prefix is the human text before it, status ok' {
        $existing = @'
[
  {"type":"paragraph","content":[{"type":"text","text":"Human note."}]},
  {"type":"paragraph","content":[{"type":"text","text":"managed body"}]}
]
'@
        $r = Split-JiraManagedSectionOwnership -Marker $Marker -ManagedJson $Managed -Ownership 'other' -ExistingJson $existing | ConvertFrom-Json
        $r.status | Should -Be 'ok'
        @($r.prefix).Count | Should -Be 1
        $r.prefix[0].content[0].text | Should -Be 'Human note.'
    }

    It 'row 4b: marker absent, ownership other, suffix does not match — whole content preserved, status migrated-warned' {
        $existing = '[{"type":"paragraph","content":[{"type":"text","text":"unrelated content"}]}]'
        $r = Split-JiraManagedSectionOwnership -Marker $Marker -ManagedJson $Managed -Ownership 'other' -ExistingJson $existing | ConvertFrom-Json
        $r.status | Should -Be 'migrated-warned'
        @($r.prefix).Count | Should -Be 1
        $r.prefix[0].content[0].text | Should -Be 'unrelated content'
    }

    It 'row 5: marker absent, ownership unknown — whole content preserved, status migrated-warned' {
        $existing = '[{"type":"paragraph","content":[{"type":"text","text":"managed body"}]}]'
        $r = Split-JiraManagedSectionOwnership -Marker $Marker -ManagedJson $Managed -Ownership 'unknown' -ExistingJson $existing | ConvertFrom-Json
        $r.status | Should -Be 'migrated-warned'
        @($r.prefix).Count | Should -Be 1
    }

    It 'treats an unrecognised ownership string as unknown' {
        $existing = '[{"type":"paragraph","content":[{"type":"text","text":"managed body"}]}]'
        $r = Split-JiraManagedSectionOwnership -Marker $Marker -ManagedJson $Managed -Ownership 'bogus' -ExistingJson $existing | ConvertFrom-Json
        $r.status | Should -Be 'migrated-warned'
        @($r.prefix).Count | Should -Be 1
    }
}
