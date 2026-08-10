#!/usr/bin/env bats
# T031/T035/T035a [Phase 3, US1, 022] — plan_writes in checklist mode:
# plan_writes_tasks is never consulted (that gate lives in reconcile.sh —
# this file proves the DESCRIPTION side), the checklist rides the story's
# description field, and the FR-041 size ceiling withholds one field only.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  MARKER="$(adf_managed_marker)"
}

DOC_WITH_TASKS='{
  "routing": {"project_key":"COMP"},
  "epic": {"title":"The Epic", "local_id":"3f2a91c04b7e6d18",
    "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
    "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},
  "stories": [
    {"local_id":"s1","title":"A story","description":{"blocks":[]},
     "tasks":[{"title":"Do a thing","done":false,"phase":"Phase 1"}]}
  ]
}'

@test "checklist mode: the story's planned description carries the Tasks section, no sub-task action exists to plan (FR-007)" {
  local ctx='{
    "base_url":"https://mock", "story_type_id":"10002", "parent_type_id":"10101",
    "parent_local_id":"3f2a91c04b7e6d18", "priority_ids":{}, "task_mirror":"checklist"
  }'
  run plan_writes "${DOC_WITH_TASKS}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].method' <<< "$output")" = "POST" ]
  local content; content="$(jq -c '.stories[0].body.fields.description.content' <<< "$output")"
  [[ "$(jq -c . <<< "${content}")" == *'"text":"Tasks"'* ]]
  [[ "$(jq -c . <<< "${content}")" == *'"Do a thing"'* ]]
}

@test "subtask mode (or unrecorded): no Tasks section rendered, byte-for-byte identical to before this feature" {
  local ctx='{
    "base_url":"https://mock", "story_type_id":"10002", "parent_type_id":"10101",
    "parent_local_id":"3f2a91c04b7e6d18", "priority_ids":{}
  }'
  run plan_writes "${DOC_WITH_TASKS}" "${ctx}"
  [ "$status" -eq 0 ]
  local content; content="$(jq -c '.stories[0].body.fields.description.content' <<< "$output")"
  [[ "$(jq -c . <<< "${content}")" != *'"text":"Tasks"'* ]]
}

@test "FR-041: a checklist pushing the description past the ceiling withholds that one field, names the story, and every other field still writes" {
  # The 2000-task list is ~200 KB, so it must never cross argv: Linux caps a
  # SINGLE argument at MAX_ARG_STRLEN (128 KiB) and macOS has no per-argument
  # cap at all, so `--argjson t "${many_tasks}"` execs fine here and dies with
  # E2BIG on the runner. Generate it inside the same jq program instead — see
  # tests/bash/commands/test_reconcile_large_spec.bats for the same hazard.
  local big_doc; big_doc="$(jq -c '.stories[0].tasks = [range(0;2000) | {title: ("A task with a fairly long title to pad the payload out " + (.|tostring)), done: false, phase: "Phase 1"}]' <<< "${DOC_WITH_TASKS}")"
  local ctx='{
    "base_url":"https://mock", "story_type_id":"10002", "parent_type_id":"10101",
    "parent_local_id":"3f2a91c04b7e6d18", "priority_ids":{"P1":"1"}, "task_mirror":"checklist"
  }'
  big_doc="$(jq -c '.stories[0].priority_logical = "P1"' <<< "${big_doc}")"
  run plan_writes "${big_doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields | has("description")' <<< "$output")" = "false" ]
  [ "$(jq -r '.stories[0].body.fields.priority.id' <<< "$output")" = "1" ]
  [[ "$(jq -r '.warnings | join("\n")' <<< "$output")" == *"A story"* ]]
}

@test "a description carrying human prose above the boundary keeps it byte-for-byte when Tasks is appended below" {
  local prefix managed existing
  prefix="$(jq -cn '[{type:"paragraph", content:[{type:"text", text:"A note the PO wrote."}]}]')"
  managed="$(jq -cn --arg m "${MARKER}" '[{type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}, {type:"paragraph", content:[{type:"text", text:"OLD BODY"}]}]')"
  existing="$(jq -cn --argjson p "${prefix}" --argjson m "${managed}" '{type:"doc", version:1, content: ($p + $m)}')"
  local ctx; ctx="$(jq -cn --argjson e "${existing}" '{
    base_url:"https://mock", story_type_id:"10002", parent_type_id:"10101",
    parent_local_id:"3f2a91c04b7e6d18", priority_ids:{}, task_mirror:"checklist",
    tickets:{s1:"COMP-9"}, ticket_descriptions:{s1:$e}, ticket_origins:{s1:"bridge"}
  }')"
  run plan_writes "${DOC_WITH_TASKS}" "${ctx}"
  [ "$status" -eq 0 ]
  local content; content="$(jq -c '.stories[0].body.fields.description.content' <<< "$output")"
  [ "$(jq -r '.[0].content[0].text' <<< "${content}")" = "A note the PO wrote." ]
  [[ "$(jq -c . <<< "${content}")" == *'"text":"Tasks"'* ]]
}

@test "a description carrying two boundary markers omits the description field entirely, every other field still writes" {
  local managed_twice
  managed_twice="$(jq -cn --arg m "${MARKER}" '[
    {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
    {type:"paragraph", content:[{type:"text", text:"body one"}]},
    {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
    {type:"paragraph", content:[{type:"text", text:"body two"}]}
  ]')"
  local existing; existing="$(jq -cn --argjson m "${managed_twice}" '{type:"doc", version:1, content: $m}')"
  local ctx; ctx="$(jq -cn --argjson e "${existing}" '{
    base_url:"https://mock", story_type_id:"10002", parent_type_id:"10101",
    parent_local_id:"3f2a91c04b7e6d18", priority_ids:{"P1":"1"}, task_mirror:"checklist",
    tickets:{s1:"COMP-9"}, ticket_descriptions:{s1:$e}, ticket_origins:{s1:"bridge"}
  }')"
  local doc; doc="$(jq -c '.stories[0].priority_logical = "P1"' <<< "${DOC_WITH_TASKS}")"
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields | has("description")' <<< "$output")" = "false" ]
  [ "$(jq -r '.stories[0].body.fields.priority.id' <<< "$output")" = "1" ]
  [[ "$(jq -r '.warnings | join("\n")' <<< "$output")" == *"COMP-9"* ]]
}

@test "T034a: checklist counts across create, update, and unchanged runs (FR-036, data-model.md §4)" {
  local doc_done_true; doc_done_true="$(jq -c '.stories[0].tasks[0].done = true' <<< "${DOC_WITH_TASKS}")"
  local ctx_create='{
    "base_url":"https://mock", "story_type_id":"10002", "parent_type_id":"10101",
    "parent_local_id":"3f2a91c04b7e6d18", "priority_ids":{}, "task_mirror":"checklist"
  }'
  run plan_writes "${doc_done_true}" "${ctx_create}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.checklist_counts.created' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.checklist_counts.entries_completed' <<< "$output")" -eq 0 ]

  # Now simulate the SAME story existing, with a checklist already on the
  # ticket showing the task incomplete — then change text and check the box.
  local existing; existing="$(jq -cn --arg m "${MARKER}" '{
    type:"doc", version:1,
    content: [
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"heading", attrs:{level:3}, content:[{type:"text", text:"Tasks"}]},
      {type:"bulletList", content:[
        {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:"☐ "},{type:"text", text:"An old title"}]}]}
      ]}
    ]
  }')"
  local ctx_update; ctx_update="$(jq -cn --argjson e "${existing}" '{
    base_url:"https://mock", story_type_id:"10002", parent_type_id:"10101",
    parent_local_id:"3f2a91c04b7e6d18", priority_ids:{}, task_mirror:"checklist",
    tickets:{s1:"COMP-9"}, ticket_descriptions:{s1:$e}, ticket_origins:{s1:"bridge"}
  }')"
  run plan_writes "${doc_done_true}" "${ctx_update}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.checklist_counts.updated' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.checklist_counts.entries_completed' <<< "$output")" -eq 1 ]

  # Third run: the existing ticket already matches the desired checklist
  # exactly (done:true, "Do a thing") — rendered through the SAME path
  # rather than hand-typed, so the fixture cannot drift from the real shape.
  local existing2; existing2="$(jq -c '.doc' <<< "$(adf_render_managed_description "$(jq -c '.stories[0]' <<< "${doc_done_true}")" "" "" "checklist")")"
  local ctx_unchanged; ctx_unchanged="$(jq -cn --argjson e "${existing2}" '{
    base_url:"https://mock", story_type_id:"10002", parent_type_id:"10101",
    parent_local_id:"3f2a91c04b7e6d18", priority_ids:{}, task_mirror:"checklist",
    tickets:{s1:"COMP-9"}, ticket_descriptions:{s1:$e}, ticket_origins:{s1:"bridge"}
  }')"
  run plan_writes "${doc_done_true}" "${ctx_unchanged}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.checklist_counts.unchanged' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.checklist_counts.entries_completed' <<< "$output")" -eq 0 ]
}
