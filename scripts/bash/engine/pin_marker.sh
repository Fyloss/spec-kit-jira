#!/usr/bin/env bash
# engine/pin_marker.sh — The pinning marker: grammar, placement, the
# four-property validation, and consume-at-binding replacement (027,
# research R3, contracts/pin-marker.md).
#
# ENGINE module: handles an OPAQUE ticket string, exactly as story_marker.sh
# does with `ticket=` — it never validates a key's shape (that is
# sink/jira/designator.sh's job, upstream), so it carries no tracker
# vocabulary and stays clean under Constitution VIII's boundary grep.
#
# Reuses marker_splice.sh's byte-preserving splice and story_marker.sh's
# `_smk_scan_anchors` heading scan and `_smk_trim` — a second marker key
# never duplicates either.

[[ -n ${_JIRA_ENGINE_PIN_MARKER:-} ]] && return 0
_JIRA_ENGINE_PIN_MARKER=1

_pin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_pin_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_pin_dir}/marker_splice.sh"
# shellcheck source=/dev/null
source "${_pin_dir}/story_marker.sh" # _smk_scan_anchors, _smk_trim

# pin_marker_format <key> — §2, the written form. Exactly one space between
# tokens, matching story_marker_format's "written" form.
pin_marker_format() {
  printf '<!-- speckit-jira pin=%s -->' "$1"
}

# pin_marker_parse_line <line> — §3 grammar. A `story=`, `spec=`, or `task=`
# body is a DIFFERENT marker and falls through to "none" here BY
# CONSTRUCTION: the regex below matches only a body starting `pin=`, exactly
# as spec_marker.sh documents for `story=`. Canonical JSON:
#   {"kind":"none"}
#   {"kind":"valid","key":".."}
#   {"kind":"malformed"}
pin_marker_parse_line() {
  local raw="$1" line t
  line="${raw%$'\r'}"
  t="$(_smk_trim "${line}")"

  local generic_re='^<!--[[:space:]]+speckit-jira[[:space:]]+(.*)-->[[:space:]]*$'
  if [[ ! "${t}" =~ ${generic_re} ]]; then
    printf '{"kind":"none"}'
    return 0
  fi
  local body="${BASH_REMATCH[1]}"
  body="$(_smk_trim "${body}")"

  local pin_re='^pin=(.*)$'
  if [[ ! "${body}" =~ ${pin_re} ]]; then
    printf '{"kind":"none"}'
    return 0
  fi
  local val="${BASH_REMATCH[1]}"
  if [[ -z "${val}" || "${val}" =~ [[:space:]] ]]; then
    printf '{"kind":"malformed"}'
    return 0
  fi
  jq -cn --arg k "${val}" '{kind:"valid", key:$k}' | json_canonical
}

# pin_marker_anchors <content> — §4 placement: one line number per
# `_smk_scan_anchors` result, verbatim (the `^#{2,4}\s+User Story` heading
# scan, falling back to the document's first H1, falling back to "0").
pin_marker_anchors() {
  _smk_scan_anchors "$1"
}

# pin_marker_validate <spec-path> <ordered-designator-keys-json> — §5, FR-058:
# reads THE PINNING MARKERS AND NOTHING ELSE, in a single pass over the
# file, then compares against the designator array in memory (R10 — no
# per-key grep). Prints a canonical JSON array of violations, one entry per
# offence, empty when all four properties hold:
#   {"kind":"missing","key":".."}                  — P1: key dropped
#   {"kind":"orphan","key":"..","lines":[N,...]}    — P2: marker names no designated key
#   {"kind":"split","key":"..","lines":[N,M]}       — P3: same key, two+ markers
#   {"kind":"merge","lines":[N,M]}                  — P3: one story, two+ markers
#   {"kind":"malformed","line":N}                   — a pin= line with a bad shape
#   {"kind":"reorder"}                              — P4: file order != designator order
pin_marker_validate() {
  local spec_path="$1" designators_json="$2" content
  content="$(cat "${spec_path}" 2> /dev/null; printf x)"; content="${content%x}"

  local -a anchors=()
  while IFS= read -r a; do anchors+=("${a}"); done < <(pin_marker_anchors "${content}")
  local n=${#anchors[@]}
  local total_lines
  total_lines="$(marker_splice_line_count "${content}")"

  # Single pass: collect every marker attempt (valid or malformed) with its
  # line number.
  local -a marker_lines=() marker_keys=() marker_malformed=()
  local lineno=0 line info kind
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    info="$(pin_marker_parse_line "${line}")"
    [[ "${info}" == '{"kind":"none"}' ]] && continue
    kind="$(jq -r '.kind' <<< "${info}")"
    marker_lines+=("${lineno}")
    if [[ "${kind}" == "valid" ]]; then
      marker_keys+=("$(jq -r '.key' <<< "${info}")")
      marker_malformed+=("false")
    else
      marker_keys+=("")
      marker_malformed+=("true")
    fi
  done <<< "${content}"

  # Which story-section index (into `anchors`) each marker line falls in,
  # for merge detection — -1 when it falls in none (should not occur, since
  # every marker line is necessarily inside some span, including the
  # implicit "before line 1" span when there are no anchors at all).
  local -a marker_section=()
  local mi
  for mi in "${!marker_lines[@]}"; do
    local m="${marker_lines[mi]}" sec=-1 i
    for ((i = 0; i < n; i++)); do
      local a="${anchors[i]}" span_start span_end
      if ((a == 0)); then span_start=1; else span_start=$((a + 1)); fi
      if ((i + 1 < n)); then span_end=$((anchors[i + 1] - 1)); else span_end="${total_lines}"; fi
      if ((m >= span_start && m <= span_end)); then
        sec=${i}
        break
      fi
    done
    marker_section+=("${sec}")
  done

  local violations='[]'

  # malformed
  for mi in "${!marker_lines[@]}"; do
    if [[ "${marker_malformed[mi]}" == "true" ]]; then
      violations="$(jq -c --argjson ln "${marker_lines[mi]}" '. + [{kind:"malformed", line:$ln}]' <<< "${violations}")"
    fi
  done

  # missing (P1): a designated key with zero valid markers.
  local dcount di
  dcount="$(jq 'length' <<< "${designators_json}")"
  for ((di = 0; di < dcount; di++)); do
    local dk found=0 mj
    dk="$(jq -r ".[${di}]" <<< "${designators_json}")"
    for mj in "${!marker_keys[@]}"; do
      [[ "${marker_malformed[mj]}" == "false" && "${marker_keys[mj]}" == "${dk}" ]] && found=$((found + 1))
    done
    ((found == 0)) && violations="$(jq -c --arg k "${dk}" '. + [{kind:"missing", key:$k}]' <<< "${violations}")"
  done

  # orphan / split (P2/P3): per distinct valid marker key.
  local -A seen_key=()
  for mi in "${!marker_keys[@]}"; do
    [[ "${marker_malformed[mi]}" == "true" ]] && continue
    local k="${marker_keys[mi]}"
    [[ -n "${seen_key[${k}]:-}" ]] && continue
    seen_key["${k}"]=1
    local is_designated
    is_designated="$(jq -r --arg k "${k}" 'index($k) != null' <<< "${designators_json}")"
    local lines_json='[]' mj
    for mj in "${!marker_keys[@]}"; do
      if [[ "${marker_malformed[mj]}" == "false" && "${marker_keys[mj]}" == "${k}" ]]; then
        lines_json="$(jq -c --argjson ln "${marker_lines[mj]}" '. + [$ln]' <<< "${lines_json}")"
      fi
    done
    local cnt; cnt="$(jq 'length' <<< "${lines_json}")"
    if [[ "${is_designated}" == "false" ]]; then
      violations="$(jq -c --arg k "${k}" --argjson lines "${lines_json}" '. + [{kind:"orphan", key:$k, lines:$lines}]' <<< "${violations}")"
    elif ((cnt > 1)); then
      violations="$(jq -c --arg k "${k}" --argjson lines "${lines_json}" '. + [{kind:"split", key:$k, lines:$lines}]' <<< "${violations}")"
    fi
  done

  # merge (P3): 2+ markers (any kind) within one story section.
  local -A section_count=()
  for mi in "${!marker_section[@]}"; do
    local sec="${marker_section[mi]}"
    ((sec < 0)) && continue
    section_count["${sec}"]=$(( ${section_count[${sec}]:-0} + 1 ))
  done
  local sec
  for sec in "${!section_count[@]}"; do
    if ((section_count[${sec}] > 1)); then
      local sec_lines='[]' mj
      for mj in "${!marker_section[@]}"; do
        [[ "${marker_section[mj]}" == "${sec}" ]] && sec_lines="$(jq -c --argjson ln "${marker_lines[mj]}" '. + [$ln]' <<< "${sec_lines}")"
      done
      violations="$(jq -c --argjson lines "${sec_lines}" '. + [{kind:"merge", lines:$lines}]' <<< "${violations}")"
    fi
  done

  # reorder (P4): the file-order sequence of valid, designated keys —
  # deduped to each key's FIRST occurrence — compared to the designator
  # order.
  local file_order='[]'
  for mi in "${!marker_keys[@]}"; do
    [[ "${marker_malformed[mi]}" == "false" ]] || continue
    file_order="$(jq -c --arg k "${marker_keys[mi]}" '. + [$k]' <<< "${file_order}")"
  done
  local same_order
  same_order="$(jq -n --argjson want "${designators_json}" --argjson got "${file_order}" '
    ($want) as $w
    | ($got | reduce .[] as $k ([]; if (($w | index($k)) != null) and (index($k) == null) then . + [$k] else . end)) as $gotFiltered
    | $gotFiltered == $w
  ')"
  [[ "${same_order}" == "false" ]] && violations="$(jq -c '. + [{kind:"reorder"}]' <<< "${violations}")"

  printf '%s' "${violations}" | json_canonical
}

# pin_marker_provenance <content> <designators-json> — FR-032: one entry
# per drafted user-story section, in document order (`_smk_scan_anchors`'
# anchors), naming its heading text and its source — the designated key
# whose valid marker falls within its span, or "new" when none does. A
# single pass over the anchors and the markers, reusing
# pin_marker_validate's own span math (R10 — no per-section grep). Prints
# canonical JSON: [{"heading":"..","source":".."|"new"}, ...]
pin_marker_provenance() {
  local content="$1" designators_json="$2"
  local -a anchors=()
  while IFS= read -r a; do anchors+=("${a}"); done < <(pin_marker_anchors "${content}")
  local n=${#anchors[@]}
  local total_lines
  total_lines="$(marker_splice_line_count "${content}")"

  local -a heading_lines=()
  local lineno=0 line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    heading_lines[lineno]="${line%$'\r'}"
  done <<< "${content}"

  local -a marker_lines=() marker_keys=()
  lineno=0
  local info kind
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    info="$(pin_marker_parse_line "${line}")"
    kind="$(jq -r '.kind' <<< "${info}")"
    [[ "${kind}" == "valid" ]] || continue
    marker_lines+=("${lineno}")
    marker_keys+=("$(jq -r '.key' <<< "${info}")")
  done <<< "${content}"

  local result='[]'
  local i
  for ((i = 0; i < n; i++)); do
    local a="${anchors[i]}" span_start span_end heading_text source="new"
    if ((a == 0)); then
      span_start=1
      heading_text="Overview"
    else
      span_start=$((a + 1))
      local raw="${heading_lines[a]}"
      if [[ "${raw}" =~ ^#+[[:space:]]+(.*)$ ]]; then
        heading_text="${BASH_REMATCH[1]}"
      else
        heading_text="${raw}"
      fi
    fi
    if ((i + 1 < n)); then span_end=$((anchors[i + 1] - 1)); else span_end="${total_lines}"; fi
    local mj
    for mj in "${!marker_lines[@]}"; do
      local m="${marker_lines[mj]}"
      if ((m >= span_start && m <= span_end)); then
        local mk="${marker_keys[mj]}"
        if jq -e --arg k "${mk}" 'index($k) != null' <<< "${designators_json}" > /dev/null; then
          source="${mk}"
        fi
        break
      fi
    done
    result="$(jq -c --arg h "${heading_text}" --arg s "${source}" '. + [{heading:$h, source:$s}]' <<< "${result}")"
  done
  printf '%s' "${result}" | json_canonical
}

# pin_marker_consume <content> <key> <replacement-line-text> <nl> — §6:
# replace the pin=<key> marker line IN PLACE with <replacement-line-text>,
# preserving every other byte and the line ending (P-7). A no-op (content
# returned unchanged) when <key> has no pin marker line.
pin_marker_consume() {
  local content="$1" key="$2" replacement="$3" nl="$4"
  local lineno=0 line info found=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    info="$(pin_marker_parse_line "${line}")"
    [[ "${info}" == '{"kind":"none"}' ]] && continue
    if [[ "$(jq -r '.kind' <<< "${info}")" == "valid" && "$(jq -r '.key' <<< "${info}")" == "${key}" ]]; then
      found="${lineno}"
      break
    fi
  done <<< "${content}"
  ((found == 0)) && { printf '%s' "${content}"; return 0; }
  marker_splice_replace_line "${content}" "${found}" "${replacement}" "${nl}"
}
