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

    It 'uppercases hex and leaves unreserved chars' {
        ConvertTo-JiraUriComponent "x-y_z.1~a'b" | Should -BeExactly "x-y_z.1~a'b"
    }
}
