# T032 [US1] / T158 [US6] — Adoption target derivation, PowerShell side. Mirror
# of tests/bash/engine/test_adoption_targets.bats (003 data-model §2, §6).

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Adoption.psm1') -Force
    $script:Prefix = 'speckit-adopt:'
    $script:Cfg = '{"routing":[{"match":{"folder_prefix":"005-"},"project":"BILL"}],"routing_default":"ADO"}'
    function Get-Targets([string] $Specs) {
        $r = Get-JiraAdoptionTarget -SpecsJson $Specs -Prefix $script:Prefix -ConfigJson $script:Cfg
        $r.ExitCode | Should -Be 0
        return ($r.Json | ConvertFrom-Json)
    }
}

Describe 'Target shape' {
    It 'yields one feature target plus one story target per user story' {
        $t = Get-Targets '[{"folder":"003-alpha","story_ordinals":[1,2]}]'
        @($t).Count | Should -Be 3
        @($t | Where-Object { $_.level -eq 'feature' }).Count | Should -Be 1
        @($t | Where-Object { $_.level -eq 'story' }).Count | Should -Be 2
    }

    It 'sets story_ordinal non-null exactly when the level is story' {
        $t = Get-Targets '[{"folder":"003-alpha","story_ordinals":[1]}]'
        (@($t | Where-Object { $_.level -eq 'feature' })[0]).story_ordinal | Should -BeNullOrEmpty
        (@($t | Where-Object { $_.level -eq 'story' })[0]).story_ordinal | Should -Be 1
    }

    It 'yields the feature target alone for a spec with no user story' {
        $t = Get-Targets '[{"folder":"003-alpha","story_ordinals":[]}]'
        @($t).Count | Should -Be 1
        @($t)[0].level | Should -Be 'feature'
    }
}

Describe 'Routing (FR-004)' {
    It 'resolves project_key through the existing routing resolver' {
        $t = Get-Targets '[{"folder":"003-alpha","story_ordinals":[]},{"folder":"005-delta","story_ordinals":[1]}]'
        (@($t | Where-Object { $_.spec_folder -eq '003-alpha' })[0]).project_key | Should -Be 'ADO'
        (@($t | Where-Object { $_.spec_folder -eq '005-delta' } | ForEach-Object { $_.project_key }) | Select-Object -Unique) | Should -Be 'BILL'
    }

    It 'propagates the routing resolver configuration error for an unroutable folder' {
        $r = Get-JiraAdoptionTarget -SpecsJson '[{"folder":"999-orphan","story_ordinals":[]}]' `
            -Prefix $Prefix -ConfigJson '{"routing":[{"match":{"folder_prefix":"x-"},"project":"X"}]}'
        $r.ExitCode | Should -Be 4
    }
}

Describe 'Ordering (data-model §2)' {
    It 'orders folder ascending, feature before story, ordinal ascending' {
        $t = Get-Targets '[{"folder":"005-delta","story_ordinals":[2,1]},{"folder":"003-alpha","story_ordinals":[1]}]'
        $actual = @($t | ForEach-Object {
                $o = if ($null -eq $_.story_ordinal) { '' } else { [string][int]$_.story_ordinal }
                "$($_.spec_folder)/$($_.level)/$o"
            }) -join "`n"
        $actual | Should -Be @'
003-alpha/feature/
003-alpha/story/1
005-delta/feature/
005-delta/story/1
005-delta/story/2
'@.Replace("`r`n", "`n").TrimEnd("`n")
    }

    It 'is deterministic — the same input yields the same bytes' {
        $specs = '[{"folder":"005-delta","story_ordinals":[2,1]},{"folder":"003-alpha","story_ordinals":[1]}]'
        (Get-JiraAdoptionTarget -SpecsJson $specs -Prefix $Prefix -ConfigJson $Cfg).Json |
            Should -Be (Get-JiraAdoptionTarget -SpecsJson $specs -Prefix $Prefix -ConfigJson $Cfg).Json
    }
}

Describe 'Labels carried on the target' {
    It 'carries the exact labels the target implies and nothing else' {
        $t = Get-Targets '[{"folder":"003-alpha","story_ordinals":[1]}]'
        ((@($t | Where-Object { $_.level -eq 'feature' })[0]).labels | Sort-Object) -join ',' |
            Should -Be 'speckit-adopt:003,speckit-adopt:003-alpha'
        (@($t | Where-Object { $_.level -eq 'story' })[0]).labels -join ',' | Should -Be 'speckit-adopt:003-alpha:us1'
    }

    It 'derives no label for a folder outside the given scope (FR-026)' {
        $r = (Get-JiraAdoptionTarget -SpecsJson '[{"folder":"003-alpha","story_ordinals":[]}]' -Prefix $Prefix -ConfigJson $Cfg).Json
        $r | Should -Not -BeLike '*004-beta*'
        $r | Should -Not -BeLike '*005-delta*'
    }

    It 'evaluates the short-number uniqueness test over the folders IN SCOPE (T158)' {
        $one = Get-Targets '[{"folder":"004-beta","story_ordinals":[]}]'
        @(@($one)[0].labels) | Should -Contain 'speckit-adopt:004'
        @($one)[0].short_conflict | Should -BeNullOrEmpty

        $both = Get-Targets '[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
        @(@($both)[0].labels) | Should -Not -Contain 'speckit-adopt:004'
        @($both)[0].short_conflict.label | Should -Be 'speckit-adopt:004'
    }
}

Describe 'Get-JiraAdoptionScope (FR-026)' {
    It 'keeps every folder in scope when the scope is absent' {
        $r = Get-JiraAdoptionScope -AllFoldersJson '["003-alpha","001-zeta"]' -ScopeJson '[]'
        $r.ExitCode | Should -Be 0
        $o = $r.Json | ConvertFrom-Json
        (@($o.in_scope) -join ',') | Should -Be '001-zeta,003-alpha'
        @($o.out_of_scope).Count | Should -Be 0
    }

    It 'splits the folders and sorts both lists ascending' {
        $r = Get-JiraAdoptionScope -AllFoldersJson '["003-alpha","001-zeta","005-delta"]' -ScopeJson '["005-delta","003-alpha"]'
        $o = $r.Json | ConvertFrom-Json
        (@($o.in_scope) -join ',') | Should -Be '003-alpha,005-delta'
        (@($o.out_of_scope) -join ',') | Should -Be '001-zeta'
    }

    It 'treats a scope naming a folder absent from disk as a usage error (exit 1)' {
        $r = Get-JiraAdoptionScope -AllFoldersJson '["003-alpha"]' -ScopeJson '["009-nope"]'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -BeLike '*009-nope*'
    }
}
