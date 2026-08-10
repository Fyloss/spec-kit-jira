# T102/T103a [Phase 7, US5, 022] — mirror of
# tests/bash/commands/test_reconcile_no_subtask_type.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-config'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    # Reconcile.psm1 -Force-imports lib/Config.psm1 internally, which
    # rebinds Get-JiraHooksDisabled et al. into Reconcile.psm1's own scope —
    # reimport here so Config.psm1's own use of them keeps working too (see
    # memory: powershell-import-force-clobbers-caller-scope).
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Config.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Invoke-CapturedConfig {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraConfig -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }

    function Invoke-CapturedReconcile {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

Describe 'Invoke-JiraReconcile — checklist mode with no sub-task type at all' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        Copy-Item -Recurse (Join-Path $Fixture '.specify') (Join-Path $script:Work '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"issueTypeStyle":{"COMP":"notask"}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-CapturedConfig -ArgList @('config', '--child-type', 'COMP=Story', '--json')

        $specDir = Join-Path $script:Work 'specs/001-feature'
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
        $script:Spec = Join-Path $specDir 'spec.md'
        $script:Tasks = Join-Path $specDir 'tasks.md'
        Set-Content -LiteralPath $script:Spec -Value @(
            '# Feature Specification: No Subtask Demo', '',
            'We need a working task tier without any sub-task type.', '',
            '### User Story 1 - The first story (Priority: P1)', '',
            'As a user, I want the first story.', '',
            '- **Given** a thing', '- **When** it happens', '- **Then** it works'
        )
        Set-Content -LiteralPath $script:Tasks -Value @(
            '# Tasks', '', '## Phase 3: User Story 1', '',
            "- [ ] T001 [US1] Implement the first story's feature"
        )

        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T102: no resolved task role at all — the config ceremony resolved no task role' {
        $localYaml = ConvertFrom-JiraConfigYaml -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')
        $localObj = $localYaml | ConvertFrom-Json -Depth 100
        $rolesProp = $localObj.resolved_ids.COMP.roles.PSObject.Properties['task']
        $rolesProp | Should -BeNullOrEmpty
    }

    It 'T102: checklist mode mirrors the full task list with no refusal, no missing-type warning (FR-005, SC-007)' {
        Add-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -Value "task_mirror:`n  COMP: checklist"
        $out = Invoke-CapturedReconcile -ArgList @('reconcile', $script:Spec, '--json')
        $r = $out | ConvertFrom-Json -Depth 100
        $r.counts.checklists.created | Should -Be 1
        ($r.warnings -join "`n") | Should -Not -Match 'sub-task'
        ($r.warnings -join "`n") | Should -Not -Match 'issue type'
        (@($r.notes)) | Should -BeNullOrEmpty
    }

    It "T103a: the same project in subtask mode still produces feature 012's existing behaviour — no task tier at all, no conflation" {
        $out = Invoke-CapturedReconcile -ArgList @('reconcile', $script:Spec, '--json')
        $r = $out | ConvertFrom-Json -Depth 100
        $r.counts.PSObject.Properties['tasks'] | Should -BeNullOrEmpty
        $r.counts.PSObject.Properties['checklists'] | Should -BeNullOrEmpty
        ($r.warnings -join "`n") | Should -Not -Match 'sub-task'
    }
}
