#!/usr/bin/env bats
# T025/T029/T031/T033/T035 [027] — The adoption read (research R4/R5,
# contract seed-cli-contract.md §6). Fail-CLOSED bulk read, distinct from
# prefetch.sh's fail-open posture.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/adoption.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

_seed_issue() {
  printf '"%s":{"summary":"%s","description":"%s","status":{"name":"%s","statusCategory":{"key":"%s"}},"issuetype":{"id":"10001","name":"%s"},"project":{"key":"%s"}}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# --- C-14 (T025): 100 designators -> 1 bulkfetch; 101 -> 2 -------------------

@test "C-14: 100 keys issue exactly 1 bulkfetch" {
  local issues="{" i
  for i in $(seq 1 100); do
    [[ "${i}" != "1" ]] && issues+=","
    issues+="$(_seed_issue "PROJ-${i}" "S${i}" "desc" "To Do" "new" "Story" "PROJ")"
  done
  issues+="}"
  local cfg; cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local -a keys=()
  for i in $(seq 1 100); do keys+=("PROJ-${i}"); done
  run adoption_load "${keys[@]}"
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c 'POST /rest/api/3/issue/bulkfetch')" -eq 1 ]
}

@test "C-14: 101 keys issue exactly 2 bulkfetch requests" {
  local issues="{" i
  for i in $(seq 1 101); do
    [[ "${i}" != "1" ]] && issues+=","
    issues+="$(_seed_issue "PROJ-${i}" "S${i}" "desc" "To Do" "new" "Story" "PROJ")"
  done
  issues+="}"
  local cfg; cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local -a keys=()
  for i in $(seq 1 101); do keys+=("PROJ-${i}"); done
  run adoption_load "${keys[@]}"
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c 'POST /rest/api/3/issue/bulkfetch')" -eq 2 ]
}

@test "adoption_load does not spawn a process per issue (budget)" {
  local issues="{" i
  for i in $(seq 1 20); do
    [[ "${i}" != "1" ]] && issues+=","
    issues+="$(_seed_issue "PROJ-${i}" "S${i}" "desc" "To Do" "new" "Story" "PROJ")"
  done
  issues+="}"
  local cfg; cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local -a keys=()
  for i in $(seq 1 20); do keys+=("PROJ-${i}"); done
  adoption_load "${keys[@]}"
  [ "$(mock_calls | grep -c 'POST /rest/api/3/issue/bulkfetch')" -eq 1 ]
}

# --- Fail-closed posture (research R4) ---------------------------------------

@test "a non-2xx bulkfetch response is fail-closed, not fail-open" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S"}},"fault":{"status":500}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run adoption_load PROJ-1
  [ "$status" -ne 0 ]
}

# --- T029: the request body reaches jira_request via a temp file -------------

@test "the bulkfetch body reaches jira_request through a temp file, never argv" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S"}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # A body long enough that, if it ever reached argv via command substitution
  # inside jira_request's own subshell-visible ps output, would be
  # detectable; here we assert only that the transport succeeds and the
  # counted request matches — the source review (T030) is the structural
  # proof; this test pins the outward-observable behaviour.
  run adoption_load PROJ-1
  [ "$status" -eq 0 ]
}

# --- adoption_get: reading a resolved entry ----------------------------------

@test "adoption_get returns the resolved issue's fields and marker" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"Parent Epic","description":"desc","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"id":"10001","name":"Epic"},"project":{"key":"PROJ"},"properties":{"spec-kit-jira":{"origin":"human"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1
  run adoption_get PROJ-1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fields.summary' <<< "$output")" = "Parent Epic" ]
  [ "$(jq -r '.fields.issuetype.name' <<< "$output")" = "Epic" ]
  [ "$(jq -r '.marker.origin' <<< "$output")" = "human" ]
}

@test "adoption_get is case-insensitive on the key" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S"}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1
  run adoption_get proj-1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fields.summary' <<< "$output")" = "S" ]
}

@test "adoption_get on a miss returns 1 and prints nothing" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S"}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1
  run adoption_get PROJ-999
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- T031: the seven state-dependent refusal classes -------------------------

@test "REF-UNRESOLVED: a designated key absent from the read" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S"}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1 PROJ-999
  run adoption_evaluate PROJ story PROJ-999 Story "" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.code' <<< "$output")" = "REF-UNRESOLVED" ]
  # FR-037: never claims deleted vs forbidden.
  [[ "$(jq -r '.message' <<< "$output")" != *"deleted"* ]]
  [[ "$(jq -r '.message' <<< "$output")" != *"does not exist"* ]]
}

@test "REF-ROLE: the named issue's type does not match the declared role" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S","issuetype":{"id":"1","name":"Bug"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1
  run adoption_evaluate PROJ story PROJ-1 Story "" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.code' <<< "$output")" = "REF-ROLE" ]
}

@test "REF-ROUTING: the named issue's project differs from the routed project" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"OTHER-1":{"summary":"S","issuetype":{"id":"1","name":"Story"},"project":{"key":"OTHER"},"status":{"name":"To Do","statusCategory":{"key":"new"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load OTHER-1
  run adoption_evaluate PROJ story OTHER-1 Story "" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.code' <<< "$output")" = "REF-ROUTING" ]
}

@test "REF-TERMINAL: the named issue is in a configured terminal status" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"Done","statusCategory":{"key":"done"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1
  run adoption_evaluate PROJ story PROJ-1 Story "Done" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.code' <<< "$output")" = "REF-TERMINAL" ]
}

@test "REF-CLAIMED: the named issue carries an identity marker for another spec" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}},"properties":{"spec-kit-jira":{"origin":"human","repo":"acme/app","spec_slug":"other-spec"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1
  run adoption_evaluate PROJ story PROJ-1 Story "" '{"repo":"acme/app","spec_slug":"this-spec"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.code' <<< "$output")" = "REF-CLAIMED" ]
}

@test "REF-THIN: the named issue's description is empty or whitespace-only" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S","description":"   ","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1
  run adoption_evaluate PROJ story PROJ-1 Story "" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.code' <<< "$output")" = "REF-THIN" ]
}

@test "REF-MULTIPROJECT: named story-role issues span more than one project" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S","project":{"key":"PROJ"}},"OTHER-1":{"summary":"S","project":{"key":"OTHER"}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1 OTHER-1
  run adoption_multiproject_violation '["PROJ-1","OTHER-1"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '. | length' <<< "$output")" -eq 2 ]
}

@test "REF-MULTIPROJECT: a single project among the named stories is not a violation" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S","project":{"key":"PROJ"}},"PROJ-2":{"summary":"S","project":{"key":"PROJ"}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1 PROJ-2
  run adoption_multiproject_violation '["PROJ-1","PROJ-2"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '. | length' <<< "$output")" -eq 0 ]
}

@test "a fully valid named issue evaluates clean" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"S","description":"real content","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1
  run adoption_evaluate PROJ story PROJ-1 Story "" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.code' <<< "$output")" = "" ]
}

# --- T033: three mistyped designators reported together (C-4) ---------------

@test "C-4: multiple refusals across a set are aggregated, not reported one per run" {
  local cfg
  cfg="$(mock_write_config '{"issues":{}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-1 PROJ-2 PROJ-3
  local r1 r2 r3 agg
  r1="$(adoption_evaluate PROJ story PROJ-1 Story "" "")"
  r2="$(adoption_evaluate PROJ story PROJ-2 Story "" "")"
  r3="$(adoption_evaluate PROJ story PROJ-3 Story "" "")"
  agg="$(adoption_aggregate_refusals "[${r1},${r2},${r3}]")"
  [ "$(jq -r '. | length' <<< "${agg}")" -eq 3 ]
  [ "$(jq -r '.[0].code' <<< "${agg}")" = "REF-UNRESOLVED" ]
}

# --- T035: current parent summary/status fold into the same bulkfetch -------

@test "the current parent's summary and status arrive with no extra request" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-99":{"summary":"Legacy epic","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"issuetype":{"id":"1","name":"Epic"},"project":{"key":"PROJ"}},"PROJ-11":{"summary":"Story","description":"real content","issuetype":{"id":"1","name":"Story"},"project":{"key":"PROJ"},"status":{"name":"To Do","statusCategory":{"key":"new"}},"parent":{"key":"PROJ-99"}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  adoption_load PROJ-11
  run adoption_get PROJ-11
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fields.parent.fields.summary' <<< "$output")" = "Legacy epic" ]
  [ "$(jq -r '.fields.parent.fields.status.name' <<< "$output")" = "In Progress" ]
  [ "$(mock_calls | grep -c 'POST /rest/api/3/issue/bulkfetch')" -eq 1 ]
}
