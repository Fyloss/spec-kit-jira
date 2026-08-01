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
_jira_curl_path() {
  if [[ "${JIRA_PATH_STYLE}" == "native" ]] && command -v cygpath > /dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

# HTTP status of the most recent request (0 = network-level failure). Exported so
# sink callers (plan_apply, discovery) can read it for diagnostics; the mapped
# exit code remains the return value.
JIRA_LAST_STATUS=0
export JIRA_LAST_STATUS

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
    local cfg
    if ! cfg="$(cred_curl_config "${email}")"; then
      rc="$(cli_exit_code auth)"
      break
    fi
    cfg="${cfg}"$'\n'"url = \"${url}\""
    cfg="${cfg}"$'\n'"request = \"${method}\""
    cfg="${cfg}"$'\n'"header = \"Content-Type: application/json\""
    cfg="${cfg}"$'\n'"header = \"Accept: application/json\""
    [[ -n "${bodyfile}" ]] && cfg="${cfg}"$'\n'"data = \"@$(_jira_curl_path "${bodyfile}")\""

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

    JIRA_LAST_STATUS="${http_code}"
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
# kcov-excl-stop
