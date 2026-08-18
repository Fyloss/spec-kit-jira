# T084 [030] — the fail-closed departure: a declared retrieval command that
# fails now RAISES where the old .env/secret-manager rungs fell through
# silently. In hook context the host is still never failed (FR-015 holds
# unconditionally) — what changes is that the failure is REPORTED, and that
# it is bounded rather than hanging or prompting.
#
# A standalone file, not another It in HookResilience.Tests.ps1: the
# credential cache (Credentials.psm1, 021 US3) is $script:-scoped and shared
# for the whole Pester PROCESS, and reimporting the module chain -Force
# mid-suite to reset it clobbers a caller's own bindings (memory:
# powershell-import-force-clobbers-caller-scope) — it silently broke
# Add-JiraHooksDisabled's availability for every test after it, the hard way.
# A fresh process per file is the reliable isolation boundary here.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/hooks/RegisterHooks.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Output.psm1') -Force
    Import-Module (Join-Path $Root 'tests/powershell/helpers/SecretStoreStub.psm1') -Force
}

Describe 'Hook resilience — the fail-closed credential departure' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        $script:Spec = Join-Path $Work 'spec.md'
        @(
            '# Feature Specification: Resilience', '', 'A spec that mirrors to Jira.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a user', '- **When** they act', '- **Then** it works'
        ) -join "`n" | Set-Content -LiteralPath $Spec -NoNewline
        $env:SPEC_KIT_JIRA_BASE_URL = 'http://127.0.0.1:1'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST'
        $env:SPEC_KIT_JIRA_EXTENSIONS_YML = Join-Path $Work '.specify/extensions.yml'
        $env:JIRA_NO_SLEEP = '1'
        $env:JIRA_MAX_ATTEMPTS = '1'
        $env:JIRA_EMAIL = 'user@example.com'
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"10004"}'
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\JIRA_API_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\JIRA_PAT_COMMAND -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\JIRA_PAT_COMMAND -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'T084: a hook-invoked run with a failing declared JIRA_PAT_COMMAND reports and completes without hanging or prompting' {
        # Re-import -Force: this file's BeforeAll already loaded Reconcile.psm1
        # once, but if an EARLIER-discovered Pester file in the same process
        # (alphabetically, or via a recursive -Path) already resolved and
        # cached a real credential through the shared module chain, that
        # cache survives across files too — module instances are PROCESS-wide,
        # not per-file. Safe here specifically because this file has no
        # sibling test relying on a stale binding from before the reimport
        # (unlike HookResilience.Tests.ps1, where this exact reimport broke
        # Add-JiraHooksDisabled for later tests — memory:
        # powershell-import-force-clobbers-caller-scope).
        Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Client.psm1') -Force
        Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
        $bindir = Join-Path $Work 'bin'
        $counter = Join-Path $Work 'count'
        Install-JiraPatCommandStub -BinDir $bindir -CounterFile $counter -Token '' -ExitCode 1 | Out-Null
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'

        $sw = [System.IO.StringWriter]::new(); $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out; $oe = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($se)
        $started = Get-Date
        try { $code = Invoke-JiraReconcile -Arguments @('reconcile', '--json', $Spec) }
        finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
        $elapsedSeconds = ((Get-Date) - $started).TotalSeconds
        $text = $sw.ToString() + $se.ToString()

        # Bounded: the credential rung's own 5s bound, not a hang.
        $elapsedSeconds | Should -BeLessThan 10
        # The host is never failed (FR-015 holds for this new failure branch too).
        [int]$code | Should -Be 0
        # Reported: exactly one WARNING, unlike the old rungs' silent fall-through.
        @([regex]::Matches($text, 'WARNING:')).Count | Should -Be 1
        $text | Should -Match 'credential resolution failed'
    }
}
