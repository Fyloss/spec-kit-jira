#!/usr/bin/env bash
# engine/marker_splice.sh — Byte-offset, line-ending, atomic-write and
# line-replacement primitives shared by every marker kind spliced into a
# specification file (T064). story_marker.sh and spec_marker.sh both build on
# these; neither owns them, so a second marker key never duplicates a splice
# routine (contracts/parent-marker.md).
#
# NEUTRAL layer: only the byte-level mechanics and the marker framing
# comment's own grammar live here — zero tracker vocabulary (017, FR-007).

[[ -n ${_JIRA_ENGINE_MARKER_SPLICE:-} ]] && return 0
_JIRA_ENGINE_MARKER_SPLICE=1

_mksp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_mksp_dir}/managed_section.sh" # managed_section_line_ending

# marker_splice_offset_after_line <content> <n> — byte offset immediately
# after the terminating newline of 1-based line <n> (the start of line n+1);
# or the length of <content> when the file has fewer than <n> newlines (line
# n is the file's last, unterminated, line — or n is 0, handled by the
# caller).
marker_splice_offset_after_line() {
  local content="$1" n="$2" rest="$1" consumed=0 count=0 chunk
  while ((count < n)) && [[ "${rest}" == *$'\n'* ]]; do
    chunk="${rest%%$'\n'*}"
    consumed=$((consumed + ${#chunk} + 1))
    rest="${rest#*$'\n'}"
    count=$((count + 1))
  done
  if ((count < n)); then
    printf '%s' "${#content}"
  else
    printf '%s' "${consumed}"
  fi
}

# marker_splice_line_count <content> — the total number of lines (an
# unterminated final line still counts).
marker_splice_line_count() {
  local content="$1" lineno=0 line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
  done <<< "${content}"
  printf '%s' "${lineno}"
}

# marker_splice_insert_after_line <content> <n> <text> <nl> — insert <text>
# as a new line immediately after 1-based line <n> (n=0: before line 1).
marker_splice_insert_after_line() {
  local content="$1" n="$2" text="$3" nl="$4" off
  if ((n == 0)); then
    printf '%s%s%s%s' "" "${text}" "${nl}" "${content}"
    return 0
  fi
  off=$(marker_splice_offset_after_line "${content}" "${n}")
  if ((off == ${#content})) && [[ -n "${content}" && "${content}" != *$'\n' ]]; then
    printf '%s%s%s' "${content}" "${nl}" "${text}"
    return 0
  fi
  printf '%s%s%s%s' "${content:0:off}" "${text}" "${nl}" "${content:off}"
}

# marker_splice_replace_line <content> <n> <text> <nl> — replace the WHOLE of
# 1-based line <n> (its text and terminator) with <text><nl>, preserving
# every other byte exactly.
marker_splice_replace_line() {
  local content="$1" n="$2" text="$3" nl="$4" start_off end_off before after
  start_off=$(marker_splice_offset_after_line "${content}" "$((n - 1))")
  end_off=$(marker_splice_offset_after_line "${content}" "${n}")
  before="${content:0:start_off}"
  after="${content:end_off}"
  printf '%s%s%s%s' "${before}" "${text}" "${nl}" "${after}"
}

# marker_splice_dominant_nl_token <content> — the literal newline to use for
# a written/rewritten marker line. NOT implemented as a value returned
# through command substitution: `$(...)` strips ALL trailing newlines from
# captured output, which would silently turn a literal "\n" result into an
# empty string. Call sites assign the caller-local `nl` directly instead.
marker_splice_dominant_nl_token() {
  printf '%s' "$1" | managed_section_line_ending
}

# marker_splice_write_file <path> <new-content> — write <new-content> to
# <path> ONLY IF it differs from the file's current bytes, atomically (a
# temporary file in the SAME directory, renamed over the original). Prints
# "written" or "unchanged"; the file's mtime and `git status` stay untouched
# on "unchanged".
marker_splice_write_file() {
  local path="$1" new="$2" current tmp dir
  current="$(cat "${path}" 2> /dev/null; printf x)"; current="${current%x}"
  if [[ "${current}" == "${new}" ]]; then
    printf 'unchanged'
    return 0
  fi
  dir="$(cd "$(dirname "${path}")" && pwd)"
  tmp="$(mktemp "${dir}/.speckit-jira-marker.XXXXXX")"
  printf '%s' "${new}" > "${tmp}"
  mv "${tmp}" "${path}"
  printf 'written'
  return 0
}

# marker_splice_stray_files <folder> — the top-level files of <folder>,
# excluding the two files the mirror legitimately writes markers into, that
# carry the bridge's marker framing comment (`<!-- speckit-jira … -->`),
# sorted as bare file names and joined ", " — empty when none (FR-007,
# research R9). No recursion into subdirectories; every file is only ever
# opened for reading, never for writing.
#
# The exclusion list is spec.md AND tasks.md: FR-007 reports files "this
# mirror never writes", and since 012 the task tier splices its own
# `task=<id>` markers into tasks.md on every ordinary run. Reporting those
# as stray damage would fire the warning on every healthy repository with a
# task role declared.
marker_splice_stray_files() {
  local folder="$1" f base line
  local generic_re='^<!--[[:space:]]+speckit-jira[[:space:]]+(.*)-->[[:space:]]*$'
  local -a hits=()
  for f in "${folder}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    [[ "${base}" == "spec.md" || "${base}" == "tasks.md" ]] && continue
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%$'\r'}"
      if [[ "${line}" =~ ${generic_re} ]]; then
        hits+=("${base}")
        break
      fi
    done < "${f}"
  done
  ((${#hits[@]} == 0)) && return 0
  printf '%s\n' "${hits[@]}" | jq -R -s -r 'split("\n") | map(select(length>0)) | sort | join(", ")'
}
