#!/usr/bin/env bash
# lib/url_origin.sh — URL origin parsing and comparison (032,
# contracts/origin-pinning.md §C1).
#
# An "origin" is scheme + host + port. Two URLs address the same origin when
# their canonical forms are identical; path, query and fragment never
# distinguish them.
#
# Port infrastructure only: NO Jira knowledge. This module exists in lib/
# rather than sink/ because Constitution VIII forbids lib/ from depending on
# sink/, and the connection chokepoint (lib/config.sh) needs the comparison.
# sink/jira/designator.sh is re-expressed on top of it, so the tree holds one
# origin grammar rather than two.
#
# Three rules this module exists to hold, each measured rather than assumed
# (research.md §R5):
#
#   * The case fold is an EXPLICIT ASCII mapping. `${x,,}` and .NET's
#     ToLowerInvariant() disagree on U+0130: bash yields `istanbul.x`,
#     PowerShell yields `İstanbul.x`. A host is attacker-supplied here, so a
#     locale- or culture-dependent fold is a cross-port divergence on exactly
#     the input this feature exists to catch.
#   * Exactly ONE trailing dot is removed. `${x%.}` removes one, .TrimEnd('.')
#     removes all; `https://a.b..` versus `https://a.b.` matched on one port
#     and not the other.
#   * A bracketed IPv6 authority splits at the closing bracket, never at the
#     first colon. Splitting on the first colon yields host `[` and port
#     `:1]:8080` — equally wrong in both ports, so conformance stayed green
#     while `http://[::1]:8080`, a value the base-URL validator explicitly
#     admits, parsed to garbage.
#
# No external process, no jq, no `[System.Uri]`, and no `$( … )` capture of a
# URL value: MSYS swallows a trailing CR across a command substitution, which
# would make a CR-contaminated input parse differently on Windows than on
# POSIX (docs/10-windows-portability.md §4).

[[ -n ${_JIRA_LIB_URL_ORIGIN:-} ]] && return 0
_JIRA_LIB_URL_ORIGIN=1

# _url_origin_fold <string> — lower-case the ASCII letters A-Z and nothing
# else, into _URL_ORIGIN_FOLD. Every mapped character is spelled out: the
# point is that the character set is stated here and not delegated to a
# locale, a culture, or a Unicode table that differs between the two ports.
#
# MUST be called directly, never through `$( … )` — a subshell would compute
# the global and discard it (the trap lib/credentials.sh documents for
# _CRED_CMD_RESULT).
_URL_ORIGIN_FOLD=""
_url_origin_fold() {
  local s="$1"
  s="${s//A/a}" s="${s//B/b}" s="${s//C/c}" s="${s//D/d}" s="${s//E/e}"
  s="${s//F/f}" s="${s//G/g}" s="${s//H/h}" s="${s//I/i}" s="${s//J/j}"
  s="${s//K/k}" s="${s//L/l}" s="${s//M/m}" s="${s//N/n}" s="${s//O/o}"
  s="${s//P/p}" s="${s//Q/q}" s="${s//R/r}" s="${s//S/s}" s="${s//T/t}"
  s="${s//U/u}" s="${s//V/v}" s="${s//W/w}" s="${s//X/x}" s="${s//Y/y}"
  s="${s//Z/z}"
  _URL_ORIGIN_FOLD="${s}"
}

# url_origin_parts <url> — set _URL_ORIGIN_SCHEME / _URL_ORIGIN_HOST /
# _URL_ORIGIN_PORT and return 0; return 1 when <url> carries no scheme or an
# empty authority. Scheme and host are folded (C1.2, C1.3); the host loses at
# most one trailing dot (C1.4); the port is empty when unspecified.
#
# Direct-call contract as above — the three globals are the return value.
_URL_ORIGIN_SCHEME=""
_URL_ORIGIN_HOST=""
_URL_ORIGIN_PORT=""
url_origin_parts() {
  local url="$1"
  # Strip a single trailing CR. Single-character form on purpose: a $'\r\n'
  # glob is bent onto a bare LF by the MSYS matcher (AGENTS.md).
  url="${url%$'\r'}"
  [[ "${url}" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]+) ]] || return 1

  local scheme="${BASH_REMATCH[1]}" hostport="${BASH_REMATCH[2]}"
  local host="" port="" rest=""

  if [[ "${hostport}" == \[* ]]; then
    # Bracketed IPv6 literal: the authority ends at the closing bracket.
    [[ "${hostport}" == *\]* ]] || return 1
    host="${hostport%%\]*}]"
    rest="${hostport#"${host}"}"
    if [[ -n "${rest}" ]]; then
      [[ "${rest}" == :* ]] || return 1
      port="${rest#:}"
    fi
  elif [[ "${hostport}" == *:* ]]; then
    host="${hostport%%:*}"
    port="${hostport#*:}"
  else
    host="${hostport}"
  fi

  [[ -n "${host}" ]] || return 1

  _url_origin_fold "${scheme}"
  _URL_ORIGIN_SCHEME="${_URL_ORIGIN_FOLD}"
  # One trailing dot, and one only (C1.4).
  host="${host%.}"
  _url_origin_fold "${host}"
  _URL_ORIGIN_HOST="${_URL_ORIGIN_FOLD}"
  _URL_ORIGIN_PORT="${port}"
  return 0
}

# _url_origin_default_port <scheme> — the scheme's default port into
# _URL_ORIGIN_DEFAULT_PORT, empty when the scheme has none (C1.6).
_URL_ORIGIN_DEFAULT_PORT=""
_url_origin_default_port() {
  case "$1" in
    https) _URL_ORIGIN_DEFAULT_PORT=443 ;;
    http) _URL_ORIGIN_DEFAULT_PORT=80 ;;
    *) _URL_ORIGIN_DEFAULT_PORT="" ;;
  esac
}

# url_origin_canonical <url> — print `scheme://host[:port]`, omitting the port
# when it is the scheme's default (C1.9). Prints nothing and returns 1 when
# <url> does not parse. This is the form recorded on disk, so its bytes are a
# cross-port obligation.
url_origin_canonical() {
  url_origin_parts "$1" || return 1
  local port="${_URL_ORIGIN_PORT}"
  _url_origin_default_port "${_URL_ORIGIN_SCHEME}"
  [[ -n "${port}" && "${port}" == "${_URL_ORIGIN_DEFAULT_PORT}" ]] && port=""
  if [[ -n "${port}" ]]; then
    printf '%s://%s:%s' "${_URL_ORIGIN_SCHEME}" "${_URL_ORIGIN_HOST}" "${port}"
  else
    printf '%s://%s' "${_URL_ORIGIN_SCHEME}" "${_URL_ORIGIN_HOST}"
  fi
  return 0
}

# url_origin_equal <a> <b> — return 0 when both parse to the same origin
# (C1.10). An unparseable operand never matches anything, including another
# unparseable one: refusing is the safe answer for a value that will be used
# to decide whether a credential may travel.
url_origin_equal() {
  local a b
  url_origin_parts "$1" || return 1
  a="${_URL_ORIGIN_SCHEME}|${_URL_ORIGIN_HOST}|${_URL_ORIGIN_PORT}"
  _url_origin_default_port "${_URL_ORIGIN_SCHEME}"
  [[ "${_URL_ORIGIN_PORT}" == "${_URL_ORIGIN_DEFAULT_PORT}" ]] && a="${_URL_ORIGIN_SCHEME}|${_URL_ORIGIN_HOST}|"
  url_origin_parts "$2" || return 1
  b="${_URL_ORIGIN_SCHEME}|${_URL_ORIGIN_HOST}|${_URL_ORIGIN_PORT}"
  _url_origin_default_port "${_URL_ORIGIN_SCHEME}"
  [[ "${_URL_ORIGIN_PORT}" == "${_URL_ORIGIN_DEFAULT_PORT}" ]] && b="${_URL_ORIGIN_SCHEME}|${_URL_ORIGIN_HOST}|"
  [[ "${a}" == "${b}" ]]
}
