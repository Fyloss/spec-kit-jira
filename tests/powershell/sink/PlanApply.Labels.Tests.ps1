# T020 [US2] — mirror of tests/bash/sink/test_plan_apply_labels.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Identity.psm1') -Force

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

# --- T1, T2 — creation payloads (no recognised ticket, no mock needed) -----

Describe 'Invoke-JiraReconcile -- provenance label on creation (017, contract Section6 T1/T2)' {
    BeforeEach {
        $env:SPEC_KIT_JIRA_BASE_URL = 'https://mock'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST'
        $env:JIRA_CONFIG_DIR = Join-Path $Root 'tests/conformance/fixtures/repo-with-reconcile-legacy/.specify/jira'
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue

        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'fresh') -Force | Out-Null
        $script:SpecFresh = Join-Path $TestDrive 'fresh/spec.md'
        @(
            '# Feature Specification: Rich Tickets', '', 'We need a reconcile bridge for specs.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a signed-in user', '- **When** they open the board', '- **Then** the widgets load'
        ) -join "`n" | Set-Content -LiteralPath $script:SpecFresh -NoNewline
    }
    AfterEach { Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue }

    It 'T1 -- parent and child creation payloads carry speckit-<slug>' {
        $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecFresh) | ConvertFrom-Json
        $out.actions[0].role | Should -Be 'parent'
        ($out.actions[0].body.fields.labels -join ',') | Should -Be 'speckit-001-feature'
        $out.actions[1].role | Should -Be 'story'
        ($out.actions[1].body.fields.labels -join ',') | Should -Be 'speckit-001-feature'
    }

    It 'T2 -- a recorded labels field default survives alongside the provenance label' {
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"10004","parent_type_id":"10003","field_defaults":{"10004":{"labels":["team-x"]},"10003":{"labels":["team-x"]}}}'
        $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecFresh) | ConvertFrom-Json
        (@($out.actions[0].body.fields.labels) | Sort-Object) -join ',' | Should -Be 'speckit-001-feature,team-x'
        (@($out.actions[1].body.fields.labels) | Sort-Object) -join ',' | Should -Be 'speckit-001-feature,team-x'
    }

    It '017 regression -- the full pipeline surfaces a label-degradation warning (Get-JiraPlanWriteSet''s own warnings were never merged into the run summary)' {
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-' + ('a' * 252)
        try {
            $out = Invoke-Captured @('reconcile', '--dry-run', '--json', $script:SpecFresh) | ConvertFrom-Json
            @($out.warnings).Count | Should -BeGreaterThan 0
            (@($out.warnings) -join ' ') | Should -Match '255-character limit'
            ($out.actions[0].body.fields.PSObject.Properties.Name -contains 'labels') | Should -BeFalse
        }
        finally { $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature' }
    }
}

# --- T3, T5, T6, T8, T9, T14 — a mirrored corpus (real mock server) --------

Describe 'Invoke-JiraReconcile -- provenance label on a mirrored corpus (017, contract Section6)' {
    BeforeEach {
        $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-mirrored-spec'
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'

        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT, Env:\SPEC_KIT_JIRA_LIFECYCLE, Env:\SPEC_KIT_JIRA_HOOK_CONTEXT, `
            Env:\SPEC_KIT_JIRA_PROJECT_KEY, Env:\SPEC_KIT_JIRA_SPEC_SLUG, Env:\SPEC_KIT_JIRA_REPO -ErrorAction SilentlyContinue

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        # Prime: create COMP-1/2/3 and write their markers into SPEC.
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        # The mock persists `labels` on create, exactly as Jira does, so the
        # priming run above leaves its tickets already labelled. Strip the
        # label back off, so they land where an existing consumer's pre-017
        # tickets actually are: recognised, marker-bound, and carrying no
        # provenance label yet. This used to happen by itself, because the
        # mock's CREATE handler dropped `labels`; relying on that made the
        # zero-churn claim unprovable (a labelled creation read back
        # unlabelled forever), so the mock was made faithful and the pre-017
        # state is now set up explicitly.
        foreach ($k in @('COMP-1', 'COMP-2', 'COMP-3', 'COMP-4')) {
            Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/$k" -Method Put `
                -ContentType 'application/json' -Body '{"fields":{"labels":[]}}' | Out-Null
        }
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T3 -- a recognised ticket missing the label is updated exactly once; counts.updated reflects it' {
        Clear-Content -LiteralPath $script:M.CallLog
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $out.counts.updated | Should -Be 4
        $out.counts.created | Should -Be 0
        (@(Get-JiraMockIssueField -Mock $script:M -Key 'COMP-2' -Path 'fields.labels') | Sort-Object) -join ',' | Should -Be 'speckit-001-billing-invoices'
    }

    It 'T5 -- a ticket carrying operator labels keeps every one of them after the update' {
        Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" -Method Put -ContentType 'application/json' `
            -Body '{"fields":{"labels":["priority-review"]}}' | Out-Null
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $out.exit_code | Should -Be 0
        (@(Get-JiraMockIssueField -Mock $script:M -Key 'COMP-2' -Path 'fields.labels') | Sort-Object) -join ',' | Should -Be 'priority-review,speckit-001-billing-invoices'
    }

    It 'T6 -- current labels in a different order than ours still compare unchanged (the R4 regression)' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json') # back-fills the label once
        Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" -Method Put -ContentType 'application/json' `
            -Body '{"fields":{"labels":["priority-review","speckit-001-billing-invoices"]}}' | Out-Null
        Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" -Method Put -ContentType 'application/json' `
            -Body '{"fields":{"labels":["speckit-001-billing-invoices","priority-review"]}}' | Out-Null

        Clear-Content -LiteralPath $script:M.CallLog
        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $out.counts.updated | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'PUT /rest/api/3/issue/COMP-2' }).Count | Should -Be 0
    }

    It 'T8 -- a halted ticket is not labelled and no write is issued for it' {
        @'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      after_specify: "To Do"
    halted_statuses:
      - "Blocked"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
'@ | Set-Content -LiteralPath (Join-Path $script:Work '.specify/jira/config.yml') -NoNewline

        Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" -Method Put -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"Blocked","statusCategory":{"key":"indeterminate"}}}}' | Out-Null

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
        try {
            $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        } finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        $out.exit_code | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'PUT /rest/api/3/issue/COMP-2' }).Count | Should -Be 0
        # NOT `@(Get-JiraMockIssueField ...).Count` — @() around a $null
        # result (the field genuinely absent) wraps it into a ONE-element
        # array holding $null, not an empty array.
        $labelsField = Get-JiraMockIssueField -Mock $script:M -Key 'COMP-2' -Path 'fields.labels'
        $labelsField | Should -BeNullOrEmpty
    }

    It 'T9 -- --dry-run action bodies equal the real run''s, labels included' {
        $dryOut = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        $realOut = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json

        $dryLabels = (@($dryOut.actions) | ForEach-Object { (@($_.body.fields.labels) | Sort-Object) -join ',' }) | Sort-Object
        $realLabels = (@($realOut.actions) | ForEach-Object { (@($_.body.fields.labels) | Sort-Object) -join ',' }) | Sort-Object
        ($dryLabels -join ';') | Should -Be ($realLabels -join ';')
    }

    It 'T14 -- a ticket adopted through mention gains the label additively, the human''s own labels survive' {
        $content = Get-Content -Raw -LiteralPath $script:Spec
        $storyId = [regex]::Match($content, 'story=([0-9a-f]{16}) ticket=COMP-2').Groups[1].Value
        $specRef = '{"repo":"local/repo","spec_slug":"001-billing-invoices","folder":"x"}'
        $null = Set-JiraIdentity -IssueKey 'COMP-2' -SpecRefJson $specRef -Origin 'mention' -Story $storyId

        Invoke-RestMethod -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-2" -Method Put -ContentType 'application/json' `
            -Body '{"fields":{"labels":["a-humans-own-label"]}}' | Out-Null

        $out = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $out.exit_code | Should -Be 0
        (@(Get-JiraMockIssueField -Mock $script:M -Key 'COMP-2' -Path 'fields.labels') | Sort-Object) -join ',' | Should -Be 'a-humans-own-label,speckit-001-billing-invoices'
    }
}
