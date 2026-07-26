# T020 [US2] — Accessible-projects listing (FR-004c). Pester twin of
# tests/bash/sink/test_discovery_list_projects.bats: Get-JiraDiscoveryProjectList
# paginates GET /project/search, maps key/name/style (three-valued, null when
# ambiguous) into one canonical array, and fails closed on zero results.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Discovery.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Start-TestMock {
        param([string]$ConfigJson)
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, $ConfigJson)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
}

Describe 'Get-JiraDiscoveryProjectList' {
    AfterEach { if ($M) { Stop-JiraMock -Mock $M; $script:M = $null } }

    It 'lists accessible projects with key, name, and mapped style' {
        Start-TestMock '{"projects":{"COMP":"company","TEAM":"team"}}'
        $r = Get-JiraDiscoveryProjectList
        $r.ExitCode | Should -Be 0
        $list = $r.List | ConvertFrom-Json
        @($list).Count | Should -Be 2
        $list[0].key | Should -Be 'COMP'
        $list[0].name | Should -Be 'COMP project'
        $list[0].style | Should -Be 'company_managed'
        $list[1].style | Should -Be 'team_managed'
    }

    It 'maps an ambiguous project to style null' {
        Start-TestMock '{"projects":{"AMBI":"ambiguous"}}'
        $r = Get-JiraDiscoveryProjectList
        $r.ExitCode | Should -Be 0
        ($r.List | ConvertFrom-Json)[0].style | Should -Be $null
    }

    It 'walks every page of a paginated result' {
        Start-TestMock '{"projects":{"AAA":"company","BBB":"team","CCC":"company"},"pageSize":2}'
        $r = Get-JiraDiscoveryProjectList
        $r.ExitCode | Should -Be 0
        @($r.List | ConvertFrom-Json).Count | Should -Be 3
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ -match 'project/search' }).Count | Should -Be 2
    }

    It 'fails closed on zero visible projects' {
        Start-TestMock '{"projects":{}}'
        $r = Get-JiraDiscoveryProjectList
        $r.ExitCode | Should -Be 2
        $r.List | Should -Be ''
    }
}
