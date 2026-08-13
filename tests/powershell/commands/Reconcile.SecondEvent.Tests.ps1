# T059, T061, T063, T063b, T065 [Phase 5, US3] — a second lifecycle event
# over unchanged files still advances the board end to end through
# reconcile, PowerShell port. Mirror of
# tests/bash/commands/test_reconcile_second_event.bats.
#
# A dedicated minimal fixture, built inline rather than copied from
# repo-with-mirrored-spec: that fixture carries a stray spec-reordered.md
# which raises a warning on EVERY run, and S10 (a run raising any warning
# records no state) means the short-circuit these tests are ABOUT could
# never once engage against it.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/RunState.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    $script:ConfigYaml = @'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
'@

    $script:ConfigLocalYaml = @'
resolved_ids:
  COMP:
    style: company_managed
    issue_types:
      - logical_name: "Epic"
        id: "10001"
        hierarchy_level: "1"
        subtask: false
      - logical_name: "Story"
        id: "10004"
        hierarchy_level: "0"
        subtask: false
    child_type:
      logical_name: "Story"
      id: "10004"
      source: derived
    parent_type:
      logical_name: "Epic"
      id: "10001"
      source: derived
    required_fields:
      "10001":
        - logical_name: "Summary"
          field_id: "summary"
      "10004":
        - logical_name: "Summary"
          field_id: "summary"
    parent_link_available:
      "10004": true
    priorities:
      Highest: "1"
      Medium: "3"
      Low: "4"
    statuses:
      To Do: "10000"
    estimation_field_id: "customfield_20011"
'@

    $script:SpecMd = @'
# Feature Specification: Billing Invoices

We need to let customers export their invoices.

### User Story 1 - Export a single invoice (Priority: P1)

As a customer, I want to export one invoice as a PDF.

- **Given** a signed-in customer viewing an invoice
- **When** they choose Export
- **Then** a PDF download starts

### User Story 2 - Export a date range (Priority: P2)

As a customer, I want to export every invoice in a date range.

- **Given** a signed-in customer on the invoices page
- **When** they pick a start and end date and choose Export
- **Then** a zip of PDFs download starts
'@

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out
        $oe = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
        return $sw.ToString() + $se.ToString()
    }
}

Describe 'Invoke-JiraReconcile — a second event over unchanged files still advances the board' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Work '.specify/jira') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Work 'specs/001-billing-invoices') | Out-Null
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        Set-Content -NoNewline -Path (Join-Path $script:Work '.specify/jira/config.yml') -Value $script:ConfigYaml
        Set-Content -NoNewline -Path (Join-Path $script:Work '.specify/jira/config.local.yml') -Value $script:ConfigLocalYaml
        Set-Content -NoNewline -Path $script:Spec -Value $script:SpecMd
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/comp-transitions.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T059 -- a second event over byte-identical files is not short-circuited, and the ticket reaches the second event''s step' {
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -BeGreaterThan 0
        $t = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-2/transitions') })
        $t.Count | Should -Be 1
        [string]$t[0].body.transition.id | Should -Be '101'
    }

    It 'T061 -- adding plan.md alone produces a full reconcile, and its Implementation Plan section reaches the parent' {
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        $planMd = @'
# Implementation Plan: Billing Invoices

## Summary

Export invoices as PDF files using the existing billing service.
'@
        Set-Content -NoNewline -Path (Join-Path $script:Work 'specs/001-billing-invoices/plan.md') -Value $planMd

        Clear-Content -LiteralPath $script:M.CallLog
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -BeGreaterThan 0
        $parentAction = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-1') })[0]
        ($parentAction.body.fields.description | ConvertTo-Json -Depth 20) | Should -Match 'Implementation Plan'
        ($parentAction.body.fields.description | ConvertTo-Json -Depth 20) | Should -Match 'Export invoices as PDF files'
    }

    It 'T063 -- the same event twice short-circuits, plan.md deletion invalidates, and a schema-1 document forces a full reconcile' {
        $planMd = @'
# Implementation Plan: Billing Invoices

## Summary

Export invoices as PDF files using the existing billing service.
'@
        $planPath = Join-Path $script:Work 'specs/001-billing-invoices/plan.md'
        Set-Content -NoNewline -Path $planPath -Value $planMd
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        # Same event, same files, immediate repeat: short-circuits with an
        # empty call log.
        Clear-Content -LiteralPath $script:M.CallLog
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -Be 0

        # Deleting plan.md is a change too (present -> absent), not just
        # the other way around: the next run under the same event is NOT
        # short-circuited.
        Remove-Item -LiteralPath $planPath -Force
        Clear-Content -LiteralPath $script:M.CallLog
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -BeGreaterThan 0

        # A schema-1 recorded document (pre-023, no hook_event/plan.md
        # keys) is never trusted as a match: the next run under an event
        # is a full reconcile, never a short-circuit.
        $stateFile = Get-JiraRunStatePath -SpecPath $script:Spec
        $doc = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json -Depth 100
        $doc.PSObject.Properties.Remove('hook_event')
        $doc.schema = 1
        ($doc | ConvertTo-Json -Depth 100 -Compress) | Set-Content -NoNewline -LiteralPath $stateFile
        Clear-Content -LiteralPath $script:M.CallLog
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -BeGreaterThan 0
    }

    It 'T063b -- after_analyze costs a full reconcile once, then short-circuits on an immediate repeat' {
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_analyze'
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -BeGreaterThan 0

        Clear-Content -LiteralPath $script:M.CallLog
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        @(Get-JiraMockCallLog -Mock $script:M).Count | Should -Be 0
    }

    It 'T065 -- a run raising a warning records no state (S10)' {
        # BeforeEach's own no-event creation run raised no warning and DID
        # record state — clear it so this run's own "records no state" is
        # unambiguous rather than an artefact of a prior run's document
        # still sitting there.
        $stateFile = Get-JiraRunStatePath -SpecPath $script:Spec
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue

        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @($r.warnings).Count | Should -BeGreaterOrEqual 1
        Test-Path -LiteralPath $stateFile | Should -BeFalse
    }
}
