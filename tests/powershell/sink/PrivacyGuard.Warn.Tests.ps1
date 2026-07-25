# T089/T090 [US12] — Privacy guard WARN tier and allowlist, PowerShell side.
# Mirror of tests/bash/sink/test_privacy_warn.bats. Cross-port byte agreement is
# proven in bats; here we assert the WARN/allowlist semantics (FR-053).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $SinkDir = Join-Path $Root 'scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'PrivacyGuard.psm1') -Force
}

Describe 'Privacy guard WARN tier and allowlist' {
    It 'warns on a generic email but does not block (FR-053)' {
        Get-JiraPrivacyWarnReason -Payload '{"t":"alice@example.com"}' | Should -Be 'email address'
        Test-JiraPrivacyBlock -Payload '{"t":"alice@example.com"}' | Should -Be 0
    }

    It 'warns on a generic UUID but does not block (FR-053)' {
        Get-JiraPrivacyWarnReason -Payload '{"id":"550e8400-e29b-41d4-a716-446655440000"}' | Should -Be 'UUID'
        Test-JiraPrivacyBlock -Payload '{"id":"550e8400-e29b-41d4-a716-446655440000"}' | Should -Be 0
    }

    It 'produces neither block nor warning on an allowlisted Atlassian host (FR-053)' {
        $p = '{"t":"https://ourco.atlassian.net/wiki/x"}'
        Test-JiraPrivacyBlock -Payload $p -AllowlistJson '["ourco.atlassian.net"]' | Should -Be 0
        Get-JiraPrivacyWarnReason -Payload $p -AllowlistJson '["ourco.atlassian.net"]' | Should -Be ''
    }

    It 'still blocks a NON-allowlisted Atlassian host — US11 preserved (FR-052)' {
        Test-JiraPrivacyBlock -Payload '{"t":"acme-corp.atlassian.net"}' -AllowlistJson '["ourco.atlassian.net"]' | Should -Be 9
    }

    It 'excludes .extensionignore paths from parse + scan (FR-053)' {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $ignore = Join-Path $work '.extensionignore'
        @('# comment', 'secrets/', '*.key', 'specs/private.md') -join "`n" | Set-Content -LiteralPath $ignore
        Test-JiraPrivacyPathExcluded -Path 'secrets/creds.txt' -IgnorePath $ignore | Should -BeTrue
        Test-JiraPrivacyPathExcluded -Path 'id_rsa.key' -IgnorePath $ignore | Should -BeTrue
        Test-JiraPrivacyPathExcluded -Path 'specs/private.md' -IgnorePath $ignore | Should -BeTrue
        Test-JiraPrivacyPathExcluded -Path 'specs/public.md' -IgnorePath $ignore | Should -BeFalse
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }

    It 'merges .extensionignore and config allowlist (FR-053)' {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $ignore = Join-Path $work '.extensionignore'
        @('# comment', '', 'ourco.atlassian.net', 'docs.example.com/') -join "`n" | Set-Content -LiteralPath $ignore
        $allow = Get-JiraPrivacyAllowlist -IgnorePath $ignore -ConfigAllowlistJson '["extra.example.org"]' | ConvertFrom-Json
        @($allow).Count | Should -Be 3
        $allow | Should -Contain 'ourco.atlassian.net'
        $allow | Should -Contain 'extra.example.org'
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }

    It 'de-duplicates the allowlist ORDINALLY, keeping case variants, sorted like jq unique (NFR-1)' {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $ignore = Join-Path $work '.extensionignore'
        @('b', 'A') -join "`n" | Set-Content -LiteralPath $ignore
        Get-JiraPrivacyAllowlist -IgnorePath $ignore -ConfigAllowlistJson '["PROJ-Secret","proj-secret"]' |
            Should -Be '["A","PROJ-Secret","b","proj-secret"]'
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}
