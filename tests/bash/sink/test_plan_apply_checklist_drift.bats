#!/usr/bin/env bats
# T056/T058/T059/T062 [Phase 4, US2, 022] — the checklist drift decision
# (contracts/checklist-rendering.md §6): a three-way digest comparison
# (current on the ticket, recorded in the identity property, desired now)
# decides whether a human's edit is reported before the checklist is
# rewritten. Completing an entry never transitions any issue's status
# (FR-029) — checklist mode has no status-transition code path at all.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  MARKER="$(adf_managed_marker)"
}

DOC='{
  "routing": {"project_key":"COMP"},
  "epic": {"title":"The Epic", "local_id":"3f2a91c04b7e6d18",
    "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
    "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},
  "stories": [
    {"local_id":"s1","title":"A story","description":{"blocks":[]},
     "tasks":[{"title":"Do a thing","done":true,"phase":null}]}
  ]
}'

_existing_with_checklist() {
  # An existing description whose managed region already carries a Tasks
  # checklist with the given glyph — built in the EXACT node shape the sink
  # emits (a separate glyph text node ahead of the title's own, contract §3),
  # so its digest is comparable to one computed from a freshly rendered story.
  local glyph="$1"
  jq -cn --arg m "${MARKER}" --arg g "${glyph}" '{
    type:"doc", version:1,
    content: [
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"heading", attrs:{level:3}, content:[{type:"text", text:"Tasks"}]},
      {type:"bulletList", content:[
        {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:$g},{type:"text", text:"Do a thing"}]}]}
      ]}
    ]
  }'
}

_ctx_for() {
  local existing="$1" recorded_digest="$2"
  jq -cn --argjson e "${existing}" --arg rd "${recorded_digest}" '{
    base_url:"https://mock", story_type_id:"10002", parent_type_id:"10101",
    parent_local_id:"3f2a91c04b7e6d18", priority_ids:{}, task_mirror:"checklist",
    tickets:{s1:"COMP-9"}, ticket_descriptions:{s1:$e}, ticket_origins:{s1:"bridge"}
  } + (if $rd == "" then {} else {ticket_last_checklists:{s1:$rd}} end)'
}

@test "no record means no warning — first write over any existing content" {
  local existing; existing="$(_existing_with_checklist "☐ ")"
  local ctx; ctx="$(_ctx_for "${existing}" "")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 0 ]
}

@test "current matches recorded: writes silently, nobody intervened" {
  local existing; existing="$(_existing_with_checklist "☑ ")"
  local existing_managed; existing_managed="$(jq -c '.content' <<< "${existing}" | managed_section_panel_split "${MARKER}" | jq -c '.managed')"
  local current_nodes; current_nodes="$(_adf_checklist_slice "${existing_managed}")"
  local recorded; recorded="$(_adf_checklist_nodes_digest "${current_nodes}")"
  local ctx; ctx="$(_ctx_for "${existing}" "${recorded}")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 0 ]
}

@test "current diverges from recorded but already matches desired — not drift, no warning" {
  # A person already ticked the box in Jira to match tasks.md (done:true).
  local existing; existing="$(_existing_with_checklist "☑ ")"
  # Recorded digest is for the OLD (unticked) state — different from current.
  local old_existing; old_existing="$(_existing_with_checklist "☐ ")"
  local old_managed; old_managed="$(jq -c '.content' <<< "${old_existing}" | managed_section_panel_split "${MARKER}" | jq -c '.managed')"
  local old_nodes; old_nodes="$(_adf_checklist_slice "${old_managed}")"
  local recorded; recorded="$(_adf_checklist_nodes_digest "${old_nodes}")"
  local ctx; ctx="$(_ctx_for "${existing}" "${recorded}")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 0 ]
}

@test "genuine drift: current diverges from both recorded and desired — one named warning, before the rewrite" {
  # tasks.md says done:true (desired = ☑); ticket currently shows ☐ (a
  # human unticked it); recorded digest is for a THIRD state (reworded).
  local existing; existing="$(_existing_with_checklist "☐ ")"
  local reworded; reworded="$(jq -cn --arg m "${MARKER}" '{
    type:"doc", version:1,
    content: [
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"heading", attrs:{level:3}, content:[{type:"text", text:"Tasks"}]},
      {type:"bulletList", content:[
        {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:"☑ Do a thing (reworded)"}]}]}
      ]}
    ]
  }')"
  local reworded_managed; reworded_managed="$(jq -c '.content' <<< "${reworded}" | managed_section_panel_split "${MARKER}" | jq -c '.managed')"
  local reworded_nodes; reworded_nodes="$(_adf_checklist_slice "${reworded_managed}")"
  local recorded; recorded="$(_adf_checklist_nodes_digest "${reworded_nodes}")"
  local ctx; ctx="$(_ctx_for "${existing}" "${recorded}")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 1 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"COMP-9"* ]]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"checklist"* ]]
  # Rewritten from tasks.md regardless (FR-026) — the entry is complete.
  [[ "$(jq -c '.stories[0].body.fields.description.content' <<< "$output")" == *'"☑ "'* ]]
}

@test "completing an entry never transitions any issue's status (FR-029) — no transition action exists" {
  local existing; existing="$(_existing_with_checklist "☐ ")"
  local ctx; ctx="$(_ctx_for "${existing}" "")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].method' <<< "$output")" = "PUT" ]
  [[ "$(jq -r '.stories[0].url' <<< "$output")" != *"/transitions"* ]]
}
