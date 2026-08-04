# T081 (012, US5) — mirror of tests/bash/sink/test_discovery_transitions.bats.
# Get-JiraDiscoveryTaskTransitionResult selects a destination by statusCategory
# alone (FR-030): no status name is ever assumed or hard-coded, in either
# direction.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Discovery.psm1') -Force
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'
}

Describe 'Get-JiraDiscoveryTaskTransitionResult' {
    BeforeEach {
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $script:ConfigDir 'task-transitions.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterEach {
        $env:JIRA_EMAIL = $null
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_NO_SLEEP = $null
        $env:SPEC_KIT_JIRA_BASE_URL = $null
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'selects the sole done-category destination as the transition' {
        $t = (Get-JiraDiscoveryTaskTransitionResult -IssueKey 'TASKS-1' -Direction 'forward').Transition | ConvertFrom-Json -Depth 100
        $t.transition_id | Should -Be '31'
        $t.withheld_field | Should -BeNullOrEmpty
        @($t.candidates).Count | Should -Be 1
    }

    It 'selects nothing and reports zero candidates when no destination is done-category' {
        $t = (Get-JiraDiscoveryTaskTransitionResult -IssueKey 'TASKS-2' -Direction 'forward').Transition | ConvertFrom-Json -Depth 100
        $t.transition_id | Should -BeNullOrEmpty
        @($t.candidates).Count | Should -Be 0
    }

    It 'selects nothing and reports both candidates when two or more are done-category' {
        $t = (Get-JiraDiscoveryTaskTransitionResult -IssueKey 'TASKS-3' -Direction 'forward').Transition | ConvertFrom-Json -Depth 100
        $t.transition_id | Should -BeNullOrEmpty
        @($t.candidates).Count | Should -Be 2
        (@($t.candidates.name) | Sort-Object) -join ',' | Should -Be 'Annulé,Fait'
    }

    It 'withholds and names the sole destination gated by a required field, never sent' {
        $t = (Get-JiraDiscoveryTaskTransitionResult -IssueKey 'TASKS-4' -Direction 'forward').Transition | ConvertFrom-Json -Depth 100
        $t.transition_id | Should -BeNullOrEmpty
        $t.withheld_field.logical_name | Should -Be 'Résolution'
        $t.withheld_field.field_id | Should -Be 'resolution'
    }

    It 'backward direction selects the not-done destination, for operator-authorised reverts' {
        $t = (Get-JiraDiscoveryTaskTransitionResult -IssueKey 'TASKS-2' -Direction 'backward').Transition | ConvertFrom-Json -Depth 100
        $t.transition_id | Should -Be '21'
    }

    It 'has no not-done candidate backward when the task is already at a done-category destination' {
        $t = (Get-JiraDiscoveryTaskTransitionResult -IssueKey 'TASKS-1' -Direction 'backward').Transition | ConvertFrom-Json -Depth 100
        $t.transition_id | Should -BeNullOrEmpty
        @($t.candidates).Count | Should -Be 0
    }
}
