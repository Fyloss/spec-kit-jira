# T021 [Phase 4, US2] — mirror of tests/bash/conformance/test_us021_state_fail_open.bats.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Conf = Join-Path $script:Root 'tests/conformance'
    $script:Harness = Join-Path $script:Conf 'run-scenario.sh'
    $script:StateRel = '.specify/jira/state/001-billing-invoices.json'

    function Get-HarnessDiagnostics {
        param([Parameter(Mandatory)] [string] $OutDir)
        $parts = foreach ($name in @('exit.2', 'stderr.2', 'calls.log.2')) {
            $p = Join-Path $OutDir $name
            $body = if (Test-Path -LiteralPath $p) {
                Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            } else { '<file absent>' }
            "--- ${name} ---`n$body"
        }
        return ($parts) -join "`n"
    }
}

Describe 'Run-state fail-open (conformance)' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'T021 — a corrupt state document does not survive a full reconcile' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us021-state-corrupt.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.2')).Length | Should -BeGreaterThan 0 -Because "harness artefacts:`n$diag"
        $statePath = Join-Path $out "workdir/$script:StateRel"
        Test-Path -LiteralPath $statePath | Should -BeTrue -Because "harness artefacts:`n$diag"
        { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100 } | Should -Not -Throw -Because "harness artefacts:`n$diag"
    }

    It 'T021 — a stale extension_version does not survive a full reconcile' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us021-state-version-changed.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.2')).Length | Should -BeGreaterThan 0 -Because "harness artefacts:`n$diag"
        $statePath = Join-Path $out "workdir/$script:StateRel"
        Test-Path -LiteralPath $statePath | Should -BeTrue -Because "harness artefacts:`n$diag"
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100
        $state.extension_version | Should -Not -Be '0.0.0-t021-sentinel' -Because "harness artefacts:`n$diag"
    }

    It 'T021 — an edited config.yml does not survive a full reconcile' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us021-state-config-changed.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.2')).Length | Should -BeGreaterThan 0 -Because "harness artefacts:`n$diag"
        $statePath = Join-Path $out "workdir/$script:StateRel"
        Test-Path -LiteralPath $statePath | Should -BeTrue -Because "harness artefacts:`n$diag"
        { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100 } | Should -Not -Throw -Because "harness artefacts:`n$diag"
    }
}
