# T036 [US1] — Adoption candidate discovery, PowerShell side. Mirror of
# tests/bash/sink/test_adoption_search.bats (003 research §1/§2, FR-004, NFR-6).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Adoption.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $script:ConfigDir = Join-Path $Root 'tests/conformance/mock-jira/configs'
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    $script:SingleProject = @'
[{"spec_folder":"003-label-based-adoption","level":"feature","story_ordinal":null,
  "project_key":"ADO","labels":["speckit-adopt:003-label-based-adoption","speckit-adopt:003"],
  "probe_labels":[],"short_conflict":null},
 {"spec_folder":"003-label-based-adoption","level":"story","story_ordinal":1,
  "project_key":"ADO","labels":["speckit-adopt:003-label-based-adoption:us1"],
  "probe_labels":[],"short_conflict":null}]
'@
}

Describe 'Get-JiraAdoptionCandidate' {
    BeforeEach {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'adoption.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'names the project and the labels in the JQL and asks for the three fields only' {
        (Get-JiraAdoptionCandidate -TargetsJson $SingleProject).ExitCode | Should -Be 0
        $calls = (Get-JiraMockCallLog -Mock $script:Mock) -join "`n"
        $calls | Should -BeLike '*GET /rest/api/3/search/jql?jql=*'
        $calls | Should -BeLike '*project+%3D+%22ADO%22*'
        $calls | Should -BeLike '*labels+IN+*'
        $calls | Should -BeLike '*fields=labels,parent,project*'
        $calls | Should -BeLike '*maxResults=100*'
    }

    It 'issues one query per DISTINCT routed project, not one per spec folder (FR-004)' {
        $targets = @'
[{"spec_folder":"a","level":"feature","story_ordinal":null,"project_key":"ADO","labels":["speckit-adopt:003-label-based-adoption"],"probe_labels":[],"short_conflict":null},
 {"spec_folder":"b","level":"feature","story_ordinal":null,"project_key":"ADO","labels":["speckit-adopt:004-billing-export"],"probe_labels":[],"short_conflict":null},
 {"spec_folder":"c","level":"feature","story_ordinal":null,"project_key":"BILL","labels":["speckit-adopt:005-audit-trail"],"probe_labels":[],"short_conflict":null}]
'@
        $r = Get-JiraAdoptionCandidate -TargetsJson $targets
        $r.ExitCode | Should -Be 0
        @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'GET /rest/api/3/search/jql*' }).Count | Should -Be 2
        (@($r.Json | ConvertFrom-Json | ForEach-Object { $_.key }) -join ',') | Should -Be 'ADO-1,ADO-3,BILL-4'
    }

    It 'still probes a suppressed short label so its ambiguity stays reportable' {
        $targets = @'
[{"spec_folder":"004-beta","level":"feature","story_ordinal":null,"project_key":"ADO",
  "labels":["speckit-adopt:004-beta"],"probe_labels":["speckit-adopt:004"],
  "short_conflict":{"label":"speckit-adopt:004","folders":["004-beta","004-gamma"]}}]
'@
        (Get-JiraAdoptionCandidate -TargetsJson $targets).ExitCode | Should -Be 0
        ((Get-JiraMockCallLog -Mock $script:Mock) -join "`n") | Should -BeLike '*speckit-adopt%3A004%22*'
    }

    It 'carries key, project, labels and parent, and no identity yet' {
        $c = (Get-JiraAdoptionCandidate -TargetsJson $SingleProject).Json | ConvertFrom-Json
        $story = @($c | Where-Object { $_.key -eq 'ADO-2' })[0]
        $story.project_key | Should -Be 'ADO'
        $story.parent_key | Should -Be 'ADO-1'
        @($story.labels)[0] | Should -Be 'speckit-adopt:003-label-based-adoption:us1'
        $story.identity | Should -BeNullOrEmpty
        (@($c | Where-Object { $_.key -eq 'ADO-1' })[0]).parent_key | Should -BeNullOrEmpty
    }

    It 'returns an empty list, not an error, when a label matches nothing' {
        $targets = '[{"spec_folder":"009-absent","level":"feature","story_ordinal":null,"project_key":"ADO","labels":["speckit-adopt:009-absent"],"probe_labels":[],"short_conflict":null}]'
        $r = Get-JiraAdoptionCandidate -TargetsJson $targets
        $r.ExitCode | Should -Be 0
        $r.Json | Should -Be '[]'
    }
}

Describe 'Pagination to exhaustion (NFR-6)' {
    BeforeEach {
        $script:Mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'adoption-paged.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
        $script:Targets = '[{"spec_folder":"003-label-based-adoption","level":"feature","story_ordinal":null,"project_key":"ADO","labels":["speckit-adopt:003-label-based-adoption"],"probe_labels":[],"short_conflict":null}]'
    }
    AfterEach {
        Stop-JiraMock -Mock $script:Mock
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'loops on nextPageToken so no candidate is silently dropped' {
        $r = Get-JiraAdoptionCandidate -TargetsJson $script:Targets
        $r.ExitCode | Should -Be 0
        $keys = @($r.Json | ConvertFrom-Json | ForEach-Object { $_.key })
        $keys.Count | Should -Be 5
        ($keys -join ',') | Should -Be 'ADO-1,ADO-2,ADO-3,ADO-4,ADO-5'
        $log = Get-JiraMockCallLog -Mock $script:Mock
        @($log | Where-Object { $_ -like 'GET /rest/api/3/search/jql*' }).Count | Should -Be 3
        @($log | Where-Object { $_ -like '*nextPageToken=*' }).Count | Should -Be 2
    }
}

Describe 'Fail-closed discovery' {
    It 'treats an unset site as a fail-closed read before any query (exit 2)' {
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        (Get-JiraAdoptionCandidate -TargetsJson $SingleProject).ExitCode | Should -Be 2
    }
}
