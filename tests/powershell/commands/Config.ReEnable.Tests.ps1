# T066 [003 US6] — `--enable-hook <event>`, the operator's explicit release,
# PowerShell port. Twin of tests/bash/commands/test_config_reenable.bats
# (FR-007, FR-029, Constitution XI, XV).
#
# This flag is the one affordance this feature adds, and it exists only because
# upstream leaves no alternative. `specify extension add` writes `enabled: true`
# unconditionally on every install and upgrade (research R5), so the extension
# cannot tell an operator's deliberate re-enable from the install's blind one.
# Guessing would silently discard a deliberate choice, so the extension does not
# guess: it holds the event disabled until the operator says otherwise, in one
# explicit command that the ceremony's own report names.
#
# The critical property is what the flag does NOT do. It clears one entry from
# the extension's own gitignored record and touches the hook registry not at all
# (FR-022) — the registry is not "restored" to enabled, because it is not ours to
# write in either direction.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $script:Root 'scripts/powershell/commands/Config.psm1') -Force
    Import-Module (Join-Path $script:Root 'scripts/powershell/commands/Reconcile.psm1') -Force
    Import-Module (Join-Path $script:Root 'scripts/powershell/lib/Config.psm1') -Force

    function Invoke-ConfigRun {
        param([string[]] $CmdArgs)
        $sw = [System.IO.StringWriter]::new(); $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out; $oe = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($se)
        try { $code = Invoke-JiraConfig -Arguments $CmdArgs }
        finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }
}

Describe 'The operator release flag' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        $env:SPEC_KIT_JIRA_EXTENSIONS_YML = Join-Path $script:Work '.specify/extensions.yml'
        $lines = @('projects:', '  - key: TEAM', 'routing_default: TEAM')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        # No connection: the run is degraded, which is exactly where an operator
        # reaching for this flag is most likely to be.
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue

        # A registry the install wrote, with every entry enabled — the state after
        # a reinstall has blown away the operator's `enabled: false`.
        [System.IO.File]::WriteAllText($env:SPEC_KIT_JIRA_EXTENSIONS_YML,
            "hooks:`n  after_implement:`n  - extension: jira-mirror`n    command: speckit.jira-mirror.reconcile`n    enabled: true`n",
            (New-Object System.Text.UTF8Encoding($false)))
    }
    AfterEach {
        Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_EXTENSIONS_YML -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'clears the event from the disable record (FR-007, FR-029)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $env:JIRA_CONFIG_DIR
        (Get-JiraHooksDisabled -ConfigDir $env:JIRA_CONFIG_DIR) | Should -BeExactly '["after_implement"]'
        (Invoke-ConfigRun @('config', '--enable-hook', 'after_implement', '--json')).ExitCode | Should -Be 0
        (Get-JiraHooksDisabled -ConfigDir $env:JIRA_CONFIG_DIR) | Should -BeExactly '[]'
    }

    It 'does NOT touch the registry (FR-022)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $env:JIRA_CONFIG_DIR
        $before = Get-Content -Raw -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML
        $null = Invoke-ConfigRun @('config', '--enable-hook', 'after_implement', '--json')
        (Get-Content -Raw -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML) | Should -BeExactly $before
    }

    It 'reports the release, naming the event (Principle XVI)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $env:JIRA_CONFIG_DIR
        $obj = (Invoke-ConfigRun @('config', '--enable-hook', 'after_implement', '--json')).Out.Trim() | ConvertFrom-Json
        $obj.effects.hooks.detail | Should -Match 'released: after_implement'
    }

    It 'is repeatable' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $env:JIRA_CONFIG_DIR
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_plan' -ConfigDir $env:JIRA_CONFIG_DIR
        (Invoke-ConfigRun @('config', '--enable-hook', 'after_implement', '--enable-hook', 'after_plan', '--json')).ExitCode | Should -Be 0
        (Get-JiraHooksDisabled -ConfigDir $env:JIRA_CONFIG_DIR) | Should -BeExactly '[]'
    }

    It 'is a no-op against an unrecorded event, reported as such' {
        $r = Invoke-ConfigRun @('config', '--enable-hook', 'after_plan', '--json')
        $r.ExitCode | Should -Be 0
        (Get-JiraHooksDisabled -ConfigDir $env:JIRA_CONFIG_DIR) | Should -BeExactly '[]'
        # Nothing was released, so nothing is claimed to have been.
        ($r.Out.Trim() | ConvertFrom-Json).effects.hooks.detail | Should -Not -Match 'released:'
    }

    It 'reports an unknown event name and does NOT fail the run (FR-029)' {
        (Invoke-ConfigRun @('config', '--enable-hook', 'not_an_event', '--json')).ExitCode | Should -Be 0
    }

    It 'predicts the clearance under --dry-run without performing it (Constitution XI)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $env:JIRA_CONFIG_DIR
        $r = Invoke-ConfigRun @('config', '--enable-hook', 'after_implement', '--dry-run', '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).effects.hooks.detail | Should -Match 'released: after_implement'
        # Predicted, not performed.
        (Get-JiraHooksDisabled -ConfigDir $env:JIRA_CONFIG_DIR) | Should -BeExactly '["after_implement"]'
    }

    It 'stops holding the released event at dispatch (FR-007)' {
        $spec = Join-Path $script:Work 'spec.md'
        @(
            '# Feature Specification: Release', '', 'A spec.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a user', '- **When** they act', '- **Then** it works'
        ) -join "`n" | Set-Content -LiteralPath $spec -NoNewline

        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $env:JIRA_CONFIG_DIR
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_implement'

        $se = [System.IO.StringWriter]::new(); $oe = [Console]::Error; [Console]::SetError($se)
        try { $null = Invoke-JiraReconcile -Arguments @('reconcile', '--dry-run', '--json', $spec) }
        finally { [Console]::SetError($oe) }
        # Held: inert and silent.
        $se.ToString() | Should -BeNullOrEmpty

        $null = Invoke-ConfigRun @('config', '--enable-hook', 'after_implement', '--json')

        $se2 = [System.IO.StringWriter]::new(); [Console]::SetError($se2)
        try { $null = Invoke-JiraReconcile -Arguments @('reconcile', '--dry-run', '--json', $spec) }
        finally { [Console]::SetError($oe) }
        # Released: the step runs again (and reports it is not configured, which
        # is a different message with a different cause).
        $se2.ToString() | Should -Not -BeNullOrEmpty
    }

    It 'T028 [023, US2] -- a disabled event exits 0 silently before any config read or network call, event genuinely supplied (contract lifecycle-event.md §4 invariant E3, FR-012)' {
        $spec = Join-Path $script:Work 'spec.md'
        @(
            '# Feature Specification: Held', '', 'A spec.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a user', '- **When** they act', '- **Then** it works'
        ) -join "`n" | Set-Content -LiteralPath $spec -NoNewline

        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_plan' -ConfigDir $env:JIRA_CONFIG_DIR
        # An unreachable base URL: if the dispatch guard failed to hold the run
        # BEFORE any network call, this run would fault loudly rather than
        # exit 0 silently.
        $env:SPEC_KIT_JIRA_BASE_URL = 'http://127.0.0.1:1'
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'

        $sw = [System.IO.StringWriter]::new(); $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out; $oe = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($se)
        try { $code = Invoke-JiraReconcile -Arguments @('reconcile', '--json', $spec) }
        finally { [Console]::SetOut($oo); [Console]::SetError($oe); Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue }
        [int]$code | Should -Be 0
        $sw.ToString() | Should -BeNullOrEmpty
        $se.ToString() | Should -BeNullOrEmpty
    }

    It 'requires a value, and says so (usage)' {
        $r = Invoke-ConfigRun @('config', '--enable-hook')
        $r.ExitCode | Should -Be 1
        $r.Err | Should -Match ([regex]::Escape('--enable-hook requires a lifecycle event'))
    }
}
