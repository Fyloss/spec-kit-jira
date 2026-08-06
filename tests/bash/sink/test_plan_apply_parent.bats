#!/usr/bin/env bats
# T057/T060 [Phase 5, US2] — plan_writes returns {parent, stories}
# (data-model.md §6): the parent performed first, its response key
# placeholder carried on every child creation, parent: null on a recognised
# unchanged parent, and the cardinality invariant of spec FR-004.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
}

DOC='{
  "routing": {"project_key":"COMP"},
  "epic": {"title":"The Epic Title", "local_id":"3f2a91c04b7e6d18",
           "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
           "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},
  "stories": [
    {"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","spans":[{"text":"need","marks":[]}]}]},
     "priority_logical":"P2"}
  ]
}'

CTX_NEW_PARENT='{
  "base_url":"https://mock",
  "story_type_id":"10002",
  "parent_type_id":"10101",
  "parent_local_id":"3f2a91c04b7e6d18",
  "priority_ids":{"P1":"1","P2":"2","P3":"3"},
  "tickets":{}
}'

# 018, T026: the parent now carries the boundary too, so a fixture meant to
# be "unchanged" must already sit inside it — otherwise the first touch of a
# legacy (marker-less) description also migrates, which is its own,
# separately-tested behaviour (contract §3).
CTX_BOUND_UNCHANGED_PARENT='{
  "base_url":"https://mock",
  "story_type_id":"10002",
  "parent_type_id":"10101",
  "parent_key":"COMP-412",
  "parent_current":{"summary":"The Epic Title","description":{"type":"doc","version":1,"content":[
    {"type":"paragraph","content":[{"type":"text","text":"Synced from spec-kit — do not edit below this line","marks":[{"type":"strong"}]}]},
    {"type":"paragraph","content":[{"type":"text","text":"Overview."}]}
  ]}},
  "priority_ids":{"P1":"1","P2":"2","P3":"3"},
  "tickets":{}
}'

CTX_BOUND_CHANGED_PARENT='{
  "base_url":"https://mock",
  "story_type_id":"10002",
  "parent_type_id":"10101",
  "parent_key":"COMP-412",
  "parent_current":{"summary":"An old title","description":{"type":"doc","version":1,"content":[]}},
  "priority_ids":{"P1":"1","P2":"2","P3":"3"},
  "tickets":{}
}'

# --- T057: the return shape --------------------------------------------------

@test "plan_writes returns an object with parent and stories keys" {
  run plan_writes "${DOC}" "${CTX_NEW_PARENT}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("parent") and has("stories")' <<< "$output")" = "true" ]
}

@test "a specification with no recognised parent plans a POST for the parent, carrying its local_id and role" {
  run plan_writes "${DOC}" "${CTX_NEW_PARENT}"
  [ "$(jq -r '.parent.method' <<< "$output")" = "POST" ]
  [ "$(jq -r '.parent.url' <<< "$output")" = "https://mock/rest/api/3/issue" ]
  [ "$(jq -r '.parent.body.fields.issuetype.id' <<< "$output")" = "10101" ]
  [ "$(jq -r '.parent.body.fields.summary' <<< "$output")" = "The Epic Title" ]
  [ "$(jq -r '.parent.local_id' <<< "$output")" = "3f2a91c04b7e6d18" ]
  [ "$(jq -r '.parent.role' <<< "$output")" = "parent" ]
}

@test "every story creation carries the parent-key placeholder, resolved at apply time" {
  run plan_writes "${DOC}" "${CTX_NEW_PARENT}"
  [ "$(jq -r '.stories[0].body.fields.parent.key' <<< "$output")" = "<resolved at apply time>" ]
}

@test "story actions still carry role:story and their own local_id" {
  run plan_writes "${DOC}" "${CTX_NEW_PARENT}"
  [ "$(jq -r '.stories[0].role' <<< "$output")" = "story" ]
  [ "$(jq -r '.stories[0].local_id' <<< "$output")" = "s1" ]
}

@test "a recognised parent with unchanged bridge-owned content plans parent: null" {
  run plan_writes "${DOC}" "${CTX_BOUND_UNCHANGED_PARENT}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent' <<< "$output")" = "null" ]
}

@test "a recognised parent whose content differs plans a PUT, no local_id (never re-created)" {
  run plan_writes "${DOC}" "${CTX_BOUND_CHANGED_PARENT}"
  [ "$(jq -r '.parent.method' <<< "$output")" = "PUT" ]
  [ "$(jq -r '.parent.url' <<< "$output")" = "https://mock/rest/api/3/issue/COMP-412" ]
  [ "$(jq -r '.parent.body.fields.summary' <<< "$output")" = "The Epic Title" ]
  [ "$(jq -r 'has("local_id")' <<< "$(jq -c '.parent' <<< "$output")")" = "false" ]
}

@test "an existing (recognised) parent never carries fields.parent on child creations differently — the placeholder is unconditional" {
  run plan_writes "${DOC}" "${CTX_BOUND_UNCHANGED_PARENT}"
  [ "$(jq -r '.stories[0].body.fields.parent.key' <<< "$output")" = "<resolved at apply time>" ]
}

@test "cardinality invariant (FR-004): parent is never a list, across every configuration" {
  local ctx
  for ctx in "${CTX_NEW_PARENT}" "${CTX_BOUND_UNCHANGED_PARENT}" "${CTX_BOUND_CHANGED_PARENT}"; do
    run plan_writes "${DOC}" "${ctx}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '(.parent == null) or (.parent | type == "object")' <<< "$output")" = "true" ]
  done
}

# --- T060: zero churn + human-managed-section comparison -------------------

@test "T060: an unchanged parent is not written to (parent: null), matching the story zero-churn rule's intent" {
  run plan_writes "${DOC}" "${CTX_BOUND_UNCHANGED_PARENT}"
  [ "$(jq -r '.parent' <<< "$output")" = "null" ]
}

@test "T060: a human-edited parent description is compared on its managed section alone" {
  # The human's prose above the managed panel differs, but the bridge-owned
  # content below the panel is identical — this must NOT count as churn.
  local marker; marker="$(adf_managed_marker)"
  local human_current
  human_current="$(jq -cn --arg m "${marker}" '
    {summary:"The Epic Title",
     description:{type:"doc", version:1, content:[
       {type:"paragraph", content:[{type:"text", text:"A human wrote this prose first."}]},
       {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
       {type:"paragraph", content:[{type:"text", text:"Overview."}]}
     ]}}')"
  local ctx
  ctx="$(jq -c --argjson c "${human_current}" '. + {parent_current:$c, parent_origin:"human"}' <<< "${CTX_BOUND_UNCHANGED_PARENT}")"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent' <<< "$output")" = "null" ]
}

# --- T090 [Phase 7, US5]: the plan section is replaced in place -------------

DOC_WITH_PLAN='{
  "routing": {"project_key":"COMP"},
  "epic": {"title":"The Epic Title", "local_id":"3f2a91c04b7e6d18",
           "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
           "description":{"blocks":[
             {"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]},
             {"type":"heading","level":3,"spans":[{"text":"Implementation Plan","marks":[]}]},
             {"type":"paragraph","spans":[{"text":"The original plan summary.","marks":[]}]}
           ]}},
  "stories": []
}'

DOC_WITH_CHANGED_PLAN='{
  "routing": {"project_key":"COMP"},
  "epic": {"title":"The Epic Title", "local_id":"3f2a91c04b7e6d18",
           "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
           "description":{"blocks":[
             {"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]},
             {"type":"heading","level":3,"spans":[{"text":"Implementation Plan","marks":[]}]},
             {"type":"paragraph","spans":[{"text":"A revised plan summary.","marks":[]}]}
           ]}},
  "stories": []
}'

@test "T090: a new parent's creation body carries the Implementation Plan section" {
  run plan_writes "${DOC_WITH_PLAN}" "${CTX_NEW_PARENT}"
  [ "$status" -eq 0 ]
  local body; body="$(jq -c '.parent.body.fields.description' <<< "$output")"
  [[ "${body}" == *"Implementation Plan"* ]]
  [[ "${body}" == *"The original plan summary."* ]]
}

@test "T090: the Implementation Plan heading appears exactly once" {
  run plan_writes "${DOC_WITH_PLAN}" "${CTX_NEW_PARENT}"
  local body; body="$(jq -c '.parent.body.fields.description' <<< "$output")"
  [ "$(grep -o "Implementation Plan" <<< "${body}" | wc -l)" -eq 1 ]
}

@test "T090: an unchanged plan issues no write to the parent" {
  # The recognised parent's current content already carries the exact same
  # plan section — a second run must plan parent: null, not a PUT.
  local current
  current='{"summary":"The Epic Title","description":{"type":"doc","version":1,"content":[
    {"type":"paragraph","content":[{"type":"text","text":"Synced from spec-kit — do not edit below this line","marks":[{"type":"strong"}]}]},
    {"type":"paragraph","content":[{"type":"text","text":"Overview."}]},
    {"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"Implementation Plan"}]},
    {"type":"paragraph","content":[{"type":"text","text":"The original plan summary."}]}
  ]}}'
  local ctx; ctx="$(jq -c --argjson c "${current}" '. + {parent_key:"COMP-412", parent_current:$c} | del(.parent_local_id)' <<< "${CTX_NEW_PARENT}")"
  run plan_writes "${DOC_WITH_PLAN}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent' <<< "$output")" = "null" ]
}

@test "T090: a changed plan replaces the section in place — the old summary is gone, not appended alongside the new one" {
  local current
  current='{"summary":"The Epic Title","description":{"type":"doc","version":1,"content":[
    {"type":"paragraph","content":[{"type":"text","text":"Synced from spec-kit — do not edit below this line","marks":[{"type":"strong"}]}]},
    {"type":"paragraph","content":[{"type":"text","text":"Overview."}]},
    {"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"Implementation Plan"}]},
    {"type":"paragraph","content":[{"type":"text","text":"The original plan summary."}]}
  ]}}'
  local ctx; ctx="$(jq -c --argjson c "${current}" '. + {parent_key:"COMP-412", parent_current:$c} | del(.parent_local_id)' <<< "${CTX_NEW_PARENT}")"
  run plan_writes "${DOC_WITH_CHANGED_PLAN}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent.method' <<< "$output")" = "PUT" ]
  local body; body="$(jq -c '.parent.body.fields.description' <<< "$output")"
  [[ "${body}" == *"A revised plan summary."* ]]
  [[ "${body}" != *"The original plan summary."* ]]
  [ "$(grep -o "Implementation Plan" <<< "${body}" | wc -l)" -eq 1 ]
}

# --- Cross-port parity -------------------------------------------------------

@test "the PowerShell port produces an identical plan shape (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(plan_writes "${DOC}" "${CTX_NEW_PARENT}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraPlanWriteSet -NeutralDocJson '${DOC}' -PlanContextJson '${CTX_NEW_PARENT}'))")"
  [ "${b}" = "${p}" ]
}
