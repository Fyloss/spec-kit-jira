# T008 — Smoke tests for the mocked Jira double (PowerShell driver).
# Mirror of tests/bash/conformance/test_mock_double.bats.

BeforeAll {
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'
}

Describe 'Mocked Jira double' {
    It 'serves company-managed project discovery' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $r = Invoke-RestMethod -Uri "$($mock.BaseUrl)/rest/api/3/project/COMP"
            $r.style | Should -Be 'classic'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'serves team-managed project discovery down the next-gen path' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $r = Invoke-RestMethod -Uri "$($mock.BaseUrl)/rest/api/3/project/TEAM"
            $r.style | Should -Be 'next-gen'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'injects a 401 for the AUTH project' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $code = $null
            try { Invoke-RestMethod -Uri "$($mock.BaseUrl)/rest/api/3/project/AUTH" | Out-Null }
            catch { $code = [int]$_.Exception.Response.StatusCode }
            $code | Should -Be 401
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'injects a network fault by dropping the connection' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            { Invoke-RestMethod -Uri "$($mock.BaseUrl)/rest/api/3/project/NET" -TimeoutSec 5 } | Should -Throw
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'records the API call sequence' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            Invoke-RestMethod -Uri "$($mock.BaseUrl)/rest/api/3/project/COMP" | Out-Null
            (Get-JiraMockCallLog -Mock $mock) -join "`n" | Should -Match 'GET /rest/api/3/project/COMP'
        } finally { Stop-JiraMock -Mock $mock }
    }
}

Describe 'JQL-aware /search/jql (003 T023)' {
    BeforeAll {
        function Invoke-Jql {
            param([string] $BaseUrl, [string] $Jql, [string] $Token = '')
            $q = "jql=$([System.Uri]::EscapeDataString($Jql))&fields=labels,parent,project&maxResults=100"
            if ($Token) { $q += "&nextPageToken=$([System.Uri]::EscapeDataString($Token))" }
            return (Invoke-RestMethod -Uri "$BaseUrl/rest/api/3/search/jql?$q")
        }
    }

    It 'filters by the JQL project term' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'adoption.json')
        try {
            $r = Invoke-Jql -BaseUrl $mock.BaseUrl -Jql 'project = "BILL" AND labels IN ("speckit-adopt:005-audit-trail")'
            @($r.issues).Count | Should -Be 1
            @($r.issues)[0].key | Should -Be 'BILL-4'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'filters by the labels IN term and orders by key ascending' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'adoption.json')
        try {
            $r = Invoke-Jql -BaseUrl $mock.BaseUrl -Jql 'project = "ADO" AND labels IN ("speckit-adopt:003-label-based-adoption", "speckit-adopt:004-billing-export")'
            (@($r.issues) | ForEach-Object { $_.key }) -join ',' | Should -Be 'ADO-1,ADO-3'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'matches labels case-sensitively (research §3)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'adoption.json')
        try {
            $r = Invoke-Jql -BaseUrl $mock.BaseUrl -Jql 'project = "ADO" AND labels IN ("SPECKIT-ADOPT:003-label-based-adoption")'
            @($r.issues).Count | Should -Be 0
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'serves key, labels, parent and project only' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'adoption.json')
        try {
            $r = Invoke-Jql -BaseUrl $mock.BaseUrl -Jql 'project = "ADO" AND labels IN ("speckit-adopt:003-label-based-adoption:us1")'
            $issue = @($r.issues)[0]
            $issue.key | Should -Be 'ADO-2'
            $issue.fields.parent.key | Should -Be 'ADO-1'
            $issue.fields.project.key | Should -Be 'ADO'
            ($issue.fields.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'labels,parent,project'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'pages with nextPageToken and omits it on the last page (NFR-6)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'adoption-paged.json')
        try {
            $jql = 'project = "ADO" AND labels IN ("speckit-adopt:003-label-based-adoption")'
            $p1 = Invoke-Jql -BaseUrl $mock.BaseUrl -Jql $jql
            (@($p1.issues) | ForEach-Object { $_.key }) -join ',' | Should -Be 'ADO-1,ADO-2'
            $p1.isLast | Should -BeFalse

            $p2 = Invoke-Jql -BaseUrl $mock.BaseUrl -Jql $jql -Token $p1.nextPageToken
            (@($p2.issues) | ForEach-Object { $_.key }) -join ',' | Should -Be 'ADO-3,ADO-4'

            $p3 = Invoke-Jql -BaseUrl $mock.BaseUrl -Jql $jql -Token $p2.nextPageToken
            (@($p3.issues) | ForEach-Object { $_.key }) -join ',' | Should -Be 'ADO-5'
            $p3.PSObject.Properties.Name | Should -Not -Contain 'nextPageToken'
            $p3.isLast | Should -BeTrue
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'serves the seeded corpus context on a per-issue read (US4 pins)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'adoption.json')
        try {
            $r = Invoke-RestMethod -Uri "$($mock.BaseUrl)/rest/api/3/issue/ADO-2?fields=labels,parent,project"
            $r.fields.parent.key | Should -Be 'ADO-1'
            $r.fields.project.key | Should -Be 'ADO'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'returns 404 for a per-issue read of a key absent from the corpus' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'adoption.json')
        try {
            $code = $null
            try { Invoke-RestMethod -Uri "$($mock.BaseUrl)/rest/api/3/issue/ADO-404?fields=labels,parent,project" | Out-Null }
            catch { $code = [int]$_.Exception.Response.StatusCode }
            $code | Should -Be 404
        } finally { Stop-JiraMock -Mock $mock }
    }
}

Describe 'Corpus seeding through inline JSON (003 T028)' {
    It 'seeds an issues corpus from -ConfigJson without a config file' {
        $json = '{"projects":{"ADO":"company"},"issues":{"ADO-7":{"labels":["speckit-adopt:009-inline"]}}}'
        $mock = Start-JiraMock -ConfigJson $json
        try {
            $q = "jql=$([System.Uri]::EscapeDataString('project = "ADO" AND labels IN ("speckit-adopt:009-inline")'))"
            $r = Invoke-RestMethod -Uri "$($mock.BaseUrl)/rest/api/3/search/jql?$q"
            @($r.issues)[0].key | Should -Be 'ADO-7'
        } finally { Stop-JiraMock -Mock $mock }
    }
}
