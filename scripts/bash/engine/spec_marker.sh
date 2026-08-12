#!/usr/bin/env bash
# engine/spec_marker.sh — The durable parent identifier: generation, grammar,
# and the byte-preserving splice that writes it into a specification (Phase
# 5, US2, T065; contracts/parent-marker.md).
#
# NEUTRAL layer: zero Jira vocabulary. This contract EXTENDS 005's
# story-marker contract rather than replacing it: the framing comment, the
# identifier alphabet, the byte-preserving splice, the line-ending rule and
# the atomic write are inherited unchanged from marker_splice.sh and
# story_marker.sh's identifier generator. Exactly one parent marker exists
# per specification file, so this module works over the WHOLE document
# rather than per-section, unlike story_marker.sh.

[[ -n ${_JIRA_ENGINE_SPEC_MARKER:-} ]] && return 0
_JIRA_ENGINE_SPEC_MARKER=1

_smkp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_smkp_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_smkp_dir}/marker_splice.sh"
# shellcheck source=/dev/null
source "${_smkp_dir}/story_marker.sh" # story_marker_generate_id — same identifier alphabet, same SPEC_KIT_JIRA_ID_SOURCE seam

# spec_marker_format <id> [state] [ticket] — the marker line's TEXT (no
# trailing newline). state: "" (bare, assigned) | "creating" | "bound"
# (requires ticket). Mirror of story_marker_format.
spec_marker_format() {
  local id="$1" state="${2:-}" ticket="${3:-}"
  case "${state}" in
    creating) printf '<!-- speckit-jira spec=%s creating -->' "${id}" ;;
    bound) printf '<!-- speckit-jira spec=%s ticket=%s -->' "${id}" "${ticket}" ;;
    *) printf '<!-- speckit-jira spec=%s -->' "${id}" ;;
  esac
}

# spec_marker_parse_line <line> — classify one line against the grammar.
# Canonical JSON, mirror of story_marker_parse_line but for the "spec="
# body. A "story=" body is a DIFFERENT marker (contracts/parent-marker.md
# "Non-collision") and MUST fall through to "none" here, by construction.
spec_marker_parse_line() {
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

  local spec_re='^spec=([^[:space:]]+)([[:space:]]+(.*))?$'
  if [[ ! "${body}" =~ ${spec_re} ]]; then
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

# _smkp_h1_or_zero <content> — the 1-based line number of the document's
# first H1 (`^#\s`), or 0 when there is none — placement's "before line 1"
# anchor, mirroring _smk_scan_anchors's own convention.
_smkp_h1_or_zero() {
  local content="$1" lineno=0 line lc
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    lc="${line%$'\r'}"
    if [[ "${lc}" =~ ^#[[:space:]] ]]; then
      printf '%s' "${lineno}"
      return 0
    fi
  done <<< "${content}"
  printf '0'
}

# spec_marker_document_info <content> — full marker detail over the WHOLE
# document. Canonical JSON:
#   {"state":"absent","id":"","lines":[]}
#   {"state":"assigned"|"creating"|"bound","id":"..","ticket":"..","lines":[N]}
#   {"state":"malformed","id":"..","lines":[N]}
#   {"state":"duplicate","id":"","lines":[N1,N2,...]}   — 2+ spec= lines anywhere
spec_marker_document_info() {
  local content="$1" lineno=0 line info kind
  local -a found_lines=() found_ids=() found_states=() found_tickets=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    info="$(spec_marker_parse_line "${line}")"
    # Same literal-comparison technique as _parse_strip_marker_lines (024,
    # contracts/spawn-budget.md C1.2): every "none" result is this exact
    # string, so the common case costs no `jq -r '.kind'` fork per line.
    [[ "${info}" == '{"kind":"none"}' ]] && continue
    found_lines+=("${lineno}")
    kind="$(jq -r '.kind' <<< "${info}")"
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

# spec_marker_assign — read a specification on stdin; when the document
# carries no spec= marker attempt at all (kind != "none"), insert one bare
# `spec=<id>` line immediately after the H1, or as line 1 when there is no
# H1 (Placement). Prints the NEW text on stdout. IDEMPOTENT: a document that
# already carries a marker attempt (valid or malformed) is returned
# byte-identical — duplicate/malformed detection is the recogniser's job,
# not assignment's.
spec_marker_assign() {
  local content; content="$(cat; printf x)"; content="${content%x}"
  local info; info="$(spec_marker_document_info "${content}")"
  local state; state="$(jq -r '.state' <<< "${info}")"
  [[ "${state}" != "absent" ]] && { printf '%s' "${content}"; return 0; }

  local nl_token nl; nl_token="$(marker_splice_dominant_nl_token "${content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi

  local anchor; anchor="$(_smkp_h1_or_zero "${content}")"
  local id; id="$(story_marker_generate_id)"
  local line_text; line_text="$(spec_marker_format "${id}")"
  marker_splice_insert_after_line "${content}" "${anchor}" "${line_text}" "${nl}"
}

# spec_marker_mark_creating <id> — read a specification on stdin; replace
# the bare `spec=<id>` line with `spec=<id> creating`. A no-op when <id> has
# no matching bare line. Prints the new text on stdout.
spec_marker_mark_creating() {
  local id="$1" content; content="$(cat; printf x)"; content="${content%x}"
  local info; info="$(spec_marker_document_info "${content}")"
  [[ "$(jq -r '.id' <<< "${info}")" != "${id}" ]] && { printf '%s' "${content}"; return 0; }
  local lineno; lineno="$(jq -r '.lines[0]' <<< "${info}")"
  local nl_token nl; nl_token="$(marker_splice_dominant_nl_token "${content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi
  marker_splice_replace_line "${content}" "${lineno}" "$(spec_marker_format "${id}" creating)" "${nl}"
}

# spec_marker_record_ticket <id> <key> — read a specification on stdin;
# replace the marker line for <id> (whatever its state) with
# `spec=<id> ticket=<key>`. A no-op when <id> has no marker line at all.
# Prints the new text on stdout.
spec_marker_record_ticket() {
  local id="$1" key="$2" content; content="$(cat; printf x)"; content="${content%x}"
  local info; info="$(spec_marker_document_info "${content}")"
  [[ "$(jq -r '.id' <<< "${info}")" != "${id}" ]] && { printf '%s' "${content}"; return 0; }
  local lineno; lineno="$(jq -r '.lines[0]' <<< "${info}")"
  local nl_token nl; nl_token="$(marker_splice_dominant_nl_token "${content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi
  marker_splice_replace_line "${content}" "${lineno}" "$(spec_marker_format "${id}" bound "${key}")" "${nl}"
}
