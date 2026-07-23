#!/usr/bin/env bats
# T022 — Sink REST-transport tests (retry/backoff honouring Retry-After on 429,
# exit-code mapping 2/3, credential-safe header) against the mocked double.
# The transport is the only module that talks HTTP to Jira; every fault path is
# proven here so the write path (US3+) can rely on fail-closed, monotonic codes.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/client.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

@test "GET returns 0 and the response body on success" {
  mock_start "${MOCK}/configs/default.json"
  run jira_request GET "${MOCK_BASE_URL}/rest/api/3/project/COMP"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .style)" = "classic" ]
}

@test "POST returns 0 and the created-issue body (201)" {
  mock_start "${MOCK}/configs/default.json"
  run jira_request POST "${MOCK_BASE_URL}/rest/api/3/issue" '{"fields":{}}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .key)" = "COMP-1" ]
}

@test "401 maps to the auth exit code (3), zero body" {
  mock_start "${MOCK}/configs/faults.json"
  run jira_request GET "${MOCK_BASE_URL}/rest/api/3/project/AUTH"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "404 maps to the fail-closed exit code (2), zero body" {
  mock_start "${MOCK}/configs/faults.json"
  run jira_request GET "${MOCK_BASE_URL}/rest/api/3/project/MISSING"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a dropped connection (network fault) maps to fail-closed (2)" {
  mock_start "${MOCK}/configs/faults.json"
  run jira_request GET "${MOCK_BASE_URL}/rest/api/3/project/NET"
  [ "$status" -eq 2 ]
}

@test "429 retries honouring Retry-After then exhausts to fail-closed (2)" {
  mock_start "${MOCK}/configs/faults.json"
  JIRA_MAX_ATTEMPTS=3 run jira_request GET "${MOCK_BASE_URL}/rest/api/3/project/RATE"
  [ "$status" -eq 2 ]
  # The transport reached the mock exactly JIRA_MAX_ATTEMPTS times before giving up.
  run mock_calls
  [ "$(printf '%s\n' "$output" | grep -c 'project/RATE')" -eq 3 ]
}

@test "the resolved token NEVER appears under set -x (NFR-3, SC-007)" {
  mock_start "${MOCK}/configs/default.json"
  trace="$(mktemp)"
  (
    exec 9> "${trace}"
    export BASH_XTRACEFD=9
    set -x
    jira_request GET "${MOCK_BASE_URL}/rest/api/3/project/COMP" > /dev/null
    set +x
  )
  run grep -c "RAWSECRETXYZ" "${trace}"
  [ "$output" = "0" ]
  rm -f "${trace}"
}
