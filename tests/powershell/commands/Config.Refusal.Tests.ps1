# T036/T040 [US2] — Config-time refusal of an impossible mapping (FR-007).
# Mirror of tests/bash/commands/test_config_refusal.bats. A team-managed level
# above the discovered Epic tier is refused with exit 4; company-managed is
# unrestricted; strategies persist by logical name. Lives in commands/Config.psm1.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    $script:TeamBinding = '{"style":"team_managed","issue_types":[{"logical_name":"Epic","id":"10200","subtask":false,"hierarchy_level":1},{"logical_name":"Story","id":"10201","subtask":false,"hierarchy_level":0},{"logical_name":"Sub-task","id":"10202","subtask":true,"hierarchy_level":-1}]}'
    $script:CompanyBinding = '{"style":"company_managed","issue_types":[{"logical_name":"Initiative","id":"10100","subtask":false,"hierarchy_level":2},{"logical_name":"Deliverable","id":"10101","subtask":false,"hierarchy_level":1},{"logical_name":"Story","id":"10102","subtask":false,"hierarchy_level":0}]}'
}

Describe 'Config-time mapping refusal' {
    It 'refuses a team-managed level above Epic with exit 4' {
        $code = Test-JiraMappingValidity -Style 'team_managed' -HierarchyJson '["Initiative","Epic","Story"]' -BindingJson $TeamBinding
        $code | Should -Be 4
    }

    It 'accepts a valid team-managed Epic/Story hierarchy' {
        $code = Test-JiraMappingValidity -Style 'team_managed' -HierarchyJson '["Epic","Story"]' -BindingJson $TeamBinding
        $code | Should -Be 0
    }

    It 'does not restrict a company-managed multi-level hierarchy' {
        $code = Test-JiraMappingValidity -Style 'company_managed' -HierarchyJson '["Initiative","Deliverable","Story"]' -BindingJson $CompanyBinding
        $code | Should -Be 0
    }

    It 'persists epic/task strategy and link type by logical name' {
        $r = New-JiraProjectMapping -Key 'COMP' -Style 'company_managed' -EpicStrategy 'per_repo' -TaskStrategy 'linked_story' -LinkType 'blocks'
        $r.ExitCode | Should -Be 0
        $obj = $r.Json | ConvertFrom-Json
        $obj.key | Should -Be 'COMP'
        $obj.epic_strategy | Should -Be 'per_repo'
        $obj.task_strategy | Should -Be 'linked_story'
        $obj.link_type | Should -Be 'blocks'
    }

    It 'refuses linked_story without a link type (exit 4)' {
        $r = New-JiraProjectMapping -Key 'TEAM' -Style 'team_managed' -EpicStrategy 'per_feature' -TaskStrategy 'linked_story'
        $r.ExitCode | Should -Be 4
    }
}
