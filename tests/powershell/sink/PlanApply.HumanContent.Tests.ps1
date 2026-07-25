# T075 [US7] — Human-content preservation in the write path, PowerShell side.
# Mirror of tests/bash/sink/test_us7_plan_apply.bats. Cross-port byte-parity is
# proven in bats; here the port's behaviour is asserted directly.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    # PlanApply imports Adf with -Force internally, which re-scopes Adf out of the
    # session; import the directly-called Adf LAST so Get-JiraManagedMarker resolves.
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    $script:Marker = Get-JiraManagedMarker
    $script:Doc = '{"stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2","description":{"blocks":[{"type":"paragraph","text":"New managed body."}]}}]}'
    $m = $script:Marker
    $script:Existing = @"
{"type":"doc","version":1,"content":[
  {"type":"paragraph","content":[{"type":"text","text":"PO handwritten note."}]},
  {"type":"paragraph","content":[{"type":"text","text":"$m","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"stale managed body"}]}
]}
"@
    $script:Ctx = @"
{"base_url":"https://mock","tickets":{"s1":"PROJ-1"},"ticket_origins":{"s1":"human"},"ticket_descriptions":{"s1":$($script:Existing)}}
"@
}

Describe 'Get-JiraPlanWriteSet (US7 human origin)' {
    It 'preserves the human prefix and drops the stale managed body (FR-038)' {
        $a = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:Ctx | ConvertFrom-Json
        $desc = $a[0].body.fields.description
        $desc.content[0].content[0].text | Should -Be 'PO handwritten note.'
        $out = ConvertTo-Json -InputObject $desc -Depth 100 -Compress
        $out | Should -BeLike '*do not edit below this line*'
        $out | Should -Not -BeLike '*stale managed body*'
        $out | Should -BeLike '*New managed body.*'
    }

    It 'keeps the whole-description behaviour when no origin is given' {
        $ctx = '{"base_url":"https://mock","tickets":{"s1":"PROJ-1"}}'
        $a = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json
        $out = ConvertTo-Json -InputObject $a[0].body.fields.description -Depth 100 -Compress
        $out | Should -Not -BeLike '*do not edit below this line*'
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
