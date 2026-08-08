#!/usr/bin/env bash
# lib/credentials.sh — Credential resolution (ELIMINATORY NFR-3 / SC-007).
#
# Resolution order: environment -> OS secret manager -> gitignored .env.
# The resolved token NEVER touches argv, logs, errors, or an xtrace: every
# function that handles the token disables `set -x` for its duration, and the
# Authorization header is delivered to curl via `--config` on stdin (see
# sink/jira/client.sh) — never `-H` on the command line.
#
# Port infrastructure only: NO Jira knowledge (Basic auth over HTTP is generic).

[[ -n ${_JIRA_LIB_CREDENTIALS:-} ]] && return 0
_JIRA_LIB_CREDENTIALS=1

# Directory holding the gitignored .env (overridable for tests).
: "${JIRA_CONFIG_DIR:=.specify/jira}"

# Token handling brackets `set +x` around itself using a FUNCTION-LOCAL saved
# state (never a global — nested calls must not clobber each other) so a caller's
# `set -x` never traces a secret. The guard stays down through the printf and the
# final emptiness test; xtrace is only restored once no token value remains live.

# Per-process credential cache (021, US3, contracts/credential-cache.md). Filled
# at most once — by `cred_prime_cache` called from the main shell, or on first
# miss inside `cred_resolve_token` — so the secret store is asked at most once
# no matter how many requests (and retries) the run issues. Both non-exported:
# a child process spawned mid-run must never inherit a copy of the token.
_CRED_CACHE_STATE="unset"
_CRED_CACHE_TOKEN=""

# kcov-excl-start — every token-handling function below runs with xtrace
# suspended (NFR-3 / SC-007), so kcov's tracer cannot observe these lines;
# the credential suites exercise all three resolution sources.
# _cred_from_secret_manager — query the OS secret manager. Test-overridable via
# _CRED_SECRET_TOKEN. Returns empty (non-fatal) when unavailable.
_cred_from_secret_manager() {
  if [[ -n "${_CRED_SECRET_TOKEN:-}" ]]; then
    printf '%s' "${_CRED_SECRET_TOKEN}"
    return 0
  fi
  if command -v security > /dev/null 2>&1; then
    # macOS Keychain. Failure is non-fatal (fall through to .env).
    security find-generic-password -s spec-kit-jira -w 2> /dev/null || true
  elif command -v secret-tool > /dev/null 2>&1; then
    # Linux libsecret.
    secret-tool lookup service spec-kit-jira 2> /dev/null || true
  fi
}

# _cred_from_env_file — read JIRA_API_TOKEN from the gitignored .env, if present.
# Follows the dotenv conventions a user will actually write: an optional
# `export ` prefix, one pair of surrounding quotes, and CRLF line endings from a
# Windows-authored file — none of which may leak into the token (a corrupted
# token turns into an unexplained 401).
_cred_from_env_file() {
  local env_file="${JIRA_CONFIG_DIR}/.env"
  [[ -f "${env_file}" ]] || return 0
  # Extract the value without sourcing (avoid executing arbitrary content).
  local line t val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    t="${line%$'\r'}"
    t="${t#"${t%%[![:space:]]*}"}"
    case "${t}" in
      export[[:space:]]*)
        t="${t#export}"
        t="${t#"${t%%[![:space:]]*}"}"
        ;;
    esac
    case "${t}" in
      JIRA_API_TOKEN=*)
        val="${t#JIRA_API_TOKEN=}"
        if [[ ${#val} -ge 2 && "${val}" == \"*\" ]]; then
          val="${val#\"}" val="${val%\"}"
        elif [[ ${#val} -ge 2 && "${val}" == \'*\' ]]; then
          val="${val#\'}" val="${val%\'}"
        fi
        printf '%s' "${val}"
        return 0
        ;;
    esac
  done < "${env_file}"
}

# cred_resolve_token — print the resolved token to stdout; return 1 if none.
# Reads the cache when filled (by cred_prime_cache or a prior call); otherwise
# resolves through the three rungs and fills it (cache-on-miss, so correctness
# never depends on cred_prime_cache having run first — only the "at most once"
# guarantee does).
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
      else
        token="$(_cred_from_secret_manager)"
        [[ -z "${token}" ]] && token="$(_cred_from_env_file)"
      fi
      if [[ -z "${token}" ]]; then
        _CRED_CACHE_STATE="unresolved"
        rc=1
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

# cred_prime_cache — fill the cache once, from the MAIN shell (research R3: a
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
cred_curl_config() {
  local email="$1"
  local _xt=0
  case "$-" in *x*) _xt=1; set +x ;; esac
  local token basic rc=0
  if token="$(cred_resolve_token)"; then
    basic="$(printf '%s:%s' "${email}" "${token}" | base64 | tr -d '\n')"
    printf 'header = "Authorization: Basic %s"\n' "${basic}"
  else
    rc=1
  fi
  [[ "${_xt}" == 1 ]] && set -x
  return "${rc}"
}
# kcov-excl-stop
