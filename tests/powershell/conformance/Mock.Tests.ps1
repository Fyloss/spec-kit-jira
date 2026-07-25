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
