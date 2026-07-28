#!/usr/bin/env bats
# T074 [US2] — Claim refusals (003 FR-011, FR-027, data-model §8, research §4).
#
# Two distinct collisions share one input — the candidate's stored identity
# marker — and must never be conflated:
#
#   already-claimed          the marker names ANOTHER spec,
#   spec-owns-bridge-ticket  the marker names THIS spec with the bridge's own
#                            origin, so the spec already owns a ticket the
#                            bridge created.
#
# A third case is not a refusal at all: THIS spec's marker with origin `human`
# means the ticket is already adopted — skipped, counted as skipped, never
# re-stamped (FR-027), which is what makes an interrupted run resumable.
#
# ⚠️ The bridge-created origin on the wire is HYPHENATED. The spec's prose
# spelling names the concept; renaming the literal would invalidate every marker
# already stamped on a real ticket (research §4). These tests pin the literal.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/engine/adoption.sh"
  PREFIX="speckit-adopt:"
  CFG='{"routing_default":"ADO"}'
  REPO="acme/app"
  ONE_SPEC='[{"folder":"003-alpha","story_ordinals":[]}]'
}

classify() {
  adoption_classify "$(adoption_targets "$1" "${PREFIX}" "${CFG}")" "${2:-[]}" "${3:-[]}" "${REPO}"
}

# candidate <identity-json> — one labelled candidate carrying that marker.
candidate() {
  jq -cn --argjson id "$1" \
    '[{key:"ADO-1", project_key:"ADO", labels:["speckit-adopt:003-alpha"], parent_key:null, identity:$id}]'
}

# --- already-claimed (FR-011) ------------------------------------------------

@test "a marker naming another spec in the same repo refuses with already-claimed" {
  run classify "${ONE_SPEC}" "$(candidate '{"origin":"human","repo":"acme/app","spec_slug":"004-other"}')"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.refusals[0].reason' <<< "$output")" = "already-claimed" ]
}

@test "a marker naming another REPOSITORY also refuses with already-claimed" {
  run classify "${ONE_SPEC}" "$(candidate '{"origin":"human","repo":"other/repo","spec_slug":"003-alpha"}')"
  [ "$(jq -r '.refusals[0].reason' <<< "$output")" = "already-claimed" ]
}

@test "the already-claimed message names the spec, the ticket, and the claiming spec" {
  run classify "${ONE_SPEC}" "$(candidate '{"origin":"human","repo":"acme/app","spec_slug":"004-other"}')"
  local msg
  msg="$(jq -r '.refusals[0].message' <<< "$output")"
  [[ "$msg" == *"003-alpha"* ]]
  [[ "$msg" == *"ADO-1"* ]]
  [[ "$msg" == *"acme/app/004-other"* ]]
  [ "$(jq -r '.refusals[0].issue_keys | join(",")' <<< "$output")" = "ADO-1" ]
  [ -n "$(jq -r '.refusals[0].remediation' <<< "$output")" ]
}

# --- spec-owns-bridge-ticket (FR-011, research §4) ---------------------------

@test "this spec's marker with the bridge origin refuses with spec-owns-bridge-ticket" {
  run classify "${ONE_SPEC}" "$(candidate '{"origin":"bridge-created","repo":"acme/app","spec_slug":"003-alpha"}')"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.refusals[0].reason' <<< "$output")" = "spec-owns-bridge-ticket" ]
}

@test "the wire origin is the HYPHENATED literal, not the spec's prose spelling" {
  # The underscore spelling must NOT trigger the class: it is not what any real
  # ticket carries, and treating it as bridge-created would refuse a legitimate
  # adoption.
  [ "${ADOPTION_ORIGIN_BRIDGE}" = "bridge-created" ]
  run classify "${ONE_SPEC}" "$(candidate '{"origin":"bridge_created","repo":"acme/app","spec_slug":"003-alpha"}')"
  [ "$(jq -r '.refusals | length' <<< "$output")" -eq 0 ]
}

@test "the spec-owns-bridge-ticket message names the spec folder and the ticket" {
  run classify "${ONE_SPEC}" "$(candidate '{"origin":"bridge-created","repo":"acme/app","spec_slug":"003-alpha"}')"
  local msg
  msg="$(jq -r '.refusals[0].message' <<< "$output")"
  [[ "$msg" == *"003-alpha"* ]]
  [[ "$msg" == *"ADO-1"* ]]
  [[ "$(jq -r '.refusals[0].remediation' <<< "$output")" == *"--spec 003-alpha"* ]]
}

# --- already-adopted is NOT a refusal (FR-027) -------------------------------

@test "this spec's marker with origin human is already-adopted, not an error" {
  run classify "${ONE_SPEC}" "$(candidate '{"origin":"human","repo":"acme/app","spec_slug":"003-alpha"}')"
  [ "$(jq -r '.refusals | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.bindings[0].status' <<< "$output")" = "already-adopted" ]
  [ "$(jq -r '.bindings[0].issue_key' <<< "$output")" = "ADO-1" ]
}

@test "an unclaimed candidate binds normally (control)" {
  run classify "${ONE_SPEC}" "$(candidate 'null')"
  [ "$(jq -r '.refusals | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.bindings[0].status' <<< "$output")" = "adopt" ]
}

# --- the claim check applies to every level ----------------------------------

@test "a story candidate is claim-checked exactly like a feature candidate" {
  local specs cands
  specs='[{"folder":"003-alpha","story_ordinals":[1]}]'
  cands='[{"key":"ADO-1","project_key":"ADO","labels":["speckit-adopt:003-alpha"],"parent_key":null,"identity":null},
          {"key":"ADO-2","project_key":"ADO","labels":["speckit-adopt:003-alpha:us1"],"parent_key":"ADO-1",
           "identity":{"origin":"human","repo":"acme/app","spec_slug":"009-someone-else"}}]'
  run classify "${specs}" "${cands}"
  [ "$(jq -r '.bindings | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.refusals[0].reason' <<< "$output")" = "already-claimed" ]
  [ "$(jq -r '.refusals[0].level' <<< "$output")" = "story" ]
}
