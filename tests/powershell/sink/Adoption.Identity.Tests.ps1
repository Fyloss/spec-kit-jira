# T038 [US1] — Adoption claim reads, PowerShell side. Mirror of
# tests/bash/sink/test_adoption_identity.bats (003 data-model §4, FR-020).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Adoption.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $script:Candidates = @'
[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-a"],"parent_key":null,"identity":null},
 {"key":"ADO-3","project_key":"ADO","labels":["speckit-adopt:004-b"],"parent_key":null,"identity":null}]
'@
    function Start-WithJson([string] $Json) {
        $script:Mock = Start-JiraMock -ConfigJson $Json
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
    }
}

Describe 'Get-JiraAdoptionCandidateIdentity' {
    # Pester forbids a teardown at the container root; it belongs to the block.
    AfterEach {
        if ($script:Mock) { Stop-JiraMock -Mock $script:Mock; $script:Mock = $null }
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'performs one identity read per candidate' {
        Start-WithJson '{"projects":{"ADO":"company"}}'
        (Get-JiraAdoptionCandidateIdentity -CandidatesJson $Candidates).ExitCode | Should -Be 0
        $log = Get-JiraMockCallLog -Mock $script:Mock
        @($log | Where-Object { $_ -like 'GET /rest/api/3/issue/*/properties/spec-kit-jira' }).Count | Should -Be 2
    }

    It 'treats a 404 as unclaimed, not a failure' {
        Start-WithJson '{"projects":{"ADO":"company"}}'
        $r = Get-JiraAdoptionCandidateIdentity -CandidatesJson $Candidates
        $r.ExitCode | Should -Be 0
        @($r.Json | ConvertFrom-Json | Where-Object { $null -eq $_.identity }).Count | Should -Be 2
    }

    It 'surfaces a stored marker onto the candidate' {
        Start-WithJson '{"projects":{"ADO":"company"},"identity":{"ADO-3":{"origin":"human","repo":"acme/app","spec_slug":"004-billing-export"}}}'
        $c = (Get-JiraAdoptionCandidateIdentity -CandidatesJson $Candidates).Json | ConvertFrom-Json
        (@($c | Where-Object { $_.key -eq 'ADO-1' })[0]).identity | Should -BeNullOrEmpty
        $m = (@($c | Where-Object { $_.key -eq 'ADO-3' })[0]).identity
        $m.origin | Should -Be 'human'
        $m.repo | Should -Be 'acme/app'
        $m.spec_slug | Should -Be '004-billing-export'
    }

    It 'keeps the discovered context through the claim read' {
        Start-WithJson '{"projects":{"ADO":"company"}}'
        $c = (Get-JiraAdoptionCandidateIdentity -CandidatesJson `
                '[{"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-a:us1"],"parent_key":"ADO-1","identity":null}]').Json | ConvertFrom-Json
        @($c)[0].parent_key | Should -Be 'ADO-1'
        @($c)[0].labels[0] | Should -Be 'speckit-adopt:003-a:us1'
    }

    It 'performs no read at all for an empty candidate list' {
        Start-WithJson '{"projects":{"ADO":"company"}}'
        $r = Get-JiraAdoptionCandidateIdentity -CandidatesJson '[]'
        $r.ExitCode | Should -Be 0
        $r.Json | Should -Be '[]'
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'propagates an authentication failure as exit 3 with zero writes' {
        Start-WithJson '{"projects":{"ADO":"company"},"faults":{"ADO":{"status":401}}}'
        (Get-JiraAdoptionCandidateIdentity -CandidatesJson $Candidates).ExitCode | Should -Be 3
        @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'PUT *' }).Count | Should -Be 0
    }

    It 'propagates a network failure as exit 2 with zero writes' {
        Start-WithJson '{"projects":{"ADO":"company"},"faults":{"ADO":{"network":true}}}'
        (Get-JiraAdoptionCandidateIdentity -CandidatesJson $Candidates).ExitCode | Should -Be 2
        @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'PUT *' }).Count | Should -Be 0
    }
}
