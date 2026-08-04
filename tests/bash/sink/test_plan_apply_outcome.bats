#!/usr/bin/env bats
# 015 T024 [US3] — `apply_writes_with_recognition`'s confirmed-creation
# outcome (contract §4.2, data-model.md §5, research R4): a canonical
# {"created":[{key, role, local_id}, ...]} object on stdout, an entry only
# after Jira returned a key for that creation, the parent first, printed on
# each of the three post-write exit paths (normal completion, parent
# rejection, story rejection) and nothing else.
#
# A dedicated file, not test_plan_apply_defaults.bats (US1's) or
# test_privacy_block.bats (the pre-write O4 rule) — this is what keeps US3
# genuinely parallel with US1.

bats_require_minimum_version 1.5.0

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
}

teardown() {
  mock_stop
}

boot() {
  local cfg
  cfg="$(mktemp)"
  printf '%s' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "normal completion: the outcome names both creations, parent first (O1/O2/O3)" {
  boot '{"projects":{"AAA":"team"}}'
  local plan='{
    "parent": {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
               "body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10101"},"summary":"The Epic"}}, "local_id":"aaaaaaaaaaaaaaaa", "role":"parent"},
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
                 "body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10102"},"summary":"A story","parent":{"key":"<resolved at apply time>"}}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local spec_ref='{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
  local spec_file="${BATS_TEST_TMPDIR}/spec.md"
  printf '# Title\n' > "${spec_file}"
  run apply_writes_with_recognition "${plan}" "${spec_ref}" "${spec_file}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.created | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.created[0].role' <<< "$output")" = "parent" ]
  [ "$(jq -r '.created[0].key' <<< "$output")" = "AAA-1" ]
  [ "$(jq -r '.created[1].role' <<< "$output")" = "story" ]
  [ "$(jq -r '.created[1].key' <<< "$output")" = "AAA-2" ]
  [ "$(jq -r '. | keys' <<< "$output" | jq -c .)" = '["created"]' ]
}

@test "parent rejection: the outcome is empty — nothing was created before the parent's own write failed (O1/O3)" {
  boot '{"projects":{"AAA":"team"},"faults":{"AAA":{"status":400}}}'
  local plan='{
    "parent": {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
               "body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10101"},"summary":"The Epic"}}, "local_id":"aaaaaaaaaaaaaaaa", "role":"parent"},
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
                 "body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10102"},"summary":"A story","parent":{"key":"<resolved at apply time>"}}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local spec_ref='{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
  local spec_file="${BATS_TEST_TMPDIR}/spec2.md"
  printf '# Title\n' > "${spec_file}"
  run apply_writes_with_recognition "${plan}" "${spec_ref}" "${spec_file}"
  [ "$status" -eq 2 ]
  [ "$(jq -c '.' <<< "$output")" = '{"created":[]}' ]
}

@test "story rejection: the outcome carries the parent already created, and nothing for the failed story (O1/O2/O3)" {
  boot '{"projects":{"AAA":"team","BBB":"team"},"faults":{"BBB":{"status":400}}}'
  local plan='{
    "parent": {"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
               "body":{"fields":{"project":{"key":"AAA"},"issuetype":{"id":"10101"},"summary":"The Epic"}}, "local_id":"aaaaaaaaaaaaaaaa", "role":"parent"},
    "stories": [{"method":"POST","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue",
                 "body":{"fields":{"project":{"key":"BBB"},"issuetype":{"id":"10102"},"summary":"A story"}}, "local_id":"1111111111111111", "role":"story"}]
  }'
  local spec_ref='{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
  local spec_file="${BATS_TEST_TMPDIR}/spec3.md"
  printf '# Title\n' > "${spec_file}"
  run apply_writes_with_recognition "${plan}" "${spec_ref}" "${spec_file}"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.created | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.created[0].role' <<< "$output")" = "parent" ]
  [ "$(jq -r '.created[0].key' <<< "$output")" = "AAA-1" ]
}

@test "O5 — an UPDATE (PUT) never produces a created entry" {
  boot '{"projects":{"AAA":"team"},"createdKey":"AAA-9"}'
  local plan='{
    "parent": null,
    "stories": [{"method":"PUT","url":"'"${MOCK_BASE_URL}"'/rest/api/3/issue/AAA-9",
                 "body":{"fields":{"summary":"Updated"}}}]
  }'
  local spec_ref='{"repo":"acme/app","spec_slug":"001-x","folder":"specs/001-x"}'
  local spec_file="${BATS_TEST_TMPDIR}/spec4.md"
  printf '# Title\n' > "${spec_file}"
  run apply_writes_with_recognition "${plan}" "${spec_ref}" "${spec_file}"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' <<< "$output")" = '{"created":[]}' ]
}
