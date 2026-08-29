# 024, T046/T047 — the request counter tells the truth on the PowerShell port
# too (mirror of tests/bash/sink/test_request_count.bats). `Get-JiraRequestCount`
# reads $script:JiraRequestCount inside Client.psm1; seven other sink modules
# each import Client.psm1 on their own, and a `-Force` import from ANY of them
# (Remove-Module + Import-Module) tears the counter out of whichever scope was
# using it and reattaches a fresh, zeroed one — the same defect class as
# project memory powershell-import-force-clobbers-caller-scope, just with
# seven origin sites instead of one. A single module's own Pester file
# (Client.Tests.ps1) cannot reproduce this: the bug only appears when a SECOND
# module that ALSO imports Client.psm1 is loaded in the same session, which is
# exactly what this file does.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Client.psm1')          # No -Force
    Import-Module (Join-Path $SinkDir 'DuplicateProbe.psm1')  # No -Force — imports Client.psm1 internally
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'
}

Describe 'the request counter is shared across every module that imports Client.psm1' {
    BeforeEach {
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
    }

    AfterEach {
        $env:JIRA_EMAIL = $null
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_NO_SLEEP = $null
        $env:SPEC_KIT_JIRA_BASE_URL = $null
    }

    It 'a request issued through DuplicateProbe.psm1 is visible to Get-JiraRequestCount, alongside a direct one' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        # 032, C6.4 — declare the destination the way production does. The
        # connection chokepoint sets this variable before any request; a suite
        # that drives the transport directly must stand in for it, or the
        # credential producer rightly refuses a destination nothing verified.
        $env:SPEC_KIT_JIRA_BASE_URL = $mock.BaseUrl
        try {
            $before = Get-JiraRequestCount
            Invoke-JiraRequest -Method GET -Url "$($mock.BaseUrl)/rest/api/3/project/COMP" | Out-Null
            Get-JiraDuplicateProbeResult -BaseUrl $mock.BaseUrl -ProjectKey 'COMP' -Label 'speckit-x' | Out-Null
            $after = Get-JiraRequestCount
            ($after - $before) | Should -Be 2
        } finally { Stop-JiraMock -Mock $mock }
    }
}
