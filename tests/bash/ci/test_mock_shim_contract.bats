#!/usr/bin/env bats
# T004 [009] — Contract test for the curl shim backend
# (tests/conformance/mock-jira/curl-shim.sh), per contracts/curl-shim.md and
# contracts/mock-driver.md. Written and observed to FAIL before T005/T005b/T006
# existed (Constitution XIII TDD); now the shim's regression guard.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
}

teardown() {
  mock_stop
}

# --- Invariant 1: style routing -----------------------------------------------

@test "GET project/COMP serves the company-managed fixture" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/project/COMP"
  [ "$status" -eq 0 ]
  [ "$(jq -r .style <<< "$output")" = "classic" ]
}

@test "GET project/TEAM serves the team-managed fixture" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/project/TEAM"
  [ "$status" -eq 0 ]
  [ "$(jq -r .style <<< "$output")" = "next-gen" ]
}

# --- Invariant 2: faults -------------------------------------------------------

@test "AUTH project injects a 401" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s -o /dev/null -w '%{http_code}' "${MOCK_BASE_URL}/rest/api/3/project/AUTH"
  [ "$output" = "401" ]
}

@test "MISSING project injects a 404" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s -o /dev/null -w '%{http_code}' "${MOCK_BASE_URL}/rest/api/3/project/MISSING"
  [ "$output" = "404" ]
}

@test "RATE project injects a 429 with Retry-After" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s -o /dev/null -w '%{http_code}' "${MOCK_BASE_URL}/rest/api/3/project/RATE"
  [ "$output" = "429" ]
  run curl -s -D - -o /dev/null "${MOCK_BASE_URL}/rest/api/3/project/RATE"
  [[ "$output" == *"Retry-After: 1"* ]]
}

@test "NET project drops the connection (network failure)" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/project/NET"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- Invariant 3: writes --------------------------------------------------------

@test "POST /issue returns 201 with a created-issue body" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s -o /dev/null -w '%{http_code}' -X POST "${MOCK_BASE_URL}/rest/api/3/issue" \
    -d '{"fields":{"project":{"key":"COMP"},"summary":"x"}}'
  [ "$output" = "201" ]
  run curl -s -X POST "${MOCK_BASE_URL}/rest/api/3/issue" -d '{"fields":{"project":{"key":"COMP"},"summary":"y"}}'
  [ "$(jq -r '.key' <<< "$output")" != "null" ]
  [[ "$(jq -r '.key' <<< "$output")" == COMP-* ]]
}

# --- Invariant 4: call log order and exact-once -------------------------------

@test "every request appears once, in order, in mock_calls" {
  mock_start "${MOCK}/configs/default.json"
  curl -s "${MOCK_BASE_URL}/rest/api/3/project/COMP" > /dev/null
  curl -s "${MOCK_BASE_URL}/rest/api/3/priority" > /dev/null
  curl -s "${MOCK_BASE_URL}/rest/api/3/field" > /dev/null
  run mock_calls
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "GET /rest/api/3/project/COMP" ]
  [ "${lines[1]}" = "GET /rest/api/3/priority" ]
  [ "${lines[2]}" = "GET /rest/api/3/field" ]
}

# --- Invariant 5 / NFR-3: the Authorization header is never logged -----------

@test "the Authorization header never appears in MOCK_CALLLOG" {
  mock_start "${MOCK}/configs/default.json"
  printf 'header = "Authorization: Basic dXNlcjpTRUNSRVQ="\nurl = "%s/rest/api/3/project/COMP"\nrequest = "GET"\n' "${MOCK_BASE_URL}" \
    | curl --silent --config - --output /dev/null --dump-header /dev/null --write-out '%{http_code}' > /dev/null
  run grep -c 'SECRET\|Authorization' "${MOCK_CALLLOG}"
  [ "$status" -ne 0 ]
  [ "$output" -eq 0 ] 2> /dev/null || [ -z "$output" ] || [ "$output" = "0" ]
}

# --- Invariants 6-7 (008 surface): the issue store -----------------------------

@test "mock_issue_field resolves a field of an issue an earlier POST created" {
  mock_start "${MOCK}/configs/default.json"
  curl -s -X POST "${MOCK_BASE_URL}/rest/api/3/issue" \
    -d '{"fields":{"project":{"key":"COMP"},"summary":"child","parent":{"key":"COMP-9"}}}' > /dev/null
  local key
  key="$(mock_calls | tail -n1 > /dev/null; curl -s -X POST "${MOCK_BASE_URL}/rest/api/3/issue" -d '{"fields":{"project":{"key":"COMP"},"parent":{"key":"COMP-9"}}}' | jq -r .key)"
  [ "$(mock_issue_field "${key}" .fields.parent.key)" = "COMP-9" ]
}

@test "two concurrent mock_start instances never see each other's issues" {
  mock_start "${MOCK}/configs/default.json"
  curl -s -X POST "${MOCK_BASE_URL}/rest/api/3/issue" -d '{"fields":{"project":{"key":"COMP"},"summary":"a-only-in-first"}}' > /dev/null
  local first_tmp="${MOCK_TMPDIR}"

  # A second, independent instance in the SAME process (nested, without
  # stopping the first) must not share state or PATH-install collisions:
  # its store is freshly seeded, so COMP-1 is unknown to IT even though the
  # first instance just created it.
  mock_start "${MOCK}/configs/default.json"
  [ "${MOCK_TMPDIR}" != "${first_tmp}" ]
  [ "$(mock_issue_field COMP-1 .fields.summary)" != "a-only-in-first" ]
  mock_stop

  # The state file that no longer has an active mock_start session still
  # holds the first instance's data on disk (isolation, not clobbering).
  [ "$(jq -r '.issues["COMP-1"].fields.summary' "${first_tmp}/state.json")" = "a-only-in-first" ]
}
