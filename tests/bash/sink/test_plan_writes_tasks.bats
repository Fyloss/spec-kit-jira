#!/usr/bin/env bats
# T031 [US1] — plan_writes_tasks: one POST per attributed task carrying
# local_id, parent_local_id, role:"task" and the parent placeholder; never a
# POST under the specification-level issue (FR-007); a story with no task
# planning nothing extra (FR-010); contract §4.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
}

TASK1='{
  "local_id":"1111111111111111","task_ref":"T014","title":"Implement the parser",
  "description":{"blocks":[{"type":"paragraph","text":"Implement the parser"}]},
  "attribution":{"story_ordinal":1,"source":"tag"},"phase":"Phase 3","parallel":true,
  "files":[],"depends_on":[],"done":false,
  "marker":{"state":"assigned","id":"1111111111111111","ticket":"","lines":[10]}
}'

DOC_ONE_TASK='{
  "routing":{"project_key":"COMP"},
  "epic":{"title":"Epic","local_id":"e1","marker":{"state":"assigned","id":"e1","lines":[1]},
          "description":{"blocks":[{"type":"paragraph","text":"x"}]}},
  "stories":[
    {"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","text":"need"}]},
     "priority_logical":"P1","tasks":['"${TASK1}"']}
  ]
}'

DOC_NO_TASKS='{
  "routing":{"project_key":"COMP"},
  "epic":{"title":"Epic","local_id":"e1","marker":{"state":"assigned","id":"e1","lines":[1]},
          "description":{"blocks":[{"type":"paragraph","text":"x"}]}},
  "stories":[
    {"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","text":"need"}]},
     "priority_logical":"P1"}
  ]
}'

CTX_CREATE='{"base_url":"https://mock","task_type_id":"10099","tickets":{}}'

@test "one POST per attributed task, carrying local_id, parent_local_id, role and the parent placeholder" {
  run plan_writes_tasks "${DOC_ONE_TASK}" "${CTX_CREATE}"
  [ "$status" -eq 0 ]
  [ "$(jq '. | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].method' <<< "$output")" = "POST" ]
  [ "$(jq -r '.[0].url' <<< "$output")" = "https://mock/rest/api/3/issue" ]
  [ "$(jq -r '.[0].local_id' <<< "$output")" = "1111111111111111" ]
  [ "$(jq -r '.[0].parent_local_id' <<< "$output")" = "s1" ]
  [ "$(jq -r '.[0].role' <<< "$output")" = "task" ]
  [ "$(jq -r '.[0].body.fields.parent.key' <<< "$output")" = "<resolved at apply time>" ]
  [ "$(jq -r '.[0].body.fields.issuetype.id' <<< "$output")" = "10099" ]
}

@test "a story with no task plans nothing extra (FR-010)" {
  run plan_writes_tasks "${DOC_NO_TASKS}" "${CTX_CREATE}"
  [ "$status" -eq 0 ]
  [ "$(jq '. | length' <<< "$output")" -eq 0 ]
}

@test "never a POST under the specification-level issue — the URL is always the collection endpoint" {
  run plan_writes_tasks "${DOC_ONE_TASK}" "${CTX_CREATE}"
  [[ "$(jq -r '.[0].url' <<< "$output")" != *"/issue/e1"* ]]
}

@test "the summary is the task's title (untruncated when short)" {
  run plan_writes_tasks "${DOC_ONE_TASK}" "${CTX_CREATE}"
  [ "$(jq -r '.[0].body.fields.summary' <<< "$output")" = "Implement the parser" ]
}

@test "an over-long title produces a deterministically shortened summary with the full text in the description" {
  local long task doc
  long="$(printf 'x%.0s' {1..400})"
  task="$(jq -c --arg t "${long}" '.title=$t' <<< "${TASK1}")"
  doc="$(jq -c --argjson t "${task}" '.stories[0].tasks=[$t]' <<< "${DOC_ONE_TASK}")"
  run plan_writes_tasks "${doc}" "${CTX_CREATE}"
  [ "$(jq -r '.[0].body.fields.summary | length' <<< "$output")" -eq 255 ]
  [[ "$(jq -c '.[0].body.fields.description' <<< "$output")" == *"${long}"* ]]
}

@test "an already-bound task with unchanged content plans nothing (zero churn)" {
  local ctx
  ctx='{"base_url":"https://mock","task_type_id":"10099",
        "tickets":{"1111111111111111":"COMP-9"},
        "ticket_current":{"1111111111111111":{"summary":"Implement the parser","description":'"$(adf_render_task_description "${TASK1}")"'}}}'
  run plan_writes_tasks "${DOC_ONE_TASK}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq '. | length' <<< "$output")" -eq 0 ]
}

@test "an already-bound task whose text changed plans a PUT carrying only the differing fields" {
  local task doc ctx
  task="$(jq -c '.title="Implement the parser, reworded"' <<< "${TASK1}")"
  doc="$(jq -c --argjson t "${task}" '.stories[0].tasks=[$t]' <<< "${DOC_ONE_TASK}")"
  ctx='{"base_url":"https://mock","task_type_id":"10099",
        "tickets":{"1111111111111111":"COMP-9"},
        "ticket_current":{"1111111111111111":{"summary":"Implement the parser","description":'"$(adf_render_task_description "${TASK1}")"'}}}'
  run plan_writes_tasks "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq '. | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].method' <<< "$output")" = "PUT" ]
  [ "$(jq -r '.[0].url' <<< "$output")" = "https://mock/rest/api/3/issue/COMP-9" ]
  [ "$(jq -r '.[0].body.fields.summary' <<< "$output")" = "Implement the parser, reworded" ]
  # A title change moves the summary, and also the description's own first
  # paragraph (the task's full, untruncated title) — so both fields
  # legitimately differ here; the fields-that-differ contrast is FR-019's
  # phase-only case below, which changes the description alone.
  [ "$(jq -r '.[0].body.fields | has("description")' <<< "$output")" = "true" ]
}

@test "an already-bound task whose description-affecting content changed plans a PUT carrying only the description (FR-019)" {
  local task doc ctx
  task="$(jq -c '.phase="Phase 4"' <<< "${TASK1}")"
  doc="$(jq -c --argjson t "${task}" '.stories[0].tasks=[$t]' <<< "${DOC_ONE_TASK}")"
  ctx='{"base_url":"https://mock","task_type_id":"10099",
        "tickets":{"1111111111111111":"COMP-9"},
        "ticket_current":{"1111111111111111":{"summary":"Implement the parser","description":'"$(adf_render_task_description "${TASK1}")"'}}}'
  run plan_writes_tasks "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq '. | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].method' <<< "$output")" = "PUT" ]
  [ "$(jq -r '.[0].body.fields | has("description")' <<< "$output")" = "true" ]
  [ "$(jq -r '.[0].body.fields | has("summary")' <<< "$output")" = "false" ]
}

@test "an already-bound task whose content diverges on the Jira side carries a named warning identifying the ticket and the field (FR-020)" {
  local task doc ctx
  task="$(jq -c '.title="Implement the parser, reworded"' <<< "${TASK1}")"
  doc="$(jq -c --argjson t "${task}" '.stories[0].tasks=[$t]' <<< "${DOC_ONE_TASK}")"
  ctx='{"base_url":"https://mock","task_type_id":"10099",
        "tickets":{"1111111111111111":"COMP-9"},
        "ticket_current":{"1111111111111111":{"summary":"Implement the parser","description":'"$(adf_render_task_description "${TASK1}")"'}}}'
  run plan_writes_tasks "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].warning' <<< "$output")" != "null" ]
  [[ "$(jq -r '.[0].warning' <<< "$output")" == *"COMP-9"* ]]
  [[ "$(jq -r '.[0].warning' <<< "$output")" == *"summary"* ]]
}

@test "a creation with no project or issue type refuses (zero writes)" {
  local ctx='{"base_url":"https://mock","tickets":{}}'
  run plan_writes_tasks "${DOC_ONE_TASK}" "${ctx}"
  [ "$status" -ne 0 ]
}

@test "several tasks under different stories each carry their own parent_local_id" {
  local task2 doc
  task2="$(jq -c '.local_id="2222222222222222"' <<< "${TASK1}")"
  doc="$(jq -c --argjson t2 "${task2}" '.stories += [{"local_id":"s2","title":"B","description":{"blocks":[{"type":"paragraph","text":"n"}]},"priority_logical":"P2","tasks":[$t2]}]' <<< "${DOC_ONE_TASK}")"
  run plan_writes_tasks "${doc}" "${CTX_CREATE}"
  [ "$(jq '. | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[0].parent_local_id' <<< "$output")" = "s1" ]
  [ "$(jq -r '.[1].parent_local_id' <<< "$output")" = "s2" ]
}

# --- Cross-port parity --------------------------------------------------------

@test "the PowerShell port produces an identical plan (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(plan_writes_tasks "${DOC_ONE_TASK}" "${CTX_CREATE}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraPlanTaskWriteSet -DocJson '${DOC_ONE_TASK}' -ContextJson '${CTX_CREATE}'))")"
  [ "${b}" = "${p}" ]
}
