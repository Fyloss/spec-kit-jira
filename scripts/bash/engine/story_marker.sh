#!/usr/bin/env bash
# engine/story_marker.sh — The durable story identifier: generation, grammar,
# and the byte-preserving splice that writes it into a specification (Phase 2,
# T009/T011/T013; contracts/story-marker.md).
#
# NEUTRAL layer: zero Jira vocabulary. The identifier is an opaque random hex
# string and the ticket key it is ever paired with is opaque text handed in by
# the caller — exactly as managed_section.sh takes its markers as parameters
# without knowing about READMEs (Constitution VIII).
#
# The byte-offset, line-ending, atomic-write and line-replacement primitives
# live in marker_splice.sh (T064) — spec_marker.sh reuses the same routines
# rather than duplicating a splice.

[[ -n ${_JIRA_ENGINE_STORY_MARKER:-} ]] && return 0
_JIRA_ENGINE_STORY_MARKER=1

_smk_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_smk_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_smk_dir}/marker_splice.sh"

# _smk_trim <string> — strip leading and trailing whitespace, fork-free
# (024, contracts/spawn-budget.md C1.3): the sed equivalent it replaces here
# and in spec_marker.sh ran once per line of the whole document, which is
# where most of the parse phase's process count came from (research R5).
_smk_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# _smk_id_index_file — where the SPEC_KIT_JIRA_ID_SOURCE seam's cursor is kept.
# A bash function invoked through command substitution (the normal way every
# caller here consumes one) runs in a FORKED SUBSHELL, so a plain shell
# variable cannot carry the cursor from one call to the next — only the
# filesystem is shared across those forks within one process. Keyed by the
# owning shell's PID ($$, stable across its own subshells, unlike $BASHPID)
# PLUS that process's own start time: PID alone is not enough — under heavy
# concurrency a PID can be reused by an unrelated process before a stale
# cursor file from the previous owner is ever cleaned up, silently leaking
# its cursor forward (T028). Start time is a cheap, portable (macOS/Linux)
# way to make a reused PID address a different file.
_smk_id_index_file() {
  local start; start="$(ps -o lstart= -p "$$" 2>/dev/null | tr -d ' \t')"
  printf '%s/.speckit-jira-id-index.%s.%s' "${TMPDIR:-/tmp}" "$$" "${start:-nostat}"
}

# story_marker_generate_id — a new 16-lowercase-hex-character identifier: 8
# bytes of cryptographic randomness, or the next value from the
# SPEC_KIT_JIRA_ID_SOURCE seam (a space/newline separated list, consumed in
# order and cycling) when set — the ONLY thing that keeps the two ports
# byte-identical under the conformance gate over an otherwise non-deterministic
# value.
story_marker_generate_id() {
  local seq="${SPEC_KIT_JIRA_ID_SOURCE:-}"
  if [[ -n "${seq}" ]]; then
    local -a ids
    read -r -a ids <<< "${seq}"
    local f idx=0
    f="$(_smk_id_index_file)"
    [[ -f "${f}" ]] && idx="$(cat "${f}")"
    printf '%s' "${ids[$((idx % ${#ids[@]}))]}"
    printf '%s' "$((idx + 1))" > "${f}"
    return 0
  fi
  od -An -tx1 -N8 /dev/urandom | tr -d ' \n'
}

# story_marker_format <id> [state] [ticket] — the marker line's TEXT (no
# trailing newline). state: "" (bare, assigned) | "creating" | "bound"
# (requires ticket). Exactly one space between tokens (contract: "written"
# form).
story_marker_format() {
  local id="$1" state="${2:-}" ticket="${3:-}"
  case "${state}" in
    creating) printf '<!-- speckit-jira story=%s creating -->' "${id}" ;;
    bound) printf '<!-- speckit-jira story=%s ticket=%s -->' "${id}" "${ticket}" ;;
    *) printf '<!-- speckit-jira story=%s -->' "${id}" ;;
  esac
}

# story_marker_parse_line <line> — classify one line against the grammar.
# Canonical JSON:
#   {"kind":"none"}                                             — not a marker at all
#   {"kind":"valid","id":"..","state":"assigned"}                — story=<id>
#   {"kind":"valid","id":"..","state":"creating"}                 — story=<id> creating
#   {"kind":"valid","id":"..","state":"bound","ticket":".."}      — story=<id> ticket=<ticket>
#   {"kind":"malformed","id":".."}                                — a valid identifier with an unrecognisable tail
#
# A "spec=" body is a DIFFERENT marker (contracts/parent-marker.md
# "Non-collision with the story marker") and MUST fall through to "none"
# here, by construction: the body is matched against `^story=...`.
story_marker_parse_line() {
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

  local story_re='^story=([^[:space:]]+)([[:space:]]+(.*))?$'
  if [[ ! "${body}" =~ ${story_re} ]]; then
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

# story_marker_any_bound <content> — return 0 when ANY line of <content> carries
# a story marker in the BOUND form, 1 otherwise (033, FR-004,
# contracts/routing-resolution.md C3.3/C3.4).
#
# Routing rank 3 — the project of the team the operator selected in their
# gitignored personal.yml — is consulted ONLY for a specification that is not
# yet bound. Without that bound, routing would depend on a per-operator file:
# two developers would resolve the same specification to different projects and
# each run would mirror it afresh into the other one, leaving two live ticket
# sets. The stopping condition is already in the filesystem (Constitution I) —
# a bound marker is an earlier run's record of which project this spec lives in.
#
# Only the ticket-bearing form counts. `creating` is a run in flight and a bare
# marker is assigned-but-not-created; neither pins a project yet.
#
# FORK-FREE by contract (C3.4). It deliberately does NOT reuse
# story_marker_parse_line, which spends one `jq` per line — on a 200-story
# document that is 200 processes against zero. The trim is inlined for the same
# reason: `$(_smk_trim …)` forks a subshell per line.
story_marker_any_bound() {
  local content="$1" line t body idval tail
  local generic_re='^<!--[[:space:]]+speckit-jira[[:space:]]+(.*)-->[[:space:]]*$'
  local story_re='^story=([^[:space:]]+)([[:space:]]+(.*))?$'
  local ticket_re='^ticket=[A-Z][A-Z0-9_]*-[1-9][0-9]*$'
  [[ -z "${content}" ]] && return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    t="${line#"${line%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    # Cheap gate first: most lines of a specification are prose.
    [[ "${t}" == '<!--'* ]] || continue
    [[ "${t}" =~ ${generic_re} ]] || continue
    body="${BASH_REMATCH[1]}"
    body="${body#"${body%%[![:space:]]*}"}"
    body="${body%"${body##*[![:space:]]}"}"
    [[ "${body}" =~ ${story_re} ]] || continue
    idval="${BASH_REMATCH[1]}"
    tail="${BASH_REMATCH[3]:-}"
    [[ "${idval}" =~ ^[0-9a-f]{16}$ ]] || continue
    tail="${tail#"${tail%%[![:space:]]*}"}"
    tail="${tail%"${tail##*[![:space:]]}"}"
    [[ "${tail}" =~ ${ticket_re} ]] && return 0
  done <<< "${content}"
  return 1
}

# _smk_scan_anchors <content> — the anchor line numbers (1-based), one per
# story section, IN DOCUMENT ORDER (contract "Placement"): every
# `^#{2,4}\s+User Story` heading; else the document's first H1; else "0" (the
# sole line printed), meaning "before line 1" — the implicit single story with
# neither a story heading nor an H1.
_smk_scan_anchors() {
  local content="$1" lineno=0 h1=0 line lc
  local -a story=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    lc="${line%$'\r'}"
    if [[ "${lc}" =~ ^#{2,4}[[:space:]]+User[[:space:]]Story ]]; then
      story+=("${lineno}")
    elif ((h1 == 0)) && [[ "${lc}" =~ ^#[[:space:]] ]]; then
      h1="${lineno}"
    fi
  done <<< "${content}"
  if ((${#story[@]} > 0)); then
    printf '%s\n' "${story[@]}"
  elif ((h1 > 0)); then
    printf '%s\n' "${h1}"
  else
    printf '0\n'
  fi
}

# _smk_section_has_marker <content> <span_start> <span_end> — 0 (true) when
# any line in the 1-based inclusive range carries a marker attempt (kind !=
# "none"; a malformed attempt still counts — assignment must never add a
# second marker beside one that is merely broken). A `spec=` line never
# counts (contracts/parent-marker.md "Non-collision"): story_marker_parse_line
# returns "none" for it.
_smk_section_has_marker() {
  local content="$1" start="$2" end="$3" lineno=0 line kind
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    ((lineno < start)) && continue
    ((lineno > end)) && break
    kind="$(story_marker_parse_line "${line}" | jq -r '.kind')"
    [[ "${kind}" != "none" ]] && return 0
  done <<< "${content}"
  return 1
}

# story_marker_section_info <content> <span_start> <span_end> — full marker
# detail for the 1-based inclusive line range, on the WHOLE document (so line
# numbers in the result are absolute). Canonical JSON:
#   {"state":"absent","id":"","lines":[]}
#   {"state":"assigned"|"creating"|"bound","id":"..","ticket":"..","lines":[N]}
#   {"state":"malformed","id":"..","lines":[N]}
#   {"state":"duplicate","id":"","lines":[N1,N2,...]}   — 2+ marker attempts
story_marker_section_info() {
  local content="$1" start="$2" end="$3" lineno=0 line info kind
  local -a found_lines=() found_ids=() found_states=() found_tickets=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    ((lineno < start)) && continue
    ((lineno > end)) && break
    info="$(story_marker_parse_line "${line}")"
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

# _smk_find_line_for_id <content> <id> — the 1-based line number of the marker
# line naming <id> (any state), or 0 when absent.
_smk_find_line_for_id() {
  local content="$1" id="$2" lineno=0 line info kind this_id
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    info="$(story_marker_parse_line "${line}")"
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

# story_marker_assign — read a specification on stdin; assign a fresh
# identifier to every story section that carries no marker at all, inserting
# one bare `story=<id>` line right after its anchor (Placement). Prints the
# NEW text on stdout. IDEMPOTENT: when every section already has a marker
# attempt, the output is byte-identical to the input (contract "Idempotence").
story_marker_assign() {
  local content; content="$(cat; printf x)"; content="${content%x}"
  local nl_token nl; nl_token="$(marker_splice_dominant_nl_token "${content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi

  local -a anchors=()
  while IFS= read -r a; do anchors+=("${a}"); done < <(_smk_scan_anchors "${content}")

  local n=${#anchors[@]}
  local -a need=()
  local i
  for ((i = 0; i < n; i++)); do
    local a="${anchors[i]}" span_start span_end
    if ((a == 0)); then span_start=1; else span_start=$((a + 1)); fi
    if ((i + 1 < n)); then
      span_end=$((anchors[i + 1] - 1))
    else
      span_end="$(marker_splice_line_count "${content}")"
    fi
    if ! _smk_section_has_marker "${content}" "${span_start}" "${span_end}"; then
      need+=("${a}")
    fi
  done

  ((${#need[@]} == 0)) && { printf '%s' "${content}"; return 0; }

  # Identifiers are generated in ASCENDING document order (`need` is already
  # in that order — the first unmarked story gets the first id of a fixed
  # test sequence), but the insertions themselves must happen in DESCENDING
  # line order: an insertion strictly after a lower anchor's line never
  # shifts that lower anchor's own line number, so pairing must happen
  # BEFORE the sort.
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
    line_text="$(story_marker_format "${id}")"
    content="$(marker_splice_insert_after_line "${content}" "${anchor}" "${line_text}" "${nl}"; printf x)"; content="${content%x}"
  done
  printf '%s' "${content}"
}

# story_marker_mark_creating <ids-json-array> — read a specification on
# stdin; replace the bare `story=<id>` line for each id in the array with
# `story=<id> creating`. IDs with no matching bare line are left untouched
# (idempotent no-op for that id). Prints the new text on stdout.
story_marker_mark_creating() {
  local ids_json="$1" content; content="$(cat; printf x)"; content="${content%x}"
  local nl_token nl; nl_token="$(marker_splice_dominant_nl_token "${content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi

  local id lineno
  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue
    lineno="$(_smk_find_line_for_id "${content}" "${id}")"
    ((lineno == 0)) && continue
    content="$(marker_splice_replace_line "${content}" "${lineno}" "$(story_marker_format "${id}" creating)" "${nl}"; printf x)"; content="${content%x}"
  done < <(jq -r '.[]' <<< "${ids_json}")
  printf '%s' "${content}"
}

# story_marker_record_ticket <id> <key> — read a specification on stdin;
# replace the marker line for <id> (whatever its state) with
# `story=<id> ticket=<key>`. Prints the new text on stdout. A no-op (content
# returned unchanged) when <id> has no marker line at all.
story_marker_record_ticket() {
  local id="$1" key="$2" content; content="$(cat; printf x)"; content="${content%x}"
  local nl_token nl; nl_token="$(marker_splice_dominant_nl_token "${content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi
  local lineno; lineno="$(_smk_find_line_for_id "${content}" "${id}")"
  ((lineno == 0)) && { printf '%s' "${content}"; return 0; }
  content="$(marker_splice_replace_line "${content}" "${lineno}" "$(story_marker_format "${id}" bound "${key}")" "${nl}"; printf x)"; content="${content%x}"
  printf '%s' "${content}"
}
