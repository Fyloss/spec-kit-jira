# T021a [Phase 4, US2] — mirror of tests/bash/conformance/test_us021a_state_fail_open_remaining.bats.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Conf = Join-Path $script:Root 'tests/conformance'
    $script:Harness = Join-Path $script:Conf 'run-scenario.sh'
    $script:StateRel = '.specify/jira/state/001-billing-invoices.json'

    function Get-HarnessDiagnostics {
        param([Parameter(Mandatory)] [string] $OutDir, [string] $Suffix = '.2')
        $names = @("exit${Suffix}", "stderr${Suffix}", "calls.log${Suffix}")
        $parts = foreach ($name in $names) {
            $p = Join-Path $OutDir $name
            $body = if (Test-Path -LiteralPath $p) {
                Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            } else { '<file absent>' }
            "--- ${name} ---`n$body"
        }
        return ($parts) -join "`n"
    }
}

Describe 'Run-state remaining fail-open rows (conformance)' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'T021a — tasks.md appearing invalidates the recorded state' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us021-state-tasks-appeared.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.2')).Length | Should -BeGreaterThan 0 -Because "harness artefacts:`n$diag"
        $statePath = Join-Path $out "workdir/$script:StateRel"
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100
        $state.inputs.PSObject.Properties.Name | Should -Contain 'tasks.md' -Because "harness artefacts:`n$diag"
    }

    It 'T021a — tasks.md disappearing invalidates the recorded state' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us021-state-tasks-deleted.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.2')).Length | Should -BeGreaterThan 0 -Because "harness artefacts:`n$diag"
        $statePath = Join-Path $out "workdir/$script:StateRel"
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100
        $state.inputs.PSObject.Properties.Name | Should -Not -Contain 'tasks.md' -Because "harness artefacts:`n$diag"
    }

    It 'T021a — the first run of all records fresh state' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us021-state-first-run.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out -Suffix ''
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        (Get-Item -LiteralPath (Join-Path $out 'calls.log')).Length | Should -BeGreaterThan 0 -Because "harness artefacts:`n$diag"
        $statePath = Join-Path $out "workdir/$script:StateRel"
        Test-Path -LiteralPath $statePath | Should -BeTrue -Because "harness artefacts:`n$diag"
        { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100 } | Should -Not -Throw -Because "harness artefacts:`n$diag"
    }

    It 'T021a — --on-drift=abort and --on-drift=proceed do not share a state' {
        $out = Join-Path $script:Tmp 'out'
        $scenario = Join-Path $script:Conf 'scenarios/us021-state-ondrift-changed.json'
        & bash $script:Harness $scenario 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit.2') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        (Get-Item -LiteralPath (Join-Path $out 'calls.log.2')).Length | Should -BeGreaterThan 0 -Because "harness artefacts:`n$diag"
        $statePath = Join-Path $out "workdir/$script:StateRel"
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100
        $state.on_drift | Should -Be 'proceed' -Because "harness artefacts:`n$diag"
    }
}
