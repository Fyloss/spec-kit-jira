# T077 [Phase 6, US4] — back-compatibility guarantees B1/B2, PowerShell
# port. Mirror of tests/bash/commands/test_reconcile_role_blind_compat.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

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

Describe 'Invoke-JiraReconcile — a role-blind mapping never moves or evaluates the parent (B1/B2)' {
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

    It 'T077 -- a role-blind mapping never moves or evaluates the parent, and the story''s own behaviour is untouched' {
        # Put the parent somewhere a real specification-role mapping WOULD
        # treat as advanced-beyond-target and warn about, if the parent
        # were ever evaluated at all — proving it genuinely never is.
        Invoke-RestMethod -Method Put -Uri "$($script:M.BaseUrl)/rest/api/3/issue/COMP-1" `
            -ContentType 'application/json' `
            -Body '{"fields":{"status":{"name":"Building","statusCategory":{"key":"indeterminate"}}}}' | Out-Null

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }

        # B2: the parent is never read for transitions, never moved, and
        # no warning ever names it.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'COMP-1/transitions' }).Count | Should -Be 0
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-1/transitions') }).Count | Should -Be 0
        (@($r.warnings) -join ' ') | Should -Not -Match 'COMP-1'

        # B1: the story's own declared-step behaviour is exactly what a
        # role-blind mapping has always produced.
        $t = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-2/transitions') })
        $t.Count | Should -Be 1
        [string]$t[0].body.transition.id | Should -Be '101'
        $r.counts.transitioned | Should -Be 1
    }
}
