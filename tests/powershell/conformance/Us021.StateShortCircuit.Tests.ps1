# T020 [Phase 4, US2] — mirror of tests/bash/conformance/test_us021_state_short_circuit.bats.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Conf = Join-Path $script:Root 'tests/conformance'
    $script:Harness = Join-Path $script:Conf 'run-scenario.sh'
    $script:Scenario = Join-Path $script:Conf 'scenarios/us021-state-unchanged.json'

    # Same rationale as Us1.Hierarchy.Tests.ps1: a bare mismatch is
    # unactionable on a host the author cannot run, so every assertion below
    # carries the harness's own captured artefacts as its -Because text.
    function Get-HarnessDiagnostics {
        param([Parameter(Mandatory)] [string] $OutDir)
        $parts = foreach ($name in @('exit.2', 'stderr.2', 'stdout.2', 'calls.log.2', 'calls.log.1')) {
            $p = Join-Path $OutDir $name
            $body = if (Test-Path -LiteralPath $p) {
                Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            } else { '<file absent>' }
            "--- ${name} ---`n$body"
        }
        return ($parts) -join "`n"
    }
}

Describe 'Run-state short-circuit (conformance)' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'T020 — the second run issues zero requests, exits 0, and names the short-circuit' {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness $script:Scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.2')).Length | Should -Be 0 -Because "harness artefacts:`n$diag"
        $stdout = Get-Content -LiteralPath (Join-Path $out 'stdout.2') -Raw | ConvertFrom-Json -Depth 100
        $stdout.short_circuited | Should -Be $true -Because "harness artefacts:`n$diag"
    }

    It 'T032 — the short-circuit summary names the file that recorded it' {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness $script:Scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        $stdout = Get-Content -LiteralPath (Join-Path $out 'stdout.2') -Raw | ConvertFrom-Json -Depth 100
        $stdout.state_file | Should -BeLike '*/state/*.json' -Because "harness artefacts:`n$diag"
    }

    It "T020/T8 — with the timing mode on, the second run's stderr carries only prereq, state, and total" {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness $script:Scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        $lines = Get-Content -LiteralPath (Join-Path $out 'stderr.2') | Where-Object { $_ -like 'timing: *' }
        $lines.Count | Should -Be 3 -Because "harness artefacts:`n$diag"
        $lines[0] | Should -BeLike 'timing: prereq*' -Because "harness artefacts:`n$diag"
        $lines[1] | Should -BeLike 'timing: state*' -Because "harness artefacts:`n$diag"
        $lines[2] | Should -BeLike 'timing: total*' -Because "harness artefacts:`n$diag"
    }
}
