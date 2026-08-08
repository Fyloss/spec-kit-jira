# T053 [Phase 6, US4] — the one-time upgrade of a pre-release estate onto the
# boundary (FR-020/FR-020a/FR-020b/FR-021), PowerShell side. Mirror of
# tests/bash/sink/test_boundary_migration.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-pre-release-migration'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Identity.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Client.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_ID_SOURCE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

Describe 'Invoke-JiraReconcile — pre-release boundary migration' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/preserve-pre-release.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'an untouched pre-release story migrates with nothing above the boundary and no duplication (FR-020a)' {
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $pre1 = $out.actions | Where-Object { $_.url -like '*PRE-1' }
        $pre1 | Should -Not -BeNullOrEmpty
        $pre1.body.fields.description.content[0].content[0].text | Should -Be 'Synced from spec-kit — do not edit below this line'
        $texts = @($pre1.body.fields.description.content | ForEach-Object { $_.content[0].text })
        @($texts | Where-Object { $_ -eq 'As a user, I want my note kept.' }).Count | Should -Be 1
        @($out.warnings | Where-Object { $_ -match 'PRE-1' }).Count | Should -Be 0
    }

    It 'a human-prefixed pre-release story keeps its prefix exactly (FR-020a)' {
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $pre2 = $out.actions | Where-Object { $_.url -like '*PRE-2' }
        $pre2 | Should -Not -BeNullOrEmpty
        $pre2.body.fields.description.content[0].content[0].text | Should -Be 'A human paragraph added after the mirror last wrote.'
        $pre2.body.fields.description.content[1].content[0].text | Should -Be 'Synced from spec-kit — do not edit below this line'
        $texts = @($pre2.body.fields.description.content | ForEach-Object { $_.content[0].text })
        @($texts | Where-Object { $_ -eq 'As a user, I want my note kept.' }).Count | Should -Be 1
        @($out.warnings | Where-Object { $_ -match 'PRE-2' }).Count | Should -Be 0
    }

    It 'an ambiguous pre-release story loses nothing and produces one warning naming the ticket key (FR-020b)' {
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $pre3 = $out.actions | Where-Object { $_.url -like '*PRE-3' }
        $pre3 | Should -Not -BeNullOrEmpty
        $pre3.body.fields.description.content[0].content[0].text | Should -Be 'Some unrelated content nobody expected.'
        $pre3.body.fields.description.content[1].content[0].text | Should -Be 'Synced from spec-kit — do not edit below this line'
        @($out.warnings | Where-Object { $_ -match 'PRE-3' }).Count | Should -Be 1
    }

    It 'the run after each migration reports zero writes (FR-021)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        Clear-Content -LiteralPath $script:M.CallLog
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $out.counts.updated | Should -Be 0
        $out.counts.created | Should -Be 0
        # reconcile emits JSON `null`, not `[]`, for an empty warnings list —
        # ConvertFrom-Json turns that into $null, and @($null) has Count 1.
        @($out.warnings | Where-Object { $_ }).Count | Should -Be 0
        # 021 US4's prefetch fires its own bulkfetch POST as a read, not a write.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^(POST|PUT) ' -and $_ -notmatch 'issue/bulkfetch' }).Count | Should -Be 0
    }
}

# --- 019, T010: the reported defect — origin bridge, no boundary, an edited
# specification — driven directly through Get-JiraPlanWriteSet rather than
# the mock pipeline above. Mirror of the two 019, T009 bats cases.

Describe 'Get-JiraPlanWriteSet — the reported defect (019)' {
    BeforeAll {
        $PlanApply = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira/PlanApply.psm1'
        $Adf = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira/Adf.psm1'
        Import-Module $PlanApply -Force
        Import-Module $Adf -Force

        $script:DocAc = @'
{"routing":{"project_key":"COMP"},
 "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18","marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]}},
 "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2",
             "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]},
             "acceptance_criteria":[{"given":[[{"text":"the page is open","marks":[]}]],"when":[[{"text":"the button is clicked","marks":[]}]],"then":[[{"text":"Hello Universe is shown","marks":[]}]]}]}]}
'@
    }

    It '019, T010 — origin bridge, no boundary, edited acceptance criteria: exactly one AC section, status ok, no warning (FR-002)' {
        $oldAc = '{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]},"acceptance_criteria":[{"given":[[{"text":"the page is open","marks":[]}]],"when":[[{"text":"the button is clicked","marks":[]}]],"then":[[{"text":"Hello World is shown","marks":[]}]]}]}'
        $rendered = ConvertTo-JiraAdfDocument -ContentJson $oldAc | ConvertFrom-Json
        $existing = (@{ type = 'doc'; version = 1; content = $rendered.content } | ConvertTo-Json -Depth 100 -Compress)
        $ctx = (@{ base_url = 'https://mock'; parent_type_id = '10101'; parent_local_id = '3f2a91c04b7e6d18'
                tickets = @{ s1 = 'PROJ-1' }; ticket_descriptions = @{ s1 = ($existing | ConvertFrom-Json) }
                ticket_origins = @{ s1 = 'bridge' }; priority_ids = @{ P2 = '2' } } | ConvertTo-Json -Depth 100 -Compress)
        $out = Get-JiraPlanWriteSet -NeutralDocJson $script:DocAc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $out.stories[0].body.fields.description
        $descJson = $desc | ConvertTo-Json -Depth 100 -Compress
        $headings = @($desc.content | Where-Object { $_.type -eq 'heading' -and $_.content[0].text -eq 'Acceptance Criteria' })
        $headings.Count | Should -Be 1
        $descJson | Should -BeLike '*Hello Universe is shown*'
        $descJson | Should -Not -BeLike '*Hello World is shown*'
        @($out.warnings | Where-Object { $_ }).Count | Should -Be 0
    }

    It '019, T049 — origin bridge, no boundary, unchanged specification: exactly one AC section, status ok, no warning (US1 AC2)' {
        $rendered = ConvertTo-JiraAdfDocument -ContentJson (($script:DocAc | ConvertFrom-Json).stories[0] | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json
        $existing = (@{ type = 'doc'; version = 1; content = $rendered.content } | ConvertTo-Json -Depth 100 -Compress)
        $ctx = (@{ base_url = 'https://mock'; parent_type_id = '10101'; parent_local_id = '3f2a91c04b7e6d18'
                tickets = @{ s1 = 'PROJ-1' }; ticket_descriptions = @{ s1 = ($existing | ConvertFrom-Json) }
                ticket_origins = @{ s1 = 'bridge' }; priority_ids = @{ P2 = '2' } } | ConvertTo-Json -Depth 100 -Compress)
        $out = Get-JiraPlanWriteSet -NeutralDocJson $script:DocAc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $out.stories[0].body.fields.description
        $headings = @($desc.content | Where-Object { $_.type -eq 'heading' -and $_.content[0].text -eq 'Acceptance Criteria' })
        $headings.Count | Should -Be 1
        @($out.warnings | Where-Object { $_ }).Count | Should -Be 0
    }

    It '019, T021 — an undeterminable origin preserves the whole existing content and names the ticket in a warning (FR-004)' {
        $existing = '{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"unrelated content nobody expected"}]}]}'
        $doc = '{"routing":{"project_key":"COMP"},
                 "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18","marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},"description":{"blocks":[]}},
                 "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2","description":{"blocks":[{"type":"paragraph","spans":[{"text":"Story body.","marks":[]}]}]}}]}'
        $ctx = (@{ base_url = 'https://mock'; parent_type_id = '10101'; parent_local_id = '3f2a91c04b7e6d18'
                tickets = @{ s1 = 'PROJ-1' }; ticket_descriptions = @{ s1 = ($existing | ConvertFrom-Json) }
                ticket_origins = @{ s1 = 'corrupted-value' }; priority_ids = @{ P2 = '2' } } | ConvertTo-Json -Depth 100 -Compress)
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $descJson = $out.stories[0].body.fields.description | ConvertTo-Json -Depth 100 -Compress
        $descJson | Should -BeLike '*unrelated content nobody expected*'
        ($out.warnings -join ' ') | Should -BeLike '*PROJ-1*'
    }

    # --- 019, T046: the parent tier in the same condition (US1 AC3, FR-008).
    # All prior 019 cases above assert `.stories[0]` only, and PRE-9 in the
    # pre-release fixture already carries the marker (rule 2, not the
    # marker-absent branch this feature adds). Mirror of the bash T046 case.
    It '019, T046 — origin bridge, no boundary, parent tier: the whole existing parent description is replaced, exactly one AC section, no warning (US1 AC3, FR-008)' {
        $oldAc = '{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]},"acceptance_criteria":[{"given":[[{"text":"the page is open","marks":[]}]],"when":[[{"text":"the button is clicked","marks":[]}]],"then":[[{"text":"Hello World is shown","marks":[]}]]}]}'
        $rendered = ConvertTo-JiraAdfDocument -ContentJson $oldAc | ConvertFrom-Json
        $existingJson = (@{ type = 'doc'; version = 1; content = $rendered.content } | ConvertTo-Json -Depth 100 -Compress)
        $ctx = "{`"base_url`":`"https://mock`",`"parent_type_id`":`"10101`",`"parent_key`":`"PROJ-1`",`"parent_origin`":`"bridge`",`"parent_current`":{`"summary`":`"The Epic`",`"description`":$existingJson},`"tickets`":{}}"
        $docParent = @'
{"routing":{"project_key":"COMP"},
 "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18","marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
         "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]},
         "acceptance_criteria":[{"given":[[{"text":"the page is open","marks":[]}]],"when":[[{"text":"the button is clicked","marks":[]}]],"then":[[{"text":"Hello Universe is shown","marks":[]}]]}]},
 "stories":[]}
'@
        $out = Get-JiraPlanWriteSet -NeutralDocJson $docParent -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $desc = $out.parent.body.fields.description
        $descJson = $desc | ConvertTo-Json -Depth 100 -Compress
        $headings = @($desc.content | Where-Object { $_.type -eq 'heading' -and $_.content[0].text -eq 'Acceptance Criteria' })
        $headings.Count | Should -Be 1
        $descJson | Should -BeLike '*Hello Universe is shown*'
        $descJson | Should -Not -BeLike '*Hello World is shown*'
        @($out.warnings | Where-Object { $_ }).Count | Should -Be 0
    }

    # --- 019, T052: the accepted-loss case, stated explicitly (spec Edge
    # Cases, Assumptions). Mirror of the bash T052 case.
    It '019, T052 — origin bridge, no boundary, a human paragraph typed into the gap: lost silently, not a warning (accepted trade-off)' {
        $rendered = ConvertTo-JiraAdfDocument -ContentJson (($script:DocAc | ConvertFrom-Json).stories[0] | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json
        $humanParagraph = @{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'A human paragraph typed after the boundary went missing.' }) }
        $content = [System.Collections.Generic.List[object]]::new()
        $content.Add($humanParagraph)
        foreach ($n in $rendered.content) { $content.Add($n) }
        $existing = (@{ type = 'doc'; version = 1; content = $content } | ConvertTo-Json -Depth 100 -Compress)
        $ctx = (@{ base_url = 'https://mock'; parent_type_id = '10101'; parent_local_id = '3f2a91c04b7e6d18'
                tickets = @{ s1 = 'PROJ-1' }; ticket_descriptions = @{ s1 = ($existing | ConvertFrom-Json) }
                ticket_origins = @{ s1 = 'bridge' }; priority_ids = @{ P2 = '2' } } | ConvertTo-Json -Depth 100 -Compress)
        $out = Get-JiraPlanWriteSet -NeutralDocJson $script:DocAc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $descJson = $out.stories[0].body.fields.description | ConvertTo-Json -Depth 100 -Compress
        $descJson | Should -Not -BeLike '*A human paragraph typed after the boundary went missing.*'
        @($out.warnings | Where-Object { $_ }).Count | Should -Be 0
    }
}
