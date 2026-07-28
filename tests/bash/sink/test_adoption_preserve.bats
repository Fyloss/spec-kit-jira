#!/usr/bin/env bats
# T104 [US3] — Human-content preservation after adoption (003 FR-016, FR-018,
# SC-002, SC-006).
#
# US3 is mostly PROOF, not new code: stamping origin `human` is what SELECTS the
# managed-panel splice and the managed-section-only churn diff that the write path
# has implemented since 001 US7. These tests prove that selection end to end from
# the adoption side, so a future change to either half cannot silently break the
# promise that makes adoption acceptable to a Product Owner.
#
# Two precise claims, because the loose one would be wrong:
#
#   1. On an update, every pre-existing human byte survives VERBATIM, above the
#      marker — the panel is ADDED below it, never a rewrite.
#   2. When the managed section is unchanged, the update is DROPPED ENTIRELY, so
#      no write payload carrying the human prose exists at all.
#
# And the origin is permanent: no later run rewrites `human` back to anything.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SINK="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK}/adoption.sh"
  # shellcheck source=/dev/null
  source "${SINK}/plan_apply.sh"
  # shellcheck source=/dev/null
  source "${SINK}/adf.sh"

  MARKER="$(adf_managed_marker)"
  HUMAN_TEXT="PO handwritten note — do not lose this."
  # A ticket a human wrote, with no managed panel yet: exactly what a freshly
  # adopted ticket looks like.
  EXISTING="$(jq -cn --arg t "${HUMAN_TEXT}" '
    {type:"doc", version:1, content:[
      {type:"paragraph", content:[{type:"text", text:$t}]}]}')"
  DOC='{"stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2",
        "description":{"blocks":[{"type":"paragraph","text":"Managed body."}]}}]}'
}

# plan_ctx <origin> [existing] — the reconcile plan context for an existing ticket.
plan_ctx() {
  jq -cn --arg o "${1}" --argjson e "${2:-null}" '
    {base_url:"http://h", tickets:{s1:"ADO-1"}, ticket_origins:{s1:$o}}
    + (if $e == null then {} else {ticket_descriptions:{s1:$e}} end)'
}

# --- (1) the panel is ADDED below the human prose, never a rewrite -----------

@test "an adopted ticket's human prose survives verbatim, above the marker (SC-002)" {
  local actions desc
  actions="$(plan_writes "${DOC}" "$(plan_ctx human "${EXISTING}")")"
  desc="$(jq -c '.[0].body.fields.description' <<< "${actions}")"

  # Every pre-existing byte is still there …
  [[ "$(jq -r '[.. | .text? // empty] | join(" ")' <<< "${desc}")" == *"${HUMAN_TEXT}"* ]]
  # … and it sits ABOVE the marker, with the managed body below it.
  local order
  order="$(jq -r '[.content[] | [.. | .text? // empty] | join("")] | join("|")' <<< "${desc}")"
  [[ "${order}" == "${HUMAN_TEXT}|"* ]]
  local human_at marker_at managed_at
  human_at="$(jq -r --arg t "${HUMAN_TEXT}" '[.content[] | ([.. | .text? // empty] | join(""))] | index($t)' <<< "${desc}")"
  marker_at="$(jq -r --arg m "${MARKER}" '[.content[] | ([.. | .text? // empty] | join(""))] | index($m)' <<< "${desc}")"
  managed_at="$(jq -r '[.content[] | ([.. | .text? // empty] | join(""))] | index("Managed body.")' <<< "${desc}")"
  [ "${human_at}" -lt "${marker_at}" ]
  [ "${marker_at}" -lt "${managed_at}" ]
}

@test "a bridge-created ticket is NOT spliced — the whole description is managed" {
  # The contrast that shows the origin is what selects the behaviour.
  local desc
  desc="$(adf_render_managed_description "$(jq -c '.stories[0]' <<< "${DOC}")" "bridge-created" "${EXISTING}")"
  [[ "$(jq -r '[.. | .text? // empty] | join(" ")' <<< "${desc}")" != *"${HUMAN_TEXT}"* ]]
  [[ "$(jq -r '[.. | .text? // empty] | join(" ")' <<< "${desc}")" != *"${MARKER}"* ]]
}

# --- (2) the churn diff is on the managed section ALONE (FR-039) -------------

@test "plan_managed_description_status compares the managed panel alone" {
  local first second edited
  first="$(adf_render_managed_description "$(jq -c '.stories[0]' <<< "${DOC}")" "human" "${EXISTING}")"
  # The human edits their own prose above the panel; the managed part is identical.
  edited="$(jq -c --arg t "The PO rewrote this line entirely." \
    '.content[0].content[0].text = $t' <<< "${first}")"
  second="$(adf_render_managed_description "$(jq -c '.stories[0]' <<< "${DOC}")" "human" "${edited}")"
  [ "$(plan_managed_description_status "${edited}" "${second}")" = "unchanged" ]
}

@test "a change INSIDE the managed panel is still detected as churn" {
  local first changed_doc second
  first="$(adf_render_managed_description "$(jq -c '.stories[0]' <<< "${DOC}")" "human" "${EXISTING}")"
  changed_doc='{"local_id":"s1","title":"Story One","priority_logical":"P2",
    "description":{"blocks":[{"type":"paragraph","text":"A DIFFERENT managed body."}]}}'
  second="$(adf_render_managed_description "${changed_doc}" "human" "${first}")"
  [ "$(plan_managed_description_status "${first}" "${second}")" = "changed" ]
}

@test "an unchanged managed section drops the update, so NO payload carries the prose" {
  # This is the strongest form of the promise: on a second reconcile the human's
  # bytes are not merely preserved — they never leave the repository at all.
  local first current lc kept
  first="$(adf_render_managed_description "$(jq -c '.stories[0]' <<< "${DOC}")" "human" "${EXISTING}")"
  current="$(jq -cn --argjson d "${first}" '{summary:"Story One", description:$d}')"
  local actions
  actions="$(plan_writes "${DOC}" "$(plan_ctx human "${first}")")"
  lc="$(jq -cn --argjson c "${current}" '
    {base_url:"http://h", order:[],
     tickets:{s1:{key:"ADO-1", origin:"human", current:$c}}}')"
  kept="$(plan_lifecycle "${actions}" "${DOC}" "${lc}" | jq -c '.actions')"
  [ "$(jq 'length' <<< "${kept}")" -eq 0 ]
  [[ "${kept}" != *"PO handwritten"* ]]
}

# --- (3) the origin is permanent (FR-016) ------------------------------------

@test "an adoption stamp records origin human, and nothing rewrites it" {
  local bindings actions
  bindings='[{"spec_folder":"003-a","level":"feature","story_ordinal":null,"issue_key":"ADO-1",
              "reason":"label-match","overrode_key":null,"status":"adopt"}]'
  actions="$(adopt_stamp_actions "${bindings}" "acme/app")"
  [ "$(jq -r '.[0].body.origin' <<< "${actions}")" = "human" ]

  # A later reconcile of the same ticket emits NO identity write at all, so the
  # origin it carries is the one adoption stamped — permanently.
  local reconcile_actions
  reconcile_actions="$(plan_writes "${DOC}" "$(plan_ctx human "${EXISTING}")")"
  [ "$(jq '[.[] | select(.url | test("/properties/"))] | length' <<< "${reconcile_actions}")" -eq 0 ]
}

@test "the human origin keeps selecting the splice on every later run" {
  # Idempotence of the selection itself: rendering twice from the previous
  # output converges, so the panel is never duplicated and the prose never drifts.
  local first second third
  first="$(adf_render_managed_description "$(jq -c '.stories[0]' <<< "${DOC}")" "human" "${EXISTING}")"
  second="$(adf_render_managed_description "$(jq -c '.stories[0]' <<< "${DOC}")" "human" "${first}")"
  third="$(adf_render_managed_description "$(jq -c '.stories[0]' <<< "${DOC}")" "human" "${second}")"
  [ "${second}" = "${third}" ]
  # Exactly one marker, however many times it is rendered.
  [ "$(jq -r --arg m "${MARKER}" '[.content[] | select(([.. | .text? // empty] | join("")) == $m)] | length' <<< "${third}")" -eq 1 ]
}
