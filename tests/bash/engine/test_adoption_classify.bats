#!/usr/bin/env bats
# T072 [US2] — Candidate-count refusals (003 FR-009, FR-010, data-model §8).
#
# Zero candidates and several candidates are the two ways a label fails to name
# exactly one ticket. Both refuse THAT binding with zero writes, and both carry a
# message naming the spec folder plus a copy-pasteable remediation. The
# several-candidates message names EVERY candidate — never a truncated pair —
# which is why discovery has to paginate to exhaustion.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/engine/adoption.sh"
  PREFIX="speckit-adopt:"
  CFG='{"routing_default":"ADO"}'
  REPO="acme/app"
}

targets() {
  adoption_targets "$1" "${PREFIX}" "${CFG}"
}

classify() {
  adoption_classify "$(targets "$1")" "${2:-[]}" "${3:-[]}" "${REPO}"
}

# A feature-only spec, so the assertions stay about the class under test.
ONE_SPEC='[{"folder":"003-alpha","story_ordinals":[]}]'

# --- no-candidate (FR-009) ---------------------------------------------------

@test "zero accessible tickets refuse with no-candidate and zero bindings" {
  run classify "${ONE_SPEC}" '[]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.refusals | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.refusals[0].reason' <<< "$output")" = "no-candidate" ]
}

@test "the no-candidate message names the spec folder and the EXACT labels searched" {
  run classify "${ONE_SPEC}" '[]'
  local msg
  msg="$(jq -r '.refusals[0].message' <<< "$output")"
  [[ "$msg" == *"003-alpha"* ]]
  [[ "$msg" == *"speckit-adopt:003-alpha"* ]]
  [[ "$msg" == *"speckit-adopt:003"* ]]
  [[ "$msg" == *"searched"* ]]
}

@test "the no-candidate remediation is a copy-pasteable --bind command" {
  run classify "${ONE_SPEC}" '[]'
  local rem
  rem="$(jq -r '.refusals[0].remediation' <<< "$output")"
  [[ "$rem" == *"spec-kit-jira adopt --bind 003-alpha=<ISSUE-KEY>"* ]]
}

@test "no-candidate carries an EMPTY issue_keys array, not a null" {
  run classify "${ONE_SPEC}" '[]'
  [ "$(jq -c '.refusals[0].issue_keys' <<< "$output")" = "[]" ]
}

@test "a story target names its ordinal in the refusal" {
  run classify '[{"folder":"003-alpha","story_ordinals":[2]}]' '[]'
  local msg
  msg="$(jq -r '.refusals[] | select(.level=="story") | .message' <<< "$output")"
  [[ "$msg" == *"003-alpha:us2"* ]]
  [ "$(jq -r '.refusals[] | select(.level=="story") | .story_ordinal' <<< "$output")" = "2" ]
}

# --- several-candidates (FR-010) ---------------------------------------------

@test "more than one candidate refuses with several-candidates" {
  local cands
  cands='[{"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-9","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'
  run classify "${ONE_SPEC}" "${cands}"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.refusals[0].reason' <<< "$output")" = "several-candidates" ]
}

@test "several-candidates names EVERY candidate, never a truncated pair (NFR-6)" {
  local cands='[]' i
  for i in 1 2 3 4 5; do
    cands="$(jq -c --arg k "ADO-${i}" \
      '. + [{key:$k, project_key:"ADO", labels:["speckit-adopt:003-alpha"], parent_key:null, identity:null}]' <<< "${cands}")"
  done
  run classify "${ONE_SPEC}" "${cands}"
  [ "$(jq -r '.refusals[0].issue_keys | length' <<< "$output")" -eq 5 ]
  local msg
  msg="$(jq -r '.refusals[0].message' <<< "$output")"
  for i in 1 2 3 4 5; do
    [[ "$msg" == *"ADO-${i}"* ]]
  done
}

@test "several-candidates lists the keys in a stable ascending order across ports" {
  local cands
  cands='[{"key":"ADO-9","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-11","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'
  run classify "${ONE_SPEC}" "${cands}"
  # Codepoint order, which is what both ports sort by.
  [ "$(jq -r '.refusals[0].issue_keys | join(",")' <<< "$output")" = "ADO-11,ADO-2,ADO-9" ]
}

@test "the several-candidates remediation names one of the real candidates" {
  local cands
  cands='[{"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-9","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'
  run classify "${ONE_SPEC}" "${cands}"
  [ "$(jq -r '.refusals[0].remediation' <<< "$output")" = "spec-kit-jira adopt --bind 003-alpha=ADO-2" ]
}

# --- a refusal never stops an unambiguous binding (FR-013) -------------------

@test "an unambiguous binding still applies alongside a refusal in the same run" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[]},{"folder":"004-beta","story_ordinals":[]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-8","project_key":"ADO","labels":["speckit-adopt:004-beta"],"parent_key":null,"identity":null},
          {"key":"ADO-9","project_key":"ADO","labels":["speckit-adopt:004-beta"],"parent_key":null,"identity":null}]'
  run classify "${specs}" "${cands}"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.bindings[0].issue_key' <<< "$output")" = "ADO-1" ]
  [ "$(jq -r '.refusals | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.refusals[0].spec_folder' <<< "$output")" = "004-beta" ]
}

@test "bindings and refusals follow the target order (data-model §7.3)" {
  local specs cands
  specs='[{"folder":"005-gamma","story_ordinals":[]},{"folder":"003-alpha","story_ordinals":[]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-5","project_key":"ADO","labels":["speckit-adopt:005-gamma"],"parent_key":null,"identity":null}]'
  run classify "${specs}" "${cands}"
  [ "$(jq -r '[.bindings[].spec_folder] | join(",")' <<< "$output")" = "003-alpha,005-gamma" ]
}

@test "the classification is deterministic — identical input, identical bytes" {
  local cands
  cands='[{"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-9","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null}]'
  local a b
  a="$(classify "${ONE_SPEC}" "${cands}")"
  b="$(classify "${ONE_SPEC}" "${cands}")"
  [ "$a" = "$b" ]
}
