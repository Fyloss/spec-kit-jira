# T058a [US6] — a created sub-task's field values are attributed to their
# source — recorded team default, operator answer for this run, or
# bridge-supplied — in the run summary and in the --dry-run preview, through
# feature 011's existing reporting surface with no sub-task-specific one
# added (FR-042). Mirror of tests/bash/commands/test_reconcile_task_provenance.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-subtask-mandatory-field'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force # Get-JiraHooksDisabled: Reconcile.psm1's own nested import is module-scoped, and Hierarchy.psm1's later -Force re-import unbinds it (mirrors every sibling Reconcile.*.Tests.ps1)

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

    function Invoke-ConfigCaptured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraConfig -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

Describe 'Invoke-JiraReconcile — a sub-task creation''s field values are attributed to their source (FR-042)' {
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
      "40705":
        - logical_name: "Summary"
          field_id: "summary"
        - logical_name: "Definition of Done"
          field_id: "customfield_50011"
    defaultable_fields:
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
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'FR-042 — a sub-task creation''s recorded team default is attributed to its source in the run summary' {
        $null = Invoke-ConfigCaptured @('config', 'TASKM', '--field-default', 'TASKM=Sub-task=Definition of Done=Shipped and documented', '--json')

        $r = Invoke-Captured @('reconcile', $script:Spec, '--accept-defaults', '--json') | ConvertFrom-Json
        $notes = @($r.notes)
        @($notes | Where-Object { $_ -match 'Definition of Done' -and $_ -match 'sent from team-config' }).Count | Should -Be 1
        ($notes -join "`n") | Should -Not -Match 'customfield_'
    }

    It 'FR-042 — an operator-answer override applied to a sub-task creation is attributed to its source, with the promotion command, in the run summary' {
        $null = Invoke-ConfigCaptured @('config', 'TASKM', '--field-default', 'TASKM=Sub-task=Definition of Done=Shipped and documented', '--json')

        $r = Invoke-Captured @('reconcile', $script:Spec, '--field-value', 'TASKM=Sub-task=Definition of Done=Override Value', '--accept-defaults', '--json') | ConvertFrom-Json
        $notes = @($r.notes)
        @($notes | Where-Object { $_ -match 'Definition of Done' -and $_ -match 'sent from operator-answer' }).Count | Should -Be 1
        @($notes | Where-Object { $_ -match [regex]::Escape("--field-default 'TASKM=Sub-task=Definition of Done=Override Value'") }).Count | Should -Be 1
    }

    It 'FR-042 — the dry-run preview attributes a sub-task creation''s field the same way, before anything is written' {
        $null = Invoke-ConfigCaptured @('config', 'TASKM', '--field-default', 'TASKM=Sub-task=Definition of Done=Shipped and documented', '--json')

        $r = Invoke-Captured @('reconcile', $script:Spec, '--dry-run', '--json') | ConvertFrom-Json
        $notes = @($r.notes)
        @($notes | Where-Object { $_ -match 'Definition of Done' -and $_ -match 'sent from team-config' }).Count | Should -Be 1
        @($notes | Where-Object { $_ -match 'this is a preview' }).Count | Should -Be 1

        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 0
    }

    It 'FR-042 — a bridge-supplied field on a sub-task creation (never recorded, never answered) earns no provenance line' {
        $null = Invoke-ConfigCaptured @('config', 'TASKM', '--field-default', 'TASKM=Sub-task=Definition of Done=Shipped and documented', '--json')

        $r = Invoke-Captured @('reconcile', $script:Spec, '--accept-defaults', '--json') | ConvertFrom-Json
        $notes = ($r.notes -join "`n")
        $notes | Should -Not -Match 'sent from bridge'
        $notes | Should -Not -Match '"Summary"'
    }
}
