#!/usr/bin/env bats
# T051 [US3] — Neutral content -> ADF rendering (FR-015, FR-016). Acceptance
# criteria render into a dedicated panel; Figma links and UX guidance render into
# a distinct Design section (heading + list). ADF construction lives in the SINK
# (Constitution VIII — ADF node names are Atlassian identifiers). The PowerShell
# port emits byte-identical ADF (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/adf.sh"
  # An existing human-origin description: a human paragraph, then a prior managed
  # panel (marker + stale body). Built here so adf_managed_marker is in scope.
  EXISTING_HUMAN="$(jq -cn --arg m "$(adf_managed_marker)" '
    {type:"doc", version:1, content:[
      {type:"paragraph", content:[{type:"text", text:"A note the PO wrote."}]},
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"paragraph", content:[{type:"text", text:"OLD MANAGED BODY"}]}
    ]}')"
}

CONTENT='{
  "description": {"blocks": [{"type":"paragraph","text":"The need statement."}]},
  "acceptance_criteria": [{"given":["a user"],"when":["they click"],"then":["it opens"]}],
  "design": [{"kind":"guidance","value":"Use the blue accent."},{"kind":"figma_link","label":"Board","value":"https://www.figma.com/file/abc"}]
}'

@test "renders a valid ADF doc envelope" {
  run adf_render_description "${CONTENT}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.type' <<< "$output")" = "doc" ]
  [ "$(jq -r '.version' <<< "$output")" = "1" ]
}

@test "description blocks render as paragraph nodes" {
  run adf_render_description "${CONTENT}"
  [ "$(jq '[.content[] | select(.type=="paragraph" and (.content[0].text=="The need statement."))] | length' <<< "$output")" -ge 1 ]
}

@test "acceptance criteria render into a dedicated panel with Given/When/Then (FR-015)" {
  run adf_render_description "${CONTENT}"
  [ "$(jq '[.content[] | select(.type=="panel")] | length' <<< "$output")" -eq 1 ]
  # The panel carries the Given/When/Then clauses.
  local panel
  panel="$(jq -c '.content[] | select(.type=="panel")' <<< "$output")"
  [[ "$(jq -r '[.content[].content[].text] | join("|")' <<< "$panel")" == *"Given a user"* ]]
  [[ "$(jq -r '[.content[].content[].text] | join("|")' <<< "$panel")" == *"When they click"* ]]
  [[ "$(jq -r '[.content[].content[].text] | join("|")' <<< "$panel")" == *"Then it opens"* ]]
}

@test "figma links and UX guidance render into a distinct Design section (FR-016)" {
  run adf_render_description "${CONTENT}"
  # A heading whose text is exactly "Design".
  [ "$(jq '[.content[] | select(.type=="heading" and (.content[0].text=="Design"))] | length' <<< "$output")" -eq 1 ]
  # The guidance text and the Figma link appear after the Design heading.
  [[ "$output" == *"Use the blue accent."* ]]
  [[ "$output" == *"https://www.figma.com/file/abc"* ]]
}

@test "no acceptance criteria => no panel node" {
  local c='{"description":{"blocks":[{"type":"paragraph","text":"x"}]}}'
  run adf_render_description "${c}"
  [ "$(jq '[.content[] | select(.type=="panel")] | length' <<< "$output")" -eq 0 ]
}

@test "a single content node still renders content as a JSON array, not a bare object, on both ports (regression, Phase 5 US2)" {
  # A specification with one overview paragraph and no acceptance criteria or
  # design — the parent's minimal case — renders exactly one content node.
  # A prior PowerShell defect returned the sole node as a scalar rather than
  # a one-element array (PowerShell's pipeline auto-unwrapping), producing
  # `"content":{...}` instead of `"content":[{...}]`.
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local c='{"description":{"blocks":[{"type":"paragraph","text":"Overview."}]}}'
  local b p
  b="$(adf_render_description "${c}")"
  [ "$(jq -r '.content | type' <<< "${b}")" = "array" ]
  p="$(pwsh -NoProfile -Command "Import-Module '${PS_SINK}/Adf.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraAdfDocument -ContentJson '${c}'))")"
  [ "${b}" = "${p}" ]
}

@test "the PowerShell port renders byte-identical ADF (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(adf_render_description "${CONTENT}")"
  p="$(pwsh -NoProfile -Command "Import-Module '${PS_SINK}/Adf.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraAdfDocument -ContentJson ([Console]::In.ReadToEnd())))" <<< "${CONTENT}")"
  [ "${b}" = "${p}" ]
}

# --- 018, T012: origin-independent managed description resolution (contract §3) ---

@test "row 5 — a creation with no existing description carries no prefix, no warning (FR-020)" {
  run adf_render_managed_description "${CONTENT}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
  local doc; doc="$(jq -c '.doc' <<< "$output")"
  [[ "$(jq -c '.' <<< "$doc")" == *"do not edit below this line"* ]]
  [[ "$(jq -c '.' <<< "$doc")" == *"The need statement."* ]]
  # The marker is the FIRST content node — no human prefix on a creation.
  [[ "$(jq -r '.content[0].content[0].text' <<< "$doc")" == *"do not edit below this line"* ]]
}

@test "row 2 — a well-formed boundary preserves the human prefix verbatim above a fresh managed panel (FR-007)" {
  run adf_render_managed_description "${CONTENT}" "${EXISTING_HUMAN}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
  local doc; doc="$(jq -c '.doc' <<< "$output")"
  [ "$(jq -r '.content[0].content[0].text' <<< "$doc")" = "A note the PO wrote." ]
  [[ "$(jq -c '.' <<< "$doc")" == *"do not edit below this line"* ]]
  [[ "$(jq -c '.' <<< "$doc")" != *"OLD MANAGED BODY"* ]]
  [[ "$(jq -c '.' <<< "$doc")" == *"The need statement."* ]]
}

@test "row 1 — more than one delimiter is malformed: no doc, status malformed (FR-012)" {
  local malformed; malformed="$(jq -cn --arg m "$(adf_managed_marker)" '
    {type:"doc", version:1, content:[
      {type:"paragraph", content:[{type:"text", text:"Human note."}]},
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"paragraph", content:[{type:"text", text:"body one"}]},
      {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
      {type:"paragraph", content:[{type:"text", text:"body two"}]}
    ]}')"
  run adf_render_managed_description "${CONTENT}" "${malformed}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "malformed" ]
  [ "$(jq -r 'has("doc")' <<< "$output")" = "false" ]
}

@test "row 3 — clean migration: existing ends with the freshly rendered managed nodes, no duplication (FR-020a)" {
  local managed pre_release
  managed="$(adf_render_description "${CONTENT}" | jq -c '.content')"
  pre_release="$(jq -cn --argjson c "${managed}" '{type:"doc", version:1, content:$c}')"
  run adf_render_managed_description "${CONTENT}" "${pre_release}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
  local doc; doc="$(jq -c '.doc' <<< "$output")"
  # Exactly one occurrence of the need statement — nothing duplicated.
  [ "$(jq -r '[.content[].content[]?.text? // empty] | map(select(. == "The need statement.")) | length' <<< "$doc")" -eq 1 ]
  [[ "$(jq -c '.' <<< "$doc")" == *"do not edit below this line"* ]]
}

@test "row 4 — ambiguous migration preserves everything and warns by status (FR-020b)" {
  local unrelated; unrelated="$(jq -cn '{type:"doc", version:1, content:[{type:"paragraph", content:[{type:"text", text:"unrelated prior content"}]}]}')"
  run adf_render_managed_description "${CONTENT}" "${unrelated}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "migrated-warned" ]
  local doc; doc="$(jq -c '.doc' <<< "$output")"
  [[ "$(jq -c '.' <<< "$doc")" == *"unrelated prior content"* ]]
  [[ "$(jq -c '.' <<< "$doc")" == *"do not edit below this line"* ]]
  [[ "$(jq -c '.' <<< "$doc")" == *"The need statement."* ]]
}

@test "re-rendering with unchanged managed content reproduces it byte-for-byte (idempotent)" {
  local once twice once_doc
  once="$(adf_render_managed_description "${CONTENT}" "${EXISTING_HUMAN}")"
  once_doc="$(jq -c '.doc' <<< "${once}")"
  twice="$(adf_render_managed_description "${CONTENT}" "${once_doc}")"
  [ "$(jq -r '.status' <<< "${twice}")" = "ok" ]
  [ "${once_doc}" = "$(jq -c '.doc' <<< "${twice}")" ]
}

@test "the managed description resolution renders byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(adf_render_managed_description "${CONTENT}" "${EXISTING_HUMAN}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/Adf.psm1' -Force
    \$c = [Console]::In.ReadToEnd()
    [Console]::Out.Write((ConvertTo-JiraManagedAdfDocument -ContentJson \$c -ExistingJson '$(printf '%s' "${EXISTING_HUMAN}")'))
  " <<< "${CONTENT}")"
  [ "${b}" = "${p}" ]
}
