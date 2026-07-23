#!/usr/bin/env bash
# lib/output.sh — Canonical serialisation + run-summary rendering.
#
# The canonical serialiser is the byte-parity contract (Constitution VI, NFR-1,
# research §11): stable key ordering, compact, raw UTF-8, no trailing newline.
# Both ports MUST emit identical bytes for identical input; the PowerShell port
# reimplements the same canonical form (see lib/Output.psm1) rather than relying
# on ConvertTo-Json's native formatting.
#
# Port infrastructure only: NO Jira knowledge.

[[ -n ${_JIRA_LIB_OUTPUT:-} ]] && return 0
_JIRA_LIB_OUTPUT=1

# json_canonical — read JSON on stdin, write the canonical form to stdout.
#   - keys sorted (-S), compact (-c)
#   - raw UTF-8 (jq does not \u-escape non-ASCII)
#   - no trailing newline (command substitution strips jq's)
json_canonical() {
  printf '%s' "$(jq -cS .)"
}

# uri_encode <string> — percent-encode for a query component, applying the
# @uri rule and the %20->+ normalisation (research §11).
uri_encode() {
  local encoded
  encoded="$(jq -rn --arg s "$1" '$s|@uri')"
  printf '%s' "${encoded//%20/+}"
}
