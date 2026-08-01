# T012 [Phase 1, defect 4] — mirror of tests/bash/sink/test_discovery_createmeta.bats.
# RED until Phase 2 (T017/T018) fetches per written type.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Discovery.psm1') -Force
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'
}

Describe 'Get-JiraDiscoveryBinding — per-type create metadata' {
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

    It 'fetches create metadata for each written issue type, not just the first' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $script:ConfigDir 'safe.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $null = Get-JiraDiscoveryBinding -ProjectKey 'SAFE'

        $calls = Get-JiraMockCallLog -Mock $script:M
        @($calls | Where-Object { $_ -eq 'GET /rest/api/3/issue/createmeta/SAFE/issuetypes/10402' }).Count | Should -BeGreaterOrEqual 1
        @($calls | Where-Object { $_ -eq 'GET /rest/api/3/issue/createmeta/SAFE/issuetypes/10403' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'records required_fields keyed by issue-type id, naming fields by their Jira name (T017)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $script:ConfigDir 'mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $binding = Get-JiraDiscoveryBinding -ProjectKey 'PM' | ConvertFrom-Json -Depth 100
        @($binding.required_fields.'10101').Count | Should -Be 3
        (@($binding.required_fields.'10101') | Where-Object { $_.field_id -eq 'customfield_40011' }).logical_name | Should -Be 'Business Owner'
    }

    It 'records required_fields for both types when the whole hierarchy is unambiguous' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $script:ConfigDir 'safe.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $binding = Get-JiraDiscoveryBinding -ProjectKey 'SAFE' | ConvertFrom-Json -Depth 100
        @($binding.required_fields.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be '10402,10403'
        @($binding.required_fields.'10402')[0].logical_name | Should -Be 'Summary'
        @($binding.required_fields.'10403')[0].logical_name | Should -Be 'Summary'
    }

    It 'reports whether a type''s create metadata offers a parent field — read, never assumed (T019)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $script:ConfigDir 'safe.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $binding = Get-JiraDiscoveryBinding -ProjectKey 'SAFE' | ConvertFrom-Json -Depth 100
        $binding.parent_link_available.'10403' | Should -Be $true
    }

    It 'a type whose create metadata offers no parent field is reported false, never assumed true' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $script:ConfigDir 'mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $binding = Get-JiraDiscoveryBinding -ProjectKey 'PM' | ConvertFrom-Json -Depth 100
        $binding.parent_link_available.'10101' | Should -Be $false
    }
}
