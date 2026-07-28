# T012 — Canonical-serializer parity (research §11), PowerShell side.
# Mirror of tests/bash/lib/test_serialize.bats. Asserts the canonical form the
# Bash port (jq -cS) also produces; cross-port byte-parity is proven in the bats suite.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Output.psm1') -Force
}

Describe 'ConvertTo-JiraCanonicalJson' {
    It 'sorts object keys and compacts' {
        ConvertTo-JiraCanonicalJson '{"b":2,"a":1}' | Should -BeExactly '{"a":1,"b":2}'
    }

    It 'preserves raw UTF-8' {
        ConvertTo-JiraCanonicalJson '{"k":"café"}' | Should -BeExactly '{"k":"café"}'
    }

    It 'escapes quote, backslash, and newline' {
        ConvertTo-JiraCanonicalJson '{"k":"a\"b\\c\nd"}' | Should -BeExactly '{"k":"a\"b\\c\nd"}'
    }

    It 'sorts nested keys and preserves array order' {
        ConvertTo-JiraCanonicalJson '{"z":[3,2,1],"a":{"n":2.5,"m":"x"}}' |
            Should -BeExactly '{"a":{"m":"x","n":2.5},"z":[3,2,1]}'
    }

    It 'emits no trailing newline' {
        (ConvertTo-JiraCanonicalJson '{"a":1}').Length | Should -Be 7
    }
}

Describe 'ConvertTo-JiraUriComponent' {
    It 'applies @uri then %20->+' {
        ConvertTo-JiraUriComponent 'a b/c' | Should -BeExactly 'a+b%2Fc'
    }

    It 'uppercases hex and leaves the RFC 3986 unreserved chars alone' {
        # The unreserved set is jq's, which is RFC 3986's — A-Za-z0-9 plus
        # `-_.~` and nothing else. This case previously asserted that `'`
        # survives, which is JavaScript's encodeURIComponent behaviour, not
        # jq's: the two ports then produced different request URLs for any
        # query carrying `!*'()` (003 found it via the adoption JQL's
        # `labels IN (…)`). The Bash side is the reference here.
        ConvertTo-JiraUriComponent 'x-y_z.1~ab' | Should -BeExactly 'x-y_z.1~ab'
        ConvertTo-JiraUriComponent "a(b)c!~*'d" | Should -BeExactly 'a%28b%29c%21~%2A%27d'
    }
}
