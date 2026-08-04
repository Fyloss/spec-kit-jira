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
# The sink may consume the neutral engine (the boundary only forbids engine->sink).
# shellcheck source=/dev/null
source "${_adf_dir}/../../engine/managed_section.sh"

# _adf_blocks_to_nodes <blocks-json> — render neutral content blocks to ADF
# nodes. panel_ref blocks are dropped here: the sink appends the acceptance and
# design sections deterministically after the description body.
_adf_blocks_to_nodes() {
  # kcov-excl-start — jq literal (string lines are not statements)
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
  # kcov-excl-stop
}

# _adf_gherkin_panel <ac-json> — a dedicated info panel carrying each scenario's
# Given/When/Then clauses as paragraphs (FR-015). Empty when there is no AC.
_adf_gherkin_panel() {
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c '
    if length == 0 then empty else
    {type:"panel", attrs:{panelType:"info"},
     content:[ .[] |
       ( (.given // [])[] | {type:"paragraph", content:[{type:"text", text:("Given " + .)}]}),
       ( (.when  // [])[] | {type:"paragraph", content:[{type:"text", text:("When " + .)}]}),
       ( (.then  // [])[] | {type:"paragraph", content:[{type:"text", text:("Then " + .)}]}) ]}
    end' <<< "$1"
  # kcov-excl-stop
}

# _adf_design_nodes <design-json> — a distinct Design section (FR-016): a level-3
# "Design" heading followed by a bullet list of guidance lines and Figma links.
# Empty when there is no design content.
_adf_design_nodes() {
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c '
    if length == 0 then empty else
    ( {type:"heading", attrs:{level:3}, content:[{type:"text", text:"Design"}]},
      {type:"bulletList",
       content:[ .[] |
         (if .kind == "figma_link" then ((.label // "Figma") + ": " + .value) else .value end) as $line
         | {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:$line}]}]} ]} )
    end' <<< "$1"
  # kcov-excl-stop
}

# _adf_content_nodes <content-json> — the managed content-node array for a story:
# description body, then the acceptance panel (with its heading), then the Design
# section, in that fixed order. This is the bridge-owned "managed section" — the
# whole description for a bridge-created ticket, or the region below the delimiter
# on a human-origin ticket.
_adf_content_nodes() {
  local content="$1" blocks ac design body panel design_nodes
  blocks="$(jq -c '.description.blocks // []' <<< "${content}")"
  ac="$(jq -c '.acceptance_criteria // []' <<< "${content}")"
  design="$(jq -c '.design // []' <<< "${content}")"

  body="$(_adf_blocks_to_nodes "${blocks}")"
  panel="$(_adf_gherkin_panel "${ac}")"
  design_nodes="$(_adf_design_nodes "${design}")"

  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn \
    --argjson body "${body}" \
    --argjson panel "${panel:-null}" \
    --argjson design "$(jq -cs '.' <<< "${design_nodes}")" '
    $body
    + (if $panel == null then []
       else [ {type:"heading", attrs:{level:3}, content:[{type:"text", text:"Acceptance Criteria"}]}, $panel ] end)
    + $design'
  # kcov-excl-stop
}

# adf_render_description <content-json> — render a story's neutral content into a
# single canonical ADF document. content-json carries `description` (content
# blocks) and the optional `acceptance_criteria` and `design` arrays.
adf_render_description() {
  jq -cn --argjson c "$(_adf_content_nodes "$1")" '{type:"doc", version:1, content:$c}' | json_canonical
}

# adf_managed_marker — the human-facing text that delimits the bridge-owned
# managed panel on a human-origin ticket (US7, FR-038). Passed to the neutral
# engine splice as a parameter (the engine never hard-codes it).
adf_managed_marker() {
  printf 'Synced from spec-kit — do not edit below this line'
}

# _adf_marker_nodes — the delimiter the managed section begins with: a single
# strong paragraph carrying the marker text. The marker MUST live in the FIRST
# managed node so the engine split re-attributes it (and everything below) to the
# managed section, leaving the human prefix untouched and stable on re-render.
_adf_marker_nodes() {
  jq -cn --arg m "$(adf_managed_marker)" \
    '[ {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]} ]'
}

# --- The task tier (Phase 3, US1, T036; contracts/task-tier.md §4) ----------
# The summary and description of a mirrored sub-task, derived from the task
# ALONE — never restating the story or the specification (FR-009).

: "${_ADF_TASK_SUMMARY_MAX:=255}"

# adf_task_summary <title> — the sub-task's summary: the task's own text,
# shortened DETERMINISTICALLY when it exceeds what the sink accepts (the
# same text always yielding the same summary). The untruncated text is
# never lost — it is the description's job to carry it (FR-008).
adf_task_summary() {
  local title="$1" max="${_ADF_TASK_SUMMARY_MAX}" len
  len="${#title}"
  if ((len <= max)); then
    printf '%s' "${title}"
  else
    printf '%s…' "${title:0:$((max - 1))}"
  fi
}

# adf_render_task_description <task-json> — the sub-task's description
# (contract §4, data-model.md §2): the task's own full (untruncated) text,
# then its identifier, phase, attribution, parallel-safety, files and
# dependencies as a bullet list. Nothing about the story or the
# specification is restated (FR-009).
adf_render_task_description() {
  local task="$1" title task_ref phase parallel files deps ordinal
  title="$(jq -r '.title' <<< "${task}")"
  task_ref="$(jq -r '.task_ref' <<< "${task}")"
  phase="$(jq -r '.phase // ""' <<< "${task}")"
  parallel="$(jq -r '.parallel' <<< "${task}")"
  files="$(jq -c '.files // []' <<< "${task}")"
  deps="$(jq -c '.depends_on // []' <<< "${task}")"
  ordinal="$(jq -r '.attribution.story_ordinal // empty' <<< "${task}")"

  local meta="[]"
  meta="$(jq -c --arg v "Identifier: ${task_ref}" '. + [$v]' <<< "${meta}")"
  [[ -n "${phase}" ]] && meta="$(jq -c --arg v "Phase: ${phase}" '. + [$v]' <<< "${meta}")"
  if [[ -n "${ordinal}" ]]; then
    meta="$(jq -c --arg v "Attribution: User Story ${ordinal}" '. + [$v]' <<< "${meta}")"
  else
    meta="$(jq -c --arg v "Attribution: none" '. + [$v]' <<< "${meta}")"
  fi
  if [[ "${parallel}" == "true" ]]; then
    meta="$(jq -c --arg v "Parallel-safe: yes" '. + [$v]' <<< "${meta}")"
  else
    meta="$(jq -c --arg v "Parallel-safe: no" '. + [$v]' <<< "${meta}")"
  fi
  if [[ "$(jq 'length' <<< "${files}")" -gt 0 ]]; then
    local files_csv; files_csv="$(jq -r 'join(", ")' <<< "${files}")"
    meta="$(jq -c --arg v "Files: ${files_csv}" '. + [$v]' <<< "${meta}")"
  fi
  if [[ "$(jq 'length' <<< "${deps}")" -gt 0 ]]; then
    local deps_csv; deps_csv="$(jq -r 'join(", ")' <<< "${deps}")"
    meta="$(jq -c --arg v "Depends on: ${deps_csv}" '. + [$v]' <<< "${meta}")"
  fi

  # kcov-excl-start — jq literal (string lines are not statements)
  local body
  body="$(jq -cn --arg t "${title}" --argjson meta "${meta}" '
    [ {type:"paragraph", content:[{type:"text", text:$t}]},
      {type:"bulletList", content:[ $meta[] | {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:.}]}]} ]} ]')"
  jq -cn --argjson c "${body}" '{type:"doc", version:1, content:$c}' | json_canonical
  # kcov-excl-stop
}

# adf_render_managed_description <content-json> <origin> [existing-desc-json]
#   Origin-discriminated description rendering (US7, T075). On a bridge-created
#   ticket the whole description IS the managed section, with no delimiter (FR-040).
#   On a human-origin ticket the human-authored prefix of the existing description
#   is preserved verbatim above a delimited managed panel (FR-038): the engine
#   splits the existing content at the marker, and the new description is
#   prefix + marker + freshly-rendered managed nodes.
adf_render_managed_description() {
  local content="$1" origin="$2" existing="${3:-}"
  local managed
  managed="$(_adf_content_nodes "${content}")"

  if [[ "${origin}" == "bridge-created" ]]; then
    jq -cn --argjson c "${managed}" '{type:"doc", version:1, content:$c}' | json_canonical
    return 0
  fi

  [[ -z "${existing}" ]] && existing='{}'
  local existing_content prefix marker_nodes
  existing_content="$(jq -c '.content // []' <<< "${existing}")"
  prefix="$(printf '%s' "${existing_content}" | managed_section_panel_split "$(adf_managed_marker)" | jq -c '.prefix')"
  marker_nodes="$(_adf_marker_nodes)"
  jq -cn --argjson p "${prefix}" --argjson m "${marker_nodes}" --argjson c "${managed}" \
    '{type:"doc", version:1, content: ($p + $m + $c)}' | json_canonical
}
