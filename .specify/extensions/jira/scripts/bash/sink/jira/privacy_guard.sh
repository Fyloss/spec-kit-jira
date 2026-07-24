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
# NOR a warning — the allowlisted substrings are neutralised before either tier
# scans, so an allowlisted Confluence host on `*.atlassian.net` never false-blocks.
# `.extensionignore` paths are excluded from both parsing and scanning.
#
# The offending value is NEVER echoed (NFR-3) — errors name only the shape.

[[ -n ${_JIRA_SINK_PRIVACY_GUARD:-} ]] && return 0
_JIRA_SINK_PRIVACY_GUARD=1

_privacy_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_privacy_guard_dir}/../../lib/cli.sh"

# _privacy_sanitize <payload> <allowlist-json> — remove every allowlisted entry
# (fixed-string) from a working copy of the payload so neither tier scans it.
_privacy_sanitize() {
  local payload="$1" allow="${2:-[]}" e
  while IFS= read -r e; do
    [[ -z "${e}" ]] && continue
    payload="${payload//"${e}"/}"
  done < <(jq -r '.[]?' <<< "${allow}" 2> /dev/null)
  printf '%s' "${payload}"
}

# privacy_guard_reason <payload> [known-coords-json] [allowlist-json] — print the
# BLOCK reason for a write payload (empty when clear). The value is never included.
# Allowlisted substrings are neutralised before the scan (FR-053).
privacy_guard_reason() {
  local payload="$1" coords="${2:-[]}" allow="${3:-[]}" scan
  scan="$(_privacy_sanitize "${payload}" "${allow}")"

  # (1) ATATT token prefix — require token characters after the prefix so the bare
  #     word "ATATT" in prose does not false-positive (precision over recall).
  if grep -qE 'ATATT[A-Za-z0-9._=+/-]{2,}' <<< "${scan}"; then
    printf 'Atlassian API token (ATATT prefix)'
    return 0
  fi

  # (2) Real *.atlassian.net host (case-sensitive lowercase, as hosts are).
  if grep -qE '[a-z0-9][a-z0-9-]*\.atlassian\.net' <<< "${scan}"; then
    printf 'Atlassian Cloud host'
    return 0
  fi

  # (3) Exact match of a known coordinate (fixed-string, precision).
  local c
  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    if grep -qF -- "${c}" <<< "${scan}"; then
      printf 'known coordinate'
      return 0
    fi
  done < <(jq -r '.[]?' <<< "${coords}" 2> /dev/null)

  return 0
}

# privacy_guard_warn_reason <payload> [allowlist-json] — print the WARN reason for a
# generic shape (empty when clear). Allowlisted substrings are neutralised first
# (FR-053). WARN never gates a write; the caller surfaces it in the run summary.
privacy_guard_warn_reason() {
  local payload="$1" allow="${2:-[]}" scan
  scan="$(_privacy_sanitize "${payload}" "${allow}")"

  # Email address — a generic contact shape, never a coordinate.
  if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' <<< "${scan}"; then
    printf 'email address'
    return 0
  fi
  # UUID — a generic identifier shape.
  if grep -qE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' <<< "${scan}"; then
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
