# T010 [Phase 3, US1, 035] — mirror of tests/bash/engine/test_routing_marker.bats.
# Routing rank 3, the specification's own record
# (contracts/marker-routing.md C2.1-C2.7).
#
# Ranks 1 and 2 stay ahead of ranks 3 and 4 unconditionally: they say where the
# specification BELONGS, rank 3 only where it currently LIVES, rank 4 who is
# reconciling it.
#
# C2.5 is the clause that makes FR-005 verifiable: with the marker input empty,
# the resolver reproduces the four-input resolver exactly.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $EngineDir = Join-Path $Root 'scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Interchange.psm1') -Force

    # A repository shaped like the one that produced the report: two projects,
    # a catalogue naming both, a default naming the SECOND, and a feature
    # folder carrying no team-specific prefix.
    $script:Cfg = '{"projects":[{"key":"ALPHA"},{"key":"BETA"}],"routing_default":"BETA","teams":[{"id":"alpha","project":"ALPHA","folder_prefix":"alpha-"},{"id":"beta","project":"BETA","folder_prefix":"beta-"}]}'
    $script:CfgRule = '{"projects":[{"key":"ALPHA"},{"key":"BETA"}],"routing":[{"match":{"folder_prefix":"031-"},"project":"BETA"}],"routing_default":"BETA","teams":[{"id":"alpha","project":"ALPHA","folder_prefix":"alpha-"},{"id":"beta","project":"BETA","folder_prefix":"beta-"}]}'
    $script:CfgNoDefault = '{"projects":[{"key":"ALPHA"},{"key":"BETA"}],"teams":[{"id":"alpha","project":"ALPHA","folder_prefix":"alpha-"},{"id":"beta","project":"BETA","folder_prefix":"beta-"}]}'
    $script:CfgBare = '{"projects":[{"key":"ALPHA"}]}'
}

Describe 'Resolve-JiraRouting -MarkerProject' {
    It 'C2.1 rank 3 wins over routing_default for a bound specification' {
        $r = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -MarkerProject 'ALPHA'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.1 rank 3 wins over the operator''s selected team' {
        $r = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'beta' -MarkerProject 'ALPHA'
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.1 two operators with different selections resolve a bound spec identically' {
        $a = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'alpha' -MarkerProject 'ALPHA'
        $b = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'beta' -MarkerProject 'ALPHA'
        $a.ProjectKey | Should -Be $b.ProjectKey
        $a.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.3 a committed routing rule still outranks the record' {
        # A team that commits a decision must still be able to move a
        # specification. What the run then DOES with the mismatch is C3.2's
        # business, not the resolver's.
        $r = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:CfgRule -MarkerProject 'ALPHA'
        $r.ProjectKey | Should -Be 'BETA'
    }

    It 'C2.3 a committed team folder prefix still outranks the record' {
        $r = Resolve-JiraRouting -FolderName '031-beta-thing' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -MarkerProject 'ALPHA'
        $r.ProjectKey | Should -Be 'BETA'
    }

    It 'C2.1 rank 3 places a bound spec in a repository declaring NO routing_default' {
        # Today this refuses — and its refusal already tells the operator the
        # project is "fixed by its own markers" while declining to use it.
        $r = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:CfgNoDefault -MarkerProject 'ALPHA'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.5 an empty marker input reproduces the four-input resolver exactly' {
        $r = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -MarkerProject ''
        $r.ProjectKey | Should -Be 'BETA'
    }

    It 'C2.5 an omitted marker input reproduces the four-input resolver exactly' {
        $r = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:Cfg
        $r.ProjectKey | Should -Be 'BETA'
    }

    It 'C2.5 an empty marker input still lets rank 4 place an unbound spec' {
        $r = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'alpha' -MarkerProject ''
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.6 no rank yields anything: refusal, exit 4, no key' {
        $r = Resolve-JiraRouting -FolderName '031-test-feature' -LabelsJson '[]' -RoutingConfigJson $script:CfgBare -Quiet
        $r.ExitCode | Should -Be 4
        $r.ProjectKey | Should -BeNullOrEmpty
    }
}
