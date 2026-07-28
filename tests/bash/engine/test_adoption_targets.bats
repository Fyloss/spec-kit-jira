#!/usr/bin/env bats
# T031 [US1] / T157 [US6] — Adoption target derivation (003 data-model §2, §6).
#
# One `feature` target per spec folder in scope plus one `story` target per user
# story, each carrying the labels it implies and the project the EXISTING routing
# resolver binds the folder to (FR-004). The order is total and deterministic —
# folder ascending, feature before story, ordinal ascending — because that order
# is what makes the plan bytes identical across ports (SC-008).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE}/adoption.sh"
  PREFIX="speckit-adopt:"
  CFG='{"routing":[{"match":{"folder_prefix":"005-"},"project":"BILL"}],"routing_default":"ADO"}'
}

# --- shape -------------------------------------------------------------------

@test "a spec yields one feature target plus one story target per user story" {
  specs='[{"folder":"003-alpha","story_ordinals":[1,2]}]'
  run adoption_targets "${specs}" "${PREFIX}" "${CFG}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '[.[] | select(.level=="feature")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.[] | select(.level=="story")] | length' <<< "$output")" -eq 2 ]
}

@test "story_ordinal is non-null exactly when the level is story" {
  specs='[{"folder":"003-alpha","story_ordinals":[1]}]'
  run adoption_targets "${specs}" "${PREFIX}" "${CFG}"
  [ "$(jq -r '.[] | select(.level=="feature") | .story_ordinal' <<< "$output")" = "null" ]
  [ "$(jq -r '.[] | select(.level=="story") | .story_ordinal' <<< "$output")" = "1" ]
}

@test "a spec with no user story yields the feature target alone" {
  specs='[{"folder":"003-alpha","story_ordinals":[]}]'
  run adoption_targets "${specs}" "${PREFIX}" "${CFG}"
  [ "$(jq -r 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].level' <<< "$output")" = "feature" ]
}

# --- routing (FR-004) --------------------------------------------------------

@test "project_key is resolved through the existing routing resolver" {
  specs='[{"folder":"003-alpha","story_ordinals":[]},{"folder":"005-delta","story_ordinals":[1]}]'
  run adoption_targets "${specs}" "${PREFIX}" "${CFG}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.spec_folder=="003-alpha") | .project_key' <<< "$output")" = "ADO" ]
  [ "$(jq -r '[.[] | select(.spec_folder=="005-delta") | .project_key] | unique | join(",")' <<< "$output")" = "BILL" ]
}

@test "an unroutable folder propagates the routing resolver's configuration error" {
  specs='[{"folder":"999-orphan","story_ordinals":[]}]'
  run adoption_targets "${specs}" "${PREFIX}" '{"routing":[{"match":{"folder_prefix":"x-"},"project":"X"}]}'
  [ "$status" -eq 4 ]
}

# --- ordering (data-model §2) ------------------------------------------------

@test "targets are ordered folder ascending, feature before story, ordinal ascending" {
  specs='[{"folder":"005-delta","story_ordinals":[2,1]},{"folder":"003-alpha","story_ordinals":[1]}]'
  run adoption_targets "${specs}" "${PREFIX}" "${CFG}"
  [ "$status" -eq 0 ]
  expected='003-alpha/feature/
003-alpha/story/1
005-delta/feature/
005-delta/story/1
005-delta/story/2'
  actual="$(jq -r '.[] | "\(.spec_folder)/\(.level)/\(if .story_ordinal == null then "" else (.story_ordinal|tostring) end)"' <<< "$output")"
  [ "$actual" = "$expected" ]
}

@test "the derivation is deterministic — the same input yields the same bytes" {
  specs='[{"folder":"005-delta","story_ordinals":[2,1]},{"folder":"003-alpha","story_ordinals":[1]}]'
  a="$(adoption_targets "${specs}" "${PREFIX}" "${CFG}")"
  b="$(adoption_targets "${specs}" "${PREFIX}" "${CFG}")"
  [ "$a" = "$b" ]
}

# --- labels carried on the target -------------------------------------------

@test "each target carries the exact labels it implies and nothing else" {
  specs='[{"folder":"003-alpha","story_ordinals":[1]}]'
  run adoption_targets "${specs}" "${PREFIX}" "${CFG}"
  [ "$(jq -r '.[] | select(.level=="feature") | .labels | sort | join(",")' <<< "$output")" = "speckit-adopt:003,speckit-adopt:003-alpha" ]
  [ "$(jq -r '.[] | select(.level=="story") | .labels | join(",")' <<< "$output")" = "speckit-adopt:003-alpha:us1" ]
}

@test "no label is derived for a folder outside the given scope (FR-026)" {
  # Scope is applied BEFORE derivation, so an out-of-scope folder contributes no
  # label to any query — which is what makes "zero reads" assertable (T157).
  specs='[{"folder":"003-alpha","story_ordinals":[]}]'
  run adoption_targets "${specs}" "${PREFIX}" "${CFG}"
  [[ "$output" != *"004-beta"* ]]
  [[ "$output" != *"005-delta"* ]]
}

@test "the short-number uniqueness test is evaluated over the folders IN SCOPE (T157, data-model §6)" {
  # 004-beta and 004-gamma share the number, but with only one of them in scope
  # the short form is unambiguous and binds.
  in_scope='[{"folder":"004-beta","story_ordinals":[]}]'
  run adoption_targets "${in_scope}" "${PREFIX}" "${CFG}"
  [ "$(jq -r '.[0].labels | index("speckit-adopt:004") != null' <<< "$output")" = "true" ]
  [ "$(jq -r '.[0].short_conflict' <<< "$output")" = "null" ]

  both='[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
  run adoption_targets "${both}" "${PREFIX}" "${CFG}"
  [ "$(jq -r '.[0].labels | index("speckit-adopt:004")' <<< "$output")" = "null" ]
  [ "$(jq -r '.[0].short_conflict.label' <<< "$output")" = "speckit-adopt:004" ]
}

# --- scope resolution (FR-026) -----------------------------------------------

@test "an absent scope keeps every folder in scope" {
  run adoption_scope '["003-alpha","001-zeta"]' '[]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.in_scope | join(",")' <<< "$output")" = "001-zeta,003-alpha" ]
  [ "$(jq -r '.out_of_scope | length' <<< "$output")" -eq 0 ]
}

@test "a scope splits the folders and sorts both lists ascending" {
  run adoption_scope '["003-alpha","001-zeta","005-delta"]' '["005-delta","003-alpha"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.in_scope | join(",")' <<< "$output")" = "003-alpha,005-delta" ]
  [ "$(jq -r '.out_of_scope | join(",")' <<< "$output")" = "001-zeta" ]
}

@test "a scope naming a folder absent from disk is a usage error (exit 1)" {
  run adoption_scope '["003-alpha"]' '["009-nope"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"009-nope"* ]]
}
