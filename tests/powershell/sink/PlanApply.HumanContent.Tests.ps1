# T075 [US7] — Human-content preservation in the write path, PowerShell side.
# Mirror of tests/bash/sink/test_us7_plan_apply.bats. Cross-port byte-parity is
# proven in bats; here the port's behaviour is asserted directly.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    # PlanApply imports Adf with -Force internally, which re-scopes Adf out of the
    # session; import the directly-called Adf LAST so Get-JiraManagedMarker resolves.
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    # -Global, and LAST: nested -Force imports re-scope Output.psm1 out of the
    # session — see PlanApply.Parent.Tests.ps1's note for the general rule.
    Import-Module (Join-Path $SinkDir '../../lib/Output.psm1') -Force -Global
    $script:Marker = Get-JiraManagedMarker
    $script:Doc = '{"routing":{"project_key":"COMP"},"epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18","marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},"stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2","description":{"blocks":[{"type":"paragraph","spans":[{"text":"New managed body.","marks":[]}]}]}}]}'
    $m = $script:Marker
    $script:Existing = @"
{"type":"doc","version":1,"content":[
  {"type":"paragraph","content":[{"type":"text","text":"PO handwritten note."}]},
  {"type":"paragraph","content":[{"type":"text","text":"$m","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"stale managed body"}]}
]}
"@
    $script:Ctx = @"
{"base_url":"https://mock","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18","tickets":{"s1":"PROJ-1"},"ticket_origins":{"s1":"human"},"ticket_descriptions":{"s1":$($script:Existing)}}
"@
}

Describe 'Get-JiraPlanWriteSet (US7 human origin)' {
    It 'preserves the human prefix and drops the stale managed body (FR-038)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:Ctx | ConvertFrom-Json
        $desc = $r.stories[0].body.fields.description
        $desc.content[0].content[0].text | Should -Be 'PO handwritten note.'
        $out = ConvertTo-Json -InputObject $desc -Depth 100 -Compress
        $out | Should -BeLike '*do not edit below this line*'
        $out | Should -Not -BeLike '*stale managed body*'
        $out | Should -BeLike '*New managed body.*'
    }

    It '018, T021 — a bridge-created update preserves the human prefix and renders a delimited managed region below it' {
        # Reproduction of the reported defect: a bridge-created ticket (no
        # ticket_origins entry at all) must not overwrite a human's prose.
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_local_id`":`"3f2a91c04b7e6d18`",`"tickets`":{`"s1`":`"PROJ-1`"},`"ticket_descriptions`":{`"s1`":$($script:Existing)}}"
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json
        $desc = $r.stories[0].body.fields.description
        $desc.content[0].content[0].text | Should -Be 'PO handwritten note.'
        $out = ConvertTo-Json -InputObject $desc -Depth 100 -Compress
        $out | Should -BeLike '*do not edit below this line*'
        $out | Should -Not -BeLike '*stale managed body*'
        $out | Should -BeLike '*New managed body.*'
    }

    It 'T059 [016, US3] — a human-authored prefix carrying Markdown-like syntax survives the rewrite byte-for-byte, untouched by the renderer (FR-013)' {
        $humanPrefix = '**PO** note with `raw` markup and a [link](https://ex.invalid) — never rendered, never touched.'
        $m = $script:Marker
        $existing = @"
{"type":"doc","version":1,"content":[
  {"type":"paragraph","content":[{"type":"text","text":"$humanPrefix"}]},
  {"type":"paragraph","content":[{"type":"text","text":"$m","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"stale managed body"}]}
]}
"@
        $ctx = @"
{"base_url":"https://mock","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18","tickets":{"s1":"PROJ-1"},"ticket_origins":{"s1":"human"},"ticket_descriptions":{"s1":$existing}}
"@

        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json
        $desc = $r.stories[0].body.fields.description
        $desc.content[0].content[0].text | Should -Be $humanPrefix
        $gotCanon = ConvertTo-JiraCanonicalJson (ConvertTo-Json -InputObject $desc.content[0] -Depth 100 -Compress)
        $wantCanon = ConvertTo-JiraCanonicalJson (ConvertTo-Json -InputObject ($existing | ConvertFrom-Json).content[0] -Depth 100 -Compress)
        $gotCanon | Should -Be $wantCanon
    }
}

Describe 'Get-JiraManagedDescriptionStatus (FR-039)' {
    It 'reports unchanged when only the human prose above the panel differs' {
        $m = $script:Marker
        $cur = @"
{"type":"doc","version":1,"content":[
  {"type":"paragraph","content":[{"type":"text","text":"ORIGINAL human note."}]},
  {"type":"paragraph","content":[{"type":"text","text":"$m","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"managed body"}]}
]}
"@
        $new = @"
{"type":"doc","version":1,"content":[
  {"type":"paragraph","content":[{"type":"text","text":"EDITED human note by the PO."}]},
  {"type":"paragraph","content":[{"type":"text","text":"$m","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"managed body"}]}
]}
"@
        Get-JiraManagedDescriptionStatus -CurrentDescJson $cur -NewDescJson $new | Should -Be 'unchanged'
    }

    It 'reports changed when the managed body differs' {
        $m = $script:Marker
        $a = "{`"content`":[{`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"$m`"}]},{`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"old`"}]}]}"
        $b = "{`"content`":[{`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"$m`"}]},{`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"new`"}]}]}"
        Get-JiraManagedDescriptionStatus -CurrentDescJson $a -NewDescJson $b | Should -Be 'changed'
    }
}
