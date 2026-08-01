# T011 [Phase 1, defect 3] / T013 [Phase 2] — mirror of
# tests/bash/lib/test_config_binding_shape.bats. `Get-JiraResolvedIdMap`
# reduces discovered issue types to a `{logical_name: id}` map, discarding
# hierarchy_level and subtask. RED until Phase 2 lands the list shape.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $LibDir 'Config.psm1') -Force
}

Describe 'Get-JiraResolvedIdMap — binding shape' {
    It 'keeps hierarchy_level and subtask' {
        $binding = @'
{
  "issue_types": [
    { "logical_name": "Épopée",  "id": "10301", "hierarchy_level": 1,  "subtask": false },
    { "logical_name": "Récit",   "id": "10302", "hierarchy_level": 0,  "subtask": false },
    { "logical_name": "Sous-tâche", "id": "10304", "hierarchy_level": -1, "subtask": true }
  ],
  "priorities": [],
  "statuses": []
}
'@
        $result = Get-JiraResolvedIdMap -BindingJson $binding | ConvertFrom-Json -Depth 100
        $result.issue_types.GetType().IsArray | Should -Be $true
        ($result.issue_types | Where-Object { $_.logical_name -eq 'Récit' }).hierarchy_level | Should -Be 0
        ($result.issue_types | Where-Object { $_.logical_name -eq 'Sous-tâche' }).subtask | Should -Be $true
    }

    It 'preserves discovered order and every issue type, priorities/statuses stay maps (T013)' {
        $binding = @'
{
  "issue_types": [
    { "logical_name": "Initiative", "id": "10100", "hierarchy_level": 2, "subtask": false },
    { "logical_name": "Deliverable", "id": "10101", "hierarchy_level": 1, "subtask": false },
    { "logical_name": "Story", "id": "10102", "hierarchy_level": 0, "subtask": false },
    { "logical_name": "Defect", "id": "10103", "hierarchy_level": 0, "subtask": false },
    { "logical_name": "Sub-task", "id": "10104", "hierarchy_level": -1, "subtask": true }
  ],
  "priorities": [ { "logical_name": "Highest", "id": "1" } ],
  "statuses": [ { "name": "To Do", "id": "10000" } ]
}
'@
        $result = Get-JiraResolvedIdMap -BindingJson $binding | ConvertFrom-Json -Depth 100
        @($result.issue_types).Count | Should -Be 5
        (@($result.issue_types) | ForEach-Object { $_.logical_name }) -join ',' | Should -Be 'Initiative,Deliverable,Story,Defect,Sub-task'
        $result.priorities.Highest | Should -Be '1'
        $result.statuses.'To Do' | Should -Be '10000'
    }

    It 'required_fields and parent_link_available carry through untouched, omitted when empty (T020)' {
        $binding = @'
{
  "issue_types": [ { "logical_name": "Story", "id": "10102", "hierarchy_level": 0, "subtask": false } ],
  "priorities": [], "statuses": [],
  "required_fields": { "10102": [ { "logical_name": "Summary", "field_id": "summary" } ] },
  "parent_link_available": { "10102": true }
}
'@
        $result = Get-JiraResolvedIdMap -BindingJson $binding | ConvertFrom-Json -Depth 100
        $result.required_fields.'10102'[0].logical_name | Should -Be 'Summary'
        $result.parent_link_available.'10102' | Should -Be $true

        $bindingNoHierarchy = '{ "issue_types": [], "priorities": [], "statuses": [] }'
        $result2 = Get-JiraResolvedIdMap -BindingJson $bindingNoHierarchy | ConvertFrom-Json -Depth 100
        $result2.PSObject.Properties.Match('required_fields').Count | Should -Be 0
        $result2.PSObject.Properties.Match('parent_link_available').Count | Should -Be 0
    }

    It 'every logical_name round-trips byte for byte in the new list shape (T014c)' {
        $json = @'
{"resolved_ids":{"COMP":{
  "child_type": {"logical_name":"高/低","id":"1","source":"operator"},
  "issue_types": [
    {"logical_name":"Задача (QA)","id":"1","hierarchy_level":"0","subtask":false},
    {"logical_name":"Done (QA)","id":"2","hierarchy_level":"1","subtask":false},
    {"logical_name":"Épopée","id":"3","hierarchy_level":"2","subtask":false}
  ],
  "required_fields": {"1": [{"logical_name":"Won't Do","field_id":"f1"}]}
}}}
'@
        $yaml = ConvertTo-JiraConfigYaml -Json $json
        $tmpf = Join-Path $TestDrive 'roundtrip.yml'
        Set-Content -LiteralPath $tmpf -Value $yaml -NoNewline
        $roundtripped = ConvertFrom-JiraConfigYaml -Path $tmpf
        ($roundtripped | & jq -cS .) | Should -Be ($json | & jq -cS .)
    }

    It 'a logical_name the reader cannot unescape refuses, even nested (T014c/FR-003b)' {
        $json = '{"resolved_ids":{"COMP":{"issue_types":[{"logical_name":"Bad\"Name","id":"1","hierarchy_level":"0","subtask":false}]}}}'
        $err = $null
        try { ConvertTo-JiraConfigYaml -Json $json } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err.Contains('resolved_ids.COMP.issue_types[0].logical_name') | Should -Be $true
    }
}
