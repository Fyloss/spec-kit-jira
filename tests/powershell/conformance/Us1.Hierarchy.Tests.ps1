# T039/T040/T041 [Phase 4, US1] — mirror of tests/bash/conformance/test_us1_hierarchy.bats.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Conf = Join-Path $script:Root 'tests/conformance'
    $script:Harness = Join-Path $script:Conf 'run-scenario.sh'
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
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '0'
        $stdout = Get-Content -LiteralPath (Join-Path $out 'stdout') -Raw | ConvertFrom-Json -Depth 100
        # Every STORY action carries the child type; the one parent action
        # (Phase 5, US2) legitimately carries the PARENT type instead.
        (@($stdout.actions) | Where-Object { $_.role -eq 'story' } | ForEach-Object { $_.body.fields.issuetype.id } | Select-Object -Unique) -join ',' | Should -Be '10302'
    }

    It 'T039 — SAFe project: children carry the resolved child type id' {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness (Join-Path $script:Conf 'scenarios/us1-hierarchy-safe.json') 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '0'
        $stdout = Get-Content -LiteralPath (Join-Path $out 'stdout') -Raw | ConvertFrom-Json -Depth 100
        (@($stdout.actions) | Where-Object { $_.role -eq 'story' } | ForEach-Object { $_.body.fields.issuetype.id } | Select-Object -Unique) -join ',' | Should -Be '10403'
    }

    It 'T040 — no-parent-level: exit 4, zero writes, candidates named' {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness (Join-Path $script:Conf 'scenarios/us1-hierarchy-no-parent-level.json') 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '4'
        $stderr = Get-Content -LiteralPath (Join-Path $out 'stderr') -Raw
        $stderr | Should -Match 'FLAT'
        $stderr | Should -Match 'Story'
        (Test-Path -LiteralPath (Join-Path $out 'workdir/.specify/jira/config.local.yml')) | Should -Be $false
    }

    It 'T040 — parent-level-ambiguous: exit 4, zero writes, every candidate named' {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness (Join-Path $script:Conf 'scenarios/us1-hierarchy-ambiguous.json') 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '4'
        $stderr = Get-Content -LiteralPath (Join-Path $out 'stderr') -Raw
        $stderr | Should -Match 'Capability'
        $stderr | Should -Match 'Feature'
    }

    It "T041 — a pre-feature binding refuses legibly, never as 'not bound yet'" {
        $out = Join-Path $script:Tmp 'out'
        & bash $script:Harness (Join-Path $script:Conf 'scenarios/us1-binding-shape-stale.json') 'powershell' $out | Out-Null
        (Get-Content -LiteralPath (Join-Path $out 'exit') -Raw).Trim() | Should -Be '4'
        $stderr = Get-Content -LiteralPath (Join-Path $out 'stderr') -Raw
        $stderr | Should -Match 'predates parent support'
        $stderr | Should -Not -Match 'has not been bound yet'
        (Get-Item -LiteralPath (Join-Path $out 'calls.log')).Length | Should -Be 0
    }
}
