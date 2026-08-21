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
# shellcheck source=/dev/null
source "${_adf_dir}/../../engine/markdown.sh"

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
  local content="$1" mode="${2:-off}" blocks ac design body panel design_nodes checklist
  blocks="$(jq -c '.description.blocks // []' <<< "${content}")"
  ac="$(jq -c '.acceptance_criteria // []' <<< "${content}")"
  design="$(jq -c '.design // []' <<< "${content}")"

  body="$(_adf_blocks_to_nodes "${blocks}")"
  panel="$(_adf_gherkin_panel "${ac}")"
  design_nodes="$(_adf_design_nodes "${design}")"
  # 022, contract §1: appended LAST, and only in checklist mode — every
  # existing call site (mode defaulting to "off") stays byte-identical.
  checklist="[]"
  [[ "${mode}" == "checklist" ]] && checklist="$(_adf_checklist_nodes "${content}")"

  # kcov-excl-start — jq literal (string lines are not statements)
  # 022: a story's checklist is unbounded — one entry per task — so $checklist
  # (and with it $body) can pass Linux's 128 KiB per-argument cap, which macOS
  # does not have. json_build keeps every value out of argv (lib/output.sh).
  # The filter text is unchanged: the success path stays byte-for-byte frozen.
  # shellcheck disable=SC2016  # a jq filter: $body/$panel/$design/$checklist are jq variables
  json_build '
    $body
    + (if $panel == null then []
       else [ {type:"heading", attrs:{level:3}, content:[{type:"text", text:"Acceptance Criteria"}]}, $panel ] end)
    + $design
    + $checklist' \
    body "${body}" \
    panel "${panel:-null}" \
    design "$(jq -cs '.' <<< "${design_nodes}")" \
    checklist "${checklist}"
  # kcov-excl-stop
}

# _adf_checklist_nodes <content-json> — a story's tasks rendered as one
# checklist section (022, contracts/checklist-rendering.md §2-4): one `Tasks`
# heading, one group per phase in first-appearance order, entries in
# document order, a leading no-phase group carrying no phase paragraph.
# Candidate B (research §1): the existing bulletList/listItem pair, each
# entry's first span a state glyph — no node carries an identity attribute.
# `[]` when there is no attributed task at all (FR-021: no heading, no empty
# list).
_adf_checklist_nodes() {
  local content="$1" tasks
  tasks="$(jq -c '.tasks // []' <<< "${content}")"
  [[ "${tasks}" == "[]" ]] && { printf '[]'; return 0; }

  # 024, contracts/spawn-budget.md C1.2/C1.3: one jq call decodes every
  # task's title/done/phase at once (a per-task loop used to cost four `jq`
  # reads plus a fifth to re-parse-and-append the growing `entries` array —
  # the same O(n^2) accumulator pattern already fixed in parse.sh/
  # recognition.sh/plan_apply.sh). `markdown_tokenize_inline` is pure bash
  # (no subprocess) so it stays a per-task call; the JSON fragment it feeds
  # is built natively (`_md_json_escape`, already sourced via
  # engine/markdown.sh) rather than through one more `jq` per task.
  local _acn_sep=$'\x1f'
  local -a entries_arr=()
  local _acn_title _acn_done _acn_phase
  while IFS="${_acn_sep}" read -r _acn_title _acn_done _acn_phase; do
    local spans; spans="$(markdown_tokenize_inline "${_acn_title}")"
    entries_arr+=("{\"spans\":${spans},\"done\":${_acn_done},\"phase\":\"$(_md_json_escape "${_acn_phase}")\"}")
  done < <(jq -r --arg sep "${_acn_sep}" '.[] | [.title, (.done | tostring), (.phase // "")] | join($sep)' <<< "${tasks}")

  local entries; entries="$(printf '%s\n' "${entries_arr[@]}" | jq -cs '.')"

  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c "${_ADF_MARK_DEFS_JQ}"'
    def first_seen_order: reduce .[] as $p ([]; if index($p) then . else . + [$p] end);
    . as $entries
    | ($entries | map(select(.phase == ""))) as $nophase
    | ($entries | map(select(.phase != ""))) as $phased
    | ($phased | map(.phase) | first_seen_order) as $phase_order
    | ( (if ($nophase|length) > 0 then [{phase:null, entries:$nophase}] else [] end)
        + [ $phase_order[] as $ph | {phase:$ph, entries:($phased | map(select(.phase == $ph)))} ] ) as $groups
    | [{type:"heading", attrs:{level:3}, content:[{type:"text", text:"Tasks"}]}]
      + [ $groups[] |
          ( if .phase != null then {type:"paragraph", content:[{type:"text", text:.phase, marks:[{type:"strong"}]}]} else empty end ),
          {type:"bulletList", content:[ .entries[] |
            {type:"listItem", content:[{type:"paragraph",
               content: ([{type:"text", text:(if .done then "☑ " else "☐ " end)}] + (.spans|spans_to_adf))
            }]}
          ]}
        ]' <<< "${entries}"
  # kcov-excl-stop
}

# adf_render_description <content-json> — render a story's neutral content into a
# single canonical ADF document. content-json carries `description` (content
# blocks) and the optional `acceptance_criteria` and `design` arrays.
adf_render_description() {
  local nodes doc rc=0
  nodes="$(_adf_content_nodes "$1")" || return $?
  # The nodes carry the checklist, so they too can pass the 128 KiB cap. The
  # result is captured rather than piped straight into json_canonical, which
  # writes nothing and exits 0 on empty input — piping would turn a failed
  # render into a silent empty description on the write path.
  # shellcheck disable=SC2016  # a jq filter: $c is a jq variable
  doc="$(json_build '{type:"doc", version:1, content:$c}' c "${nodes}")" || rc=$?
  ((rc == 0)) || return "${rc}"
  printf '%s' "${doc}" | json_canonical
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
#
# The body comes from `.description.blocks` through the SAME neutral-block
# renderer the story tier uses, so a task's markup renders as marks rather than
# surviving as punctuation (016, FR-017). The metadata bullets below are
# composed by the bridge, not written by an author, and stay plain text
# (FR-018) — `Files:` in particular carries paths the task parser already
# extracted from inside their backticks.
adf_render_task_description() {
  local task="$1" blocks task_ref phase parallel files deps ordinal
  blocks="$(jq -c '.description.blocks // []' <<< "${task}")"
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

  local body_nodes; body_nodes="$(_adf_blocks_to_nodes "${blocks}")"

  # kcov-excl-start — jq literal (string lines are not statements)
  local body
  body="$(jq -cn --argjson body "${body_nodes}" --argjson meta "${meta}" '
    $body
    + [ {type:"bulletList", content:[ $meta[] | {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:.}]}]} ]} ]')"
  jq -cn --argjson c "${body}" '{type:"doc", version:1, content:$c}' | json_canonical
  # kcov-excl-stop
}

# _adf_translate_origin <origin>
#   019, contracts/ownership-decision.md §2: the sink-side, total translation
#   from the ticket's recorded origin to the engine's neutral ownership
#   vocabulary. `bridge` (the mirror created it) -> self; `human` (adopted via
#   mention) -> other; anything else, including empty and absent -> unknown
#   (FR-004; R3 — not reachable through any shipping code path, but built
#   because the recorded property could in principle be hand-edited).
_adf_translate_origin() {
  case "${1:-}" in
    bridge) printf 'self' ;;
    human) printf 'other' ;;
    *) printf 'unknown' ;;
  esac
}

# _adf_resolve_managed <managed-nodes-json> [existing-desc-json] [origin]
#   The shared contract §3 resolution engine (018, T014/T026; 019, T012,
#   data-model.md §3), independent of what produced the managed-node array —
#   the same decision serves the story/parent shape (_adf_content_nodes) and
#   the task tier's own shape (adf_render_task_description) identically:
#     - No existing-desc-json argument at all: a CREATION. No prior content to
#       preserve; the result is marker ++ freshly-rendered managed nodes, with
#       no human prefix and no warning (contract §3 row 5).
#     - Otherwise, `origin` is translated to the engine's ownership vocabulary
#       (_adf_translate_origin) and the whole marker-count-then-ownership
#       decision is delegated to managed_section_ownership_split (019, T006):
#       marker_count > 1 is malformed (row 1); marker_count == 1 keeps the
#       existing prefix verbatim (row 2); marker_count == 0 and ownership
#       self replaces the whole existing description (row 3, the fix,
#       FR-002); ownership other reuses today's suffix-split behaviour
#       unmodified (row 4); ownership unknown preserves the whole existing
#       content and reports "migrated-warned" (row 5, FR-004) — nothing is
#       ever discarded (FR-020a/FR-020b).
#   Prints canonical {status:"ok"|"malformed"|"migrated-warned", doc:<adf-doc>}
#   — `doc` is present on every status except "malformed".
_adf_resolve_managed() {
  local managed="$1" existing="${2:-}" origin="${3:-}"
  local marker marker_nodes
  marker="$(adf_managed_marker)"
  marker_nodes="$(_adf_marker_nodes)"

  if [[ -z "${existing}" ]]; then
    # $managed carries the checklist — past the 128 KiB per-argument cap on a
    # large story. Captured, not piped, so a failure is not swallowed by
    # json_canonical's exit 0 on empty input.
    local fresh rc=0
    # shellcheck disable=SC2016  # a jq filter: $m/$c are jq variables
    fresh="$(json_build '{status:"ok", doc:{type:"doc", version:1, content: ($m + $c)}}' \
      m "${marker_nodes}" c "${managed}")" || rc=$?
    ((rc == 0)) || return "${rc}"
    printf '%s' "${fresh}" | json_canonical
    return 0
  fi

  local ownership existing_content split status prefix
  ownership="$(_adf_translate_origin "${origin}")"
  existing_content="$(jq -c '.content // []' <<< "${existing}")"
  split="$(printf '%s' "${existing_content}" | managed_section_ownership_split "${marker}" "${managed}" "${ownership}")"
  status="$(jq -r '.status' <<< "${split}")"

  if [[ "${status}" == "malformed" ]]; then
    jq -cn '{status:"malformed"}' | json_canonical
    return 0
  fi

  prefix="$(jq -c '.prefix' <<< "${split}")"
  # $managed carries the checklist and $prefix the retained human text, so both
  # can pass the 128 KiB per-argument cap. $st is a short string and stays in
  # argv: this keeps the jq call and moves only the large values, which is the
  # shape #31 chose for a mixed call. Captured, not piped — see above.
  # Real files, NOT `<(…)`. A process substitution is an MSYS `/dev/fd/N`, and
  # the jq on PATH under git-bash is a native Windows binary that cannot open
  # one — measured as 103 of the 231 conformance scenarios failing on
  # windows-latest, all of them here (the `p_f` in "Bad JSON in --slurpfile
  # p_f /dev/fd/63"). json_path_arg spells the path for that jq.
  local spliced rc=0 _p_f _c_f
  _p_f="$(mktemp)"
  _c_f="$(mktemp)"
  printf '%s' "${prefix}" > "${_p_f}"
  printf '%s' "${managed}" > "${_c_f}"
  spliced="$(jq -cn \
    --slurpfile p_f "$(json_path_arg "${_p_f}")" \
    --argjson m "${marker_nodes}" \
    --slurpfile c_f "$(json_path_arg "${_c_f}")" \
    --arg st "${status}" \
    '($p_f[0]) as $p | ($c_f[0]) as $c |
     {status:$st, doc:{type:"doc", version:1, content: ($p + $m + $c)}}')" || rc=$?
  rm -f "${_p_f}" "${_c_f}"
  ((rc == 0)) || return "${rc}"
  printf '%s' "${spliced}" | json_canonical
}

# adf_render_managed_description <content-json> [existing-desc-json] [origin]
#   Description resolution for the story/parent shape (018, T014; 019, T012).
#   See _adf_resolve_managed for the contract §3 decision.
adf_render_managed_description() {
  local content="$1" existing="${2:-}" origin="${3:-}" mode="${4:-off}"
  local managed
  managed="$(_adf_content_nodes "${content}" "${mode}")"
  _adf_resolve_managed "${managed}" "${existing}" "${origin}"
}

# adf_render_managed_task_description <task-json> [existing-desc-json] [origin]
#   Description resolution for the task tier's own shape (018, T026, FR-006;
#   019, T030): the sub-task's description (adf_render_task_description — its
#   own text, identifier, phase, attribution, etc., never the story or the
#   specification, FR-009) is what the boundary now wraps, resolved through the
#   SAME §3 decision as every other tier.
adf_render_managed_task_description() {
  local task="$1" existing="${2:-}" origin="${3:-}"
  local managed
  managed="$(adf_render_task_description "${task}" | jq -c '.content')"
  _adf_resolve_managed "${managed}" "${existing}" "${origin}"
}

# _adf_checklist_normalise <nodes-json> — comparison-only normalisation
# (022, contract §5): strip attrs.localId from every checklist node and
# entry node, then the caller compares through json_canonical. A defensive
# no-op under the shipped candidate B (bulletList/listItem carry no
# identity attribute) — kept so a future move to candidate A is a one-file
# change, following _summary_normalise's "for COMPARISON only" precedent.
_adf_checklist_normalise() {
  jq -c '[ .[] | del(.attrs.localId) | if has("content") then .content |= map(del(.attrs.localId)) else . end ]' <<< "$1"
}

# _adf_checklist_nodes_digest <nodes-json> — git hash-object --no-filters
# over the canonical JSON of NORMALISED nodes. Empty input yields an empty
# digest — absence means "no record yet", never "empty checklist".
_adf_checklist_nodes_digest() {
  local nodes="$1"
  [[ "${nodes}" == "[]" ]] && { printf ''; return 0; }
  _adf_checklist_normalise "${nodes}" | json_canonical | git hash-object --no-filters --stdin 2> /dev/null
}

# adf_checklist_digest <content-json> — the identity-stamp digest (022,
# data-model.md §3): the digest of the story's DESIRED checklist nodes.
# Empty when the story has no attributed task at all — no digest is ever
# recorded for "no checklist" (absence means "no record yet", never "empty
# checklist").
adf_checklist_digest() {
  local content="$1" nodes
  nodes="$(_adf_checklist_nodes "${content}")"
  _adf_checklist_nodes_digest "${nodes}"
}

# _adf_checklist_slice <managed-nodes-json> — the checklist portion of an
# already-managed node array (022, contract §1/§5): everything from the
# 'Tasks' heading onward — appended LAST, so this is exactly the suffix
# starting at that heading, or [] when there is none.
_adf_checklist_slice() {
  local managed="$1"
  jq -c '
    . as $m
    | ([range(0; ($m|length))
        | select($m[.].type=="heading" and (($m[.].content[0].text? // "") == "Tasks"))][0]) as $idx
    | if $idx == null then [] else $m[$idx:] end
  ' <<< "${managed}"
}

# _adf_content_has_checklist <existing-doc-json> — true when a story's
# CURRENT description (the full `{type, version, content}` doc, as read by
# recognition) already carries a checklist section in its managed region
# (022, FR-034's reverse-switch report). No new Jira read: the caller
# already has this from recognition's own current-content fetch.
_adf_content_has_checklist() {
  local existing="${1:-{\}}"
  [[ -z "${existing}" || "${existing}" == "null" ]] && existing='{}'
  local managed
  managed="$(jq -c '.content // []' <<< "${existing}" | managed_section_panel_split "$(adf_managed_marker)" | jq -c '.managed')"
  local cl; cl="$(_adf_checklist_slice "${managed}")"
  [[ "$(jq 'length' <<< "${cl}")" -gt 0 ]] && printf 'true' || printf 'false'
}
