#!/usr/bin/env bash
# sink/jira/adf.sh — Neutral content -> Atlassian Document Format (US3, T056).
#
# ADF is the required rich-content format for the Jira Cloud REST v3 description
# field (research §6). This renderer is the ONLY place ADF node names live: the
# engine emits neutral, Jira-agnostic content blocks and the sink turns them into
# ADF here (Constitution VIII — ADF node names are Atlassian identifiers, so this
# file is the sink layer and NEVER the engine).
#
# It maps:
#   - description content blocks (heading / paragraph / bullet_list / code) -> ADF
#   - acceptance_criteria (Given/When/Then) -> a dedicated info panel (FR-015)
#   - design (Figma links + UX guidance)   -> a distinct Design section (FR-016)
#
# Output is the canonical ADF document; the PowerShell port (Adf.psm1) emits
# byte-identical bytes (NFR-1).

[[ -n ${_JIRA_SINK_ADF:-} ]] && return 0
_JIRA_SINK_ADF=1

_adf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_adf_dir}/../../lib/output.sh"

# _adf_blocks_to_nodes <blocks-json> — render neutral content blocks to ADF
# nodes. panel_ref blocks are dropped here: the sink appends the acceptance and
# design sections deterministically after the description body.
_adf_blocks_to_nodes() {
  jq -c '[ .[] |
    if .type == "heading" then
      {type:"heading", attrs:{level:(.level // 3)}, content:[{type:"text", text:(.text // "")}]}
    elif .type == "paragraph" then
      {type:"paragraph", content:(if (.text // "") == "" then [] else [{type:"text", text:.text}] end)}
    elif .type == "bullet_list" then
      {type:"bulletList", content:[ (.items // [])[] | {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:.}]}]} ]}
    elif .type == "code" then
      {type:"codeBlock", content:(if (.text // "") == "" then [] else [{type:"text", text:.text}] end)}
    else empty end ]' <<< "$1"
}

# _adf_gherkin_panel <ac-json> — a dedicated info panel carrying each scenario's
# Given/When/Then clauses as paragraphs (FR-015). Empty when there is no AC.
_adf_gherkin_panel() {
  jq -c '
    if length == 0 then empty else
    {type:"panel", attrs:{panelType:"info"},
     content:[ .[] |
       ( (.given // [])[] | {type:"paragraph", content:[{type:"text", text:("Given " + .)}]}),
       ( (.when  // [])[] | {type:"paragraph", content:[{type:"text", text:("When " + .)}]}),
       ( (.then  // [])[] | {type:"paragraph", content:[{type:"text", text:("Then " + .)}]}) ]}
    end' <<< "$1"
}

# _adf_design_nodes <design-json> — a distinct Design section (FR-016): a level-3
# "Design" heading followed by a bullet list of guidance lines and Figma links.
# Empty when there is no design content.
_adf_design_nodes() {
  jq -c '
    if length == 0 then empty else
    ( {type:"heading", attrs:{level:3}, content:[{type:"text", text:"Design"}]},
      {type:"bulletList",
       content:[ .[] |
         (if .kind == "figma_link" then ((.label // "Figma") + ": " + .value) else .value end) as $line
         | {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:$line}]}]} ]} )
    end' <<< "$1"
}

# adf_render_description <content-json> — render a story's neutral content into a
# single canonical ADF document. content-json carries `description` (content
# blocks) and the optional `acceptance_criteria` and `design` arrays.
adf_render_description() {
  local content="$1"
  local blocks ac design body panel design_nodes

  blocks="$(jq -c '.description.blocks // []' <<< "${content}")"
  ac="$(jq -c '.acceptance_criteria // []' <<< "${content}")"
  design="$(jq -c '.design // []' <<< "${content}")"

  body="$(_adf_blocks_to_nodes "${blocks}")"
  panel="$(_adf_gherkin_panel "${ac}")"
  design_nodes="$(_adf_design_nodes "${design}")"

  # Assemble the doc content in a fixed order: description body, then the
  # acceptance panel (with its heading), then the Design section.
  jq -cn \
    --argjson body "${body}" \
    --argjson panel "${panel:-null}" \
    --argjson design "$(jq -cs '.' <<< "${design_nodes}")" '
    { type:"doc", version:1,
      content: (
        $body
        + (if $panel == null then []
           else [ {type:"heading", attrs:{level:3}, content:[{type:"text", text:"Acceptance Criteria"}]}, $panel ] end)
        + $design
      ) }' | json_canonical
}
