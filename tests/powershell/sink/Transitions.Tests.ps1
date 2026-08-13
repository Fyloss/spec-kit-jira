# T035/T037/T039 [Phase 4, US1] — Transitions.psm1: one GET per due ticket
# (branch C, research R1), resolved by destination NAME alone (contracts/
# transition-resolution.md §3), never by category. Pester twin of
# tests/bash/sink/test_transitions.bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Transitions.psm1') -Force
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'
}

Describe 'Transitions' {
    BeforeEach {
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
        Reset-JiraTransitionsCache
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $script:ConfigDir 'story-transitions.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
    }

    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        $env:JIRA_EMAIL = $null
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_NO_SLEEP = $null
        $env:SPEC_KIT_JIRA_BASE_URL = $null
    }

    It 'one ungated candidate onto the declared step resolves to move' {
        Import-JiraTransitions -Key @('STORY-1') | Should -Be 0
        $record = Get-JiraTransitionRecord -Key 'STORY-1'
        $outcome = Resolve-JiraTransition -RecordJson $record -DeclaredStep 'In Progress' | ConvertFrom-Json
        $outcome.outcome | Should -Be 'move'
        $outcome.transition_id | Should -Be '11'
    }

    It 'two candidates landing on the declared step resolve to ambiguous, both named' {
        Import-JiraTransitions -Key @('STORY-2') | Should -Be 0
        $record = Get-JiraTransitionRecord -Key 'STORY-2'
        $outcome = Resolve-JiraTransition -RecordJson $record -DeclaredStep 'In Progress' | ConvertFrom-Json
        $outcome.outcome | Should -Be 'ambiguous'
        $outcome.candidates.Count | Should -Be 2
        (($outcome.candidates | ForEach-Object { $_.id }) | Sort-Object) -join ',' | Should -Be '21,22'
    }

    It 'the sole candidate gated by a required field resolves to gated, field named' {
        Import-JiraTransitions -Key @('STORY-3') | Should -Be 0
        $record = Get-JiraTransitionRecord -Key 'STORY-3'
        $outcome = Resolve-JiraTransition -RecordJson $record -DeclaredStep 'In Progress' | ConvertFrom-Json
        $outcome.outcome | Should -Be 'gated'
        $outcome.gated_field.logical_name | Should -Be 'Resolution'
        $outcome.gated_field.field_id | Should -Be 'resolution'
    }

    It 'no candidate onto the declared step resolves to unreachable, reachable set named' {
        Import-JiraTransitions -Key @('STORY-4') | Should -Be 0
        $record = Get-JiraTransitionRecord -Key 'STORY-4'
        $outcome = Resolve-JiraTransition -RecordJson $record -DeclaredStep 'In Progress' | ConvertFrom-Json
        $outcome.outcome | Should -Be 'unreachable'
        ($outcome.reachable -join ',') | Should -Be 'Done'
    }

    It 'the step comparison is exact string equality — case or spacing never accepted' {
        Import-JiraTransitions -Key @('STORY-1') | Should -Be 0
        $record = Get-JiraTransitionRecord -Key 'STORY-1'
        $outcome = Resolve-JiraTransition -RecordJson $record -DeclaredStep 'in progress' | ConvertFrom-Json
        $outcome.outcome | Should -Be 'unreachable'
    }

    It 'Get-JiraTransitionRecord matches the requested key case-insensitively' {
        Import-JiraTransitions -Key @('STORY-1') | Should -Be 0
        $record = Get-JiraTransitionRecord -Key 'story-1' | ConvertFrom-Json
        $record.key | Should -Be 'STORY-1'
    }

    It 'Get-JiraTransitionRecord on a miss returns $null' {
        Import-JiraTransitions -Key @('STORY-1') | Should -Be 0
        Get-JiraTransitionRecord -Key 'STORY-99' | Should -BeNullOrEmpty
    }

    It 'Import-JiraTransitions issues exactly one GET per key, none for a bulk endpoint' {
        Import-JiraTransitions -Key @('STORY-1', 'STORY-2') | Should -Be 0
        $calls = Get-JiraMockCallLog -Mock $script:Mock
        (@($calls | Where-Object { $_ -match '^GET /rest/api/3/issue/STORY-1/transitions' })).Count | Should -Be 1
        (@($calls | Where-Object { $_ -match '^GET /rest/api/3/issue/STORY-2/transitions' })).Count | Should -Be 1
        (@($calls | Where-Object { $_ -match 'bulkfetch' })).Count | Should -Be 0
    }

    It 'a read failure on any key fails closed, without reading remaining keys' {
        Stop-JiraMock -Mock $script:Mock
        $faults = [ordered]@{
            projects    = [ordered]@{ 'STORY' = 'company' }
            transitions = [ordered]@{ 'STORY-1' = @(@{ id = '11'; name = 'Start'; to = @{ name = 'In Progress' }; fields = @{} }) }
            faults      = [ordered]@{ 'issue/STORY-1/transitions' = @{ status = 500 } }
        }
        $faultsPath = Join-Path ([System.IO.Path]::GetTempPath()) "$([System.Guid]::NewGuid()).json"
        ($faults | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $faultsPath
        $script:Mock = Start-JiraMock -ConfigPath $faultsPath
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl

        $rc = Import-JiraTransitions -Key @('STORY-1', 'STORY-2')
        $rc | Should -Not -Be 0
        $calls = Get-JiraMockCallLog -Mock $script:Mock
        (@($calls | Where-Object { $_ -match '^GET /rest/api/3/issue/STORY-2/transitions' })).Count | Should -Be 0
    }
}
