#!/usr/bin/env bash
# sink/jira/plan_apply.sh — The Jira write path (US11 gate; extended by US3).
#
# `apply_writes` executes an ordered action set against Jira. Its FIRST
# responsibility (US11, T049) is the mandatory pre-write privacy gate: every
# action's content payload is scanned through the BLOCK guard BEFORE any write is
# performed. A single blocked payload aborts the whole apply with EXIT_BLOCK (9)
# and ZERO writes — there is no gap through which a leak could reach Jira
# (Constitution IV, FR-052).
#
# US3 (T058) fleshes out plan_writes / the richer action set (create / update /
# transition / comment / link / label, estimation create-only). This module owns
# the guard-then-write ordering; the guard placement is invariant across that
# extension.
#
# Action shape: [ {method, url, body?}, ... ]. Only the content `body` is scanned
# (the request URL necessarily targets the real host and is not content).

[[ -n ${_JIRA_SINK_PLAN_APPLY:-} ]] && return 0
_JIRA_SINK_PLAN_APPLY=1

_plan_apply_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/privacy_guard.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/client.sh"

# _apply_known_coords <extra-json> — the known-coordinate set the guard checks:
# the real site host derived from SPEC_KIT_JIRA_BASE_URL plus any caller extras.
_apply_known_coords() {
  local extra="${1:-[]}" base="${SPEC_KIT_JIRA_BASE_URL:-}" host=""
  host="$(sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#:[0-9]+$##' <<< "${base}")"
  jq -cn --arg h "${host}" --argjson e "${extra}" \
    '($e + (if $h == "" then [] else [$h] end)) | unique'
}

# apply_writes <actions-json> [extra-known-coords-json] — guard every payload,
# then perform the writes in order. Returns EXIT_BLOCK (9) with zero writes if any
# payload is blocked; otherwise returns the worst (highest) transport exit code.
apply_writes() {
  local actions="$1" extra="${2:-[]}"
  local coords
  coords="$(_apply_known_coords "${extra}")"

  local n
  n="$(jq 'length' <<< "${actions}")"

  # (1) Pre-write gate — scan every content payload before writing anything.
  local i body
  for ((i = 0; i < n; i++)); do
    body="$(jq -c ".[${i}].body // {}" <<< "${actions}")"
    privacy_guard_scan "${body}" "${coords}" || return $?
  done

  # (2) Write pass — all payloads cleared; perform each write in order.
  local worst=0 method url rc
  for ((i = 0; i < n; i++)); do
    method="$(jq -r ".[${i}].method" <<< "${actions}")"
    url="$(jq -r ".[${i}].url" <<< "${actions}")"
    body="$(jq -c ".[${i}].body // empty" <<< "${actions}")"
    if [[ -n "${body}" ]]; then
      jira_request "${method}" "${url}" "${body}" > /dev/null
    else
      jira_request "${method}" "${url}" > /dev/null
    fi
    rc=$?
    ((rc > worst)) && worst=${rc}
  done
  return "${worst}"
}
