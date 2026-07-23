#!/usr/bin/env bats
# T051 [US3] — Neutral content -> ADF rendering (FR-015, FR-016). Acceptance
# criteria render into a dedicated panel; Figma links and UX guidance render into
# a distinct Design section (heading + list). ADF construction lives in the SINK
# (Constitution VIII — ADF node names are Atlassian identifiers). The PowerShell
# port emits byte-identical ADF (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/.specify/extensions/jira/scripts/powershell/sink/jira"
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

@test "the PowerShell port renders byte-identical ADF (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(adf_render_description "${CONTENT}")"
  p="$(pwsh -NoProfile -Command "Import-Module '${PS_SINK}/Adf.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraAdfDocument -ContentJson ([Console]::In.ReadToEnd())))" <<< "${CONTENT}")"
  [ "${b}" = "${p}" ]
}

# --- US7 (T075): origin-discriminated managed description --------------------

@test "bridge-created origin renders the whole description as the managed section, no delimiter (FR-040)" {
  run adf_render_managed_description "${CONTENT}" "bridge-created" '{}'
  [ "$status" -eq 0 ]
  # No marker paragraph is present when the bridge owns the whole description.
  [[ "$output" != *"do not edit below this line"* ]]
  [ "$(jq -r '.type' <<< "$output")" = "doc" ]
}

@test "human origin preserves the human prefix verbatim above a delimited managed panel (FR-038)" {
  run adf_render_managed_description "${CONTENT}" "human" "${EXISTING_HUMAN}"
  [ "$status" -eq 0 ]
  # The human's line survives, the stale managed body is gone, the marker delimits.
  [ "$(jq -r '.content[0].content[0].text' <<< "$output")" = "A note the PO wrote." ]
  [[ "$output" == *"do not edit below this line"* ]]
  [[ "$output" != *"OLD MANAGED BODY"* ]]
  [[ "$output" == *"The need statement."* ]]
}

@test "re-rendering a human description with unchanged managed content reproduces it byte-for-byte (idempotent)" {
  # First render onto the existing human doc; then feed that result back in.
  local once twice
  once="$(adf_render_managed_description "${CONTENT}" "human" "${EXISTING_HUMAN}")"
  twice="$(adf_render_managed_description "${CONTENT}" "human" "${once}")"
  [ "${once}" = "${twice}" ]
}

@test "the managed description renders byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(adf_render_managed_description "${CONTENT}" "human" "${EXISTING_HUMAN}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/Adf.psm1' -Force
    \$c = [Console]::In.ReadToEnd()
    [Console]::Out.Write((ConvertTo-JiraManagedAdfDocument -ContentJson \$c -Origin 'human' -ExistingJson '$(printf '%s' "${EXISTING_HUMAN}")'))
  " <<< "${CONTENT}")"
  [ "${b}" = "${p}" ]
}
