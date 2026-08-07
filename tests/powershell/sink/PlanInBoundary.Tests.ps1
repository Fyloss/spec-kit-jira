# 018, T031 [US1] — mirror of tests/bash/sink/test_plan_in_boundary.bats
# (FR-001-FR-005, FR-033): the plan section inside the managed region.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Adf.psm1') -Force
    $script:Marker = Get-JiraManagedMarker

    function script:HumanDesc([string] $PrefixText, [object[]] $Managed) {
        $content = [System.Collections.Generic.List[object]]::new()
        $content.Add([ordered]@{ type = 'paragraph'; content = @(@{ type = 'text'; text = $PrefixText }) })
        $content.Add([ordered]@{ type = 'paragraph'; content = @(@{ type = 'text'; text = $script:Marker; marks = @(@{ type = 'strong' }) }) })
        foreach ($n in $Managed) { $content.Add($n) }
        return [ordered]@{ type = 'doc'; version = 1; content = $content }
    }

    function script:PlanDoc([object[]] $PlanBlocks) {
        return [ordered]@{
            routing = [ordered]@{ project_key = 'COMP' }
            epic    = [ordered]@{
                title       = 'The Epic'
                local_id    = '3f2a91c04b7e6d18'
                marker      = [ordered]@{ state = 'assigned'; id = '3f2a91c04b7e6d18'; lines = @(2) }
                description = [ordered]@{ blocks = (@(@{ type = 'paragraph'; spans = @(@{ text = 'Epic overview.'; marks = @() }) }) + $PlanBlocks) }
            }
            stories = @()
        }
    }

    $script:PlanA = @(
        @{ type = 'heading'; level = 3; spans = @(@{ text = 'Implementation Plan'; marks = @() }) },
        @{ type = 'paragraph'; spans = @(@{ text = 'Use a shared library.'; marks = @() }) }
    )
    $script:PlanB = @(
        @{ type = 'heading'; level = 3; spans = @(@{ text = 'Implementation Plan'; marks = @() }) },
        @{ type = 'paragraph'; spans = @(@{ text = 'Use a different approach.'; marks = @() }) }
    )
    $script:NoPlan = @()

    function script:ManagedFor([object[]] $PlanBlocks) {
        $doc = PlanDoc $PlanBlocks
        $epicJson = ConvertTo-Json -InputObject $doc.epic -Depth 100 -Compress
        return @((ConvertTo-JiraAdfDocument -ContentJson $epicJson | ConvertFrom-Json -Depth 100).content)
    }
}

Describe 'T031 (FR-001-FR-005, FR-033) — the plan section inside the managed region' {
    It 'FR-001 — the plan section sits inside the managed region, below a preserved prefix' {
        $managed = ManagedFor $script:NoPlan
        $existing = HumanDesc 'A PO wrote this on the epic.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $docJson = ConvertTo-Json -InputObject (PlanDoc $script:PlanA) -Depth 100 -Compress
        $r = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r.parent.body.fields.description
        $desc.content[0].content[0].text | Should -Be 'A PO wrote this on the epic.'
        (ConvertTo-Json -InputObject $desc.content -Depth 100 -Compress) | Should -BeLike '*Implementation Plan*'
        $markerIdx = -1; $planIdx = -1
        for ($i = 0; $i -lt $desc.content.Count; $i++) {
            $n = $desc.content[$i]
            $t = $null
            if ($n.content -and $n.content[0].PSObject.Properties['text']) { $t = $n.content[0].text }
            if ($t -eq $script:Marker) { $markerIdx = $i }
            if ($t -eq 'Implementation Plan') { $planIdx = $i }
        }
        $planIdx | Should -BeGreaterThan $markerIdx
    }

    It 'FR-002 — a plan change replaces the section in place; exactly one exists' {
        $managed = ManagedFor $script:PlanA
        $existing = HumanDesc 'A PO wrote this on the epic.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $docJson = ConvertTo-Json -InputObject (PlanDoc $script:PlanB) -Depth 100 -Compress
        $r = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r.parent.body.fields.description
        $headings = @($desc.content | Where-Object { $_.content -and $_.content[0].PSObject.Properties['text'] -and $_.content[0].text -eq 'Implementation Plan' })
        $headings.Count | Should -Be 1
        $descText = ConvertTo-Json -InputObject $desc.content -Depth 100 -Compress
        $descText | Should -BeLike '*Use a different approach.*'
        $descText | Should -Not -BeLike '*Use a shared library.*'
    }

    It 'FR-003 — no plan.md yields no plan section and no warning' {
        $ctx = '{"base_url":"https://mock","parent_type_id":"10101","tickets":{}}'
        $docJson = ConvertTo-Json -InputObject (PlanDoc $script:NoPlan) -Depth 100 -Compress
        $r = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r.parent.body.fields.description
        (ConvertTo-Json -InputObject $desc.content -Depth 100 -Compress) | Should -Not -BeLike '*Implementation Plan*'
        $warningsMember = $r.PSObject.Properties['warnings']
        if ($null -ne $warningsMember) { @($warningsMember.Value).Count | Should -Be 0 }
    }

    It 'FR-004 — a plan that later yields nothing removes the section' {
        $managed = ManagedFor $script:PlanA
        $existing = HumanDesc 'A PO wrote this on the epic.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $docJson = ConvertTo-Json -InputObject (PlanDoc $script:NoPlan) -Depth 100 -Compress
        $r = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r.parent.body.fields.description
        (ConvertTo-Json -InputObject $desc.content -Depth 100 -Compress) | Should -Not -BeLike '*Implementation Plan*'
        $desc.content[0].content[0].text | Should -Be 'A PO wrote this on the epic.'
    }

    It 'FR-005 — an unchanged plan produces zero writes' {
        $managed = ManagedFor $script:PlanA
        $existing = HumanDesc 'A PO wrote this on the epic.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $docJson = ConvertTo-Json -InputObject (PlanDoc $script:PlanA) -Depth 100 -Compress
        $r = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $r.parent | Should -Be $null
    }

    It "FR-033 — the payload is deterministic: --dry-run's report is exactly what the real run sends" {
        $managed = ManagedFor $script:NoPlan
        $existing = HumanDesc 'A PO wrote this on the epic.' $managed
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $docJson = ConvertTo-Json -InputObject (PlanDoc $script:PlanA) -Depth 100 -Compress
        $out1 = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx
        $out2 = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx
        $out1 | Should -Be $out2
    }
}

Describe '019, T025 — origin bridge, no boundary, parent tier (US2 AC1-AC3)' {
    # A parent description written by a release predating the boundary — no
    # marker, the whole content the mirror's own — carries no human prefix,
    # so this skips HumanDesc's prefix and marker paragraph entirely.
    function script:BridgeDescNoBoundary([object[]] $Managed) {
        return [ordered]@{ type = 'doc'; version = 1; content = $Managed }
    }

    It '019, T024 — origin bridge, no boundary, changed plan summary: exactly one section, no trace of the previous (FR-010)' {
        $managedA = ManagedFor $script:PlanA
        $existing = BridgeDescNoBoundary $managedA
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_origin`":`"bridge`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $docJson = ConvertTo-Json -InputObject (PlanDoc $script:PlanB) -Depth 100 -Compress
        $r = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r.parent.body.fields.description
        $headings = @($desc.content | Where-Object { $_.content -and $_.content[0].PSObject.Properties['text'] -and $_.content[0].text -eq 'Implementation Plan' })
        $headings.Count | Should -Be 1
        $descText = ConvertTo-Json -InputObject $desc.content -Depth 100 -Compress
        $descText | Should -BeLike '*Use a different approach.*'
        $descText | Should -Not -BeLike '*Use a shared library.*'
        $warningsMember = $r.PSObject.Properties['warnings']
        if ($null -ne $warningsMember) { @($warningsMember.Value).Count | Should -Be 0 }
    }

    It '019, T024 — plan summary and specification both changed in one run settle in a single write (US2 AC3)' {
        $managedA = ManagedFor $script:PlanA
        $existing = BridgeDescNoBoundary $managedA
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_origin`":`"bridge`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $docB = PlanDoc $script:PlanB
        $docB.epic.description.blocks[0].spans[0].text = 'Epic overview, revised.'
        $docBJson = ConvertTo-Json -InputObject $docB -Depth 100 -Compress
        $r1 = Get-JiraPlanWriteSet -NeutralDocJson $docBJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r1.parent.body.fields.description
        $descText = ConvertTo-Json -InputObject $desc.content -Depth 100 -Compress
        $descText | Should -BeLike '*Epic overview, revised.*'
        $descText | Should -BeLike '*Use a different approach.*'
        $descText | Should -Not -BeLike '*Use a shared library.*'

        # The run after it, against the just-written description, writes nothing.
        $existingJson2 = ConvertTo-Json -InputObject $desc -Depth 100 -Compress
        $ctx2 = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_origin`":`"bridge`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson2},`"tickets`":{}}"
        $r2 = Get-JiraPlanWriteSet -NeutralDocJson $docBJson -PlanContextJson $ctx2 | ConvertFrom-Json -Depth 100
        $r2.parent | Should -Be $null
    }

    It '019, T026 — origin bridge, no boundary, no plan.md: no plan content, no warning, on the run that establishes the boundary and every run after (US2 AC2)' {
        $managedA = ManagedFor $script:NoPlan
        $existing = BridgeDescNoBoundary $managedA
        $existingJson = ConvertTo-Json -InputObject $existing -Depth 100 -Compress
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_origin`":`"bridge`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $docJson = ConvertTo-Json -InputObject (PlanDoc $script:NoPlan) -Depth 100 -Compress
        $r1 = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $r1.parent.body.fields.description
        (ConvertTo-Json -InputObject $desc.content -Depth 100 -Compress) | Should -Not -BeLike '*Implementation Plan*'
        $warningsMember = $r1.PSObject.Properties['warnings']
        if ($null -ne $warningsMember) { @($warningsMember.Value).Count | Should -Be 0 }

        $existingJson2 = ConvertTo-Json -InputObject $desc -Depth 100 -Compress
        $ctx2 = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_origin`":`"bridge`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson2},`"tickets`":{}}"
        $r2 = Get-JiraPlanWriteSet -NeutralDocJson $docJson -PlanContextJson $ctx2 | ConvertFrom-Json -Depth 100
        $r2.parent | Should -Be $null
    }
}
