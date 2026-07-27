# Mirror of tests/bash/ci/test_coverage_bats_measurement.bats (T103). The gate
# measured the wrong thing, against an inflated denominator, and reported 59.24%
# for a port whose unit suites cover far more than that.
#
#   1. Constitution XIII computes coverage on the MOCKED UNIT SUITES. kcov
#      cannot run them — it instruments bats-core's own DEBUG-trap tracing and
#      the two feed each other an unbounded trace — so the gate measured only
#      the conformance corpus, which never drives the error paths that
#      credentials.psm1's Bash twin and friends are unit-tested for. The bats
#      suite is now traced on a dedicated fd and merged with kcov's report.
#   2. Without `--exclude-region`, the ~533 lines the port brackets as
#      `kcov-excl-start/stop` (multi-line jq literals, whose continuation lines
#      kcov counts as statements no execution can hit) sit permanently in the
#      denominator.
#   3. `PS4` must survive `set -u`: `${BASH_SOURCE}` without a default makes
#      every traced `bash -c` child print "BASH_SOURCE: unbound variable" into
#      the output bats captured, turning green tests red.
#
# File-shape assertions on purpose: the merge only reproduces on a Linux host
# with kcov, which is the environment this suite cannot assume.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CoveragePath = Join-Path $Root 'tests/coverage/bash-coverage.sh'
    $WorkflowDir = Join-Path $Root '.github/workflows'

    $Coverage = Get-Content -LiteralPath $CoveragePath

    # Backslash continuations joined: the runaway invocation spans four lines,
    # and a per-line match never sees it.
    function Join-ShellContinuations {
        param([string[]] $Lines)
        $joined = @()
        $buffer = ''
        foreach ($line in $Lines) {
            $buffer += $line
            if ($buffer -match '\\$') { $buffer = $buffer -replace '\\$', ' '; continue }
            $joined += $buffer
            $buffer = ''
        }
        if ($buffer -ne '') { $joined += $buffer }
        return $joined
    }
}

Describe 'Bash coverage measurement' {
    It 'excludes the regions the port annotates as non-statements' {
        ($Coverage | Where-Object { $_ -match '--exclude-region=.*kcov-excl-start:kcov-excl-stop' }).Count |
            Should -BeGreaterThan 0
    }

    It 'never drives bats under kcov in any workflow' {
        $offenders = @()
        foreach ($wf in Get-ChildItem -LiteralPath $WorkflowDir -Filter *.yml) {
            $lines = Join-ShellContinuations -Lines (Get-Content -LiteralPath $wf.FullName)
            if ($lines | Where-Object { $_ -match '^[^#]*\bkcov\b[^#]*\bbats\b' }) {
                $offenders += $wf.Name
            }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty
    }

    It 'traces on a dedicated fd, never fd 1, 2 or bats own 3' {
        $match = $Coverage | Select-String -Pattern 'BASH_XTRACEFD=(\d+)' | Select-Object -First 1
        $match | Should -Not -BeNullOrEmpty
        $fd = [int] $match.Matches[0].Groups[1].Value
        $fd | Should -BeGreaterThan 3
        # `exec` cannot take a variable descriptor, so the same number is
        # spelled out where the fd is opened; a mismatch traces into nothing.
        ($Coverage | Where-Object { $_ -match "exec $fd> " }).Count | Should -BeGreaterThan 0
    }

    It 'keeps the trace marker nounset-safe' {
        $ps4 = @($Coverage | Where-Object { $_ -match 'PS4=' })[0]
        $ps4 | Should -Not -BeNullOrEmpty
        $ps4 | Should -BeLike '*${BASH_SOURCE:-}*'
    }

    It 'bounds the bats phase with its own wall clock' {
        ($Coverage | Where-Object { $_ -match 'run_bounded "\$\{BATS_TIMEOUT\}"' }).Count |
            Should -BeGreaterThan 0
    }

    It 'lets the bats wall clock be overridden' {
        ($Coverage | Where-Object { $_ -match 'SPEC_KIT_JIRA_COVERAGE_BATS_TIMEOUT' }).Count |
            Should -BeGreaterThan 0
    }

    It 'reads the per-line record kcov writes, not the per-file summary' {
        # coverage.json carries only per-file totals; merging a second hit set
        # needs cobertura.xml's <line number= hits=> records.
        ($Coverage | Where-Object { $_ -match 'cobertura\.xml' }).Count | Should -BeGreaterThan 0
    }
}
