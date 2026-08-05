#!/usr/bin/env bats
# 018, T040 [US3] — the last-written summary record (contract summary-record.md
# §2/§3/§4), the whole decision table plus the §3 normalisation rule, across
# every tier:
#   - no record means no warning (FR-018)
#   - record equal (normalised) means a silent retitle (FR-017)
#   - record different means the field is omitted and one warning names
#     ticket and field (FR-015)
#   - --on-drift=proceed restores and counts it (FR-016)
#   - a whitespace-only difference never warns (§3)
#   - a settled ticket writes no entity property at all (FR-019)

teardown() {
  mock_stop
}

boot() {
  local cfg
  cfg="$(mktemp)"
  printf '%s' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

# --- Unit: the pure decision function ---------------------------------------

@test "plan_summary_drift_status: no record — sends the desired summary, never warns" {
  run plan_summary_drift_status "Old Title" "" "New Title" "abort"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.summary' <<< "$output")" = "New Title" ]
}

@test "plan_summary_drift_status: record equal to current — silent retitle" {
  run plan_summary_drift_status "The Epic" "The Epic" "The Epic, revised" "abort"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.summary' <<< "$output")" = "The Epic, revised" ]
}

@test "plan_summary_drift_status: record differs from current (abort, default) — omits the summary" {
  run plan_summary_drift_status "A human's rename" "The Epic" "The Epic, revised" "abort"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.summary' <<< "$output")" = "null" ]
}

@test "plan_summary_drift_status: --on-drift=proceed restores the specification's title" {
  run plan_summary_drift_status "A human's rename" "The Epic" "The Epic, revised" "proceed"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.summary' <<< "$output")" = "The Epic, revised" ]
}

@test "plan_summary_drift_status: a whitespace-only difference between current and recorded never triggers omission" {
  run plan_summary_drift_status "  The   Epic " "The Epic" "The Epic, revised" "abort"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.summary' <<< "$output")" = "The Epic, revised" ]
}

@test "plan_summary_drift_status: a human's rename that already matches the specification's title is never treated as drift" {
  run plan_summary_drift_status "The Epic, revised" "The Epic" "The Epic, revised" "abort"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.summary' <<< "$output")" = "The Epic, revised" ]
}

# --- Integration: the story tier via plan_writes ----------------------------

DOC='{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
      "stories":[{"local_id":"s1","title":"Story One, revised","priority_logical":"P2",
                  "description":{"blocks":[{"type":"paragraph","text":"Story body."}]}}]}'

_story_ctx() {
  local current_summary="$1" recorded_summary="$2" on_drift="${3:-abort}"
  local managed existing
  managed="$(adf_render_description '{"description":{"blocks":[{"type":"paragraph","text":"Story body."}]}}' | jq -c '.content')"
  existing="$(jq -cn --arg m "$(adf_managed_marker)" --argjson managed "${managed}" \
    '{type:"doc", version:1, content: ([{type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}] + $managed)}')"
  jq -cn --argjson ex "${existing}" --arg cs "${current_summary}" --arg od "${on_drift}" \
    '{base_url:"https://mock", parent_type_id:"10101", tickets:{"s1":"PROJ-1"},
      ticket_descriptions:{"s1":$ex}, ticket_summaries:{"s1":$cs}, ticket_origins:{"s1":"bridge"},
      on_drift:$od, priority_ids:{"P2":"2"}}' \
    | if [[ -n "${recorded_summary}" ]]; then jq -c --arg rs "${recorded_summary}" '. + {ticket_last_summaries:{"s1":$rs}}'; else cat; fi
}

@test "T040 — story: no record means no warning, the summary is sent (FR-018)" {
  local ctx; ctx="$(_story_ctx "Story One" "")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields.summary' <<< "$output")" = "Story One, revised" ]
  [ "$(jq '.warnings // [] | length' <<< "$output")" -eq 0 ]
}

@test "T040 — story: record equal to current means a silent retitle (FR-017)" {
  local ctx; ctx="$(_story_ctx "Story One" "Story One")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields.summary' <<< "$output")" = "Story One, revised" ]
  [ "$(jq '.warnings // [] | length' <<< "$output")" -eq 0 ]
}

@test "T040 — story: record different (abort, default) omits the field and warns by ticket and field name (FR-015)" {
  local ctx; ctx="$(_story_ctx "A human's rename" "Story One")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields | has("summary")' <<< "$output")" = "false" ]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"PROJ-1"* ]]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"summary"* ]]
  # The human's rename itself is never quoted (contract §4).
  [[ "$(jq -r '.warnings[]' <<< "$output")" != *"A human's rename"* ]]
}

@test "T040 — story: every other field of a drifted ticket still reconciles" {
  local ctx; ctx="$(_story_ctx "A human's rename" "Story One")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields.priority.id' <<< "$output")" = "2" ]
}

@test "T040 — story: --on-drift=proceed restores the specification's title and is an ordinary update (FR-016)" {
  local ctx; ctx="$(_story_ctx "A human's rename" "Story One" "proceed")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields.summary' <<< "$output")" = "Story One, revised" ]
  [ "$(jq '.warnings // [] | length' <<< "$output")" -eq 0 ]
}

@test "T040 — story: a whitespace-only difference between current and recorded never warns" {
  local ctx; ctx="$(_story_ctx "  Story   One " "Story One")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields.summary' <<< "$output")" = "Story One, revised" ]
  [ "$(jq '.warnings // [] | length' <<< "$output")" -eq 0 ]
}

# --- Integration: the parent tier via plan_writes ---------------------------

DOC_PARENT_ONLY='{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic, revised","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
      "stories":[]}'

_parent_ctx() {
  local current_summary="$1" recorded_summary="$2" on_drift="${3:-abort}"
  local managed existing
  managed="$(adf_render_description '{"description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}}' | jq -c '.content')"
  existing="$(jq -cn --arg m "$(adf_managed_marker)" --argjson managed "${managed}" \
    '{type:"doc", version:1, content: ([{type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}] + $managed)}')"
  jq -cn --argjson ex "${existing}" --arg cs "${current_summary}" --arg od "${on_drift}" \
    '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1",
      parent_current:{summary:$cs, description:$ex}, parent_origin:"bridge", tickets:{}, on_drift:$od}' \
    | if [[ -n "${recorded_summary}" ]]; then jq -c --arg rs "${recorded_summary}" '. + {parent_last_summary:$rs}'; else cat; fi
}

@test "T040 — parent: record different (abort, default) omits the field and warns (FR-015)" {
  local ctx; ctx="$(_parent_ctx "A human's rename" "The Epic")"
  run plan_writes "${DOC_PARENT_ONLY}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent.body.fields | has("summary")' <<< "$output")" = "false" ]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"PROJ-1"* ]]
}

@test "T040 — parent: --on-drift=proceed restores the specification's title (FR-016)" {
  local ctx; ctx="$(_parent_ctx "A human's rename" "The Epic" "proceed")"
  run plan_writes "${DOC_PARENT_ONLY}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent.body.fields.summary' <<< "$output")" = "The Epic, revised" ]
}

# --- Integration: the task tier via plan_writes_tasks -----------------------

TASK='{"local_id":"1111111111111111","task_ref":"T001","title":"Do the thing, revised",
       "description":{"blocks":[{"type":"paragraph","text":"Do the thing"}]},
       "attribution":{"story_ordinal":1,"source":"tag"},"phase":"Phase 1","parallel":false,
       "files":[],"depends_on":[],"done":false,
       "marker":{"state":"assigned","id":"1111111111111111","ticket":"","lines":[10]}}'

DOC_WITH_TASK='{"routing":{"project_key":"COMP"},
  "epic":{"title":"The Epic","local_id":"e1","marker":{"state":"assigned","id":"e1","lines":[1]},
          "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
  "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2",
              "description":{"blocks":[{"type":"paragraph","text":"Story body."}]},
              "tasks":['"${TASK}"']}]}'

@test "T040 — task tier: record different (abort, default) omits the field and warns (FR-015, §5)" {
  local managed existing ctx
  managed="$(adf_render_task_description "${TASK}" | jq -c '.content')"
  existing="$(jq -cn --arg m "$(adf_managed_marker)" --argjson managed "${managed}" \
    '{type:"doc", version:1, content: ([{type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}] + $managed)}')"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", task_type_id:"10099",
    tickets:{"1111111111111111":"PROJ-9"}, ticket_current:{"1111111111111111":{summary:"A human'"'"'s rename", description:$ex}},
    ticket_summaries:{"1111111111111111":"A human'"'"'s rename"}, ticket_last_summaries:{"1111111111111111":"Do the thing"},
    ticket_origins:{"1111111111111111":"bridge"}, on_drift:"abort"}')"
  run plan_writes_tasks "${DOC_WITH_TASK}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[0].body.fields | has("summary")' <<< "$output")" = "false" ]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"PROJ-9"* ]]
}

# --- FR-019: a settled ticket writes no entity property at all -------------
#
# Since the record is stamped only on an action that actually reaches Jira
# (apply time), the planning-level guarantee this pins is upstream of that:
# a genuinely unchanged parent (same summary, same managed content, no
# drift) produces NO action at all — by construction, nothing follows it.

@test "T040 — FR-019: a fully settled parent (nothing changed, including summary) produces zero writes" {
  local ctx; ctx="$(_parent_ctx "The Epic" "The Epic")"
  local doc_unchanged='{"routing":{"project_key":"COMP"},
    "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
            "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
            "description":{"blocks":[{"type":"paragraph","text":"Epic overview."}]}},
    "stories":[]}'
  run plan_writes "${doc_unchanged}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.parent' <<< "$output")" = "null" ]
}

# --- Apply-time: the record is actually written, only when it should be ----

@test "T048/T049 — a story update whose payload carries summary stamps the identity record" {
  boot '{"issues":{"PROJ-1":{"summary":"Story One"}}}'
  local ctx; ctx="$(_story_ctx "Story One" "")"
  ctx="$(jq -c --arg b "${MOCK_BASE_URL}" '.base_url = $b' <<< "${ctx}")"
  local plan; plan="$(plan_writes "${DOC}" "${ctx}")"
  plan="$(jq -cn --argjson p "${plan}" '{parent:null, stories:$p.stories}')"
  local spec_file="${BATS_TEST_TMPDIR}/spec_summary_apply.md"
  run apply_writes_with_recognition "${plan}" '{}' "${spec_file}"
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c 'PUT /rest/api/3/issue/PROJ-1/properties/spec-kit-jira')" -eq 1 ]
  [ "$(identity_read PROJ-1 | jq -r '.summary')" = "Story One, revised" ]
}

@test "T048/T049 — a task PUT that changes only its description never touches the identity property (summary unchanged)" {
  boot '{"issues":{"PROJ-9":{"summary":"Do the thing, revised"}}}'
  local managed existing
  managed="$(adf_render_task_description "${TASK}" | jq -c '.content')"
  existing="$(jq -cn --arg m "$(adf_managed_marker)" --argjson managed "${managed}" \
    '{type:"doc", version:1, content: ([{type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}] + $managed)}')"
  local task_reworded; task_reworded="$(jq -c '.phase="Phase 2"' <<< "${TASK}")"
  local doc; doc="$(jq -c --argjson t "${task_reworded}" '.stories[0].tasks=[$t]' <<< "${DOC_WITH_TASK}")"
  local ctx; ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"'"${MOCK_BASE_URL}"'", task_type_id:"10099",
    tickets:{"1111111111111111":"PROJ-9"}, ticket_current:{"1111111111111111":{summary:"Do the thing, revised", description:$ex}},
    ticket_summaries:{"1111111111111111":"Do the thing, revised"}, ticket_origins:{"1111111111111111":"bridge"}}')"
  local tasks_plan; tasks_plan="$(plan_writes_tasks "${doc}" "${ctx}")"
  local tasks_actions; tasks_actions="$(jq -c '.actions' <<< "${tasks_plan}")"
  local spec_file="${BATS_TEST_TMPDIR}/spec_summary_task.md" tasks_file="${BATS_TEST_TMPDIR}/tasks_summary_task.md"
  run apply_writes_with_recognition '{"parent":null,"stories":[]}' '{}' "${spec_file}" "" "[]" "{}" "${tasks_actions}" "${tasks_file}" "{}"
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c 'PUT /rest/api/3/issue/PROJ-9$')" -eq 1 ]
  [ "$(mock_calls | grep -c 'properties/spec-kit-jira')" -eq 0 ]
}
