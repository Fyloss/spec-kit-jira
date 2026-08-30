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

    It '034 — a retired disable record is REFUSED, with zero requests and the state file untouched' {
        # Twin of the bats test of the same name. This used to assert the
        # opposite: that an event recorded as disabled produced exit 0 with no
        # output. 034 retired the record — `hooks.disabled` left
        # config.local.yml's accepted key set — so the same fixture now falls to
        # the schema's pre-existing unknown-key refusal.
        #
        # The placement claim still holds and still matters: the refusal happens
        # BEFORE the state phase. Zero requests, and the recorded state document
        # is byte-identical afterwards.
        $out = Join-Path $script:Tmp 'out'
        $stateRel = '.specify/jira/state/001-billing-invoices.json'
        $fixture = Join-Path $script:Conf "fixtures/repo-with-disabled-event/$stateRel"
        $scenario = Join-Path $script:Conf 'scenarios/us021b-retired-disable-record.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '4'
        (Get-Item -LiteralPath (Join-Path $out 'calls.log')).Length | Should -Be 0
        # The refusal names the key and the file (FR-005, SC-004).
        $err = Get-Content -LiteralPath (Join-Path $out 'stderr') -Raw
        $err | Should -Match 'hooks'
        $err | Should -Match ([regex]::Escape('config.local.yml'))
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
