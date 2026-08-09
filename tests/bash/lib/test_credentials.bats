#!/usr/bin/env bats
# T018 — Credential resolution (ELIMINATORY NFR-3 / SC-007).
# Order: env -> OS secret manager -> gitignored .env. The resolved token NEVER
# appears in argv, logs, errors, or under `set -x`.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/credentials.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/secret_store_stub.bash"
  TMPDIR_T="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${TMPDIR_T}"
  # A minimal PATH entry carrying only `bash`, for tests that must prove a
  # tool genuinely ABSENT (so PATH cannot include the directory holding the
  # real macOS /usr/bin/security) while still letting a `#!/usr/bin/env bash`
  # stub script resolve its own interpreter.
  SAFEBIN="${TMPDIR_T}/safebin"
  mkdir -p "${SAFEBIN}"
  ln -s "$(command -v bash)" "${SAFEBIN}/bash"
}

teardown() {
  rm -rf "${TMPDIR_T}"
}

@test "resolves the token from the environment first" {
  JIRA_API_TOKEN="env-token" run cred_resolve_token
  [ "$status" -eq 0 ]
  [ "$output" = "env-token" ]
}

@test "falls back to the gitignored .env when env and secret manager are empty" {
  printf 'JIRA_API_TOKEN=file-token\n' > "${TMPDIR_T}/.env"
  run cred_resolve_token
  [ "$status" -eq 0 ]
  [ "$output" = "file-token" ]
}

@test "environment token wins over the .env file" {
  printf 'JIRA_API_TOKEN=file-token\n' > "${TMPDIR_T}/.env"
  JIRA_API_TOKEN="env-token" run cred_resolve_token
  [ "$output" = "env-token" ]
}

@test "secret manager (mockable) sits between env and .env" {
  printf 'JIRA_API_TOKEN=file-token\n' > "${TMPDIR_T}/.env"
  _CRED_SECRET_TOKEN="keychain-token" run cred_resolve_token
  [ "$output" = "keychain-token" ]
}

@test "reads an 'export JIRA_API_TOKEN=...' line in .env (dotenv convention)" {
  printf 'export JIRA_API_TOKEN=file-token\n' > "${TMPDIR_T}/.env"
  run cred_resolve_token
  [ "$status" -eq 0 ]
  [ "$output" = "file-token" ]
}

@test "strips surrounding quotes from the .env value (dotenv convention)" {
  printf 'JIRA_API_TOKEN="file-token"\n' > "${TMPDIR_T}/.env"
  run cred_resolve_token
  [ "$output" = "file-token" ]
  printf "JIRA_API_TOKEN='file-token'\n" > "${TMPDIR_T}/.env"
  run cred_resolve_token
  [ "$output" = "file-token" ]
}

@test "strips the carriage return from a Windows-authored (CRLF) .env" {
  printf 'JIRA_API_TOKEN=file-token\r\n' > "${TMPDIR_T}/.env"
  run cred_resolve_token
  [ "$output" = "file-token" ]
}

@test "the PowerShell port reads export/quoted/CRLF .env lines identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  printf 'export JIRA_API_TOKEN="file-token"\r\n' > "${TMPDIR_T}/.env"
  run cred_resolve_token
  [ "$output" = "file-token" ]
  ps="$(pwsh -NoProfile -Command "
    \$env:JIRA_CONFIG_DIR = '${TMPDIR_T}'
    \$env:JIRA_API_TOKEN = ''
    Import-Module '${ROOT}/scripts/powershell/lib/Credentials.psm1' -Force
    [Console]::Out.Write((Resolve-JiraToken))
  ")"
  [ "$ps" = "file-token" ]
}

@test "returns non-zero when no source provides a token" {
  run cred_resolve_token
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

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

# --- T036/T037/T038 [US3] — the per-run credential cache -------------------
# contracts/credential-cache.md. cred_prime_cache/the _CRED_CACHE_* pair are
# process-lifetime state: every scenario below either runs in a fresh `bash
# -c` child (rotation needs two independent, unprimed processes) or relies on
# the fact that each bats @test is itself a fresh forked process, so no test
# here depends on cache state left behind by another.

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

@test "an unresolved cache is not re-consulted on a second resolve (T037)" {
  local bindir counter
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  helper_secret_store_install "${bindir}" "${counter}"
  PATH="${bindir}:${PATH}" cred_prime_cache
  PATH="${bindir}:${PATH}" run cred_resolve_token
  [ "${status}" -ne 0 ]
  [ "$(helper_secret_store_count "${counter}")" = "1" ]
}

@test "security and secret-tool both absent from PATH: silent fall-through to .env (T038)" {
  printf 'JIRA_API_TOKEN=file-token\n' > "${TMPDIR_T}/.env"
  local emptybin="${TMPDIR_T}/emptybin"
  mkdir -p "${emptybin}"
  PATH="${emptybin}" run cred_resolve_token
  [ "${status}" -eq 0 ]
  [ "${output}" = "file-token" ]
}

@test "security present but exits non-zero: silent fall-through to .env, and the attempt still counts (T038)" {
  printf 'JIRA_API_TOKEN=file-token\n' > "${TMPDIR_T}/.env"
  local bindir counter
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  helper_secret_store_install "${bindir}" "${counter}" "" 1
  PATH="${bindir}:${SAFEBIN}" run cred_resolve_token
  [ "${status}" -eq 0 ]
  [ "${output}" = "file-token" ]
  [ "$(helper_secret_store_count "${counter}")" = "1" ]
}

@test "secret-tool present but exits non-zero, security absent: silent fall-through to .env (T038)" {
  printf 'JIRA_API_TOKEN=file-token\n' > "${TMPDIR_T}/.env"
  local bindir counter
  bindir="${TMPDIR_T}/bin" counter="${TMPDIR_T}/count"
  helper_secret_store_install "${bindir}" "${counter}" "" 1
  rm -f "${bindir}/security"
  PATH="${bindir}:${SAFEBIN}" run cred_resolve_token
  [ "${status}" -eq 0 ]
  [ "${output}" = "file-token" ]
  [ "$(helper_secret_store_count "${counter}")" = "1" ]
}
