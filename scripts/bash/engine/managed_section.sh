#!/usr/bin/env bash
# engine/managed_section.sh — Generic managed-section byte-splice (US5, T063).
#
# A "managed section" is a region of a text file delimited by a begin marker and
# an end marker. This module owns the byte manipulation: it replaces only the
# region between (and including) the markers, preserves every byte outside it,
# renders the region with the host's dominant line ending, appends the region
# once when it is absent, and refuses malformed marker configurations with a
# located error and zero output.
#
# NEUTRAL layer: zero Jira identifiers, never sources sink/. The marker tokens
# are PARAMETERS — this module knows nothing about README files or the extension;
# the version-marked README block that supplies the markers lives in hooks/. US7
# reuses the same splice for the origin-discriminated Jira description panel.

[[ -n ${_JIRA_ENGINE_MANAGED_SECTION:-} ]] && return 0
_JIRA_ENGINE_MANAGED_SECTION=1

_ms_this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ms_this_dir}/../lib/output.sh"

# _ms_count <haystack> <needle> — echo the number of non-overlapping occurrences
# of <needle> in <haystack>. Substring-based (not line-based) so the count is
# identical to the PowerShell port's regex Matches count.
_ms_count() {
  local rest="$1" needle="$2" n=0
  [[ -z "${needle}" ]] && { printf '0'; return 0; }
  while [[ "${rest}" == *"${needle}"* ]]; do
    rest="${rest#*"${needle}"}"
    n=$((n + 1))
  done
  printf '%s' "${n}"
}

# _ms_line_numbers <content> <token> — echo the 1-based line numbers of every
# occurrence of <token>, space-separated. Used only for located error messages.
_ms_line_numbers() {
  local content="$1" token="$2" rest="$1" nums="" consumed=0 chunk prefix nls
  while [[ "${rest}" == *"${token}"* ]]; do
    chunk="${rest%%"${token}"*}"
    prefix="${content:0:$((consumed + ${#chunk}))}"
    nls="${prefix//[!$'\n']/}"
    nums+="$(( ${#nls} + 1 )) "
    consumed=$((consumed + ${#chunk} + ${#token}))
    rest="${rest#*"${token}"}"
  done
  printf '%s' "${nums% }"
}

# managed_section_line_ending — read text on stdin; print the dominant line-ending
# token, "CRLF" or "LF". A file with more CRLF than bare-LF terminators is CRLF;
# everything else (including an empty file) is LF, so a new file always uses LF.
managed_section_line_ending() {
  local content crlf lf_total lf_only
  content="$(cat; printf x)"; content="${content%x}"
  crlf="$(_ms_count "${content}" $'\r\n')"
  lf_total="$(_ms_count "${content}" $'\n')"
  lf_only=$((lf_total - crlf))
  if [[ "${crlf}" -gt "${lf_only}" ]]; then
    printf 'CRLF'
  else
    printf 'LF'
  fi
}

# managed_section_splice <begin-token> <end-token> <new-block>
#   stdin:  the current host bytes (may be empty).
#   <new-block>: the full replacement region including its markers, lines joined
#                with LF and NO trailing newline; the splice re-renders it with the
#                host's dominant line ending.
#   stdout: the new file bytes.
#   returns 0 on success; 4 (malformed markers) with a located error and NO output.
managed_section_splice() {
  local begin="$1" end="$2" block="$3" content
  content="$(cat; printf x)"; content="${content%x}"

  local eol nl
  eol="$(printf '%s' "${content}" | managed_section_line_ending)"
  if [[ "${eol}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi
  local rblock="${block//$'\n'/${nl}}"

  local bcount ecount
  bcount="$(_ms_count "${content}" "${begin}")"
  ecount="$(_ms_count "${content}" "${end}")"

  # --- Absent: append the region once at the end of the file ----------------
  if [[ "${bcount}" -eq 0 && "${ecount}" -eq 0 ]]; then
    if [[ -z "${content}" ]]; then
      printf '%s%s' "${rblock}" "${nl}"
    else
      local sep=""
      [[ "${content}" != *$'\n' ]] && sep="${nl}"
      sep="${sep}${nl}"
      printf '%s%s%s%s' "${content}" "${sep}" "${rblock}" "${nl}"
    fi
    return 0
  fi

  # --- Malformed: anything other than exactly one well-ordered pair ----------
  local before_b before_e begin_idx end_idx
  before_b="${content%%"${begin}"*}"; begin_idx="${#before_b}"
  before_e="${content%%"${end}"*}"; end_idx="${#before_e}"
  if [[ "${bcount}" -ne 1 || "${ecount}" -ne 1 || "${begin_idx}" -ge "${end_idx}" ]]; then
    local bl el
    bl="$(_ms_line_numbers "${content}" "${begin}")"
    el="$(_ms_line_numbers "${content}" "${end}")"
    if [[ "${bcount}" -ge 1 && "${ecount}" -eq 0 ]]; then
      printf 'managed section: begin marker at line(s) %s with no matching end marker\n' "${bl}" >&2
    elif [[ "${ecount}" -ge 1 && "${bcount}" -eq 0 ]]; then
      printf 'managed section: end marker at line(s) %s with no matching begin marker\n' "${el}" >&2
    elif [[ "${bcount}" -eq 1 && "${ecount}" -eq 1 ]]; then
      printf 'managed section: end marker at line %s precedes begin marker at line %s\n' "${el}" "${bl}" >&2
    else
      printf 'managed section: malformed markers — begin at line(s) %s, end at line(s) %s (expected exactly one of each)\n' "${bl}" "${el}" >&2
    fi
    return 4
  fi

  # --- Present: replace the region, preserving every byte outside it ---------
  # `before` keeps everything up to and including the newline that terminates the
  # line preceding the begin marker; `after` keeps everything after the newline
  # that terminates the end-marker line. Both are byte-preserved verbatim.
  local before after after_e
  if [[ "${before_b}" == *$'\n'* ]]; then
    before="${before_b%$'\n'*}"$'\n'
  else
    before=""
  fi
  after_e="${content#*"${end}"}"
  if [[ "${after_e}" == *$'\n'* ]]; then
    after="${after_e#*$'\n'}"
  else
    after=""
  fi
  printf '%s%s%s%s' "${before}" "${rblock}" "${nl}" "${after}"
  return 0
}

# managed_section_panel_split <marker>   (stdin: an array of opaque content nodes)
#   Split an existing rich-text description's content-node array at the managed
#   panel marker (US7, T075). The marker is a PARAMETER — this module knows nothing
#   about the panel's wording or the host format; it treats every node as opaque
#   JSON and searches every string value inside it, so no sink vocabulary reaches
#   the neutral layer. Everything before the first node that carries the marker is
#   the human-authored prefix, preserved verbatim; everything from that node onward
#   is the previously-written managed section. When no node carries the marker the
#   whole array is human prefix (the first managed write appends the panel below).
#   Emits canonical {prefix, managed, had_marker}.
managed_section_panel_split() {
  local marker="$1" nodes
  nodes="$(cat)"
  [[ -z "${nodes}" ]] && nodes="[]"
  jq -c --arg m "${marker}" '
    . as $nodes
    | ( first(
          range(0; ($nodes | length)) as $i
          | select(([ $nodes[$i] | .. | strings ] | join("\n")) | contains($m))
          | $i
        ) // null ) as $k
    | if $k == null
      then { prefix: $nodes, managed: [], had_marker: false }
      else { prefix: $nodes[0:$k], managed: $nodes[$k:], had_marker: true }
      end' <<< "${nodes}" | json_canonical
}
