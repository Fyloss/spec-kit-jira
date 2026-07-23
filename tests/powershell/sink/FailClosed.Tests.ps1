# T067 [US6] — Fail-closed writes, PowerShell side. Mirror of
# tests/bash/sink/test_fail_closed.bats. An unreliable Jira endpoint causes zero
# applied writes for the spec and a documented, monotonic exit code (auth 3, else
# fail-closed 2); a fault aborts the remaining writes. Cross-port code agreement
# is proven in bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../.specify/extensions/jira/scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PlanApply.psm1') -Force
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'

    function New-Put([string] $BaseUrl, [string] $Key) {
        return ([ordered]@{ method = 'PUT'; url = "$BaseUrl/rest/api/3/issue/$Key"; body = [ordered]@{ fields = [ordered]@{ summary = 'x' } } })
    }
}

Describe 'Fail-closed writes' {
    BeforeEach {
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
    }
    AfterEach {
        $env:JIRA_EMAIL = $null
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_NO_SLEEP = $null
        $env:JIRA_MAX_ATTEMPTS = $null
    }

    It 'a 401 write fails closed with the auth exit code (3)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $actions = ConvertTo-Json -InputObject @((New-Put $mock.BaseUrl 'AUTH-1')) -Depth 10
            Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 3
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'a 404 write fails closed (2)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $actions = ConvertTo-Json -InputObject @((New-Put $mock.BaseUrl 'MISSING-1')) -Depth 10
            Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 2
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'a dropped connection fails closed (2)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $actions = ConvertTo-Json -InputObject @((New-Put $mock.BaseUrl 'NET-1')) -Depth 10
            Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 2
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'an exhausted 429 fails closed (2)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $env:JIRA_MAX_ATTEMPTS = '3'
            $actions = ConvertTo-Json -InputObject @((New-Put $mock.BaseUrl 'RATE-1')) -Depth 10
            Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 2
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'a fault aborts the remaining writes — the second action is never attempted' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $actions = ConvertTo-Json -InputObject @((New-Put $mock.BaseUrl 'AUTH-1'), (New-Put $mock.BaseUrl 'COMP-9')) -Depth 10
            Invoke-JiraApplyWriteSet -ActionsJson $actions | Should -Be 3
            $calls = @(Get-JiraMockCallLog -Mock $mock)
            (@($calls | Where-Object { $_ -match 'issue/AUTH-1' }).Count) | Should -Be 1
            (@($calls | Where-Object { $_ -match 'issue/COMP-9' }).Count) | Should -Be 0
        } finally { Stop-JiraMock -Mock $mock }
    }
}
