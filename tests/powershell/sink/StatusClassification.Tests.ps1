# T035/T039 [US2] — Status classification + many-to-one phase->status mapping.
# Mirror of tests/bash/sink/test_status_classification.bats. Classification is
# statusCategory-seeded and operator-refined, with NO built-in default table
# (FR-011/FR-034/FR-012). Lives in lib/Config.psm1.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../.specify/extensions/jira/scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Config.psm1') -Force
    $script:Statuses = '[{"name":"To Do","status_category":"new"},{"name":"In Progress","status_category":"indeterminate"},{"name":"In Review","status_category":"indeterminate"},{"name":"Done","status_category":"done"},{"name":"Cancelled","status_category":"done"}]'
}

Describe 'Status classification' {
    It 'seeds category-only classification when the operator maps nothing' {
        $c = Get-JiraStatusClassification -StatusesJson $Statuses | ConvertFrom-Json
        $c.Done | Should -Be 'post-scope'
        $c.'To Do' | Should -Be 'unknown'
        $c.'In Progress' | Should -Be 'unknown'
    }

    It 'promotes an operator-mapped status to mapped (many-to-one), overriding the done seed' {
        $pm = '{"build":"In Progress","verify":"In Progress","ship":"Done"}'
        $c = Get-JiraStatusClassification -StatusesJson $Statuses -PhaseStatusMapJson $pm | ConvertFrom-Json
        $c.'In Progress' | Should -Be 'mapped'
        $c.Done | Should -Be 'mapped'
    }

    It 'marks an operator-designated stop state as halted' {
        $c = Get-JiraStatusClassification -StatusesJson $Statuses -HaltedJson '["Cancelled"]' | ConvertFrom-Json
        $c.Cancelled | Should -Be 'halted'
        $c.Done | Should -Be 'post-scope'
    }

    It 'collapses a many-to-one phase->status map to distinct targets' {
        $t = @(Get-JiraPhaseStatusTargetSet -PhaseStatusMapJson '{"design":"In Review","develop":"In Review"}' | ConvertFrom-Json)
        $t.Count | Should -Be 1
        $t[0] | Should -Be 'In Review'
    }
}
