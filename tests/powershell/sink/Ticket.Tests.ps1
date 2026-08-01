# T043 [US3] — Ticket sink: validate (read) and create (guarded write). Pester
# twin of tests/bash/sink/test_ticket.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Ticket.psm1') -Force
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
