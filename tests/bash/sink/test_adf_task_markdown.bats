#!/usr/bin/env bats
# T073 [016, US1] — FR-017/FR-018: the sub-task description renderer must map
# the neutral spans of its description blocks onto ADF marks, exactly as the
# story renderer does, while leaving the bridge-composed metadata bullets as
# plain text. Feature 012 rendered the raw `.title` string into a bare text
# node and never read `.description.blocks` at all.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/adf.sh"
}

# A task whose description blocks carry marked spans (the feature-016 shape).
TASK='{
  "local_id": "3f8a1c02d94b7e65",
  "task_ref": "T014",
  "title": "Implement the parser in `engine/tasks_parse.sh` with **bold**",
  "description": {"blocks": [{"type":"paragraph","spans":[
    {"text":"Implement the parser in ","marks":[]},
    {"text":"engine/tasks_parse.sh","marks":[{"kind":"monospace"}]},
    {"text":" with ","marks":[]},
    {"text":"bold","marks":[{"kind":"bold"}]}
  ]}]},
  "attribution": {"story_ordinal": 1, "source": "tag"},
  "phase": "Phase 3: User Story 1",
  "parallel": true,
  "files": ["engine/tasks_parse.sh"],
  "depends_on": ["T012"],
  "done": false,
  "marker": {"state":"assigned","id":"3f8a1c02d94b7e65","ticket":"","lines":[41]}
}'

@test "the description body renders a monospace span as an ADF code mark" {
  local out body
  out="$(adf_render_task_description "${TASK}")"
  body="$(jq -c '.content[0]' <<< "${out}")"
  [ "$(jq -r '.type' <<< "${body}")" = "paragraph" ]
  [ "$(jq -r '[.content[] | select(.marks[]?.type == "code")][0].text' <<< "${body}")" = "engine/tasks_parse.sh" ]
}

@test "the description body renders a bold span as an ADF strong mark" {
  local out body
  out="$(adf_render_task_description "${TASK}")"
  body="$(jq -c '.content[0]' <<< "${out}")"
  [ "$(jq -r '[.content[] | select(.marks[]?.type == "strong")][0].text' <<< "${body}")" = "bold" ]
}

@test "no Markdown delimiter reaches the rendered sub-task body (SC-001)" {
  local out body_text
  out="$(adf_render_task_description "${TASK}")"
  body_text="$(jq -r '[.content[0].content[].text] | join("")' <<< "${out}")"
  [[ "${body_text}" != *'**'* ]]
  [[ "${body_text}" != *'`'* ]]
}

@test "the renderer reads description.blocks, not the raw title" {
  # Same title, different blocks: the body must follow the BLOCKS.
  local task out
  task="$(jq -c '.description.blocks=[{type:"paragraph",spans:[{text:"FROM THE BLOCKS",marks:[]}]}]' <<< "${TASK}")"
  out="$(adf_render_task_description "${task}")"
  [ "$(jq -r '.content[0].content[0].text' <<< "${out}")" = "FROM THE BLOCKS" ]
}

@test "a link span becomes an ADF link mark carrying its href (FR-006)" {
  local task out
  task="$(jq -c '.description.blocks=[{type:"paragraph",spans:[
    {text:"see ",marks:[]},
    {text:"the guide",marks:[{kind:"link",href:"https://example.invalid/g"}]}]}]' <<< "${TASK}")"
  out="$(adf_render_task_description "${task}")"
  [ "$(jq -r '[.content[0].content[] | select(.marks[]?.type == "link")][0].marks[0].attrs.href' <<< "${out}")" = "https://example.invalid/g" ]
}

@test "bridge-composed metadata bullets stay plain text with no marks (FR-018)" {
  local out bullets
  out="$(adf_render_task_description "${TASK}")"
  bullets="$(jq -c '.content[1]' <<< "${out}")"
  [ "$(jq -r '.type' <<< "${bullets}")" = "bulletList" ]
  [ "$(jq -r '[.content[].content[].content[] | select(has("marks"))] | length' <<< "${bullets}")" = "0" ]
  [[ "$(jq -r '[.content[].content[].content[].text] | join("|")' <<< "${bullets}")" == *"Identifier: T014"* ]]
}

@test "a multi-block description renders every block in order" {
  local task out
  task="$(jq -c '.description.blocks=[
    {type:"paragraph",spans:[{text:"first",marks:[]}]},
    {type:"paragraph",spans:[{text:"second",marks:[]}]}]' <<< "${TASK}")"
  out="$(adf_render_task_description "${task}")"
  [ "$(jq -r '.content[0].content[0].text' <<< "${out}")" = "first" ]
  [ "$(jq -r '.content[1].content[0].text' <<< "${out}")" = "second" ]
  # The metadata bullet list is always last.
  [ "$(jq -r '.content[-1].type' <<< "${out}")" = "bulletList" ]
}

@test "the rendered description is still a valid ADF doc envelope" {
  local out
  out="$(adf_render_task_description "${TASK}")"
  [ "$(jq -r '.type' <<< "${out}")" = "doc" ]
  [ "$(jq -r '.version' <<< "${out}")" = "1" ]
  [ "$(jq -r '.content | type' <<< "${out}")" = "array" ]
}

# --- Cross-port parity --------------------------------------------------------

@test "the PowerShell port renders byte-identical marked task ADF (FR-015)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(adf_render_task_description "${TASK}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/Adf.psm1' -Force
    [Console]::Out.Write((ConvertTo-JiraAdfTaskDescription -TaskJson '${TASK}'))")"
  [ "${b}" = "${p}" ]
}
