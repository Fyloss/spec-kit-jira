# T052 [US3] — plan_writes content rules, PowerShell side. Mirror of
# tests/bash/sink/test_plan_apply_content.bats. Cross-port parity proven in bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    $script:Doc = '{"stories":[{"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","text":"need"}]},"acceptance_criteria":[{"given":["g"],"when":["w"],"then":["t"]}],"priority_logical":"P1","estimation":5}]}'
    $script:CtxCreate = '{"base_url":"https://mock","story_type_id":"10002","priority_ids":{"P1":"1","P2":"2","P3":"3"},"estimation_field_id":"customfield_30044","tickets":{}}'
    $script:CtxUpdate = '{"base_url":"https://mock","story_type_id":"10002","priority_ids":{"P1":"1","P2":"2","P3":"3"},"estimation_field_id":"customfield_30044","tickets":{"s1":"ABC-1"}}'
}

Describe 'Get-JiraPlanWriteSet' {
    It 'maps the P1 priority to the project priority id on create (FR-017)' {
        $a = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxCreate | ConvertFrom-Json
        $a[0].method | Should -Be 'POST'
        $a[0].body.fields.priority.id | Should -Be '1'
    }
    It 'writes the estimation on create to the discovered field (FR-018)' {
        $a = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxCreate | ConvertFrom-Json
        $a[0].body.fields.customfield_30044 | Should -Be 5
    }
    It 'renders the ADF panel into the created description' {
        $a = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxCreate | ConvertFrom-Json
        $a[0].body.fields.description.type | Should -Be 'doc'
        @($a[0].body.fields.description.content | Where-Object { $_.type -eq 'panel' }).Count | Should -Be 1
    }
    It 'never re-sends the estimation field on update (FR-018)' {
        $a = Get-JiraPlanWriteSet -NeutralDocJson $script:Doc -PlanContextJson $script:CtxUpdate | ConvertFrom-Json
        $a[0].method | Should -Be 'PUT'
        $a[0].url | Should -Be 'https://mock/rest/api/3/issue/ABC-1'
        $a[0].body.fields.PSObject.Properties.Name | Should -Not -Contain 'customfield_30044'
        $a[0].body.fields.priority.id | Should -Be '1'
    }
}
