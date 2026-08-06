# T057 [US3] — Ticket identity marker, PowerShell side. Mirror of
# tests/bash/sink/test_identity.bats. Cross-port parity is proven in bats.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
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

Describe 'T053 [Phase 5, US2] — the identity marker gains role (data-model.md §4)' {
    It 'a marker with no role is the legacy shape (feature-ceremony / mentioned-ticket tickets, unchanged)' {
        $m = Get-JiraIdentityMarker -SpecRefJson $script:SpecA -Origin 'bridge-created' | ConvertFrom-Json
        ($m.PSObject.Properties.Name -contains 'role') | Should -BeFalse
    }

    It 'records role=story alongside the story identifier' {
        $m = Get-JiraIdentityMarker -SpecRefJson $script:SpecA -Origin 'bridge-created' -Story '7f3a9c1e40b2d85a' -Role 'story' | ConvertFrom-Json
        $m.role | Should -Be 'story'
        $m.story | Should -Be '7f3a9c1e40b2d85a'
    }

    It 'records role=parent with no story field' {
        $m = Get-JiraIdentityMarker -SpecRefJson $script:SpecA -Origin 'bridge-created' -Role 'parent' | ConvertFrom-Json
        $m.role | Should -Be 'parent'
        ($m.PSObject.Properties.Name -contains 'story') | Should -BeFalse
    }

    It 'Test-JiraIdentityClaimedByOther still compares repo and spec_slug alone, regardless of role' {
        $marker = Get-JiraIdentityMarker -SpecRefJson $script:SpecA -Origin 'bridge-created' -Role 'parent'
        Test-JiraIdentityClaimedByOther -MarkerJson $marker -SpecRefJson $script:SpecB | Should -BeTrue
        Test-JiraIdentityClaimedByOther -MarkerJson $marker -SpecRefJson $script:SpecA | Should -BeFalse
    }
}

Describe 'T037 [Phase 5, US3] — the identity marker gains summary (summary-record.md §1/§2)' {
    It 'omits summary when not supplied' {
        $m = Get-JiraIdentityMarker -SpecRefJson $script:SpecA -Origin 'bridge-created' -Role 'parent' | ConvertFrom-Json
        ($m.PSObject.Properties.Name -contains 'summary') | Should -BeFalse
    }

    It 'records summary as the exact string given, alongside role and story' {
        $m = Get-JiraIdentityMarker -SpecRefJson $script:SpecA -Origin 'bridge-created' -Story '7f3a9c1e40b2d85a' -Role 'story' -Summary '  The Epic, renamed  ' | ConvertFrom-Json
        $m.summary | Should -Be '  The Epic, renamed  '
        $m.role | Should -Be 'story'
        $m.story | Should -Be '7f3a9c1e40b2d85a'
    }

    It "Test-JiraIdentityClaimedByOther is unaffected by summary's presence" {
        $marker = Get-JiraIdentityMarker -SpecRefJson $script:SpecA -Origin 'bridge-created' -Summary 'Some title'
        Test-JiraIdentityClaimedByOther -MarkerJson $marker -SpecRefJson $script:SpecB | Should -BeTrue
        Test-JiraIdentityClaimedByOther -MarkerJson $marker -SpecRefJson $script:SpecA | Should -BeFalse
    }

    It 'Set-JiraIdentity stamps a marker carrying summary when given one' {
        $m = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $m.BaseUrl
        try {
            $rc = Set-JiraIdentity -IssueKey 'ABC-1' -SpecRefJson $script:SpecA -Origin 'bridge-created' -Summary 'The Epic'
            $rc | Should -Be 0
        }
        finally { Stop-JiraMock -Mock $m }
    }
}
