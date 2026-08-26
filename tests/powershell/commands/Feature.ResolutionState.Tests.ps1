# 031, T006 — Pester twin of tests/bash/commands/test_feature.bats' T005:
# the seven resolution-state identifiers (data-model.md §1) are exhaustive
# and mutually exclusive.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $script:FeaturePath = Join-Path $Root 'scripts/powershell/commands/Feature.psm1'
    $script:ConfigPath = Join-Path $Root 'scripts/powershell/lib/Config.psm1'
    $script:VerboseTestsPath = Join-Path $PSScriptRoot 'Feature.Verbose.Tests.ps1'
}

# This Describe block is a STATIC vocabulary check only — it proves the
# seven identifiers exist in source and nowhere else, the same scope the
# bash twin's T005 (tests/bash/commands/test_feature.bats) has. It cannot
# prove any state is actually emitted at runtime, or that two states never
# fire together for one input (code review, PR #55): that behavioral
# exhaustiveness — one real `Invoke-JiraFeature` run per state, asserting
# `resolution state: <x>` on stderr — is Feature.Verbose.Tests.ps1's T033
# block. The second It below is the drift guard between the two: it fails
# if a state is renamed or dropped here without T033 following.
Describe 'Feature command resolution-state vocabulary' {
    It 'names all seven states, and only those seven (data-model.md §1)' {
        $expected = @(
            'config-unloadable', 'no-config-file', 'no-personal-file',
            'no-repository', 'no-team-key', 'no-teams', 'personal-unloadable'
        ) | Sort-Object

        $pattern = "['`"](no-config-file|config-unloadable|no-teams|no-personal-file|no-team-key|personal-unloadable|no-repository)['`"]"
        $found = @()
        foreach ($f in @($FeaturePath, $ConfigPath)) {
            $matches = Select-String -Path $f -Pattern $pattern -AllMatches
            foreach ($m in $matches) {
                foreach ($g in $m.Matches) { $found += $g.Groups[1].Value }
            }
        }
        $actual = $found | Sort-Object -Unique
        Compare-Object $expected $actual | Should -BeNullOrEmpty
    }

    It 'each of the seven states has a T033 runtime assertion in Feature.Verbose.Tests.ps1' {
        $expected = @(
            'config-unloadable', 'no-config-file', 'no-personal-file',
            'no-repository', 'no-team-key', 'no-teams', 'personal-unloadable'
        ) | Sort-Object

        # T033's own assertions read `$r.Err | Should -Match 'resolution state: <x>'`
        # against a captured live run (Invoke-FeatureCaptured) — this is where
        # "does the code actually emit it" is proven, one fixture per state.
        $pattern = "resolution state: (no-config-file|config-unloadable|no-teams|no-personal-file|no-team-key|personal-unloadable|no-repository)"
        $lineMatches = Select-String -Path $VerboseTestsPath -Pattern $pattern -AllMatches
        $found = @()
        foreach ($m in $lineMatches) {
            foreach ($g in $m.Matches) { $found += $g.Groups[1].Value }
        }
        $actual = $found | Sort-Object -Unique
        Compare-Object $expected $actual | Should -BeNullOrEmpty
    }
}
