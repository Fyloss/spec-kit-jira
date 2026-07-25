#!/usr/bin/env bats
# T008 — Smoke tests for the mocked Jira double (Bash driver).
# Proves discovery serving, fault injection, and call-sequence recording so the
# transport suites (T022) and the conformance harness (T009) can rely on it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
}

teardown() {
  mock_stop
}

@test "serves company-managed project discovery" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/project/COMP"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .style)" = "classic" ]
}

@test "serves team-managed project discovery down the next-gen path" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/project/TEAM"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .style)" = "next-gen" ]
}

@test "serves per-style issue-type createmeta" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/issue/createmeta/TEAM/issuetypes"
  [ "$status" -eq 0 ]
  # Team-managed hierarchy is limited to Epic / Story / Sub-task.
  [ "$(printf '%s' "$output" | jq -r '[.issueTypes[].name] | sort | join(",")')" = "Epic,Story,Sub-task" ]
}

@test "injects a 401 for the AUTH project" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s -o /dev/null -w '%{http_code}' "${MOCK_BASE_URL}/rest/api/3/project/AUTH"
  [ "$output" = "401" ]
}

@test "injects a 404 for the MISSING project" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s -o /dev/null -w '%{http_code}' "${MOCK_BASE_URL}/rest/api/3/project/MISSING"
  [ "$output" = "404" ]
}

@test "injects a 429 with Retry-After (exhausts retries)" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s -D - -o /dev/null "${MOCK_BASE_URL}/rest/api/3/project/RATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"429"* ]]
  printf '%s' "$output" | grep -qi 'Retry-After: 1'
}

@test "injects a network fault by dropping the connection" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/project/NET"
  [ "$status" -ne 0 ]
}

@test "records the API call sequence with query strings" {
  mock_start "${MOCK}/configs/default.json"
  curl -s "${MOCK_BASE_URL}/rest/api/3/project/COMP" > /dev/null
  curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-7?fields=status,priority" > /dev/null
  run mock_calls
  [[ "$output" == *"GET /rest/api/3/project/COMP"* ]]
  [[ "$output" == *"GET /rest/api/3/issue/COMP-7?fields=status,priority"* ]]
}
