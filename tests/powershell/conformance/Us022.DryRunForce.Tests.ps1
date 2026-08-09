# T022 [Phase 4, US2] — mirror of tests/bash/conformance/test_us022_dry_run_force.bats.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Conf = Join-Path $script:Root 'tests/conformance'
    $script:Harness = Join-Path $script:Conf 'run-scenario.sh'
}

Describe 'contracts/run-state.md §3/S6 — --dry-run and --force (conformance)' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'T022 — dry-run never short-circuits, even on a matching state the prior run just recorded' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us022-dry-run-full-preview.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0'
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.2')).Length | Should -BeGreaterThan 0
        $summary = Get-Content -LiteralPath (Join-Path $out 'stdout.2') -Raw | ConvertFrom-Json
        [bool]($summary.short_circuited) | Should -Be $false
    }

    It 'T022 — dry-run on a spec with no recorded state writes no state document' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us022-dry-run-no-write.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '0'
        Test-Path -LiteralPath (Join-Path $out 'workdir/.specify/jira/state/001-billing-invoices.json') | Should -Be $false
    }

    It 'T022 — force bypasses the read on both runs and records state after each success' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us022-force-bypasses-and-records.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit.1') -Raw).Trim() | Should -Be '0'
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0'
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.1')).Length | Should -BeGreaterThan 0
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.2')).Length | Should -BeGreaterThan 0
        $statePath = Join-Path $out 'workdir/.specify/jira/state/001-billing-invoices.json'
        Test-Path -LiteralPath $statePath | Should -Be $true
        { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}
