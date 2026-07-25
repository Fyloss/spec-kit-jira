#!/usr/bin/env bash
# engine/parse.sh — Neutral spec parser (US3, T054).
#
# Turns a specification document into the neutral content the interchange
# assembly (T055) wraps into a schema-validated neutral document. Every decision
# here is the ENGINE's (Constitution VIII): the deterministic title ladder
# (FR 013), the never-empty structured description (FR 014), Given/When/Then
# extraction (FR 015), the Design section (FR 016), the P1/P2/P3 priority
# (FR 017), and the declared estimation (FR 018). It carries ZERO Jira
# identifiers and never sources sink/: it emits logical, Jira-agnostic content;
# the sink renders it to ADF and resolves logical names to ids.
#
# All functions read the document on stdin and emit canonical JSON (or a plain
# string for the title). The PowerShell port (Parse.psm1) is byte-identical.

[[ -n ${_JIRA_ENGINE_PARSE:-} ]] && return 0
_JIRA_ENGINE_PARSE=1

_parse_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_parse_dir}/../lib/output.sh" # json_canonical only — lib/, never sink/

# _parse_trim <string> — strip leading and trailing whitespace.
_parse_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# _parse_strip_marker <string> — remove a leading list marker (- / * / "N.").
_parse_strip_marker() {
  local s="$1"
  if [[ "${s}" =~ ^([-*]|[0-9]+\.)[[:space:]]+(.*)$ ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  else
    printf '%s' "${s}"
  fi
}

# _parse_lines_to_json — read lines on stdin, emit a compact JSON array of the
# non-empty lines as strings ([] when none).
_parse_lines_to_json() {
  local acc="[]" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    acc="$(jq -c --arg v "${line}" '. + [$v]' <<< "${acc}")"
  done
  printf '%s' "${acc}"
}

# parse_title <folder-slug> — the deterministic title ladder (FR 013), first
# match wins: explicit `Title:` line -> first H1 -> user-story section title ->
# first non-empty paragraph -> humanised folder slug. NEVER a `## Summary`.
parse_title() {
  local slug="${1:-}" doc line
  doc="$(cat)"

  # 1. Explicit `Title:` line.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    if [[ "${line}" =~ ^[[:space:]]*Title:[[:space:]]*(.+)$ ]]; then
      _parse_trim "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "${doc}"

  # 2. First H1 (a single leading '#' followed by whitespace).
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    if [[ "${line}" =~ ^#[[:space:]]+(.+)$ ]]; then
      local h="${BASH_REMATCH[1]}"
      # Strip the spec-kit document label so the title is the feature name.
      if [[ "${h}" =~ ^Feature\ Specification:[[:space:]]*(.+)$ ]]; then h="${BASH_REMATCH[1]}"; fi
      _parse_trim "${h}"
      return 0
    fi
  done <<< "${doc}"

  # 3. First user-story section title (text before an optional Priority tag).
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    if [[ "${line}" =~ ^#{2,4}[[:space:]]+User\ Story[^-]*-[[:space:]]*(.+)$ ]]; then
      local t="${BASH_REMATCH[1]}"
      t="${t%%"(Priority:"*}"
      _parse_trim "${t}"
      return 0
    fi
  done <<< "${doc}"

  # 4. First non-empty paragraph (non-heading prose line).
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    local p; p="$(_parse_trim "${line}")"
    [[ -z "${p}" ]] && continue
    [[ "${p}" =~ ^# ]] && continue
    [[ "${p}" =~ ^Title: ]] && continue
    _parse_trim "$(_parse_strip_marker "${p}")"
    return 0
  done <<< "${doc}"

  # 5. Humanised folder slug (strip the NNN- prefix; separators -> spaces).
  local s="${slug}"
  s="${s#[0-9][0-9][0-9]-}"
  s="${s//-/ }"
  s="${s//_/ }"
  printf '%s' "${s}"
}

# parse_description_blocks — synthesise a never-empty structured description
# (FR 014). Collects the overview prose (up to two paragraphs) that precedes the
# first Acceptance/Design/Tasks/Scenario section; falls back to the H1 text and
# then a fixed sentence so the description is never empty, including for specs
# with no `## Summary` section (SC 002).
parse_description_blocks() {
  local doc line
  doc="$(cat)"

  local -a paras=()
  local para="" h1=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    local t; t="$(_parse_trim "${line}")"
    if [[ -z "${t}" ]]; then
      [[ -n "${para}" ]] && { paras+=("${para}"); para=""; }
      continue
    fi
    if [[ "${t}" =~ ^#{1,6}[[:space:]]+(.*)$ ]]; then
      local ht="${BASH_REMATCH[1]}"
      [[ -z "${h1}" && "${line}" =~ ^#[[:space:]] ]] && h1="$(_parse_trim "${ht#Feature Specification: }")"
      if [[ "${ht}" =~ ^(Acceptance|Design|Task|Scenario|Requirement|Success|Edge) ]]; then break; fi
      [[ -n "${para}" ]] && { paras+=("${para}"); para=""; }
      continue
    fi
    [[ "${t}" =~ ^Title: ]] && continue
    t="$(_parse_trim "$(_parse_strip_marker "${t}")")"
    if [[ -n "${para}" ]]; then para="${para} ${t}"; else para="${t}"; fi
  done <<< "${doc}"
  [[ -n "${para}" ]] && paras+=("${para}")

  # Never empty: fall back to the H1 text, then a fixed sentence.
  if ((${#paras[@]} == 0)); then
    if [[ -n "${h1}" ]]; then paras+=("${h1}"); else paras+=("This ticket tracks the linked specification."); fi
  fi

  # Keep at most the first two paragraphs (need statement + one context block).
  local blocks="[]" idx=0 p
  for p in "${paras[@]}"; do
    ((idx >= 2)) && break
    blocks="$(jq -c --arg t "${p}" '. + [{type:"paragraph", text:$t}]' <<< "${blocks}")"
    idx=$((idx + 1))
  done
  jq -cn --argjson b "${blocks}" '{blocks:$b}' | json_canonical
}

# parse_acceptance_criteria — extract Given/When/Then scenarios (FR 015) as a
# JSON array of {given[],when[],then[]}. Supports one-clause-per-line and inline
# single-line triples; And/But continuations append to the last-touched bucket.
# Only a scenario that reaches a Then is emitted.
parse_acceptance_criteria() {
  local doc line
  doc="$(cat)"

  local blocks="[]"
  local given="[]" when="[]" then="[]" have_then=0 last=""

  _parse_ac_flush() {
    if [[ "$(jq 'length' <<< "${then}")" -gt 0 ]]; then
      blocks="$(jq -c --argjson g "${given}" --argjson w "${when}" --argjson t "${then}" \
        '. + [{given:$g, when:$w, then:$t}]' <<< "${blocks}")"
    fi
    given="[]"; when="[]"; then="[]"; have_then=0; last=""
  }

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    local t; t="$(_parse_trim "${line}")"
    t="${t//\*\*/}"
    t="$(_parse_trim "$(_parse_strip_marker "${t}")")"
    [[ -z "${t}" ]] && continue

    # Inline triple on a single line. Prefer explicit clause boundaries
    # (", When" / ", Then") so a Given clause that itself contains the word
    # "when" survives intact; only a delimiter-free line falls back to the
    # first-keyword split. The regex lives in a variable (the reliable way to
    # feed ERE to bash =~).
    if [[ "${t}" =~ [Gg]iven[[:space:]] ]] && [[ "${t}" =~ [Ww]hen[[:space:]] ]] && [[ "${t}" =~ [Tt]hen[[:space:]] ]]; then
      _parse_ac_flush
      local rest gv wv tv
      local trip_re='[Gg]iven[[:space:]]+(.+)[,;][[:space:]]*[Ww]hen[[:space:]]+(.+)[,;][[:space:]]*[Tt]hen[[:space:]]+(.+)$'
      if [[ "${t}" =~ ${trip_re} ]]; then
        gv="${BASH_REMATCH[1]}"
        wv="${BASH_REMATCH[2]}"
        tv="${BASH_REMATCH[3]}"
      else
        rest="${t#*[Gg]iven }"
        gv="${rest%%[Ww]hen *}"
        rest="${rest#*[Ww]hen }"
        wv="${rest%%[Tt]hen *}"
        tv="${rest#*[Tt]hen }"
      fi
      given="$(jq -cn --arg v "$(_parse_trim "${gv}")" '[$v]')"
      when="$(jq -cn --arg v "$(_parse_trim "${wv}")" '[$v]')"
      then="$(jq -cn --arg v "$(_parse_trim "${tv}")" '[$v]')"
      _parse_ac_flush
      continue
    fi

    if [[ "${t}" =~ ^[Gg]iven[[:space:]]+(.+)$ ]]; then
      ((have_then)) && _parse_ac_flush
      given="$(jq -c --arg v "$(_parse_trim "${BASH_REMATCH[1]}")" '. + [$v]' <<< "${given}")"; last="g"
    elif [[ "${t}" =~ ^[Ww]hen[[:space:]]+(.+)$ ]]; then
      when="$(jq -c --arg v "$(_parse_trim "${BASH_REMATCH[1]}")" '. + [$v]' <<< "${when}")"; last="w"
    elif [[ "${t}" =~ ^[Tt]hen[[:space:]]+(.+)$ ]]; then
      then="$(jq -c --arg v "$(_parse_trim "${BASH_REMATCH[1]}")" '. + [$v]' <<< "${then}")"; have_then=1; last="t"
    elif [[ "${t}" =~ ^([Aa]nd|[Bb]ut)[[:space:]]+(.+)$ ]]; then
      local v; v="$(_parse_trim "${BASH_REMATCH[2]}")"
      case "${last}" in
        g) given="$(jq -c --arg v "${v}" '. + [$v]' <<< "${given}")" ;;
        w) when="$(jq -c --arg v "${v}" '. + [$v]' <<< "${when}")" ;;
        t) then="$(jq -c --arg v "${v}" '. + [$v]' <<< "${then}")" ;;
      esac
    fi
  done <<< "${doc}"
  _parse_ac_flush

  json_canonical <<< "${blocks}"
}

# parse_design — surface Figma links and Design-section UX guidance (FR 016) as
# a JSON array of {kind, value, label?}. Figma links (whole document, in order)
# come first, then guidance lines under a Design heading.
parse_design() {
  local doc line
  doc="$(cat)"

  local items="[]"

  # Figma links anywhere in the document (markdown [label](url) or bare url).
  # The regexes live in variables (the reliable way to feed ERE to bash =~).
  local md_re='\[([^]]+)\]\(([^)]+)\)'
  local bare_re='(https?://[^[:space:])]*figma\.com[^[:space:])]*)'
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    if [[ "${line}" =~ ${md_re} ]] && [[ "${BASH_REMATCH[2]}" == *figma.com* ]]; then
      items="$(jq -c --arg v "${BASH_REMATCH[2]}" --arg l "${BASH_REMATCH[1]}" \
        '. + [{kind:"figma_link", label:$l, value:$v}]' <<< "${items}")"
    elif [[ "${line}" =~ ${bare_re} ]]; then
      items="$(jq -c --arg v "${BASH_REMATCH[1]}" '. + [{kind:"figma_link", value:$v}]' <<< "${items}")"
    fi
  done <<< "${doc}"

  # Guidance lines under a Design heading (until a heading of the same or higher
  # level closes the section). Pure Figma-link lines are already captured above.
  local dlevel=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    local t; t="$(_parse_trim "${line}")"
    if [[ "${t}" =~ ^(#{1,6})[[:space:]]+(.*)$ ]]; then
      local hl="${#BASH_REMATCH[1]}" htext="${BASH_REMATCH[2]}"
      if [[ "${htext}" =~ [Dd]esign ]]; then
        dlevel="${hl}"
      elif ((dlevel > 0 && hl <= dlevel)); then
        dlevel=0
      fi
      continue
    fi
    if ((dlevel > 0)); then
      [[ -z "${t}" ]] && continue
      [[ "${t}" =~ figma\.com ]] && continue
      t="$(_parse_trim "$(_parse_strip_marker "${t}")")"
      [[ -z "${t}" ]] && continue
      items="$(jq -c --arg v "${t}" '. + [{kind:"guidance", value:$v}]' <<< "${items}")"
    fi
  done <<< "${doc}"

  json_canonical <<< "${items}"
}

# parse_priority — the spec's P1/P2/P3 priority (FR 017); defaults to P2 when
# none is declared.
parse_priority() {
  local doc; doc="$(cat)"
  if [[ "${doc}" =~ [Pp]riority:?[[:space:]]*P([123]) ]]; then
    printf 'P%s' "${BASH_REMATCH[1]}"
  else
    printf 'P2'
  fi
}

# parse_estimation — the declared estimation as a JSON number, or null (FR 018).
parse_estimation() {
  local doc; doc="$(cat)"
  if [[ "${doc}" =~ ([Ee]stimation|[Ee]stimate|[Ee]ffort|[Pp]oints)[[:space:]]*:[[:space:]]*([0-9]+(\.[0-9]+)?) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  else
    printf 'null'
  fi
}

# parse_story <folder-slug> <local-id> — assemble one neutral story from a
# section of the spec (stdin). Optional keys are omitted when empty so the
# neutral document stays minimal.
parse_story() {
  local slug="$1" local_id="$2" doc
  doc="$(cat)"

  local title desc ac design priority estimation
  title="$(printf '%s' "${doc}" | parse_title "${slug}")"
  desc="$(printf '%s' "${doc}" | parse_description_blocks)"
  ac="$(printf '%s' "${doc}" | parse_acceptance_criteria)"
  design="$(printf '%s' "${doc}" | parse_design)"
  priority="$(printf '%s' "${doc}" | parse_priority)"
  estimation="$(printf '%s' "${doc}" | parse_estimation)"

  jq -cn \
    --arg id "${local_id}" --arg title "${title}" \
    --argjson desc "${desc}" --argjson ac "${ac}" --argjson design "${design}" \
    --arg prio "${priority}" --argjson est "${estimation}" '
    {local_id:$id, title:$title, description:$desc, priority_logical:$prio}
    + (if ($ac | length) > 0 then {acceptance_criteria:$ac} else {} end)
    + (if ($design | length) > 0 then {design:$design} else {} end)
    + (if $est == null then {} else {estimation:$est} end)
  ' | json_canonical
}

# parse_spec <folder-slug> — parse a whole specification (stdin) into neutral
# content: one epic (title + description) plus one story per `User Story`
# section (or a single story when the spec has none).
parse_spec() {
  local slug="$1" doc line
  doc="$(cat)"

  local etitle edesc
  etitle="$(printf '%s' "${doc}" | parse_title "${slug}")"
  edesc="$(printf '%s' "${doc}" | parse_description_blocks)"

  # Split into user-story sections.
  local -a sections=()
  local cur="" in_story=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    local lc="${line%$'\r'}"
    if [[ "${lc}" =~ ^#{2,4}[[:space:]]+User\ Story ]]; then
      ((in_story)) && sections+=("${cur}")
      cur="${lc}"$'\n'; in_story=1
    elif ((in_story)); then
      cur+="${lc}"$'\n'
    fi
  done <<< "${doc}"
  ((in_story)) && sections+=("${cur}")

  local stories="[]" i=0 s story
  if ((${#sections[@]} == 0)); then
    story="$(printf '%s' "${doc}" | parse_story "${slug}" "s1")"
    stories="$(jq -c --argjson s "${story}" '. + [$s]' <<< "${stories}")"
  else
    for s in "${sections[@]}"; do
      i=$((i + 1))
      story="$(printf '%s' "${s}" | parse_story "${slug}" "s${i}")"
      stories="$(jq -c --argjson s "${story}" '. + [$s]' <<< "${stories}")"
    done
  fi

  jq -cn --arg et "${etitle}" --argjson ed "${edesc}" --argjson st "${stories}" \
    '{epic:{title:$et, description:$ed}, stories:$st}' | json_canonical
}
