#!/usr/bin/env bash
# tests/bash/helpers/calls_log.bash — read the conformance mock's request log.
#
# Feature 021 asserts request COUNTS: recognition issues a bounded number of
# reads, an unchanged re-run issues zero, the secret store is consulted once.
# Those claims need one authoritative source, and `calls.log` is it.
#
# Why not an in-process counter. `client.sh` does own a `JIRA_REQUEST_COUNT`,
# but most `jira_request` call sites capture the body through `$(…)`, so an
# increment inside one of them dies with the subshell and never reaches the
# parent. A test that trusted that variable would under-count exactly where the
# config-ceremony and mention paths are involved, and would do it silently.
# `calls.log` is written by the mock, one line per request actually received,
# and no subshell on the caller's side can lose a line from it.
#
# Format, written by `tests/conformance/mock-jira/curl-shim.sh` and by
# `mock-server.ps1`, one request per line:
#
#     GET /rest/api/3/issue/PROJ-1
#     POST /rest/api/3/issue/bulkfetch
#
# The harness copies it to `<outdir>/calls.log`, and creates it EMPTY when the
# mock received nothing — so "no file" and "no requests" are the same answer
# here, deliberately: a scenario that short-circuits before touching the network
# must read as zero, not as an error.

# _helper_calls_read <calls.log> — emit one cleaned "METHOD target" per request.
#
# Strips a single trailing CR (a Windows-authored log) and drops blank lines.
# The CR is removed with a bare `$'\r'` suffix pattern, never a `$'\r\n'` glob:
# the MSYS bash matcher lets a CRLF inside a pattern match a bare LF, which is
# how feature 015's line-ending detector called every LF host CRLF.
_helper_calls_read() {
  local file="$1" line
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -n "${line}" ]] && printf '%s\n' "${line}"
  done < "${file}"
}

# helper_calls_total <calls.log> — how many requests the scenario issued.
#
# A missing or empty log is 0, which is the answer US2's short-circuit needs.
helper_calls_total() {
  local n=0 _line
  while IFS= read -r _line; do n=$((n + 1)); done < <(_helper_calls_read "$1")
  printf '%s' "${n}"
}

# helper_calls_matching <calls.log> <substring> — how many requests carry
# <substring> anywhere in their "METHOD target" line.
#
# Substring, not glob: callers ask for `/rest/api/3/issue/bulkfetch` or
# `GET /rest/api/3/issue/PROJ-1`, and a literal comparison is what makes the
# assertion readable in the failure output.
helper_calls_matching() {
  local file="$1" needle="$2" n=0 line
  while IFS= read -r line; do
    [[ "${line}" == *"${needle}"* ]] && n=$((n + 1))
  done < <(_helper_calls_read "${file}")
  printf '%s' "${n}"
}

# helper_calls_by_path <calls.log> — a per-target tabulation, one
# "<count><TAB><METHOD target>" line per distinct request, sorted by target so
# two runs of the same scenario produce byte-identical output.
#
# This is the diffable form: a test that wants "the read phase issued one
# bulkfetch and no per-key GET" reads better as a comparison against a fixed
# block than as six separate count assertions.
helper_calls_by_path() {
  local count rest
  _helper_calls_read "$1" | LC_ALL=C sort | LC_ALL=C uniq -c |
    while read -r count rest; do
      printf '%s\t%s\n' "${count}" "${rest}"
    done
}
