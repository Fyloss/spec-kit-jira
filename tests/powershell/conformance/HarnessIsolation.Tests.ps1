# Pester twin of tests/bash/conformance/test_harness_isolation.bats.
#
# The conformance harness is hermetic: a scenario's outcome is decided by the
# scenario, never by whatever SPEC_KIT_JIRA_* / JIRA_* variables the caller
# happened to be holding when it invoked the harness.
#
# Regression. tests/powershell/lib/TokenLeak.Tests.ps1 exports
# SPEC_KIT_JIRA_PROJECT_KEY=PROJ (the shipped placeholder) in a BeforeEach and
# never clears it. Pester discovers lib/ immediately before conformance/ on the
# Linux CI host — but after commands/, whose Reconcile.* files scrub that same
# variable, on the author's macOS host. Every reconcile scenario therefore
# refused with the placeholder-key message (exit 4, zero writes) instead of
# mirroring: four red conformance tests in CI, green locally, and nothing in
# either log naming the cause. This file is the Pester side of the guard —
# it drives the PowerShell port, which is the one that went red.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:Conf = Join-Path $script:Root 'tests/conformance'
    $script:Harness = Join-Path $script:Conf 'run-scenario.sh'

    # Same reporting discipline as Us1.Hierarchy.Tests.ps1: a bare exit-code
    # mismatch is unactionable on a host the author cannot run.
    function Get-HarnessDiagnostics {
        param([Parameter(Mandatory)] [string] $OutDir)
        $parts = foreach ($name in @('exit', 'stderr', 'stdout')) {
            $p = Join-Path $OutDir $name
            $body = if (Test-Path -LiteralPath $p) {
                Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            } else { '<file absent>' }
            "--- ${name} ---`n$body"
        }
        return $parts -join "`n"
    }

    function Invoke-Scenario {
        param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $OutDir)
        & bash $script:Harness (Join-Path $script:Conf "scenarios/$Name.json") 'powershell' $OutDir | Out-Null
    }

    # Set a variable for the duration of one test and put the environment back
    # exactly as it was — this file must not become the next leak it guards.
    function Use-AmbientVariable {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [Parameter(Mandatory)] [string] $Value,
            [Parameter(Mandatory)] [scriptblock] $Body
        )
        $had = Test-Path -LiteralPath "Env:\$Name"
        $prior = if ($had) { (Get-Item -LiteralPath "Env:\$Name").Value } else { $null }
        Set-Item -LiteralPath "Env:\$Name" -Value $Value
        try { & $Body }
        finally {
            if ($had) { Set-Item -LiteralPath "Env:\$Name" -Value $prior }
            else { Remove-Item -LiteralPath "Env:\$Name" -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'The conformance harness is hermetic' {
    BeforeEach {
        $script:Tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid()))
        $script:Out = Join-Path $script:Tmp 'out'
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -Recurse -Force -LiteralPath $script:Tmp }
    }

    It 'an ambient SPEC_KIT_JIRA_PROJECT_KEY never reaches the port' {
        # PROJ is the shipped placeholder: if it reaches the port, reconcile
        # refuses with exit 4 before its first Jira call instead of mirroring.
        Use-AmbientVariable -Name 'SPEC_KIT_JIRA_PROJECT_KEY' -Value 'PROJ' -Body {
            Invoke-Scenario -Name 'us1-hierarchy-french' -OutDir $script:Out
        }
        $diag = Get-HarnessDiagnostics -OutDir $script:Out
        (Get-Content -LiteralPath (Join-Path $script:Out 'exit') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        $stdout = Get-Content -LiteralPath (Join-Path $script:Out 'stdout') -Raw | ConvertFrom-Json -Depth 100
        (@($stdout.actions) | Where-Object { $_.role -eq 'story' } | ForEach-Object { $_.body.fields.issuetype.id } | Select-Object -Unique) -join ',' | Should -Be '10302' -Because "harness artefacts:`n$diag"
    }

    It 'an ambient SPEC_KIT_JIRA_PLAN_CONTEXT never rewrites the creation context' {
        # The override is read wholesale (FR-013), so a leaked one silently
        # replaces every id the persisted binding resolved.
        Use-AmbientVariable -Name 'SPEC_KIT_JIRA_PLAN_CONTEXT' -Value '{"story_type_id":"99999"}' -Body {
            Invoke-Scenario -Name 'us1-hierarchy-french' -OutDir $script:Out
        }
        $diag = Get-HarnessDiagnostics -OutDir $script:Out
        (Get-Content -LiteralPath (Join-Path $script:Out 'exit') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
        $stdout = Get-Content -LiteralPath (Join-Path $script:Out 'stdout') -Raw | ConvertFrom-Json -Depth 100
        (@($stdout.actions) | Where-Object { $_.role -eq 'story' } | ForEach-Object { $_.body.fields.issuetype.id } | Select-Object -Unique) -join ',' | Should -Be '10302' -Because "harness artefacts:`n$diag"
    }

    It 'an ambient SPEC_KIT_JIRA_HOOK_CONTEXT never downgrades a refusal' {
        # Under a hook every refusal becomes one WARNING and exit 0 — which
        # would turn the stale-binding scenario's exit 4 into a pass that
        # proves nothing.
        Use-AmbientVariable -Name 'SPEC_KIT_JIRA_HOOK_CONTEXT' -Value 'after_specify' -Body {
            Invoke-Scenario -Name 'us1-binding-shape-stale' -OutDir $script:Out
        }
        $diag = Get-HarnessDiagnostics -OutDir $script:Out
        (Get-Content -LiteralPath (Join-Path $script:Out 'exit') -Raw).Trim() | Should -Be '4' -Because "harness artefacts:`n$diag"
        Get-Content -LiteralPath (Join-Path $script:Out 'stderr') -Raw | Should -Match 'predates parent support' -Because "harness artefacts:`n$diag"
    }

    It 'SPEC_KIT_JIRA_HARNESS_ENV is the one channel that still reaches the port' {
        # The scrub has to leave a deliberate override a way through, or every
        # test that varies one variable across two runs of one scenario needs a
        # second scenario file.
        Use-AmbientVariable -Name 'SPEC_KIT_JIRA_HARNESS_ENV' -Value 'SPEC_KIT_JIRA_PROJECT_KEY=PROJ' -Body {
            Invoke-Scenario -Name 'us1-hierarchy-french' -OutDir $script:Out
        }
        $diag = Get-HarnessDiagnostics -OutDir $script:Out
        (Get-Content -LiteralPath (Join-Path $script:Out 'exit') -Raw).Trim() | Should -Be '4' -Because "harness artefacts:`n$diag"
        Get-Content -LiteralPath (Join-Path $script:Out 'stderr') -Raw | Should -Match 'shipped placeholder' -Because "harness artefacts:`n$diag"
    }

    It 'an ambient JIRA_CONFIG_DIR never redirects the port away from the workdir' {
        $elsewhere = Join-Path $script:Tmp 'elsewhere'
        New-Item -ItemType Directory -Path $elsewhere | Out-Null
        Use-AmbientVariable -Name 'JIRA_CONFIG_DIR' -Value $elsewhere -Body {
            Invoke-Scenario -Name 'us1-hierarchy-french' -OutDir $script:Out
        }
        $diag = Get-HarnessDiagnostics -OutDir $script:Out
        (Get-Content -LiteralPath (Join-Path $script:Out 'exit') -Raw).Trim() | Should -Be '0' -Because "harness artefacts:`n$diag"
    }
}
