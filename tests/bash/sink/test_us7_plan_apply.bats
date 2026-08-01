#!/usr/bin/env bats
# T075 [US7] — Human-content preservation wired into the write path.
#
# plan_writes on a human-origin UPDATE renders the description through the managed
# panel (human prose preserved above, FR-038). plan_managed_description_status
# decides churn on the managed section ALONE, so a human edit above the panel is
# not churn (FR-039). Both ports agree byte-for-byte (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"

  DOC='{"routing":{"project_key":"COMP"},
        "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
                "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
                "description":{"blocks":[{"type":"paragraph","text":"Overview."}]}},
        "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2","description":{"blocks":[{"type":"paragraph","text":"New managed body."}]}}]}'
  MARKER="$(adf_managed_marker)"
  # An existing human-origin description: one human paragraph, then a prior panel.
  EXISTING="$(jq -cn --arg m "${MARKER}" '
    {type:"doc", version:1, content:[
      {type:"paragraph", content:[{type:"text", text:"PO handwritten note."}]},
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"paragraph", content:[{type:"text", text:"stale managed body"}]}
    ]}')"
  CTX="$(jq -cn --argjson ex "${EXISTING}" '{
    base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18",
    tickets:{s1:"PROJ-1"},
    ticket_origins:{s1:"human"}, ticket_descriptions:{s1:$ex}
  }')"
}

@test "a human-origin update preserves the human prefix and drops the stale managed body (FR-038)" {
  run plan_writes "${DOC}" "${CTX}"
  [ "$status" -eq 0 ]
  local desc
  desc="$(jq -c '.stories[0].body.fields.description' <<< "$output")"
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "PO handwritten note." ]
  [[ "$(jq -c '.' <<< "${desc}")" == *"do not edit below this line"* ]]
  [[ "$(jq -c '.' <<< "${desc}")" != *"stale managed body"* ]]
  [[ "$(jq -c '.' <<< "${desc}")" == *"New managed body."* ]]
}

@test "a bridge-created update (no origin) keeps the US3 whole-description behaviour" {
  local ctx
  ctx="$(jq -cn '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}}')"
  run plan_writes "${DOC}" "${ctx}"
  [ "$status" -eq 0 ]
  [[ "$(jq -c '.stories' <<< "$output")" != *"do not edit below this line"* ]]
}

@test "an edit to the human prose above the panel is not churn (FR-039)" {
  # current = existing panel with the ORIGINAL managed body; the new render carries
  # the SAME managed body but a DIFFERENT human prefix -> managed section unchanged.
  local current_desc new_desc st
  current_desc="$(jq -cn --arg m "${MARKER}" '
    {type:"doc", version:1, content:[
      {type:"paragraph", content:[{type:"text", text:"ORIGINAL human note."}]},
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"paragraph", content:[{type:"text", text:"managed body"}]}
    ]}')"
  new_desc="$(jq -cn --arg m "${MARKER}" '
    {type:"doc", version:1, content:[
      {type:"paragraph", content:[{type:"text", text:"EDITED human note by the PO."}]},
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"paragraph", content:[{type:"text", text:"managed body"}]}
    ]}')"
  st="$(plan_managed_description_status "${current_desc}" "${new_desc}")"
  [ "${st}" = "unchanged" ]
}

@test "a change to the managed body IS churn (FR-039)" {
  local a b st
  a="$(jq -cn --arg m "${MARKER}" '{content:[{type:"paragraph",content:[{type:"text",text:$m}]},{type:"paragraph",content:[{type:"text",text:"old"}]}]}')"
  b="$(jq -cn --arg m "${MARKER}" '{content:[{type:"paragraph",content:[{type:"text",text:$m}]},{type:"paragraph",content:[{type:"text",text:"new"}]}]}')"
  st="$(plan_managed_description_status "${a}" "${b}")"
  [ "${st}" = "changed" ]
}

@test "plan_writes for a human update is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(plan_writes "${DOC}" "${CTX}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraPlanWriteSet -NeutralDocJson '$(printf '%s' "${DOC}")' -PlanContextJson '$(printf '%s' "${CTX}")'))
  ")"
  [ "${b}" = "${p}" ]
}
