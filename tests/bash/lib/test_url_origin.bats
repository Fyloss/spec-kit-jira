#!/usr/bin/env bats
# T013 [032] — URL origin parsing and comparison (contracts/origin-pinning.md
# §C1). The PowerShell twin is tests/powershell/lib/UrlOrigin.Tests.ps1; the
# cross-port byte equality of the canonical form is proven by the conformance
# corpus, not here.
#
# Three cases below are regressions, not hypotheticals — each was measured
# divergent between the two ports before this module existed (research.md §R5):
# the one-trailing-dot arity, the ASCII-only case fold, and the bracketed IPv6
# authority.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/url_origin.sh"
}

# --- C1.1 parsing -----------------------------------------------------------

@test "C1.1 — parses scheme, host and port" {
  url_origin_parts "https://jira.example.invalid:8443/browse/X-1"
  [ "${_URL_ORIGIN_SCHEME}" = "https" ]
  [ "${_URL_ORIGIN_HOST}" = "jira.example.invalid" ]
  [ "${_URL_ORIGIN_PORT}" = "8443" ]
}

@test "C1.1 — an absent port is empty, not a default" {
  url_origin_parts "https://jira.example.invalid"
  [ "${_URL_ORIGIN_PORT}" = "" ]
}

@test "C1.1 — refuses a URL with no scheme" {
  run url_origin_parts "jira.example.invalid/browse/X-1"
  [ "${status}" -ne 0 ]
}

@test "C1.1 — refuses an empty authority" {
  run url_origin_parts "https:///browse/X-1"
  [ "${status}" -ne 0 ]
}

# --- C1.2 / C1.3 the explicit ASCII fold ------------------------------------

@test "C1.2 — the scheme is folded" {
  url_origin_parts "HTTPS://jira.example.invalid"
  [ "${_URL_ORIGIN_SCHEME}" = "https" ]
}

@test "C1.3 — ASCII letters fold" {
  url_origin_parts "https://JIRA.Example.INVALID"
  [ "${_URL_ORIGIN_HOST}" = "jira.example.invalid" ]
}

@test "C1.3 — a non-ASCII uppercase letter is NOT folded (regression)" {
  # Measured divergence: ${x,,} yielded 'istanbul.x' while .NET's
  # ToLowerInvariant() yielded 'İstanbul.x'. Both ports now leave U+0130 alone,
  # so the two agree. A host reaching here is attacker-supplied.
  url_origin_parts "https://İSTANBUL.X"
  [ "${_URL_ORIGIN_HOST}" = "İstanbul.x" ]
}

@test "C1.3 — a folded host does not equal its unfolded Unicode neighbour" {
  run url_origin_equal "https://İSTANBUL.X/y" "https://istanbul.x"
  [ "${status}" -ne 0 ]
}

# --- C1.4 one trailing dot, and one only ------------------------------------

@test "C1.4 — exactly one trailing dot is removed (regression)" {
  url_origin_parts "https://a.b.."
  [ "${_URL_ORIGIN_HOST}" = "a.b." ]
}

@test "C1.4 — a single trailing dot is insignificant" {
  run url_origin_equal "https://a.b." "https://a.b"
  [ "${status}" -eq 0 ]
}

@test "C1.4 — a doubled trailing dot is NOT the same origin (regression)" {
  # bash refused this and PowerShell matched it before the repair.
  run url_origin_equal "https://a.b../x" "https://a.b."
  [ "${status}" -ne 0 ]
}

# --- C1.5 bracketed IPv6 ----------------------------------------------------

@test "C1.5 — a bracketed IPv6 authority splits at the closing bracket" {
  url_origin_parts "http://[::1]:8080/z"
  [ "${_URL_ORIGIN_HOST}" = "[::1]" ]
  [ "${_URL_ORIGIN_PORT}" = "8080" ]
}

@test "C1.5 — a bracketed IPv6 authority with no port has no port" {
  url_origin_parts "http://[::1]"
  [ "${_URL_ORIGIN_HOST}" = "[::1]" ]
  [ "${_URL_ORIGIN_PORT}" = "" ]
}

@test "C1.5 — an unclosed bracket does not parse" {
  run url_origin_parts "http://[::1:8080"
  [ "${status}" -ne 0 ]
}

# --- C1.6 default ports -----------------------------------------------------

@test "C1.6 — https and its default port are the same origin" {
  run url_origin_equal "https://x" "https://x:443"
  [ "${status}" -eq 0 ]
}

@test "C1.6 — http and its default port are the same origin" {
  run url_origin_equal "http://x" "http://x:80"
  [ "${status}" -eq 0 ]
}

@test "C1.6 — a non-default port distinguishes" {
  run url_origin_equal "https://x" "https://x:8443"
  [ "${status}" -ne 0 ]
}

@test "C1.6 — the schemes' defaults do not cross" {
  run url_origin_equal "https://x:80" "http://x"
  [ "${status}" -ne 0 ]
}

# --- C1.7 CR ----------------------------------------------------------------

@test "C1.7 — a single trailing CR is stripped" {
  url_origin_parts "https://a.b"$'\r'
  [ "${_URL_ORIGIN_HOST}" = "a.b" ]
}

@test "C1.7 — a CR-contaminated value equals its clean form" {
  run url_origin_equal "https://a.b"$'\r' "https://a.b"
  [ "${status}" -eq 0 ]
}

# --- C1.9 canonical form ----------------------------------------------------

@test "C1.9 — the canonical form omits a default port" {
  run url_origin_canonical "https://X.Example.INVALID:443/p?q#f"
  [ "${output}" = "https://x.example.invalid" ]
}

@test "C1.9 — the canonical form keeps a non-default port" {
  run url_origin_canonical "https://X.Example.INVALID:8443/p?q#f"
  [ "${output}" = "https://x.example.invalid:8443" ]
}

@test "C1.9 — an unparseable URL has no canonical form" {
  run url_origin_canonical "notaurl"
  [ "${status}" -ne 0 ]
  [ "${output}" = "" ]
}

# --- C1.10 comparison ignores everything after the authority ----------------

@test "C1.10 — path, query and fragment never distinguish" {
  run url_origin_equal "https://a.b/one?x=1#f" "https://a.b/two"
  [ "${status}" -eq 0 ]
}

@test "C1.10 — an unparseable operand never matches, even another one" {
  run url_origin_equal "notaurl" "notaurl"
  [ "${status}" -ne 0 ]
}

# --- C1.8 no process spawn --------------------------------------------------

@test "C1.8 — parsing spawns no external process" {
  # A PATH shim that fails loudly if anything is exec'd. If the primitive ever
  # reaches for sed/tr/jq, this reddens instead of silently costing a spawn.
  local shim
  shim="$(mktemp -d)"
  for prog in sed tr jq awk cut grep; do
    printf '#!/bin/sh\necho "SPAWNED %s" >&2\nexit 99\n' "${prog}" > "${shim}/${prog}"
    chmod +x "${shim}/${prog}"
  done
  run env PATH="${shim}:${PATH}" bash -c \
    "source '${ROOT}/scripts/bash/lib/url_origin.sh'; url_origin_canonical 'https://A.B:8443/x'"
  rm -rf "${shim}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "https://a.b:8443" ]
}
