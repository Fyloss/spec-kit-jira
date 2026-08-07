#!/usr/bin/env bats
# 018, T022 [US2] — the boundary's four remaining behaviours, proven through
# the FULL write-planning functions (plan_writes, _plan_writes_parent via
# plan_writes, plan_writes_tasks) across every tier, not just the adf.sh
# splice unit tests:
#   - preservation across parent, story and sub-task (FR-007)
#   - an edit confined to the prefix produces zero writes (FR-009)
#   - a deleted managed region is restored in full (FR-008)
#   - a duplicated delimiter warns by ticket key and writes no description,
#     while every other field of that ticket still reconciles (FR-012)
#   - a tracker rejection of an oversized description retries the same
#     write without it, warns once by ticket key, and every other field
#     still reconciles (T068, FR-011)

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  MARKER="$(adf_managed_marker)"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

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

_human_desc() {
  # A human-authored prefix above a well-formed panel wrapping the given
  # managed-node array.
  local prefix_text="$1" managed="$2"
  jq -cn --arg t "${prefix_text}" --arg m "${MARKER}" --argjson managed "${managed}" \
    '{type:"doc", version:1, content: (
      [{type:"paragraph", content:[{type:"text", text:$t}]},
       {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}]
      + $managed) }'
}

_two_marker_desc() {
  local managed="$1"
  jq -cn --arg m "${MARKER}" --argjson managed "${managed}" \
    '{type:"doc", version:1, content: (
      [{type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}]
      + $managed
      + [{type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}]
      + $managed) }'
}

DOC='{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Epic overview.","marks":[]}]}]}},
      "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2",
                  "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Story body.","marks":[]}]}]}}]}'

# A parent-only document (no stories) for tests that must isolate the parent
# tier without a story creation also needing resolution.
DOC_PARENT_ONLY='{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Epic overview.","marks":[]}]}]}},
      "stories":[]}'

DOC_PARENT_ONLY_CHANGED='{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Epic overview, revised.","marks":[]}]}]}},
      "stories":[]}'

TASK='{"local_id":"1111111111111111","task_ref":"T001","title":"Do the thing",
       "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Do the thing","marks":[]}]}]},
       "attribution":{"story_ordinal":1,"source":"tag"},"phase":"Phase 1","parallel":false,
       "files":[],"depends_on":[],"done":false,
       "marker":{"state":"assigned","id":"1111111111111111","ticket":"","lines":[10]}}'

DOC_WITH_TASK='{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"e1","marker":{"state":"assigned","id":"e1","lines":[1]},
              "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Epic overview.","marks":[]}]}]}},
      "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2",
                  "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Story body.","marks":[]}]}]},
                  "tasks":['"${TASK}"']}]}'

# --- FR-007: preservation across parent, story and sub-task -----------------

@test "FR-007 — the story tier preserves the human prefix verbatim" {
  local managed existing ctx
  managed="$(_adf_content_nodes '{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Story body.","marks":[]}]}]}}')"
  existing="$(_human_desc "A PO wrote this on the story." "${managed}")"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}, ticket_descriptions:{s1:$ex}}')"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.stories[0].body.fields.description' <<< "$output")"
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "A PO wrote this on the story." ]
}

@test "FR-007 — the parent tier preserves the human prefix verbatim" {
  # The managed body changes (forcing a write) while the human prefix stays
  # put — proving preservation is visible in the emitted payload.
  local managed existing ctx
  managed="$(_adf_content_nodes '{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Epic overview.","marks":[]}]}]}}')"
  existing="$(_human_desc "A PO wrote this on the epic." "${managed}")"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  run plan_writes "${DOC_PARENT_ONLY_CHANGED}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.parent.body.fields.description' <<< "$output")"
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "A PO wrote this on the epic." ]
  [[ "$(jq -c '.' <<< "${desc}")" == *"Epic overview, revised."* ]]
}

@test "FR-007 — the sub-task tier preserves the human prefix verbatim" {
  # The task's own text changes (forcing a write of the description — 016
  # moved a task's body from .title to .description.blocks, so the title
  # alone no longer does) while the human prefix stays put — proving
  # preservation is visible in the emitted payload.
  local managed existing task_reworded doc ctx
  managed="$(adf_render_task_description "${TASK}" | jq -c '.content')"
  existing="$(_human_desc "A PO wrote this on the sub-task." "${managed}")"
  task_reworded="$(jq -c '.title="Do the thing, reworded" | .description.blocks[0].spans[0].text="Do the thing, reworded"' <<< "${TASK}")"
  doc="$(jq -c --argjson t "${task_reworded}" '.stories[0].tasks=[$t]' <<< "${DOC_WITH_TASK}")"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", task_type_id:"10099", tickets:{"1111111111111111":"PROJ-9"}, ticket_current:{"1111111111111111":{summary:"Do the thing", description:$ex}}}')"
  run plan_writes_tasks "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.actions[0].body.fields.description' <<< "$output")"
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "A PO wrote this on the sub-task." ]
  [[ "$(jq -c '.' <<< "${desc}")" == *"Do the thing, reworded"* ]]
}

# --- FR-009: an edit confined to the prefix produces zero writes -----------

@test "FR-009 — a sub-task's prefix-only edit produces zero writes" {
  local managed current_existing new_existing ctx
  managed="$(adf_render_task_description "${TASK}" | jq -c '.content')"
  new_existing="$(_human_desc "EDITED note by the PO." "${managed}")"
  ctx="$(jq -cn --argjson ex "${new_existing}" '{base_url:"https://mock", task_type_id:"10099", tickets:{"1111111111111111":"PROJ-9"}, ticket_current:{"1111111111111111":{summary:"Do the thing", description:$ex}}}')"
  run plan_writes_tasks "${DOC_WITH_TASK}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq '.actions | length' <<< "$output")" -eq 0 ]
}

@test "FR-009 — the parent's prefix-only edit produces zero writes" {
  local managed existing ctx
  managed="$(_adf_content_nodes '{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Epic overview.","marks":[]}]}]}}')"
  existing="$(_human_desc "A DIFFERENT human note." "${managed}")"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  run plan_writes "${DOC_PARENT_ONLY}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent' <<< "$output")" = "null" ]
}

# --- FR-008: a deleted managed region is restored in full -------------------

@test "FR-008 — a story missing its managed region entirely has it restored in full" {
  local existing ctx
  # The marker survives (a human cannot see it well-formed without it), but
  # everything after it — the mirror's own region — was deleted.
  existing="$(jq -cn --arg m "${MARKER}" '{type:"doc", version:1, content:[
    {type:"paragraph", content:[{type:"text", text:"PO note."}]},
    {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}
  ]}')"
  local ctx; ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}, ticket_descriptions:{s1:$ex}}')"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.stories[0].body.fields.description' <<< "$output")"
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "PO note." ]
  [[ "$(jq -c '.' <<< "${desc}")" == *"Story body."* ]]
}

# --- FR-012: a duplicated delimiter warns and writes no description --------

@test "FR-012 — a story with two boundary markers warns by key, writes no description, but still updates other fields" {
  local managed existing ctx
  managed="$(_adf_content_nodes '{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Story body.","marks":[]}]}]}}')"
  existing="$(_two_marker_desc "${managed}")"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}, ticket_descriptions:{s1:$ex}, priority_ids:{P2:"2"}}')"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields | has("description")' <<< "$output")" = "false" ]
  [ "$(jq -r '.stories[0].body.fields.summary' <<< "$output")" = "Story One" ]
  [ "$(jq -r '.stories[0].body.fields.priority.id' <<< "$output")" = "2" ]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"PROJ-1"* ]]
}

@test "FR-012 — a sub-task with two boundary markers warns by key, writes no description, but still updates the summary" {
  local managed existing ctx
  managed="$(adf_render_task_description "${TASK}" | jq -c '.content')"
  existing="$(_two_marker_desc "${managed}")"
  local task_reworded; task_reworded="$(jq -c '.title="Do the thing, reworded"' <<< "${TASK}")"
  local doc; doc="$(jq -c --argjson t "${task_reworded}" '.stories[0].tasks=[$t]' <<< "${DOC_WITH_TASK}")"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", task_type_id:"10099", tickets:{"1111111111111111":"PROJ-9"}, ticket_current:{"1111111111111111":{summary:"Do the thing", description:$ex}}}')"
  run plan_writes_tasks "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[0].body.fields | has("description")' <<< "$output")" = "false" ]
  [ "$(jq -r '.actions[0].body.fields.summary' <<< "$output")" = "Do the thing, reworded" ]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"PROJ-9"* ]]
}

# --- 019, T018 [US4]: text a human wrote is never mistaken for the mirror's --

@test "019, T018 — origin human, no boundary: the whole description is preserved above a newly established boundary, with one warning (FR-003)" {
  local existing ctx
  existing="$(jq -cn '{type:"doc", version:1, content:[{type:"paragraph", content:[{type:"text", text:"A human wrote this ticket from scratch."}]}]}')"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}, ticket_descriptions:{s1:$ex}, ticket_origins:{s1:"human"}, priority_ids:{P2:"2"}}')"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.stories[0].body.fields.description' <<< "$output")"
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "A human wrote this ticket from scratch." ]
  [[ "$(jq -c '.' <<< "${desc}")" == *"do not edit below this line"* ]]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"PROJ-1"* ]]
}

@test "019, T018 — origin human, existing boundary: human prose above it is preserved verbatim, only the region below is replaced (FR-003)" {
  local managed existing ctx
  managed="$(_adf_content_nodes '{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Story body.","marks":[]}]}]}}')"
  existing="$(_human_desc "Context the product owner added." "${managed}")"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}, ticket_descriptions:{s1:$ex}, ticket_origins:{s1:"human"}}')"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.stories[0].body.fields.description' <<< "$output")"
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "Context the product owner added." ]
  [ "$(jq -r '.warnings // [] | length' <<< "$output")" -eq 0 ]
}

@test "T068 (FR-011) — a tracker rejection of an oversized description retries without it, warns once by key, and every other field still reconciles" {
  boot '{"issues":{"PRSV-2":{"summary":"Old summary"}},"faults":{"PRSV-2":{"status":400,"errors":{"description":"The description field exceeds the maximum length of 32767 characters."},"ifFieldPresent":"description"}}}'
  local desc plan spec_file
  desc="$(jq -cn '{type:"doc", version:1, content:[{type:"paragraph", content:[{type:"text", text:"managed body"}]}]}')"
  plan="$(jq -cn --arg url "${MOCK_BASE_URL}/rest/api/3/issue/PRSV-2" --argjson d "${desc}" \
    '{parent:null, stories:[{method:"PUT", url:$url, body:{fields:{summary:"New summary", description:$d}}}]}')"
  spec_file="${BATS_TEST_TMPDIR}/spec_t068.md"
  run --separate-stderr apply_writes_with_recognition "${plan}" '{}' "${spec_file}"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"PRSV-2"* ]]
  [[ "$stderr" == *"description"* ]]
  [ "$(mock_issue_field PRSV-2 '.fields.summary')" = "New summary" ]
  [ "$(mock_issue_field PRSV-2 '.fields.description')" = "null" ]
  [ "$(mock_calls | grep -c '^PUT /rest/api/3/issue/PRSV-2$')" -eq 2 ]
}
