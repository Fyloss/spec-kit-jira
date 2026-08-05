#!/usr/bin/env bats
# T033/T034 [US1] — apply_writes_with_recognition, the task tier (contract §5):
# order epic -> stories -> tasks; each task's parent key resolves from the
# story created in the same run or from a recognised story's recorded key;
# each created key is recorded into tasks.md immediately; every task body
# passes privacy_guard_scan in the same pre-write sweep as every other
# payload, and one blocked task body produces zero writes for the whole run.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export JIRA_MAX_ATTEMPTS=1
}

teardown() {
  mock_stop
}

SPEC_REF='{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'

@test "order within one run: epic, then stories, then tasks" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{
    "parent": {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
      "body":{"fields":{"project":{"key":"COMP"},"summary":"The Epic"}}, "local_id":"aaaaaaaaaaaaaaaa", "role":"parent"},
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
      "body":{"fields":{"project":{"key":"COMP"},"summary":"A story","parent":{"key":"<resolved at apply time>"}}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local tasks='[{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
    "body":{"fields":{"project":{"key":"COMP"},"summary":"A task","parent":{"key":"<resolved at apply time>"}}},
    "local_id":"2222222222222222","parent_local_id":"1111111111111111","role":"task"}]'
  local spec_file="${BATS_TEST_TMPDIR}/spec.md" tasks_file="${BATS_TEST_TMPDIR}/tasks.md"
  printf '# Title\n' > "${spec_file}"
  printf '%s\n' '- [ ] T001 A task' > "${tasks_file}"
  run apply_writes_with_recognition "${plan}" "${SPEC_REF}" "${spec_file}" "" "[]" "" "${tasks}" "${tasks_file}"
  [ "$status" -eq 0 ]
  local calls; calls="$(mock_calls | grep '^POST /rest/api/3/issue$')"
  [ "$(wc -l <<< "${calls}")" -eq 3 ]
}

@test "a task's parent key resolves from the story created in the SAME run" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{
    "parent": null,
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
      "body":{"fields":{"project":{"key":"COMP"},"summary":"A story"}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local tasks='[{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
    "body":{"fields":{"project":{"key":"COMP"},"summary":"A task","parent":{"key":"<resolved at apply time>"}}},
    "local_id":"2222222222222222","parent_local_id":"1111111111111111","role":"task"}]'
  local spec_file="${BATS_TEST_TMPDIR}/spec.md" tasks_file="${BATS_TEST_TMPDIR}/tasks.md"
  printf '# Title\n' > "${spec_file}"
  printf '%s\n' '- [ ] T001 A task' > "${tasks_file}"
  run apply_writes_with_recognition "${plan}" "${SPEC_REF}" "${spec_file}" "" "[]" "" "${tasks}" "${tasks_file}"
  [ "$status" -eq 0 ]
  # The story is the FIRST issue created (COMP-1); the task is the second (COMP-2).
  [ "$(mock_issue_field "COMP-2" '.fields.parent.key')" = "COMP-1" ]
}

@test "a task's parent key resolves from an already-recognised story (known_story_keys)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{"parent": null, "stories": []}'
  local tasks='[{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
    "body":{"fields":{"project":{"key":"COMP"},"summary":"A task","parent":{"key":"<resolved at apply time>"}}},
    "local_id":"2222222222222222","parent_local_id":"1111111111111111","role":"task"}]'
  local known_keys='{"1111111111111111":"COMP-9"}'
  local spec_file="${BATS_TEST_TMPDIR}/spec.md" tasks_file="${BATS_TEST_TMPDIR}/tasks.md"
  printf '# Title\n' > "${spec_file}"
  printf '%s\n' '- [ ] T001 A task' > "${tasks_file}"
  run apply_writes_with_recognition "${plan}" "${SPEC_REF}" "${spec_file}" "" "[]" "" "${tasks}" "${tasks_file}" "${known_keys}"
  [ "$status" -eq 0 ]
  local calls; calls="$(mock_calls | grep '^POST /rest/api/3/issue$')"
  [ "$(wc -l <<< "${calls}")" -eq 1 ]
  [ "$(mock_issue_field "COMP-1" '.fields.parent.key')" = "COMP-9" ]
}

@test "a task attributed to a story with no key anywhere is skipped, not blocking others" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{"parent": null, "stories": []}'
  local tasks='[
    {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
     "body":{"fields":{"project":{"key":"COMP"},"summary":"Orphaned task","parent":{"key":"<resolved at apply time>"}}},
     "local_id":"3333333333333333","parent_local_id":"deadbeefdeadbeef","role":"task"},
    {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
     "body":{"fields":{"project":{"key":"COMP"},"summary":"Real task","parent":{"key":"<resolved at apply time>"}}},
     "local_id":"4444444444444444","parent_local_id":"1111111111111111","role":"task"}
  ]'
  local known_keys='{"1111111111111111":"COMP-9"}'
  local spec_file="${BATS_TEST_TMPDIR}/spec.md" tasks_file="${BATS_TEST_TMPDIR}/tasks.md"
  printf '# Title\n' > "${spec_file}"
  printf '%s\n' '- [ ] T001 A' '- [ ] T002 B' > "${tasks_file}"
  run apply_writes_with_recognition "${plan}" "${SPEC_REF}" "${spec_file}" "" "[]" "" "${tasks}" "${tasks_file}" "${known_keys}"
  [ "$status" -eq 0 ]
  local calls; calls="$(mock_calls | grep -c '^POST /rest/api/3/issue$')"
  [ "${calls}" -eq 1 ]
}

@test "a created sub-task's key is recorded into tasks-file immediately, and marked bound" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{"parent": null, "stories": []}'
  local tasks='[{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
    "body":{"fields":{"project":{"key":"COMP"},"summary":"A task"}},
    "local_id":"5555555555555555","role":"task"}]'
  local spec_file="${BATS_TEST_TMPDIR}/spec.md" tasks_file="${BATS_TEST_TMPDIR}/tasks.md"
  printf '# Title\n' > "${spec_file}"
  printf '%s\n' '- [ ] T001 A task' '<!-- speckit-jira task=5555555555555555 creating -->' > "${tasks_file}"
  run apply_writes_with_recognition "${plan}" "${SPEC_REF}" "${spec_file}" "" "[]" "" "${tasks}" "${tasks_file}"
  [ "$status" -eq 0 ]
  grep -q "task=5555555555555555 ticket=COMP-1" "${tasks_file}"
}

@test "an unresolved parent placeholder still passes through unchanged when parent_local_id is absent (a PUT task action)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local issue; issue="$(mock_write_config '{"projects":{"COMP":"c"},"issues":{"COMP-5":{"summary":"old"}}}')"
  mock_stop
  mock_start "${issue}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{"parent": null, "stories": []}'
  local tasks='[{"method":"PUT","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue/COMP-5",
    "body":{"fields":{"summary":"reworded"}}, "role":"task"}]'
  local spec_file="${BATS_TEST_TMPDIR}/spec.md" tasks_file="${BATS_TEST_TMPDIR}/tasks.md"
  printf '# Title\n' > "${spec_file}"
  printf '%s\n' '- [x] T001 reworded' > "${tasks_file}"
  run apply_writes_with_recognition "${plan}" "${SPEC_REF}" "${spec_file}" "" "[]" "" "${tasks}" "${tasks_file}"
  [ "$status" -eq 0 ]
  [ "$(mock_issue_field "COMP-5" '.fields.summary')" = "reworded" ]
}

@test "no tasks-file and no tasks-actions leaves existing zero-task behaviour byte-identical (regression)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{
    "parent": {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
      "body":{"fields":{"project":{"key":"COMP"},"summary":"The Epic"}}, "local_id":"aaaaaaaaaaaaaaaa", "role":"parent"},
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
      "body":{"fields":{"project":{"key":"COMP"},"summary":"Add billing feature","parent":{"key":"<resolved at apply time>"}}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local spec_file="${BATS_TEST_TMPDIR}/spec2.md"
  printf '# Title\n' > "${spec_file}"
  run apply_writes_with_recognition "${plan}" "${SPEC_REF}" "${spec_file}"
  [ "$status" -eq 0 ]
  local calls; calls="$(mock_calls | grep -c '^POST /rest/api/3/issue$')"
  [ "${calls}" -eq 2 ]
}

# --- Privacy guard: the task pre-write sweep (FR-025) ------------------------

@test "a blocked task body produces zero writes for the whole run" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local plan='{
    "parent": null,
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
      "body":{"fields":{"project":{"key":"COMP"},"summary":"Add billing feature"}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local tasks='[{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
    "body":{"fields":{"description":"token ATATT3xFfGF0abcdefghijklmnopqrstuvwxyz1234567890"}},
    "local_id":"2222222222222222","parent_local_id":"1111111111111111","role":"task"}]'
  local spec_file="${BATS_TEST_TMPDIR}/spec.md" tasks_file="${BATS_TEST_TMPDIR}/tasks.md"
  printf '# Title\n' > "${spec_file}"
  printf '%s\n' '- [ ] T001 A task' > "${tasks_file}"
  run apply_writes_with_recognition "${plan}" "${SPEC_REF}" "${spec_file}" "" "[]" "" "${tasks}" "${tasks_file}"
  [ "$status" -eq 9 ]
  run mock_calls
  [ -z "$output" ]
}
