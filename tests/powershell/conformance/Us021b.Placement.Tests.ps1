# T021b [Phase 4, US2] — mirror of tests/bash/conformance/test_us021b_placement.bats.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Conf = Join-Path $script:Root 'tests/conformance'
    $script:Harness = Join-Path $script:Conf 'run-scenario.sh'
}

Describe 'FR-027 placement — dispatch/target guards fire before the state phase (conformance)' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'T021b — a disabled lifecycle event exits 0 silently, with zero requests, state file untouched' {
        $out = Join-Path $script:Tmp 'out'
        $stateRel = '.specify/jira/state/001-billing-invoices.json'
        $fixture = Join-Path $script:Conf "fixtures/repo-with-disabled-event/$stateRel"
        $scenario = Join-Path $script:Conf 'scenarios/us021b-disabled-event.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '0'
        (Get-Item -LiteralPath (Join-Path $out 'calls.log')).Length | Should -Be 0
        (Get-Item -LiteralPath (Join-Path $out 'stdout')).Length | Should -Be 0
        (Get-Item -LiteralPath (Join-Path $out 'stderr')).Length | Should -Be 0
        $expected = Get-Content -LiteralPath $fixture -Raw
        $actual = Get-Content -LiteralPath (Join-Path $out "workdir/$stateRel") -Raw
        $actual | Should -Be $expected
    }

    It 'T021b — a rejected target exits 1 with zero requests, state file untouched' {
        $out = Join-Path $script:Tmp 'out'
        $stateRel = '.specify/jira/state/001-test-page.json'
        $fixture = Join-Path $script:Conf "fixtures/repo-with-plan-artifact/$stateRel"
        $scenario = Join-Path $script:Conf 'scenarios/us021b-rejected-target.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '1'
        (Get-Item -LiteralPath (Join-Path $out 'calls.log')).Length | Should -Be 0
        $expected = Get-Content -LiteralPath $fixture -Raw
        $actual = Get-Content -LiteralPath (Join-Path $out "workdir/$stateRel") -Raw
        $actual | Should -Be $expected
    }
}
