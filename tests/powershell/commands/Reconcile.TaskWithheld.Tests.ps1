# T056 [US6] — a declared `task` role whose type carries an unsatisfiable
# or undefaultable required field must never make a run worse than not
# declaring the role at all (FR-036, FR-037): the specification and story
# tiers still mirror exactly as they would with no `task` role; the task
# tier alone is withheld — zero sub-task writes — with each unmet field
# named once, carrying a `--field-default` remedy only when the field is
# actually defaultable, and the run summary states the tier as withheld,
# distinctly from a tier with nothing to mirror. Mirror of
# tests/bash/commands/test_reconcile_task_withheld.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-subtask-mandatory-field'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

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

Describe 'Invoke-JiraReconcile — the task tier is withheld when its mandatory fields are unmet' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $script:Tasks = Join-Path $script:Work 'specs/001-feature/tasks.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"TASKM":"t"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T056 — the specification and story tiers mirror exactly as they would with no task role declared' {
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 2
    }

    It 'T056 — zero sub-task writes: no issue is created at the task role''s own issue type' {
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        (Get-JiraMockIssueField -Mock $script:M -Key 'TASKM-1' -Path 'fields.issuetype.id') | Should -Not -Be '40705'
        (Get-JiraMockIssueField -Mock $script:M -Key 'TASKM-2' -Path 'fields.issuetype.id') | Should -Not -Be '40705'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 2
    }

    It 'T056 — each unmet field is named once, the defaultable one carrying its --field-default remedy, the other its reason and no remedy' {
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        $warningLines = @($r.warnings)
        $warnings = ($warningLines -join "`n")
        @($warningLines | Select-String -Pattern 'Definition of Done' -SimpleMatch).Count | Should -Be 1
        @($warningLines | Select-String -Pattern 'Affected Teams' -SimpleMatch).Count | Should -Be 1
        @($warningLines | Select-String -Pattern '--field-default' -SimpleMatch).Count | Should -Be 1
        $warnings | Should -Not -Match 'customfield_'
        $warnings | Should -Match 'a list of values cannot be expressed as a single recorded value'
    }

    It 'T056 — the summary states the tier as withheld, distinctly from a tier with nothing to mirror' {
        $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        ($r.warnings -join "`n") | Should -Match 'withheld'

        @'
# Tasks: Task Tier Mandatory Field Demo

## Phase 1: Setup

- [ ] T001 Do the setup work
'@ | Set-Content -LiteralPath $script:Tasks -NoNewline

        $r2 = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        (@($r2.warnings) -join "`n") | Should -Not -Match 'withheld'
    }

    It 'T057 — tasks.md is unchanged after a withheld run — no durable identifier is recorded for a withheld task' {
        $before = Get-Content -Raw -LiteralPath $script:Tasks
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
        $after = Get-Content -Raw -LiteralPath $script:Tasks
        $after | Should -Be $before
        $after | Should -Not -Match 'speckit-jira task='
    }
}
