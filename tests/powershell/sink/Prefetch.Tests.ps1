# T048 — sink/jira/Prefetch.psm1: recognition prefetch, contracts/recognition-prefetch.md.
# Mirror of tests/bash/sink/test_prefetch.bats. Cross-port parity is proven
# in the differential conformance scenarios (T049-T052).

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Prefetch.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function New-JiraPrefetchSeedConfig([string] $IssuesJson) {
        $path = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        @"
{"issues": $IssuesJson}
"@ | Set-Content -NoNewline -Path $path
        return $path
    }

    function New-JiraPrefetchFaultConfig([string] $IssuesJson, [string] $FaultsJson) {
        $path = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        @"
{"issues": $IssuesJson, "faults": $FaultsJson}
"@ | Set-Content -NoNewline -Path $path
        return $path
    }
}

Describe 'Invoke-JiraPrefetchLoad / Get-JiraPrefetch' {
    AfterEach {
        Reset-JiraPrefetch
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'populates the map; Get-JiraPrefetch returns the canonical shape for a hit' {
        $cfg = New-JiraPrefetchSeedConfig '{"COMP-1": {"summary": "S1", "properties": {"spec-kit-jira": {"story":"aaaa"}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraPrefetchLoad -Keys @('COMP-1')
        $out = Get-JiraPrefetch -Key 'COMP-1' -FieldsCsv 'summary' | ConvertFrom-Json
        $out.gone | Should -Be $false
        $out.marker.story | Should -Be 'aaaa'
        $out.fields.summary | Should -Be 'S1'
    }

    It 'returns $null on a miss' {
        $cfg = New-JiraPrefetchSeedConfig '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraPrefetchLoad -Keys @('COMP-1')
        Get-JiraPrefetch -Key 'COMP-1' -FieldsCsv 'summary' | Should -BeNullOrEmpty
    }

    It "field projection yields exactly the caller's field set - no more, no less" {
        $cfg = New-JiraPrefetchSeedConfig '{"COMP-1": {"summary": "S1", "priority": {"name":"High"}, "properties": {}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraPrefetchLoad -Keys @('COMP-1')
        $out = Get-JiraPrefetch -Key 'COMP-1' -FieldsCsv 'summary,priority' | ConvertFrom-Json
        ($out.fields.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'priority,summary'
    }

    It 'matches keys case-insensitively' {
        $cfg = New-JiraPrefetchSeedConfig '{"COMP-1": {"summary": "S1", "properties": {}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraPrefetchLoad -Keys @('comp-1')
        $out = Get-JiraPrefetch -Key 'COMP-1' -FieldsCsv 'summary' | ConvertFrom-Json
        $out.fields.summary | Should -Be 'S1'
    }

    It 'a returned key is matched by value, never by position' {
        # State insertion order is COMP-1 then COMP-2, so the mock's bulkfetch
        # response returns COMP-1 first - the OPPOSITE of this request's order.
        # A positional matcher would hand COMP-2's data back for the key "COMP-1".
        $cfg = New-JiraPrefetchSeedConfig '{"COMP-1": {"summary": "first", "properties": {}}, "COMP-2": {"summary": "second", "properties": {}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraPrefetchLoad -Keys @('COMP-2', 'COMP-1')
        (Get-JiraPrefetch -Key 'COMP-1' -FieldsCsv 'summary' | ConvertFrom-Json).fields.summary | Should -Be 'first'
        (Get-JiraPrefetch -Key 'COMP-2' -FieldsCsv 'summary' | ConvertFrom-Json).fields.summary | Should -Be 'second'
    }

    It 'chunks at 100: 101 keys issue exactly 2 bulkfetch requests' {
        $issuesObj = @{}
        1..101 | ForEach-Object { $issuesObj["COMP-$_"] = @{ summary = 'S'; properties = @{} } }
        $cfg = New-JiraPrefetchSeedConfig ($issuesObj | ConvertTo-Json -Depth 5 -Compress)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $keys = 1..101 | ForEach-Object { "COMP-$_" }
        Invoke-JiraPrefetchLoad -Keys $keys
        $calls = Get-JiraMockCallLog -Mock $script:M
        ($calls | Select-String -Pattern 'issue/bulkfetch').Count | Should -Be 2
        Get-JiraPrefetch -Key 'COMP-1' -FieldsCsv 'summary' | Should -Not -BeNullOrEmpty
        Get-JiraPrefetch -Key 'COMP-101' -FieldsCsv 'summary' | Should -Not -BeNullOrEmpty
    }

    It 'a non-2xx bulkfetch response empties the map and still succeeds' {
        $cfg = New-JiraPrefetchFaultConfig '{"COMP-1": {"summary": "S1", "properties": {}}}' '{"issue/bulkfetch": {"status": 400}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        { Invoke-JiraPrefetchLoad -Keys @('COMP-1') } | Should -Not -Throw
        Get-JiraPrefetch -Key 'COMP-1' -FieldsCsv 'summary' | Should -BeNullOrEmpty
    }

    It 'zero recorded keys: issues zero requests' {
        $cfg = New-JiraPrefetchSeedConfig '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraPrefetchLoad -Keys @()
        $calls = Get-JiraMockCallLog -Mock $script:M
        ($calls | Select-String -Pattern 'issue/bulkfetch').Count | Should -Be 0
    }

    It 'Reset-JiraPrefetch empties the map' {
        $cfg = New-JiraPrefetchSeedConfig '{"COMP-1": {"summary": "S1", "properties": {}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraPrefetchLoad -Keys @('COMP-1')
        Reset-JiraPrefetch
        Get-JiraPrefetch -Key 'COMP-1' -FieldsCsv 'summary' | Should -BeNullOrEmpty
    }

    It 'a deleted key (absent from the store) is simply a miss, never gone:true' {
        $cfg = New-JiraPrefetchSeedConfig '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraPrefetchLoad -Keys @('COMP-404')
        Get-JiraPrefetch -Key 'COMP-404' -FieldsCsv 'summary' | Should -BeNullOrEmpty
    }

    It 'a forbidden key (faulted on its own per-key path) is simply a miss' {
        $cfg = New-JiraPrefetchFaultConfig '{"COMP-1": {"summary": "S1", "properties": {}}, "COMP-2": {"summary": "S2", "properties": {}}}' '{"issue/COMP-2": {"status": 403}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraPrefetchLoad -Keys @('COMP-1', 'COMP-2')
        Get-JiraPrefetch -Key 'COMP-1' -FieldsCsv 'summary' | Should -Not -BeNullOrEmpty
        Get-JiraPrefetch -Key 'COMP-2' -FieldsCsv 'summary' | Should -BeNullOrEmpty
    }
}
