# T023 [Phase 4, US2] — mirror of tests/bash/conformance/test_us023_no_state_on_non_success.bats.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Conf = Join-Path $script:Root 'tests/conformance'
    $script:Harness = Join-Path $script:Conf 'run-scenario.sh'
}

Describe 'contracts/run-state.md §4/§9 — no state on warning, pending confirmation, or failure (conformance)' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'T023 — a run that ends with a warning records no state' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/sc008-task-tier-boundary.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '0'
        $summary = Get-Content -LiteralPath (Join-Path $out 'stdout') -Raw | ConvertFrom-Json
        [int]$summary.counts.warnings | Should -BeGreaterThan 0
        Test-Path -LiteralPath (Join-Path $out 'workdir/.specify/jira/state/001-feature.json') | Should -Be $false
    }

    It 'T023 — a run that ends in a pending confirmation records no state' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us2-field-defaults-question.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0'
        $summary = Get-Content -LiteralPath (Join-Path $out 'stdout.2') -Raw | ConvertFrom-Json
        $summary.status | Should -Be 'confirmation-pending'
        Test-Path -LiteralPath (Join-Path $out 'workdir/.specify/jira/state/001-reporting.json') | Should -Be $false
    }

    It 'T023 — a failed run records no state' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us6-fail-closed.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Not -Be '0'
        Test-Path -LiteralPath (Join-Path $out 'workdir/.specify/jira/state/001-feature.json') | Should -Be $false
    }
}
