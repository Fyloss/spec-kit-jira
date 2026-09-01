#!/usr/bin/env bash
# sink/jira/client.sh — Jira Cloud REST v3 transport (SINK layer).
#
# The single HTTP conduit to Jira. Every request:
#   * carries the Authorization header via `curl --config` on stdin — NEVER argv
#     (NFR-3 / SC-007): the base64 credential never reaches a command line, a log,
#     or an xtrace (the whole function runs with xtrace suspended);
#   * retries a 429 with backoff honouring `Retry-After` up to JIRA_MAX_ATTEMPTS;
#   * maps outcomes to the shared, monotonic exit-code table (Constitution III):
#       2xx            -> 0        (body printed to stdout)
#       401 / 403      -> auth (3)
#       404 / 5xx / network / 429-exhausted -> fail_closed (2)  (zero stdout)
#
# On failure NOTHING is written to stdout so a caller capturing the body sees the
# empty result of a fail-closed read (zero writes downstream, FR-032).

[[ -n ${_JIRA_SINK_CLIENT:-} ]] && return 0
_JIRA_SINK_CLIENT=1

_client_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_client_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_client_dir}/../../lib/credentials.sh"

# Bounded retry budget (total attempts, including the first). Overridable so the
# transport suites can pin the exact number of calls that reach the mock.
: "${JIRA_MAX_ATTEMPTS:=3}"

# JIRA_PATH_STYLE — how the curl on PATH spells a filesystem path: `native` on
# git-bash, where curl is a Windows binary that cannot open the POSIX paths this
# shell speaks, and `posix` everywhere else. Detected once from the host and
# overridable, so the guard below is exercisable on a host that does not need
# it — tests/bash/sink/test_client_body_path.bats runs it everywhere.
: "${JIRA_PATH_STYLE:=$(
  case "$(uname -s 2> /dev/null || true)" in
    MINGW* | MSYS* | CYGWIN*) printf 'native' ;;
    *) printf 'posix' ;;
  esac
)}"

# _jira_curl_path <posix-path> — that path spelled for the curl on PATH.
#
# It matters in exactly one place, and that place is invisible to MSYS. The body
# is kept OFF argv (NFR-3) by writing it to a file and naming that file from the
# curl config, and the config travels on STDIN. MSYS rewrites paths it sees in
# argv — which is why --output and --dump-header need nothing here — but stdin
# is opaque bytes to it. A POSIX path in the config therefore reached a native
# curl untranslated, curl could not open it, and the transport mapped the
# non-zero curl status to fail-closed: on windows-latest EVERY write failed
# before reaching the network while every read succeeded, because only a request
# with a body has a path to mistranslate.
#
# `-m` (mixed: `C:/Users/...`), never `-w` (`C:\Users\...`). Asked of the runner
# rather than reasoned about, by building this exact config against a dead port
# and reading curl's exit code — 26 for a data file it cannot open, 7 for one it
# read before failing to connect:
#
#   posix=26  win=26  mixed=7
#
# `-w` fails identically to the POSIX path it replaces, because curl's config
# parser reads a quoted value's backslashes as escape sequences. A first fix
# shipped `-w` and the probe came back byte-identical; that is what prompted
# measuring instead of deducing.
_jira_curl_path() {
  if [[ "${JIRA_PATH_STYLE}" == "native" ]] && command -v cygpath > /dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

# HTTP status of the most recent request (0 = network-level failure). A plain
# shell variable, NOT exported: every reader (plan_apply, identity,
# recognition) is a function sourced into this SAME bash process, and a
# `$( … )` subshell already inherits every shell variable regardless of
# export status — export only matters across an execve() boundary. `export`
# was removed here (T161 investigation) because the response body it sits
# beside is response-sized and unbounded: once 027's bulkfetch responses
# started carrying full issue descriptions, an exported JIRA_LAST_ERROR_BODY
# pushed the process environment past Linux's MAX_ARG_STRLEN (128 KiB) on the
# very next execve of ANY external command — cat, rm, jq, mktemp alike —
# invisible on macOS, which enforces no such per-argument/environment cap.
JIRA_LAST_STATUS=0

# Raw response body of the most recent request, success or failure (011,
# contract §3.7, FR-019). Never printed to a human directly — a caller
# translates it (ticket_field_rejection_message) before it reaches the run
# summary, so the raw API body itself never leaks into output. NOT exported
# — see JIRA_LAST_STATUS above; this is the variable whose size actually
# triggered the Linux argv/environment overflow.
JIRA_LAST_ERROR_BODY=''

# Total curl attempts issued so far, including retries (contracts/timing-report.md
# §5). NOT exported. A caller that invokes jira_request via `$( … )` (discovery.sh,
# ticket.sh, duplicate_probe.sh — 15 of 28 call sites) loses this variable's
# increment to the subshell on exit, so it is not itself a reliable total; the
# counter file below (jira_request_count_prime / jira_request_count) is what
# survives a subshell, and is what a caller wanting the true count reads instead.
: "${JIRA_REQUEST_COUNT:=0}"

# _JIRA_REQUEST_COUNT_FILE — the true, subshell-proof request tally
# (data-model.md §3, contracts/request-counting.md). A bash variable
# increment made inside a `$( … )` subshell is discarded when that subshell
# exits (research R2); a byte appended to a file on disk is not, and needs no
# external process to append or to read back (see jira_request_count below) —
# spawning one per request would defeat the very feature this counter serves.
: "${_JIRA_REQUEST_COUNT_FILE:=}"

# jira_request_count_prime — create the counter file once, in the parent
# shell, before the first phase that can issue a request (contracts/
# request-counting.md C2.1). Call this the same way cred_prime_cache is
# called (research R3/R5, feature 021): from the main shell only, never from
# inside a `$( … )` subshell, or the path itself is lost when that subshell
# exits and every later call re-primes into a file nothing else can see.
jira_request_count_prime() {
  [[ -n "${_JIRA_REQUEST_COUNT_FILE}" ]] && return 0
  _JIRA_REQUEST_COUNT_FILE="$(mktemp)" || _JIRA_REQUEST_COUNT_FILE=""
}

# jira_request_count — the true total requests issued so far, read back with
# no external process (a `read … -d ''` slurp is a shell builtin). 0 when
# priming never happened — a run that issues no request never creates the
# file — and fail-open (FR-037, C2.4): an unreadable file counts as zero
# rather than failing the caller.
jira_request_count() {
  if [[ -z "${_JIRA_REQUEST_COUNT_FILE}" || ! -s "${_JIRA_REQUEST_COUNT_FILE}" ]]; then
    printf '0'
    return 0
  fi
  local content=""
  IFS= read -r -d '' content < "${_JIRA_REQUEST_COUNT_FILE}" 2> /dev/null
  printf '%s' "${#content}"
}

# kcov-excl-start — jira_request suspends xtrace for its whole duration
# (NFR-3 / SC-007: the credential must never be traced), so kcov's tracer
# cannot observe this machinery; the transport suites exercise it end-to-end.
# _jira_sleep <seconds> — real backoff sleep, suppressed in tests via JIRA_NO_SLEEP.
_jira_sleep() {
  [[ -n "${JIRA_NO_SLEEP:-}" ]] && return 0
  sleep "$1"
}

# _jira_retry_after <header-file> <attempt> — seconds to wait before the next try:
# the response's Retry-After when it is a plain integer, else exponential backoff.
_jira_retry_after() {
  local hdrfile="$1" attempt="$2" val
  val="$(grep -i '^Retry-After:' "${hdrfile}" | head -n1 | tr -d '\r' | sed 's/^[^:]*:[[:space:]]*//')"
  if [[ "${val}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${val}"
  else
    printf '%s' "$((1 << (attempt - 1)))"
  fi
}

# jira_request <method> <url> [body] — perform the request; print the body on
# success; return the mapped exit code. JIRA_EMAIL supplies the Basic-auth email.
jira_request() {
  local method="$1" url="$2" body="${3:-}"
  local email="${JIRA_EMAIL:-}"

  # Suspend xtrace for the whole function: the curl config we pipe on stdin
  # carries the base64 credential and must never be traced (NFR-3 / SC-007).
  local _xt=0
  case "$-" in *x*) _xt=1; set +x ;; esac

  local rc=0 attempt=1 delay
  local hdrfile respfile bodyfile=""
  hdrfile="$(mktemp)"
  respfile="$(mktemp)"
  if [[ -n "${body}" ]]; then
    bodyfile="$(mktemp)"
    printf '%s' "${body}" > "${bodyfile}"
  fi

  while :; do
    : > "${hdrfile}"
    : > "${respfile}"

    # Build the curl config on stdin: the auth header first, then the request
    # shape. Data (never secret) is referenced from a file, still off argv.
    # A resolution failure here (030, C6.1) is reported by cred_curl_config
    # itself, to stderr, before it returns — this call site only needs to map
    # the failure to the auth exit code, not construct the message.
    local cfg
    # 032, C6.1 — the destination travels with the request so the producer can
    # refuse an unbound one. Passing it here is what makes the guarantee
    # structural rather than a convention every future call site must remember.
    if ! cfg="$(cred_curl_config "${email}" "${url}")"; then
      rc="$(cli_exit_code auth)"
      break
    fi
    cfg="${cfg}"$'\n'"url = \"${url}\""
    cfg="${cfg}"$'\n'"request = \"${method}\""
    cfg="${cfg}"$'\n'"header = \"Content-Type: application/json\""
    cfg="${cfg}"$'\n'"header = \"Accept: application/json\""
    [[ -n "${bodyfile}" ]] && cfg="${cfg}"$'\n'"data = \"@$(_jira_curl_path "${bodyfile}")\""

    JIRA_REQUEST_COUNT=$((JIRA_REQUEST_COUNT + 1))
    # C2.2/C2.4: every attempt, retries included, tallies here too — this is
    # the increment that survives a `$( … )` subshell (research R2). A write
    # failure must never fail the request it is counting (FR-037).
    [[ -n "${_JIRA_REQUEST_COUNT_FILE}" ]] && { printf 'x' >> "${_JIRA_REQUEST_COUNT_FILE}"; } 2> /dev/null
    local http_code curl_rc
    http_code="$(
      printf '%s\n' "${cfg}" | curl --silent --config - \
        --output "${respfile}" --dump-header "${hdrfile}" \
        --write-out '%{http_code}' 2> /dev/null
    )"
    curl_rc=$?

    if [[ "${curl_rc}" -ne 0 ]]; then
      # Network-level failure (dropped connection, DNS, timeout) -> fail-closed.
      JIRA_LAST_STATUS=0
      rc="$(cli_exit_code fail_closed)"
      break
    fi

    # shellcheck disable=SC2034 # read by identity.sh/plan_apply.sh/recognition.sh, sourced into this same process (see the declarations above)
    JIRA_LAST_STATUS="${http_code}"
    # shellcheck disable=SC2034 # same as JIRA_LAST_STATUS above
    JIRA_LAST_ERROR_BODY="$(cat "${respfile}" 2> /dev/null)"
    case "${http_code}" in
      2*)
        cat "${respfile}"
        rc=0
        break
        ;;
      401 | 403)
        rc="$(cli_exit_code auth)"
        break
        ;;
      429)
        if ((attempt < JIRA_MAX_ATTEMPTS)); then
          delay="$(_jira_retry_after "${hdrfile}" "${attempt}")"
          _jira_sleep "${delay}"
          attempt=$((attempt + 1))
          continue
        fi
        rc="$(cli_exit_code fail_closed)"
        break
        ;;
      *)
        rc="$(cli_exit_code fail_closed)"
        break
        ;;
    esac
  done

  rm -f "${hdrfile}" "${respfile}"
  [[ -n "${bodyfile}" ]] && rm -f "${bodyfile}"
  [[ "${_xt}" == 1 ]] && set -x
  return "${rc}"
}

# jira_request_multipart <method> <url> <parts-json> — a multipart/form-data
# request carrying one `file` part per entry of <parts-json>
# (036 contracts/artifact-publication.md C2.1; FR-023).
#
# <parts-json> is an array of `{attachment_name, file}` objects: the name the
# part must carry, and the absolute on-disk path to read it from.
#
# This is a SIBLING of jira_request rather than a flag on it, and deliberately
# so: the two build different configs (this one sets no Content-Type, because
# curl composes the multipart boundary itself, and adds the XSRF header Jira
# requires for uploads) while sharing everything that matters — the credential
# on stdin, the bounded retry, the monotonic exit-code mapping. A flag would
# have put two request shapes inside one already long function.
#
# Three constraints meet here and only this shape satisfies all three:
#
#   * The credential stays OFF ARGV. The parts join the config that already
#     travels on stdin; they never become `-F` arguments (NFR-3 / SC-007).
#   * Every path is spelled for the curl that will OPEN it, through
#     `_jira_curl_path` — the measured MSYS behaviour recorded at the top of
#     this file (posix=26, win=26, mixed=7 against a dead port).
#   * The argument vector does not grow with the artifact set. One `-F` per
#     artifact would, and the cap that binds is Windows counting the WHOLE
#     command line against ~32767 bytes, not this host's.
#
# `;filename=` is not optional: without it curl derives the part name from the
# path's basename, and `contracts/api.md` would arrive as `api.md` — exactly
# the collision the flattening exists to prevent.
jira_request_multipart() {
  local method="$1" url="$2" parts="$3"
  local email="${JIRA_EMAIL:-}"

  # Suspend xtrace for the whole function, as jira_request does: the config
  # piped on stdin carries the base64 credential and must never be traced.
  local _xt=0
  case "$-" in *x*) _xt=1; set +x ;; esac

  local rc=0 attempt=1 delay
  local hdrfile respfile
  hdrfile="$(mktemp)"
  respfile="$(mktemp)"

  while :; do
    : > "${hdrfile}"
    : > "${respfile}"

    local cfg
    if ! cfg="$(cred_curl_config "${email}" "${url}")"; then
      rc="$(cli_exit_code auth)"
      break
    fi
    cfg="${cfg}"$'\n'"url = \"${url}\""
    cfg="${cfg}"$'\n'"request = \"${method}\""
    cfg="${cfg}"$'\n'"header = \"Accept: application/json\""
    # Jira's XSRF check rejects an upload without this. It is the one endpoint
    # in this codebase that needs a header the transport does not already send.
    cfg="${cfg}"$'\n'"header = \"X-Atlassian-Token: no-check\""
    # NO Content-Type: curl composes `multipart/form-data` and its boundary
    # itself, and setting one by hand produces a body curl did not build.

    local name file
    while IFS=$'\x1f' read -r name file; do
      [[ -z "${file}" ]] && continue
      cfg="${cfg}"$'\n'"form = \"file=@$(_jira_curl_path "${file}");filename=${name}\""
    # `\037` in OCTAL, not `\x1f`: BSD `tr` does not understand a hex escape and
    # silently substitutes a literal `x`, which merges the two columns into one
    # field and leaves `file` empty — so every form line vanishes and the
    # request uploads nothing while still returning 200. Caught by the tests;
    # invisible in a run that looks like it worked.
    #
    # `\037` rather than the tab itself for the reason recorded in
    # sink/jira/plan_apply.sh: bash's `read` treats tab as IFS *whitespace* and
    # silently squeezes an empty field.
    done < <(jq -r '.[] | [.attachment_name, .file] | @tsv' <<< "${parts}" 2> /dev/null | tr '\t' '\037')

    JIRA_REQUEST_COUNT=$((JIRA_REQUEST_COUNT + 1))
    [[ -n "${_JIRA_REQUEST_COUNT_FILE}" ]] && { printf 'x' >> "${_JIRA_REQUEST_COUNT_FILE}"; } 2> /dev/null
    local http_code curl_rc
    http_code="$(
      printf '%s\n' "${cfg}" | curl --silent --config - \
        --output "${respfile}" --dump-header "${hdrfile}" \
        --write-out '%{http_code}' 2> /dev/null
    )"
    curl_rc=$?

    if [[ "${curl_rc}" -ne 0 ]]; then
      JIRA_LAST_STATUS=0
      rc="$(cli_exit_code fail_closed)"
      break
    fi
    # shellcheck disable=SC2034 # read by the sink modules sourced into this SAME process, as jira_request's twin assignment is
    JIRA_LAST_STATUS="${http_code}"
    # shellcheck disable=SC2034 # same as JIRA_LAST_STATUS above
    JIRA_LAST_ERROR_BODY="$(cat "${respfile}" 2> /dev/null)"
    case "${http_code}" in
      2*)
        cat "${respfile}"
        rc=0
        break
        ;;
      401 | 403)
        rc="$(cli_exit_code auth)"
        break
        ;;
      429)
        if ((attempt < JIRA_MAX_ATTEMPTS)); then
          delay="$(_jira_retry_after "${hdrfile}" "${attempt}")"
          _jira_sleep "${delay}"
          attempt=$((attempt + 1))
          continue
        fi
        rc="$(cli_exit_code fail_closed)"
        break
        ;;
      *)
        rc="$(cli_exit_code fail_closed)"
        break
        ;;
    esac
  done

  rm -f "${hdrfile}" "${respfile}"
  [[ "${_xt}" == 1 ]] && set -x
  return "${rc}"
}
# kcov-excl-stop
