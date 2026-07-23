#!/usr/bin/env bash
# sink/jira/privacy_guard.sh — Privacy guard BLOCK tier (US11, T048).
#
# The pre-write guard that runs before EVERY Jira write (Constitution IV/IX,
# FR-052). It blocks — zero writes, dedicated exit code 9 — on an exact match of:
#
#   1. the ATATT token prefix          (an Atlassian API token embedded in content),
#   2. a real *.atlassian.net host      (a live Cloud coordinate), or
#   3. a known site/project coordinate  (an exact string the caller flags as real).
#
# PRECISION OVER RECALL: the guard matches only these specific, high-confidence
# shapes. The generic shapes (emails, UUIDs) belong to the P3 WARN tier (US12) and
# do NOT block here — a BLOCK false positive gets the guard disabled, which is the
# exact failure mode Constitution IX forbids. The documentation-host allowlist
# exemption is the P3 refinement (US12/T090); at this tier every real Atlassian
# host blocks.
#
# The offending value is NEVER echoed (NFR-3) — the error names only the shape.

[[ -n ${_JIRA_SINK_PRIVACY_GUARD:-} ]] && return 0
_JIRA_SINK_PRIVACY_GUARD=1

_privacy_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_privacy_guard_dir}/../../lib/cli.sh"

# privacy_guard_reason <payload> [known-coords-json] — print the BLOCK reason for
# a write payload (empty when clear). The value itself is never included.
privacy_guard_reason() {
  local payload="$1" coords="${2:-[]}"

  # (1) ATATT token prefix — require token characters after the prefix so the bare
  #     word "ATATT" in prose does not false-positive (precision over recall).
  if grep -qE 'ATATT[A-Za-z0-9._=+/-]{2,}' <<< "${payload}"; then
    printf 'Atlassian API token (ATATT prefix)'
    return 0
  fi

  # (2) Real *.atlassian.net host (case-sensitive lowercase, as hosts are).
  if grep -qE '[a-z0-9][a-z0-9-]*\.atlassian\.net' <<< "${payload}"; then
    printf 'Atlassian Cloud host'
    return 0
  fi

  # (3) Exact match of a known coordinate (fixed-string, precision).
  local c
  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    if grep -qF -- "${c}" <<< "${payload}"; then
      printf 'known coordinate'
      return 0
    fi
  done < <(jq -r '.[]?' <<< "${coords}" 2> /dev/null)

  return 0
}

# privacy_guard_scan <payload> [known-coords-json] — the pre-write gate. Returns
# EXIT_BLOCK (9) with a located reason on stderr when the payload carries a
# blocked shape; returns 0 when clear. Zero writes must occur on a non-zero return
# (the caller performs writes only after every payload has passed).
privacy_guard_scan() {
  local reason
  reason="$(privacy_guard_reason "$1" "${2:-[]}")"
  if [[ -n "${reason}" ]]; then
    printf 'privacy: BLOCK — %s detected in a write payload; zero writes performed (FR-052)\n' "${reason}" >&2
    return "$(cli_exit_code block)"
  fi
  return 0
}
