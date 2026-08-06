# T052 [US3] — plan_writes content rules, PowerShell side. Mirror of
# tests/bash/sink/test_plan_apply_content.bats. Cross-port parity proven in bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    $script:Doc = '{"routing":{"project_key":"COMP"},"epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18","marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},"stories":[{"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","spans":[{"text":"need","marks":[]}]}]},"acceptance_criteria":[{"given":[[{"text":"g","marks":[]}]],"when":[[{"text":"w","marks":[]}]],"then":[[{"text":"t","marks":[]}]]}],"priority_logical":"P1","estimation":5}]}'
    $script:CtxCreate = '{"base_url":"https://mock","story_type_id":"10002","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18","priority_ids":{"P1":"1","P2":"2","P3":"3"},"estimation_field_id":"customfield_30044","tickets":{}}'
    $script:CtxUpdate = '{"base_url":"https://mock","story_type_id":"10002","parent_type_id":"10101","parent_local_id":"3f2a91c04b7e6d18","priority_ids":{"P1":"1","P2":"2","P3":"3"},"estimation_field_id":"customfield_30044","tickets":{"s1":"ABC-1"}}'
}

Describe 'Get-JiraPlanWriteSet' {
    It 'maps the P1 priority to the project priority id on create (FR-017)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxCreate | ConvertFrom-Json
        $r.stories[0].method | Should -Be 'POST'
        $r.stories[0].body.fields.priority.id | Should -Be '1'
    }
    It 'writes the estimation on create to the discovered field (FR-018)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxCreate | ConvertFrom-Json
        $r.stories[0].body.fields.customfield_30044 | Should -Be 5
    }
    It 'renders the ADF panel into the created description' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxCreate | ConvertFrom-Json
        $r.stories[0].body.fields.description.type | Should -Be 'doc'
        @($r.stories[0].body.fields.description.content | Where-Object { $_.type -eq 'panel' }).Count | Should -Be 1
    }
    It 'never re-sends the estimation field on update (FR-018)' {
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxUpdate | ConvertFrom-Json
        $r.stories[0].method | Should -Be 'PUT'
        $r.stories[0].url | Should -Be 'https://mock/rest/api/3/issue/ABC-1'
        $r.stories[0].body.fields.PSObject.Properties.Name | Should -Not -Contain 'customfield_30044'
        $r.stories[0].body.fields.priority.id | Should -Be '1'
    }
    It 'T109: an update re-links a child whose current parent disagrees with the resolved one' {
        $ctx = '{"base_url":"https://mock","story_type_id":"10002","priority_ids":{"P1":"1","P2":"2","P3":"3"},"tickets":{"s1":"ABC-1"},"ticket_parents":{"s1":"OLD-9"},"parent_key":"NEW-1"}'
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json
        $r.stories[0].method | Should -Be 'PUT'
        $r.stories[0].body.fields.parent.key | Should -Be 'NEW-1'
    }
    It 'T109: an update leaves a child carrying NO parent untouched (Out of Scope, no migration)' {
        $ctx = '{"base_url":"https://mock","story_type_id":"10002","priority_ids":{"P1":"1","P2":"2","P3":"3"},"tickets":{"s1":"ABC-1"},"parent_key":"NEW-1"}'
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json
        $r.stories[0].body.fields.PSObject.Properties.Name | Should -Not -Contain 'parent'
    }
    It 'T109: an update whose current parent already matches the resolved one adds no parent field' {
        $ctx = '{"base_url":"https://mock","story_type_id":"10002","priority_ids":{"P1":"1","P2":"2","P3":"3"},"tickets":{"s1":"ABC-1"},"ticket_parents":{"s1":"NEW-1"},"parent_key":"NEW-1"}'
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json
        $r.stories[0].body.fields.PSObject.Properties.Name | Should -Not -Contain 'parent'
    }
    It 'T109: an update whose target parent is not yet known (created this run) uses the apply-time placeholder' {
        $ctx = '{"base_url":"https://mock","story_type_id":"10002","priority_ids":{"P1":"1","P2":"2","P3":"3"},"tickets":{"s1":"ABC-1"},"ticket_parents":{"s1":"OLD-9"}}'
        $r = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $ctx | ConvertFrom-Json
        $r.stories[0].body.fields.parent.key | Should -Be '<resolved at apply time>'
    }
}
