# T043 [US1] — The config run reports its effects separately (FR-054).
# Mirror of tests/bash/commands/test_config_three_effects.bats.
#
# The effect set has grown and shrunk over time — 002 added gitignore, 011 added
# field_defaults and task_mirror, 030 added personal, and 034 REMOVED hooks — so
# what this file pins is the summary STRUCTURE: every effect the ceremony
# performs appears as its own named section, and nothing else does.
#
# 034: the hooks effect is gone because the extension no longer reads the hook
# registry (FR-001, FR-002). The two assertions that it is absent are not
# redundant with each other — the JSON summary and the human-rendered `Effects:`
# block are separate consumers of the same object, and the renderer iterates its
# own fixed order.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $script:Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $script:Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-config'
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
}

Describe 'Config three-effect reporting' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        Copy-Item -Recurse (Join-Path $Fixture '.specify') (Join-Path $Work '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $M
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'reports each effect separately in --json, and no hooks effect (034 FR-002)' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--json')) }
        finally { [Console]::SetOut($orig) }
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        # All effects are present as distinct, named sections (002 adds
        # gitignore; 011 adds field_defaults and task_mirror; 030 adds personal;
        # 034 removes hooks).
        ($obj.effects.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'discovery,field_defaults,gitignore,personal,readme,task_mirror'
        # 034 FR-002: the ceremony no longer reports on the hook registry at
        # all. `additionalProperties: false` in run-summary.schema.json makes a
        # summary still carrying this key invalid, not merely unexpected.
        $obj.effects.PSObject.Properties.Name | Should -Not -Contain 'hooks'
        $obj.effects.discovery.status | Should -Be 'written'
        $obj.effects.readme.status | Should -Not -BeNullOrEmpty
        $obj.effects.gitignore.status | Should -Not -BeNullOrEmpty
    }

    It 'names each effect in the prose summary, and never the word hooks (034 FR-002)' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story')) }
        finally { [Console]::SetOut($orig) }
        $text = $sw.ToString()
        $text | Should -Match 'discovery'
        $text | Should -Match 'readme'
        # T093 — the gitignore effect modifies a tracked file; the default
        # output must say so, not only the --json summary.
        $text | Should -Match '  gitignore: '
        # The human path is a separate consumer of the effects object from the
        # JSON one, and it renders from its own fixed order — so it needs its
        # own assertion (034 FR-008).
        $text | Should -Not -Match '  hooks: '
    }
}

Describe 'T083 [Phase 9] — the §7.1 per-role audit and the §7.3 promotion note (010)' {
    # SAFE (Epic 2 / Feature 1 / Story 0 / Sub-task -1) is unambiguous at
    # every level, so declaring `specification` and answering `task` while
    # leaving `story` alone gives one role resolved from each of the three
    # sources in a SINGLE run.
    BeforeAll {
        function Invoke-SafeConfigCaptured {
            param([string[]] $CmdArgs)
            $sw = [System.IO.StringWriter]::new()
            $swErr = [System.IO.StringWriter]::new()
            $orig = [Console]::Out
            $origErr = [Console]::Error
            [Console]::SetOut($sw)
            [Console]::SetError($swErr)
            try { $code = Invoke-JiraConfig -Arguments $CmdArgs }
            finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
            return [pscustomobject]@{ ExitCode = [int]$code; StdOut = $sw.ToString(); StdErr = $swErr.ToString(); Out = ($sw.ToString() + $swErr.ToString()) }
        }
    }
    BeforeEach {
        $script:SafeWork = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $SafeWork '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $SafeWork '.specify/jira'
        $script:SafeM = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/safe.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $SafeM.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $SafeM
        Remove-Item -Recurse -Force $SafeWork -ErrorAction SilentlyContinue
    }

    It 'reports one role from each source, in prose and --json' {
        $lines = "projects:`n  - key: SAFE`n    hierarchy:`n      specification: Epic`nrouting_default: SAFE`n"
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), $lines)

        $r = Invoke-SafeConfigCaptured @('config', '--issue-type', 'SAFE=task=Sub-task', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.StdOut | ConvertFrom-Json
        $obj.effects.discovery.projects.SAFE.roles.specification.logical_name | Should -Be 'Epic'
        $obj.effects.discovery.projects.SAFE.roles.specification.source | Should -Be 'declared'
        $obj.effects.discovery.projects.SAFE.roles.story.logical_name | Should -Be 'Story'
        $obj.effects.discovery.projects.SAFE.roles.story.source | Should -Be 'derived'
        $obj.effects.discovery.projects.SAFE.roles.task.logical_name | Should -Be 'Sub-task'
        $obj.effects.discovery.projects.SAFE.roles.task.source | Should -Be 'operator'

        $prose = Invoke-SafeConfigCaptured @('config', '--issue-type', 'SAFE=task=Sub-task')
        $prose.ExitCode | Should -Be 0
        $prose.Out | Should -Match 'specification: Epic \(declared\)'
        $prose.Out | Should -Match 'story: Story \(derived\)'
        $prose.Out | Should -Match 'task: Sub-task \(operator\)'
    }

    It 'the §7.3 promotion note names the role resolved from an operator answer, as a note, exit still 0' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "projects:`n  - key: SAFE`nrouting_default: SAFE`n")
        $r = Invoke-SafeConfigCaptured @('config', '--issue-type', 'SAFE=task=Sub-task', '--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'config: project SAFE: commit this so your team mirrors identically —'
        $r.Out | Should -Match '    task: "Sub-task"'
        ($r.Out -split "`n" | Where-Object { $_ -match '^WARNING: ' }).Count | Should -Be 0
    }
}

# =============================================================================
# T060 [030, US3] — the personal effect statuses: created, unchanged,
# would_create (contracts/personal-config-creation.md)
# =============================================================================

Describe 'T060 — the personal effect statuses' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        Copy-Item -Recurse (Join-Path $Fixture '.specify') (Join-Path $Work '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $M
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'T060 — personal reports created on a fresh repository, with the catalogue ids in the comment' {
        $env:JIRA_EMAIL = 'op@example.com'
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--json')) }
        finally { [Console]::SetOut($orig); $env:JIRA_EMAIL = 'user@example.com' }
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        $obj.effects.personal.status | Should -Be 'created'
        $pf = Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'
        Test-Path $pf | Should -BeTrue
        (Get-Content -Raw $pf) | Should -Match 'email: op@example.com'
        (Get-Content -Raw $pf) | Should -Match '# team: alpha'
    }

    It 'T060 — personal reports unchanged when the file already exists, byte-identical' {
        New-Item -ItemType Directory -Path $env:JIRA_CONFIG_DIR -Force | Out-Null
        $pf = Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'
        [System.IO.File]::WriteAllText($pf, "email: kept@example.com`n# custom comment`n")
        $before = Get-Content -Raw $pf
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--json')) }
        finally { [Console]::SetOut($orig) }
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        $obj.effects.personal.status | Should -Be 'unchanged'
        (Get-Content -Raw $pf) | Should -Be $before
    }

    It 'T060 — personal reports would_create under --dry-run, and writes nothing' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--dry-run', '--json')) }
        finally { [Console]::SetOut($orig) }
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        $obj.effects.personal.status | Should -Be 'would_create'
        Test-Path (Join-Path $env:JIRA_CONFIG_DIR 'personal.yml') | Should -BeFalse
    }
}
