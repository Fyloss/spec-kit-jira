# T059 [US6] — a run creating all three tiers, each carrying a defaulted
# field, asks ONE consolidated confirmation covering all three — never one
# per tier (FR-040). Mirror of
# tests/bash/commands/test_reconcile_task_one_question.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-subtask-mandatory-field'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
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

Describe 'Invoke-JiraReconcile — a run creating all three tiers asks one consolidated confirmation (FR-040)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        @'
resolved_ids:
  TASKM:
    style: company_managed
    issue_types:
      - logical_name: "Epic"
        id: "40701"
        hierarchy_level: "1"
        subtask: false
      - logical_name: "Story"
        id: "40704"
        hierarchy_level: "0"
        subtask: false
      - logical_name: "Sub-task"
        id: "40705"
        hierarchy_level: "-1"
        subtask: true
    roles:
      specification:
        logical_name: "Epic"
        id: "40701"
        hierarchy_level: "1"
        subtask: false
        source: declared
      story:
        logical_name: "Story"
        id: "40704"
        hierarchy_level: "0"
        subtask: false
        source: declared
      task:
        logical_name: "Sub-task"
        id: "40705"
        hierarchy_level: "-1"
        subtask: true
        source: declared
    child_type:
      logical_name: "Story"
      id: "40704"
      source: declared
    parent_type:
      logical_name: "Epic"
      id: "40701"
      source: declared
    required_fields:
      "40701":
        - logical_name: "Summary"
          field_id: "summary"
      "40704":
        - logical_name: "Summary"
          field_id: "summary"
        - logical_name: "Business Owner"
          field_id: "customfield_50022"
      "40705":
        - logical_name: "Summary"
          field_id: "summary"
        - logical_name: "Definition of Done"
          field_id: "customfield_50011"
    defaultable_fields:
      "40704":
        - logical_name: "Business Owner"
          field_id: "customfield_50022"
          schema_type: "string"
          required: true
          defaultable: true
          allowed_values: []
      "40705":
        - logical_name: "Definition of Done"
          field_id: "customfield_50011"
          schema_type: "string"
          required: true
          defaultable: true
          allowed_values: []
    parent_link_available:
      "40704": true
      "40705": true
    priorities:
      Highest: "1"
      Medium: "3"
      Low: "4"
    statuses:
      To Do: "10000"
    estimation_field_id: null
'@ | Set-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml') -NoNewline

        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"TASKM":"company"},"issueTypeStyle":{"TASKM":"taskm"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $map = '{"TASKM":{"Story":{"Business Owner":"Platform Team"},"Sub-task":{"Definition of Done":"Shipped and documented"}}}'
        $null = Set-JiraFieldDefaultsBlock -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -MapJson $map -DryRun $false
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'FR-040 — a run creating all three tiers, each carrying a defaulted field, asks one consolidated confirmation naming every tier''s field' {
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.status | Should -Be 'confirmation-pending'
        @($r.fields | Where-Object { $_.label -eq 'Business Owner' }).Count | Should -Be 1
        @($r.fields | Where-Object { $_.label -eq 'Definition of Done' }).Count | Should -Be 1
        $r.creations_pending | Should -Be 3

        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 0
    }

    It 'FR-040 — resuming with --accept-defaults creates all three tiers in the same run, with no second question' {
        $r = Invoke-Captured @('reconcile', $script:Spec, '--accept-defaults', '--json') | ConvertFrom-Json
        if ($r.PSObject.Properties.Name -contains 'status') { $r.status | Should -Not -Be 'confirmation-pending' }
        $r.counts.created | Should -Be 2
        $r.counts.tasks.created | Should -Be 1

        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 3
    }
}
