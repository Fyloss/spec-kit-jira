# T057 [US3] — Ticket identity marker, PowerShell side. Mirror of
# tests/bash/sink/test_identity.bats. Cross-port parity is proven in bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../.specify/extensions/jira/scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Identity.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $script:SpecA = '{"repo":"acme/app","spec_slug":"001-feature-a","folder":"specs/001-feature-a"}'
    $script:SpecB = '{"repo":"acme/app","spec_slug":"002-feature-b","folder":"specs/002-feature-b"}'
}

Describe 'Get-JiraIdentityMarker' {
    It 'records origin and the spec ref' {
        $m = Get-JiraIdentityMarker -SpecRefJson $script:SpecA -Origin 'bridge-created' | ConvertFrom-Json
        $m.origin | Should -Be 'bridge-created'
        $m.spec_slug | Should -Be '001-feature-a'
        $m.repo | Should -Be 'acme/app'
    }
}

Describe 'Test-JiraIdentityClaimedByOther' {
    It 'is true for a different spec, false for the same' {
        $marker = Get-JiraIdentityMarker -SpecRefJson $script:SpecA -Origin 'bridge-created'
        Test-JiraIdentityClaimedByOther -MarkerJson $marker -SpecRefJson $script:SpecB | Should -BeTrue
        Test-JiraIdentityClaimedByOther -MarkerJson $marker -SpecRefJson $script:SpecA | Should -BeFalse
    }
}

Describe 'Get-JiraIdentity / Set-JiraIdentity' {
    BeforeAll {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
    }
    AfterAll { Stop-JiraMock -Mock $script:M }

    It 'reads an unclaimed ticket as empty (404 is not a failure)' {
        $r = Get-JiraIdentity -IssueKey 'ABC-1'
        $r.ExitCode | Should -Be 0
        $r.Value | Should -Be ''
    }

    It 'stamps the marker via an entity property (PUT)' {
        $code = Set-JiraIdentity -IssueKey 'ABC-1' -SpecRefJson $script:SpecA -Origin 'bridge-created'
        $code | Should -Be 0
        (Get-JiraMockCallLog -Mock $script:M) -join "`n" | Should -BeLike '*PUT /rest/api/3/issue/ABC-1/properties/spec-kit-jira*'
    }
}
