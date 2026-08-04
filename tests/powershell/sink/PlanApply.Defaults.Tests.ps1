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

# --- 015, T010 [US1] — the encoding table (contract §1.3, data-model.md §2),
# mirror of tests/bash/sink/test_plan_apply_defaults.bats' 015 T008 cases.
# Each case builds its own tree — Pester discovery order differs between hosts.

Describe 'Get-JiraPlanResolveFieldDefault — field_defaults_encoded (015)' {
    BeforeEach {
        $script:ITypes015 = '[{"logical_name":"Epic","id":"10101"}]'
    }

    It 'a select-list (option) default is encoded as {value: v}' {
        $df = '{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]}]}'
        $recorded = '{"Epic":{"Region":"EMEA"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        $out.field_defaults_encoded.'10101'.customfield_1.value | Should -Be 'EMEA'
        $out.field_defaults.'10101'.customfield_1 | Should -Be 'EMEA'
    }

    It 'each named-entity schema_type is encoded as {name: v}' {
        foreach ($st in @('priority', 'resolution', 'version', 'component', 'group')) {
            $df = '{"10101":[{"logical_name":"F","field_id":"customfield_2","schema_type":"' + $st + '","required":true,"defaultable":true,"allowed_values":[]}]}'
            $recorded = '{"Epic":{"F":"Val"}}'
            $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
            $out.field_defaults_encoded.'10101'.customfield_2.name | Should -Be 'Val'
        }
    }

    It 'a string-typed default falls through unencoded' {
        $df = '{"10101":[{"logical_name":"F","field_id":"customfield_3","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}]}'
        $recorded = '{"Epic":{"F":"Plain text"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        $out.field_defaults_encoded.'10101'.customfield_3 | Should -Be 'Plain text'
    }

    It 'FR-004 — a user-typed default falls through unencoded, deliberately excluded from the table' {
        $df = '{"10101":[{"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]}]}'
        $recorded = '{"Epic":{"Business Owner":"Platform Team"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        $out.field_defaults_encoded.'10101'.customfield_40011 | Should -Be 'Platform Team'
    }

    It 'a cascading select (option-with-child) falls through unencoded' {
        $df = '{"10101":[{"logical_name":"Cascade","field_id":"customfield_4","schema_type":"option-with-child","required":true,"defaultable":true,"allowed_values":[]}]}'
        $recorded = '{"Epic":{"Cascade":"Parent Value"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        $out.field_defaults_encoded.'10101'.customfield_4 | Should -Be 'Parent Value'
    }

    It 'FR-006 — the non-string guard: a non-string recorded value passes through unchanged even for an option field' {
        $df = '{"10101":[{"logical_name":"Flag","field_id":"customfield_5","schema_type":"option","required":false,"defaultable":true,"allowed_values":[]}]}'
        $answers = '[{"type":"Epic","label":"Flag","value":true}]'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson '{}' -AnswersJson $answers | ConvertFrom-Json -Depth 100
        $out.field_defaults_encoded.'10101'.customfield_5 | Should -Be $true
        $out.field_defaults.'10101'.customfield_5 | Should -Be $true
    }

    It 'T050 (US2/AC4) — a this-run answer on an option-typed field encodes identically to the same text recorded' {
        $df = '{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]}]}'
        $answers = '[{"type":"Epic","label":"Region","value":"EMEA"}]'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson '{}' -AnswersJson $answers | ConvertFrom-Json -Depth 100
        $out.field_defaults_encoded.'10101'.customfield_1.value | Should -Be 'EMEA'

        $recorded = '{"Epic":{"Region":"EMEA"}}'
        $out2 = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        $out2.field_defaults_encoded.'10101'.customfield_1.value | Should -Be 'EMEA'
    }

    It 'FR-007 — a label resolving to no field falls through as recorded, and unresolved is unaffected' {
        $df = '{"10101":[]}'
        $recorded = '{"Epic":{"Nonexistent":"X"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        @($out.field_defaults.PSObject.Properties).Count | Should -Be 0
        @($out.field_defaults_encoded.PSObject.Properties).Count | Should -Be 0
        $out.unresolved[0].reason | Should -Be 'unknown field label'
    }

    It 'data-model §2 I1/I2 — field_defaults is unchanged and both maps share an identical key set' {
        $df = '{"10101":[
            {"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]},
            {"logical_name":"F","field_id":"customfield_3","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}
        ]}'
        $recorded = '{"Epic":{"Region":"EMEA","F":"Plain"}}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        (@($out.field_defaults.'10101'.PSObject.Properties.Name) | Sort-Object) -join ',' | Should -Be 'customfield_1,customfield_3'
        (@($out.field_defaults_encoded.'10101'.PSObject.Properties.Name) | Sort-Object) -join ',' | Should -Be 'customfield_1,customfield_3'
    }

    It 'data-model §2 I4 — nothing recorded and no answer: both maps are empty' {
        $df = '{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":false,"defaultable":true,"allowed_values":[]}]}'
        $out = Get-JiraPlanResolveFieldDefault -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $df -RecordedJson '{}' -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        @($out.field_defaults.PSObject.Properties).Count | Should -Be 0
        @($out.field_defaults_encoded.PSObject.Properties).Count | Should -Be 0
        @($out.unresolved).Count | Should -Be 0
    }
}
