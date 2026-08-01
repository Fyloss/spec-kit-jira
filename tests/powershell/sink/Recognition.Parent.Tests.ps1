# T054/T055/T056 [Phase 5, US2] — Parent recognition, PowerShell side. Mirror
# of tests/bash/sink/test_recognition_parent.bats. Cross-port parity is
# proven in bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Recognition.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:JIRA_MAX_ATTEMPTS = '1'
    $script:SpecRef = '{"repo":"acme/app","spec_slug":"001-billing","folder":"specs/001-billing"}'
    $script:SpecPath = 'specs/001-billing/spec.md'

    function New-JiraMockConfig([string] $MarkerJson) {
        $path = Join-Path $TestDrive 'cfg.json'
        $body = "{`"issues`": {`"COMP-412`": {`"summary`": `"S`", `"properties`": {`"spec-kit-jira`": $MarkerJson}}}}"
        Set-Content -LiteralPath $path -Value $body -NoNewline
        return $path
    }
}

Describe 'Invoke-JiraRecognitionParentRun — the decision table (contracts/hierarchy-resolution.md §7)' {
    It 'absent: no read, state new' {
        $minfo = '{"state":"absent","id":"","lines":[]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).state | Should -Be 'new'
    }

    It 'assigned: no read, state new' {
        $minfo = '{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        ($r.Json | ConvertFrom-Json).state | Should -Be 'new'
    }

    It 'creating: no read, state blocked, reason parent-key-unrecorded' {
        $minfo = '{"state":"creating","id":"3f2a91c04b7e6d18","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $j = $r.Json | ConvertFrom-Json
        $j.state | Should -Be 'blocked'
        $j.reason | Should -Be 'parent-key-unrecorded'
        $j.detail | Should -BeLike '*creating*'
    }

    It 'malformed: no read, state blocked, reason parent-marker-malformed' {
        $minfo = '{"state":"malformed","id":"3f2a91c04b7e6d18","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $j = $r.Json | ConvertFrom-Json
        $j.state | Should -Be 'blocked'
        $j.reason | Should -Be 'parent-marker-malformed'
        $j.detail | Should -BeLike '*line 2*'
    }

    It 'duplicate: no read, state blocked, reason parent-marker-duplicate, every line named' {
        $minfo = '{"state":"duplicate","id":"","lines":[2,7]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $j = $r.Json | ConvertFrom-Json
        $j.state | Should -Be 'blocked'
        $j.reason | Should -Be 'parent-marker-duplicate'
        $j.detail | Should -BeLike '*2, 7*'
    }
}

Describe 'Invoke-JiraRecognitionParentRun — bound reads' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'ok + role:parent + same repo/spec_slug: state bound, key and current carried' {
        $cfg = New-JiraMockConfig '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","role":"parent"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $minfo = '{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $j = $r.Json | ConvertFrom-Json
        $j.state | Should -Be 'bound'
        $j.key | Should -Be 'COMP-412'
        $j.current.summary | Should -Be 'S'
        $j.origin | Should -Be 'bridge'
    }

    It 'ok + different spec_slug: state blocked, reason parent-claimed-by-other' {
        $cfg = New-JiraMockConfig '{"origin":"bridge","repo":"acme/app","spec_slug":"999-other","role":"parent"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $minfo = '{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $j = $r.Json | ConvertFrom-Json
        $j.state | Should -Be 'blocked'
        $j.reason | Should -Be 'parent-claimed-by-other'
        $j.detail | Should -BeLike '*999-other*'
    }

    It 'ok + no identity property at all: state blocked, reason parent-identity-unverifiable' {
        $cfg = New-JiraMockConfig 'null'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $minfo = '{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $j = $r.Json | ConvertFrom-Json
        $j.state | Should -Be 'blocked'
        $j.reason | Should -Be 'parent-identity-unverifiable'
    }

    It 'ok + identity present but no role field: state blocked, reason parent-identity-unverifiable, never treated as a parent' {
        $cfg = New-JiraMockConfig '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","story":"1111111111111111"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $minfo = '{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $j = $r.Json | ConvertFrom-Json
        $j.state | Should -Be 'blocked'
        $j.reason | Should -Be 'parent-identity-unverifiable'
    }
}

Describe 'T055 — an inconclusive read is NEVER downgraded to "no parent exists"' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It '401 on the parent read -> exit 3, zero stdout' {
        $cfg = Join-Path $TestDrive 'faults1.json'
        Set-Content -LiteralPath $cfg -Value '{"faults": {"issue/COMP-412": {"status": 401}}}' -NoNewline
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $minfo = '{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $r.ExitCode | Should -Be 3
        $r.Json | Should -Be ''
    }

    It 'exhausted 429 on the parent read -> exit 2, zero stdout' {
        $cfg = Join-Path $TestDrive 'faults2.json'
        Set-Content -LiteralPath $cfg -Value '{"faults": {"issue/COMP-412": {"status": 429, "retryAfter": 0}}}' -NoNewline
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $minfo = '{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $r.ExitCode | Should -Be 2
        $r.Json | Should -Be ''
    }

    It 'network drop on the parent read -> exit 2, zero stdout' {
        $cfg = Join-Path $TestDrive 'faults3.json'
        Set-Content -LiteralPath $cfg -Value '{"faults": {"issue/COMP-412": {"network": true}}}' -NoNewline
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $minfo = '{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $r.ExitCode | Should -Be 2
        $r.Json | Should -Be ''
    }
}

Describe 'T056 — a recorded parent returning 404 is re-created, not a failure' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It '404 on the parent read: state new, the former key carried for the recreation notice' {
        $cfg = Join-Path $TestDrive 'faults4.json'
        Set-Content -LiteralPath $cfg -Value '{"faults": {"issue/COMP-412": {"status": 404}}}' -NoNewline
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $minfo = '{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-412","lines":[2]}'
        $r = Invoke-JiraRecognitionParentRun -MarkerInfoJson $minfo -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath $script:SpecPath
        $j = $r.Json | ConvertFrom-Json
        $j.state | Should -Be 'new'
        $j.recreated_from.key | Should -Be 'COMP-412'
    }
}
