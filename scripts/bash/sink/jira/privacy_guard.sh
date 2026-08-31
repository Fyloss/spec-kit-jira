#!/usr/bin/env bash
# sink/jira/privacy_guard.sh — Privacy guard: BLOCK tier (US11, T048) + WARN tier
# and allowlist (US12, T090).
#
# The pre-write guard that runs before EVERY Jira write (Constitution IV/IX). Two
# tiers, precision over recall:
#
#   BLOCK (FR-052) — zero writes, dedicated exit code 9 — on an exact match of:
#     1. the ATATT token prefix          (an Atlassian API token embedded in content),
#     2. a real *.atlassian.net host      (a live Cloud coordinate), or
#     3. a known site/project coordinate  (an exact string the caller flags as real).
#
#   WARN (FR-053) — surfaced, never gating — on generic shapes (emails, UUIDs). A
#   BLOCK false positive gets the guard disabled, the exact failure Constitution IX
#   forbids, so these low-confidence shapes only warn.
#
# ALLOWLIST (FR-053): Confluence links and domains declared in `.extensionignore`
# (gitignore syntax) or the config's `privacy.allowlist` produce NEITHER a block
# NOR a warning. The exemption is evaluated PER MATCH — the payload is never
# rewritten — so an allowlist entry can only neutralise the exact text it covers
# (the match appears inside an allowlisted link, or the entry is a domain the
# match belongs to at a label boundary). A broad or overlapping entry can never
# disable detection of unrelated tokens, hosts, or coordinates (fail-closed).
# `.extensionignore` paths are excluded from both parsing and scanning.
#
# The offending value is NEVER echoed (NFR-3) — errors name only the shape.

[[ -n ${_JIRA_SINK_PRIVACY_GUARD:-} ]] && return 0
_JIRA_SINK_PRIVACY_GUARD=1

_privacy_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_privacy_guard_dir}/../../lib/cli.sh"

# _privacy_match_allowed <match> <allowlist-json> [ci:true|false] — return 0 when
# an allowlist entry covers the matched text (FR-053): the whole match appears
# inside the entry (an allowlisted link/coordinate), or the entry is a DOMAIN the
# match belongs to at a label boundary (`.entry` / `@entry` suffix). Evaluated per
# match — the payload is never rewritten — so an overlapping entry can never
# disable detection of unrelated secrets (fail-closed).
_privacy_match_allowed() {
  local m="$1" allow="${2:-[]}" ci="${3:-false}" e mm ee
  [[ -z "${m}" ]] && return 1
  while IFS= read -r e; do
    [[ -z "${e}" ]] && continue
    mm="${m}" ee="${e}"
    if [[ "${ci}" == "true" ]]; then
      mm="${mm,,}" ee="${ee,,}"
    fi
    [[ "${ee}" == *"${mm}"* ]] && return 0
    [[ "${mm}" == *".${ee}" || "${mm}" == *"@${ee}" ]] && return 0
  done < <(jq -r '.[]?' <<< "${allow}" 2> /dev/null)
  return 1
}

# _privacy_regex_hit <payload> <ere> <allowlist-json> [ci:true|false] — return 0
# when the payload carries at least one match of the shape that is NOT covered by
# the allowlist.
_privacy_regex_hit() {
  local payload="$1" re="$2" allow="${3:-[]}" ci="${4:-false}" m
  local -a grep_opts=(-oE)
  [[ "${ci}" == "true" ]] && grep_opts=(-oiE)
  while IFS= read -r m; do
    [[ -z "${m}" ]] && continue
    _privacy_match_allowed "${m}" "${allow}" "${ci}" || return 0
  done < <(grep "${grep_opts[@]}" -- "${re}" <<< "${payload}" 2> /dev/null)
  return 1
}

# privacy_guard_reason <payload> [known-coords-json] [allowlist-json] — print the
# BLOCK reason for a write payload (empty when clear). The value is never included.
# The allowlist exempts individual matches only (FR-053).
privacy_guard_reason() {
  local payload="$1" coords="${2:-[]}" allow="${3:-[]}"

  # (1) ATATT token prefix — require token characters after the prefix so the bare
  #     word "ATATT" in prose does not false-positive (precision over recall).
  if _privacy_regex_hit "${payload}" 'ATATT[A-Za-z0-9._=+/-]{2,}' "${allow}"; then
    printf 'Atlassian API token (ATATT prefix)'
    return 0
  fi

  # (2) Real *.atlassian.net host — matched case-insensitively: DNS hosts are
  #     case-insensitive, so a MiXeD-case spelling must not bypass the guard.
  if _privacy_regex_hit "${payload}" '[a-z0-9][a-z0-9-]*\.atlassian\.net' "${allow}" true; then
    printf 'Atlassian Cloud host'
    return 0
  fi

  # (3) Exact match of a known coordinate (fixed-string, precision).
  local c
  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    if grep -qF -- "${c}" <<< "${payload}" && ! _privacy_match_allowed "${c}" "${allow}"; then
      printf 'known coordinate'
      return 0
    fi
  done < <(jq -r '.[]?' <<< "${coords}" 2> /dev/null)

  return 0
}

# privacy_guard_warn_reason <payload> [allowlist-json] — print the WARN reason for
# a generic shape (empty when clear). The allowlist exempts individual matches
# (FR-053). WARN never gates a write; the caller surfaces it in the run summary.
privacy_guard_warn_reason() {
  local payload="$1" allow="${2:-[]}"

  # Email address — a generic contact shape, never a coordinate.
  if _privacy_regex_hit "${payload}" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "${allow}" true; then
    printf 'email address'
    return 0
  fi
  # UUID — a generic identifier shape.
  if _privacy_regex_hit "${payload}" '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "${allow}" true; then
    printf 'UUID'
    return 0
  fi
  return 0
}

# privacy_guard_scan <payload> [known-coords-json] [allowlist-json] — the pre-write
# gate. Returns EXIT_BLOCK (9) with a located reason on stderr when the payload
# carries a BLOCKED shape (after neutralising the allowlist); returns 0 when clear.
# Zero writes must occur on a non-zero return.
privacy_guard_scan() {
  local reason
  reason="$(privacy_guard_reason "$1" "${2:-[]}" "${3:-[]}")"
  if [[ -n "${reason}" ]]; then
    printf 'privacy: BLOCK — %s detected in a write payload; zero writes performed (FR-052)\n' "${reason}" >&2
    return "$(cli_exit_code block)"
  fi
  return 0
}

# privacy_allowlist_load <extensionignore-path> [config-allowlist-json] — build the
# canonical allow-pattern array (FR-053): the non-empty, non-comment, trimmed lines
# of `.extensionignore` merged with the config's `privacy.allowlist`, de-duplicated.
privacy_allowlist_load() {
  local ignore="$1" cfg="${2:-[]}" lines='[]'
  if [[ -f "${ignore}" ]]; then
    lines="$(grep -vE '^[[:space:]]*(#|$)' "${ignore}" 2> /dev/null \
      | sed 's/[[:space:]]*$//; s/^[[:space:]]*//' | jq -R . | jq -s .)"
    [[ -z "${lines}" ]] && lines='[]'
  fi
  jq -cn --argjson a "${lines}" --argjson b "${cfg}" '($a + $b) | map(select(. != "")) | unique'
}

# privacy_path_excluded <path> <extensionignore-path> — return 0 when the path is
# excluded from parsing and scanning by an `.extensionignore` rule (gitignore
# syntax: directory prefix, `*.ext` glob, or an exact path), non-zero otherwise.
privacy_path_excluded() {
  local path="$1" ignore="$2" line
  [[ -f "${ignore}" ]] || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="$(sed 's/[[:space:]]*$//; s/^[[:space:]]*//' <<< "${line}")"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    # Directory prefix: 'secrets/' matches secrets/ and everything under it.
    if [[ "${line}" == */ ]]; then
      [[ "${path}" == "${line}"* || "${path}" == "${line%/}" ]] && return 0
      continue
    fi
    # Glob such as '*.key' — match the whole path or its basename.
    if [[ "${line}" == \** ]]; then
      # shellcheck disable=SC2053
      [[ "${path}" == ${line} || "$(basename "${path}")" == ${line} ]] && return 0
      continue
    fi
    # Exact path or a directory name that prefixes the path.
    [[ "${path}" == "${line}" || "${path}" == "${line}/"* ]] && return 0
  done < "${ignore}"
  return 1
}

# _privacy_normalise_bytes — read arbitrary bytes on stdin, write a payload
# every host's grep will speak about on stdout.
#
# Two transformations, and neither is cosmetic:
#
#   * NUL bytes are dropped. Bash cannot hold one in a variable and drops it
#     with a warning on stderr; doing it here deliberately keeps that warning
#     out of the operator's output and makes the behaviour defined.
#   * Every other non-printable byte becomes a space. THIS is the one that
#     matters. Passing raw binary through a shell variable made `grep` stop
#     reporting matches altogether: an `ATATT…` token appended to a PNG was
#     present in the file and absent from the variable, and the guard returned
#     clear. The bytes were there; grep declined to speak about them.
#
# Mapping non-printables to spaces cannot hide a BLOCKED shape, because all
# three of them are printable ASCII — the token prefix, the host, and a known
# coordinate. It costs no recall.
#
# `LC_ALL=C` on BOTH `tr` calls, not just the second: BSD `tr` aborts with
# "Illegal byte sequence" on invalid UTF-8 under the ambient locale, so a single
# unpinned call turns the whole scan into a silent no-op on macOS.
_privacy_normalise_bytes() {
  LC_ALL=C tr -d '\0' | LC_ALL=C tr -c '[:print:]\n' ' '
}

# privacy_guard_artifact_reason <feature-dir> <set-json> [known-coords] [allow]
# — print "<path>: <reason>" for the first artifact carrying a BLOCKED shape;
# print nothing when the whole set is clear (036 C5.2, FR-016).
#
# ONE PASS, not one per artifact (C5.4). The set is concatenated into a single
# blob and scanned once, because privacy_guard_reason spawns processes of its
# own and calling it per artifact is exactly the per-item spawn
# `docs/11-process-budget.md` forbids. The blob is assembled by ONE
# `xargs -0 cat`, which does its own splitting against the host's real argument
# cap, so no command line grows with the set either.
#
# Attribution — working out WHICH artifact carried the shape — costs a second
# pass, and it is paid only on the failure path, where the run is aborting
# anyway and a message that names the file is worth far more than the cycles.
# The clear path, which is every ordinary run, stays at one pass.
#
# Binary artifacts are scanned with no special case (research R12). The BLOCKED
# shapes are ASCII byte sequences, so a byte scan finds them wherever they sit —
# an API token pasted into an image's metadata is not hypothetical. Reading the
# blob into a shell variable drops NUL bytes; that cannot hide a contiguous
# ASCII match, so it costs no recall, and inventing a text/binary discriminator
# would create a class of file the guard does not cover at all.
privacy_guard_artifact_reason() {
  local dir="$1" set_json="$2" coords="${3:-[]}" allow="${4:-[]}"

  [[ -d "${dir}" ]] || return 0
  local n
  n="$(jq -r 'length' <<< "${set_json}" 2> /dev/null)" || return 0
  [[ -n "${n}" ]] && [[ "${n}" -gt 0 ]] || return 0

  local tmp
  tmp="$(mktemp -d)" || return 1

  # Absolute paths, NUL-separated, so a path holding a space or a newline
  # survives the hand-off to xargs. `jq -j` writes no separator of its own; the
  # NUL is emitted explicitly from the filter.
  jq -jr --arg d "${dir}" '.[] | $d + "/" + .path + "\u0000"' <<< "${set_json}" > "${tmp}/paths_z" 2> /dev/null

  # One `xargs -0 cat` for the whole set, then NORMALISE TO TEXT before the
  # scan. Both halves of that are load-bearing and neither is obvious:
  #
  #   * `tr -d '\0'` — bash cannot hold a NUL in a variable and drops it with a
  #     warning on stderr. Dropping it deliberately keeps the warning out of the
  #     operator's output and makes the behaviour defined rather than incidental.
  #   * `tr -c '[:print:]\n' ' '` — this is the one that MATTERS. Passing raw
  #     binary through a shell variable made `grep` stop reporting matches
  #     entirely: an `ATATT…` token appended to a PNG was present in the blob
  #     FILE, absent from the blob VARIABLE, and the guard returned clear. The
  #     bytes were there; grep declined to speak about them.
  #
  # Mapping every non-printable byte to a space cannot hide a BLOCKED shape,
  # because all three of them are printable ASCII: the token prefix, the host,
  # and a known coordinate. It costs no recall and buys a payload every host's
  # grep treats identically.
  xargs -0 cat < "${tmp}/paths_z" 2> /dev/null | _privacy_normalise_bytes > "${tmp}/blob" || true

  local blob reason
  blob="$(cat "${tmp}/blob" 2> /dev/null)"
  reason="$(privacy_guard_reason "${blob}" "${coords}" "${allow}")"

  if [[ -z "${reason}" ]]; then
    rm -rf "${tmp}"
    return 0
  fi

  # Failure path only: find the artifact so the message can name it.
  local p per
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    per="$(privacy_guard_reason \
      "$(_privacy_normalise_bytes < "${dir}/${p}" 2> /dev/null)" \
      "${coords}" "${allow}")"
    if [[ -n "${per}" ]]; then
      rm -rf "${tmp}"
      printf '%s: %s' "${p}" "${per}"
      return 0
    fi
  done < <(jq -r '.[].path' <<< "${set_json}" 2> /dev/null)

  # The blob matched but no single artifact did: the shape straddles a file
  # boundary in the concatenation. Report it without naming a file rather than
  # letting the run proceed — fail closed on the ambiguous case.
  rm -rf "${tmp}"
  printf '(across the artifact set): %s' "${reason}"
}

# privacy_guard_scan_artifacts <feature-dir> <set-json> [coords] [allow] — the
# pre-write gate for artifact content (036 C5.1, C5.3, C5.5, FR-016).
#
# Returns EXIT_BLOCK (9) with a located reason on stderr when any artifact
# carries a BLOCKED shape; returns 0 when the set is clear. On a non-zero
# return the caller must perform ZERO writes of EVERY kind — not merely zero
# attachments. Publication runs after the description and story writes, so a
# guard placed beside the upload could only refuse the upload while the rest
# had already landed; this one runs at the pre-write sweep instead.
privacy_guard_scan_artifacts() {
  local reason
  reason="$(privacy_guard_artifact_reason "$1" "$2" "${3:-[]}" "${4:-[]}")"
  if [[ -n "${reason}" ]]; then
    printf 'privacy: BLOCK — %s detected in a feature artifact; zero writes performed (FR-016)\n' "${reason}" >&2
    return "$(cli_exit_code block)"
  fi
  return 0
}
