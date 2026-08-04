# T058 [US6] — once the ONLY reason a task tier was withheld is a
# defaultable field, recording its default and reconciling again creates
# exactly the withheld sub-tasks, moving the issue count by precisely that
# number, with no cleanup, no flag beyond the ordinary recorded-default
# confirmation, and nothing else changed (FR-039). Mirror of
# tests/bash/commands/test_reconcile_task_recovered.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-subtask-mandatory-field'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    # 4 ids: the parent, the story, and one per tasks.md task line (T001's
    # unattributed setup task still gets a marker even though it is never
    # mirrored — same pool sizing as tests/bash/commands/test_reconcile_task_recovered.bats).
    $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222 3333333333333333'
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

Describe 'Invoke-JiraReconcile — the task tier recovers once its sole missing default is recorded' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $script:Tasks = Join-Path $script:Work 'specs/001-feature/tasks.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        # This scenario's task type has exactly ONE unmet field — Definition
        # of Done, which is defaultable — and no undefaultable one, so
        # recording its default is enough to make the tier fully recoverable
        # (unlike the withheld-forever case Reconcile.TaskWithheld.Tests.ps1
        # exercises).
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

    It 'T058 — recording the sole missing default and reconciling again creates exactly the withheld sub-task, moving the count by precisely one, with nothing else changed' {
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $r.counts.tasks.created | Should -Be 0
        $postsBefore = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count
        $postsBefore | Should -Be 2

        $null = Invoke-ConfigCaptured @('config', 'TASKM', '--field-default', 'TASKM=Sub-task=Definition of Done=Shipped and documented', '--json')

        $r2 = Invoke-Captured @('reconcile', $script:Spec, '--accept-defaults', '--json') | ConvertFrom-Json
        $r2.counts.created | Should -Be 0
        $r2.counts.updated | Should -Be 0
        $r2.counts.tasks.created | Should -Be 1

        # The call log is cumulative for the whole test (no mock reset seam) —
        # the count must have moved by exactly one, on top of the two POSTs
        # already made by the first run above.
        $postsAfter = @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count
        ($postsAfter - $postsBefore) | Should -Be 1
    }
}
