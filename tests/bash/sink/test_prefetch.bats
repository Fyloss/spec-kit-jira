#!/usr/bin/env bats
# T047 — sink/jira/prefetch.sh: recognition prefetch, contracts/recognition-prefetch.md.
# The prefetch may only ever remove requests — it may never change an outcome
# (§ governing rule). These tests exercise the module in isolation, against
# the mock's `POST /rest/api/3/issue/bulkfetch` handler (T046); T049-T052
# prove the invariant end to end against reconcile.sh.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/prefetch.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
  prefetch_reset
}

_seed() {
  # A mock config seeding the given issues map verbatim under `.issues`.
  cat > "${BATS_TEST_TMPDIR}/cfg.json" << EOF
{"issues": ${1}}
EOF
  printf '%s' "${BATS_TEST_TMPDIR}/cfg.json"
}

@test "prefetch_load populates the map; prefetch_get returns canonical JSON for a hit" {
  local cfg; cfg="$(_seed '{"COMP-1": {"summary": "S1", "properties": {"spec-kit-jira": {"story":"aaaa"}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  prefetch_load "COMP-1"
  run prefetch_get "COMP-1" "summary"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.gone' <<< "$output")" = "false" ]
  [ "$(jq -r '.marker.story' <<< "$output")" = "aaaa" ]
  [ "$(jq -r '.fields.summary' <<< "$output")" = "S1" ]
}

@test "prefetch_get on a miss returns 1 and prints nothing" {
  local cfg; cfg="$(_seed '{}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  prefetch_load "COMP-1"
  run prefetch_get "COMP-1" "summary"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "field projection yields exactly the caller's field set — no more, no less" {
  local cfg; cfg="$(_seed '{"COMP-1": {"summary": "S1", "priority": {"name":"High"}, "properties": {}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  prefetch_load "COMP-1"
  run prefetch_get "COMP-1" "summary,priority"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fields | keys | sort | join(",")' <<< "$output")" = "priority,summary" ]
}

@test "case-insensitive key matching: prefetch_get is reached from a differently-cased request" {
  local cfg; cfg="$(_seed '{"COMP-1": {"summary": "S1", "properties": {}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  prefetch_load "comp-1"
  run prefetch_get "COMP-1" "summary"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fields.summary' <<< "$output")" = "S1" ]
}

@test "a returned key is matched by value, never by position" {
  # State insertion order is COMP-1 then COMP-2, so the mock's bulkfetch
  # response returns COMP-1 first — the OPPOSITE of this request's order.
  # A positional matcher would hand COMP-2's data back for the key "COMP-1".
  local cfg; cfg="$(_seed '{"COMP-1": {"summary": "first", "properties": {}}, "COMP-2": {"summary": "second", "properties": {}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  prefetch_load "COMP-2" "COMP-1"
  run prefetch_get "COMP-1" "summary"
  [ "$(jq -r '.fields.summary' <<< "$output")" = "first" ]
  run prefetch_get "COMP-2" "summary"
  [ "$(jq -r '.fields.summary' <<< "$output")" = "second" ]
}

@test "chunking at 100: 101 keys issue exactly 2 bulkfetch requests" {
  local issues; issues="$(jq -cn '[range(1;102)] | map({("COMP-" + (.|tostring)): {summary:"S", properties:{}}}) | add')"
  local cfg; cfg="$(_seed "${issues}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local -a keys=()
  for i in $(seq 1 101); do keys+=("COMP-${i}"); done
  prefetch_load "${keys[@]}"
  run mock_calls
  [ "$(printf '%s\n' "$output" | grep -c 'issue/bulkfetch')" -eq 2 ]
  # Both chunks landed: a key from each half is a hit.
  run prefetch_get "COMP-1" "summary"
  [ "$status" -eq 0 ]
  run prefetch_get "COMP-101" "summary"
  [ "$status" -eq 0 ]
}

@test "a non-2xx bulkfetch response empties the map and prefetch_load still returns 0" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"issues": {"COMP-1": {"summary": "S1", "properties": {}}}, "faults": {"issue/bulkfetch": {"status": 400}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run prefetch_load "COMP-1"
  [ "$status" -eq 0 ]
  run prefetch_get "COMP-1" "summary"
  [ "$status" -eq 1 ]
}

@test "zero recorded keys: prefetch_load issues zero requests and returns 0" {
  local cfg; cfg="$(_seed '{}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run prefetch_load
  [ "$status" -eq 0 ]
  run mock_calls
  [ "$(printf '%s\n' "$output" | grep -c 'issue/bulkfetch')" -eq 0 ]
}

@test "prefetch_reset empties the map" {
  local cfg; cfg="$(_seed '{"COMP-1": {"summary": "S1", "properties": {}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  prefetch_load "COMP-1"
  prefetch_reset
  run prefetch_get "COMP-1" "summary"
  [ "$status" -eq 1 ]
}

@test "a deleted key (absent from the store) is simply a miss, never gone:true" {
  local cfg; cfg="$(_seed '{}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  prefetch_load "COMP-404"
  run prefetch_get "COMP-404" "summary"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a forbidden key (faulted on its own per-key path) is simply a miss" {
  cat > "${BATS_TEST_TMPDIR}/faults.json" << 'EOF'
{"issues": {"COMP-1": {"summary": "S1", "properties": {}}, "COMP-2": {"summary": "S2", "properties": {}}}, "faults": {"issue/COMP-2": {"status": 403}}}
EOF
  mock_start "${BATS_TEST_TMPDIR}/faults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  prefetch_load "COMP-1" "COMP-2"
  run prefetch_get "COMP-1" "summary"
  [ "$status" -eq 0 ]
  run prefetch_get "COMP-2" "summary"
  [ "$status" -eq 1 ]
}
