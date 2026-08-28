# T048 [032] — the ceremony's destination record, PowerShell side. Mirror of
# tests/bash/commands/test_config_bound_site.bats (contracts/origin-pinning.md §C3).
#
# The load-bearing case here is C3.7: the refusal a redirected run prints tells
# the operator to run this ceremony. If running it were enough to re-record the
# new destination, that instruction would BE the bypass — an attacker changes
# `base_url`, the operator follows the printed advice, and the redirection is
# accepted in silence. Accepting has to mean naming it.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'UrlOrigin.psm1') -Force

    # The ceremony's record decision, in isolation from discovery and the
    # network. Mirrors the block at commands/Config.psm1's write site.
    function Get-RecordDecision {
        param([string] $Prior, [string] $Reached, [string] $Accept)
        if ($Prior -and $Prior -cne $Reached) {
            if ([string]::IsNullOrEmpty($Accept)) { return 'refuse-unaccepted' }
            $accepted = Get-JiraUrlOriginCanonical -Url $Accept
            if ($accepted -cne $Reached) { return 'refuse-names-other' }
        }
        return 'record'
    }
}

Describe 'Ceremony destination record — C3' {
    It 'C3.2 — a first bind records the origin the ceremony reached' {
        Get-RecordDecision -Prior '' -Reached 'https://a.example.invalid' -Accept '' |
            Should -BeExactly 'record'
    }

    It 'C3.6 — an unchanged re-run records the same origin, no churn' {
        Get-RecordDecision -Prior 'https://a.example.invalid' -Reached 'https://a.example.invalid' -Accept '' |
            Should -BeExactly 'record'
    }

    It 'C3.7 — replaying the refusal''s instruction records NOTHING (SC-008)' {
        # The whole feature turns on this row. If it ever returns 'record', the
        # control is a speed bump: the attacker's own refusal message becomes
        # the instructions for accepting the attack.
        Get-RecordDecision -Prior 'https://a.example.invalid' -Reached 'https://b.example.invalid' -Accept '' |
            Should -BeExactly 'refuse-unaccepted'
    }

    It 'C3.8 — --accept-site naming a different origin is not an override' {
        # Naming SOME origin is not the point; naming the one actually reached
        # is. Otherwise a pasted invocation from anywhere would unlock any
        # destination.
        Get-RecordDecision -Prior 'https://a.example.invalid' -Reached 'https://b.example.invalid' -Accept 'https://c.example.invalid' |
            Should -BeExactly 'refuse-names-other'
    }

    It 'C3.8 — --accept-site naming the reached origin accepts the change' {
        Get-RecordDecision -Prior 'https://a.example.invalid' -Reached 'https://b.example.invalid' -Accept 'https://b.example.invalid' |
            Should -BeExactly 'record'
    }

    It 'C3.8 — the accepted value is compared as an origin, not as bytes' {
        # An operator who types a default port, a trailing slash or a capital
        # letter has still named the right destination.
        Get-RecordDecision -Prior 'https://a.example.invalid' -Reached 'https://b.example.invalid' -Accept 'https://B.Example.INVALID:443/' |
            Should -BeExactly 'record'
    }

    It 'C3.4 — a ceremony that reached nothing records nothing' {
        # Degraded mode returns before the write site; this pins the invariant
        # that an empty reached-origin can never produce a record.
        Get-JiraUrlOriginCanonical -Url '' | Should -BeNullOrEmpty
    }
}
