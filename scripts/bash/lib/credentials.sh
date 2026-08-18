#!/usr/bin/env bash
# lib/credentials.sh — Credential resolution (030, contracts/credential-resolution.md).
#
# Resolution order: environment variable -> operator-declared retrieval command
# (JIRA_PAT_COMMAND). No .env, no hardcoded secret-manager probe — a store is
# reached only through a command the operator declares. The resolved token
# NEVER touches argv, logs, errors, or an xtrace: every function that handles
# the token disables `set -x` for its duration, and the Authorization header is
# delivered to curl via `--config` on stdin (see sink/jira/client.sh) — never
# `-H` on the command line.
#
# Port infrastructure only: NO Jira knowledge (Basic auth over HTTP is generic).

[[ -n ${_JIRA_LIB_CREDENTIALS:-} ]] && return 0
_JIRA_LIB_CREDENTIALS=1

# Directory holding gitignored per-operator files (overridable for tests).
: "${JIRA_CONFIG_DIR:=.specify/jira}"

# The retrieval command's execution bound (C2.5, C7's R3): 5 seconds, the same
# literal in both ports, not configurable — the failure message names it
# (SC-003), so a "sensible default per port" would be a conformance divergence.
_CRED_BOUND_SECONDS=5

# Token handling brackets `set +x` around itself using a FUNCTION-LOCAL saved
# state (never a global — nested calls must not clobber each other) so a caller's
# `set -x` never traces a secret. The guard stays down through the printf and the
# final emptiness test; xtrace is only restored once no token value remains live.

# Per-process credential cache (021, US3, contracts/credential-cache.md). Filled
# at most once — by `cred_prime_cache` called from the main shell, or on first
# miss inside `cred_resolve_token` — so the retrieval command is run at most once
# no matter how many requests (and retries) the run issues (C2.6). Both non-
# exported: a child process spawned mid-run must never inherit a copy (C4.5).
_CRED_CACHE_STATE="unset"
_CRED_CACHE_TOKEN=""

# _CRED_LAST_ERROR — set by cred_resolve_token on failure to the located reason
# (C3.3-C3.7), consumed by both call sites (C6.1-C6.3) and by the config
# ceremony's degraded-mode trigger (C6.4-C6.6). NEVER contains anything the
# retrieval command wrote to stdout (C4.4) — only the command's own stderr, and
# only for the "declared and failed" class.
_CRED_LAST_ERROR=""

# _CRED_CMD_RESULT — the retrieval command's trimmed stdout, set by
# _cred_from_command when called DIRECTLY (never through `$( … )`, see there).
_CRED_CMD_RESULT=""

# kcov-excl-start — every token-handling function below runs with xtrace
# suspended (NFR-3 / SC-007), so kcov's tracer cannot observe these lines;
# the credential suites exercise both resolution sources.

# _cred_trim <string> — strip leading/trailing whitespace (including \r, for a
# Windows-authored helper). Interior whitespace is preserved (C2.3).
_cred_trim() {
  local t="$1"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "${t}"
}

# _cred_from_command <command-line> — execute JIRA_PAT_COMMAND's value as a
# tokenized argument vector (C2.1: no shell, no eval — a pipe or `$(...)` in
# the value arrives as a literal, inert argument, C2.2), bounded at
# _CRED_BOUND_SECONDS (C2.5). On success sets _CRED_CMD_RESULT to the trimmed
# stdout (C2.3) and returns 0; on any failure sets _CRED_LAST_ERROR to the
# located reason (never echoing the command's own stdout, C4.4) and returns 1.
# MUST be called DIRECTLY, never through `$( … )` — a subshell would compute
# both globals and discard them with the subshell itself (the same trap
# lib/config.sh documents for its recursive parsers).
_cred_from_command() {
  local cmdline="$1"
  local -a argv=()
  # shellcheck disable=SC2206  # deliberate whitespace tokenization (research R2)
  read -ra argv <<< "${cmdline}"
  if [[ ${#argv[@]} -eq 0 ]]; then
    _CRED_LAST_ERROR="credential resolution failed: JIRA_PAT_COMMAND is empty — see docs/CREDENTIALS.md"
    return 1
  fi
  if ! command -v "${argv[0]}" > /dev/null 2>&1; then
    _CRED_LAST_ERROR="credential resolution failed: JIRA_PAT_COMMAND '${cmdline}' could not be executed — see docs/CREDENTIALS.md"
    return 1
  fi

  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  "${argv[@]}" > "${out_file}" 2> "${err_file}" &
  local pid=$!

  # Watchdog: no `timeout(1)` dependency (not universal on macOS, research R3).
  # A sentinel file distinguishes "we killed it" from a command that happened
  # to exit with the same signal-derived status on its own.
  local timeout_flag
  timeout_flag="$(mktemp)"
  rm -f "${timeout_flag}"
  (
    sleep "${_CRED_BOUND_SECONDS}"
    if kill -0 "${pid}" 2> /dev/null; then
      : > "${timeout_flag}"
      kill -TERM "${pid}" 2> /dev/null
    fi
  ) &
  local watchdog=$!

  local rc=0
  wait "${pid}" 2> /dev/null || rc=$?
  kill "${watchdog}" 2> /dev/null
  wait "${watchdog}" 2> /dev/null

  local out err
  out="$(cat "${out_file}" 2> /dev/null)"
  err="$(cat "${err_file}" 2> /dev/null)"

  if [[ -f "${timeout_flag}" ]]; then
    rm -f "${timeout_flag}" "${out_file}" "${err_file}"
    _CRED_LAST_ERROR="credential resolution failed: JIRA_PAT_COMMAND '${cmdline}' exceeded the ${_CRED_BOUND_SECONDS}s bound — see docs/CREDENTIALS.md"
    return 1
  fi
  rm -f "${timeout_flag}" "${out_file}" "${err_file}" 2> /dev/null

  if ((rc != 0)); then
    _CRED_LAST_ERROR="credential resolution failed: JIRA_PAT_COMMAND '${cmdline}' exited with status ${rc} — see docs/CREDENTIALS.md"
    err="$(_cred_trim "${err}")"
    [[ -n "${err}" ]] && _CRED_LAST_ERROR="${_CRED_LAST_ERROR} (stderr: ${err})"
    return 1
  fi

  local trimmed
  trimmed="$(_cred_trim "${out}")"
  if [[ -z "${trimmed}" ]]; then
    _CRED_LAST_ERROR="credential resolution failed: JIRA_PAT_COMMAND '${cmdline}' produced no output — see docs/CREDENTIALS.md"
    return 1
  fi
  _CRED_CMD_RESULT="${trimmed}"
  return 0
}

# cred_resolve_token — print the resolved token to stdout; return 1 if none,
# setting _CRED_LAST_ERROR to the located reason (C3.3-C3.7). Reads the cache
# when filled (by cred_prime_cache or a prior call); otherwise resolves through
# the two rungs and fills it (cache-on-miss, so correctness never depends on
# cred_prime_cache having run first — only the "at most once" guarantee does,
# C5.3).
cred_resolve_token() {
  local _xt=0
  case "$-" in *x*) _xt=1; set +x ;; esac
  local token="" rc=0
  case "${_CRED_CACHE_STATE}" in
    resolved) token="${_CRED_CACHE_TOKEN}" ;;
    unresolved) rc=1 ;;
    *)
      if [[ -n "${JIRA_API_TOKEN:-}" ]]; then
        token="${JIRA_API_TOKEN}"
      elif [[ -n "${_CRED_SECRET_TOKEN:-}" ]]; then
        # Test override (C1.5): stands in for a successful retrieval-command
        # run, so no test needs a real vault. Keeps precedence over actually
        # executing JIRA_PAT_COMMAND.
        token="${_CRED_SECRET_TOKEN}"
      elif [[ -n "${JIRA_PAT_COMMAND:-}" ]]; then
        if _cred_from_command "${JIRA_PAT_COMMAND}"; then
          token="${_CRED_CMD_RESULT}"
        else
          rc=1
        fi
      else
        _CRED_LAST_ERROR="credential resolution failed: neither JIRA_API_TOKEN nor JIRA_PAT_COMMAND is set — see docs/CREDENTIALS.md"
        rc=1
      fi
      if [[ "${rc}" == 0 && -z "${token}" ]]; then
        rc=1
      fi
      if ((rc != 0)); then
        _CRED_CACHE_STATE="unresolved"
      else
        _CRED_CACHE_STATE="resolved"
        _CRED_CACHE_TOKEN="${token}"
      fi
      ;;
  esac
  # Emit and test emptiness while still suspended — the token is live here.
  [[ "${rc}" == 0 ]] && printf '%s' "${token}"
  [[ "${_xt}" == 1 ]] && set -x
  return "${rc}"
}

# cred_prime_cache — fill the cache once, from the MAIN shell (research R2/R3: a
# cache filled inside a `$(jira_request …)` subshell dies with it). Returns 0
# whether or not a token was found — priming is not a gate. Prints nothing.
cred_prime_cache() {
  local _xt=0
  case "$-" in *x*) _xt=1; set +x ;; esac
  cred_resolve_token > /dev/null 2>&1 || true
  [[ "${_xt}" == 1 ]] && set -x
  return 0
}

# cred_curl_config <email> — emit a curl `--config` document carrying the
# Authorization header (Basic email:token, base64). Consumed on stdin by curl
# so the token never appears in argv. The raw token never appears here.
#
# On a resolution failure, prints the located reason to STDERR itself (C6.1)
# before returning 1. `cred_resolve_token` is called DIRECTLY below (its
# stdout redirected, never captured through `$( … )`) so `_CRED_LAST_ERROR`
# and the resolved token (read back from `_CRED_CACHE_TOKEN`, filled by that
# same call) are both visible in THIS shell, not lost in a subshell that died
# before this function could read them — the same trap lib/config.sh documents
# for its recursive parsers. A caller of THIS function, e.g.
# `cfg="$(cred_curl_config …)"`, may still wrap it in `$( … )`: stderr is not
# captured by that construct, so the message printed here survives the
# boundary and reaches the terminal exactly where the failure occurred — this
# is what `sink/jira/client.sh` relies on to satisfy C6.1 without touching the
# global itself.
cred_curl_config() {
  local email="$1"
  local _xt=0
  case "$-" in *x*) _xt=1; set +x ;; esac
  local token basic rc=0
  if cred_resolve_token > /dev/null; then
    token="${_CRED_CACHE_TOKEN}"
    basic="$(printf '%s:%s' "${email}" "${token}" | base64 | tr -d '\n')"
    printf 'header = "Authorization: Basic %s"\n' "${basic}"
  else
    rc=1
  fi
  [[ "${_xt}" == 1 ]] && set -x
  if ((rc != 0)); then
    printf '%s\n' "${_CRED_LAST_ERROR}" >&2
  fi
  return "${rc}"
}
# kcov-excl-stop
