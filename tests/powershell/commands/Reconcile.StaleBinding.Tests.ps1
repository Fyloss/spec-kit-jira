# T015/T016 [Phase 2] — mirror of tests/bash/commands/test_reconcile_stale_binding.bats.
# spec FR-003a: a pre-feature binding refuses with its OWN message, never
# "not bound yet", and never reaches the first GET.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-stale-binding'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-billing'
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue

    function Invoke-CapturedAll {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($sw)
        $code = 0
        try { $code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
        return [pscustomobject]@{ Output = $sw.ToString(); ExitCode = $code }
    }
}

Describe 'Invoke-JiraReconcile — the stale-binding refusal' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }

    It 'refuses with its own message, exit 4, zero writes' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Invoke-CapturedAll @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 4
        $r.Output | Should -Match 'predates parent support'
        $r.Output | Should -Not -Match 'has not been bound yet'
        @(Get-JiraMockCallLog -Mock $script:M) | Should -BeNullOrEmpty
    }

    It 'downgrades to one WARNING and exit 0 under a hook (FR-032)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = 'after_specify'

        $r = Invoke-CapturedAll @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        @([regex]::Matches($r.Output, '(?m)^WARNING: ')).Count | Should -Be 1
        $r.Output | Should -Match 'predates parent support'
    }
}
