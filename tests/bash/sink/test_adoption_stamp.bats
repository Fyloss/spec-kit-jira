#!/usr/bin/env bats
# T041 [US1] — The adoption stamp action set (003 FR-007, FR-027, research §7).
#
# The ONLY write adoption ever emits is one identity entity-property PUT per
# binding whose status is `adopt`, carrying origin `human`. The payload is built
# by the SAME `identity_marker` the mention command uses, so the two stamping
# paths cannot drift; the set is executed by the existing `apply_writes`, so the
# BLOCK-tier privacy guard and the fail-closed abort ladder are inherited.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK}/adoption.sh"
  export SPEC_KIT_JIRA_BASE_URL="http://jira.invalid"
  BINDINGS='[{"spec_folder":"003-a","level":"feature","story_ordinal":null,"issue_key":"ADO-1",
              "reason":"label-match","overrode_key":null,"status":"adopt"},
             {"spec_folder":"003-a","level":"story","story_ordinal":1,"issue_key":"ADO-2",
              "reason":"label-match","overrode_key":null,"status":"adopt"}]'
}

@test "one PUT of the identity property per adopted binding, and nothing else" {
  run adopt_stamp_actions "${BINDINGS}" "acme/app"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '[.[] | select(.method != "PUT")] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.[0].url' <<< "$output")" = "http://jira.invalid/rest/api/3/issue/ADO-1/properties/spec-kit-jira" ]
  [ "$(jq -r '.[1].url' <<< "$output")" = "http://jira.invalid/rest/api/3/issue/ADO-2/properties/spec-kit-jira" ]
}

@test "adoption emits no create, transition, comment, link, relabel or content write (FR-007)" {
  run adopt_stamp_actions "${BINDINGS}" "acme/app"
  # Every URL is an identity property; no bare /issue, /transitions, /comment,
  # /issuelink or field update can appear.
  [ "$(jq -r '[.[] | select(.url | endswith("/properties/spec-kit-jira") | not)] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '[.[] | select(.body | has("fields"))] | length' <<< "$output")" -eq 0 ]
  [[ "$output" != *"transitions"* ]]
  [[ "$output" != *"comment"* ]]
}

@test "the stamp body carries origin human and the spec ref (FR-016)" {
  run adopt_stamp_actions "${BINDINGS}" "acme/app"
  [ "$(jq -r '.[0].body.origin' <<< "$output")" = "human" ]
  [ "$(jq -r '.[0].body.repo' <<< "$output")" = "acme/app" ]
  [ "$(jq -r '.[0].body.spec_slug' <<< "$output")" = "003-a" ]
  # No new marker field is introduced (data-model §9).
  [ "$(jq -r '.[0].body | keys | join(",")' <<< "$output")" = "origin,repo,spec_slug" ]
}

@test "the payload equals what identity_marker builds for the same spec ref" {
  run adopt_stamp_actions "${BINDINGS}" "acme/app"
  local expected
  expected="$(identity_marker '{"repo":"acme/app","spec_slug":"003-a"}' human)"
  [ "$(jq -c '.[0].body' <<< "$output")" = "${expected}" ]
}

@test "an already-adopted binding produces NO action at all (FR-027)" {
  local b
  b='[{"spec_folder":"003-a","level":"feature","story_ordinal":null,"issue_key":"ADO-1",
       "reason":"label-match","overrode_key":null,"status":"already-adopted"}]'
  run adopt_stamp_actions "${b}" "acme/app"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "actions follow the binding order, so the plan and the run agree" {
  run adopt_stamp_actions "${BINDINGS}" "acme/app"
  [ "$(jq -r '[.[].url | split("/")[7]] | join(",")' <<< "$output")" = "ADO-1,ADO-2" ]
}

@test "no bindings means no actions" {
  run adopt_stamp_actions '[]' "acme/app"
  [ "$output" = "[]" ]
}
