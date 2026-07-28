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

# --- JQL-aware /search/jql (003 T024) ----------------------------------------

# jql_get <jql> [extra query] — issue a search against the mock, URL-encoding the
# JQL exactly as the sink's transport does.
jql_get() {
  curl -s --get --data-urlencode "jql=$1" --data "fields=labels,parent,project" \
    --data "maxResults=100" ${2:+--data "$2"} "${MOCK_BASE_URL}/rest/api/3/search/jql"
}

@test "search/jql filters by the JQL project term (003 T024)" {
  mock_start "${MOCK}/configs/adoption.json"
  run jql_get 'project = "BILL" AND labels IN ("speckit-adopt:005-audit-trail")'
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.issues[].key] | join(",")' <<< "$output")" = "BILL-4" ]
}

@test "search/jql filters by the labels IN term (003 T024)" {
  mock_start "${MOCK}/configs/adoption.json"
  run jql_get 'project = "ADO" AND labels IN ("speckit-adopt:004-billing-export")'
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.issues[].key] | join(",")' <<< "$output")" = "ADO-3" ]
}

@test "search/jql matches any one of several labels, in key order (003 T024)" {
  mock_start "${MOCK}/configs/adoption.json"
  run jql_get 'project = "ADO" AND labels IN ("speckit-adopt:003-label-based-adoption", "speckit-adopt:004-billing-export")'
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.issues[].key] | join(",")' <<< "$output")" = "ADO-1,ADO-3" ]
}

@test "search/jql label matching is case-sensitive (003 T024, research §3)" {
  mock_start "${MOCK}/configs/adoption.json"
  run jql_get 'project = "ADO" AND labels IN ("SPECKIT-ADOPT:003-label-based-adoption")'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.issues | length' <<< "$output")" -eq 0 ]
}

@test "search/jql serves key, labels, parent and project only (003 T024)" {
  mock_start "${MOCK}/configs/adoption.json"
  run jql_get 'project = "ADO" AND labels IN ("speckit-adopt:003-label-based-adoption:us1")'
  [ "$status" -eq 0 ]
  local issue
  issue="$(jq -c '.issues[0]' <<< "$output")"
  [ "$(jq -r '.key' <<< "$issue")" = "ADO-2" ]
  [ "$(jq -r '.fields.parent.key' <<< "$issue")" = "ADO-1" ]
  [ "$(jq -r '.fields.project.key' <<< "$issue")" = "ADO" ]
  [ "$(jq -r '.fields | keys | sort | join(",")' <<< "$issue")" = "labels,parent,project" ]
}

@test "search/jql omits parent when the issue has none (003 T024)" {
  mock_start "${MOCK}/configs/adoption.json"
  run jql_get 'project = "ADO" AND labels IN ("speckit-adopt:003-label-based-adoption")'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.issues[0].fields | has("parent")' <<< "$output")" = "false" ]
}

@test "search/jql pages with nextPageToken and omits it on the last page (003 T024, NFR-6)" {
  mock_start "${MOCK}/configs/adoption-paged.json"
  local jql='project = "ADO" AND labels IN ("speckit-adopt:003-label-based-adoption")'

  run jql_get "${jql}"
  [ "$(jq -r '[.issues[].key] | join(",")' <<< "$output")" = "ADO-1,ADO-2" ]
  [ "$(jq -r 'has("nextPageToken")' <<< "$output")" = "true" ]
  [ "$(jq -r '.isLast' <<< "$output")" = "false" ]
  local t1
  t1="$(jq -r '.nextPageToken' <<< "$output")"

  run jql_get "${jql}" "nextPageToken=${t1}"
  [ "$(jq -r '[.issues[].key] | join(",")' <<< "$output")" = "ADO-3,ADO-4" ]
  local t2
  t2="$(jq -r '.nextPageToken' <<< "$output")"

  run jql_get "${jql}" "nextPageToken=${t2}"
  [ "$(jq -r '[.issues[].key] | join(",")' <<< "$output")" = "ADO-5" ]
  [ "$(jq -r 'has("nextPageToken")' <<< "$output")" = "false" ]
  [ "$(jq -r '.isLast' <<< "$output")" = "true" ]
}

@test "a per-issue read serves the seeded corpus context (003 T024, US4 pins)" {
  mock_start "${MOCK}/configs/adoption.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/issue/ADO-2?fields=labels,parent,project"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fields.parent.key' <<< "$output")" = "ADO-1" ]
  [ "$(jq -r '.fields.project.key' <<< "$output")" = "ADO" ]
}

@test "a per-issue read of a key absent from the corpus is a 404 (003 T024)" {
  mock_start "${MOCK}/configs/adoption.json"
  run curl -s -o /dev/null -w '%{http_code}' "${MOCK_BASE_URL}/rest/api/3/issue/ADO-404?fields=labels,parent,project"
  [ "$output" = "404" ]
}

@test "records the API call sequence with query strings" {
  mock_start "${MOCK}/configs/default.json"
  curl -s "${MOCK_BASE_URL}/rest/api/3/project/COMP" > /dev/null
  curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-7?fields=status,priority" > /dev/null
  run mock_calls
  [[ "$output" == *"GET /rest/api/3/project/COMP"* ]]
  [[ "$output" == *"GET /rest/api/3/issue/COMP-7?fields=status,priority"* ]]
}
