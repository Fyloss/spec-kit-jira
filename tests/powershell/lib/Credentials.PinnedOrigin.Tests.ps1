# T058 [032] — the credential producer's own refusal, PowerShell side. Mirror of
# tests/bash/lib/test_credentials_pinned_origin.bats
# (contracts/origin-pinning.md §C6, SC-005).
#
# SC-005 asks for this to be reachable WITHOUT going through the transport, and
# that is the point of the suite: the gate at the connection chokepoint already
# refuses a redirected destination once, with a located message. What is proven
# here is the second, structural line — a future call site that builds its own
# URL cannot obtain a credential by forgetting to ask the gate.
#
# The token is a sentinel throughout so that "no part of it appears" is a
# meaningful assertion rather than a vacuous one.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Credentials.psm1') -Force
}

Describe 'Get-JiraAuthHeader — the pinned-origin refusal (C6)' {
    BeforeEach {
        $env:JIRA_API_TOKEN = 'SENTINELTOKEN0123456789'
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        Set-JiraCredentialPinnedOrigin -Origin ''
    }
    AfterEach {
        Remove-Item Env:\JIRA_API_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'C6.4 — with no verified destination the producer refuses' {
        Get-JiraAuthHeader -Email 'user@example.com' -Url 'https://anything.example.invalid/rest' |
            Should -BeNullOrEmpty
        Get-JiraCredentialLastError | Should -Match 'verified no Jira destination'
    }

    It 'C6.1 — a request to the pinned origin is authorised' {
        Set-JiraCredentialPinnedOrigin -Origin 'https://ok.example.invalid'
        $h = Get-JiraAuthHeader -Email 'user@example.com' -Url 'https://ok.example.invalid/rest/api/3/issue/X-1'
        $h | Should -Not -BeNullOrEmpty
        $h.Authorization | Should -Match '^Basic '
    }

    It 'C6.1 — a request to any other origin is refused' {
        Set-JiraCredentialPinnedOrigin -Origin 'https://ok.example.invalid'
        Get-JiraAuthHeader -Email 'user@example.com' -Url 'https://evil.example.invalid/rest' |
            Should -BeNullOrEmpty
        Get-JiraCredentialLastError | Should -Match 'not bound to'
    }

    It 'C6.1 — the comparison is by origin, not by byte equality' {
        # A default port, a trailing slash and a capital letter still name the
        # same destination; refusing them would break real call sites for no
        # gain.
        Set-JiraCredentialPinnedOrigin -Origin 'https://ok.example.invalid'
        Get-JiraAuthHeader -Email 'user@example.com' -Url 'https://OK.Example.INVALID:443/rest/api/3/issue/X-1' |
            Should -Not -BeNullOrEmpty
    }

    It 'C6.1 — a same-host different-scheme request is refused' {
        Set-JiraCredentialPinnedOrigin -Origin 'https://ok.example.invalid'
        Get-JiraAuthHeader -Email 'user@example.com' -Url 'http://ok.example.invalid/rest' |
            Should -BeNullOrEmpty
    }

    It 'FR-011 — an environment-supplied destination stands in for the pin' {
        # No chokepoint ran, but the destination came from the environment,
        # which is the case FR-011 declares exempt and for which the chokepoint
        # would have pinned this very origin. config.yml is read ONLY by the
        # chokepoint, so a file-supplied destination cannot be in play here.
        $env:SPEC_KIT_JIRA_BASE_URL = 'https://env.example.invalid'
        Get-JiraAuthHeader -Email 'user@example.com' -Url 'https://env.example.invalid/rest' |
            Should -Not -BeNullOrEmpty
    }

    It 'FR-011 — the environment fallback does not authorise a different origin' {
        $env:SPEC_KIT_JIRA_BASE_URL = 'https://env.example.invalid'
        Get-JiraAuthHeader -Email 'user@example.com' -Url 'https://elsewhere.example.invalid/rest' |
            Should -BeNullOrEmpty
    }

    It 'C6.2 — a caller passing no URL keeps the old behaviour' {
        # So the check cannot break a call site that has not been taught about
        # it; every such site is still covered by the gate itself.
        Get-JiraAuthHeader -Email 'user@example.com' | Should -Not -BeNullOrEmpty
    }

    It 'C4.10 — no refusal echoes any part of the credential' {
        Set-JiraCredentialPinnedOrigin -Origin 'https://ok.example.invalid'
        Get-JiraAuthHeader -Email 'user@example.com' -Url 'https://evil.example.invalid/rest' | Out-Null
        Get-JiraCredentialLastError | Should -Not -Match 'SENTINELTOKEN'
    }

    It 'C6.3 — the pinned origin is not an environment variable' {
        # A spawned child must not inherit it, the same rule the credential
        # cache states for itself.
        Set-JiraCredentialPinnedOrigin -Origin 'https://ok.example.invalid'
        (Get-ChildItem Env: | Where-Object { $_.Value -eq 'https://ok.example.invalid' }) |
            Should -BeNullOrEmpty
    }
}
