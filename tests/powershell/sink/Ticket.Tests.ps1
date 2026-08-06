# T043 [US3] — Ticket sink: validate (read) and create (guarded write). Pester
# twin of tests/bash/sink/test_ticket.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    # Import order is load-bearing: PlanApply.psm1 -Force-imports Ticket.psm1
    # internally, and Ticket.psm1 -Force-imports PrivacyGuard.psm1 internally
    # (Import-Module -Force is Remove-Module + Import-Module, which tears an
    # earlier copy out of THIS scope and reattaches it wherever the -Force
    # call itself runs). Each module is therefore reimported here, directly,
    # in dependency order, so every function this file calls is bound back
    # into the test scope last (see memory:
    # powershell-import-force-clobbers-caller-scope).
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/PlanApply.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Ticket.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/PrivacyGuard.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Start-TestMock {
        param([string]$ConfigJson)
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, $ConfigJson)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
}

Describe 'Ticket sink' {
    AfterEach { if ($M) { Stop-JiraMock -Mock $M; $script:M = $null } }

    It 'validates a mentioned key and returns its project' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Confirm-JiraTicket -Key 'IJT-42'
        $r.ExitCode | Should -Be 0
        $obj = $r.Json | ConvertFrom-Json
        $obj.key | Should -Be 'IJT-42'
        $obj.project | Should -Be 'IJT'
        (Get-JiraMockCallLog -Mock $M) -join "`n" | Should -Match 'GET /rest/api/3/issue/IJT-42\?fields=project'
    }

    It 'fails closed on an unknown mentioned key (exit 2)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Confirm-JiraTicket -Key 'NOPE-1'
        $r.ExitCode | Should -Be 2
        $r.Json | Should -Be ''
    }

    It 'New-JiraCreateFieldsBase returns exactly {project,issuetype,summary} (FR-025)' {
        $base = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10201'
        $obj = $base | ConvertFrom-Json
        @($obj.PSObject.Properties.Name | Sort-Object) | Should -Be @('issuetype', 'project', 'summary')
        $obj.project.key | Should -Be 'IJT'
        $obj.issuetype.id | Should -Be '10201'
        $obj.summary | Should -Be 'invoice export'
    }

    It 'tolerates an empty issue-type id — validation is the CALLER''s job (regression, Phase 5 US2)' {
        # The parent's own creation path (PlanApply.psm1, Get-JiraPlanWriteSetParent)
        # calls this builder before any mandatory-field gate exists (Phase 6,
        # US3). A prior defect had these parameters reject an empty string at
        # the binding level — a stricter behaviour bash's jq-based builder
        # does not share (NFR-1).
        { Get-JiraCreateFieldsBase -ProjectKey 'TEST' -Summary 'The Epic' -IssueTypeId '' -ErrorAction Stop } | Should -Not -Throw
        $base = Get-JiraCreateFieldsBase -ProjectKey 'TEST' -Summary 'The Epic' -IssueTypeId ''
        ($base | ConvertFrom-Json).issuetype.id | Should -Be ''
    }

    It 'Get-JiraTicketCreateBody is built from Get-JiraCreateFieldsBase, unchanged (FR-025)' {
        $base = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10201'
        $body = Get-JiraTicketCreateBody -ProjectKey 'IJT' -Summary 'invoice export' -StoryTypeId '10201'
        (($body | ConvertFrom-Json).fields | ConvertTo-Json -Compress -Depth 10) | Should -Be ($base | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10)
    }

    It 'builds the create body with the team project and the resolved story-type id' {
        $body = Get-JiraTicketCreateBody -ProjectKey 'IJT' -Summary 'invoice export' -StoryTypeId '10201'
        $obj = $body | ConvertFrom-Json
        $obj.fields.project.key | Should -Be 'IJT'
        $obj.fields.issuetype.id | Should -Be '10201'
        $obj.fields.summary | Should -Be 'invoice export'
        ($obj.fields.issuetype.PSObject.Properties.Name -contains 'name') | Should -BeFalse
    }

    It 'T024b, T12 [017] -- Get-JiraCreateFieldsBase sends the provenance label as its fifth argument (union with recorded labels default)' {
        $out = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10201' -FieldDefaultsByTypeJson '{}' -Provenance 'speckit-001-x' | ConvertFrom-Json
        ($out.labels -join ',') | Should -Be 'speckit-001-x'
    }

    It 'T024b, T12 [017] -- the feature ceremony''s Get-JiraTicketCreateBody carries NO labels key -- in particular never speckit-spec -- while its base stays byte-identical to the mirror''s' {
        $baseNoProv = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10201'
        $baseWithProv = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10201' -FieldDefaultsByTypeJson '{}' -Provenance 'speckit-spec'
        $withProvObj = $baseWithProv | ConvertFrom-Json
        $noLabels = [ordered]@{}
        foreach ($p in $withProvObj.PSObject.Properties) { if ($p.Name -ne 'labels') { $noLabels[$p.Name] = $p.Value } }
        (ConvertTo-Json -InputObject $noLabels -Compress -Depth 10) | Should -Be ($baseNoProv | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10)

        $body = Get-JiraTicketCreateBody -ProjectKey 'IJT' -Summary 'invoice export' -StoryTypeId '10201'
        $bodyObj = $body | ConvertFrom-Json
        ($bodyObj.fields.PSObject.Properties.Name -contains 'labels') | Should -BeFalse
        (($bodyObj.fields | ConvertTo-Json -Compress -Depth 10)) | Should -Be ($baseNoProv | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10)
    }

    It 'creates, returns the new key, and identity-stamps it' {
        Start-TestMock '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
        $r = New-JiraTicket -ProjectKey 'IJT' -Summary 'invoice export' -StoryTypeId '10201' -SpecRefJson '{"repo":"acme/app","spec_slug":"003-x"}'
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).key | Should -Be 'IJT-123'
        $log = (Get-JiraMockCallLog -Mock $M) -join "`n"
        $log | Should -Match 'POST /rest/api/3/issue'
        $log | Should -Match 'PUT /rest/api/3/issue/IJT-123/properties/spec-kit-jira'
    }

    It 'blocks a credential-shaped payload BEFORE the POST (exit 9, zero writes)' {
        Start-TestMock '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
        $r = New-JiraTicket -ProjectKey 'IJT' -Summary 'summary with token ATATT3xFfGF0abcdef' -StoryTypeId '10201'
        $r.ExitCode | Should -Be 9
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }
}

Describe 'Get-JiraCreateFieldsBase — field defaults (011, T030/T030a)' {
    It 'merges the defaults for the type being created' {
        $dbt = '{"10101":{"customfield_40011":"Platform Team"}}'
        $out = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10101' -FieldDefaultsByTypeJson $dbt
        $obj = $out | ConvertFrom-Json
        $obj.customfield_40011 | Should -Be 'Platform Team'
        $obj.project.key | Should -Be 'IJT'
    }

    It 'merges nothing when the map is empty (FR-028, absence is the off switch)' {
        $out = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10101' -FieldDefaultsByTypeJson '{}'
        @(($out | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'issuetype,project,summary'
    }

    It 'the fourth argument is entirely optional — omitting it behaves exactly as before (regression)' {
        $out = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10101'
        @(($out | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'issuetype,project,summary'
    }

    It 'merges NOTHING recorded against a DIFFERENT issue type (FR-018 negative)' {
        $dbt = '{"10101":{"customfield_40011":"Platform Team"}}'
        $out = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'a story' -IssueTypeId '10102' -FieldDefaultsByTypeJson $dbt
        (($out | ConvertFrom-Json).PSObject.Properties.Match('customfield_40011').Count) | Should -Be 0
    }

    It 'the defaulted value reaches the privacy guard scan, proving the merge happens at plan time' {
        $dbt = '{"10201":{"customfield_99999":"RAWSECRET-shaped-value ATATT3xFfGF0abcdef"}}'
        $merged = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10201' -FieldDefaultsByTypeJson $dbt
        $guardedBody = '{"fields":' + $merged + '}'
        $code = Test-JiraPrivacyBlock -Payload $guardedBody -KnownCoordinatesJson '[]' -AllowlistJson '[]'
        $code | Should -Be 9
    }

    It 'an allowlisted defaulted value passes the guard silently' {
        $dbt = '{"10201":{"customfield_1":"support.example.atlassian.net"}}'
        $merged = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'invoice export' -IssueTypeId '10201' -FieldDefaultsByTypeJson $dbt
        $guardedBody = '{"fields":' + $merged + '}'
        $code = Test-JiraPrivacyBlock -Payload $guardedBody -KnownCoordinatesJson '[]' -AllowlistJson '["support.example.atlassian.net"]'
        $code | Should -Be 0
    }
}

# --- 015 FR-017 regression, mirror of tests/bash/sink/test_ticket.bats ------

Describe '015 field-default encoding, end to end through Get-JiraCreateFieldsBase' {
    It 'FR-017 — a select-list default reaches Get-JiraCreateFieldsBase as {value: v}, a string default unchanged' {
        $itypes = '[{"logical_name":"Story","id":"10102"}]'
        $df = '{"10102":[
            {"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]},
            {"logical_name":"Team","field_id":"customfield_2","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}
        ]}'
        $recorded = '{"Story":{"Region":"EMEA","Team":"Payments"}}'
        $resolved = Get-JiraPlanResolveFieldDefault -IssueTypesJson $itypes -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        $encoded = $resolved.field_defaults_encoded | ConvertTo-Json -Compress -Depth 100
        $base = Get-JiraCreateFieldsBase -ProjectKey 'IJT' -Summary 'a story' -IssueTypeId '10102' -FieldDefaultsByTypeJson $encoded | ConvertFrom-Json -Depth 100
        $base.customfield_1.value | Should -Be 'EMEA'
        $base.customfield_2 | Should -Be 'Payments'
    }

    It 'FR-008 — the story CREATE branch and the parent CREATE branch encode the same recorded default identically' {
        $itypes = '[{"logical_name":"Story","id":"10102"},{"logical_name":"Epic","id":"10101"}]'
        $df = '{"10102":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]}],
                 "10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]}]}'
        $recorded = '{"Story":{"Region":"EMEA"},"Epic":{"Region":"EMEA"}}'
        $resolved = Get-JiraPlanResolveFieldDefault -IssueTypesJson $itypes -DefaultableFieldsByTypeJson $df -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json -Depth 100
        $encoded = $resolved.field_defaults_encoded | ConvertTo-Json -Compress -Depth 100

        $doc = '{"routing":{"project_key":"CONSUMER"},"epic":{"local_id":"E1","title":"New epic","description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},"stories":[{"local_id":"S1","title":"New story","priority_logical":null,"estimation":null}]}'
        $ctx = '{"base_url":"https://example.atlassian.net","story_type_id":"10102","parent_type_id":"10101","field_defaults":' + $encoded + '}'
        $out = Get-JiraPlanWriteSet -NeutralDocJson $doc -PlanContextJson $ctx | ConvertFrom-Json -Depth 100
        $out.stories[0].body.fields.customfield_1.value | Should -Be 'EMEA'
        $out.parent.body.fields.customfield_1.value | Should -Be 'EMEA'
    }
}
