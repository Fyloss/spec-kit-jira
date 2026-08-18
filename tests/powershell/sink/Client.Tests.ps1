# T022 — Sink REST-transport tests. Mirror of tests/bash/sink/test_client.bats.
# Retry/backoff honouring Retry-After on 429, exit-code mapping 2/3, and a
# credential-safe header — the same observable contract as the Bash port.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Client.psm1') -Force
    $MockDir = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $MockDir 'Mock.psm1') -Force
    $script:ConfigDir = Join-Path $MockDir 'configs'
}

Describe 'Jira REST transport' {
    BeforeEach {
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
        # Re-import -Force: resets Credentials.psm1's $script:-scoped credential
        # cache (021, US3) to 'unset' — Pester runs every It in one process, so
        # module scope has no per-test isolation otherwise (030, T043).
        Import-Module (Join-Path $SinkDir 'Client.psm1') -Force
    }

    AfterEach {
        $env:JIRA_EMAIL = $null
        $env:JIRA_API_TOKEN = $null
        $env:JIRA_NO_SLEEP = $null
        $env:JIRA_MAX_ATTEMPTS = $null
    }

    It 'GET returns exit code 0 and the response body on success' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $r = Invoke-JiraRequest -Method GET -Url "$($mock.BaseUrl)/rest/api/3/project/COMP"
            $r.ExitCode | Should -Be 0
            ($r.Body | ConvertFrom-Json).style | Should -Be 'classic'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'POST returns exit code 0 and the created-issue body (201)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $r = Invoke-JiraRequest -Method POST -Url "$($mock.BaseUrl)/rest/api/3/issue" -Body '{"fields":{}}'
            $r.ExitCode | Should -Be 0
            ($r.Body | ConvertFrom-Json).key | Should -Be 'COMP-1'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'T043 [030, C6.2/C6.3]: no credential resolvable maps to the auth exit code AND reports the reason, never silent' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $env:JIRA_API_TOKEN = $null
            $se = [System.IO.StringWriter]::new()
            $origErr = [Console]::Error
            [Console]::SetError($se)
            try {
                $r = Invoke-JiraRequest -Method GET -Url "$($mock.BaseUrl)/rest/api/3/project/COMP"
            } finally { [Console]::SetError($origErr) }
            $r.ExitCode | Should -Be 3
            $r.Body | Should -BeNullOrEmpty
            $se.ToString() | Should -Match 'credential resolution failed'
            $se.ToString() | Should -Match 'neither JIRA_API_TOKEN nor JIRA_PAT_COMMAND is set'
        } finally { Stop-JiraMock -Mock $mock }
    }

    It '401 maps to the auth exit code (3), zero body' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $r = Invoke-JiraRequest -Method GET -Url "$($mock.BaseUrl)/rest/api/3/project/AUTH"
            $r.ExitCode | Should -Be 3
            $r.Body | Should -BeNullOrEmpty
        } finally { Stop-JiraMock -Mock $mock }
    }

    It '404 maps to the fail-closed exit code (2), zero body' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $r = Invoke-JiraRequest -Method GET -Url "$($mock.BaseUrl)/rest/api/3/project/MISSING"
            $r.ExitCode | Should -Be 2
            $r.Body | Should -BeNullOrEmpty
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'a dropped connection (network fault) maps to fail-closed (2)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $r = Invoke-JiraRequest -Method GET -Url "$($mock.BaseUrl)/rest/api/3/project/NET"
            $r.ExitCode | Should -Be 2
        } finally { Stop-JiraMock -Mock $mock }
    }

    It '429 retries honouring Retry-After then exhausts to fail-closed (2)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'faults.json')
        try {
            $env:JIRA_MAX_ATTEMPTS = '3'
            $r = Invoke-JiraRequest -Method GET -Url "$($mock.BaseUrl)/rest/api/3/project/RATE"
            $r.ExitCode | Should -Be 2
            $calls = @(Get-JiraMockCallLog -Mock $mock) | Where-Object { $_ -match 'project/RATE' }
            $calls.Count | Should -Be 3
        } finally { Stop-JiraMock -Mock $mock }
    }

    It 'never emits the token on the verbose stream (NFR-3, SC-007)' {
        $mock = Start-JiraMock -ConfigPath (Join-Path $ConfigDir 'default.json')
        try {
            $tmp = New-TemporaryFile
            Invoke-JiraRequest -Method GET -Url "$($mock.BaseUrl)/rest/api/3/project/COMP" -Verbose 4> $tmp.FullName | Out-Null
            $trace = Get-Content -Raw $tmp.FullName -ErrorAction SilentlyContinue
            $trace | Should -Not -Match 'RAWSECRETXYZ'
            Remove-Item $tmp.FullName -Force
        } finally { Stop-JiraMock -Mock $mock }
    }
}
