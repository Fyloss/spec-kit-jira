# T122 [US4] — Explicit binding resolution, PowerShell side. Mirror of
# tests/bash/engine/test_adoption_pins.bats (003 FR-020, FR-021, FR-022).

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Adoption.psm1') -Force
    Import-Module (Join-Path $EngineDir '../lib/Output.psm1') -Force
    $script:Prefix = 'speckit-adopt:'
    $script:Cfg = '{"routing_default":"ADO"}'
    $script:Repo = 'acme/app'
    $script:All = '["003-alpha","004-beta"]'
    $script:Specs = '[{"folder":"003-alpha","story_ordinals":[1]}]'

    function Get-Plan {
        param([string] $Candidates = '[]', [string] $Pins = '[]', [string] $Specs = $script:Specs)
        $t = Get-JiraAdoptionTarget -SpecsJson $Specs -Prefix $script:Prefix -ConfigJson $script:Cfg
        return (Get-JiraAdoptionPlan -TargetsJson $t.Json -CandidatesJson $Candidates -PinsJson $Pins -Repo $script:Repo | ConvertFrom-Json)
    }
}

Describe 'parsing a pin into a target (data-model §5)' {
    It 'targets the feature level for a bare folder pin' {
        $r = Resolve-JiraAdoptionPin -PinsJson '["003-alpha=ADO-9"]' -AllFoldersJson $All
        $r.ExitCode | Should -Be 0
        $p = @($r.Json | ConvertFrom-Json)[0]
        $p.spec_folder | Should -Be '003-alpha'
        $p.level | Should -Be 'feature'
        $p.story_ordinal | Should -BeNullOrEmpty
        $p.issue_key | Should -Be 'ADO-9'
    }

    It 'targets the story for a :usN pin' {
        $p = @((Resolve-JiraAdoptionPin -PinsJson '["003-alpha:us2=ADO-9"]' -AllFoldersJson $All).Json | ConvertFrom-Json)[0]
        $p.level | Should -Be 'story'
        $p.story_ordinal | Should -Be 2
    }

    It 'is repeatable and keeps the given order' {
        $r = Resolve-JiraAdoptionPin -PinsJson '["003-alpha=ADO-1","004-beta:us1=ADO-2"]' -AllFoldersJson $All
        (@($r.Json | ConvertFrom-Json | ForEach-Object { $_.issue_key }) -join ',') | Should -Be 'ADO-1,ADO-2'
    }

    It 'resolves an empty pin list to an empty array' {
        (Resolve-JiraAdoptionPin -PinsJson '[]' -AllFoldersJson $All).Json | Should -Be '[]'
    }
}

Describe 'the folder must exist on disk (FR-021)' {
    It 'treats a pin naming an absent folder as a usage error (exit 1)' {
        $r = Resolve-JiraAdoptionPin -PinsJson '["009-nope=ADO-1"]' -AllFoldersJson $All
        $r.ExitCode | Should -Be 1
        $r.Message | Should -BeLike '*009-nope*'
    }

    It 'refuses a story pin on the FOLDER, not the ordinal' {
        $r = Resolve-JiraAdoptionPin -PinsJson '["009-nope:us1=ADO-1"]' -AllFoldersJson $All
        $r.ExitCode | Should -Be 1
        $r.Message | Should -BeLike '*009-nope*'
        $r.Message | Should -Not -BeLike '*us1*'
    }

    It 'stops the whole run on one bad pin among good ones' {
        (Resolve-JiraAdoptionPin -PinsJson '["003-alpha=ADO-1","009-nope=ADO-2"]' -AllFoldersJson $All).ExitCode | Should -Be 1
    }

    It 'treats a malformed pin value as a usage error' {
        $r = Resolve-JiraAdoptionPin -PinsJson '["003-alpha-no-equals"]' -AllFoldersJson $All
        $r.ExitCode | Should -Be 1
        $r.Message | Should -BeLike '*malformed*'
    }

    It 'applies NO key-shape check here — that lives in the sink (research §9)' {
        $r = Resolve-JiraAdoptionPin -PinsJson '["003-alpha=not-a-key"]' -AllFoldersJson $All
        $r.ExitCode | Should -Be 0
        @($r.Json | ConvertFrom-Json)[0].issue_key | Should -Be 'not-a-key'
    }
}

Describe 'a pin REPLACES discovery for its target (FR-020, FR-022)' {
    It 'binds with reason explicit-binding, needing no label on the ticket' {
        $p = Get-Plan -Candidates '[{"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,"identity":null}]' `
            -Pins '[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
        @($p.bindings)[0].issue_key | Should -Be 'ADO-9'
        @($p.bindings)[0].reason | Should -Be 'explicit-binding'
    }

    It 'names the discovered key it replaced in overrode_key (FR-022)' {
        $cands = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
 {"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,"identity":null}]
'@
        $p = Get-Plan -Candidates $cands -Pins '[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
        @($p.bindings)[0].issue_key | Should -Be 'ADO-9'
        @($p.bindings)[0].overrode_key | Should -Be 'ADO-1'
    }

    It 'leaves overrode_key null when the pin names the SAME discovered ticket' {
        $p = Get-Plan -Candidates '[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]' `
            -Pins '[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-1"}]'
        @($p.bindings)[0].overrode_key | Should -BeNullOrEmpty
    }

    It 'leaves overrode_key null when discovery found nothing to override' {
        $p = Get-Plan -Candidates '[{"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,"identity":null}]' `
            -Pins '[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
        @($p.bindings)[0].overrode_key | Should -BeNullOrEmpty
    }
}

Describe 'a pin is validated EXACTLY like a discovered candidate (FR-020)' {
    It 'refuses a pin to a claimed ticket' {
        $cands = '[{"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,"identity":{"origin":"human","repo":"acme/app","spec_slug":"009-elsewhere"}}]'
        $p = Get-Plan -Candidates $cands -Pins '[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
        @($p.refusals | Where-Object { $_.reason -eq 'already-claimed' }).Count | Should -Be 1
    }

    It 'refuses a pin to a ticket outside the routed project' {
        $p = Get-Plan -Candidates '[{"key":"BILL-9","project_key":"BILL","labels":[],"parent_key":null,"identity":null}]' `
            -Pins '[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"BILL-9"}]'
        @($p.refusals | Where-Object { $_.reason -eq 'wrong-project' }).Count | Should -Be 1
    }

    It 'still hierarchy-checks a pinned story against the bound feature' {
        $cands = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
 {"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":"ADO-77","identity":null}]
'@
        $p = Get-Plan -Candidates $cands -Pins '[{"spec_folder":"003-alpha","level":"story","story_ordinal":1,"issue_key":"ADO-9"}]'
        @($p.refusals | Where-Object { $_.reason -eq 'wrong-parent' }).Count | Should -Be 1
    }

    It 'skips a pinned ticket already adopted by THIS spec' {
        $cands = '[{"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,"identity":{"origin":"human","repo":"acme/app","spec_slug":"003-alpha"}}]'
        $p = Get-Plan -Candidates $cands -Pins '[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
        @($p.bindings)[0].status | Should -Be 'already-adopted'
        @($p.bindings)[0].reason | Should -Be 'explicit-binding'
    }

    It 'overrides the ambiguous-short-number refusal it exists to remedy' {
        $specs = '[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
        $p = Get-Plan -Specs $specs `
            -Candidates '[{"key":"ADO-5","project_key":"ADO","labels":["speckit-adopt:004"],"parent_key":null,"identity":null}]' `
            -Pins '[{"spec_folder":"004-beta","level":"feature","story_ordinal":null,"issue_key":"ADO-5"}]'
        @($p.bindings | Where-Object { $_.spec_folder -eq '004-beta' }).Count | Should -Be 1
        @($p.refusals | Where-Object { $_.spec_folder -eq '004-beta' }).Count | Should -Be 0
        @($p.refusals | Where-Object { $_.reason -eq 'ambiguous-short-number' }).Count | Should -Be 1
    }
}
