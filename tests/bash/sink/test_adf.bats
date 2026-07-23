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
