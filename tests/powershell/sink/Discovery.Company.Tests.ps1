# T033/T037 [US2] — Company-managed (classic) discovery. Mirror of
# tests/bash/sink/test_discovery_company.bats: style detected first, then the
# scheme-based per-style path (research §1/§2/§15). Same observable binding as
# the Bash port (NFR-1).

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Discovery.psm1') -Force
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'
}

Describe 'Company-managed discovery' {
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
    }

    It 'detects the classic project style as company_managed' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $mock.BaseUrl
            $binding = Get-JiraDiscoveryBinding -ProjectKey 'COMP' | ConvertFrom-Json
            $binding.style | Should -Be 'company_managed'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'issues the style call first, then the per-style discovery calls' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $mock.BaseUrl
            Get-JiraDiscoveryBinding -ProjectKey 'COMP' | Out-Null
            $calls = @(Get-JiraMockCallLog -Mock $mock)
            $calls[0] | Should -Be 'GET /rest/api/3/project/COMP'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'discovers issue types with hierarchy levels' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $mock.BaseUrl
            $binding = Get-JiraDiscoveryBinding -ProjectKey 'COMP' | ConvertFrom-Json
            @($binding.issue_types).Count | Should -Be 5
            ($binding.issue_types | Where-Object { $_.logical_name -eq 'Initiative' }).id | Should -Be '10100'
            ($binding.issue_types | Where-Object { $_.logical_name -eq 'Initiative' }).hierarchy_level | Should -Be 2
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'ranks the project own estimation field and finds the flagged field' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $mock.BaseUrl
            $binding = Get-JiraDiscoveryBinding -ProjectKey 'COMP' | ConvertFrom-Json
            $binding.estimation_candidates[0].id | Should -Be 'customfield_20011'
            $binding.flagged_field.id | Should -Be 'customfield_20044'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'fail-closes (exit 2, empty) on a 404 read' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $mock.BaseUrl
            $r = Get-JiraDiscoveryBindingResult -ProjectKey 'MISSING'
            $r.ExitCode | Should -Be 2
            $r.Binding | Should -BeNullOrEmpty
        } finally { Stop-JiraMock -Mock $mock }
    }
}
