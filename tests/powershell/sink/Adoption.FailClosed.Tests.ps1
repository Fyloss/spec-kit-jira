# T083 [US2] — Fail-closed discovery, PowerShell side. Mirror of
# tests/bash/sink/test_adoption_fail_closed.bats (003 FR-008, Constitution III).
#
# Any unreliable read during discovery aborts the WHOLE run before any write:
# 401/403 -> 3, and 404 / network error / exhausted 429 -> 2. The abort is not
# "skip this binding": a partially-read corpus turns a two-candidate ambiguity
# into a one-candidate binding and would stamp identity onto the wrong ticket.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Adoption.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $script:Targets = @'
[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"project_key":"ADO",
  "labels":["speckit-adopt:003-alpha"],"probe_labels":[],"short_conflict":null}]
'@
    $script:Candidates = '[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'

    function Start-Faulted { param([string] $Json)
        $script:Mock = Start-JiraMock -ConfigJson $Json
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
    }
    function Get-PutCount {
        return @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'PUT *' }).Count
    }
}

Describe 'a fault during the label search aborts the run' {
    AfterEach {
        if ($script:Mock) { Stop-JiraMock -Mock $script:Mock; $script:Mock = $null }
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'maps <Label> to exit <Code> with zero writes' -TestCases @(
        @{ Label = '401'; Fault = '{"status":401}'; Code = 3 }
        @{ Label = '403'; Fault = '{"status":403}'; Code = 3 }
        @{ Label = '404'; Fault = '{"status":404}'; Code = 2 }
        @{ Label = 'a dropped connection'; Fault = '{"network":true}'; Code = 2 }
        @{ Label = 'an exhausted 429'; Fault = '{"status":429,"retryAfter":1}'; Code = 2 }
    ) {
        param($Label, $Fault, $Code)
        Start-Faulted "{`"projects`":{`"ADO`":`"company`"},`"fault`":$Fault}"
        $r = Get-JiraAdoptionCandidate -TargetsJson $script:Targets
        $r.ExitCode | Should -Be $Code
        Get-PutCount | Should -Be 0
    }

    It 'emits nothing when the search fails (no partial candidate list)' {
        Start-Faulted '{"projects":{"ADO":"company"},"fault":{"status":404}}'
        $r = Get-JiraAdoptionCandidate -TargetsJson $script:Targets
        $r.ExitCode | Should -Be 2
        $r.Json | Should -Be ''
    }

    It 'retries a 429 up to the bounded budget before giving up' {
        Start-Faulted '{"projects":{"ADO":"company"},"fault":{"status":429,"retryAfter":1}}'
        $env:JIRA_MAX_ATTEMPTS = '3'
        try {
            (Get-JiraAdoptionCandidate -TargetsJson $script:Targets).ExitCode | Should -Be 2
            @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'GET /rest/api/3/search/jql*' }).Count | Should -Be 3
        }
        finally { Remove-Item env:JIRA_MAX_ATTEMPTS -ErrorAction SilentlyContinue }
    }
}

Describe 'a fault during a claim read aborts the run' {
    AfterEach {
        if ($script:Mock) { Stop-JiraMock -Mock $script:Mock; $script:Mock = $null }
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'maps 401 to exit 3 with zero writes' {
        Start-Faulted '{"projects":{"ADO":"company"},"fault":{"status":401}}'
        (Get-JiraAdoptionCandidateIdentity -CandidatesJson $script:Candidates).ExitCode | Should -Be 3
        Get-PutCount | Should -Be 0
    }

    It 'maps a dropped connection to exit 2 with zero writes' {
        Start-Faulted '{"projects":{"ADO":"company"},"fault":{"network":true}}'
        (Get-JiraAdoptionCandidateIdentity -CandidatesJson $script:Candidates).ExitCode | Should -Be 2
        Get-PutCount | Should -Be 0
    }

    It 'does NOT treat a 404 as a failure — it means unclaimed' {
        Start-Faulted '{"projects":{"ADO":"company"}}'
        $r = Get-JiraAdoptionCandidateIdentity -CandidatesJson $script:Candidates
        $r.ExitCode | Should -Be 0
        (@($r.Json | ConvertFrom-Json))[0].identity | Should -BeNullOrEmpty
    }

    It 'aborts immediately, leaving later candidates unread' {
        Start-Faulted '{"projects":{"ADO":"company"},"faults":{"ADO-2":{"status":401}}}'
        $many = @'
[{"key":"ADO-1","project_key":"ADO","labels":[],"parent_key":null,"identity":null},
 {"key":"ADO-2","project_key":"ADO","labels":[],"parent_key":null,"identity":null},
 {"key":"ADO-3","project_key":"ADO","labels":[],"parent_key":null,"identity":null}]
'@
        (Get-JiraAdoptionCandidateIdentity -CandidatesJson $many).ExitCode | Should -Be 3
        Get-PutCount | Should -Be 0
        @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like '*ADO-3*' }).Count | Should -Be 0
    }
}
