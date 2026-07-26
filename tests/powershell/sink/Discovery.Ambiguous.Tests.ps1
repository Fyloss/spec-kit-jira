# T006 [US1] — Three-valued style mapping regression (FR-001/FR-002).
# Pester twin of tests/bash/sink/test_discovery_ambiguous.bats: an absent or
# contradictory style signal MUST yield the empty result — never the silent
# company_managed default. Written FIRST and observed failing (Constitution XIII).

BeforeAll {
    $root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $root 'scripts/powershell/sink/jira/Discovery.psm1') -Force
}

Describe 'Get-JiraDiscoveryStyle three-valued mapping (FR-001/FR-002)' {
    It 'yields empty for a payload with neither style nor simplified — never company_managed' {
        $proj = '{"id":"10002","key":"AMBI","name":"Ambiguous Signals Demo"}' | ConvertFrom-Json
        Get-JiraDiscoveryStyle $proj | Should -Be ''
    }

    It 'yields empty for contradictory signals (classic + simplified:true)' {
        $proj = '{"key":"CONTRA","style":"classic","simplified":true}' | ConvertFrom-Json
        Get-JiraDiscoveryStyle $proj | Should -Be ''
    }

    It 'yields empty for contradictory signals (next-gen + simplified:false)' {
        $proj = '{"key":"CONTRA","style":"next-gen","simplified":false}' | ConvertFrom-Json
        Get-JiraDiscoveryStyle $proj | Should -Be ''
    }

    It 'still maps an unambiguous team-managed signal' {
        (Get-JiraDiscoveryStyle ('{"key":"TEAM","style":"next-gen","simplified":true}' | ConvertFrom-Json)) | Should -Be 'team_managed'
        (Get-JiraDiscoveryStyle ('{"key":"TEAM","simplified":true}' | ConvertFrom-Json)) | Should -Be 'team_managed'
        (Get-JiraDiscoveryStyle ('{"key":"TEAM","style":"next-gen"}' | ConvertFrom-Json)) | Should -Be 'team_managed'
    }

    It 'still maps an unambiguous company-managed signal' {
        (Get-JiraDiscoveryStyle ('{"key":"COMP","style":"classic","simplified":false}' | ConvertFrom-Json)) | Should -Be 'company_managed'
        (Get-JiraDiscoveryStyle ('{"key":"COMP","simplified":false}' | ConvertFrom-Json)) | Should -Be 'company_managed'
        (Get-JiraDiscoveryStyle ('{"key":"COMP","style":"classic"}' | ConvertFrom-Json)) | Should -Be 'company_managed'
    }

    It 'yields empty for an unknown style string with no simplified signal' {
        $proj = '{"key":"ODD","style":"something-new"}' | ConvertFrom-Json
        Get-JiraDiscoveryStyle $proj | Should -Be ''
    }
}
