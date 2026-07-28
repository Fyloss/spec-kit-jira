# T073 [US2] — Candidate-count refusals, PowerShell side. Mirror of
# tests/bash/engine/test_adoption_classify.bats (003 FR-009, FR-010).

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Adoption.psm1') -Force
    # Imported directly (and LAST) because the helpers below serialise with it;
    # Adoption's own nested -Force import would otherwise re-scope it away.
    Import-Module (Join-Path $EngineDir '../lib/Output.psm1') -Force
    $script:Prefix = 'speckit-adopt:'
    $script:Cfg = '{"routing_default":"ADO"}'
    $script:Repo = 'acme/app'
    $script:OneSpec = '[{"folder":"003-alpha","story_ordinals":[]}]'

    function Get-Plan {
        param([string] $Specs, [string] $Candidates = '[]', [string] $Pins = '[]')
        $t = Get-JiraAdoptionTarget -SpecsJson $Specs -Prefix $script:Prefix -ConfigJson $script:Cfg
        $t.ExitCode | Should -Be 0
        return (Get-JiraAdoptionPlan -TargetsJson $t.Json -CandidatesJson $Candidates -PinsJson $Pins -Repo $script:Repo | ConvertFrom-Json)
    }

    function New-Candidates {
        param([string[]] $Keys, [string] $Label = 'speckit-adopt:003-alpha')
        $l = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $Keys) {
            $l.Add([ordered]@{ key = $k; project_key = 'ADO'; labels = @($Label); parent_key = $null; identity = $null })
        }
        return (ConvertTo-JiraJsonValue $l.ToArray())
    }
}

Describe 'no-candidate (FR-009)' {
    It 'refuses with no-candidate and produces zero bindings' {
        $p = Get-Plan -Specs $OneSpec
        @($p.bindings).Count | Should -Be 0
        @($p.refusals).Count | Should -Be 1
        @($p.refusals)[0].reason | Should -Be 'no-candidate'
    }

    It 'names the spec folder and the EXACT labels searched for' {
        $msg = (Get-Plan -Specs $OneSpec).refusals[0].message
        $msg | Should -BeLike '*003-alpha*'
        $msg | Should -BeLike '*speckit-adopt:003-alpha*'
        $msg | Should -BeLike '*speckit-adopt:003*'
        $msg | Should -BeLike '*searched*'
    }

    It 'offers a copy-pasteable --bind remediation' {
        (Get-Plan -Specs $OneSpec).refusals[0].remediation |
            Should -BeLike '*spec-kit-jira adopt --bind 003-alpha=<ISSUE-KEY>*'
    }

    It 'carries an EMPTY issue_keys array, not a null' {
        # The property must exist and serialise as [], which is what the schema
        # requires and what the byte-parity capture asserts.
        $r = (Get-Plan -Specs $OneSpec).refusals[0]
        $r.PSObject.Properties.Name | Should -Contain 'issue_keys'
        @($r.issue_keys).Count | Should -Be 0
    }

    It 'names the ordinal of a story target' {
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[2]}]'
        $story = @($p.refusals | Where-Object { $_.level -eq 'story' })[0]
        $story.message | Should -BeLike '*003-alpha:us2*'
        $story.story_ordinal | Should -Be 2
    }
}

Describe 'several-candidates (FR-010)' {
    It 'refuses when more than one ticket carries the label' {
        $p = Get-Plan -Specs $OneSpec -Candidates (New-Candidates @('ADO-2', 'ADO-9'))
        @($p.bindings).Count | Should -Be 0
        @($p.refusals)[0].reason | Should -Be 'several-candidates'
    }

    It 'names EVERY candidate, never a truncated pair (NFR-6)' {
        $p = Get-Plan -Specs $OneSpec -Candidates (New-Candidates @('ADO-1', 'ADO-2', 'ADO-3', 'ADO-4', 'ADO-5'))
        @($p.refusals[0].issue_keys).Count | Should -Be 5
        foreach ($k in @('ADO-1', 'ADO-2', 'ADO-3', 'ADO-4', 'ADO-5')) {
            $p.refusals[0].message | Should -BeLike "*$k*"
        }
    }

    It 'lists the keys in a stable ascending (codepoint) order across ports' {
        $p = Get-Plan -Specs $OneSpec -Candidates (New-Candidates @('ADO-9', 'ADO-2', 'ADO-11'))
        (@($p.refusals[0].issue_keys) -join ',') | Should -Be 'ADO-11,ADO-2,ADO-9'
    }

    It 'names one of the real candidates in the remediation' {
        $p = Get-Plan -Specs $OneSpec -Candidates (New-Candidates @('ADO-2', 'ADO-9'))
        $p.refusals[0].remediation | Should -Be 'spec-kit-jira adopt --bind 003-alpha=ADO-2'
    }
}

Describe 'a refusal never stops an unambiguous binding (FR-013)' {
    It 'applies the clean binding alongside the refused one' {
        $specs = '[{"folder":"003-alpha","story_ordinals":[]},{"folder":"004-beta","story_ordinals":[]}]'
        $cands = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
 {"key":"ADO-8","project_key":"ADO","labels":["speckit-adopt:004-beta"],"parent_key":null,"identity":null},
 {"key":"ADO-9","project_key":"ADO","labels":["speckit-adopt:004-beta"],"parent_key":null,"identity":null}]
'@
        $p = Get-Plan -Specs $specs -Candidates $cands
        @($p.bindings).Count | Should -Be 1
        @($p.bindings)[0].issue_key | Should -Be 'ADO-1'
        @($p.refusals).Count | Should -Be 1
        @($p.refusals)[0].spec_folder | Should -Be '004-beta'
    }

    It 'orders bindings and refusals by the target order (data-model §7.3)' {
        $specs = '[{"folder":"005-gamma","story_ordinals":[]},{"folder":"003-alpha","story_ordinals":[]}]'
        $cands = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
 {"key":"ADO-5","project_key":"ADO","labels":["speckit-adopt:005-gamma"],"parent_key":null,"identity":null}]
'@
        $p = Get-Plan -Specs $specs -Candidates $cands
        (@($p.bindings | ForEach-Object { $_.spec_folder }) -join ',') | Should -Be '003-alpha,005-gamma'
    }

    It 'is deterministic — identical input, identical bytes' {
        $cands = New-Candidates @('ADO-2', 'ADO-9')
        $t = (Get-JiraAdoptionTarget -SpecsJson $OneSpec -Prefix $Prefix -ConfigJson $Cfg).Json
        (Get-JiraAdoptionPlan -TargetsJson $t -CandidatesJson $cands -Repo $Repo) |
            Should -Be (Get-JiraAdoptionPlan -TargetsJson $t -CandidatesJson $cands -Repo $Repo)
    }
}
