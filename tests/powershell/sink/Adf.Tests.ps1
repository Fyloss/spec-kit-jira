# T051 [US3] — ADF rendering, PowerShell side. Mirror of tests/bash/sink/test_adf.bats.
# Cross-port byte-parity is proven in bats; here we assert the port's behaviour.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    $script:Content = @'
{
  "description": {"blocks": [{"type":"paragraph","spans":[{"text":"The need statement.","marks":[]}]}]},
  "acceptance_criteria": [{"given":[[{"text":"a user","marks":[]}]],"when":[[{"text":"they click","marks":[]}]],"then":[[{"text":"it opens","marks":[]}]]}],
  "design": [{"kind":"guidance","value":[{"text":"Use the blue accent.","marks":[]}]},{"kind":"figma_link","label":"Board","value":"https://www.figma.com/file/abc"}]
}
'@
}

Describe 'ConvertTo-JiraAdfDocument' {
    It 'renders a valid ADF doc envelope' {
        $d = ConvertTo-JiraAdfDocument -ContentJson $script:Content | ConvertFrom-Json
        $d.type | Should -Be 'doc'
        $d.version | Should -Be 1
    }
    It 'renders description blocks as paragraph nodes' {
        $d = ConvertTo-JiraAdfDocument -ContentJson $script:Content | ConvertFrom-Json
        @($d.content | Where-Object { $_.type -eq 'paragraph' -and $_.content[0].text -eq 'The need statement.' }).Count | Should -BeGreaterOrEqual 1
    }
    It 'renders acceptance criteria into a dedicated panel (FR-015)' {
        $d = ConvertTo-JiraAdfDocument -ContentJson $script:Content | ConvertFrom-Json
        $panels = @($d.content | Where-Object { $_.type -eq 'panel' })
        $panels.Count | Should -Be 1
        $texts = ($panels[0].content | ForEach-Object { ($_.content | ForEach-Object { $_.text }) -join '' }) -join '|'
        $texts | Should -BeLike '*Given a user*'
        $texts | Should -BeLike '*When they click*'
        $texts | Should -BeLike '*Then it opens*'
    }
    It 'renders a distinct Design section (FR-016)' {
        $d = ConvertTo-JiraAdfDocument -ContentJson $script:Content | ConvertFrom-Json
        @($d.content | Where-Object { $_.type -eq 'heading' -and $_.content[0].text -eq 'Design' }).Count | Should -Be 1
    }
    It 'omits the panel when there is no acceptance criteria' {
        $c = '{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}}'
        $d = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json
        @($d.content | Where-Object { $_.type -eq 'panel' }).Count | Should -Be 0
    }
}

Describe 'ConvertTo-JiraManagedAdfDocument (018, T013, contract §3 — origin-independent)' {
    BeforeAll {
        $m = Get-JiraManagedMarker
        $script:ExistingHuman = @"
{"type":"doc","version":1,"content":[
  {"type":"paragraph","content":[{"type":"text","text":"A note the PO wrote."}]},
  {"type":"paragraph","content":[{"type":"text","text":"$m","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"OLD MANAGED BODY"}]}
]}
"@
    }

    It 'row 5 — a creation with no existing description carries no prefix, no warning (FR-020)' {
        $raw = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content
        $r = $raw | ConvertFrom-Json
        $r.status | Should -Be 'ok'
        $raw | Should -BeLike '*do not edit below this line*'
        $raw | Should -BeLike '*The need statement.*'
        $r.doc.content[0].content[0].text | Should -BeLike '*do not edit below this line*'
    }

    It 'row 2 — a well-formed boundary preserves the human prefix verbatim above a fresh managed panel (FR-007)' {
        $raw = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -ExistingJson $script:ExistingHuman
        $r = $raw | ConvertFrom-Json
        $r.status | Should -Be 'ok'
        $r.doc.content[0].content[0].text | Should -Be 'A note the PO wrote.'
        $raw | Should -BeLike '*do not edit below this line*'
        $raw | Should -Not -BeLike '*OLD MANAGED BODY*'
        $raw | Should -BeLike '*The need statement.*'
    }

    It 'row 1 — more than one delimiter is malformed: no doc, status malformed (FR-012)' {
        $malformed = @"
{"type":"doc","version":1,"content":[
  {"type":"paragraph","content":[{"type":"text","text":"Human note."}]},
  {"type":"paragraph","content":[{"type":"text","text":"$m","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"body one"}]},
  {"type":"paragraph","content":[{"type":"text","text":"$m","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"body two"}]}
]}
"@
        $r = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -ExistingJson $malformed | ConvertFrom-Json
        $r.status | Should -Be 'malformed'
        $r.PSObject.Properties.Name | Should -Not -Contain 'doc'
    }

    It 'row 3 — clean migration: existing ends with the freshly rendered managed nodes, no duplication (FR-020a)' {
        $managed = (ConvertTo-JiraAdfDocument -ContentJson $script:Content | ConvertFrom-Json).content
        $preRelease = (@{ type = 'doc'; version = 1; content = $managed } | ConvertTo-Json -Depth 100 -Compress)
        # 019: origin 'human' keeps this on the suffix-split ('other') path
        # it was written to test; omitting Origin now defaults to 'unknown'
        # (contract §2), a different row of the decision table.
        $raw = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -ExistingJson $preRelease -Origin 'human'
        $r = $raw | ConvertFrom-Json
        $r.status | Should -Be 'ok'
        $needTexts = @($r.doc.content | Where-Object { $_.content -and $_.content[0].text -eq 'The need statement.' })
        $needTexts.Count | Should -Be 1
        $raw | Should -BeLike '*do not edit below this line*'
    }

    It 'row 4 — ambiguous migration preserves everything and warns by status (FR-020b)' {
        $unrelated = '{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"unrelated prior content"}]}]}'
        $raw = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -ExistingJson $unrelated
        $r = $raw | ConvertFrom-Json
        $r.status | Should -Be 'migrated-warned'
        $raw | Should -BeLike '*unrelated prior content*'
        $raw | Should -BeLike '*do not edit below this line*'
        $raw | Should -BeLike '*The need statement.*'
    }

    It 'reproduces the description byte-for-byte when the managed content is unchanged (idempotent)' {
        $once = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -ExistingJson $script:ExistingHuman | ConvertFrom-Json
        $onceDocJson = $once.doc | ConvertTo-Json -Depth 100 -Compress
        $twice = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -ExistingJson $onceDocJson | ConvertFrom-Json
        $twice.status | Should -Be 'ok'
        $twiceDocJson = $twice.doc | ConvertTo-Json -Depth 100 -Compress
        [System.String]::Equals($onceDocJson, $twiceDocJson, [System.StringComparison]::Ordinal) | Should -BeTrue
    }
}
