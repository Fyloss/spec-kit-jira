# T051 [US3] — ADF rendering, PowerShell side. Mirror of tests/bash/sink/test_adf.bats.
# Cross-port byte-parity is proven in bats; here we assert the port's behaviour.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    $script:Content = @'
{
  "description": {"blocks": [{"type":"paragraph","text":"The need statement."}]},
  "acceptance_criteria": [{"given":["a user"],"when":["they click"],"then":["it opens"]}],
  "design": [{"kind":"guidance","value":"Use the blue accent."},{"kind":"figma_link","label":"Board","value":"https://www.figma.com/file/abc"}]
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
        $texts = ($panels[0].content | ForEach-Object { $_.content[0].text }) -join '|'
        $texts | Should -BeLike '*Given a user*'
        $texts | Should -BeLike '*When they click*'
        $texts | Should -BeLike '*Then it opens*'
    }
    It 'renders a distinct Design section (FR-016)' {
        $d = ConvertTo-JiraAdfDocument -ContentJson $script:Content | ConvertFrom-Json
        @($d.content | Where-Object { $_.type -eq 'heading' -and $_.content[0].text -eq 'Design' }).Count | Should -Be 1
    }
    It 'omits the panel when there is no acceptance criteria' {
        $c = '{"description":{"blocks":[{"type":"paragraph","text":"x"}]}}'
        $d = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json
        @($d.content | Where-Object { $_.type -eq 'panel' }).Count | Should -Be 0
    }
}

Describe 'ConvertTo-JiraManagedAdfDocument (US7)' {
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

    It 'renders the whole description as the managed section for a bridge-created ticket (FR-040)' {
        $out = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -Origin 'bridge-created' -ExistingJson '{}'
        $out | Should -Not -BeLike '*do not edit below this line*'
        ($out | ConvertFrom-Json).type | Should -Be 'doc'
    }

    It 'preserves the human prefix verbatim above a delimited managed panel (FR-038)' {
        $out = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -Origin 'human' -ExistingJson $script:ExistingHuman
        $d = $out | ConvertFrom-Json
        $d.content[0].content[0].text | Should -Be 'A note the PO wrote.'
        $out | Should -BeLike '*do not edit below this line*'
        $out | Should -Not -BeLike '*OLD MANAGED BODY*'
        $out | Should -BeLike '*The need statement.*'
    }

    It 'reproduces the description byte-for-byte when the managed content is unchanged (idempotent)' {
        $once = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -Origin 'human' -ExistingJson $script:ExistingHuman
        $twice = ConvertTo-JiraManagedAdfDocument -ContentJson $script:Content -Origin 'human' -ExistingJson $once
        [System.String]::Equals($once, $twice, [System.StringComparison]::Ordinal) | Should -BeTrue
    }
}
