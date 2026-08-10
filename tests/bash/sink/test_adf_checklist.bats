#!/usr/bin/env bats
# T024/T026/T026a/T027/T029 [Phase 3, US1, 022] — rendering a story's tasks as
# a checklist (contracts/checklist-rendering.md §1-3). Candidate B: the
# existing bulletList renderer, each entry's first span a state glyph. ADF
# construction lives in SINK (Constitution VIII).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/adf.sh"
}

_content_with_tasks() {
  jq -cn '{
    description: {blocks: []},
    tasks: [
      {title: "Do the first thing", done: false, phase: "Phase 1: Setup", task_ref: "T001", local_id: "t1", files: ["a.sh"], depends_on: [], parallel: true},
      {title: "Do the second thing", done: true, phase: "Phase 1: Setup", task_ref: "T002", local_id: "t2"},
      {title: "Unphased work", done: false, phase: null, task_ref: "T003", local_id: "t3"},
      {title: "Phase two item", done: false, phase: "Phase 2: Story", task_ref: "T004", local_id: "t4"}
    ]
  }'
}

@test "structure: one Tasks heading, one group per phase in first-appearance order, no-phase group leads" {
  local nodes; nodes="$(_adf_checklist_nodes "$(_content_with_tasks)")"
  [ "$(jq -r '.[0].type' <<< "${nodes}")" = "heading" ]
  [ "$(jq -r '.[0].content[0].text' <<< "${nodes}")" = "Tasks" ]
  # groups: [heading, bulletList(no-phase), paragraph(Phase1), bulletList(Phase1), paragraph(Phase2), bulletList(Phase2)]
  [ "$(jq -r '.[1].type' <<< "${nodes}")" = "bulletList" ]
  [ "$(jq -r '.[1].content | length' <<< "${nodes}")" -eq 1 ]
  [ "$(jq -r '.[2].type' <<< "${nodes}")" = "paragraph" ]
  [ "$(jq -r '.[2].content[0].text' <<< "${nodes}")" = "Phase 1: Setup" ]
  [ "$(jq -r '.[3].type' <<< "${nodes}")" = "bulletList" ]
  [ "$(jq -r '.[3].content | length' <<< "${nodes}")" -eq 2 ]
  [ "$(jq -r '.[4].content[0].text' <<< "${nodes}")" = "Phase 2: Story" ]
  [ "$(jq -r '.[5].content | length' <<< "${nodes}")" -eq 1 ]
  [ "$(jq -r 'length' <<< "${nodes}")" -eq 6 ]
}

@test "the no-phase group carries no phase paragraph" {
  local nodes; nodes="$(_adf_checklist_nodes "$(_content_with_tasks)")"
  local texts; texts="$(jq -r '[.[] | select(.type=="paragraph") | .content[0].text]' <<< "${nodes}")"
  [[ "${texts}" != *"null"* ]]
}

@test "a story with zero attributed tasks renders no section at all (FR-021)" {
  local nodes; nodes="$(_adf_checklist_nodes '{"description":{"blocks":[]},"tasks":[]}')"
  [ "${nodes}" = "[]" ]
  nodes="$(_adf_checklist_nodes '{"description":{"blocks":[]}}')"
  [ "${nodes}" = "[]" ]
}

@test "two stories holding tasks whose text is identical each render their own entry, never deduplicated" {
  local content_a content_b nodes_a nodes_b
  content_a="$(jq -cn '{description:{blocks:[]}, tasks:[{title:"Same text", done:false, phase:null}]}')"
  content_b="$(jq -cn '{description:{blocks:[]}, tasks:[{title:"Same text", done:false, phase:null}]}')"
  nodes_a="$(_adf_checklist_nodes "${content_a}")"
  nodes_b="$(_adf_checklist_nodes "${content_b}")"
  [ "${nodes_a}" = "${nodes_b}" ]
  [ "$(jq -r '.[1].content | length' <<< "${nodes_a}")" -eq 1 ]
}

@test "an entry carries none of task_ref, local_id, files, depends_on, parallel or the phase text (FR-017)" {
  local nodes; nodes="$(_adf_checklist_nodes "$(_content_with_tasks)")"
  local all; all="$(jq -c . <<< "${nodes}")"
  [[ "${all}" != *"T001"* ]]
  [[ "${all}" != *"t1"* ]]
  [[ "${all}" != *"a.sh"* ]]
  [[ "${all}" != *"local_id"* ]]
  [[ "${all}" != *"depends_on"* ]]
  [[ "${all}" != *"parallel"* ]]
}

@test "an entry's text renders the Markdown subset exactly as a sub-task description body does for the same line (FR-023)" {
  local content nodes entry_spans
  content="$(jq -cn '{description:{blocks:[]}, tasks:[{title:"A **bold** word", done:false, phase:null}]}')"
  nodes="$(_adf_checklist_nodes "${content}")"
  entry_spans="$(jq -c '.[1].content[0].content[0].content' <<< "${nodes}")"
  # the glyph text node, then a plain "A " text, then a strong "bold" text
  [ "$(jq -r '.[0].text' <<< "${entry_spans}")" = "☐ " ]
  [[ "$(jq -c . <<< "${entry_spans}")" == *'"marks":[{"type":"strong"}]'* ]]
  [[ "$(jq -c . <<< "${entry_spans}")" == *'"text":"bold"'* ]]
}

@test "done: true renders complete, done: false renders incomplete (FR-025)" {
  local nodes; nodes="$(_adf_checklist_nodes "$(_content_with_tasks)")"
  # T001 (index 0 within no-phase bucket is actually T003 unphased; check phase-1 group at index 3)
  local phase1_glyphs; phase1_glyphs="$(jq -c '[.[3].content[].content[0].content[0].text]' <<< "${nodes}")"
  [ "$(jq -r '.[0]' <<< "${phase1_glyphs}")" = "☐ " ]
  [ "$(jq -r '.[1]' <<< "${phase1_glyphs}")" = "☑ " ]
}

@test "no entry or checklist node carries an identity attribute" {
  local nodes; nodes="$(_adf_checklist_nodes "$(_content_with_tasks)")"
  [[ "$(jq -c . <<< "${nodes}")" != *"localId"* ]]
}
