# T026/T029/T031/T033/T035 [027] — Pester twin of test_adoption.bats.
# The resolution read (research R4/R5, contract seed-cli-contract.md §6).

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Adoption.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
}

Describe 'Invoke-JiraAdoptionLoad — budget (C-14)' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Reset-JiraAdoption
    }

    It '100 keys issue exactly 1 bulkfetch' {
        $issues = @{}
        1..100 | ForEach-Object { $issues["PROJ-$_"] = @{ summary = "S$_"; description = 'desc'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } } }
        $cfg = Write-JiraMockConfig -Json (@{ issues = $issues } | ConvertTo-Json -Depth 10 -Compress)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $keys = 1..100 | ForEach-Object { "PROJ-$_" }
        $rc = Invoke-JiraAdoptionLoad -Keys $keys
        $rc | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'POST /rest/api/3/issue/bulkfetch' }).Count | Should -Be 1
    }

    It '101 keys issue exactly 2 bulkfetch requests' {
        $issues = @{}
        1..101 | ForEach-Object { $issues["PROJ-$_"] = @{ summary = "S$_"; description = 'desc'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } } }
        $cfg = Write-JiraMockConfig -Json (@{ issues = $issues } | ConvertTo-Json -Depth 10 -Compress)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $keys = 1..101 | ForEach-Object { "PROJ-$_" }
        $rc = Invoke-JiraAdoptionLoad -Keys $keys
        $rc | Should -Be 0
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'POST /rest/api/3/issue/bulkfetch' }).Count | Should -Be 2
    }
}

Describe 'Fail-closed posture (research R4)' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Reset-JiraAdoption
    }

    It 'a non-2xx bulkfetch response is fail-closed' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S"}},"fault":{"status":500}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $rc = Invoke-JiraAdoptionLoad -Keys @('PROJ-1')
        $rc | Should -Not -Be 0
    }
}

Describe 'Get-JiraAdoption' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Reset-JiraAdoption
    }

    It 'returns the resolved issue fields and marker' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"Parent Epic","description":"desc","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"id":"10001","name":"Epic"},"project":{"key":"PROJ"},"properties":{"spec-kit-jira":{"origin":"human"}}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1') | Out-Null
        $r = Get-JiraAdoption -Key 'PROJ-1' | ConvertFrom-Json
        $r.fields.summary | Should -Be 'Parent Epic'
        $r.fields.issuetype.name | Should -Be 'Epic'
        $r.marker.origin | Should -Be 'human'
    }

    It 'is case-insensitive on the key' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S"}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1') | Out-Null
        $r = Get-JiraAdoption -Key 'proj-1' | ConvertFrom-Json
        $r.fields.summary | Should -Be 'S'
    }

    It 'returns $null on a miss' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S"}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1') | Out-Null
        Get-JiraAdoption -Key 'PROJ-999' | Should -BeNullOrEmpty
    }
}

Describe 'Test-JiraAdoptionEvaluate — the seven state-dependent refusal classes' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Reset-JiraAdoption
    }

    It 'REF-UNRESOLVED: a designated key absent from the read' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S"}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1', 'PROJ-999') | Out-Null
        $r = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'PROJ-999' -DeclaredType 'Story' -TerminalStatusesCsv '' -SpecRefJson '' | ConvertFrom-Json
        $r.code | Should -Be 'REF-UNRESOLVED'
        $r.message | Should -Not -Match 'deleted'
    }

    It 'REF-ROLE: type does not match the declared role' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S","issuetype":{"id":"1","name":"Bug"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1') | Out-Null
        $r = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'PROJ-1' -DeclaredType 'Story' -TerminalStatusesCsv '' -SpecRefJson '' | ConvertFrom-Json
        $r.code | Should -Be 'REF-ROLE'
    }

    It 'REF-ROUTING: project differs from the routed project' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"OTHER-1":{"summary":"S","issuetype":{"id":"1","name":"Story"},"project":{"key":"OTHER"},"status":{"name":"To Do","statusCategory":{"key":"new"}}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('OTHER-1') | Out-Null
        $r = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'OTHER-1' -DeclaredType 'Story' -TerminalStatusesCsv '' -SpecRefJson '' | ConvertFrom-Json
        $r.code | Should -Be 'REF-ROUTING'
    }

    It 'REF-TERMINAL: issue in a configured terminal status' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"Done","statusCategory":{"key":"done"}}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1') | Out-Null
        $r = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'PROJ-1' -DeclaredType 'Story' -TerminalStatusesCsv 'Done' -SpecRefJson '' | ConvertFrom-Json
        $r.code | Should -Be 'REF-TERMINAL'
    }

    It 'REF-CLAIMED: identity marker for another spec' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}},"properties":{"spec-kit-jira":{"origin":"human","repo":"acme/app","spec_slug":"other-spec"}}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1') | Out-Null
        $r = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'PROJ-1' -DeclaredType 'Story' -TerminalStatusesCsv '' -SpecRefJson '{"repo":"acme/app","spec_slug":"this-spec"}' | ConvertFrom-Json
        $r.code | Should -Be 'REF-CLAIMED'
    }

    It 'REF-THIN: description is empty or whitespace-only' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S","description":"   ","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1') | Out-Null
        $r = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'PROJ-1' -DeclaredType 'Story' -TerminalStatusesCsv '' -SpecRefJson '' | ConvertFrom-Json
        $r.code | Should -Be 'REF-THIN'
    }

    It 'REF-MULTIPROJECT: named stories span more than one project' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S","project":{"key":"PROJ"}},"OTHER-1":{"summary":"S","project":{"key":"OTHER"}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1', 'OTHER-1') | Out-Null
        $r = Get-JiraAdoptionMultiprojectViolation -StoryKeysJson '["PROJ-1","OTHER-1"]' | ConvertFrom-Json
        @($r).Count | Should -Be 2
    }

    It 'a fully valid named issue evaluates clean' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-1":{"summary":"S","description":"real content","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1') | Out-Null
        $r = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'PROJ-1' -DeclaredType 'Story' -TerminalStatusesCsv '' -SpecRefJson '' | ConvertFrom-Json
        $r.code | Should -Be ''
    }
}

Describe 'C-4: refusals aggregated together' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Reset-JiraAdoption
    }

    It 'three mistyped designators are reported together' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-1', 'PROJ-2', 'PROJ-3') | Out-Null
        $r1 = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'PROJ-1' -DeclaredType 'Story' -TerminalStatusesCsv '' -SpecRefJson ''
        $r2 = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'PROJ-2' -DeclaredType 'Story' -TerminalStatusesCsv '' -SpecRefJson ''
        $r3 = Test-JiraAdoptionEvaluate -RoutedProject 'PROJ' -Role 'story' -Key 'PROJ-3' -DeclaredType 'Story' -TerminalStatusesCsv '' -SpecRefJson ''
        $agg = Get-JiraAdoptionAggregateRefusals -Items "[$r1,$r2,$r3]" | ConvertFrom-Json
        @($agg).Count | Should -Be 3
    }
}

Describe 'T035: current parent summary/status fold into the same bulkfetch' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Reset-JiraAdoption
    }

    It 'arrives with no extra request' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-99":{"summary":"Legacy epic","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"issuetype":{"id":"1","name":"Epic"},"project":{"key":"PROJ"}},"PROJ-11":{"summary":"Story","description":"real content","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}},"parent":{"key":"PROJ-99"}}}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Invoke-JiraAdoptionLoad -Keys @('PROJ-11') | Out-Null
        $r = Get-JiraAdoption -Key 'PROJ-11' | ConvertFrom-Json
        $r.fields.parent.fields.summary | Should -Be 'Legacy epic'
        $r.fields.parent.fields.status.name | Should -Be 'In Progress'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'POST /rest/api/3/issue/bulkfetch' }).Count | Should -Be 1
    }
}
