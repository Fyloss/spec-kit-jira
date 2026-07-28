#!/usr/bin/env bats
# T123 [US4] — Issue-key shape validation and pinned context reads
# (003 research §9, FR-020).
#
# The key regex lives in the SINK and nowhere else: that is what keeps every
# key-shaped literal on the Jira side of the engine/sink boundary, and it is why
# the CLI parser checks only that a `--bind` value is non-empty on both sides of
# its `=`. A malformed key is an operator typo, so it is a usage error raised
# before any request rather than a search that finds nothing.
#
# A pinned key is then read for its context exactly as a discovered candidate is,
# so the two go through the identical validation path.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SINK="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${SINK}/adoption.sh"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  CORPUS='{"projects":{"ADO":"company"},"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-alpha"]},
    "ADO-77":{"labels":[],"parent":"ADO-1"}}}'
}

teardown() {
  mock_stop
}

start() {
  mock_start_json "${CORPUS}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

# --- the shape itself --------------------------------------------------------

@test "a well-formed key is accepted" {
  for k in ADO-1 ADO-4242 A1-7 LONGPROJECT-99 WITH_UNDERSCORE-3; do
    run adopt_valid_issue_key "${k}"
    [ "$status" -eq 0 ]
  done
}

@test "a malformed key is rejected" {
  for k in "not-a-key" "ado-1" "ADO" "ADO-" "-1" "ADO-1x" "ADO 1" "1ADO-1" ""; do
    run adopt_valid_issue_key "${k}"
    [ "$status" -ne 0 ]
  done
}

@test "the key regex lives ONLY in the sink, never in the neutral layers" {
  # Constitution VIII: the engine may not carry a key-shaped literal at all, and
  # the CLI parser deliberately does not either (research §9).
  run bash -c "grep -cE '\\[A-Z\\]\\[A-Z0-9_\\]\\*-\\[0-9\\]' '${ROOT}/scripts/bash/engine/adoption.sh' '${ROOT}/scripts/bash/lib/cli.sh' | grep -v ':0$' | wc -l | tr -d ' '"
  [ "$output" = "0" ]
  run grep -c 'A-Z0-9_' "${SINK}/adoption.sh"
  [ "$output" -ge 1 ]
}

# --- reading a pinned key's context -----------------------------------------

@test "a pinned key is read for its labels, parent and project" {
  start
  run adopt_fetch_pinned '["ADO-77"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].key' <<< "$output")" = "ADO-77" ]
  [ "$(jq -r '.[0].project_key' <<< "$output")" = "ADO" ]
  [ "$(jq -r '.[0].parent_key' <<< "$output")" = "ADO-1" ]
  [ "$(jq -r '.[0].identity' <<< "$output")" = "null" ]
  [[ "$(mock_calls)" == *"GET /rest/api/3/issue/ADO-77?fields=labels,parent,project"* ]]
}

@test "several pinned keys are read and returned in key order" {
  start
  run adopt_fetch_pinned '["ADO-77","ADO-1"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].key] | join(",")' <<< "$output")" = "ADO-1,ADO-77" ]
}

@test "an empty pin list performs no read at all" {
  start
  run adopt_fetch_pinned '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ -z "$(mock_calls)" ]
}

@test "a malformed pinned key is a usage error raised BEFORE any request" {
  start
  run adopt_fetch_pinned '["not-a-key"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed issue key"* ]]
  [ -z "$(mock_calls)" ]
}

@test "one malformed key among valid ones stops the run with zero writes" {
  start
  run adopt_fetch_pinned '["ADO-1","nope"]'
  [ "$status" -eq 1 ]
  [ "$(mock_calls | grep -c '^PUT ' || true)" -eq 0 ]
}

@test "a pinned key absent from the tracker fails closed, never binds silently" {
  start
  run adopt_fetch_pinned '["ADO-404"]'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "an unreadable pinned key propagates its mapped code and writes nothing" {
  mock_start_json '{"projects":{"ADO":"company"},"fault":{"status":401},"issues":{"ADO-1":{"labels":[]}}}'
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run adopt_fetch_pinned '["ADO-1"]'
  [ "$status" -eq 3 ]
  [ "$(mock_calls | grep -c '^PUT ' || true)" -eq 0 ]
}

@test "identity is read for a pinned key exactly as for a discovered candidate" {
  mock_start_json '{"projects":{"ADO":"company"},
                    "identity":{"ADO-77":{"origin":"human","repo":"acme/app","spec_slug":"009-elsewhere"}},
                    "issues":{"ADO-77":{"labels":[]}}}'
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local pinned
  pinned="$(adopt_fetch_pinned '["ADO-77"]')"
  run adopt_read_candidate_identity "${pinned}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].identity.spec_slug' <<< "$output")" = "009-elsewhere" ]
}
