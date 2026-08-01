# T039/T040/T041 [Phase 4, US1] — mirror of tests/bash/conformance/test_us1_hierarchy.bats.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Conf = Join-Path $script:Root 'tests/conformance'
    $script:Harness = Join-Path $script:Conf 'run-scenario.sh'

    # Every assertion below carries this as its -Because text. A bare exit-code
    # or JSON-parse mismatch is unactionable on a host the author cannot run:
    # these cases failed on windows-latest with nothing in the log but the test
    # name, while Linux and macOS stayed green, and the annotation GitHub
    # produces carries no assertion body. Reporting each captured artefact,
    # labelled, is what makes a CI-only failure diagnosable — the same reason
    # Us1.UnicodeBinding.Tests.ps1 already does it.
    #
    # The workdir listing is deliberate: these three scenarios are exactly the
    # ones whose fixture ships a .specify/jira/config.local.yml, so whether that
    # file reached the run's workdir is the first thing worth knowing.
    function Get-HarnessDiagnostics {
        param([Parameter(Mandatory)] [string] $OutDir)
        $parts = foreach ($name in @('exit', 'stderr', 'stdout', 'argv.1', 'entry.1')) {
            $p = Join-Path $OutDir $name
            $body = if (Test-Path -LiteralPath $p) {
                Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            } else { '<file absent>' }
            "--- ${name} ---`n$body"
        }
        $workdir = Join-Path $OutDir 'workdir'
        $tree = if (Test-Path -LiteralPath $workdir) {
            # -Force or the listing omits every dotted entry — which is the whole
            # of .specify/, i.e. exactly the files worth reporting.
            (Get-ChildItem -LiteralPath $workdir -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($workdir.Length).TrimStart('\', '/') } |
                Sort-Object) -join "`n"
        } else { '<workdir absent>' }
        return (@($parts) + @("--- workdir tree ---`n$tree")) -join "`n"
    }
}

Describe 'Hierarchy resolution (conformance)' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'T039 — French project: children carry the resolved child type id' {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness (Join-Path $script:Conf 'scenarios/us1-hierarchy-french.json') 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        $stdout = Get-Content -LiteralPath (Join-Path $out 'stdout') -Raw | ConvertFrom-Json -Depth 100
        # Every STORY action carries the child type; the one parent action
        # (Phase 5, US2) legitimately carries the PARENT type instead.
        (@($stdout.actions) | Where-Object { $_.role -eq 'story' } | ForEach-Object { $_.body.fields.issuetype.id } | Select-Object -Unique) -join ',' | Should -Be '10302' -Because "harness artefacts:`n$diag"
    }

    It 'T039 — SAFe project: children carry the resolved child type id' {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness (Join-Path $script:Conf 'scenarios/us1-hierarchy-safe.json') 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        $stdout = Get-Content -LiteralPath (Join-Path $out 'stdout') -Raw | ConvertFrom-Json -Depth 100
        (@($stdout.actions) | Where-Object { $_.role -eq 'story' } | ForEach-Object { $_.body.fields.issuetype.id } | Select-Object -Unique) -join ',' | Should -Be '10403' -Because "harness artefacts:`n$diag"
    }

    It 'T040 — no-parent-level: exit 4, zero writes, candidates named' {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness (Join-Path $script:Conf 'scenarios/us1-hierarchy-no-parent-level.json') 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '4' -Because "harness artefacts:`n$diag"
        $stderr = Get-Content -LiteralPath (Join-Path $out 'stderr') -Raw
        $stderr | Should -Match 'FLAT' -Because "harness artefacts:`n$diag"
        $stderr | Should -Match 'Story' -Because "harness artefacts:`n$diag"
        (Test-Path -LiteralPath (Join-Path $out 'workdir/.specify/jira/config.local.yml')) | Should -Be $false -Because "harness artefacts:`n$diag"
    }

    It 'T040 — parent-level-ambiguous: exit 4, zero writes, every candidate named' {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness (Join-Path $script:Conf 'scenarios/us1-hierarchy-ambiguous.json') 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '4' -Because "harness artefacts:`n$diag"
        $stderr = Get-Content -LiteralPath (Join-Path $out 'stderr') -Raw
        $stderr | Should -Match 'Capability' -Because "harness artefacts:`n$diag"
        $stderr | Should -Match 'Feature' -Because "harness artefacts:`n$diag"
    }

    It "T041 — a pre-feature binding refuses legibly, never as 'not bound yet'" {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness (Join-Path $script:Conf 'scenarios/us1-binding-shape-stale.json') 'powershell' $out | Out-Null
        $diag = Get-HarnessDiagnostics -OutDir $out
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '4' -Because "harness artefacts:`n$diag"
        $stderr = Get-Content -LiteralPath (Join-Path $out 'stderr') -Raw
        $stderr | Should -Match 'predates parent support' -Because "harness artefacts:`n$diag"
        $stderr | Should -Not -Match 'has not been bound yet' -Because "harness artefacts:`n$diag"
        (Get-Item -LiteralPath (Join-Path $out 'calls.log')).Length | Should -Be 0 -Because "harness artefacts:`n$diag"
    }
}
