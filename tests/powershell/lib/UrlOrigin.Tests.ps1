# T014 [032] — URL origin parsing and comparison, PowerShell side. Mirror of
# tests/bash/lib/test_url_origin.bats (contracts/origin-pinning.md §C1).
# Cross-port byte equality of the canonical form is proven by the conformance
# corpus, not here.
#
# Three cases below are regressions, not hypotheticals — each was measured
# divergent between the two ports before this module existed (research.md §R5):
# the one-trailing-dot arity, the case fold, and the bracketed IPv6 authority.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'UrlOrigin.psm1') -Force
}

Describe 'Get-JiraUrlOriginPart — C1.1 parsing' {
    It 'C1.1 — parses scheme, host and port' {
        $p = Get-JiraUrlOriginPart -Url 'https://jira.example.invalid:8443/browse/X-1'
        $p.Scheme | Should -BeExactly 'https'
        $p.UrlHost | Should -BeExactly 'jira.example.invalid'
        $p.Port | Should -BeExactly '8443'
    }

    It 'C1.1 — an absent port is empty, not a default' {
        (Get-JiraUrlOriginPart -Url 'https://jira.example.invalid').Port | Should -BeExactly ''
    }

    It 'C1.1 — refuses a URL with no scheme' {
        Get-JiraUrlOriginPart -Url 'jira.example.invalid/browse/X-1' | Should -BeNullOrEmpty
    }

    It 'C1.1 — refuses an empty authority' {
        Get-JiraUrlOriginPart -Url 'https:///browse/X-1' | Should -BeNullOrEmpty
    }
}

Describe 'Convert-JiraUrlOriginFold — C1.2 / C1.3 the explicit ASCII fold' {
    It 'C1.2 — the scheme is folded' {
        (Get-JiraUrlOriginPart -Url 'HTTPS://jira.example.invalid').Scheme | Should -BeExactly 'https'
    }

    It 'C1.3 — ASCII letters fold' {
        (Get-JiraUrlOriginPart -Url 'https://JIRA.Example.INVALID').UrlHost |
            Should -BeExactly 'jira.example.invalid'
    }

    It 'C1.3 — a non-ASCII uppercase letter is NOT folded (regression)' {
        # Measured divergence: ToLowerInvariant() yielded 'İstanbul.x' while
        # bash's ${x,,} yielded 'istanbul.x'. Both ports now leave U+0130 alone.
        # ToLowerInvariant() must never come back here — a host reaching this
        # point is attacker-supplied.
        (Get-JiraUrlOriginPart -Url 'https://İSTANBUL.X').UrlHost | Should -BeExactly 'İstanbul.x'
    }

    It 'C1.3 — a folded host does not equal its unfolded Unicode neighbour' {
        Test-JiraUrlOriginEqual -First 'https://İSTANBUL.X/y' -Second 'https://istanbul.x' |
            Should -BeFalse
    }
}

Describe 'Get-JiraUrlOriginPart — C1.4 one trailing dot, and one only' {
    It 'C1.4 — exactly one trailing dot is removed (regression)' {
        # TrimEnd('.') removed all of them and must not return.
        (Get-JiraUrlOriginPart -Url 'https://a.b..').UrlHost | Should -BeExactly 'a.b.'
    }

    It 'C1.4 — a single trailing dot is insignificant' {
        Test-JiraUrlOriginEqual -First 'https://a.b.' -Second 'https://a.b' | Should -BeTrue
    }

    It 'C1.4 — a doubled trailing dot is NOT the same origin (regression)' {
        # This port matched and bash refused, before the repair.
        Test-JiraUrlOriginEqual -First 'https://a.b../x' -Second 'https://a.b.' | Should -BeFalse
    }
}

Describe 'Get-JiraUrlOriginPart — C1.5 bracketed IPv6' {
    It 'C1.5 — a bracketed IPv6 authority splits at the closing bracket' {
        $p = Get-JiraUrlOriginPart -Url 'http://[::1]:8080/z'
        $p.UrlHost | Should -BeExactly '[::1]'
        $p.Port | Should -BeExactly '8080'
    }

    It 'C1.5 — a bracketed IPv6 authority with no port has no port' {
        $p = Get-JiraUrlOriginPart -Url 'http://[::1]'
        $p.UrlHost | Should -BeExactly '[::1]'
        $p.Port | Should -BeExactly ''
    }

    It 'C1.5 — an unclosed bracket does not parse' {
        Get-JiraUrlOriginPart -Url 'http://[::1:8080' | Should -BeNullOrEmpty
    }
}

Describe 'Test-JiraUrlOriginEqual — C1.6 default ports' {
    It 'C1.6 — https and its default port are the same origin' {
        Test-JiraUrlOriginEqual -First 'https://x' -Second 'https://x:443' | Should -BeTrue
    }

    It 'C1.6 — http and its default port are the same origin' {
        Test-JiraUrlOriginEqual -First 'http://x' -Second 'http://x:80' | Should -BeTrue
    }

    It 'C1.6 — a non-default port distinguishes' {
        Test-JiraUrlOriginEqual -First 'https://x' -Second 'https://x:8443' | Should -BeFalse
    }

    It 'C1.6 — the schemes'' defaults do not cross' {
        Test-JiraUrlOriginEqual -First 'https://x:80' -Second 'http://x' | Should -BeFalse
    }
}

Describe 'Get-JiraUrlOriginPart — C1.7 CR' {
    It 'C1.7 — a single trailing CR is stripped' {
        (Get-JiraUrlOriginPart -Url "https://a.b`r").UrlHost | Should -BeExactly 'a.b'
    }

    It 'C1.7 — a CR-contaminated value equals its clean form' {
        Test-JiraUrlOriginEqual -First "https://a.b`r" -Second 'https://a.b' | Should -BeTrue
    }
}

Describe 'Get-JiraUrlOriginCanonical — C1.9' {
    It 'C1.9 — the canonical form omits a default port' {
        Get-JiraUrlOriginCanonical -Url 'https://X.Example.INVALID:443/p?q#f' |
            Should -BeExactly 'https://x.example.invalid'
    }

    It 'C1.9 — the canonical form keeps a non-default port' {
        Get-JiraUrlOriginCanonical -Url 'https://X.Example.INVALID:8443/p?q#f' |
            Should -BeExactly 'https://x.example.invalid:8443'
    }

    It 'C1.9 — an unparseable URL has no canonical form' {
        Get-JiraUrlOriginCanonical -Url 'notaurl' | Should -BeNullOrEmpty
    }
}

Describe 'Test-JiraUrlOriginEqual — C1.10' {
    It 'C1.10 — path, query and fragment never distinguish' {
        Test-JiraUrlOriginEqual -First 'https://a.b/one?x=1#f' -Second 'https://a.b/two' |
            Should -BeTrue
    }

    It 'C1.10 — an unparseable operand never matches, even another one' {
        Test-JiraUrlOriginEqual -First 'notaurl' -Second 'notaurl' | Should -BeFalse
    }
}

Describe 'UrlOrigin — C1.8 no [System.Uri]' {
    It 'C1.8 — the module never calls System.Uri, ToLowerInvariant, or TrimEnd' {
        # [System.Uri] elides default ports, inserts a trailing slash and
        # punycode-encodes IDN; ToLowerInvariant folds by a Unicode table the
        # bash port does not share; TrimEnd('.') strips every trailing dot
        # rather than one. The bash port reproduces none of the three, so any
        # of them here is a byte-equivalence break waiting to happen.
        #
        # Comment lines are stripped first: all three names appear in this
        # module's header, in the prose explaining why they are banned.
        $path = Join-Path $PSScriptRoot '../../../scripts/powershell/lib/UrlOrigin.psm1'
        $code = (Get-Content $path | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $code | Should -Not -Match 'System\.Uri'
        $code | Should -Not -Match 'ToLowerInvariant'
        $code | Should -Not -Match "TrimEnd\("
    }
}
