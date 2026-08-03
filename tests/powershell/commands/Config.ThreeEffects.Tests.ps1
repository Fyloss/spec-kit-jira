# T043 [US1] — The config run reports three effects separately (FR-054).
# Mirror of tests/bash/commands/test_config_three_effects.bats. A single config
# run has three effects — discovery, hook registration, README-block management —
# each reported SEPARATELY. At this phase only discovery performs its write; the
# hooks/README effects are wired in later increments (T085, T065). This asserts
# the summary STRUCTURE: all three effects appear as distinct, named sections.

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

    It 'reports discovery, hooks, and readme effects separately in --json' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story', '--json')) }
        finally { [Console]::SetOut($orig) }
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        # All effects are present as distinct, named sections (002 adds
        # gitignore; 011 adds field_defaults).
        ($obj.effects.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'discovery,field_defaults,gitignore,hooks,readme'
        $obj.effects.discovery.status | Should -Be 'written'
        $obj.effects.hooks.status | Should -Not -BeNullOrEmpty
        $obj.effects.readme.status | Should -Not -BeNullOrEmpty
        $obj.effects.gitignore.status | Should -Not -BeNullOrEmpty
    }

    It 'names each of the four effects in the prose summary' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraConfig -Arguments @('config', '--child-type', 'COMP=Story')) }
        finally { [Console]::SetOut($orig) }
        $text = $sw.ToString()
        $text | Should -Match 'discovery'
        $text | Should -Match 'hooks'
        $text | Should -Match 'readme'
        # T093 — the gitignore effect modifies a tracked file; the default
        # output must say so, not only the --json summary.
        $text | Should -Match '  gitignore: '
    }
}

Describe 'The ceremony records the disable decision (T026, 003 US2)' {
    # `specify extension add` writes `enabled: true` unconditionally on every
    # install and upgrade (research R5), so the hook registry cannot carry the
    # operator's decision across a reinstall. The ceremony is where the extension
    # observes it — the only moment it reads the registry with intent — and it
    # records it in the gitignored local binding, which survives.
    #
    # Three separations matter: the CEREMONY records while the health
    # CLASSIFICATION writes nothing anywhere; the record goes in OUR file and the
    # registry is not edited to match (FR-022); and --dry-run predicts the record
    # write without performing it (Constitution XI).
    BeforeAll {
        Import-Module (Join-Path $Root 'scripts/powershell/hooks/RegisterHooks.psm1') -Force
        Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force

        function Set-RegistryWithDisabled {
            # A COMPLETE registry, as the install writes it, with one entry the
            # operator turned off. Completeness matters: a registry that is also
            # missing entries reports `incomplete`, the more severe state.
            param([Parameter(Mandatory)] [string] $Path)
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine('hooks:')
            foreach ($e in (Get-JiraHookEventList)) {
                $cmd = Get-JiraHookCommandFor -LifecycleEvent $e
                $enabled = if ($e -eq 'after_implement') { 'false' } else { 'true' }
                [void]$sb.AppendLine("  ${e}:")
                [void]$sb.AppendLine('  - extension: jira')
                [void]$sb.AppendLine("    command: $cmd")
                [void]$sb.AppendLine("    enabled: $enabled")
                [void]$sb.AppendLine('    optional: false')
                [void]$sb.AppendLine('    priority: 10')
                [void]$sb.AppendLine("    prompt: Execute $cmd" + '?')
                [void]$sb.AppendLine('    description: Mirror.')
                [void]$sb.AppendLine('    condition: null')
            }
            [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        }

        function Invoke-ConfigSummary {
            param([string[]] $CmdArgs)
            $sw = [System.IO.StringWriter]::new(); $orig = [Console]::Out; [Console]::SetOut($sw)
            try { [void](Invoke-JiraConfig -Arguments $CmdArgs) } finally { [Console]::SetOut($orig) }
            return ($sw.ToString().Trim() | ConvertFrom-Json)
        }
    }

    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        Copy-Item -Recurse (Join-Path $Fixture '.specify') (Join-Path $script:Work '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $env:SPEC_KIT_JIRA_EXTENSIONS_YML = Join-Path $script:Work '.specify/extensions.yml'
        Set-RegistryWithDisabled -Path $env:SPEC_KIT_JIRA_EXTENSIONS_YML
    }
    AfterEach {
        Stop-JiraMock -Mock $script:M
        Remove-Item Env:\SPEC_KIT_JIRA_EXTENSIONS_YML -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'records an observed enabled:false into the disable record (R5 step 1)' {
        $obj = Invoke-ConfigSummary @('config', '--child-type', 'COMP=Story', '--json')
        (Get-JiraHooksDisabled -ConfigDir $env:JIRA_CONFIG_DIR) | Should -BeExactly '["after_implement"]'
        @($obj.hook_health.held_disabled) | Should -Contain 'after_implement'
    }

    It 'writes NOTHING from the health classification itself (data-model)' {
        $null = Get-JiraHookHealth -Path $env:SPEC_KIT_JIRA_EXTENSIONS_YML
        # Classifying observed the disabled entry; it recorded nothing. Only the
        # ceremony records — that separation is what keeps health a pure function.
        (Get-JiraHooksDisabled -ConfigDir $env:JIRA_CONFIG_DIR) | Should -BeExactly '[]'
    }

    It 'predicts the record write under --dry-run without performing it (Constitution XI)' {
        $obj = Invoke-ConfigSummary @('config', '--dry-run', '--child-type', 'COMP=Story', '--json')
        $obj.effects.hooks.detail | Should -Match 'after_implement'
        (Get-JiraHooksDisabled -ConfigDir $env:JIRA_CONFIG_DIR) | Should -BeExactly '[]'
    }

    It 'reports the hook effect with the read-only vocabulary (FR-021)' {
        $obj = Invoke-ConfigSummary @('config', '--child-type', 'COMP=Story', '--json')
        # `held_disabled` — not a write outcome, because nothing was written.
        $obj.effects.hooks.status | Should -BeExactly 'held_disabled'
        $obj.effects.hooks.detail | Should -Match ([regex]::Escape('--enable-hook'))
    }

    It 'leaves the registry byte-identical while recording (FR-022, FR-023)' {
        $before = (Get-FileHash -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML -Algorithm SHA256).Hash
        $null = Invoke-ConfigSummary @('config', '--child-type', 'COMP=Story', '--json')
        (Get-FileHash -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML -Algorithm SHA256).Hash | Should -BeExactly $before
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
