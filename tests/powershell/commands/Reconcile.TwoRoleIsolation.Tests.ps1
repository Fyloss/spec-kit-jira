# T079 [Phase 6, US4] — isolation rule I1: two independent per-role
# workflows never cross-evaluate each other's step name (contract
# role-lifecycle-config.md §5 I1). Mirror of the T078 bats test in
# tests/bash/commands/test_reconcile_lifecycle.bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-two-role-workflows'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out
        $oe = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $script:code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
        return $sw.ToString() + $se.ToString()
    }
}

Describe 'Invoke-JiraReconcile — two independent per-role workflows' {
    It 'the parent and every story advance on independent workflows, zero cross-role evaluations' {
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work
        $spec = Join-Path $work 'specs/001-two-role-example/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'

        $m = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/comp-two-role-transitions.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $m.BaseUrl
            $null = Invoke-Captured @('reconcile', $spec, '--json')

            # The mock always creates a fresh issue at "To Do" regardless of
            # project/role — a status the specification role's OWN delivery
            # workflow never declares. Move the parent to "Funnel" (its
            # after_specify step) directly, so drift has a classifiable
            # starting point for the specification role.
            Invoke-RestMethod -Method Put -Uri "$($m.BaseUrl)/rest/api/3/issue/COMP-1" `
                -ContentType 'application/json' `
                -Body '{"fields":{"status":{"name":"Funnel","statusCategory":{"key":"new"}}}}' | Out-Null

            Clear-Content -LiteralPath $m.CallLog
            $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
            try {
                $r = Invoke-Captured @('reconcile', $spec, '--json') | ConvertFrom-Json
            }
            finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }

            # The parent lands on "Building" (its own delivery workflow) …
            $parentTransition = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-1/transitions') })
            $parentTransition.Count | Should -Be 1
            [string]$parentTransition[0].body.transition.id | Should -Be '201'
            # … each story lands on "In Progress" (its own development workflow) …
            $expected = @{ 'COMP-2' = '202'; 'COMP-3' = '203'; 'COMP-4' = '204' }
            foreach ($key in $expected.Keys) {
                $t = @($r.actions | Where-Object { ([string]$_.url).EndsWith("/rest/api/3/issue/$key/transitions") })
                $t.Count | Should -Be 1
                [string]$t[0].body.transition.id | Should -Be $expected[$key]
            }
            # … zero warnings (no ambiguous/gated/unreachable outcome for any ticket) —
            # $r.warnings is omitted entirely from a run with nothing to report
            # (matching bash byte-for-byte), so $r.warnings is $null here, and
            # @($null).Count is 1, never 0 — -BeNullOrEmpty is the correct check.
            $r.warnings | Should -BeNullOrEmpty
            # … and exactly one availability read per ticket — never more, never
            # a read against the other role's declared step.
            @(Get-JiraMockCallLog -Mock $m | Where-Object { $_ -match '/transitions\?expand=' }).Count | Should -Be 4
        }
        finally { Stop-JiraMock -Mock $m }
    }
}
