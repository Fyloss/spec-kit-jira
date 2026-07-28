# T124 [US4] — Issue-key shape validation and pinned context reads, PowerShell
# side. Mirror of tests/bash/sink/test_adoption_key_shape.bats (003 research §9).
#
# The key regex lives in the SINK and nowhere else: that is what keeps every
# key-shaped literal on the Jira side of the engine/sink boundary.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Adoption.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $script:Corpus = '{"projects":{"ADO":"company"},"issues":{"ADO-1":{"labels":["speckit-adopt:003-alpha"]},"ADO-77":{"labels":[],"parent":"ADO-1"}}}'

    function Start-Corpus { param([string] $Json = $script:Corpus)
        $script:Mock = Start-JiraMock -ConfigJson $Json
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
    }
    function Get-PutCount {
        return @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'PUT *' }).Count
    }
}

Describe 'Test-JiraAdoptionIssueKey' {
    It 'accepts <Key>' -TestCases @(
        @{ Key = 'ADO-1' }, @{ Key = 'ADO-4242' }, @{ Key = 'A1-7' }
        @{ Key = 'LONGPROJECT-99' }, @{ Key = 'WITH_UNDERSCORE-3' }
    ) { param($Key) Test-JiraAdoptionIssueKey -Key $Key | Should -BeTrue }

    It 'rejects <Key>' -TestCases @(
        @{ Key = 'not-a-key' }, @{ Key = 'ado-1' }, @{ Key = 'ADO' }, @{ Key = 'ADO-' }
        @{ Key = '-1' }, @{ Key = 'ADO-1x' }, @{ Key = 'ADO 1' }, @{ Key = '1ADO-1' }, @{ Key = '' }
    ) { param($Key) Test-JiraAdoptionIssueKey -Key $Key | Should -BeFalse }

    It 'keeps the key regex out of the neutral layers (Constitution VIII)' {
        # `-BeLike` is the wrong operator here: `[0-9]` is a wildcard character
        # class, so the pattern would never mean what it reads as. Compare as
        # plain ordinal substrings instead.
        $needle = 'A-Z0-9_]*-[0-9]'
        foreach ($f in @('scripts/powershell/engine/Adoption.psm1', 'scripts/powershell/lib/Cli.psm1')) {
            (Get-Content -Raw -LiteralPath (Join-Path $Root $f)).Contains($needle) | Should -BeFalse
        }
        (Get-Content -Raw -LiteralPath (Join-Path $Root 'scripts/powershell/sink/jira/Adoption.psm1')).Contains($needle) |
            Should -BeTrue
    }
}

Describe 'Get-JiraAdoptionPinnedContext' {
    AfterEach {
        if ($script:Mock) { Stop-JiraMock -Mock $script:Mock; $script:Mock = $null }
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'reads a pinned key for its labels, parent and project' {
        Start-Corpus
        $r = Get-JiraAdoptionPinnedContext -KeysJson '["ADO-77"]'
        $r.ExitCode | Should -Be 0
        $c = @($r.Json | ConvertFrom-Json)[0]
        $c.key | Should -Be 'ADO-77'
        $c.project_key | Should -Be 'ADO'
        $c.parent_key | Should -Be 'ADO-1'
        $c.identity | Should -BeNullOrEmpty
        ((Get-JiraMockCallLog -Mock $script:Mock) -join "`n") | Should -BeLike '*GET /rest/api/3/issue/ADO-77?fields=labels,parent,project*'
    }

    It 'returns several pinned keys in key order' {
        Start-Corpus
        $r = Get-JiraAdoptionPinnedContext -KeysJson '["ADO-77","ADO-1"]'
        (@($r.Json | ConvertFrom-Json | ForEach-Object { $_.key }) -join ',') | Should -Be 'ADO-1,ADO-77'
    }

    It 'performs no read for an empty pin list' {
        Start-Corpus
        $r = Get-JiraAdoptionPinnedContext -KeysJson '[]'
        $r.ExitCode | Should -Be 0
        $r.Json | Should -Be '[]'
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'raises a usage error BEFORE any request for a malformed key' {
        Start-Corpus
        $r = Get-JiraAdoptionPinnedContext -KeysJson '["not-a-key"]'
        $r.ExitCode | Should -Be 1
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'stops the run on one malformed key among valid ones' {
        Start-Corpus
        (Get-JiraAdoptionPinnedContext -KeysJson '["ADO-1","nope"]').ExitCode | Should -Be 1
        Get-PutCount | Should -Be 0
    }

    It 'fails closed on a pinned key absent from the tracker' {
        Start-Corpus
        $r = Get-JiraAdoptionPinnedContext -KeysJson '["ADO-404"]'
        $r.ExitCode | Should -Be 2
        $r.Json | Should -Be ''
    }

    It 'propagates an unreadable pinned key and writes nothing' {
        Start-Corpus '{"projects":{"ADO":"company"},"fault":{"status":401},"issues":{"ADO-1":{"labels":[]}}}'
        (Get-JiraAdoptionPinnedContext -KeysJson '["ADO-1"]').ExitCode | Should -Be 3
        Get-PutCount | Should -Be 0
    }

    It 'reads identity for a pinned key exactly as for a discovered candidate' {
        Start-Corpus '{"projects":{"ADO":"company"},"identity":{"ADO-77":{"origin":"human","repo":"acme/app","spec_slug":"009-elsewhere"}},"issues":{"ADO-77":{"labels":[]}}}'
        $pinned = (Get-JiraAdoptionPinnedContext -KeysJson '["ADO-77"]').Json
        $r = Get-JiraAdoptionCandidateIdentity -CandidatesJson $pinned
        $r.ExitCode | Should -Be 0
        @($r.Json | ConvertFrom-Json)[0].identity.spec_slug | Should -Be '009-elsewhere'
    }
}
