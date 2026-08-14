# T099 [Phase 6, US4] — isolation rules I4/I5, PowerShell port. Mirror of
# tests/bash/commands/test_reconcile_task_role_inert_note.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-task-tier'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
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

Describe 'Invoke-JiraReconcile — the once-per-run inert note for a declared task mapping (I4/I5)' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'T099 -- a declared task mapping under checklist mode produces exactly one inert note, zero writes to the mapping''s own effect' {
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work
        $spec = Join-Path $work 'specs/001-feature/spec.md'
        $configYaml = @'
projects:
  - key: TASKP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      task:
        after_specify: "To Do"
        after_plan: "In Progress"
routing_default: TASKP
task_mirror:
  TASKP: checklist
'@
        Set-Content -NoNewline -Path (Join-Path $work '.specify/jira/config.yml') -Value $configYaml
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $spec, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        $inertNotes = @($r.notes | Where-Object { $_ -match 'task-role lifecycle mapping' })
        $inertNotes.Count | Should -Be 1
        $inertNotes[0] | Should -Match 'mirrored as a checklist'
        (@($r.warnings) -join ' ') | Should -Not -Match 'task-role lifecycle mapping'
    }

    It 'T101 -- a sub-task abandoned by a switch to checklist mode never enters the mapping''s move set, even with a declared step' {
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work
        $spec = Join-Path $work 'specs/001-feature/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        # First run in `subtask` mode (the fixture's own default): binds
        # TASKP-3, its marker recorded in tasks.md.
        $null = Invoke-Captured @('reconcile', $spec, '--json')

        # Switch to checklist mode. The task role ALSO declares a step for
        # this event -- a mapping that LOOKS active is exactly the case I6
        # guards: TASKP-3's marker is still in tasks.md, its ticket still
        # in the tracker, but the mirror abandoned it the moment mode
        # switched.
        $configYaml = @'
projects:
  - key: TASKP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      task:
        after_specify: "To Do"
        after_plan: "In Progress"
routing_default: TASKP
task_mirror:
  TASKP: checklist
'@
        Set-Content -NoNewline -Path (Join-Path $work '.specify/jira/config.yml') -Value $configYaml

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'TASKP-3' }).Count | Should -Be 0
        @($r.actions | Where-Object { ([string]$_.url) -match 'TASKP-3' }).Count | Should -Be 0
        # The switch's own note still fires (022, unrelated to I6's own claim).
        (@($r.notes) -join ' ') | Should -Match 'switched to checklist mode'
    }

    It 'T099 -- an empty task mapping stays silent (I2), no inert note' {
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work
        $spec = Join-Path $work 'specs/001-feature/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $spec, '--json')

        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @($r.notes | Where-Object { $_ -match 'task-role lifecycle mapping' }).Count | Should -Be 0
    }
}
