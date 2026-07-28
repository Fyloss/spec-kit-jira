#!/usr/bin/env bats
# T121 [US4] — Explicit binding resolution (003 FR-020, FR-021, FR-022,
# data-model §5).
#
# A pin REPLACES label discovery for its target and is then validated exactly
# like a discovered candidate: same routed-project check, same claim check, both
# hierarchy checks, the same refusal classes and the same exit codes. It needs no
# label on the ticket, and adoption never adds one.
#
# The engine owns the folder check (a pin naming a folder absent from disk is a
# usage error that stops the whole run with zero writes) and deliberately does
# NOT own the key-shape check — that lives in the sink (research §9).

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/engine/adoption.sh"
  PREFIX="speckit-adopt:"
  CFG='{"routing_default":"ADO"}'
  REPO="acme/app"
  ALL='["003-alpha","004-beta"]'
  SPECS='[{"folder":"003-alpha","story_ordinals":[1]}]'
}

classify() {
  adoption_classify "$(adoption_targets "${SPECS}" "${PREFIX}" "${CFG}")" "${1:-[]}" "${2:-[]}" "${REPO}"
}

# --- parsing the pin into a target (data-model §5) ---------------------------

@test "a bare folder pin targets the feature level" {
  run adoption_pins_resolve '["003-alpha=ADO-9"]' "${ALL}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].spec_folder' <<< "$output")" = "003-alpha" ]
  [ "$(jq -r '.[0].level' <<< "$output")" = "feature" ]
  [ "$(jq -r '.[0].story_ordinal' <<< "$output")" = "null" ]
  [ "$(jq -r '.[0].issue_key' <<< "$output")" = "ADO-9" ]
}

@test "a :usN pin targets that story" {
  run adoption_pins_resolve '["003-alpha:us2=ADO-9"]' "${ALL}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].level' <<< "$output")" = "story" ]
  [ "$(jq -r '.[0].story_ordinal' <<< "$output")" = "2" ]
}

@test "pins are repeatable and keep their order" {
  run adoption_pins_resolve '["003-alpha=ADO-1","004-beta:us1=ADO-2"]' "${ALL}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '[.[].issue_key] | join(",")' <<< "$output")" = "ADO-1,ADO-2" ]
}

@test "an empty pin list resolves to an empty array" {
  run adoption_pins_resolve '[]' "${ALL}"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- the folder must exist on disk (FR-021) ----------------------------------

@test "a pin naming a folder absent from disk is a usage error, exit 1" {
  run adoption_pins_resolve '["009-nope=ADO-1"]' "${ALL}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"009-nope"* ]]
}

@test "a story pin naming an absent folder is refused on the FOLDER, not the ordinal" {
  run adoption_pins_resolve '["009-nope:us1=ADO-1"]' "${ALL}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"009-nope"* ]]
  [[ "$output" != *"us1"* ]]
}

@test "one bad pin among good ones stops the whole run" {
  run adoption_pins_resolve '["003-alpha=ADO-1","009-nope=ADO-2"]' "${ALL}"
  [ "$status" -eq 1 ]
}

@test "a malformed pin value is a usage error" {
  run adoption_pins_resolve '["003-alpha-no-equals"]' "${ALL}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed"* ]]
}

# --- the engine applies NO key-shape check (research §9) ---------------------

@test "a structurally valid pin with a non-key-shaped value still resolves here" {
  # The shape check belongs to the sink; keeping it out of the engine is what
  # keeps every key-shaped literal on the sink side.
  run adoption_pins_resolve '["003-alpha=not-a-key"]' "${ALL}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].issue_key' <<< "$output")" = "not-a-key" ]
}

# --- a pin REPLACES discovery for its target (FR-020, FR-022) ---------------

@test "a pin binds with reason explicit-binding, needing no label on the ticket" {
  local cands pins
  cands='[{"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,"identity":null}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '[.bindings[] | select(.level=="feature")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.bindings[0].issue_key' <<< "$output")" = "ADO-9" ]
  [ "$(jq -r '.bindings[0].reason' <<< "$output")" = "explicit-binding" ]
}

@test "a pin resolves a target that discovery found NOTHING for (US2's remedy)" {
  local cands pins
  cands='[{"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,"identity":null}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '[.refusals[] | select(.level=="feature")] | length' <<< "$output")" -eq 0 ]
}

@test "a pin resolves a target discovery found SEVERAL candidates for (US2's remedy)" {
  local cands pins
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-2"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '[.refusals[] | select(.reason=="several-candidates")] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.bindings[0].issue_key' <<< "$output")" = "ADO-2" ]
}

@test "overrode_key names the discovered candidate the pin replaced (FR-022)" {
  local cands pins
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,"identity":null}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '.bindings[0].issue_key' <<< "$output")" = "ADO-9" ]
  [ "$(jq -r '.bindings[0].overrode_key' <<< "$output")" = "ADO-1" ]
}

@test "overrode_key is null when the pin names the SAME ticket discovery found" {
  local cands pins
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-1"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '.bindings[0].overrode_key' <<< "$output")" = "null" ]
}

@test "overrode_key is null when discovery found nothing to override" {
  local cands pins
  cands='[{"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,"identity":null}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '.bindings[0].overrode_key' <<< "$output")" = "null" ]
}

# --- a pin is validated EXACTLY like a discovered candidate (FR-020) --------

@test "a pin to a CLAIMED ticket is refused just as a discovered candidate would be" {
  local cands pins
  cands='[{"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,
           "identity":{"origin":"human","repo":"acme/app","spec_slug":"009-elsewhere"}}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '[.refusals[] | select(.reason=="already-claimed")] | length' <<< "$output")" -eq 1 ]
}

@test "a pin to a ticket outside the routed project is refused with wrong-project" {
  local cands pins
  cands='[{"key":"BILL-9","project_key":"BILL","labels":[],"parent_key":null,"identity":null}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"BILL-9"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '[.refusals[] | select(.reason=="wrong-project")] | length' <<< "$output")" -eq 1 ]
}

@test "a pinned STORY is still hierarchy-checked against the bound feature" {
  local cands pins
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":"ADO-77","identity":null}]'
  pins='[{"spec_folder":"003-alpha","level":"story","story_ordinal":1,"issue_key":"ADO-9"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '[.refusals[] | select(.reason=="wrong-parent")] | length' <<< "$output")" -eq 1 ]
}

@test "a pinned ticket already adopted by THIS spec is skipped, not re-stamped" {
  local cands pins
  cands='[{"key":"ADO-9","project_key":"ADO","labels":[],"parent_key":null,
           "identity":{"origin":"human","repo":"acme/app","spec_slug":"003-alpha"}}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"ADO-9"}]'
  run classify "${cands}" "${pins}"
  [ "$(jq -r '.bindings[0].status' <<< "$output")" = "already-adopted" ]
  [ "$(jq -r '.bindings[0].reason' <<< "$output")" = "explicit-binding" ]
}

@test "a pin overrides the ambiguous-short-number refusal it exists to remedy" {
  local specs cands pins
  specs='[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
  cands='[{"key":"ADO-5","project_key":"ADO","labels":["speckit-adopt:004"],"parent_key":null,"identity":null}]'
  pins='[{"spec_folder":"004-beta","level":"feature","story_ordinal":null,"issue_key":"ADO-5"}]'
  run adoption_classify "$(adoption_targets "${specs}" "${PREFIX}" "${CFG}")" "${cands}" "${pins}" "${REPO}"
  # 004-beta binds through the pin; only 004-gamma still reports the ambiguity.
  [ "$(jq -r '[.bindings[] | select(.spec_folder=="004-beta")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.refusals[] | select(.spec_folder=="004-beta")] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '[.refusals[] | select(.reason=="ambiguous-short-number")] | length' <<< "$output")" -eq 1 ]
}
