# T027 [032] — the --accept-site flag, PowerShell side. Mirror of
# tests/bash/lib/test_cli_accept_site.bats (contracts/origin-pinning.md §C3.8).
# The two ports emit the same key at the same index, which is what keeps the
# streams byte-identical (this module's header states that order is normative).

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Cli.psm1') -Force

    function Get-ParseLines {
        param([string[]] $Arguments)
        return ((Invoke-JiraCliParse -Arguments $Arguments) -split "`n")
    }
}

Describe '--accept-site — C3.8' {
    It 'C3.8 — a well-formed origin is carried through verbatim' {
        $lines = Get-ParseLines -Arguments @('config', '--accept-site', 'https://jira.example.invalid')
        $lines | Should -Contain 'accept_site=https://jira.example.invalid'
        $lines | Should -Contain 'exit=0'
    }

    It 'C3.8 — the value is NOT canonicalised by the parser' {
        # The ceremony compares it against the origin it actually reached, and
        # that comparison is origin-aware. Folding here would hide from the
        # operator the exact bytes they typed, which is the one thing this flag
        # exists to surface.
        $lines = Get-ParseLines -Arguments @('config', '--accept-site', 'https://JIRA.Example.INVALID:443')
        $lines | Should -Contain 'accept_site=https://JIRA.Example.INVALID:443'
    }

    It 'C3.8 — a value that is not an origin is refused' {
        $lines = Get-ParseLines -Arguments @('config', '--accept-site', 'prod')
        $lines | Should -Contain 'exit=1'
        ($lines -join "`n") | Should -Match '--accept-site requires an absolute origin'
    }

    It 'C3.8 — a bare hostname is refused (no scheme)' {
        Get-ParseLines -Arguments @('config', '--accept-site', 'jira.example.invalid') |
            Should -Contain 'exit=1'
    }

    It 'C3.8 — a missing value is refused with the flag''s own message' {
        $lines = Get-ParseLines -Arguments @('config', '--accept-site')
        $lines | Should -Contain 'exit=1'
        ($lines -join "`n") | Should -Match '--accept-site requires a value \(--accept-site <origin>\)'
    }

    It 'C3.8 — absent means empty, never a default' {
        # A default would accept a changed destination on the operator's
        # behalf, which is precisely the bypass FR-010 forbids.
        $lines = Get-ParseLines -Arguments @('config')
        $lines | Should -Contain 'accept_site='
    }

    It 'C3.8 — the key is emitted for every command' {
        foreach ($cmd in @('config', 'reconcile', 'mention', 'feature', 'seed')) {
            Get-ParseLines -Arguments @($cmd) | Should -Contain 'accept_site='
        }
    }

    It 'C3.8 — accept_site is emitted between accept_defaults and args' {
        # The emission order is normative for cross-port byte equality. A key
        # inserted at a different index in one port is a silent divergence.
        $keys = (Get-ParseLines -Arguments @('config') |
                ForEach-Object { ($_ -split '=', 2)[0] }) -join ' '
        $keys | Should -Match 'accept_defaults accept_site args'
    }
}
