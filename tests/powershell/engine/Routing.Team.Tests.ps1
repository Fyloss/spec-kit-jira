# T082 [US3] — Implicit team→project route (US3 scenario 6, data-model §4).
# Pester twin of tests/bash/engine/test_routing_team.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/engine/Interchange.psm1') -Force
    $script:CfgTeams = '{"routing":[],"routing_default":"COMP","teams":[{"id":"ijt","project":"IJT","folder_prefix":"ijt-","branch_pattern":"ijt-<ID>/<FEATURE_NAME>"},{"id":"wex","project":"WEX","folder_prefix":"wex-","branch_pattern":"wex-<ID>/<FEATURE_NAME>"}]}'
}

Describe 'Implicit team route' {
    It 'routes a team-prefixed folder to the team project with no explicit rule (scenario 6)' {
        $r = Resolve-JiraRouting -FolderName '003-ijt-invoice-export' -LabelsJson '[]' -RoutingConfigJson $CfgTeams
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'IJT'
        (Resolve-JiraRouting -FolderName '004-wex-onboarding' -LabelsJson '[]' -RoutingConfigJson $CfgTeams).ProjectKey | Should -Be 'WEX'
    }

    It 'lets an explicit routing rule win over the implicit team route' {
        $cfg = '{"routing":[{"match":{"folder_prefix":"003-"},"project":"BILL"}],"routing_default":"COMP","teams":[{"id":"ijt","project":"IJT","folder_prefix":"ijt-","branch_pattern":"ijt-<ID>/<FEATURE_NAME>"}]}'
        (Resolve-JiraRouting -FolderName '003-ijt-invoice-export' -LabelsJson '[]' -RoutingConfigJson $cfg).ProjectKey | Should -Be 'BILL'
    }

    It 'still falls back to routing_default for a non-team folder' {
        (Resolve-JiraRouting -FolderName '005-plain-feature' -LabelsJson '[]' -RoutingConfigJson $CfgTeams).ProjectKey | Should -Be 'COMP'
    }

    It 'keeps behaviour unchanged without a catalogue' {
        (Resolve-JiraRouting -FolderName '003-ijt-invoice-export' -LabelsJson '[]' -RoutingConfigJson '{"routing":[],"routing_default":"COMP"}').ProjectKey | Should -Be 'COMP'
    }
}

Describe 'Implicit team route — review remediation (T090)' {
    It 'does not let a template catch-all rule (empty folder_prefix) shadow the team route' {
        $cfg = '{"routing":[{"match":{"folder_prefix":""},"project":"COMP"}],"routing_default":"COMP","teams":[{"id":"wex","project":"WEX","folder_prefix":"wex-","branch_pattern":"wex-<ID>/<FEATURE_NAME>"}]}'
        (Resolve-JiraRouting -FolderName '004-wex-onboarding' -LabelsJson '[]' -RoutingConfigJson $cfg).ProjectKey | Should -Be 'WEX'
        (Resolve-JiraRouting -FolderName '005-plain-feature' -LabelsJson '[]' -RoutingConfigJson $cfg).ProjectKey | Should -Be 'COMP'
    }

    It 'ignores a teams entry without folder_prefix (twin of the bash jq guard)' {
        $cfg = '{"routing":[{"match":{"folder_prefix":"001-"},"project":"AAA"}],"routing_default":"DEF","teams":[{"id":"t","project":"TTT"}]}'
        $r = Resolve-JiraRouting -FolderName '001-alpha' -LabelsJson '[]' -RoutingConfigJson $cfg
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'AAA'
    }
}
