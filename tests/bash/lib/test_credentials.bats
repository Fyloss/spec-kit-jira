#!/usr/bin/env bats
# T018 — Credential resolution (ELIMINATORY NFR-3 / SC-007).
# Order: env -> OS secret manager -> gitignored .env. The resolved token NEVER
# appears in argv, logs, errors, or under `set -x`.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/credentials.sh"
  TMPDIR_T="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${TMPDIR_T}"
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
