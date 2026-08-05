# T055 [US6] — the task-tier satisfiability verdict (data-model.md §5): a
# THIRD, SEPARATE gate from Get-JiraHierarchyMandatoryGate, over the type
# carrying the `task` role alone. Get-JiraHierarchyMandatoryGate's own
# two-type verdict is unchanged by any of this — it never inspects
# `roles.task` (FR-036). Mirror of tests/bash/sink/test_hierarchy_task_gate.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $SinkDir = Join-Path $Root 'scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Hierarchy.psm1') -Force

    # A binding whose specification/story tiers are already clean, and whose
    # `task` role (Sous-tâche, id 10201) carries one required, defaultable
    # field (Definition of Done) and one required, undefaultable field
    # (Affected Teams, an array — its shape can never be a recorded value).
    $script:BindingTaskJson = '{
      "child_type": {"logical_name":"Story", "id":"10102"},
      "parent_type": {"logical_name":"Deliverable", "id":"10101"},
      "parent_link_available": {"10102": true},
      "required_fields": {
        "10101": [{"logical_name":"Summary", "field_id":"summary"}],
        "10102": [{"logical_name":"Summary", "field_id":"summary"}],
        "10201": [
          {"logical_name":"Summary", "field_id":"summary"},
          {"logical_name":"Definition of Done", "field_id":"customfield_50011"},
          {"logical_name":"Affected Teams", "field_id":"customfield_50012"}
        ]
      },
      "defaultable_fields": {
        "10201": [
          {"logical_name":"Definition of Done", "field_id":"customfield_50011", "schema_type":"string", "required":true, "defaultable":true, "allowed_values":[]},
          {"logical_name":"Affected Teams", "field_id":"customfield_50012", "schema_type":"array", "required":true, "defaultable":false, "allowed_values":[], "undefaultable_reason":"a list of values cannot be expressed as a single recorded value"}
        ]
      },
      "roles": {"task": {"logical_name":"Sous-tâche", "id":"10201"}}
    }'
}

Describe 'Get-JiraHierarchyTaskGate' {
    It 'T055 — a task role with nothing unsatisfiable or undefaultable passes clean (ok)' {
        $binding = $script:BindingTaskJson | ConvertFrom-Json
        $binding.required_fields.'10201' = @([pscustomobject]@{ logical_name = 'Summary'; field_id = 'summary' })
        $binding.defaultable_fields.'10201' = @()
        $r = Get-JiraHierarchyTaskGate -Binding $binding
        $r.status | Should -Be 'ok'
    }

    It 'T055 — no task role in the binding at all trivially passes (ok)' {
        $binding = $script:BindingTaskJson | ConvertFrom-Json
        $binding.PSObject.Properties.Remove('roles')
        $r = Get-JiraHierarchyTaskGate -Binding $binding
        $r.status | Should -Be 'ok'
    }

    It 'T055 — a required, defaultable field nothing has satisfied yet reports unsatisfiable, named by Jira label, with a --field-default remedy' {
        $binding = $script:BindingTaskJson | ConvertFrom-Json
        $binding.required_fields.'10201' = @(
            [pscustomobject]@{ logical_name = 'Summary'; field_id = 'summary' },
            [pscustomobject]@{ logical_name = 'Definition of Done'; field_id = 'customfield_50011' }
        )
        $binding.defaultable_fields.'10201' = @(
            [pscustomobject]@{ logical_name = 'Definition of Done'; field_id = 'customfield_50011'; schema_type = 'string'; required = $true; defaultable = $true; allowed_values = @() }
        )
        $r = Get-JiraHierarchyTaskGate -Binding $binding -ProjectKey 'COMP'
        $r.status | Should -Be 'unsatisfiable'
        @($r.fields).Count | Should -Be 1
        $r.fields[0].logical_name | Should -Be 'Definition of Done'
        $r.message | Should -Match 'Definition of Done'
        $r.message | Should -Match '--field-default'
        $r.message | Should -Not -Match 'customfield_'
    }

    It 'T055 — a recorded or answered default resolves the unsatisfiable field (ok)' {
        $binding = $script:BindingTaskJson | ConvertFrom-Json
        $binding.required_fields.'10201' = @(
            [pscustomobject]@{ logical_name = 'Summary'; field_id = 'summary' },
            [pscustomobject]@{ logical_name = 'Definition of Done'; field_id = 'customfield_50011' }
        )
        $binding.defaultable_fields.'10201' = @(
            [pscustomobject]@{ logical_name = 'Definition of Done'; field_id = 'customfield_50011'; schema_type = 'string'; required = $true; defaultable = $true; allowed_values = @() }
        )
        $defaults = '{"10201":{"customfield_50011":"Shipped and documented"}}' | ConvertFrom-Json
        $r = Get-JiraHierarchyTaskGate -Binding $binding -ProjectKey 'COMP' -DefaultsByType $defaults
        $r.status | Should -Be 'ok'
    }

    It 'T055 — a required field whose shape cannot be defaulted at all reports undefaultable, named by Jira label with its reason, and no --field-default remedy' {
        $binding = $script:BindingTaskJson | ConvertFrom-Json
        $binding.required_fields.'10201' = @(
            [pscustomobject]@{ logical_name = 'Summary'; field_id = 'summary' },
            [pscustomobject]@{ logical_name = 'Affected Teams'; field_id = 'customfield_50012' }
        )
        $binding.defaultable_fields.'10201' = @(
            [pscustomobject]@{ logical_name = 'Affected Teams'; field_id = 'customfield_50012'; schema_type = 'array'; required = $true; defaultable = $false; allowed_values = @(); undefaultable_reason = 'a list of values cannot be expressed as a single recorded value' }
        )
        $r = Get-JiraHierarchyTaskGate -Binding $binding -ProjectKey 'COMP'
        $r.status | Should -Be 'undefaultable'
        @($r.fields).Count | Should -Be 1
        $r.fields[0].logical_name | Should -Be 'Affected Teams'
        $r.fields[0].reason | Should -Be 'a list of values cannot be expressed as a single recorded value'
        $r.message | Should -Match 'Affected Teams'
        $r.message | Should -Match 'a list of values cannot be expressed as a single recorded value'
        $r.message | Should -Not -Match '--field-default'
    }

    It 'T055 — Get-JiraHierarchyMandatoryGate''s own two-type verdict is unchanged by a binding that also carries roles.task' {
        $without = $script:BindingTaskJson | ConvertFrom-Json
        $without.PSObject.Properties.Remove('roles')
        $with = $script:BindingTaskJson | ConvertFrom-Json

        $rWithout = Get-JiraHierarchyMandatoryGate -Binding $without
        $rWith = Get-JiraHierarchyMandatoryGate -Binding $with

        (ConvertTo-Json -InputObject $rWithout -Compress) | Should -Be (ConvertTo-Json -InputObject $rWith -Compress)
        $rWith.status | Should -Be 'ok'
    }
}
