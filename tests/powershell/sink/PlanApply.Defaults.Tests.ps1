# T026/T028/T034 [Phase 2, 011] — mirror of tests/bash/sink/test_plan_apply_defaults.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/PlanApply.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Ticket.psm1') -Force

    $script:ITypes = '[{"logical_name":"Epic","id":"10101"},{"logical_name":"Story","id":"10102"}]'
    $script:Defaultable = '{"10101":[
        {"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]},
        {"logical_name":"Program Increment","field_id":"customfield_40012","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}
    ]}'
}

Describe 'Get-JiraPlanResolveFieldDefault' {
    It 'a recorded label resolves to its field id, source team-config' {
        $recorded = '{"Epic":{"Business Owner":"Platform Team"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        $out.field_defaults.'10101'.customfield_40011 | Should -Be 'Platform Team'
        $out.field_default_sources.'10101'.customfield_40011 | Should -Be 'team-config'
    }

    It 'an answer for this run wins over the recorded default, source operator-answer' {
        $recorded = '{"Epic":{"Business Owner":"Platform Team"}}'
        $answers = '[{"type":"Epic","label":"Business Owner","value":"Override Team"}]'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -RecordedJson $recorded -AnswersJson $answers | ConvertFrom-Json -Depth 100
        $out.field_defaults.'10101'.customfield_40011 | Should -Be 'Override Team'
        $out.field_default_sources.'10101'.customfield_40011 | Should -Be 'operator-answer'
    }

    It 'an unresolvable field label is reported, never silently dropped' {
        $recorded = '{"Epic":{"Nonexistent Field":"X"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        @($out.field_defaults.PSObject.Properties).Count | Should -Be 0
        $out.unresolved[0].type | Should -Be 'Epic'
        $out.unresolved[0].label | Should -Be 'Nonexistent Field'
    }

    It 'an unresolvable issue-type name is reported, never silently dropped' {
        $recorded = '{"NoSuchType":{"Team":"Payments"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        $out.unresolved[0].type | Should -Be 'NoSuchType'
    }

    It 'the ask key of the recorded map is never mistaken for an issue-type name' {
        $recorded = '{"ask":false,"Epic":{"Business Owner":"Platform Team"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        @($out.unresolved).Count | Should -Be 0
        $out.field_defaults.'10101'.customfield_40011 | Should -Be 'Platform Team'
    }

    It 'empty inputs resolve to nothing, never an error' {
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -RecordedJson '{}' -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        @($out.field_defaults.PSObject.Properties).Count | Should -Be 0
        @($out.unresolved).Count | Should -Be 0
    }
}

Describe 'Get-JiraPlanConfirmationField' {
    It 'a field about to be sent is included with its recorded value' {
        $defaults = '{"10101":{"customfield_40011":"Platform Team"}}'
        $out = @(Get-JiraPlanConfirmationField -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -FieldDefaultsByTypeJson $defaults -PendingTypeIdsJson '["10101"]' | ConvertFrom-Json -Depth 100)
        # Program Increment is also required, with no resolved value — included too (recorded_value $null).
        $out.Count | Should -Be 2
        $bo = $out | Where-Object { $_.label -eq 'Business Owner' }
        $bo.issue_type | Should -Be 'Epic'
        $bo.recorded_value | Should -Be 'Platform Team'
        $bo.required | Should -Be $true
    }

    It 'a required field with no resolved value is included with recorded_value null' {
        $out = @(Get-JiraPlanConfirmationField -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -FieldDefaultsByTypeJson '{}' -PendingTypeIdsJson '["10101"]' | ConvertFrom-Json -Depth 100)
        $out.Count | Should -Be 2
        $pi = $out | Where-Object { $_.label -eq 'Program Increment' }
        $pi.recorded_value | Should -Be $null
    }

    It 'a merely-defaultable optional field with no resolved value is never included' {
        $optionalDf = '{"10101":[
            {"logical_name":"Team Nickname","field_id":"customfield_40099","schema_type":"string","required":false,"defaultable":true,"allowed_values":[]}
        ]}'
        $out = @(Get-JiraPlanConfirmationField -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $optionalDf -FieldDefaultsByTypeJson '{}' -PendingTypeIdsJson '["10101"]' | ConvertFrom-Json -Depth 100)
        $out.Count | Should -Be 0
    }

    It 'a type the project offers but has no creation pending this run contributes nothing' {
        $defaults = '{"10101":{"customfield_40011":"Platform Team"}}'
        $out = @(Get-JiraPlanConfirmationField -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -FieldDefaultsByTypeJson $defaults -PendingTypeIdsJson '[]' | ConvertFrom-Json -Depth 100)
        $out.Count | Should -Be 0
    }

    It 'allowed_values is carried through for a field that has them' {
        $df = '{"10101":[
            {"logical_name":"Program Increment","field_id":"customfield_40012","schema_type":"option","required":true,"defaultable":true,"allowed_values":["PI-2026-Q2","PI-2026-Q3"]}
        ]}'
        $out = @(Get-JiraPlanConfirmationField -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $df -FieldDefaultsByTypeJson '{}' -PendingTypeIdsJson '["10101"]' | ConvertFrom-Json -Depth 100)
        ($out[0].allowed_values -join ',') | Should -Be 'PI-2026-Q2,PI-2026-Q3'
    }
}

Describe 'Get-JiraPlanWriteSet — field defaults (T027/T033)' {
    It 'an UPDATE (existing ticket) carries no defaulted field, even when defaults are recorded' {
        $doc = '{"routing":{"project_key":"CONSUMER"},"epic":{"local_id":"E1","title":"Epic","description":{"blocks":[]}},"stories":[{"local_id":"S1","title":"Existing story","priority_logical":null,"estimation":null}]}'
        $ctx = '{"base_url":"https://example.atlassian.net","story_type_id":"10102","tickets":{"S1":"CONSUMER-9"},"field_defaults":{"10102":{"customfield_50001":"Payments"}}}'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $out.stories[0].method | Should -Be 'PUT'
        ($out.stories[0].body.fields.PSObject.Properties.Match('customfield_50001').Count) | Should -Be 0
    }

    It 'a story CREATE merges field_defaults from the plan context' {
        $doc = '{"routing":{"project_key":"CONSUMER"},"epic":{"local_id":"E1","title":"Epic","description":{"blocks":[]}},"stories":[{"local_id":"S1","title":"New story","priority_logical":null,"estimation":null}]}'
        $ctx = '{"base_url":"https://example.atlassian.net","story_type_id":"10102","field_defaults":{"10102":{"customfield_50001":"Payments"}}}'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $out.stories[0].method | Should -Be 'POST'
        $out.stories[0].body.fields.customfield_50001 | Should -Be 'Payments'
    }

    It 'a parent CREATE merges field_defaults, scoped to the parent type' {
        $doc = '{"routing":{"project_key":"CONSUMER"},"epic":{"local_id":"E1","title":"New epic","description":{"blocks":[{"type":"paragraph","text":"Overview."}]}},"stories":[]}'
        $ctx = '{"base_url":"https://example.atlassian.net","parent_type_id":"10101","field_defaults":{"10101":{"customfield_40011":"Platform Team"},"10102":{"customfield_50001":"Payments"}}}'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $out.parent.body.fields.customfield_40011 | Should -Be 'Platform Team'
        ($out.parent.body.fields.PSObject.Properties.Match('customfield_50001').Count) | Should -Be 0
    }

    It 'no field_defaults key in the context leaves every payload byte-identical to before this feature (FR-028)' {
        $doc = '{"routing":{"project_key":"CONSUMER"},"epic":{"local_id":"E1","title":"Epic","description":{"blocks":[]}},"stories":[{"local_id":"S1","title":"New story","priority_logical":null,"estimation":null}]}'
        $ctx = '{"base_url":"https://example.atlassian.net","story_type_id":"10102"}'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        (@($out.stories[0].body.fields.PSObject.Properties.Name) | Sort-Object) -join ',' | Should -Be 'description,issuetype,parent,project,summary'
    }
}
