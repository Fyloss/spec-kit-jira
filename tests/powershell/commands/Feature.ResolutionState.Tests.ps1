# 031, T006 — Pester twin of tests/bash/commands/test_feature.bats' T005:
# the seven resolution-state identifiers (data-model.md §1) are exhaustive
# and mutually exclusive.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $script:FeaturePath = Join-Path $Root 'scripts/powershell/commands/Feature.psm1'
    $script:ConfigPath = Join-Path $Root 'scripts/powershell/lib/Config.psm1'
}

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
}
