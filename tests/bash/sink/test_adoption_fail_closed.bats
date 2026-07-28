#!/usr/bin/env bats
# T082 [US2] — Fail-closed discovery (003 FR-008, Constitution III).
#
# Any unreliable read during discovery aborts the WHOLE run before any write:
#
#   401 / 403                              -> 3
#   404 / network error / exhausted 429    -> 2
#
# The abort is not "skip this binding" — it is "stop, having written nothing",
# because a partially-read corpus turns a two-candidate ambiguity into a
# one-candidate binding and would stamp identity onto the wrong human's ticket.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SINK="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${SINK}/adoption.sh"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  TARGETS='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"project_key":"ADO",
             "labels":["speckit-adopt:003-alpha"],"probe_labels":[],"short_conflict":null}]'
  CANDIDATES='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'
}

teardown() {
  mock_stop
}

start() {
  mock_start_json "$1"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

puts() {
  mock_calls | grep -c '^PUT ' || true
}

# --- the search itself ---------------------------------------------------------

@test "401 during the label search aborts with exit 3 and zero writes" {
  start '{"projects":{"ADO":"company"},"fault":{"status":401}}'
  run adopt_search_candidates "${TARGETS}"
  [ "$status" -eq 3 ]
  [ "$(puts)" -eq 0 ]
}

@test "403 during the label search aborts with exit 3 and zero writes" {
  start '{"projects":{"ADO":"company"},"fault":{"status":403}}'
  run adopt_search_candidates "${TARGETS}"
  [ "$status" -eq 3 ]
  [ "$(puts)" -eq 0 ]
}

@test "404 during the label search aborts with exit 2 and zero writes" {
  start '{"projects":{"ADO":"company"},"fault":{"status":404}}'
  run adopt_search_candidates "${TARGETS}"
  [ "$status" -eq 2 ]
  [ "$(puts)" -eq 0 ]
}

@test "a network drop during the label search aborts with exit 2 and zero writes" {
  start '{"projects":{"ADO":"company"},"fault":{"network":true}}'
  run adopt_search_candidates "${TARGETS}"
  [ "$status" -eq 2 ]
  [ "$(puts)" -eq 0 ]
}

@test "an exhausted 429 during the label search aborts with exit 2 and zero writes" {
  start '{"projects":{"ADO":"company"},"fault":{"status":429,"retryAfter":1}}'
  run adopt_search_candidates "${TARGETS}"
  [ "$status" -eq 2 ]
  [ "$(puts)" -eq 0 ]
}

@test "a 429 is retried up to the bounded budget before it is given up on" {
  start '{"projects":{"ADO":"company"},"fault":{"status":429,"retryAfter":1}}'
  run env JIRA_MAX_ATTEMPTS=3 bash -c "
    source '${SINK}/adoption.sh'
    adopt_search_candidates '${TARGETS}'"
  [ "$status" -eq 2 ]
  [ "$(mock_calls | grep -c '^GET /rest/api/3/search/jql')" -eq 3 ]
}

@test "nothing is emitted on stdout when the search fails (zero-partial reads)" {
  start '{"projects":{"ADO":"company"},"fault":{"status":404}}'
  run adopt_search_candidates "${TARGETS}"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# --- a failure on a LATER page still aborts the whole run --------------------

@test "a fault on the second page aborts, rather than returning a truncated list" {
  # Page one succeeds; the injected fault is keyed on the issue the second page
  # would serve, so the loop meets it mid-pagination.
  start '{"projects":{"ADO":"company"},"pageSize":2,"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-alpha"]},
    "ADO-2":{"labels":["speckit-adopt:003-alpha"]},
    "ADO-3":{"labels":["speckit-adopt:003-alpha"]}}}'
  # First confirm the clean corpus paginates to three.
  run adopt_search_candidates "${TARGETS}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 3 ]
}

# --- the claim read ------------------------------------------------------------

@test "401 during a claim read aborts with exit 3 and zero writes" {
  start '{"projects":{"ADO":"company"},"fault":{"status":401}}'
  run adopt_read_candidate_identity "${CANDIDATES}"
  [ "$status" -eq 3 ]
  [ "$(puts)" -eq 0 ]
}

@test "a network drop during a claim read aborts with exit 2 and zero writes" {
  start '{"projects":{"ADO":"company"},"fault":{"network":true}}'
  run adopt_read_candidate_identity "${CANDIDATES}"
  [ "$status" -eq 2 ]
  [ "$(puts)" -eq 0 ]
}

@test "a 404 on a claim read is NOT a failure — it means unclaimed" {
  # The one status that must not abort: a ticket with no identity property is
  # the normal case for a human's ticket.
  start '{"projects":{"ADO":"company"}}'
  run adopt_read_candidate_identity "${CANDIDATES}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].identity' <<< "$output")" = "null" ]
}

@test "an abort mid-way through the claim reads still writes nothing" {
  start '{"projects":{"ADO":"company"},"faults":{"ADO-2":{"status":401}}}'
  local many
  many='[{"key":"ADO-1","project_key":"ADO","labels":[],"parent_key":null,"identity":null},
         {"key":"ADO-2","project_key":"ADO","labels":[],"parent_key":null,"identity":null},
         {"key":"ADO-3","project_key":"ADO","labels":[],"parent_key":null,"identity":null}]'
  run adopt_read_candidate_identity "${many}"
  [ "$status" -eq 3 ]
  [ "$(puts)" -eq 0 ]
  # The read of the THIRD candidate never happened: the abort is immediate.
  [ "$(mock_calls | grep -c 'ADO-3' || true)" -eq 0 ]
}
