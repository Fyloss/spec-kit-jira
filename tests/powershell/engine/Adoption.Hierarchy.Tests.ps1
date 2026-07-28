# T077 [US2] — Hierarchy and scope refusals, PowerShell side. Mirror of
# tests/bash/engine/test_adoption_hierarchy.bats
# (003 FR-005, FR-014, FR-015, data-model §8).

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Adoption.psm1') -Force
    Import-Module (Join-Path $EngineDir '../lib/Output.psm1') -Force
    $script:Prefix = 'speckit-adopt:'
    $script:Cfg = '{"routing":[{"match":{"folder_prefix":"005-"},"project":"BILL"}],"routing_default":"ADO"}'
    $script:Repo = 'acme/app'

    function Get-Plan {
        param([string] $Specs, [string] $Candidates = '[]', [string] $Pins = '[]')
        $t = Get-JiraAdoptionTarget -SpecsJson $Specs -Prefix $script:Prefix -ConfigJson $script:Cfg
        return (Get-JiraAdoptionPlan -TargetsJson $t.Json -CandidatesJson $Candidates -PinsJson $Pins -Repo $script:Repo | ConvertFrom-Json)
    }

    function Get-Refusal {
        param($Plan, [string] $Reason)
        return @($Plan.refusals | Where-Object { $_.reason -eq $Reason })[0]
    }
}

Describe 'wrong-project (FR-005)' {
    It 'refuses a pin to a ticket outside the routed project' {
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[]}]' `
            -Candidates '[{"key":"BILL-9","project_key":"BILL","labels":[],"parent_key":null,"identity":null}]' `
            -Pins '[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"BILL-9"}]'
        @($p.bindings).Count | Should -Be 0
        $r = Get-Refusal $p 'wrong-project'
        $r | Should -Not -BeNullOrEmpty
        $r.message | Should -BeLike '*003-alpha*'
        $r.message | Should -BeLike '*ADO*'
        $r.message | Should -BeLike '*BILL-9*'
        $r.message | Should -BeLike '*never migrates*'
    }

    It 'never applies wrong-project to a discovered candidate in the routed project' {
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[]}]' `
            -Candidates '[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'
        @($p.refusals).Count | Should -Be 0
    }
}

Describe 'unbound-parent (FR-014)' {
    It 'refuses a story whose feature ticket is not bound' {
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[1]}]' `
            -Candidates '[{"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-1","identity":null}]'
        $r = Get-Refusal $p 'unbound-parent'
        $r | Should -Not -BeNullOrEmpty
        $r.message | Should -BeLike '*003-alpha:us1*'
        $r.message | Should -BeLike '*ADO-2*'
        $r.remediation | Should -BeLike '*--bind 003-alpha=*'
    }

    It 'accepts a feature bound in THIS run as the story parent' {
        $cands = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
 {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-1","identity":null}]
'@
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[1]}]' -Candidates $cands
        @($p.refusals).Count | Should -Be 0
        @($p.bindings).Count | Should -Be 2
    }

    It 'accepts an ALREADY-ADOPTED feature as bound for its stories' {
        $cands = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,
  "identity":{"origin":"human","repo":"acme/app","spec_slug":"003-alpha"}},
 {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-1","identity":null}]
'@
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[1]}]' -Candidates $cands
        @($p.refusals).Count | Should -Be 0
        @($p.bindings)[0].status | Should -Be 'already-adopted'
        @($p.bindings)[1].status | Should -Be 'adopt'
    }
}

Describe 'wrong-parent (FR-015)' {
    It "refuses a story whose parent is not the spec's bound ticket" {
        $cands = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
 {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-77","identity":null}]
'@
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[1]}]' -Candidates $cands
        $r = Get-Refusal $p 'wrong-parent'
        $r | Should -Not -BeNullOrEmpty
        $r.message | Should -BeLike '*003-alpha:us1*'
        $r.message | Should -BeLike '*ADO-77*'
        (@($r.issue_keys) -join ',') | Should -Be 'ADO-1,ADO-2,ADO-77'
        $r.remediation | Should -BeLike '*re-parent ADO-2 under ADO-1*'
    }

    It 'refuses a story candidate with NO parent at all' {
        $cands = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
 {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":null,"identity":null}]
'@
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[1]}]' -Candidates $cands
        (Get-Refusal $p 'wrong-parent').message | Should -BeLike '*(none)*'
    }
}

Describe 'ambiguous-short-number (spec edge case)' {
    BeforeAll {
        $script:BothSpecs = '[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
        $script:ShortCand = '[{"key":"ADO-5","project_key":"ADO","labels":["speckit-adopt:004"],"parent_key":null,"identity":null}]'
    }

    It 'refuses BOTH folders sharing the number' {
        $p = Get-Plan -Specs $script:BothSpecs -Candidates $script:ShortCand
        @($p.bindings).Count | Should -Be 0
        @($p.refusals | Where-Object { $_.reason -eq 'ambiguous-short-number' }).Count | Should -Be 2
    }

    It 'names both spec folders and the label' {
        $r = Get-Refusal (Get-Plan -Specs $script:BothSpecs -Candidates $script:ShortCand) 'ambiguous-short-number'
        $r.message | Should -BeLike '*speckit-adopt:004*'
        $r.message | Should -BeLike '*004-beta*'
        $r.message | Should -BeLike '*004-gamma*'
        (@($r.issue_keys) -join ',') | Should -Be 'ADO-5'
        $r.remediation | Should -BeLike '*full-folder label form*'
    }

    It 'reports nothing when no ticket carries the short form' {
        $cands = '[{"key":"ADO-5","project_key":"ADO","labels":["speckit-adopt:004-beta"],"parent_key":null,"identity":null}]'
        $p = Get-Plan -Specs $script:BothSpecs -Candidates $cands
        @($p.refusals | Where-Object { $_.reason -eq 'ambiguous-short-number' }).Count | Should -Be 0
        @($p.bindings)[0].issue_key | Should -Be 'ADO-5'
    }

    It 'still binds through the short form when the number is unique' {
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[]}]' `
            -Candidates '[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003"],"parent_key":null,"identity":null}]'
        @($p.refusals).Count | Should -Be 0
        @($p.bindings)[0].issue_key | Should -Be 'ADO-1'
    }
}
