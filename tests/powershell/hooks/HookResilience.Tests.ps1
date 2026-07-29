# T022 [003 US2] — Hook resilience under `optional: false`. Twin of
# tests/bash/hooks/test_hook_resilience.bats. Originally T081 [US9] — Hook resilience, PowerShell side.
# Mirror of tests/bash/hooks/test_hook_resilience.bats. Cross-port byte agreement
# is proven in bats; here we assert the resilience semantics (FR-046, FR-048, SC-008).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $HookDir = Join-Path $Root 'scripts/powershell/hooks'
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $HookDir 'RegisterHooks.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Output.psm1') -Force

    function Invoke-ReconcileCode([string[]] $ArgList) {
        # Swallow the summary and return only the exit code. The param must NOT be
        # named $Args — that collides with PowerShell's automatic variable.
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { return (Invoke-JiraReconcile -Arguments $ArgList) }
        finally { [Console]::SetOut($orig) }
    }
}

Describe 'Hook resilience' {
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
        # 004 FR-005: the shipped placeholder is now refused outright, so this
        # suite (about hook resilience, not config resolution) is migrated to
        # a real key with a matching epic-strategy override — both bypass
        # config.yml, which this isolated work dir never has.
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST'
        $env:SPEC_KIT_JIRA_EPIC_STRATEGY = 'per_repo'
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
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_EPIC_STRATEGY -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'fails a bridge error outside hook context (baseline)' {
        $code = Invoke-ReconcileCode @('reconcile', '--json', $Spec)
        $code | Should -Not -Be 0
    }

    It 'never fails the host in hook context (FR-046)' {
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        $code = Invoke-ReconcileCode @('reconcile', '--json', $Spec)
        $code | Should -Be 0
    }

    It 'leaves the host exit code untouched for every bridge fault (FR-015)' {
        # Under `optional: false` the agent PERFORMS this step as part of the host
        # command, so a fault that returns early must be downgraded too — not only
        # the ones that reach the end of the run.
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        (Invoke-ReconcileCode @('reconcile', '--json', $Spec)) | Should -Be 0

        $bad = Join-Path ([System.IO.Path]::GetTempPath()) "$([System.Guid]::NewGuid()).md"
        Set-Content -Path $bad -Value 'not a specification at all' -NoNewline
        (Invoke-ReconcileCode @('reconcile', '--json', $bad)) | Should -Be 0
        Remove-Item -Force $bad -ErrorAction SilentlyContinue

        $env:SPEC_KIT_JIRA_LIFECYCLE = '{not json'
        try { (Invoke-ReconcileCode @('reconcile', '--json', $Spec)) | Should -Be 0 }
        finally { Remove-Item Env:SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue }
    }

    It 'is inert at dispatch for a recorded event — no Jira call, no warning (FR-020)' {
        # The operator's decision lives in OUR file, so it survives the reinstall
        # that rewrote the registry to `enabled: true`. The guarantee is on the
        # EFFECT (no bridge step runs), not on the registry field, which upstream
        # rewrites unconditionally (research R5).
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $env:JIRA_CONFIG_DIR = $dir
        try {
            $null = Add-JiraHooksDisabled -LifecycleEvent 'after_specify' -ConfigDir $dir
            $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
            (Invoke-ReconcileCode @('reconcile', '--json', $Spec)) | Should -Be 0
        }
        finally {
            Remove-Item Env:SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
            Remove-Item Env:JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }

    It 'never brings the hook registry into existence (FR-022, SC-011)' {
        $ext = $env:SPEC_KIT_JIRA_EXTENSIONS_YML
        Remove-Item -Force $ext -ErrorAction SilentlyContinue
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        $null = Invoke-ReconcileCode @('reconcile', '--json', $Spec)
        $null = Invoke-ReconcileCode @('reconcile', '--dry-run', '--json', $Spec)
        Test-Path -LiteralPath $ext | Should -BeFalse
    }
}
