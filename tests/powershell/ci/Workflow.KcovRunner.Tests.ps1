# Mirror of tests/bash/ci/test_workflow_kcov_runner.bats. kcov was dropped from
# the Ubuntu 24.04 (noble) archive, so any job that apt-installs it on
# `ubuntu-latest` dies with "E: Unable to locate package kcov" before measuring
# anything. Jammy (22.04) still ships it, so every kcov-installing job must pin a
# runner image whose archive carries the package. Building kcov from source is
# exempt: the rule keys on the apt install line only.

BeforeAll {
    $WorkflowDir = Join-Path $PSScriptRoot '../../../.github/workflows'

    # Returns one object per job whose steps apt-install kcov.
    function Get-KcovJob {
        param([string] $Path)

        $jobs = @()
        $inJobs = $false
        $job = $null
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^jobs:') { $inJobs = $true; continue }
            if (-not $inJobs) { continue }
            if ($line -match '^  ([A-Za-z0-9_.-]+): *$') {
                if ($job -and $job.Kcov) { $jobs += $job }
                $job = [pscustomobject]@{
                    File   = Split-Path -Leaf $Path
                    Name   = $Matches[1]
                    RunsOn = '<unset>'
                    Kcov   = $false
                }
                continue
            }
            if ($null -eq $job) { continue }
            if ($line -match '^    runs-on: *(\S+)') { $job.RunsOn = $Matches[1]; continue }
            if ($line -match 'apt-get install' -and $line -match 'kcov') { $job.Kcov = $true }
        }
        if ($job -and $job.Kcov) { $jobs += $job }
        return $jobs
    }

    # -Force: PowerShell marks anything under a dot-prefixed directory as hidden
    # on Unix, so a plain Get-ChildItem over .github/workflows lists nothing.
    $KcovJobs = @(Get-ChildItem -Path $WorkflowDir -Filter '*.yml' -Force |
        ForEach-Object { Get-KcovJob -Path $_.FullName })

    # The step that drives tests/coverage/bash-coverage.sh: its own ceiling and
    # the two wall clocks it hands the runner.
    function Get-CoverageStepBudget {
        param([string] $Path)

        $budget = [pscustomobject]@{ Ceiling = $null; Kcov = $null; Bats = $null }
        $inStep = $false
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -eq '      - name: Measure statement coverage with kcov') { $inStep = $true; continue }
            if (-not $inStep) { continue }
            if ($line -match '^      - name:') { $inStep = $false; continue }
            if ($line -match '^        timeout-minutes: *(\d+)') { $budget.Ceiling = [int]$Matches[1]; continue }
            if ($line -match 'SPEC_KIT_JIRA_COVERAGE_TIMEOUT: *(\d+)') { $budget.Kcov = [int]$Matches[1]; continue }
            if ($line -match 'SPEC_KIT_JIRA_COVERAGE_BATS_TIMEOUT: *(\d+)') { $budget.Bats = [int]$Matches[1]; continue }
        }
        return $budget
    }

    $CoverageBudget = Get-CoverageStepBudget -Path (Join-Path $WorkflowDir 'gates.yml')
}

Describe 'Workflow runner images for kcov' {
    It 'finds the workflow jobs that apt-install kcov' {
        $KcovJobs.Count | Should -BeGreaterThan 0
    }

    It 'pins every kcov-installing job to an image whose archive still ships it' {
        $dropped = $KcovJobs | Where-Object {
            $_.RunsOn -match '^ubuntu-(latest|24\.04|25|26)'
        }
        $detail = ($dropped | ForEach-Object { "$($_.File): job '$($_.Name)' on $($_.RunsOn)" }) -join '; '
        $detail | Should -BeNullOrEmpty
    }

    It "the coverage step's ceiling sits above both of its inner wall clocks" {
        # The runner bounds each phase itself so that an overrun REPORTS: how far
        # the exercise got, the tail of kcov.log, which clock expired. A ceiling
        # below the sum of those clocks makes that impossible — the runner is
        # killed mid-phase and the fallback, seeing no `rescue`, calls it a
        # genuine failure. That inversion (15 minutes of ceiling against 30
        # minutes of inner budget) left this gate red and unreadable from
        # 2026-07-28 on.
        $CoverageBudget.Ceiling | Should -Not -BeNullOrEmpty
        $CoverageBudget.Kcov | Should -Not -BeNullOrEmpty
        $CoverageBudget.Bats | Should -Not -BeNullOrEmpty
        ($CoverageBudget.Ceiling * 60) |
            Should -BeGreaterThan ($CoverageBudget.Kcov + $CoverageBudget.Bats)
    }
}
