# T082 [US9] — Hook health reported in every run + one-command --repair-hooks,
# PowerShell side. Mirror of tests/bash/commands/test_hook_health.bats. Cross-port
# byte agreement is proven in bats; here we assert the reporting semantics (FR-047).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

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
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'PROJ'
        $env:SPEC_KIT_JIRA_EXTENSIONS_YML = Join-Path $Work '.specify/extensions.yml'
        $env:JIRA_NO_SLEEP = '1'
        $env:JIRA_MAX_ATTEMPTS = '1'
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'reports hook health in every run summary, in the contract shape (FR-047)' {
        $obj = Invoke-ReconcileSummary @('reconcile', '--dry-run', '--json', $Spec) | ConvertFrom-Json
        @($obj.hook_health.missing).Count | Should -Be 6
        @($obj.hook_health.present).Count | Should -Be 0
        @($obj.hook_health.disabled).Count | Should -Be 0
        $obj.hook_health.repair_hint | Should -Match 'repair-hooks'
    }

    It 'carries NO key outside the published run-summary contract' {
        $obj = Invoke-ReconcileSummary @('reconcile', '--dry-run', '--json', $Spec) | ConvertFrom-Json
        $allowed = @('schema_version', 'command', 'dry_run', 'counts', 'effects', 'drift', 'flags',
            'blockers', 'hook_health', 'mutations', 'actions', 'warnings', 'notes', 'exit_code')
        foreach ($k in $obj.PSObject.Properties.Name) { $allowed | Should -Contain $k }
    }

    It 'previews a dry-run --repair-hooks without writing (FR-047)' {
        $obj = Invoke-ReconcileSummary @('reconcile', '--repair-hooks', '--dry-run', '--json', $Spec) | ConvertFrom-Json
        Test-Path -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML | Should -BeFalse
        @($obj.hook_health.missing).Count | Should -Be 6
    }

    It 'registers hooks with --repair-hooks and then reports healthy (FR-047)' {
        $obj = Invoke-ReconcileSummary @('reconcile', '--repair-hooks', '--json', $Spec) | ConvertFrom-Json
        Test-Path -LiteralPath $env:SPEC_KIT_JIRA_EXTENSIONS_YML | Should -BeTrue
        @($obj.hook_health.present).Count | Should -Be 6
        @($obj.hook_health.missing).Count | Should -Be 0
        $obj.hook_health.PSObject.Properties.Name | Should -Not -Contain 'repair_hint'
    }
}
