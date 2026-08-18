#!/usr/bin/env bats
# 030 — Credential resolution (contracts/credential-resolution.md).
# Two rungs: environment variable -> operator-declared retrieval command
# (JIRA_PAT_COMMAND). No .env, no hardcoded secret-manager probe. The
# resolved token NEVER appears in argv, logs, errors, or under `set -x`.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/credentials.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/secret_store_stub.bash"
  TMPDIR_T="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${TMPDIR_T}"
  unset JIRA_API_TOKEN JIRA_PAT_COMMAND _CRED_SECRET_TOKEN
}

teardown() {
  rm -rf "${TMPDIR_T}"
}

# --- §1/§3 Sources and outcomes (C1.1, C3.1-C3.11) --------------------------

@test "resolves the token from the environment first (C3.1)" {
  JIRA_API_TOKEN="env-token" run cred_resolve_token
  [ "$status" -eq 0 ]
  [ "$output" = "env-token" ]
}

@test "no JIRA_API_TOKEN, command succeeds with non-empty stdout: token resolved (C3.2)" {
  local bindir counter prog
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  prog="$(helper_pat_command_install "${bindir}" "${counter}" "from-command")"
  JIRA_PAT_COMMAND="${prog}" run cred_resolve_token
  [ "$status" -eq 0 ]
  [ "$output" = "from-command" ]
}

@test "environment token wins over a declared command, which is never executed (C3.11)" {
  local bindir counter prog
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  prog="$(helper_pat_command_install "${bindir}" "${counter}" "from-command")"
  JIRA_API_TOKEN="env-token" JIRA_PAT_COMMAND="${prog}" run cred_resolve_token
  [ "$output" = "env-token" ]
  [ "$(helper_pat_command_count "${counter}")" = "0" ]
}

@test "the _CRED_SECRET_TOKEN test override stands in for the command, unexecuted" {
  local bindir counter prog
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  prog="$(helper_pat_command_install "${bindir}" "${counter}" "from-command")"
  _CRED_SECRET_TOKEN="keychain-token" JIRA_PAT_COMMAND="${prog}" run cred_resolve_token
  [ "$output" = "keychain-token" ]
  [ "$(helper_pat_command_count "${counter}")" = "0" ]
}

@test "C3.3: neither variable set — failure names both" {
  run cred_resolve_token
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "C3.3 message names JIRA_API_TOKEN and JIRA_PAT_COMMAND" {
  cred_resolve_token > /dev/null 2>&1 || true
  [[ "${_CRED_LAST_ERROR}" == *"JIRA_API_TOKEN"* ]]
  [[ "${_CRED_LAST_ERROR}" == *"JIRA_PAT_COMMAND"* ]]
}

@test "C3.4: command not found — message names it and that it could not be executed" {
  JIRA_PAT_COMMAND="spec-kit-jira-no-such-helper" cred_resolve_token > /dev/null 2>&1 || true
  [[ "${_CRED_LAST_ERROR}" == *"spec-kit-jira-no-such-helper"* ]]
  [[ "${_CRED_LAST_ERROR}" == *"could not be executed"* ]]
}

@test "C3.5: command exits non-zero — message names it and the exit status" {
  local bindir counter prog
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  prog="$(helper_pat_command_install "${bindir}" "${counter}" "" 3)"
  JIRA_PAT_COMMAND="${prog}" cred_resolve_token > /dev/null 2>&1 || true
  [[ "${_CRED_LAST_ERROR}" == *"${prog}"* ]]
  [[ "${_CRED_LAST_ERROR}" == *"status 3"* ]]
}

@test "C3.7: command exits zero with empty stdout — message names it and that output was empty" {
  local bindir counter prog
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  prog="$(helper_pat_command_install "${bindir}" "${counter}" "")"
  JIRA_PAT_COMMAND="${prog}" cred_resolve_token > /dev/null 2>&1 || true
  [[ "${_CRED_LAST_ERROR}" == *"${prog}"* ]]
  [[ "${_CRED_LAST_ERROR}" == *"produced no output"* ]]
}

@test "C3.6: command exceeds the bound — message names it and the bound" {
  _CRED_BOUND_SECONDS=1
  JIRA_PAT_COMMAND="sleep 5" cred_resolve_token > /dev/null 2>&1 || true
  [[ "${_CRED_LAST_ERROR}" == *"sleep 5"* ]]
  [[ "${_CRED_LAST_ERROR}" == *"1s bound"* ]]
}

@test "C2.3: interior whitespace preserved, surrounding whitespace (incl. CR) trimmed" {
  local bindir counter prog
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  mkdir -p "${bindir}"
  prog="${bindir}/spaced"
  printf '#!/usr/bin/env bash\nprintf "  a b  \\r\\n"\n' > "${prog}"
  chmod +x "${prog}"
  JIRA_PAT_COMMAND="${prog}" run cred_resolve_token
  [ "$status" -eq 0 ]
  [ "$output" = "a b" ]
}

@test "C2.4: the command's stderr never contributes to the token's value" {
  local bindir prog
  bindir="${TMPDIR_T}/bin"
  mkdir -p "${bindir}"
  prog="${bindir}/noisy"
  printf '#!/usr/bin/env bash\necho leaked-on-stderr >&2\nprintf "real-token"\n' > "${prog}"
  chmod +x "${prog}"
  JIRA_PAT_COMMAND="${prog}" run cred_resolve_token
  [ "$status" -eq 0 ]
  [ "$output" = "real-token" ]
}

@test "C2.2: shell metacharacters in JIRA_PAT_COMMAND are inert" {
  rm -f "${TMPDIR_T}/x"
  JIRA_PAT_COMMAND="echo a | tee ${TMPDIR_T}/x" run cred_resolve_token
  [ "$status" -eq 0 ]
  [ "$output" = "a | tee ${TMPDIR_T}/x" ]
  [ ! -f "${TMPDIR_T}/x" ]
}

@test "C2.1: no shell, no eval — Invoke-Expression-style substitution is never evaluated" {
  rm -f "${TMPDIR_T}/evidence"
  JIRA_PAT_COMMAND='echo $(touch '"${TMPDIR_T}"'/evidence)' run cred_resolve_token
  [ ! -f "${TMPDIR_T}/evidence" ]
}

@test "C2.5: execution is bounded, and the bound is not configurable from a file" {
  # No requirement asks for a knob (research R3): only the in-process
  # _CRED_BOUND_SECONDS override (test-only) changes the bound.
  run declare -p _CRED_BOUND_SECONDS
  [[ "${output}" == *"5"* ]]
}

# --- §1 Sources — the .env rung and the hardcoded probe are gone -----------

@test "C1.2: a gitignored .env holding a token is never opened — ignored entirely, no message names it" {
  printf 'JIRA_API_TOKEN=file-token\n' > "${TMPDIR_T}/.env"
  run cred_resolve_token
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "${_CRED_LAST_ERROR}" != *".env"* ]]
}

@test "C1.3/C1.3a: a security stand-in on PATH returning a token is never consulted absent a declared command" {
  local bindir counter
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  helper_secret_store_install "${bindir}" "${counter}" "from-the-store"
  PATH="${bindir}:${PATH}" run cred_resolve_token
  [ "$status" -ne 0 ]
  [ "$(helper_secret_store_count "${counter}")" = "0" ]
}

@test "_cred_from_env_file and _cred_from_secret_manager no longer exist" {
  run declare -F _cred_from_env_file
  [ "$status" -ne 0 ]
  run declare -F _cred_from_secret_manager
  [ "$status" -ne 0 ]
}

# --- §4 Secrecy --------------------------------------------------------------

@test "resolved token NEVER appears under set -x (NFR-3, SC-007)" {
  trace="$(mktemp)"
  JIRA_API_TOKEN="RAWSECRETXYZ" bash -c '
    source "'"${LIB_DIR}"'/credentials.sh"
    exec 9>"'"${trace}"'"
    export BASH_XTRACEFD=9
    set -x
    cred_resolve_token > /dev/null
    header="$(cred_curl_config user@example.com)"
    set +x
  '
  run grep -c "RAWSECRETXYZ" "${trace}"
  [ "$output" = "0" ]
  rm -f "${trace}"
}

@test "cred_curl_config emits Basic auth base64, never the raw token (NFR-3)" {
  out="$(JIRA_API_TOKEN=RAWSECRETXYZ cred_curl_config user@example.com)"
  [[ "$out" != *"RAWSECRETXYZ"* ]]
  [[ "$out" == *"Authorization: Basic "* ]]
  b64="$(printf '%s' "$out" | sed -n 's/.*Basic \([A-Za-z0-9+/=]*\).*/\1/p')"
  decoded="$(printf '%s' "$b64" | base64 -d)"
  [ "$decoded" = "user@example.com:RAWSECRETXYZ" ]
}

@test "C4.4: a failure report never echoes the command's own stdout" {
  local bindir counter prog
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  mkdir -p "${bindir}"
  prog="${bindir}/partial"
  printf '#!/usr/bin/env bash\nprintf "PARTIAL-SECRET-ON-STDOUT"\nexit 1\n' > "${prog}"
  chmod +x "${prog}"
  JIRA_PAT_COMMAND="${prog}" cred_resolve_token > /dev/null 2>&1 || true
  [[ "${_CRED_LAST_ERROR}" != *"PARTIAL-SECRET-ON-STDOUT"* ]]
}

@test "cred_curl_config prints the located reason to stderr, never the raw token, on failure" {
  out="$(cred_curl_config user@example.com 2>"${TMPDIR_T}/err")" || true
  [ -z "${out}" ]
  run cat "${TMPDIR_T}/err"
  [[ "${output}" == *"credential resolution failed"* ]]
}

# --- §2.6/§5 Cache — at most once per run -----------------------------------

@test "the credential cache variable is never exported; a child process born mid-run inherits no copy of the token (T036)" {
  _CRED_SECRET_TOKEN="MID-RUN-SECRET-TOKEN" cred_prime_cache
  run declare -p _CRED_CACHE_TOKEN
  [[ "${output}" == "declare -- _CRED_CACHE_TOKEN="* ]]
  run env
  [[ "${output}" != *"MID-RUN-SECRET-TOKEN"* ]]
}

@test "credential rotation: two runs pick up two different stub tokens (T037)" {
  local out1 out2
  out1="$(_CRED_SECRET_TOKEN="token-one" bash -c '
    source "'"${LIB_DIR}"'/credentials.sh"
    cred_prime_cache
    cred_resolve_token
  ')"
  out2="$(_CRED_SECRET_TOKEN="token-two" bash -c '
    source "'"${LIB_DIR}"'/credentials.sh"
    cred_prime_cache
    cred_resolve_token
  ')"
  [ "${out1}" = "token-one" ]
  [ "${out2}" = "token-two" ]
}

@test "an unresolved outcome caches as 'unresolved', a state distinct from an empty resolved token (T037)" {
  cred_prime_cache
  run declare -p _CRED_CACHE_STATE
  [[ "${output}" == *"unresolved"* ]]
  run cred_resolve_token
  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
}

@test "C2.6: an unresolved cache is not re-consulted on a second resolve" {
  local bindir counter prog
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  # A command that fails every time — the cache must still short-circuit the
  # SECOND call rather than re-running it.
  mkdir -p "${bindir}"
  prog="${bindir}/always-fails"
  printf '#!/usr/bin/env bash\nprintf "x\\n" >> "%s"\nexit 1\n' "${counter}" > "${prog}"
  chmod +x "${prog}"
  : > "${counter}"
  JIRA_PAT_COMMAND="${prog}" cred_prime_cache
  JIRA_PAT_COMMAND="${prog}" run cred_resolve_token
  [ "${status}" -ne 0 ]
  [ "$(helper_pat_command_count "${counter}")" = "1" ]
}

@test "C2.6: JIRA_PAT_COMMAND is executed at most once across several \$( jira_request … ) subshells" {
  local bindir counter prog
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  prog="$(helper_pat_command_install "${bindir}" "${counter}" "tok")"
  export JIRA_PAT_COMMAND="${prog}"
  # cred_prime_cache MUST be called from the main shell (research R3) — a
  # cache filled inside a `$( … )` subshell dies with it, and the command
  # would then run once per request instead of once per run.
  cred_prime_cache
  local a b c
  a="$(cred_resolve_token)"
  b="$(cred_resolve_token)"
  c="$(cred_resolve_token)"
  [ "${a}" = "tok" ] && [ "${b}" = "tok" ] && [ "${c}" = "tok" ]
  [ "$(helper_pat_command_count "${counter}")" = "1" ]
}
