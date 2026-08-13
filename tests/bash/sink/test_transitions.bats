#!/usr/bin/env bats
# T032-T039 [Phase 4, US1] — transitions.sh: one GET per due ticket (branch C,
# research R1), resolved by destination NAME alone (contracts/
# transition-resolution.md §3), never by category — the story/specification
# tier's own rule, distinct from discovery_task_transition's category rule
# for the task tier.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/transitions.sh"

  export JIRA_CONFIG_DIR="${BATS_TEST_TMPDIR}/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1

  mock_start "${MOCK}/configs/story-transitions.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  transitions_reset
}

teardown() {
  mock_stop
}

@test "one ungated candidate onto the declared step resolves to move" {
  transitions_load STORY-1
  run transitions_resolve "$(transitions_get STORY-1)" "In Progress"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' <<< "$output")" = "move" ]
  [ "$(jq -r '.transition_id' <<< "$output")" = "11" ]
}

@test "two candidates landing on the declared step resolve to ambiguous, both named" {
  transitions_load STORY-2
  run transitions_resolve "$(transitions_get STORY-2)" "In Progress"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' <<< "$output")" = "ambiguous" ]
  [ "$(jq -r '.candidates | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.candidates | map(.id) | sort | join(",")' <<< "$output")" = "21,22" ]
}

@test "the sole candidate gated by a required field resolves to gated, field named" {
  transitions_load STORY-3
  run transitions_resolve "$(transitions_get STORY-3)" "In Progress"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' <<< "$output")" = "gated" ]
  [ "$(jq -r '.gated_field.logical_name' <<< "$output")" = "Resolution" ]
  [ "$(jq -r '.gated_field.field_id' <<< "$output")" = "resolution" ]
}

@test "no candidate onto the declared step resolves to unreachable, reachable set named" {
  transitions_load STORY-4
  run transitions_resolve "$(transitions_get STORY-4)" "In Progress"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' <<< "$output")" = "unreachable" ]
  [ "$(jq -r '.reachable | join(",")' <<< "$output")" = "Done" ]
}

@test "the step comparison is exact string equality — case or spacing never accepted" {
  transitions_load STORY-1
  run transitions_resolve "$(transitions_get STORY-1)" "in progress"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' <<< "$output")" = "unreachable" ]
}

@test "transitions_get matches the requested key case-insensitively" {
  transitions_load STORY-1
  run transitions_get "story-1"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "STORY-1" ]
}

@test "transitions_get on a miss returns 1 and prints nothing" {
  transitions_load STORY-1
  run transitions_get STORY-99
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "transitions_load issues exactly one GET per key, none for a bulk endpoint" {
  : > "${MOCK_CALLLOG}"
  transitions_load STORY-1 STORY-2
  [ "$(grep -c '^GET /rest/api/3/issue/STORY-1/transitions' "${MOCK_CALLLOG}")" -eq 1 ]
  [ "$(grep -c '^GET /rest/api/3/issue/STORY-2/transitions' "${MOCK_CALLLOG}")" -eq 1 ]
  [ "$(grep -c 'bulkfetch' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "a read failure on any key fails closed, without reading remaining keys" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{
  "projects": {"STORY": "company"},
  "transitions": {
    "STORY-1": [{"id": "11", "name": "Start", "to": {"name": "In Progress"}, "fields": {}}]
  },
  "faults": {"issue/STORY-1/transitions": {"status": 500}}
}
EOF
  mock_stop
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  : > "${MOCK_CALLLOG}"
  run transitions_load STORY-1 STORY-2
  [ "$status" -ne 0 ]
  [ "$(grep -c '^GET /rest/api/3/issue/STORY-2/transitions' "${MOCK_CALLLOG}")" -eq 0 ]
}
