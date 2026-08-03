# T006 [Phase 2, 011] — mirror of tests/bash/sink/test_discovery_defaultable.bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Discovery.psm1') -Force
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'
}

Describe 'Get-JiraDiscoveryDefaultableFields' {
    It 'carries logical_name, field_id, schema_type, required, defaultable, allowed_values for a required scalar field' {
        $fields = @([pscustomobject]@{ fieldId = 'customfield_40012'; name = 'Program Increment'; required = $true; schema = @{ type = 'string' } })
        $out = @(Get-JiraDiscoveryDefaultableFields -Fields $fields)
        $out[0].logical_name | Should -Be 'Program Increment'
        $out[0].field_id | Should -Be 'customfield_40012'
        $out[0].schema_type | Should -Be 'string'
        $out[0].required | Should -Be $true
        $out[0].defaultable | Should -Be $true
        @($out[0].allowed_values).Count | Should -Be 0
    }

    It 'carries the same shape for an OPTIONAL field — never filtered out by requiredness (FR-004)' {
        $fields = @([pscustomobject]@{ fieldId = 'customfield_50001'; name = 'Team'; required = $false; schema = @{ type = 'string' } })
        $out = @(Get-JiraDiscoveryDefaultableFields -Fields $fields)
        $out[0].required | Should -Be $false
        $out[0].defaultable | Should -Be $true
    }

    It 'an enumerated field carries its allowed values, by the value Jira presents' {
        $fields = @([pscustomobject]@{ fieldId = 'customfield_40012'; name = 'Program Increment'; required = $true; schema = @{ type = 'option' }; allowedValues = @(@{ value = 'PI-2026-Q2' }, @{ value = 'PI-2026-Q3' }) })
        $out = @(Get-JiraDiscoveryDefaultableFields -Fields $fields)
        ($out[0].allowed_values -join ',') | Should -Be 'PI-2026-Q2,PI-2026-Q3'
    }

    It 'an allowed value keyed by name (not value) still resolves (priority-shaped enums)' {
        $fields = @([pscustomobject]@{ fieldId = 'customfield_1'; name = 'Severity'; required = $false; schema = @{ type = 'option' }; allowedValues = @(@{ name = 'Critical' }, @{ name = 'Medium' }) })
        $out = @(Get-JiraDiscoveryDefaultableFields -Fields $fields)
        ($out[0].allowed_values -join ',') | Should -Be 'Critical,Medium'
    }

    It 'a shape that cannot be a scalar (attachment, array-typed) is reported undefaultable with a reason, never offered (FR-010)' {
        $fields = @([pscustomobject]@{ fieldId = 'attachment'; name = 'Attachment'; required = $true; schema = @{ type = 'array' } })
        $out = @(Get-JiraDiscoveryDefaultableFields -Fields $fields)
        $out[0].defaultable | Should -Be $false
        $out[0].undefaultable_reason.Length | Should -BeGreaterThan 0
    }

    It 'a defaultable field carries NO undefaultable_reason key at all' {
        $fields = @([pscustomobject]@{ fieldId = 'customfield_1'; name = 'Team'; required = $false; schema = @{ type = 'string' } })
        $out = @(Get-JiraDiscoveryDefaultableFields -Fields $fields)
        ($out[0].PSObject.Properties.Match('undefaultable_reason').Count) | Should -Be 0
    }

    It 'the bridge-supplied fields never appear — they are not candidates for a default' {
        $fields = @(
            [pscustomobject]@{ fieldId = 'summary'; name = 'Summary'; required = $true; schema = @{ type = 'string' } },
            [pscustomobject]@{ fieldId = 'description'; name = 'Description'; required = $false; schema = @{ type = 'doc' } },
            [pscustomobject]@{ fieldId = 'issuetype'; name = 'Issue Type'; required = $true; schema = @{ type = 'issuetype' } },
            [pscustomobject]@{ fieldId = 'project'; name = 'Project'; required = $true; schema = @{ type = 'project' } },
            [pscustomobject]@{ fieldId = 'priority'; name = 'Priority'; required = $false; schema = @{ type = 'priority' } },
            [pscustomobject]@{ fieldId = 'reporter'; name = 'Reporter'; required = $false; schema = @{ type = 'user' } },
            [pscustomobject]@{ fieldId = 'parent'; name = 'Parent'; required = $false; schema = @{ type = 'issuelink' } }
        )
        $out = @(Get-JiraDiscoveryDefaultableFields -Fields $fields)
        $out.Count | Should -Be 0
    }

    It "a 'user' field IS defaultable — the bridge simply sends what was recorded" {
        $fields = @([pscustomobject]@{ fieldId = 'customfield_40011'; name = 'Business Owner'; required = $true; schema = @{ type = 'user' } })
        $out = @(Get-JiraDiscoveryDefaultableFields -Fields $fields)
        $out[0].defaultable | Should -Be $true
    }
}

Describe 'Get-JiraDiscoveryBindingResult — defaultable_fields' {
    BeforeEach {
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
    }
    AfterEach {
        $env:JIRA_EMAIL = $null
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_NO_SLEEP = $null
        $env:SPEC_KIT_JIRA_BASE_URL = $null
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'emits defaultable_fields keyed by issue-type id, alongside required_fields unchanged' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $script:ConfigDir 'mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $binding = Get-JiraDiscoveryBinding -ProjectKey 'PM' | ConvertFrom-Json -Depth 100
        @($binding.defaultable_fields.'10101').Count | Should -BeGreaterThan 0
        (@($binding.defaultable_fields.'10101') | Where-Object { $_.field_id -eq 'customfield_40011' }).logical_name | Should -Be 'Business Owner'
        @($binding.required_fields.'10101').Count | Should -Be 3
    }

    It 'Get-JiraDiscoveryTypeMetadataResult emits DefaultableFields for the fetched type' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $script:ConfigDir 'mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Get-JiraDiscoveryTypeMetadataResult -ProjectKey 'PM' -TypeId '10101'
        $r.ExitCode | Should -Be 0
        @($r.DefaultableFields).Count | Should -BeGreaterThan 0
    }
}
