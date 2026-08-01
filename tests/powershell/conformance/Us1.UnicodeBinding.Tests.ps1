# T036 [US3] — Conformance: a shared defect neither port can hide behind the
# other (SC-005, research R6, R7 case 12). Pester mirror of
# tests/bash/conformance/test_us1_unicode_binding.bats.
#
# Drives the us1-unicode-binding scenario through the real dispatcher on both
# ports via the shared Bash harness (the harness itself has no PowerShell
# twin — it is language-agnostic tooling, not a port). Asserted against the
# fixture's EXPECTED CONTENT, not only port-against-port.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Harness = Join-Path $script:Root 'tests/conformance/run-scenario.sh'
    $script:Scenario = Join-Path $script:Root 'tests/conformance/scenarios/us1-unicode-binding.json'
    Import-Module (Join-Path $script:Root 'scripts/powershell/lib/Config.psm1') -Force
}

Describe 'The unicode binding survives an unrelated config run (conformance)' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'the unicode binding''s every key with every expected id survives (powershell)' {
        $outDir = Join-Path $script:Tmp 'out-ps'
        & bash $script:Harness $script:Scenario 'powershell' $outDir | Out-Null
        # A bare exit-code mismatch here is unactionable on its own, and an empty
        # stderr says only that the run failed WITHOUT complaining — which is its
        # own distinct cause. Report every artefact the harness captured, each
        # labelled, so a CI failure names what actually happened.
        $diag = (@('stderr', 'stdout', 'argv.1', 'entry.1') | ForEach-Object {
            $p = Join-Path $outDir $_
            $body = if (Test-Path -LiteralPath $p) {
                Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            } else { '<file absent>' }
            "--- ${_} ---`n$body"
        }) -join "`n"
        (Get-Content -LiteralPath (Join-Path $outDir 'exit') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"

        $localf = Join-Path $outDir 'workdir/.specify/jira/config.local.yml'
        $localj = ConvertFrom-JiraConfigYaml -Path $localf | ConvertFrom-Json -Depth 100

        # New list shape (008 T014a): issue_types is a list of
        # {logical_name, id, hierarchy_level, subtask}, not a name-to-id map.
        (@($localj.resolved_ids.JET.issue_types) | Where-Object { $_.logical_name -eq 'Récit' }).id | Should -Be '10004'
        (@($localj.resolved_ids.JET.issue_types) | Where-Object { $_.logical_name -eq 'Story' }).id | Should -Be '10005'
        $localj.resolved_ids.JET.child_type.logical_name | Should -Be 'Récit'
        $localj.resolved_ids.JET.parent_type.logical_name | Should -Be 'Chantier'
        $localj.resolved_ids.JET.priorities.Faible | Should -Be '4'
        $localj.resolved_ids.JET.priorities.'Élevée' | Should -Be '1'
        $localj.resolved_ids.JET.priorities.'Приоритет' | Should -Be '2'
        $localj.resolved_ids.JET.priorities.'Größe' | Should -Be '3'
        $localj.resolved_ids.JET.statuses.'Terminé' | Should -Be '10002'
        $localj.resolved_ids.JET.statuses.'Won''t Do' | Should -Be '10004'
        $localj.resolved_ids.JET.statuses.'À faire' | Should -Be '10001'
        $localj.resolved_ids.JET.statuses.'完了' | Should -Be '10003'
        $localj.resolved_ids.JET.statuses.'Done (QA)' | Should -Be '10005'
        $localj.resolved_ids.JET.statuses.'high/low' | Should -Be '6'
        $localj.resolved_ids.JET.style | Should -Be 'company_managed'
    }

    # Skipped on Windows because it is the only test in the PowerShell suite that
    # drives the BASH port, and Windows is the one host where that port is
    # deliberately neither provisioned nor exercised: ci.yml installs the Bash
    # toolchain on Linux and macOS only, and skips bats outright with
    # `if: runner.os != 'Windows'`. Running the Bash half here asserted a support
    # claim the project does not make. The parity guarantee itself is NOT weakened
    # — the conformance job replays this scenario, and the whole corpus, against
    # both ports on Linux.
    It 'is byte-identical across ports (FR-014, SC-005)' -Skip:$IsWindows {
        $outBash = Join-Path $script:Tmp 'out-bash'
        $outPs = Join-Path $script:Tmp 'out-ps'
        & bash $script:Harness $script:Scenario 'bash' $outBash | Out-Null
        & bash $script:Harness $script:Scenario 'powershell' $outPs | Out-Null

        $bashExit = (Get-Content -LiteralPath (Join-Path $outBash 'exit') -Raw).Trim()
        $psExit = (Get-Content -LiteralPath (Join-Path $outPs 'exit') -Raw).Trim()
        $bashErr = Get-Content -LiteralPath (Join-Path $outBash 'stderr') -Raw -ErrorAction SilentlyContinue
        $psErr = Get-Content -LiteralPath (Join-Path $outPs 'stderr') -Raw -ErrorAction SilentlyContinue
        # Asserted per port before they are compared to each other: two ports that
        # both fail identically would otherwise satisfy an equality check while
        # proving nothing (exactly what masked this scenario's Windows failure).
        $bashExit | Should -Be '0' -Because "bash port stderr:`n$bashErr"
        $psExit | Should -Be '0' -Because "powershell port stderr:`n$psErr"

        $bashLocal = Get-Content -LiteralPath (Join-Path $outBash 'workdir/.specify/jira/config.local.yml') -Raw
        $psLocal = Get-Content -LiteralPath (Join-Path $outPs 'workdir/.specify/jira/config.local.yml') -Raw
        $bashLocal | Should -Be $psLocal
    }
}
