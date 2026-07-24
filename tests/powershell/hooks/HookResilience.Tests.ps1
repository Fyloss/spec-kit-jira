# T081 [US9] — Hook resilience, PowerShell side.
# Mirror of tests/bash/hooks/test_hook_resilience.bats. Cross-port byte agreement
# is proven in bats; here we assert the resilience semantics (FR-046, FR-048, SC-008).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root '.specify/extensions/jira/scripts/powershell/commands'
    $HookDir = Join-Path $Root '.specify/extensions/jira/scripts/powershell/hooks'
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $HookDir 'RegisterHooks.psm1') -Force
    Import-Module (Join-Path $Root '.specify/extensions/jira/scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root '.specify/extensions/jira/scripts/powershell/lib/Output.psm1') -Force

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
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
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

    It 'keeps an operator-disabled hook disabled across repeated repair (FR-048, SC-008)' {
        $ext = $env:SPEC_KIT_JIRA_EXTENSIONS_YML
        [void](Set-JiraHookRegistration -Path $ext)
        $obj = ConvertFrom-JiraConfigYaml -Path $ext | ConvertFrom-Json
        $obj.hooks.after_specify[0].enabled = $false
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $obj)
        [System.IO.File]::WriteAllText($ext, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        [void](Set-JiraHookRegistration -Path $ext)
        [void](Set-JiraHookRegistration -Path $ext)
        [void](Set-JiraHookRegistration -Path $ext)
        $json = ConvertFrom-JiraConfigYaml -Path $ext | ConvertFrom-Json
        @($json.hooks.after_specify).Count | Should -Be 1
        $json.hooks.after_specify[0].enabled | Should -BeFalse
    }
}
