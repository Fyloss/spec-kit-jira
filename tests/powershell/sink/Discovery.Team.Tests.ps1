# T034/T037/T038 [US2] — Team-managed (next-gen) discovery. Mirror of
# tests/bash/sink/test_discovery_team.bats: project-owned objects, Epic/Sub-task
# hierarchy only, and the project's OWN estimation field ranked (never the global
# Story Points, research §3). Same observable binding as the Bash port (NFR-1).

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../.specify/extensions/jira/scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Discovery.psm1') -Force
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'
}

Describe 'Team-managed discovery' {
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

    It 'detects the next-gen project style as team_managed' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $mock.BaseUrl
            $binding = Get-JiraDiscoveryBinding -ProjectKey 'TEAM' | ConvertFrom-Json
            $binding.style | Should -Be 'team_managed'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'limits the hierarchy to Epic (parent) / Sub-task (child)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $mock.BaseUrl
            $binding = Get-JiraDiscoveryBinding -ProjectKey 'TEAM' | ConvertFrom-Json
            $topLevel = ($binding.issue_types | Where-Object { -not $_.subtask } | Measure-Object -Property hierarchy_level -Maximum).Maximum
            $topLevel | Should -Be 1
            ($binding.issue_types | Where-Object { $_.hierarchy_level -eq 1 }).logical_name | Should -Be 'Epic'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'ranks the project OWN estimation field, never the global Story Points' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $env:SPEC_KIT_JIRA_BASE_URL = $mock.BaseUrl
            $binding = Get-JiraDiscoveryBinding -ProjectKey 'TEAM' | ConvertFrom-Json
            $binding.estimation_candidates[0].id | Should -Be 'customfield_30044'
            $binding.estimation_candidates[0].logical_name | Should -Be 'Effort Points'
            $binding.flagged_field | Should -BeNullOrEmpty
        } finally { Stop-JiraMock -Mock $mock }
    }
}
