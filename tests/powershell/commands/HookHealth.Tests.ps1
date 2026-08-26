# T060 [003 US6] — Hook health reported in every run, and NEVER repaired.
# PowerShell side. Mirror of tests/bash/commands/test_hook_health.bats. Cross-port
# byte agreement is proven in bats; here we assert the reporting semantics
# (FR-021, FR-022, FR-025, FR-028).
#
# Every reconcile run READS the consuming repository's hook registry, classifies
# all seven declared events, and reports. It repairs nothing: `--repair-hooks`
# existed only to perform a registry write FR-022 now forbids, and the flag is
# gone rather than kept as a no-op.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    Import-Module (Join-Path $Root 'scripts/powershell/hooks/RegisterHooks.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    # Imported LAST so its exports are not re-scoped by the -Force imports nested
    # inside the modules above (the nested-import re-scope trap).
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Output.psm1') -Force

    function Set-CanonicalRegistry {
        # Exactly the shape the host install produces: one eight-field entry per
        # declared event, owned by `jira`.
        param([Parameter(Mandatory)] [string] $Path)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('hooks:')
        foreach ($e in (Get-JiraHookEventList)) {
            $cmd = Get-JiraHookCommandFor -LifecycleEvent $e
            [void]$sb.AppendLine("  ${e}:")
            [void]$sb.AppendLine('    - extension: jira-mirror')
            [void]$sb.AppendLine("      command: $cmd")
            [void]$sb.AppendLine('      enabled: true')
            [void]$sb.AppendLine('      optional: false')
            [void]$sb.AppendLine('      priority: 10')
            [void]$sb.AppendLine("      prompt: Execute $cmd" + '?')
            [void]$sb.AppendLine('      description: A human-readable sentence.')
            [void]$sb.AppendLine('      condition: null')
        }
        [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    }

    function Invoke-ReconcileSummary([string[]] $ArgList) {
        # Capture the summary the command writes via [Console]::Out.
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { [void](Invoke-JiraReconcile -Arguments $ArgList) }
        finally { [Console]::SetOut($orig) }
        return $sw.ToString().Trim()
    }
}

Describe 'Hook health reporting' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        $script:Spec = Join-Path $Work 'spec.md'
        @(
            '# Feature Specification: Health', '', 'A spec that mirrors to Jira.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a user', '- **When** they act', '- **Then** it works'
        ) -join "`n" | Set-Content -LiteralPath $Spec -NoNewline
        $env:SPEC_KIT_JIRA_BASE_URL = 'http://127.0.0.1:1'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        # 004 FR-005: the shipped placeholder is now refused outright, so this
        # suite (about hook health, not config resolution) is migrated to a
        # real key with a matching epic-strategy override — both bypass
        # config.yml, which this isolated work dir never has.
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST'
        $env:SPEC_KIT_JIRA_EXTENSIONS_YML = Join-Path $Work '.specify/extensions.yml'
        $env:JIRA_NO_SLEEP = '1'
        $env:JIRA_MAX_ATTEMPTS = '1'
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        # A minimal override supplying the issue type the assembly guard
        # requires — this suite has no persisted binding to resolve one from.
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"10004"}'
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        # 015 (regression): SPEC_KIT_JIRA_PROJECT_KEY set in BeforeEach above
        # was never cleared, leaking into whichever test file's session
        # happens to run next and overriding ITS OWN project-key routing.
        Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'reports hook health in every run summary, in the contract shape (FR-047)' {
        $obj = Invoke-ReconcileSummary @('reconcile', '--dry-run', '--json', $Spec) | ConvertFrom-Json
        @($obj.hook_health.missing).Count | Should -Be 7
        @($obj.hook_health.present).Count | Should -Be 0
        @($obj.hook_health.disabled).Count | Should -Be 0
        @($obj.hook_health.duplicated).Count | Should -Be 0
        $obj.hook_health.unreadable | Should -BeFalse
        # The hint names the ONE command that registers them — the official
        # install, which this extension cannot perform for the operator (FR-025).
        $obj.hook_health.repair_hint | Should -Match 'specify extension add'
    }

    It 'reports healthy with NO repair hint for a registry the install wrote (FR-021)' {
        Set-CanonicalRegistry -Path $env:SPEC_KIT_JIRA_EXTENSIONS_YML
        $obj = Invoke-ReconcileSummary @('reconcile', '--dry-run', '--json', $Spec) | ConvertFrom-Json
        @($obj.hook_health.present).Count | Should -Be 7
        $obj.hook_health.PSObject.Properties.Name | Should -Not -Contain 'repair_hint'
    }

    It 'leaves the registry byte-identical — every state, every run (FR-023, SC-007)' {
        Set-CanonicalRegistry -Path $env:SPEC_KIT_JIRA_EXTENSIONS_YML
        $before = (Get-FileHash -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML -Algorithm SHA256).Hash
        $null = Invoke-ReconcileSummary @('reconcile', '--dry-run', '--json', $Spec)
        $null = Invoke-ReconcileSummary @('reconcile', '--json', $Spec)
        (Get-FileHash -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It 'reports a leftover pre-manifest entry as duplicated, with the manual edit (FR-028)' {
        Set-CanonicalRegistry -Path $env:SPEC_KIT_JIRA_EXTENSIONS_YML
        $json = ConvertFrom-JiraConfigYaml -Path $env:SPEC_KIT_JIRA_EXTENSIONS_YML | ConvertFrom-Json -Depth 100
        $json.hooks.after_plan = @($json.hooks.after_plan) + @([pscustomobject]@{ command = 'speckit.jira.reconcile'; enabled = $true })
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $json)
        [System.IO.File]::WriteAllText($env:SPEC_KIT_JIRA_EXTENSIONS_YML, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $obj = Invoke-ReconcileSummary @('reconcile', '--dry-run', '--json', $Spec) | ConvertFrom-Json
        @($obj.hook_health.duplicated) | Should -Contain 'after_plan'
        $obj.hook_health.repair_hint | Should -Match ([regex]::Escape('extension: jira-mirror'))
    }

    It 'reports an unreadable registry as unreadable, never as missing hooks (FR-024)' {
        $dir = Split-Path -Parent $env:SPEC_KIT_JIRA_EXTENSIONS_YML
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($env:SPEC_KIT_JIRA_EXTENSIONS_YML, "hooks:`n  after_plan:`n   - broken`n", (New-Object System.Text.UTF8Encoding($false)))
        $obj = Invoke-ReconcileSummary @('reconcile', '--dry-run', '--json', $Spec) | ConvertFrom-Json
        $obj.hook_health.unreadable | Should -BeTrue
        @($obj.hook_health.missing).Count | Should -Be 0
    }

    It 'carries NO key outside the published run-summary contract' {
        $obj = Invoke-ReconcileSummary @('reconcile', '--dry-run', '--json', $Spec) | ConvertFrom-Json
        $allowed = @('schema_version', 'command', 'dry_run', 'counts', 'effects', 'drift', 'flags',
            'blockers', 'hook_health', 'mutations', 'actions', 'warnings', 'notes', 'exit_code')
        foreach ($k in $obj.PSObject.Properties.Name) { $allowed | Should -Contain $k }
    }

    It 'rejects --repair-hooks and creates no registry (T073, FR-022, SC-011)' {
        # The flag existed only to write the registry. It is removed rather than
        # kept as a no-op — a flag named "repair" that no longer repairs would be
        # worse than none (Principle XV, XVI) — and no run of any kind may bring
        # the file into existence, which is the strongest form of "we never write it".
        (Invoke-JiraReconcile -Arguments @('reconcile', '--repair-hooks', '--dry-run', '--json', $Spec)) | Should -Be 1
        Test-Path -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML | Should -BeFalse

        $null = Invoke-ReconcileSummary @('reconcile', '--json', $Spec)
        Test-Path -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML | Should -BeFalse
    }
}
