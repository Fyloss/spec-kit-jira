# T079 [US2] — The no-heuristic guarantee, PowerShell side. Mirror of
# tests/bash/engine/test_adoption_no_heuristic.bats (003 FR-012, US2 AS-5).
#
# FR-012 forbids any similarity, order, recency or issue-type path from EXISTING
# in any code path — not merely from being reached.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Adoption.psm1') -Force
    Import-Module (Join-Path $EngineDir '../lib/Output.psm1') -Force
    $script:Prefix = 'speckit-adopt:'
    $script:Cfg = '{"routing_default":"ADO"}'
    $script:Repo = 'acme/app'
    $script:Specs = '[{"folder":"003-label-based-adoption","story_ordinals":[]}]'
    $script:Label = 'speckit-adopt:003-label-based-adoption'
    $script:Targets = (Get-JiraAdoptionTarget -SpecsJson $script:Specs -Prefix $script:Prefix -ConfigJson $script:Cfg).Json

    function Get-PlanJson { param([string] $Candidates)
        return (Get-JiraAdoptionPlan -TargetsJson $script:Targets -CandidatesJson $Candidates -Repo $script:Repo)
    }

    function New-TwoCandidates {
        param([hashtable] $ExtraA = @{}, [hashtable] $ExtraB = @{})
        $mk = {
            param([string] $Key, [hashtable] $Extra)
            $o = [ordered]@{ key = $Key; project_key = 'ADO'; labels = @($script:Label); parent_key = $null; identity = $null }
            foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
            return $o
        }
        return (ConvertTo-JiraJsonValue @((& $mk 'ADO-2' $ExtraA), (& $mk 'ADO-9' $ExtraB)))
    }
}

Describe 'no tie-break exists (FR-012)' {
    It 'refuses two candidates whose titles match the spec exactly' {
        $p = Get-PlanJson (New-TwoCandidates @{ summary = 'Label-Based Adoption' } @{ summary = 'Label-Based Adoption' }) | ConvertFrom-Json
        @($p.bindings).Count | Should -Be 0
        @($p.refusals)[0].reason | Should -Be 'several-candidates'
    }

    It 'refuses even when only ONE title matches — similarity never breaks the tie' {
        $p = Get-PlanJson (New-TwoCandidates @{ summary = 'Label-Based Adoption' } @{ summary = 'Something else entirely' }) | ConvertFrom-Json
        @($p.bindings).Count | Should -Be 0
        @($p.refusals)[0].reason | Should -Be 'several-candidates'
    }

    It 'is unaffected by candidate ORDER' {
        $forward = New-TwoCandidates
        $reverse = ConvertTo-JiraJsonValue (@($forward | ConvertFrom-Json)[-1..0])
        (Get-PlanJson $forward) | Should -Be (Get-PlanJson $reverse)
    }

    It 'is unaffected by apparent RECENCY' {
        (Get-PlanJson (New-TwoCandidates @{ created = '2019-01-01' } @{ created = '2026-01-01' })) |
            Should -Be (Get-PlanJson (New-TwoCandidates @{ created = '2026-01-01' } @{ created = '2019-01-01' }))
    }

    It 'is unaffected by ISSUE TYPE' {
        (Get-PlanJson (New-TwoCandidates @{ issuetype = 'Epic' } @{ issuetype = 'Story' })) |
            Should -Be (Get-PlanJson (New-TwoCandidates @{ issuetype = 'Story' } @{ issuetype = 'Epic' }))
    }

    It 'does not read titles, dates or types at all — the plan is byte-identical without them' {
        $bare = Get-PlanJson (New-TwoCandidates)
        $rich = Get-PlanJson (New-TwoCandidates `
                @{ summary = 'Label-Based Adoption'; created = '2026-07-27'; issuetype = 'Epic'; status = 'In Progress' } `
                @{ summary = 'Label-Based Adoption'; created = '2019-01-01'; issuetype = 'Story'; status = 'Done' })
        $bare | Should -Be $rich
    }

    It 'binds a SINGLE candidate however unlike the spec its title is' {
        $c = ConvertTo-JiraJsonValue @([ordered]@{ key = 'ADO-1'; project_key = 'ADO'; labels = @($script:Label)
                parent_key = $null; identity = $null; summary = 'zzz unrelated'
            })
        $p = Get-PlanJson $c | ConvertFrom-Json
        @($p.bindings).Count | Should -Be 1
        @($p.bindings)[0].reason | Should -Be 'label-match'
    }

    It 'chooses a candidate for one of exactly two reasons (data-model §7.1)' {
        $c = ConvertTo-JiraJsonValue @([ordered]@{ key = 'ADO-1'; project_key = 'ADO'; labels = @($script:Label)
                parent_key = $null; identity = $null
            })
        $p = Get-PlanJson $c | ConvertFrom-Json
        @('label-match', 'explicit-binding') | Should -Contain @($p.bindings)[0].reason
    }
}
