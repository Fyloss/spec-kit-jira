# T019/T020/T043/T056 — Recognition, PowerShell side. Mirror of
# tests/bash/sink/test_recognition.bats: the marker verification decision
# table, the fault matrix, and the diagnostics catalogue's privacy discipline.
# Cross-port parity is proven in bats.

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

    function New-JiraRecognitionSeedConfig([string] $MarkerJson) {
        # A mock config seeding COMP-1 already bound and carrying the given marker.
        $path = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        @"
{"issues": {"COMP-1": {"summary": "S", "properties": {"spec-kit-jira": $MarkerJson}}}}
"@ | Set-Content -NoNewline -Path $path
        return $path
    }

    function New-JiraRecognitionFaultConfig([string] $FaultsJson) {
        $path = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        @"
{"faults": $FaultsJson}
"@ | Set-Content -NoNewline -Path $path
        return $path
    }
}

Describe 'Invoke-JiraRecognitionRun — marker verification decision table' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It "bound: marker's repo/spec_slug/story all match — recognised" {
        $cfg = New-JiraRecognitionSeedConfig '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","story":"1111111111111111"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        $out = $r.Json | ConvertFrom-Json
        $out.bound.'1111111111111111'.key | Should -Be 'COMP-1'
        @($out.new).Count | Should -Be 0
        @($out.blocked).Count | Should -Be 0
    }

    It 'marker-mismatch: story present, matches a SIBLING story of this same spec, not this one' {
        $cfg = New-JiraRecognitionSeedConfig '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","story":"9999999999999999"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}},{"local_id":"9999999999999999","marker":{"state":"absent"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).blocked[0].reason | Should -Be 'marker-mismatch'
    }

    It 'orphan: stamped identifier matches no story of the specification' {
        $cfg = New-JiraRecognitionSeedConfig '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing","story":"deadbeefdeadbeef"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).blocked[0].reason | Should -Be 'orphan'
    }

    It 'claimed-by-other: repo names another repository (spec_slug alone never blocks — durability across a rename, US3)' {
        $cfg = New-JiraRecognitionSeedConfig '{"origin":"bridge","repo":"other/app","spec_slug":"001-billing","story":"1111111111111111"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).blocked[0].reason | Should -Be 'claimed-by-other'
    }

    It 'a spec_slug mismatch alone (same repo, matching story id) is bound, not blocked — durability across a rename (US3, FR-017)' {
        $cfg = New-JiraRecognitionSeedConfig '{"origin":"bridge","repo":"acme/app","spec_slug":"001-billing-renamed","story":"1111111111111111"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        $out = $r.Json | ConvertFrom-Json
        @($out.blocked).Count | Should -Be 0
        $out.bound.'1111111111111111'.key | Should -Be 'COMP-1'
    }

    It 'duplicate-claim on two stories: an identifier appears on two markers (parse-level)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"aaaa111122223333","marker":{"state":"duplicate","lines":[2,3]}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).blocked[0].reason | Should -Be 'duplicate-claim'
    }

    It 'duplicate-claim on two keys: two recorded keys resolving to one ticket' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}},{"local_id":"2222222222222222","marker":{"state":"bound","id":"2222222222222222","ticket":"COMP-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        @(($r.Json | ConvertFrom-Json).blocked | Where-Object { $_.reason -eq 'duplicate-claim' }).Count | Should -Be 2
    }

    It 'a ticket with no marker at all is never adopted' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"UNSEEDED-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'UNSEEDED' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).blocked[0].reason | Should -Be 'marker-mismatch'
    }

    It 'story=<id> alone (no ticket) is new' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"assigned","id":"1111111111111111"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).new[0] | Should -Be '1111111111111111'
    }

    It 'story=<id> creating fails closed for that story only (key-unrecorded)' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"creating","id":"1111111111111111"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).blocked[0].reason | Should -Be 'key-unrecorded'
    }
}

Describe 'Fault matrix: zero creation, every read failure fails the run closed' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It '401 on the recognition read -> exit 3, zero writes' {
        $cfg = New-JiraRecognitionFaultConfig '{"issue/COMP-1": {"status": 401}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 3
        $r.Json | Should -Be ''
    }

    It 'exhausted 429 on the recognition read -> exit 2, zero writes' {
        $cfg = New-JiraRecognitionFaultConfig '{"issue/COMP-1": {"status": 429, "retryAfter": 0}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 2
        $r.Json | Should -Be ''
    }

    It 'network drop on the recognition read -> exit 2, zero writes' {
        $cfg = New-JiraRecognitionFaultConfig '{"issue/COMP-1": {"network": true}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 2
        $r.Json | Should -Be ''
    }

    It '404 on the recognition read: ticket re-created with a notice (not a failure)' {
        $cfg = New-JiraRecognitionFaultConfig '{"issue/COMP-999": {"status": 404}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-999"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).new[0] | Should -Be '1111111111111111'
    }
}

Describe 'Privacy: diagnostics name no host, token, or account id' {
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'no diagnostic contains the mock host' {
        $cfg = New-JiraRecognitionSeedConfig '{"origin":"bridge","repo":"acme/app","spec_slug":"002-other","story":"1111111111111111"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}}]'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.Json | Should -Not -BeLike '*127.0.0.1*'
        $r.Json | Should -Not -BeLike '*RAWSECRETXYZ*'
    }

    It "T056: every diagnostic reason's wording matches the catalogue and leaks nothing, at max detail" {
        $cfg = New-JiraRecognitionSeedConfig '{"origin":"bridge","repo":"other/app","spec_slug":"999-x","story":"9999999999999999"}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = @'
[
  {"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"COMP-1"}},
  {"local_id":"2222222222222222","marker":{"state":"malformed","id":"2222222222222222","lines":[7]}},
  {"local_id":"aaaa111122223333","marker":{"state":"duplicate","lines":[10,11]}},
  {"local_id":"3333333333333333","marker":{"state":"creating","id":"3333333333333333"}}
]
'@
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $script:SpecRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        $out = $r.Json | ConvertFrom-Json
        $reasons = ($out.blocked | ForEach-Object { $_.reason } | Sort-Object) -join ','
        $reasons | Should -Be 'claimed-by-other,duplicate-claim,key-unrecorded,marker-malformed'
        $allDetails = ($out.blocked | ForEach-Object { $_.detail }) -join "`n"
        $hostOnly = $script:M.BaseUrl -replace '^http://', ''
        $allDetails | Should -Not -BeLike "*$hostOnly*"
        $allDetails | Should -Not -BeLike '*RAWSECRETXYZ*'
        $allDetails | Should -Not -BeLike '*127.0.0.1*'
        $r.Json | Should -Not -BeLike '*127.0.0.1*'
    }
}
