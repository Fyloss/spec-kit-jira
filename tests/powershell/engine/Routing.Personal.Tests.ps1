# T009/T011/T013 [Phase 3, US1] — mirror of
# tests/bash/engine/test_routing_personal.bats. Routing rank 3, the operator's
# own team (contracts/routing-resolution.md C1.1, C1.4, C2.1, C2.3, C2.5,
# C4.1, C4.2).
#
# Ranks 1 and 2 stay ahead of rank 3 unconditionally: they reason about the
# SPECIFICATION, rank 3 about the PERSON.
#
# C1.4 is the clause that makes FR-009 verifiable: with an empty selection the
# resolver must reproduce the three-input resolver exactly.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $EngineDir = Join-Path $Root 'scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Interchange.psm1') -Force

    # Rank 1 tests the RAW folder name, numbering included, unlike rank 2 which
    # tests it de-numbered — hence the '003-billing-' prefix rather than
    # 'billing-'.
    $script:Cfg = @'
{
  "routing": [{"match": {"folder_prefix": "003-billing-"}, "project": "ALPHA"}],
  "routing_default": "ALPHA",
  "teams": [
    {"id": "alpha", "project": "ALPHA", "folder_prefix": "alpha-", "branch_pattern": "alpha-<ID>/<FEATURE_NAME>"},
    {"id": "beta",  "project": "BETA",  "folder_prefix": "beta-",  "branch_pattern": "beta-<ID>/<FEATURE_NAME>"}
  ]
}
'@
    $script:CfgNoDefault = @'
{
  "routing": [{"match": {"folder_prefix": "003-billing-"}, "project": "ALPHA"}],
  "teams": [
    {"id": "alpha", "project": "ALPHA", "folder_prefix": "alpha-", "branch_pattern": "alpha-<ID>/<FEATURE_NAME>"},
    {"id": "beta",  "project": "BETA",  "folder_prefix": "beta-",  "branch_pattern": "beta-<ID>/<FEATURE_NAME>"}
  ]
}
'@
}

Describe 'Routing rank 3 - the operator selected team' {

    It 'C2.1 a spec matching nothing resolves to the selected team project' {
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'beta'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'BETA'
    }

    It 'C2.1 resolves per operator: the same spec, the other team' {
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'alpha'
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.1 rank 3 fires with no routing_default declared at all' {
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:CfgNoDefault -SelectedTeamId 'beta'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'BETA'
    }

    It 'C2.5 a committed routing rule beats the personal selection' {
        $r = Resolve-JiraRouting -FolderName '003-billing-refund' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'beta'
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.5 the committed team route beats the personal selection' {
        $r = Resolve-JiraRouting -FolderName '004-alpha-102-export' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'beta'
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.5 holds when the personal selection is the only thing that could match' {
        $r = Resolve-JiraRouting -FolderName '004-alpha-102-export' -LabelsJson '[]' -RoutingConfigJson $script:CfgNoDefault -SelectedTeamId 'beta'
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.3 an empty selection falls through to routing_default' {
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId ''
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C2.4 no rank yields anything: exit 4 and an empty key' {
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:CfgNoDefault -SelectedTeamId '' 2>$null
        $r.ExitCode | Should -Be 4
        $r.ProjectKey | Should -Be ''
    }

    It 'C4.2 a selected id matching no catalogue entry falls through to rank 4' {
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'ghost'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C4.2 an id matching no catalogue entry, with no default, refuses' {
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:CfgNoDefault -SelectedTeamId 'ghost' 2>$null
        $r.ExitCode | Should -Be 4
    }

    It 'C4.1 the id match is case-sensitive, like the bash jq comparison' {
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId 'BETA'
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C1.4 an omitted selection behaves exactly like an empty one' {
        $omitted = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:Cfg
        $empty = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:Cfg -SelectedTeamId ''
        $omitted.ProjectKey | Should -Be $empty.ProjectKey
        $omitted.ExitCode | Should -Be $empty.ExitCode
    }

    It 'C1.4 an empty selection reproduces rank 1 unchanged' {
        $r = Resolve-JiraRouting -FolderName '003-billing-refund' -LabelsJson '[]' -RoutingConfigJson $script:Cfg
        $r.ProjectKey | Should -Be 'ALPHA'
    }

    It 'C1.4 an empty selection reproduces rank 2 unchanged' {
        $r = Resolve-JiraRouting -FolderName '004-alpha-102-export' -LabelsJson '[]' -RoutingConfigJson $script:Cfg
        $r.ProjectKey | Should -Be 'ALPHA'
    }
}

Describe 'Rank 3 and a catalogue project absent from projects[] (T016)' {
    # Twin of tests/bash/commands/test_reconcile_rank3_unknown_project.bats.
    # Resolution itself must SUCCEED — the inconsistency is caught downstream by
    # the declared-projects check, not by making the resolver second-guess the
    # catalogue it was handed (Constitution VIII).
    BeforeAll {
        $script:CfgGhost = '{"projects":[{"key":"ALPHA"}],"routing":[],"routing_default":"ALPHA","teams":[{"id":"beta","project":"GHOST","folder_prefix":"beta-"}]}'
    }

    It 'rank 3 resolves the catalogue project even when projects[] omits it' {
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $script:CfgGhost -SelectedTeamId 'beta'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'GHOST'
    }

    It 'the resolver does not consult projects[] at all' {
        $cfg = '{"routing":[],"routing_default":"ALPHA","teams":[{"id":"beta","project":"GHOST","folder_prefix":"beta-"}]}'
        $r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson $cfg -SelectedTeamId 'beta'
        $r.ProjectKey | Should -Be 'GHOST'
    }
}
