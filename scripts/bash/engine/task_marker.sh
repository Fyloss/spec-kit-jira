#!/usr/bin/env bash
# engine/task_marker.sh — The durable task identifier: generation, grammar,
# and the byte-preserving splice that writes it into tasks.md (Phase 2,
# T009/T011/T013; contracts/task-tier.md §1).
#
# NEUTRAL layer: zero Jira vocabulary. The identifier is an opaque random hex
# string and the ticket key it is ever paired with is opaque text handed in by
# the caller — exactly as story_marker.sh and spec_marker.sh already do.
#
# This module defines NO generator of its own: story_marker_generate_id is
# reused unchanged so all three grammars share one SPEC_KIT_JIRA_ID_SOURCE seam
# cursor and stay byte-identical across ports (research R1, T009).
#
# The byte-offset, line-ending, atomic-write and line-replacement primitives
# live in marker_splice.sh — this module reuses those routines rather than
# duplicating a splice.

[[ -n ${_JIRA_ENGINE_TASK_MARKER:-} ]] && return 0
_JIRA_ENGINE_TASK_MARKER=1

_tmk_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_tmk_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_tmk_dir}/marker_splice.sh"
# shellcheck source=/dev/null
source "${_tmk_dir}/story_marker.sh" # story_marker_generate_id alone — the shared identifier seam

# _tmk_task_line_re — a task line: a checkbox followed by a task reference
# (T014). Deliberately minimal — full task recognition (attribution, files,
# dependencies) is tasks_parse.sh's job; this module only needs enough to
# place a marker immediately after the line it belongs to.
_TMK_TASK_LINE_RE='^-[[:space:]]+\[[ xX]\][[:space:]]+T[0-9]+[A-Za-z]?([[:space:]]|$)'

# task_marker_format <id> [state] [ticket] — the marker line's TEXT (no
# trailing newline). state: "" (bare, assigned) | "creating" | "bound"
# (requires ticket). Exactly one space between tokens (contract: "written"
# form). Mirror of story_marker_format.
task_marker_format() {
  local id="$1" state="${2:-}" ticket="${3:-}"
  case "${state}" in
    creating) printf '<!-- speckit-jira task=%s creating -->' "${id}" ;;
    bound) printf '<!-- speckit-jira task=%s ticket=%s -->' "${id}" "${ticket}" ;;
    *) printf '<!-- speckit-jira task=%s -->' "${id}" ;;
  esac
}

# task_marker_parse_line <line> — classify one line against the grammar.
# Canonical JSON, mirror of story_marker_parse_line but for the "task="
# body. A "story=" or "spec=" body is a DIFFERENT marker and MUST fall
# through to "none" here, by construction: the body is matched against
# `^task=`.
task_marker_parse_line() {
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

  local task_re='^task=([^[:space:]]+)([[:space:]]+(.*))?$'
  if [[ ! "${body}" =~ ${task_re} ]]; then
    printf '{"kind":"none"}'
    return 0
  fi
  local idval="${BASH_REMATCH[1]}" tail="${BASH_REMATCH[3]:-}"

  if [[ ! "${idval}" =~ ^[0-9a-f]{16}$ ]]; then
    printf '{"kind":"none"}'
    return 0
  fi

  tail="$(_smk_trim "${tail}")"
  if [[ -z "${tail}" ]]; then
    jq -cn --arg id "${idval}" '{kind:"valid", id:$id, state:"assigned"}' | json_canonical
    return 0
  fi
  if [[ "${tail}" == "creating" ]]; then
    jq -cn --arg id "${idval}" '{kind:"valid", id:$id, state:"creating"}' | json_canonical
    return 0
  fi
  if [[ "${tail}" =~ ^ticket=([^[:space:]]+)$ ]]; then
    local key="${BASH_REMATCH[1]}"
    if [[ "${key}" =~ ^[A-Z][A-Z0-9_]*-[1-9][0-9]*$ ]]; then
      jq -cn --arg id "${idval}" --arg k "${key}" '{kind:"valid", id:$id, state:"bound", ticket:$k}' | json_canonical
      return 0
    fi
  fi
  jq -cn --arg id "${idval}" '{kind:"malformed", id:$id}' | json_canonical
}

# _tmk_scan_anchors <content> — the anchor line numbers (1-based), one per
# task line, IN DOCUMENT ORDER. Unlike story_marker's scan there is NO
# fallback anchor: a file with no recognisable task line yields no anchors
# at all (contract §2 "the file holds no recognisable task" -> empty list).
_tmk_scan_anchors() {
  local content="$1" lineno=0 line lc
  local -a anchors=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    lc="${line%$'\r'}"
    [[ "${lc}" =~ ${_TMK_TASK_LINE_RE} ]] && anchors+=("${lineno}")
  done <<< "${content}"
  printf '%s\n' "${anchors[@]:-}"
}

# _tmk_section_has_marker <content> <span_start> <span_end> — 0 (true) when
# any line in the 1-based inclusive range carries a marker attempt (kind !=
# "none"; a malformed attempt still counts). Mirror of
# _smk_section_has_marker.
_tmk_section_has_marker() {
  local content="$1" start="$2" end="$3" lineno=0 line kind
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    ((lineno < start)) && continue
    ((lineno > end)) && break
    kind="$(task_marker_parse_line "${line}" | jq -r '.kind')"
    [[ "${kind}" != "none" ]] && return 0
  done <<< "${content}"
  return 1
}

# task_marker_section_info <content> <span_start> <span_end> — full marker
# detail for the 1-based inclusive line range, on the WHOLE document.
# Canonical JSON, mirror of story_marker_section_info:
#   {"state":"absent","id":"","lines":[]}
#   {"state":"assigned"|"creating"|"bound","id":"..","ticket":"..","lines":[N]}
#   {"state":"malformed","id":"..","lines":[N]}
#   {"state":"duplicate","id":"","lines":[N1,N2,...]}
task_marker_section_info() {
  local content="$1" start="$2" end="$3" lineno=0 line info kind
  local -a found_lines=() found_ids=() found_states=() found_tickets=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    ((lineno < start)) && continue
    ((lineno > end)) && break
    info="$(task_marker_parse_line "${line}")"
    # 024, contracts/spawn-budget.md C1.2/C1.3: this loop runs once per
    # document line, so an extra `jq -r '.kind'` call here — the same
    # per-line-classification pattern T025 already fixed in
    # story_marker.sh/spec_marker.sh — would cost one process per line
    # regardless of marker density. `task_marker_parse_line`'s "none" path
    # is a plain `printf`, never `json_canonical`, so the literal string is
    # exact, not approximate — every other return path is JSON-object-typed
    # and can never collide with it.
    [[ "${info}" == '{"kind":"none"}' ]] && continue
    kind="$(jq -r '.kind' <<< "${info}")"
    found_lines+=("${lineno}")
    if [[ "${kind}" == "valid" ]]; then
      found_ids+=("$(jq -r '.id' <<< "${info}")")
      found_states+=("$(jq -r '.state' <<< "${info}")")
      found_tickets+=("$(jq -r '.ticket // ""' <<< "${info}")")
    else
      found_ids+=("$(jq -r '.id' <<< "${info}")")
      found_states+=("malformed")
      found_tickets+=("")
    fi
  done <<< "${content}"

  local count=${#found_lines[@]}
  local lines_json; lines_json="$(printf '%s\n' "${found_lines[@]:-}" | jq -R 'select(length>0) | tonumber' | jq -s '.')"
  if ((count == 0)); then
    jq -cn '{state:"absent", id:"", lines:[]}'
  elif ((count == 1)); then
    jq -cn --arg st "${found_states[0]}" --arg id "${found_ids[0]}" --arg tk "${found_tickets[0]}" --argjson ln "${lines_json}" \
      '{state:$st, id:$id, ticket:$tk, lines:$ln}'
  else
    jq -cn --argjson ln "${lines_json}" '{state:"duplicate", id:"", lines:$ln}'
  fi
}

# _tmk_find_line_for_id <content> <id> — the 1-based line number of the marker
# line naming <id> (any state), or 0 when absent.
_tmk_find_line_for_id() {
  local content="$1" id="$2" lineno=0 line info kind this_id
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    info="$(task_marker_parse_line "${line}")"
    kind="$(jq -r '.kind' <<< "${info}")"
    [[ "${kind}" == "none" ]] && continue
    this_id="$(jq -r '.id // empty' <<< "${info}")"
    if [[ "${this_id}" == "${id}" ]]; then
      printf '%s' "${lineno}"
      return 0
    fi
  done <<< "${content}"
  printf '0'
}

# task_marker_assign — read tasks.md on stdin; assign a fresh identifier to
# every task line that carries no marker attempt, inserting one bare
# `task=<id>` line right after it (Placement). Prints the NEW text on
# stdout. IDEMPOTENT: when every task already carries a marker attempt, the
# output is byte-identical to the input (contract "Idempotence").
task_marker_assign() {
  local content; content="$(cat; printf x)"; content="${content%x}"
  local nl_token nl; nl_token="$(marker_splice_dominant_nl_token "${content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi

  local -a anchors=()
  while IFS= read -r a; do [[ -n "${a}" ]] && anchors+=("${a}"); done < <(_tmk_scan_anchors "${content}")

  local n=${#anchors[@]}
  ((n == 0)) && { printf '%s' "${content}"; return 0; }

  local -a need=()
  local i
  for ((i = 0; i < n; i++)); do
    local a="${anchors[i]}" span_start span_end
    span_start=$((a + 1))
    if ((i + 1 < n)); then
      span_end=$((anchors[i + 1] - 1))
    else
      span_end="$(marker_splice_line_count "${content}")"
    fi
    if ! _tmk_section_has_marker "${content}" "${span_start}" "${span_end}"; then
      need+=("${a}")
    fi
  done

  ((${#need[@]} == 0)) && { printf '%s' "${content}"; return 0; }

  # Identifiers are generated in ASCENDING document order, but insertions
  # happen in DESCENDING line order — pairing before the sort, exactly as
  # story_marker_assign does.
  local -a pairs=()
  local a
  for a in "${need[@]}"; do
    pairs+=("${a}:$(story_marker_generate_id)")
  done
  local -a sorted
  mapfile -t sorted < <(printf '%s\n' "${pairs[@]}" | sort -t: -k1,1 -rn)

  local pair anchor id line_text
  for pair in "${sorted[@]}"; do
    anchor="${pair%%:*}"
    id="${pair#*:}"
    line_text="$(task_marker_format "${id}")"
    content="$(marker_splice_insert_after_line "${content}" "${anchor}" "${line_text}" "${nl}"; printf x)"; content="${content%x}"
  done
  printf '%s' "${content}"
}

# task_marker_mark_creating <ids-json-array> — read tasks.md on stdin;
# replace the bare `task=<id>` line for each id in the array with
# `task=<id> creating`. IDs with no matching bare line are left untouched.
# Prints the new text on stdout.
task_marker_mark_creating() {
  local ids_json="$1" content; content="$(cat; printf x)"; content="${content%x}"
  local nl_token nl; nl_token="$(marker_splice_dominant_nl_token "${content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi

  local id lineno
  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue
    lineno="$(_tmk_find_line_for_id "${content}" "${id}")"
    ((lineno == 0)) && continue
    content="$(marker_splice_replace_line "${content}" "${lineno}" "$(task_marker_format "${id}" creating)" "${nl}"; printf x)"; content="${content%x}"
  done < <(jq -r '.[]' <<< "${ids_json}")
  printf '%s' "${content}"
}

# task_marker_record_ticket <id> <key> — read tasks.md on stdin; replace the
# marker line for <id> (whatever its state) with `task=<id> ticket=<key>`.
# Prints the new text on stdout. A no-op when <id> has no marker line.
task_marker_record_ticket() {
  local id="$1" key="$2" content; content="$(cat; printf x)"; content="${content%x}"
  local nl_token nl; nl_token="$(marker_splice_dominant_nl_token "${content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi
  local lineno; lineno="$(_tmk_find_line_for_id "${content}" "${id}")"
  ((lineno == 0)) && { printf '%s' "${content}"; return 0; }
  content="$(marker_splice_replace_line "${content}" "${lineno}" "$(task_marker_format "${id}" bound "${key}")" "${nl}"; printf x)"; content="${content%x}"
  printf '%s' "${content}"
}
