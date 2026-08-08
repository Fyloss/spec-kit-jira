# T008 — Per-phase timing (spec FR-001…FR-006, contracts/timing-report.md).
# Pester twin of tests/bash/lib/test_timing.bats (T007).
#
# Off by default; every function is a no-op unless SPEC_KIT_JIRA_TIMING is
# set. Unlike the bash port there is no clock-tier test here: research R1
# gives PowerShell a single always-available clock ([datetime]::UtcNow.Ticks
# / 10000, never forks), so there is no probed tier and no degraded-clock
# banner to exercise. `_TIMING_FAKE_CLOCK` (an environment variable here, so
# the conformance harness's `env` block can inject it identically for both
# ports) makes the report byte-diffable against the bash port regardless.
#
# The request count is passed explicitly (`-RequestCount`) rather than read
# from a shared variable: PowerShell modules do not share a bash process's
# flat namespace, and `JIRA_REQUEST_COUNT` stays `$script:`-scoped inside
# Client.psm1 (T013) — the caller (Reconcile.psm1, T015) reads it there and
# hands the value to each phase mark.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    $ModulePath = Join-Path $LibDir 'Timing.psm1'

    function Invoke-TimingReportCaptured {
        $sw = [System.IO.StringWriter]::new()
        $origErr = [Console]::Error
        [Console]::SetError($sw)
        try { Write-JiraTimingReport } finally { [Console]::SetError($origErr) }
        return $sw.ToString()
    }
}

Describe 'Timing' {
    BeforeEach {
        # Force-reimport for a clean $script: state each test — the twin of
        # bats' fresh `source` inside `setup()`.
        Import-Module $ModulePath -Force
        $env:SPEC_KIT_JIRA_TIMING = '1'
    }

    AfterEach {
        Remove-Item Env:\SPEC_KIT_JIRA_TIMING -ErrorAction SilentlyContinue
        Remove-Item Env:\_TIMING_FAKE_CLOCK -ErrorAction SilentlyContinue
    }

Describe 'Timing activation' {
    It 'every function is a no-op when SPEC_KIT_JIRA_TIMING is unset' {
        Remove-Item Env:\SPEC_KIT_JIRA_TIMING -ErrorAction SilentlyContinue
        Start-JiraTimingPhase -Phase prereq
        Stop-JiraTimingPhase -Phase prereq
        $out = Invoke-TimingReportCaptured
        $out | Should -BeNullOrEmpty
    }

    It 'every function is a no-op when SPEC_KIT_JIRA_TIMING is empty' {
        $env:SPEC_KIT_JIRA_TIMING = ''
        Start-JiraTimingPhase -Phase prereq
        Stop-JiraTimingPhase -Phase prereq
        $out = Invoke-TimingReportCaptured
        $out | Should -BeNullOrEmpty
    }
}

Describe 'The fixed-width report shape (contracts/timing-report.md §2)' {
    It 'renders the fixed-width shape with an injected clock' {
        $env:_TIMING_FAKE_CLOCK = '0 12 12 19 19 107 107 148 148 157 157 891 891 954 954 3795'
        Start-JiraTimingPhase -Phase prereq -RequestCount 0
        Stop-JiraTimingPhase -Phase prereq -RequestCount 0
        Start-JiraTimingPhase -Phase state -RequestCount 0
        Stop-JiraTimingPhase -Phase state -RequestCount 0
        Start-JiraTimingPhase -Phase config -RequestCount 0
        Stop-JiraTimingPhase -Phase config -RequestCount 0
        Start-JiraTimingPhase -Phase parse -RequestCount 0
        Stop-JiraTimingPhase -Phase parse -RequestCount 0
        Start-JiraTimingPhase -Phase gate -RequestCount 0
        Stop-JiraTimingPhase -Phase gate -RequestCount 0
        Start-JiraTimingPhase -Phase recognition -RequestCount 0
        Stop-JiraTimingPhase -Phase recognition -RequestCount 2
        Start-JiraTimingPhase -Phase plan -RequestCount 2
        Stop-JiraTimingPhase -Phase plan -RequestCount 2
        Start-JiraTimingPhase -Phase apply -RequestCount 2
        Stop-JiraTimingPhase -Phase apply -RequestCount 13

        $lines = (Invoke-TimingReportCaptured) -split "`r?`n" | Where-Object { $_ -ne '' }

        $lines[0] | Should -Be 'timing: prereq          12 ms    0 requests'
        $lines[1] | Should -Be 'timing: state            7 ms    0 requests'
        $lines[2] | Should -Be 'timing: config          88 ms    0 requests'
        $lines[3] | Should -Be 'timing: parse           41 ms    0 requests'
        $lines[4] | Should -Be 'timing: gate             9 ms    0 requests'
        $lines[5] | Should -Be 'timing: recognition    734 ms    2 requests'
        $lines[6] | Should -Be 'timing: plan            63 ms    0 requests'
        $lines[7] | Should -Be 'timing: apply         2841 ms   11 requests'
        $lines[8] | Should -Be 'timing: total         3795 ms   13 requests'
    }

    It 'does not print a phase not reached, and prints in fixed order regardless of call order' {
        $env:_TIMING_FAKE_CLOCK = '0 5 0 3'
        Start-JiraTimingPhase -Phase apply
        Stop-JiraTimingPhase -Phase apply
        Start-JiraTimingPhase -Phase prereq
        Stop-JiraTimingPhase -Phase prereq

        $lines = (Invoke-TimingReportCaptured) -split "`r?`n" | Where-Object { $_ -ne '' }

        $lines.Count | Should -Be 3
        $lines[0] | Should -Match '^timing: prereq'
        $lines[1] | Should -Match '^timing: apply'
        $lines[2] | Should -Match '^timing: total'
    }

    It 'a short-circuited run reports prereq, state, and the total, and nothing else' {
        $env:_TIMING_FAKE_CLOCK = '0 12 12 19'
        Start-JiraTimingPhase -Phase prereq
        Stop-JiraTimingPhase -Phase prereq
        Start-JiraTimingPhase -Phase state
        Stop-JiraTimingPhase -Phase state

        $lines = (Invoke-TimingReportCaptured) -split "`r?`n" | Where-Object { $_ -ne '' }

        $lines.Count | Should -Be 3
        $lines[0] | Should -Match '^timing: prereq'
        $lines[1] | Should -Match '^timing: state'
        $lines[2] | Should -Match '^timing: total'
    }

    It 'requests counts the caller-supplied RequestCount delta across the phase' {
        $env:_TIMING_FAKE_CLOCK = '1000 1500'
        Start-JiraTimingPhase -Phase recognition -RequestCount 4
        Stop-JiraTimingPhase -Phase recognition -RequestCount 7

        $lines = (Invoke-TimingReportCaptured) -split "`r?`n" | Where-Object { $_ -ne '' }

        $lines[0] | Should -Be 'timing: recognition    500 ms    3 requests'
    }
}

Describe 'The _TIMING_FAKE_CLOCK seam' {
    It 'yields deterministic durations, consumed in order' {
        $env:_TIMING_FAKE_CLOCK = '100 250'
        Start-JiraTimingPhase -Phase prereq
        Stop-JiraTimingPhase -Phase prereq

        $lines = (Invoke-TimingReportCaptured) -split "`r?`n" | Where-Object { $_ -ne '' }
        $lines[0] | Should -Be 'timing: prereq         150 ms    0 requests'
    }

    It 'returns its last reading again once exhausted' {
        $env:_TIMING_FAKE_CLOCK = '10 20'
        Start-JiraTimingPhase -Phase prereq
        Stop-JiraTimingPhase -Phase prereq
        Start-JiraTimingPhase -Phase state
        Stop-JiraTimingPhase -Phase state

        $lines = (Invoke-TimingReportCaptured) -split "`r?`n" | Where-Object { $_ -ne '' }
        $lines[0] | Should -Be 'timing: prereq          10 ms    0 requests'
        $lines[1] | Should -Be 'timing: state            0 ms    0 requests'
    }

    # A set-but-empty _TIMING_FAKE_CLOCK supplies zero readings, so the cursor
    # clamp computes index -1 over an empty array — which throws under
    # Set-StrictMode -Version Latest rather than degrading. §4 says an
    # under-supplied fixture shows 0 ms phases rather than crashing a run, and
    # that has to hold at zero readings too. Mirror of the bats twin.
    It 'set to whitespace only reads 0 ms rather than throwing' {
        $env:_TIMING_FAKE_CLOCK = '   '
        { Start-JiraTimingPhase -Phase prereq } | Should -Not -Throw
        { Stop-JiraTimingPhase -Phase prereq } | Should -Not -Throw

        $lines = (Invoke-TimingReportCaptured) -split "`r?`n" | Where-Object { $_ -ne '' }
        $lines[0] | Should -Be 'timing: prereq           0 ms    0 requests'
    }
}

}
