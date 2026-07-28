#!/usr/bin/env bats
# T076 [US2] — Hierarchy and scope refusals (003 FR-005, FR-014, FR-015,
# data-model §8).
#
#   wrong-project           the candidate's project is not the spec's routed one,
#   unbound-parent          a story whose spec's feature ticket is not bound,
#   wrong-parent            the candidate's parent is not that bound ticket,
#   ambiguous-short-number  the short label names a number two folders share.
#
# Every message names the spec folder and every key or project key involved, and
# every one leaves ZERO writes for its binding while the rest of the run applies.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/engine/adoption.sh"
  PREFIX="speckit-adopt:"
  CFG='{"routing":[{"match":{"folder_prefix":"005-"},"project":"BILL"}],"routing_default":"ADO"}'
  REPO="acme/app"
}

classify() {
  adoption_classify "$(adoption_targets "$1" "${PREFIX}" "${CFG}")" "${2:-[]}" "${3:-[]}" "${REPO}"
}

refusal() {
  jq -c --arg r "$1" '.refusals[] | select(.reason == $r)' <<< "$2"
}

# --- wrong-project (FR-005) --------------------------------------------------
# Reachable only through an explicit binding: discovery searches inside the
# spec's routed project, so a discovered candidate is project-correct by
# construction. That is the guarantee this test pins.

@test "a pin to a ticket outside the routed project refuses with wrong-project" {
  local specs cands pins
  specs='[{"folder":"003-alpha","story_ordinals":[]}]'
  cands='[{"key":"BILL-9","project_key":"BILL","labels":[],"parent_key":null,"identity":null}]'
  pins='[{"spec_folder":"003-alpha","level":"feature","story_ordinal":null,"issue_key":"BILL-9"}]'
  run classify "${specs}" "${cands}" "${pins}"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 0 ]
  local r
  r="$(refusal wrong-project "$output")"
  [ -n "$r" ]
  local msg
  msg="$(jq -r '.message' <<< "$r")"
  [[ "$msg" == *"003-alpha"* ]]
  [[ "$msg" == *"ADO"* ]]
  [[ "$msg" == *"BILL"* ]]
  [[ "$msg" == *"BILL-9"* ]]
  [[ "$msg" == *"never migrates"* ]]
}

@test "a discovered candidate in the routed project is never wrong-project" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'
  run classify "${specs}" "${cands}"
  [ "$(jq -r '.refusals | length' <<< "$output")" -eq 0 ]
}

# --- unbound-parent (FR-014) -------------------------------------------------

@test "a story whose feature ticket is not bound refuses with unbound-parent" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[1]}]'
  # Only the story is labelled; the feature target finds nothing.
  cands='[{"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-1","identity":null}]'
  run classify "${specs}" "${cands}"
  local r
  r="$(refusal unbound-parent "$output")"
  [ -n "$r" ]
  local msg
  msg="$(jq -r '.message' <<< "$r")"
  [[ "$msg" == *"003-alpha:us1"* ]]
  [[ "$msg" == *"ADO-2"* ]]
  [[ "$(jq -r '.remediation' <<< "$r")" == *"--bind 003-alpha="* ]]
}

@test "a feature bound in THIS run satisfies the story's parent requirement" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[1]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-1","identity":null}]'
  run classify "${specs}" "${cands}"
  [ "$(jq -r '.refusals | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 2 ]
}

@test "an ALREADY-ADOPTED feature also counts as bound for its stories" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[1]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,
           "identity":{"origin":"human","repo":"acme/app","spec_slug":"003-alpha"}},
          {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-1","identity":null}]'
  run classify "${specs}" "${cands}"
  [ "$(jq -r '.refusals | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.bindings[0].status' <<< "$output")" = "already-adopted" ]
  [ "$(jq -r '.bindings[1].status' <<< "$output")" = "adopt" ]
}

# --- wrong-parent (FR-015) ---------------------------------------------------

@test "a story whose parent is not the spec's bound ticket refuses with wrong-parent" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[1]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-77","identity":null}]'
  run classify "${specs}" "${cands}"
  local r
  r="$(refusal wrong-parent "$output")"
  [ -n "$r" ]
  local msg
  msg="$(jq -r '.message' <<< "$r")"
  [[ "$msg" == *"003-alpha:us1"* ]]
  [[ "$msg" == *"ADO-2"* ]]
  [[ "$msg" == *"ADO-77"* ]]
  [[ "$msg" == *"ADO-1"* ]]
  # Every key involved is listed, sorted.
  [ "$(jq -r '.issue_keys | join(",")' <<< "$r")" = "ADO-1,ADO-2,ADO-77" ]
}

@test "a story candidate with NO parent at all refuses with wrong-parent" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[1]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":null,"identity":null}]'
  run classify "${specs}" "${cands}"
  local r
  r="$(refusal wrong-parent "$output")"
  [ -n "$r" ]
  [[ "$(jq -r '.message' <<< "$r")" == *"(none)"* ]]
}

@test "wrong-parent never re-parents — the remediation is a Jira action" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[1]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-77","identity":null}]'
  run classify "${specs}" "${cands}"
  [[ "$(jq -r '.refusals[0].remediation' <<< "$output")" == *"re-parent ADO-2 under ADO-1"* ]]
}

# --- ambiguous-short-number (spec edge case) ---------------------------------

@test "a short-form label naming a number two folders share refuses both" {
  local specs cands
  specs='[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
  cands='[{"key":"ADO-5","project_key":"ADO","labels":["speckit-adopt:004"],"parent_key":null,"identity":null}]'
  run classify "${specs}" "${cands}"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '[.refusals[] | select(.reason == "ambiguous-short-number")] | length' <<< "$output")" -eq 2 ]
}

@test "the ambiguous-short-number message names BOTH spec folders and the label" {
  local specs cands
  specs='[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
  cands='[{"key":"ADO-5","project_key":"ADO","labels":["speckit-adopt:004"],"parent_key":null,"identity":null}]'
  run classify "${specs}" "${cands}"
  local msg
  msg="$(jq -r '.refusals[0].message' <<< "$output")"
  [[ "$msg" == *"speckit-adopt:004"* ]]
  [[ "$msg" == *"004-beta"* ]]
  [[ "$msg" == *"004-gamma"* ]]
  [ "$(jq -r '.refusals[0].issue_keys | join(",")' <<< "$output")" = "ADO-5" ]
  [[ "$(jq -r '.refusals[0].remediation' <<< "$output")" == *"full-folder label form"* ]]
}

@test "no short-form-labelled ticket means no ambiguity to report" {
  local specs cands
  specs='[{"folder":"004-beta","story_ordinals":[]},{"folder":"004-gamma","story_ordinals":[]}]'
  cands='[{"key":"ADO-5","project_key":"ADO","labels":["speckit-adopt:004-beta"],"parent_key":null,"identity":null}]'
  run classify "${specs}" "${cands}"
  [ "$(jq -r '[.refusals[] | select(.reason == "ambiguous-short-number")] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.bindings[0].issue_key' <<< "$output")" = "ADO-5" ]
}

@test "a unique numbering component still binds through the short form" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003"],"parent_key":null,"identity":null}]'
  run classify "${specs}" "${cands}"
  [ "$(jq -r '.refusals | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.bindings[0].issue_key' <<< "$output")" = "ADO-1" ]
}
