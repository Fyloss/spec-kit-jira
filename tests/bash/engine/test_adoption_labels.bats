#!/usr/bin/env bats
# T029 [US1] — Adoption label grammar (003 research §3, data-model §3).
#
# Three recognised forms over the operator-declared prefix: the full folder, the
# story form anchored on the ordinal the bridge already assigns, and the short
# numbering form — the last emitted ONLY when that number is unique among the
# folders in scope. Matching is case-sensitive and exact; a label carrying the
# prefix alone, or naming a folder absent from disk, is never derived and is
# therefore never even searched for (FR-003's "never infer", structurally).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE}/adoption.sh"
  PREFIX="speckit-adopt:"
}

# --- the three forms ---------------------------------------------------------

@test "a feature target implies the full-folder form" {
  run adoption_labels_for "${PREFIX}" "003-label-based-adoption" feature
  [ "$status" -eq 0 ]
  [ "$output" = '["speckit-adopt:003-label-based-adoption"]' ]
}

@test "a story target implies the story form anchored on the ordinal" {
  run adoption_labels_for "${PREFIX}" "003-label-based-adoption" story 2
  [ "$status" -eq 0 ]
  [ "$output" = '["speckit-adopt:003-label-based-adoption:us2"]' ]
}

@test "a unique numbering component adds the short form to a feature target" {
  run adoption_labels_for "${PREFIX}" "003-label-based-adoption" feature "" "003"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '. | index("speckit-adopt:003") != null' <<< "$output")" = "true" ]
}

@test "a story target never carries the short form" {
  run adoption_labels_for "${PREFIX}" "003-label-based-adoption" story 1 "003"
  [ "$output" = '["speckit-adopt:003-label-based-adoption:us1"]' ]
}

@test "the prefix alone is never a derived label" {
  run adoption_labels_for "${PREFIX}" "003-label-based-adoption" feature
  [[ "$output" != *'"speckit-adopt:"'* ]]
}

# --- numbering component -----------------------------------------------------

@test "adoption_number_component reads the leading digits before the first hyphen" {
  [ "$(adoption_number_component '003-label-based-adoption')" = "003" ]
  [ "$(adoption_number_component '0042-many-digits')" = "0042" ]
}

@test "adoption_number_component is empty for a folder that does not begin with digits" {
  [ "$(adoption_number_component 'billing-export')" = "" ]
  [ "$(adoption_number_component '003')" = "" ]
}

# --- short form only when the number is unique in scope ----------------------

@test "the short form is emitted when exactly one folder in scope carries the number" {
  specs='[{"folder":"003-alpha","story_ordinals":[]},{"folder":"004-beta","story_ordinals":[]}]'
  run adoption_targets "${specs}" "${PREFIX}" '{"routing_default":"ADO"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.spec_folder=="003-alpha" and .level=="feature") | .labels | index("speckit-adopt:003") != null' <<< "$output")" = "true" ]
  [ "$(jq -r '.[] | select(.spec_folder=="003-alpha") | .short_conflict' <<< "$output")" = "null" ]
}

@test "two folders sharing a number suppress the short form for BOTH (data-model §3)" {
  specs='[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
  run adoption_targets "${specs}" "${PREFIX}" '{"routing_default":"ADO"}'
  [ "$status" -eq 0 ]
  for f in 004-beta 004-gamma; do
    [ "$(jq -r --arg f "$f" '.[] | select(.spec_folder==$f) | .labels | index("speckit-adopt:004")' <<< "$output")" = "null" ]
    # ...but the suppressed value is still PROBED so a ticket carrying it is
    # discoverable and can be refused by name rather than matching nothing.
    [ "$(jq -r --arg f "$f" '.[] | select(.spec_folder==$f) | .probe_labels[0]' <<< "$output")" = "speckit-adopt:004" ]
    [ "$(jq -r --arg f "$f" '.[] | select(.spec_folder==$f) | .short_conflict.folders | join(",")' <<< "$output")" = "004-beta,004-gamma" ]
  done
}

# --- prefix validation (FR-002) ----------------------------------------------

@test "an empty prefix is a located configuration error (exit 4)" {
  run adoption_validate_prefix "" 40
  [ "$status" -eq 4 ]
  [[ "$output" == *"label_prefix"* ]]
  [[ "$output" == *"empty"* ]]
}

@test "a whitespace-bearing prefix is a located configuration error (exit 4)" {
  run adoption_validate_prefix "speckit adopt:" 40
  [ "$status" -eq 4 ]
  [[ "$output" == *"whitespace"* ]]
  run adoption_validate_prefix "speckit-adopt:$(printf '\t')" 40
  [ "$status" -eq 4 ]
}

@test "a prefix whose longest implied label exceeds the limit is refused (exit 4)" {
  long="$(printf 'a%.0s' $(seq 1 240))"
  run adoption_validate_prefix "${long}" 20
  [ "$status" -eq 4 ]
  [[ "$output" == *"255"* ]]
  # Exactly at the limit is accepted.
  run adoption_validate_prefix "${long}" 15
  [ "$status" -eq 0 ]
}

@test "a valid prefix passes silently" {
  run adoption_validate_prefix "${PREFIX}" 40
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "adoption_longest_suffix accounts for the story form, not just the folder" {
  specs='[{"folder":"003-alpha","story_ordinals":[1,12]},{"folder":"0004-b","story_ordinals":[]}]'
  # "003-alpha" is 9 chars; ":us12" adds 5 -> 14.
  [ "$(adoption_longest_suffix "${specs}")" = "14" ]
}

@test "adoption_longest_suffix is 0 for an empty scope" {
  [ "$(adoption_longest_suffix '[]')" = "0" ]
}
