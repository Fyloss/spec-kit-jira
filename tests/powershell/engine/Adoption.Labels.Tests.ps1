# T030 [US1] — Adoption label grammar, PowerShell side. Mirror of
# tests/bash/engine/test_adoption_labels.bats (003 research §3, data-model §3).
# Cross-port byte agreement is proven by the conformance corpus; here the port's
# behaviour is asserted directly.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Adoption.psm1') -Force
    $script:Prefix = 'speckit-adopt:'
    $script:Cfg = '{"routing_default":"ADO"}'
}

Describe 'Get-JiraAdoptionLabel' {
    It 'derives the full-folder form for a feature target' {
        Get-JiraAdoptionLabel -Prefix $Prefix -Folder '003-label-based-adoption' -Level 'feature' |
            Should -Be '["speckit-adopt:003-label-based-adoption"]'
    }

    It 'derives the story form anchored on the ordinal' {
        Get-JiraAdoptionLabel -Prefix $Prefix -Folder '003-label-based-adoption' -Level 'story' -Ordinal '2' |
            Should -Be '["speckit-adopt:003-label-based-adoption:us2"]'
    }

    It 'adds the short form to a feature target when the number is unique' {
        $labels = Get-JiraAdoptionLabel -Prefix $Prefix -Folder '003-a' -Level 'feature' -ShortNumber '003' | ConvertFrom-Json
        @($labels).Count | Should -Be 2
        @($labels) | Should -Contain 'speckit-adopt:003'
    }

    It 'never carries the short form on a story target' {
        Get-JiraAdoptionLabel -Prefix $Prefix -Folder '003-a' -Level 'story' -Ordinal '1' -ShortNumber '003' |
            Should -Be '["speckit-adopt:003-a:us1"]'
    }

    It 'never derives the bare prefix' {
        (Get-JiraAdoptionLabel -Prefix $Prefix -Folder '003-a' -Level 'feature') | Should -Not -Be '["speckit-adopt:"]'
    }
}

Describe 'Get-JiraAdoptionNumberComponent' {
    It 'reads the leading digits before the first hyphen' {
        Get-JiraAdoptionNumberComponent -Folder '003-label-based-adoption' | Should -Be '003'
        Get-JiraAdoptionNumberComponent -Folder '0042-many-digits' | Should -Be '0042'
    }
    It 'is empty for a folder that does not begin with digits' {
        Get-JiraAdoptionNumberComponent -Folder 'billing-export' | Should -Be ''
        Get-JiraAdoptionNumberComponent -Folder '003' | Should -Be ''
    }
}

Describe 'Short-form suppression (data-model §3)' {
    It 'emits the short form when exactly one folder in scope carries the number' {
        $specs = '[{"folder":"003-alpha","story_ordinals":[]},{"folder":"004-beta","story_ordinals":[]}]'
        $t = (Get-JiraAdoptionTarget -SpecsJson $specs -Prefix $Prefix -ConfigJson $Cfg).Json | ConvertFrom-Json
        $alpha = @($t | Where-Object { $_.spec_folder -eq '003-alpha' })[0]
        @($alpha.labels) | Should -Contain 'speckit-adopt:003'
        $alpha.short_conflict | Should -BeNullOrEmpty
    }

    It 'suppresses the short form for BOTH folders sharing a number, and probes it instead' {
        $specs = '[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
        $t = (Get-JiraAdoptionTarget -SpecsJson $specs -Prefix $Prefix -ConfigJson $Cfg).Json | ConvertFrom-Json
        foreach ($f in @('004-beta', '004-gamma')) {
            $entry = @($t | Where-Object { $_.spec_folder -eq $f })[0]
            @($entry.labels) | Should -Not -Contain 'speckit-adopt:004'
            @($entry.probe_labels)[0] | Should -Be 'speckit-adopt:004'
            (@($entry.short_conflict.folders) -join ',') | Should -Be '004-beta,004-gamma'
        }
    }
}

Describe 'Test-JiraAdoptionPrefix (FR-002)' {
    It 'refuses an empty prefix with exit 4' {
        $r = Test-JiraAdoptionPrefix -Prefix '' -LongestSuffix 40
        $r.ExitCode | Should -Be 4
        $r.Message | Should -BeLike '*empty*'
    }
    It 'refuses a whitespace-bearing prefix with exit 4' {
        (Test-JiraAdoptionPrefix -Prefix 'speckit adopt:' -LongestSuffix 40).ExitCode | Should -Be 4
        (Test-JiraAdoptionPrefix -Prefix "speckit-adopt:`t" -LongestSuffix 40).ExitCode | Should -Be 4
    }
    It 'refuses a prefix whose longest implied label exceeds the limit' {
        $long = 'a' * 240
        $r = Test-JiraAdoptionPrefix -Prefix $long -LongestSuffix 20
        $r.ExitCode | Should -Be 4
        $r.Message | Should -BeLike '*255*'
        (Test-JiraAdoptionPrefix -Prefix $long -LongestSuffix 15).ExitCode | Should -Be 0
    }
    It 'accepts a valid prefix silently' {
        $r = Test-JiraAdoptionPrefix -Prefix $Prefix -LongestSuffix 40
        $r.ExitCode | Should -Be 0
        $r.Message | Should -Be ''
    }
}

Describe 'Get-JiraAdoptionLongestSuffix' {
    It 'accounts for the story form, not just the folder' {
        Get-JiraAdoptionLongestSuffix -SpecsJson '[{"folder":"003-alpha","story_ordinals":[1,12]},{"folder":"0004-b","story_ordinals":[]}]' |
            Should -Be 14
    }
    It 'is 0 for an empty scope' {
        Get-JiraAdoptionLongestSuffix -SpecsJson '[]' | Should -Be 0
    }
}
