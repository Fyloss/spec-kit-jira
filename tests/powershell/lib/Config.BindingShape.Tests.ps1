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

    # --- T078 [Phase 9] — the `roles` shape (010, contract §5.1, §9.2) -----

    It 'T078 — roles.<role> round-trips {logical_name, id, hierarchy_level, subtask, source} with hierarchy_level as a STRING' {
        $json = @'
{"resolved_ids":{"CONSUMER":{
  "roles": {
    "specification": {"logical_name":"Epic","id":"10701","hierarchy_level":"1","subtask":false,"source":"declared"},
    "story":         {"logical_name":"Story","id":"10704","hierarchy_level":"0","subtask":false,"source":"declared"},
    "task":          {"logical_name":"Sous-tâche","id":"10716","hierarchy_level":"-1","subtask":true,"source":"declared"}
  },
  "child_type":  {"logical_name":"Story","id":"10704","source":"declared"},
  "parent_type": {"logical_name":"Epic","id":"10701","source":"declared"}
}}}
'@
        $yaml = ConvertTo-JiraConfigYaml -Json $json
        $tmpf = Join-Path $TestDrive 'roundtrip-roles.yml'
        Set-Content -LiteralPath $tmpf -Value $yaml -NoNewline
        $roundtripped = ConvertFrom-JiraConfigYaml -Path $tmpf
        ($roundtripped | & jq -cS .) | Should -Be ($json | & jq -cS .)
        ($roundtripped | & jq -r '.resolved_ids.CONSUMER.roles.story.hierarchy_level | type') | Should -Be 'string'
    }

    It 'T078 — roles.story ≡ child_type and roles.specification ≡ parent_type on the declared-hierarchy fixture' {
        $fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-declared-hierarchy/.specify/jira/config.local.yml'
        $json = ConvertFrom-JiraConfigYaml -Path $fixture
        $story = ($json | & jq -cS '.resolved_ids.CONSUMER.roles.story | {logical_name, id, source}')
        $childType = ($json | & jq -cS '.resolved_ids.CONSUMER.child_type')
        $story | Should -Be $childType

        $spec = ($json | & jq -cS '.resolved_ids.CONSUMER.roles.specification | {logical_name, id, source}')
        $parentType = ($json | & jq -cS '.resolved_ids.CONSUMER.parent_type')
        $spec | Should -Be $parentType
    }
}

Describe 'Get-JiraResolvedIdMap — defaultable_fields (011, T012)' {
    It 'carries straight through, keyed by issue-type id' {
        $binding = @'
{
  "issue_types": [ { "logical_name": "Deliverable", "id": "10101", "hierarchy_level": 1, "subtask": false } ],
  "priorities": [], "statuses": [],
  "defaultable_fields": { "10101": [
    { "logical_name": "Business Owner", "field_id": "customfield_40011", "schema_type": "user",
      "required": true, "defaultable": true, "allowed_values": [] }
  ] }
}
'@
        $result = Get-JiraResolvedIdMap -BindingJson $binding | ConvertFrom-Json -Depth 100
        $result.defaultable_fields.'10101'[0].logical_name | Should -Be 'Business Owner'
    }

    It 'is OMITTED, never emitted empty, when discovery resolved no type' {
        $binding = '{ "issue_types": [], "priorities": [], "statuses": [] }'
        $result = Get-JiraResolvedIdMap -BindingJson $binding | ConvertFrom-Json -Depth 100
        $result.PSObject.Properties.Match('defaultable_fields').Count | Should -Be 0
    }

    It 'a full entry (allowed_values + undefaultable_reason) round-trips byte for byte' {
        $json = @'
{"resolved_ids":{"PM":{
  "defaultable_fields": { "10101": [
    { "logical_name": "Business Owner", "field_id": "customfield_40011", "schema_type": "user",
      "required": true, "defaultable": true, "allowed_values": [] },
    { "logical_name": "Program Increment", "field_id": "customfield_40012", "schema_type": "option",
      "required": true, "defaultable": true, "allowed_values": ["PI-2026-Q2", "PI-2026-Q3"] },
    { "logical_name": "Attachment", "field_id": "attachment", "schema_type": "array",
      "required": true, "defaultable": false, "allowed_values": [],
      "undefaultable_reason": "a list of values cannot be expressed as a single recorded value" }
  ] }
}}}
'@
        $yaml = ConvertTo-JiraConfigYaml -Json $json
        $tmpf = Join-Path $TestDrive 'roundtrip-defaultable.yml'
        Set-Content -LiteralPath $tmpf -Value $yaml -NoNewline
        $roundtripped = ConvertFrom-JiraConfigYaml -Path $tmpf
        ($roundtripped | & jq -cS .) | Should -Be ($json | & jq -cS .)
    }

    It 'a binding written BEFORE this feature (no defaultable_fields key at all) still loads' {
        # A dedicated inline fixture, not tests/conformance/fixtures/repo-with-mandatory-field —
        # that shared fixture has since gained defaultable_fields of its own, to let the
        # US3 reconcile scenarios exercise the consolidated question without a config
        # ceremony run first. Reusing it here would test the wrong thing.
        $json = @'
{"resolved_ids":{"PM":{
    "issue_types": [ { "logical_name": "Deliverable", "id": "10101", "hierarchy_level": 1, "subtask": false } ],
    "priorities": [], "statuses": [],
    "required_fields": { "10101": [
      { "logical_name": "Summary", "field_id": "summary" },
      { "logical_name": "Business Owner", "field_id": "customfield_40011" },
      { "logical_name": "Program Increment", "field_id": "customfield_40012" }
    ] }
}}}
'@
        $yaml = ConvertTo-JiraConfigYaml -Json $json
        $tmpf = Join-Path $TestDrive 'pre-011-binding.yml'
        Set-Content -LiteralPath $tmpf -Value $yaml -NoNewline
        $roundtripped = ConvertFrom-JiraConfigYaml -Path $tmpf
        ($roundtripped | & jq -r '.resolved_ids.PM | has("defaultable_fields")') | Should -Be 'false'
        ($roundtripped | & jq -r '.resolved_ids.PM.required_fields."10101" | length') | Should -Be '3'
    }
}
