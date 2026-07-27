# Mirror of tests/bash/ci/test_coverage_runner_bounds.bats. The `bash-coverage`
# CI job hit the runner's 20-minute wall with no report and no diagnostics.
# Three structural defects made that outcome both possible and unreadable:
#
#   1. kcov collects the trace by swapping the traced program's fd 2. Every
#      exercise phase ran under `> /dev/null 2>&1`, which points fd 2 at
#      /dev/null and discards every traced line.
#   2. Nothing bounded the kcov run, so a stuck child consumed the whole step
#      budget and GitHub killed the job before the script could report where it
#      stalled.
#   3. An aborted scenario left its pwsh mock running, and a surviving child
#      holds the tracer's pipe open, so kcov never sees EOF.
#
# File-shape assertions on purpose: the failure only reproduces on a Linux host
# with kcov installed, which is the environment this suite cannot assume.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CoveragePath = Join-Path $Root 'tests/coverage/bash-coverage.sh'
    $HarnessPath = Join-Path $Root 'tests/conformance/run-scenario.sh'
    $MockLibPath = Join-Path $Root 'tests/conformance/mock-jira/lib.sh'

    $Coverage = Get-Content -LiteralPath $CoveragePath
    $Harness = Get-Content -LiteralPath $HarnessPath
    $MockLib = Get-Content -LiteralPath $MockLibPath

    # The code that runs INSIDE kcov, where fd 2 belongs to the tracer. Comments
    # are dropped: that section documents the redirections it must not perform.
    $Exercise = @()
    $inExercise = $false
    foreach ($line in $Coverage) {
        if ($line -match '^# --- Exercise mode') { $inExercise = $true; continue }
        if ($line -match '^# --- Drive mode') { $inExercise = $false; continue }
        if ($inExercise -and $line -notmatch '^\s*#') { $Exercise += $line }
    }
}

Describe 'Bash coverage runner bounds' {
    It 'reads a non-empty exercise section' {
        $Exercise.Count | Should -BeGreaterThan 0
    }

    It 'never redirects fd 2 inside the exercise section' {
        $offenders = @($Exercise | Where-Object { $_ -match '2>' })
        ($offenders -join '; ') | Should -BeNullOrEmpty
    }

    It 'pins stdin to /dev/null for every exercised entry point' {
        $unguarded = @($Exercise |
            Where-Object { $_ -match 'source "\$\{(HARNESS|entry)\}' } |
            Where-Object { $_ -notmatch '< /dev/null' })
        ($unguarded -join '; ') | Should -BeNullOrEmpty
    }

    It 'bounds the kcov run with a wall clock' {
        ($Coverage | Where-Object { $_ -match '^\s*(run_bounded|timeout)[^|]*kcov' }).Count |
            Should -BeGreaterThan 0
    }

    It 'lets the wall clock be overridden' {
        ($Coverage | Where-Object { $_ -match 'SPEC_KIT_JIRA_COVERAGE_TIMEOUT' }).Count |
            Should -BeGreaterThan 0
    }

    It 'records progress somewhere the drive side can read after a stall' {
        ($Coverage | Where-Object { $_ -match 'PROGRESS' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Conformance mock lifetime' {
    It 'stops the mock on every harness exit path' {
        ($Harness | Where-Object { $_ -match '^\s*trap .*mock_stop.* EXIT' }).Count |
            Should -BeGreaterThan 0
    }

    It 'starts the mock without inheriting the caller stdio' {
        $launch = @($MockLib | Where-Object { $_ -match 'pwsh "\$\{args\[@\]\}"' })
        $launch.Count | Should -Be 1
        $launch[0] | Should -Match '< /dev/null'
        $launch[0] | Should -Match '> '
        $launch[0] | Should -Match '2> '
    }
}
