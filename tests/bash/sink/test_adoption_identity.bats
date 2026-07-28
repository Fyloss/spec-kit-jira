#!/usr/bin/env bats
# T037 [US1] — Adoption claim reads (003 data-model §4, FR-020).
#
# One identity read per candidate. A 404 means "unclaimed" and is NOT a failure —
# it is the normal case for a human's ticket that the bridge has never touched.
# Any other transport failure propagates its mapped code and aborts the whole run
# before any write (FR-008).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${SINK}/adoption.sh"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  CANDIDATES='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-a"],"parent_key":null,"identity":null},
               {"key":"ADO-3","project_key":"ADO","labels":["speckit-adopt:004-b"],"parent_key":null,"identity":null}]'
}

teardown() {
  mock_stop
}

start_json() {
  mock_start_json "$1"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "one identity read per candidate" {
  start_json '{"projects":{"ADO":"company"}}'
  run adopt_read_candidate_identity "${CANDIDATES}"
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c 'GET /rest/api/3/issue/.*/properties/spec-kit-jira')" -eq 2 ]
  [[ "$(mock_calls)" == *"GET /rest/api/3/issue/ADO-1/properties/spec-kit-jira"* ]]
  [[ "$(mock_calls)" == *"GET /rest/api/3/issue/ADO-3/properties/spec-kit-jira"* ]]
}

@test "a 404 means unclaimed, not a failure" {
  start_json '{"projects":{"ADO":"company"}}'
  run adopt_read_candidate_identity "${CANDIDATES}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[] | select(.identity == null)] | length' <<< "$output")" -eq 2 ]
}

@test "a stored marker is surfaced onto the candidate (origin, repo, spec_slug)" {
  start_json '{"projects":{"ADO":"company"},
               "identity":{"ADO-3":{"origin":"human","repo":"acme/app","spec_slug":"004-billing-export"}}}'
  run adopt_read_candidate_identity "${CANDIDATES}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.key=="ADO-1") | .identity' <<< "$output")" = "null" ]
  local m
  m="$(jq -c '.[] | select(.key=="ADO-3") | .identity' <<< "$output")"
  [ "$(jq -r '.origin' <<< "$m")" = "human" ]
  [ "$(jq -r '.repo' <<< "$m")" = "acme/app" ]
  [ "$(jq -r '.spec_slug' <<< "$m")" = "004-billing-export" ]
}

@test "the candidate's discovered context survives the claim read" {
  start_json '{"projects":{"ADO":"company"}}'
  run adopt_read_candidate_identity \
    '[{"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-a:us1"],"parent_key":"ADO-1","identity":null}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].parent_key' <<< "$output")" = "ADO-1" ]
  [ "$(jq -r '.[0].labels[0]' <<< "$output")" = "speckit-adopt:003-a:us1" ]
}

@test "an empty candidate list performs no read at all" {
  start_json '{"projects":{"ADO":"company"}}'
  run adopt_read_candidate_identity '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ -z "$(mock_calls)" ]
}

@test "an authentication failure propagates exit 3 and aborts before any write" {
  start_json '{"projects":{"ADO":"company"},"faults":{"ADO":{"status":401}}}'
  run adopt_read_candidate_identity "${CANDIDATES}"
  [ "$status" -eq 3 ]
  [ "$(mock_calls | grep -c 'PUT ')" -eq 0 ]
}

@test "a network failure propagates exit 2 and aborts before any write" {
  start_json '{"projects":{"ADO":"company"},"faults":{"ADO":{"network":true}}}'
  run adopt_read_candidate_identity "${CANDIDATES}"
  [ "$status" -eq 2 ]
  [ "$(mock_calls | grep -c 'PUT ')" -eq 0 ]
}
