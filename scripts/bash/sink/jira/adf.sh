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

# _ADF_MARK_DEFS_JQ — the neutral mark -> ADF mark map (research §1, feature
# 016). THE ONLY place ADF mark names may appear (Constitution VIII). Shared
# by every jq program below that renders spans.
# kcov-excl-start — jq literal (string lines are not statements)
_ADF_MARK_DEFS_JQ='
def marks_to_adf:
  map(
    if .kind == "bold" then {type:"strong"}
    elif .kind == "italic" then {type:"em"}
    elif .kind == "monospace" then {type:"code"}
    elif .kind == "strikethrough" then {type:"strike"}
    elif .kind == "link" then {type:"link", attrs:{href:.href}}
    else empty end
  );
def spans_to_adf:
  [ .[] | {type:"text", text:.text} + (if (.marks|length) > 0 then {marks:(.marks|marks_to_adf)} else {} end) ];
'
# kcov-excl-stop

# _adf_blocks_to_nodes <blocks-json> — render neutral content blocks to ADF
# nodes. panel_ref blocks are dropped here: the sink appends the acceptance and
# design sections deterministically after the description body. code stays a
# plain-string body (FR-007: no markup interpretation inside code).
_adf_blocks_to_nodes() {
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c "${_ADF_MARK_DEFS_JQ}"'
    [ .[] |
      if .type == "heading" then
        {type:"heading", attrs:{level:(.level // 3)}, content:((.spans // [])|spans_to_adf)}
      elif .type == "paragraph" then
        {type:"paragraph", content:((.spans // [])|spans_to_adf)}
      elif .type == "bullet_list" then
        {type:"bulletList", content:[ (.items // [])[] | {type:"listItem", content:[{type:"paragraph", content:(.|spans_to_adf)}]} ]}
      elif .type == "ordered_list" then
        {type:"orderedList", content:[ (.items // [])[] | {type:"listItem", content:[{type:"paragraph", content:(.|spans_to_adf)}]} ]}
      elif .type == "code" then
        {type:"codeBlock", content:(if (.text // "") == "" then [] else [{type:"text", text:.text}] end)}
      else empty end ]' <<< "$1"
  # kcov-excl-stop
}

# _adf_gherkin_panel <ac-json> — a dedicated info panel carrying each scenario's
# Given/When/Then clauses as paragraphs (FR-015). Each clause is an inline
# sequence (feature 016): the "Given "/"When "/"Then " prefix is a plain
# unmarked text node ahead of the clause's own tokenized spans. Empty when
# there is no AC.
_adf_gherkin_panel() {
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c "${_ADF_MARK_DEFS_JQ}"'
    if length == 0 then empty else
    {type:"panel", attrs:{panelType:"info"},
     content:[ .[] |
       ( (.given // [])[] | {type:"paragraph", content:([{type:"text", text:"Given "}] + (.|spans_to_adf))}),
       ( (.when  // [])[] | {type:"paragraph", content:([{type:"text", text:"When "}]  + (.|spans_to_adf))}),
       ( (.then  // [])[] | {type:"paragraph", content:([{type:"text", text:"Then "}]  + (.|spans_to_adf))}) ]}
    end' <<< "$1"
  # kcov-excl-stop
}

# _adf_design_nodes <design-json> — a distinct Design section (FR-016): a level-3
# "Design" heading followed by a bullet list of guidance lines and Figma links.
# guidance values are inline sequences (feature 016); figma_link stays a plain
# string URL (a URL is not prose) with its label prefixed as plain text. Empty
# when there is no design content.
_adf_design_nodes() {
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c "${_ADF_MARK_DEFS_JQ}"'
    if length == 0 then empty else
    ( {type:"heading", attrs:{level:3}, content:[{type:"text", text:"Design"}]},
      {type:"bulletList",
       content:[ .[] |
         if .kind == "figma_link" then
           {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:((.label // "Figma") + ": " + .value)}]}]}
         else
           {type:"listItem", content:[{type:"paragraph", content:(.value|spans_to_adf)}]}
         end ]} )
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

# _adf_resolve_managed <managed-nodes-json> [existing-desc-json]
#   The shared contract §3 resolution engine (018, T014/T026, data-model.md
#   §3), independent of what produced the managed-node array — the same
#   decision serves the story/parent shape (_adf_content_nodes) and the task
#   tier's own shape (adf_render_task_description) identically:
#     - No existing-desc-json argument at all: a CREATION. No prior content to
#       preserve; the result is marker ++ freshly-rendered managed nodes, with
#       no human prefix and no warning (contract §3 row 5).
#     - marker_count > 1 (managed_section_panel_split): malformed — the split
#       cannot tell which region is the mirror's, so nothing is written for
#       this description (row 1). Status "malformed", no `doc` key.
#     - marker_count == 1: well-formed. The existing prefix is preserved
#       verbatim above a freshly-rendered managed panel (row 2).
#     - marker_count == 0: a description written before this feature, or with
#       no boundary at all. managed_section_suffix_split (the migration split,
#       T010/T011) decides whether the existing content ends with the freshly
#       rendered managed nodes: a match is a clean migration with nothing
#       duplicated (row 3); no match preserves the WHOLE existing content as
#       human text above a fresh panel and reports "migrated-warned" so the
#       caller can name the ticket in a warning (row 4) — nothing is ever
#       discarded (FR-020a/FR-020b).
#   Prints canonical {status:"ok"|"malformed"|"migrated-warned", doc:<adf-doc>}
#   — `doc` is present on every status except "malformed".
_adf_resolve_managed() {
  local managed="$1" existing="${2:-}"
  local marker marker_nodes
  marker="$(adf_managed_marker)"
  marker_nodes="$(_adf_marker_nodes)"

  if [[ -z "${existing}" ]]; then
    jq -cn --argjson m "${marker_nodes}" --argjson c "${managed}" \
      '{status:"ok", doc:{type:"doc", version:1, content: ($m + $c)}}' | json_canonical
    return 0
  fi

  local existing_content split marker_count prefix status="ok"
  existing_content="$(jq -c '.content // []' <<< "${existing}")"
  split="$(printf '%s' "${existing_content}" | managed_section_panel_split "${marker}")"
  marker_count="$(jq -r '.marker_count' <<< "${split}")"

  if ((marker_count > 1)); then
    jq -cn '{status:"malformed"}' | json_canonical
    return 0
  elif ((marker_count == 1)); then
    prefix="$(jq -c '.prefix' <<< "${split}")"
  else
    local suffix matched
    suffix="$(printf '%s' "${existing_content}" | managed_section_suffix_split "${managed}")"
    matched="$(jq -r '.matched' <<< "${suffix}")"
    prefix="$(jq -c '.prefix' <<< "${suffix}")"
    [[ "${matched}" != "true" ]] && status="migrated-warned"
  fi

  jq -cn --argjson p "${prefix}" --argjson m "${marker_nodes}" --argjson c "${managed}" --arg st "${status}" \
    '{status:$st, doc:{type:"doc", version:1, content: ($p + $m + $c)}}' | json_canonical
}

# adf_render_managed_description <content-json> [existing-desc-json]
#   Origin-INDEPENDENT description resolution for the story/parent shape (018,
#   T014). See _adf_resolve_managed for the contract §3 decision.
adf_render_managed_description() {
  local content="$1" existing="${2:-}"
  local managed
  managed="$(_adf_content_nodes "${content}")"
  _adf_resolve_managed "${managed}" "${existing}"
}

# adf_render_managed_task_description <task-json> [existing-desc-json]
#   Origin-INDEPENDENT description resolution for the task tier's own shape
#   (018, T026, FR-006): the sub-task's description (adf_render_task_description
#   — its own text, identifier, phase, attribution, etc., never the story or the
#   specification, FR-009) is what the boundary now wraps, resolved through the
#   SAME §3 decision as every other tier.
adf_render_managed_task_description() {
  local task="$1" existing="${2:-}"
  local managed
  managed="$(adf_render_task_description "${task}" | jq -c '.content')"
  _adf_resolve_managed "${managed}" "${existing}"
}
