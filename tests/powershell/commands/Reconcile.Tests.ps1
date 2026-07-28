# T059 [US3] — The reconcile command, PowerShell side. Mirror of
# tests/bash/commands/test_reconcile.bats. Cross-port parity is proven in bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:SPEC_KIT_JIRA_BASE_URL = 'https://mock'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_PROJECT_KEY = 'PROJ'
    $env:SPEC_KIT_JIRA_PLAN_CONTEXT = $null

    $script:SpecWith = Join-Path $TestDrive 'with.md'
    @(
        '# Feature Specification: Rich Tickets', '', 'We need a reconcile bridge for specs.', '',
        '### User Story 1 - The core story (Priority: P1)', '', 'Estimation: 5', '',
        '- **Given** a signed-in user', '- **When** they open the board', '- **Then** the widgets load'
    ) -join "`n" | Set-Content -LiteralPath $script:SpecWith -NoNewline

    $script:SpecNoSummary = Join-Path $TestDrive 'nosummary.md'
    '# Only A Title' | Set-Content -LiteralPath $script:SpecNoSummary -NoNewline

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

Describe 'Invoke-JiraReconcile (dry-run)' {
    It 'plans a create with the story title and a rich ADF description' {
        $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) | ConvertFrom-Json
        $out.actions[0].method | Should -Be 'POST'
        $out.actions[0].body.fields.summary | Should -Be 'The core story'
        $out.actions[0].body.fields.description.type | Should -Be 'doc'
        @($out.actions[0].body.fields.description.content | Where-Object { $_.type -eq 'panel' }).Count | Should -Be 1
    }

    It 'yields a non-empty description for a spec with no ## Summary (SC-002)' {
        $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecNoSummary) | ConvertFrom-Json
        $out.actions[0].body.fields.summary | Should -Be 'Only A Title'
        @($out.actions[0].body.fields.description.content | Where-Object { $_.type -eq 'paragraph' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'never re-sends the estimation on update (FR-018)' {
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"estimation_field_id":"customfield_30044","tickets":{"s1":"ABC-1"}}'
        try {
            $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) | ConvertFrom-Json
            $out.actions[0].method | Should -Be 'PUT'
            $out.actions[0].body.fields.PSObject.Properties.Name | Should -Not -Contain 'customfield_30044'
        }
        finally { $env:SPEC_KIT_JIRA_PLAN_CONTEXT = $null }
    }

    It 'reports host-relative action urls (no coordinate leaks)' {
        $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) | ConvertFrom-Json
        $out.actions[0].url | Should -Be '/rest/api/3/issue'
    }

    It 'resolves a bare relative spec filename from the current directory (NFR-1)' {
        # Split-Path -Parent yields '' for a bare filename, where the Bash port's
        # dirname yields '.' — the folder must still resolve instead of failing
        # the interchange schema with an empty spec_ref.folder.
        Push-Location $TestDrive
        try {
            $out = Invoke-Captured @('reconcile', '--dry-run', '--json', 'with.md') 2> $null | ConvertFrom-Json
            $script:code | Should -Be 0
            $out.actions[0].body.fields.summary | Should -Be 'The core story'
        }
        finally { Pop-Location }
    }

    It 'maps an invalid SPEC_KIT_JIRA_LIFECYCLE to exit 4 with an actionable error (FR-032)' {
        $env:SPEC_KIT_JIRA_LIFECYCLE = '{not json'
        try {
            $null = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) 2>$null
            $script:code | Should -Be 4
        }
        finally { $env:SPEC_KIT_JIRA_LIFECYCLE = $null }
    }
}

Describe 'Adoption reporting (003 T111, FR-018)' {
    BeforeAll {
        # The reporting helper is exercised directly so the assertion is about
        # the report itself, not about a whole dispatched run.
        $script:Adopted = '{"stories":[{"local_id":"s1","title":"S","priority_logical":"P2","description":{"blocks":[]}}]}'
        $script:HumanDesc = '{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"PO handwritten note."}]}]}'
    }

    It 'reports the ticket and that the panel was ADDED on the first reconcile' {
        $ctx = "{`"tickets`":{`"s1`":`"ADO-1`"},`"ticket_origins`":{`"s1`":`"human`"},`"ticket_descriptions`":{`"s1`":$script:HumanDesc}}"
        $r = @((Get-JiraReconcileAdoptedReport -NeutralDocJson $script:Adopted -PlanContextJson $ctx) | ConvertFrom-Json)
        $r.Count | Should -Be 1
        $r[0].ticket | Should -Be 'ADO-1'
        $r[0].action | Should -BeLike '*adopted ticket*'
        $r[0].action | Should -BeLike '*added below the existing description*'
        $r[0].action | Should -BeLike '*nothing outside it was touched*'
    }

    It 'reports the panel as UPDATED once the marker is present' {
        $marker = 'Synced from spec-kit — do not edit below this line'
        $desc = "{`"type`":`"doc`",`"version`":1,`"content`":[{`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"PO note.`"}]},{`"type`":`"paragraph`",`"content`":[{`"type`":`"text`",`"text`":`"$marker`"}]}]}"
        $ctx = "{`"tickets`":{`"s1`":`"ADO-1`"},`"ticket_origins`":{`"s1`":`"human`"},`"ticket_descriptions`":{`"s1`":$desc}}"
        $r = @((Get-JiraReconcileAdoptedReport -NeutralDocJson $script:Adopted -PlanContextJson $ctx) | ConvertFrom-Json)
        $r[0].action | Should -BeLike '*updated*'
        $r[0].action | Should -Not -BeLike '*added below*'
    }

    It 'reports nothing for a bridge-created ticket' {
        $ctx = "{`"tickets`":{`"s1`":`"ADO-1`"},`"ticket_origins`":{`"s1`":`"bridge-created`"},`"ticket_descriptions`":{`"s1`":$script:HumanDesc}}"
        (Get-JiraReconcileAdoptedReport -NeutralDocJson $script:Adopted -PlanContextJson $ctx) | Should -Be '[]'
    }

    It 'reports nothing when the story has no existing ticket' {
        (Get-JiraReconcileAdoptedReport -NeutralDocJson $script:Adopted -PlanContextJson '{}') | Should -Be '[]'
    }

    It 'omits the summary key entirely when no ticket is adopted' {
        $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecWith) 2> $null | ConvertFrom-Json
        $out.PSObject.Properties.Name | Should -Not -Contain 'adopted'
    }

    It 'surfaces the report in the DEFAULT prose output (Principle XVI)' {
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = "{`"tickets`":{`"s1`":`"ADO-1`"},`"ticket_origins`":{`"s1`":`"human`"},`"ticket_descriptions`":{`"s1`":$script:HumanDesc}}"
        try {
            $out = (Invoke-Captured @('reconcile', '--dry-run', $script:SpecWith) 2> $null) -join "`n"
            $out | Should -BeLike '*Adopted:*'
            $out | Should -BeLike '*ADO-1: adopted ticket*'
        }
        finally { $env:SPEC_KIT_JIRA_PLAN_CONTEXT = $null }
    }
}
