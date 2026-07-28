#!/usr/bin/env bats
# T035 [US1] — Adoption candidate discovery (003 research §1/§2, FR-004, NFR-6).
#
# One paginated JQL label search per DISTINCT routed project, over the union of
# that project's derived label values — never one query per spec folder. The JQL
# is assembled from those values alone. Pagination loops on `nextPageToken` to
# EXHAUSTION: a truncated candidate list would turn a two-candidate ambiguity
# (which must be refused) into a one-candidate binding (which would be applied).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${SINK}/adoption.sh"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

start() {
  mock_start "${MOCK}/configs/$1"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

# Targets for the three-folder corpus in configs/adoption.json.
targets_single_project() {
  cat <<'JSON'
[{"spec_folder":"003-label-based-adoption","level":"feature","story_ordinal":null,
  "project_key":"ADO","labels":["speckit-adopt:003-label-based-adoption","speckit-adopt:003"],
  "probe_labels":[],"short_conflict":null},
 {"spec_folder":"003-label-based-adoption","level":"story","story_ordinal":1,
  "project_key":"ADO","labels":["speckit-adopt:003-label-based-adoption:us1"],
  "probe_labels":[],"short_conflict":null}]
JSON
}

@test "the JQL names the project and the labels, and asks for the three fields only" {
  start adoption.json
  run adopt_search_candidates "$(targets_single_project)"
  [ "$status" -eq 0 ]
  local calls
  calls="$(mock_calls)"
  [[ "$calls" == *"GET /rest/api/3/search/jql?jql="* ]]
  [[ "$calls" == *"project+%3D+%22ADO%22"* ]]
  [[ "$calls" == *"labels+IN+"* ]]
  [[ "$calls" == *"fields=labels,parent,project"* ]]
  [[ "$calls" == *"maxResults=100"* ]]
}

@test "one query per DISTINCT routed project, not one per spec folder (FR-004)" {
  start adoption.json
  local targets
  targets='[{"spec_folder":"a","level":"feature","story_ordinal":null,"project_key":"ADO","labels":["speckit-adopt:003-label-based-adoption"],"probe_labels":[],"short_conflict":null},
            {"spec_folder":"b","level":"feature","story_ordinal":null,"project_key":"ADO","labels":["speckit-adopt:004-billing-export"],"probe_labels":[],"short_conflict":null},
            {"spec_folder":"c","level":"feature","story_ordinal":null,"project_key":"BILL","labels":["speckit-adopt:005-audit-trail"],"probe_labels":[],"short_conflict":null}]'
  run adopt_search_candidates "${targets}"
  [ "$status" -eq 0 ]
  # Three folders, two projects => exactly two searches.
  [ "$(mock_calls | grep -c '^GET /rest/api/3/search/jql')" -eq 2 ]
  [ "$(jq -r '[.[].key] | join(",")' <<< "$output")" = "ADO-1,ADO-3,BILL-4" ]
}

@test "a suppressed short label is still probed so its ambiguity is reportable" {
  start adoption.json
  local targets
  targets='[{"spec_folder":"004-beta","level":"feature","story_ordinal":null,"project_key":"ADO",
             "labels":["speckit-adopt:004-beta"],"probe_labels":["speckit-adopt:004"],
             "short_conflict":{"label":"speckit-adopt:004","folders":["004-beta","004-gamma"]}}]'
  run adopt_search_candidates "${targets}"
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *"speckit-adopt%3A004%22"* ]]
}

@test "candidates carry key, project, labels and parent, and no identity yet" {
  start adoption.json
  run adopt_search_candidates "$(targets_single_project)"
  [ "$status" -eq 0 ]
  local story
  story="$(jq -c '.[] | select(.key=="ADO-2")' <<< "$output")"
  [ "$(jq -r '.project_key' <<< "$story")" = "ADO" ]
  [ "$(jq -r '.parent_key' <<< "$story")" = "ADO-1" ]
  [ "$(jq -r '.labels[0]' <<< "$story")" = "speckit-adopt:003-label-based-adoption:us1" ]
  [ "$(jq -r '.identity' <<< "$story")" = "null" ]
  [ "$(jq -r '.[] | select(.key=="ADO-1") | .parent_key' <<< "$output")" = "null" ]
}

@test "candidates are ordered by key ascending" {
  start adoption-paged.json
  local targets
  targets='[{"spec_folder":"003-label-based-adoption","level":"feature","story_ordinal":null,"project_key":"ADO",
             "labels":["speckit-adopt:003-label-based-adoption"],"probe_labels":[],"short_conflict":null}]'
  run adopt_search_candidates "${targets}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].key] | join(",")' <<< "$output")" = "ADO-1,ADO-2,ADO-3,ADO-4,ADO-5" ]
}

@test "pagination loops to token exhaustion so no candidate is silently dropped (NFR-6)" {
  start adoption-paged.json
  local targets
  targets='[{"spec_folder":"003-label-based-adoption","level":"feature","story_ordinal":null,"project_key":"ADO",
             "labels":["speckit-adopt:003-label-based-adoption"],"probe_labels":[],"short_conflict":null}]'
  run adopt_search_candidates "${targets}"
  [ "$status" -eq 0 ]
  # Five issues at a page size of two => three pages, two of them cursor-driven.
  [ "$(jq -r 'length' <<< "$output")" -eq 5 ]
  [ "$(mock_calls | grep -c '^GET /rest/api/3/search/jql')" -eq 3 ]
  [ "$(mock_calls | grep -c 'nextPageToken=')" -eq 2 ]
}

@test "a label matching nothing yields an empty candidate list, not an error" {
  start adoption.json
  local targets
  targets='[{"spec_folder":"009-absent","level":"feature","story_ordinal":null,"project_key":"ADO",
             "labels":["speckit-adopt:009-absent"],"probe_labels":[],"short_conflict":null}]'
  run adopt_search_candidates "${targets}"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "an unset site is a fail-closed read before any query (exit 2)" {
  SPEC_KIT_JIRA_BASE_URL="" run adopt_search_candidates "$(targets_single_project)"
  [ "$status" -eq 2 ]
}
