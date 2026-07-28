# T075 [US2] — Claim refusals, PowerShell side. Mirror of
# tests/bash/engine/test_adoption_claims.bats (003 FR-011, FR-027, research §4).
#
# ⚠️ The bridge-created origin on the wire is HYPHENATED. The spec's prose
# spelling names the concept; renaming the literal would invalidate every marker
# already stamped on a real ticket. These tests pin the literal.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Adoption.psm1') -Force
    Import-Module (Join-Path $EngineDir '../lib/Output.psm1') -Force
    $script:Prefix = 'speckit-adopt:'
    $script:Cfg = '{"routing_default":"ADO"}'
    $script:Repo = 'acme/app'
    $script:OneSpec = '[{"folder":"003-alpha","story_ordinals":[]}]'

    function Get-Plan {
        param([string] $Specs, [string] $Candidates = '[]')
        $t = Get-JiraAdoptionTarget -SpecsJson $Specs -Prefix $script:Prefix -ConfigJson $script:Cfg
        return (Get-JiraAdoptionPlan -TargetsJson $t.Json -CandidatesJson $Candidates -Repo $script:Repo | ConvertFrom-Json)
    }

    function New-ClaimedCandidate {
        param([string] $IdentityJson)
        $identity = if ($IdentityJson -eq 'null') { $null } else { $IdentityJson | ConvertFrom-Json }
        return (ConvertTo-JiraJsonValue @(
                [ordered]@{ key = 'ADO-1'; project_key = 'ADO'; labels = @('speckit-adopt:003-alpha')
                    parent_key = $null; identity = $identity
                }))
    }
}

Describe 'already-claimed (FR-011)' {
    It 'refuses when the marker names another spec in the same repository' {
        $p = Get-Plan -Specs $OneSpec -Candidates (New-ClaimedCandidate '{"origin":"human","repo":"acme/app","spec_slug":"004-other"}')
        @($p.bindings).Count | Should -Be 0
        @($p.refusals)[0].reason | Should -Be 'already-claimed'
    }

    It 'refuses when the marker names another REPOSITORY' {
        $p = Get-Plan -Specs $OneSpec -Candidates (New-ClaimedCandidate '{"origin":"human","repo":"other/repo","spec_slug":"003-alpha"}')
        @($p.refusals)[0].reason | Should -Be 'already-claimed'
    }

    It 'names the spec, the ticket, and the claiming spec' {
        $r = (Get-Plan -Specs $OneSpec -Candidates (New-ClaimedCandidate '{"origin":"human","repo":"acme/app","spec_slug":"004-other"}')).refusals[0]
        $r.message | Should -BeLike '*003-alpha*'
        $r.message | Should -BeLike '*ADO-1*'
        $r.message | Should -BeLike '*acme/app/004-other*'
        (@($r.issue_keys) -join ',') | Should -Be 'ADO-1'
        $r.remediation | Should -Not -BeNullOrEmpty
    }
}

Describe 'spec-owns-bridge-ticket (FR-011, research §4)' {
    It "refuses on THIS spec's marker carrying the bridge origin" {
        $p = Get-Plan -Specs $OneSpec -Candidates (New-ClaimedCandidate '{"origin":"bridge-created","repo":"acme/app","spec_slug":"003-alpha"}')
        @($p.bindings).Count | Should -Be 0
        @($p.refusals)[0].reason | Should -Be 'spec-owns-bridge-ticket'
    }

    It 'triggers on the HYPHENATED wire literal, not the prose spelling' {
        # The underscore spelling is not what any real ticket carries; treating
        # it as bridge-created would refuse a legitimate adoption.
        $p = Get-Plan -Specs $OneSpec -Candidates (New-ClaimedCandidate '{"origin":"bridge_created","repo":"acme/app","spec_slug":"003-alpha"}')
        @($p.refusals).Count | Should -Be 0
    }

    It 'names the spec folder and the ticket, and points at a Jira fix' {
        $r = (Get-Plan -Specs $OneSpec -Candidates (New-ClaimedCandidate '{"origin":"bridge-created","repo":"acme/app","spec_slug":"003-alpha"}')).refusals[0]
        $r.message | Should -BeLike '*003-alpha*'
        $r.message | Should -BeLike '*ADO-1*'
        $r.remediation | Should -BeLike '*--spec 003-alpha*'
    }
}

Describe 'already-adopted is NOT a refusal (FR-027)' {
    It "treats THIS spec's human-origin marker as already adopted and skipped" {
        $p = Get-Plan -Specs $OneSpec -Candidates (New-ClaimedCandidate '{"origin":"human","repo":"acme/app","spec_slug":"003-alpha"}')
        @($p.refusals).Count | Should -Be 0
        @($p.bindings).Count | Should -Be 1
        @($p.bindings)[0].status | Should -Be 'already-adopted'
        @($p.bindings)[0].issue_key | Should -Be 'ADO-1'
    }

    It 'binds an unclaimed candidate normally (control)' {
        $p = Get-Plan -Specs $OneSpec -Candidates (New-ClaimedCandidate 'null')
        @($p.refusals).Count | Should -Be 0
        @($p.bindings)[0].status | Should -Be 'adopt'
    }
}

Describe 'the claim check applies at every level' {
    It 'claim-checks a story candidate exactly like a feature candidate' {
        $cands = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
 {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-1",
  "identity":{"origin":"human","repo":"acme/app","spec_slug":"009-someone-else"}}]
'@
        $p = Get-Plan -Specs '[{"folder":"003-alpha","story_ordinals":[1]}]' -Candidates $cands
        @($p.bindings).Count | Should -Be 1
        @($p.refusals)[0].reason | Should -Be 'already-claimed'
        @($p.refusals)[0].level | Should -Be 'story'
    }
}
