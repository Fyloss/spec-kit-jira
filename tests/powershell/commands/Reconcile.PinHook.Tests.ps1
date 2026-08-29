# T065 [032] — the destination pin's refusal under a lifecycle hook, PowerShell
# side. Mirror of tests/bash/commands/test_reconcile_pin_hook.bats
# (contracts/origin-pinning.md §C5, SC-006).
#
# Two things are proven here that the conformance corpus structurally cannot:
#
#   * Constitution III's hook contract — an `after_*` step must never fail the
#     host command. The corpus runs the bridge directly, never as a hook, so
#     only a per-port suite can set SPEC_KIT_JIRA_HOOK_CONTEXT and observe the
#     downgrade.
#   * That the LOCATED message survives the downgrade. Reconcile's chokepoint
#     call site substitutes a generic "team configuration could not be loaded"
#     line for whatever the library reported; if that substitution ever comes
#     back, the operator loses both origins and the accepting invocation on
#     exactly the path a hook takes, and every conformance scenario still
#     passes because none of them runs under a hook.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-032-origin-mismatch'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
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

Describe 'Invoke-JiraReconcile — the destination pin refusal' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-feature/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
        # The gate only applies to a FILE-supplied destination (C4.3): with this
        # set, FR-011 exempts the run and nothing below would fire.
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }

    It 'C4.5 — outside a hook the mismatch refuses with exit 4 and zero requests' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $r = Invoke-CapturedAll @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 4
        $r.Output | Should -Match 'this checkout is bound to'
        @(Get-JiraMockCallLog -Mock $script:M) | Should -BeNullOrEmpty
    }

    It 'C5.1 — under a hook it downgrades to one WARNING and exit 0' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = 'after_specify'
        $r = Invoke-CapturedAll @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        @([regex]::Matches($r.Output, '(?m)^WARNING: ')).Count | Should -Be 1
    }

    It 'C5.2 — the located message survives the hook downgrade' {
        # The regression this exists for: the chokepoint call site replacing the
        # pin's message with the generic configuration-load line.
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = 'after_specify'
        $r = Invoke-CapturedAll @('reconcile', $script:Spec, '--json')
        $r.Output | Should -Match 'declared\.example\.invalid'
        $r.Output | Should -Match 'other\.example\.invalid'
        $r.Output | Should -Match '--accept-site'
        $r.Output | Should -Not -Match 'the team configuration could not be loaded'
    }

    It 'C5.1 — a hook refusal still issues zero requests' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = 'after_specify'
        Invoke-CapturedAll @('reconcile', $script:Spec, '--json') | Out-Null
        @(Get-JiraMockCallLog -Mock $script:M) | Should -BeNullOrEmpty
    }

    It 'C5.3 — the downgrade holds for every registered lifecycle event' {
        # SC-006 names all seven. A guarantee proven for one event and assumed
        # for the others is the shape of defect this project has shipped before.
        foreach ($event in @('after_specify', 'after_plan', 'after_tasks', 'after_analyze', 'after_implement', 'after_clarify', 'before_specify')) {
            $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
            $env:SPEC_KIT_JIRA_HOOK_CONTEXT = $event
            $r = Invoke-CapturedAll @('reconcile', $script:Spec, '--json')
            $r.ExitCode | Should -Be 0 -Because "event $event must not fail the host command"
            @([regex]::Matches($r.Output, '(?m)^WARNING: ')).Count |
                Should -Be 1 -Because "event $event must emit exactly one WARNING"
            Stop-JiraMock -Mock $script:M; $script:M = $null
        }
    }

    It 'C4.10 — no refusal path echoes any part of the credential' {
        # SC-007, at maximum verbosity. The token is a sentinel here so a
        # substring match is meaningful.
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:JIRA_API_TOKEN = 'SENTINELTOKEN0123456789'
        $r = Invoke-CapturedAll @('reconcile', $script:Spec, '--json', '--verbose')
        $r.Output | Should -Not -Match 'SENTINELTOKEN'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    }
}
