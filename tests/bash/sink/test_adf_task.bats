#!/usr/bin/env bats
# T032 [US1] — Task summary/description rendering (contracts/task-tier.md §4).
# The summary is the task's own text with the marker and file-only markup
# removed; an over-long text is shortened deterministically with the
# untruncated text present in the description; the description carries
# identifier, phase, attribution, parallel-safety, files, dependencies and
# continuation lines, and restates neither the story nor the specification.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/adf.sh"
}

TASK='{
  "local_id": "3f8a1c02d94b7e65",
  "task_ref": "T014",
  "title": "Implement the neutral task parser in scripts/bash/engine/tasks_parse.sh",
  "description": {"blocks": [{"type":"paragraph","text":"Implement the neutral task parser"}]},
  "attribution": {"story_ordinal": 1, "source": "tag"},
  "phase": "Phase 3: User Story 1",
  "parallel": true,
  "files": ["scripts/bash/engine/tasks_parse.sh"],
  "depends_on": ["T012"],
  "done": false,
  "marker": {"state":"assigned","id":"3f8a1c02d94b7e65","ticket":"","lines":[41]}
}'

@test "a short title passes through the summary unchanged" {
  run adf_task_summary "Short title"
  [ "$output" = "Short title" ]
}

@test "an over-long title is shortened deterministically" {
  local long a b
  long="$(printf 'x%.0s' {1..400})"
  a="$(adf_task_summary "${long}")"
  b="$(adf_task_summary "${long}")"
  [ "${a}" = "${b}" ]
  [ "${#a}" -eq 255 ]
  [[ "${a}" == *"…" ]]
}

@test "a title within the limit is returned byte-for-byte" {
  local exact; exact="$(printf 'x%.0s' {1..255})"
  run adf_task_summary "${exact}"
  [ "$output" = "${exact}" ]
}

@test "description carries the identifier" {
  run adf_render_task_description "${TASK}"
  [[ "$output" == *"Identifier: T014"* ]]
}

@test "description carries the phase" {
  run adf_render_task_description "${TASK}"
  [[ "$output" == *"Phase 3: User Story 1"* ]]
}

@test "description carries the attribution" {
  run adf_render_task_description "${TASK}"
  [[ "$output" == *"User Story 1"* ]]
}

@test "description carries parallel-safety" {
  run adf_render_task_description "${TASK}"
  [[ "$output" == *"Parallel-safe: yes"* ]]
}

@test "description carries files" {
  run adf_render_task_description "${TASK}"
  [[ "$output" == *"scripts/bash/engine/tasks_parse.sh"* ]]
}

@test "description carries dependencies" {
  run adf_render_task_description "${TASK}"
  [[ "$output" == *"Depends on: T012"* ]]
}

@test "description carries the full untruncated text even when the summary is shortened" {
  local long task
  long="$(printf 'x%.0s' {1..400})"
  task="$(jq -c --arg t "${long}" '.title=$t' <<< "${TASK}")"
  run adf_render_task_description "${task}"
  [[ "$output" == *"${long}"* ]]
}

@test "an unattributed task's description says so" {
  local task; task="$(jq -c '.attribution={story_ordinal:null,source:"none"}' <<< "${TASK}")"
  run adf_render_task_description "${task}"
  [[ "$output" == *"Attribution: none"* ]]
}

@test "an unparallel task's description says no" {
  local task; task="$(jq -c '.parallel=false' <<< "${TASK}")"
  run adf_render_task_description "${task}"
  [[ "$output" == *"Parallel-safe: no"* ]]
}

@test "no files and no dependencies produce no such bullet" {
  local task; task="$(jq -c '.files=[] | .depends_on=[]' <<< "${TASK}")"
  run adf_render_task_description "${task}"
  [[ "$output" != *"Files:"* ]]
  [[ "$output" != *"Depends on:"* ]]
}

@test "the rendered description is a valid ADF doc envelope" {
  run adf_render_task_description "${TASK}"
  [ "$(jq -r '.type' <<< "$output")" = "doc" ]
  [ "$(jq -r '.version' <<< "$output")" = "1" ]
  [ "$(jq -r '.content | type' <<< "$output")" = "array" ]
}

# --- Cross-port parity --------------------------------------------------------

@test "the PowerShell port renders an identical summary (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local long b p
  long="$(printf 'x%.0s' {1..400})"
  b="$(adf_task_summary "${long}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/Adf.psm1' -Force
    [Console]::Out.Write((Get-JiraAdfTaskSummary -Title '${long}'))")"
  [ "${b}" = "${p}" ]
}

@test "the PowerShell port renders byte-identical task description ADF (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(adf_render_task_description "${TASK}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/Adf.psm1' -Force
    [Console]::Out.Write((ConvertTo-JiraAdfTaskDescription -TaskJson '${TASK}'))")"
  [ "${b}" = "${p}" ]
}
