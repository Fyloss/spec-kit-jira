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
        (Get-Content -LiteralPath (Join-Path $outDir 'exit') -Raw).Trim() | Should -Be '0'

        $localf = Join-Path $outDir 'workdir/.specify/jira/config.local.yml'
        $localj = ConvertFrom-JiraConfigYaml -Path $localf | ConvertFrom-Json -Depth 100

        $localj.resolved_ids.JET.issue_types.'Récit' | Should -Be '10004'
        $localj.resolved_ids.JET.issue_types.Story | Should -Be '10005'
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

    It 'is byte-identical across ports (FR-014, SC-005)' {
        $outBash = Join-Path $script:Tmp 'out-bash'
        $outPs = Join-Path $script:Tmp 'out-ps'
        & bash $script:Harness $script:Scenario 'bash' $outBash | Out-Null
        & bash $script:Harness $script:Scenario 'powershell' $outPs | Out-Null

        (Get-Content -LiteralPath (Join-Path $outBash 'exit') -Raw) | Should -Be (Get-Content -LiteralPath (Join-Path $outPs 'exit') -Raw)

        $bashLocal = Get-Content -LiteralPath (Join-Path $outBash 'workdir/.specify/jira/config.local.yml') -Raw
        $psLocal = Get-Content -LiteralPath (Join-Path $outPs 'workdir/.specify/jira/config.local.yml') -Raw
        $bashLocal | Should -Be $psLocal
    }
}
