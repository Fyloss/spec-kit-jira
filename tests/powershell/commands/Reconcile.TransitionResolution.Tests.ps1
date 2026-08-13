# T033/T040a [Phase 4, US1] — a declared step actually moves a ticket, end
# to end through reconcile, PowerShell side. Mirror of
# tests/bash/commands/test_reconcile_transition_resolution.bats. This is
# the failing test the whole feature turned green (quickstart §1).

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333 4444444444444444'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    $script:ConfigYaml = @'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
'@

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

Describe 'Invoke-JiraReconcile — a declared step actually moves a ticket' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-billing-invoices/spec.md'
        Set-Content -NoNewline -Path (Join-Path $script:Work '.specify/jira/config.yml') -Value $script:ConfigYaml
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/comp-transitions.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'an ungated declared step actually moves the ticket, once, and counts it' {
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        $transitionAction = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-2/transitions') })
        $transitionAction.Count | Should -Be 1
        [string]$transitionAction[0].body.transition.id | Should -Be '101'
        [int]$r.counts.transitioned | Should -BeGreaterOrEqual 1
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^GET /rest/api/3/issue/COMP-2/transitions' }).Count | Should -Be 1
    }

    It 'two candidates onto the declared step move nothing and warn, naming both' {
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-3/transitions') }).Count | Should -Be 0
        (@($r.warnings) -join ' ') | Should -Match 'COMP-3'
    }

    It 'T122 -- an ambiguous outcome names both candidates verbatim, content still mirrors, exactly one warning and idempotent on a repeat run' {
        # A genuine content diff for COMP-3's own story -- otherwise its PUT
        # is zero-churn (unchanged since BeforeEach's own creation run) and
        # the content-survival assertion below would prove nothing.
        $content = (Get-Content -Raw -LiteralPath $script:Spec) `
            -replace 'export every invoice in a date range', 'export every invoice in a date range as a bundle'
        Set-Content -NoNewline -Path $script:Spec -Value $content

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        $comp3Warns = @($r.warnings | Where-Object { $_ -like '*COMP-3*' })
        $comp3Warns.Count | Should -Be 1
        $comp3Warns[0] | Should -Be 'Story ticket COMP-3 was not moved to "In Progress": 2 transitions land on it (Start (102), Start (dup) (103)). The bridge invents no preference — perform the one you want by hand, or narrow the workflow.'
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-3') -and $_.method -eq 'PUT' }).Count | Should -Be 1

        # A second run under the same event produces the SAME single
        # warning — never duplicated, never grown.
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r2 = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        $comp3Warns2 = @($r2.warnings | Where-Object { $_ -like '*COMP-3*' })
        $comp3Warns2.Count | Should -Be 1
        $comp3Warns2[0] | Should -Be $comp3Warns[0]
    }

    It 'T131 -- a recorded field_defaults value of the same name is never substituted for the gated field, warning unchanged (rule M4, FR-006)' {
        # A FRESH mock instance too (Stop-JiraMock/Start-JiraMock, not
        # BeforeEach's own instance which already advanced past COMP-1..4):
        # field_defaults must never even be CONSULTED for a transition
        # resolution (the POST body is always {transition:{id}} with no
        # fields key), so this proves isolation, not a shared-state
        # interaction with the other tests in this file. Reusing
        # BeforeEach's own mock instance would create COMP-5..8 instead,
        # breaking the hardcoded "COMP-4" fault key below.
        Stop-JiraMock -Mock $script:M
        $work2 = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work2
        $spec2 = Join-Path $work2 'specs/001-billing-invoices/spec.md'
        $configYaml2 = @'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
field_defaults:
  COMP:
    ask: false
    Story:
      Resolution: "Done"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
'@
        Set-Content -NoNewline -Path (Join-Path $work2 '.specify/jira/config.yml') -Value $configYaml2
        $env:JIRA_CONFIG_DIR = Join-Path $work2 '.specify/jira'

        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/comp-transitions.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $spec2, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $spec2, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        # The gated warning is byte-identical to the no-field_defaults case
        # — naming the demanded field, never a substituted value.
        $comp4Warn = @($r.warnings | Where-Object { $_ -like '*COMP-4*' })[0]
        $comp4Warn | Should -Be 'Story ticket COMP-4 was not moved to "In Progress": completing that transition requires "Resolution", which the bridge does not hold and never guesses. Set it by hand, then reconcile.'
    }

    It 'T140 -- an unreachable declared step names the reachable set, the empty set, or a near-miss verbatim, never forcing an intermediate move' {
        # A FRESH mock instance too: three distinct unreachable shapes on
        # the SAME due set, one read (contract §2 T047).
        Stop-JiraMock -Mock $script:M
        $work2 = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work2
        $spec2 = Join-Path $work2 'specs/001-billing-invoices/spec.md'
        Copy-Item -Path (Join-Path $script:Work '.specify/jira/config.yml') -Destination (Join-Path $work2 '.specify/jira/config.yml') -Force
        $env:JIRA_CONFIG_DIR = Join-Path $work2 '.specify/jira'

        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"transitions":{"COMP-2":[{"id":"201","name":"Review","to":{"name":"Under Review"},"fields":{}}],"COMP-3":[],"COMP-4":[{"id":"203","name":"Start","to":{"name":"in progress"},"fields":{}}]}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $spec2, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $spec2, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }

        # Reachable-set form: COMP-2 has a move, just not onto the declared step.
        $comp2Warn = @($r.warnings | Where-Object { $_ -like '*COMP-2*' })[0]
        $comp2Warn | Should -Be 'Story ticket COMP-2 was not moved to "In Progress": no transition from "To Do" lands on it. Reachable from here: Under Review. Move it by hand, or map this event to one of those.'

        # Empty-set form: COMP-3 has no transition available at all.
        $comp3Warn = @($r.warnings | Where-Object { $_ -like '*COMP-3*' })[0]
        $comp3Warn | Should -Be 'Story ticket COMP-3 was not moved to "In Progress": no transition from "To Do" is available at all. Move it by hand, or map this event to a reachable step.'

        # Near-miss: COMP-4's only candidate lands on "in progress"
        # (lower-case), not "In Progress" (M2, exact string equality) --
        # unreachable, and the reachable set names the candidate's ACTUAL
        # name verbatim, proving no case-insensitive or whitespace-
        # normalising match ever happened.
        $comp4WarnUnreach = @($r.warnings | Where-Object { $_ -like '*COMP-4*' })[0]
        $comp4WarnUnreach | Should -Be 'Story ticket COMP-4 was not moved to "In Progress": no transition from "To Do" lands on it. Reachable from here: in progress. Move it by hand, or map this event to one of those.'

        # Never an inferred intermediate move: zero transition POSTs this run.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^POST .*/transitions$' }).Count | Should -Be 0
    }

    It 'a gated declared step moves nothing and names the withheld field' {
        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-4/transitions') }).Count | Should -Be 0
        (@($r.warnings) -join ' ') | Should -Match 'Resolution'
    }

    It 'a second run under the same event moves nothing more — idempotent (Z2)' {
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
            Clear-Content -LiteralPath $script:M.CallLog
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        [int]$r.counts.transitioned | Should -Be 0
    }

    It 'a ticket already at its declared step asks the tracker nothing about it' {
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $null = Invoke-Captured @('reconcile', $script:Spec, '--json')
            Clear-Content -LiteralPath $script:M.CallLog
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^GET /rest/api/3/issue/COMP-2/transitions' }).Count | Should -Be 0
        (@($r.warnings) -join ' ') | Should -Not -Match 'COMP-2'
    }

    It 'T110 -- an ambiguous or gated outcome never suppresses that ticket''s own content update, and never suppresses another ticket''s move (U2/U3)' {
        # A genuine content diff for COMP-3 and COMP-4's own stories --
        # otherwise their PUT is zero-churn (unchanged since BeforeEach's
        # own creation run) and this test would prove nothing about
        # content survival.
        $content = (Get-Content -Raw -LiteralPath $script:Spec) `
            -replace 'export every invoice in a date range', 'export every invoice in a date range as a bundle' `
            -replace 'a clear message when export is temporarily unavailable', 'a clear message when export is temporarily unavailable for maintenance'
        Set-Content -NoNewline -Path $script:Spec -Value $content

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        try {
            $r = Invoke-Captured @('reconcile', $script:Spec, '--json') | ConvertFrom-Json
        }
        finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        # COMP-3 (ambiguous) and COMP-4 (gated) still receive their content PUT.
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-3') -and $_.method -eq 'PUT' }).Count | Should -Be 1
        @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-4') -and $_.method -eq 'PUT' }).Count | Should -Be 1
        # COMP-2's own move (a clean outcome) still fires in the SAME run --
        # neither COMP-3's ambiguous nor COMP-4's gated outcome suppresses it.
        $t = @($r.actions | Where-Object { ([string]$_.url).EndsWith('/rest/api/3/issue/COMP-2/transitions') })
        $t.Count | Should -Be 1
        [string]$t[0].body.transition.id | Should -Be '101'
    }

    It 'T112 -- an exhausted availability read fails closed for the WHOLE specification, zero content writes, exit code F2 (contract §2)' {
        # BeforeEach's own $script:Spec already carries real markers
        # recorded against BeforeEach's own mock instance -- restarting the
        # mock (fresh, blank state) against that SAME file would refuse as
        # an unrecognised identity, not exercise the fault this test is
        # about. A genuinely fresh work directory keeps this test's own
        # mock instance the only one its markers were ever recorded
        # against.
        Stop-JiraMock -Mock $script:M
        $work2 = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work2
        $spec2 = Join-Path $work2 'specs/001-billing-invoices/spec.md'
        Copy-Item -Path (Join-Path $script:Work '.specify/jira/config.yml') -Destination (Join-Path $work2 '.specify/jira/config.yml') -Force
        $env:JIRA_CONFIG_DIR = Join-Path $work2 '.specify/jira'

        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"transitions":{"COMP-2":[{"id":"101","name":"Start","to":{"name":"In Progress"},"fields":{}}]},"faults":{"issue/COMP-2/transitions":{"status":400}}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $spec2, '--json')

        Clear-Content -LiteralPath $script:M.CallLog
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        $out = ''
        try { $out = Invoke-Captured @('reconcile', $spec2, '--json') } finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        [int]$script:code | Should -Be 2
        $out | Should -Match 'COMP-2'
        # Fail-closed for the WHOLE specification -- not even the OTHER
        # tickets' already-decided content writes reach the tracker (reads
        # -- recognition's own bulkfetch prefetch, and the failing
        # availability read itself -- are not writes, and are expected).
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -notmatch 'bulkfetch' -and $_ -notmatch 'transitions\?expand' }).Count | Should -Be 0
    }

    It 'T116 -- a rejected move (write rejected after a healthy read) is reported naming the ticket, no retry, no re-ask, no substitute' {
        # A human moves COMP-2 between reconcile's own read of its available
        # moves and the transition POST that read decided on: the read stays
        # healthy (COMP-2's declared move is genuinely available), but the
        # WRITE itself is rejected (409 -- the ticket has since moved).
        # Method-keyed fault (T116's own mock enhancement to Get-Fault): the
        # GET on /issue/COMP-2/transitions must stay healthy while the POST
        # to the same path is rejected.
        Stop-JiraMock -Mock $script:M
        $work2 = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work2
        $spec2 = Join-Path $work2 'specs/001-billing-invoices/spec.md'
        Copy-Item -Path (Join-Path $script:Work '.specify/jira/config.yml') -Destination (Join-Path $work2 '.specify/jira/config.yml') -Force
        $env:JIRA_CONFIG_DIR = Join-Path $work2 '.specify/jira'

        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"},"transitions":{"COMP-2":[{"id":"101","name":"Start","to":{"name":"In Progress"},"fields":{}}]},"faults":{"issue/COMP-2/transitions":{"status":409,"method":"POST","body":{"errorMessages":["The transition is not valid."]}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $null = Invoke-Captured @('reconcile', $spec2, '--json')

        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        $out = ''
        try { $out = Invoke-Captured @('reconcile', $spec2, '--json') } finally { Remove-Item Env:\SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue }
        [int]$script:code | Should -BeGreaterOrEqual 2
        $out | Should -Match 'Story ticket COMP-2 was not moved to "In Progress"'
        $out | Should -Match 'rejected the transition'
        # No retry: exactly one POST to COMP-2's own transitions endpoint this run.
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match '^POST /rest/api/3/issue/COMP-2/transitions' }).Count | Should -Be 1
    }
}
