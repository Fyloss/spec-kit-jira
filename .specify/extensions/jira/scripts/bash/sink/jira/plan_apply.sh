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
source "${_plan_apply_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/privacy_guard.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/client.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/adf.sh"

# plan_writes <neutral-doc-json> <plan-context-json> — resolve the validated
# neutral document into an ordered action set (US3, T058). Each story becomes a
# create OR an update, with logical values resolved to ids (FR-017 priority by
# logical name) and the estimation written to the discovered field ON CREATE ONLY
# (FR-018 — never re-sent on update). The `--dry-run` report is exactly this
# action set (FR-033); no Jira mutation happens here. apply_writes performs it.
#
# plan-context carries the resolved facts the engine cannot know:
#   { base_url, story_type_id, priority_ids:{P1,P2,P3}, estimation_field_id|null,
#     tickets:{<local_id>: <existing-issue-key>} }   (a local_id absent => create)
plan_writes() {
  local doc="$1" ctx="$2"
  local base story_type estid
  base="$(jq -r '.base_url // ""' <<< "${ctx}")"
  story_type="$(jq -r '.story_type_id // ""' <<< "${ctx}")"
  estid="$(jq -r '.estimation_field_id // ""' <<< "${ctx}")"

  local actions="[]" n i
  n="$(jq '.stories | length' <<< "${doc}")"
  for ((i = 0; i < n; i++)); do
    local story sid title prio est ticket priority_id adf fields action
    story="$(jq -c ".stories[${i}]" <<< "${doc}")"
    sid="$(jq -r '.local_id' <<< "${story}")"
    title="$(jq -r '.title' <<< "${story}")"
    prio="$(jq -r '.priority_logical' <<< "${story}")"
    est="$(jq -c '.estimation // null' <<< "${story}")"
    ticket="$(jq -r --arg s "${sid}" '.tickets[$s] // ""' <<< "${ctx}")"
    priority_id="$(jq -r --arg p "${prio}" '.priority_ids[$p] // ""' <<< "${ctx}")"
    adf="$(adf_render_description "${story}")"

    if [[ -z "${ticket}" ]]; then
      # CREATE: full content + issuetype + priority + estimation (create-only).
      fields="$(jq -cn --arg t "${title}" --argjson d "${adf}" --arg it "${story_type}" \
        '{summary:$t, description:$d} + (if $it == "" then {} else {issuetype:{id:$it}} end)')"
      [[ -n "${priority_id}" ]] && fields="$(jq -c --arg pid "${priority_id}" '. + {priority:{id:$pid}}' <<< "${fields}")"
      if [[ -n "${estid}" && "${est}" != "null" ]]; then
        fields="$(jq -c --arg fid "${estid}" --argjson v "${est}" '. + {($fid): $v}' <<< "${fields}")"
      fi
      action="$(jq -cn --arg u "${base}/rest/api/3/issue" --argjson f "${fields}" \
        '{method:"POST", url:$u, body:{fields:$f}}')"
    else
      # UPDATE: content + priority; the estimation is NEVER re-sent (FR-018).
      fields="$(jq -cn --arg t "${title}" --argjson d "${adf}" '{summary:$t, description:$d}')"
      [[ -n "${priority_id}" ]] && fields="$(jq -c --arg pid "${priority_id}" '. + {priority:{id:$pid}}' <<< "${fields}")"
      action="$(jq -cn --arg u "${base}/rest/api/3/issue/${ticket}" --argjson f "${fields}" \
        '{method:"PUT", url:$u, body:{fields:$f}}')"
    fi
    actions="$(jq -c --argjson a "${action}" '. + [$a]' <<< "${actions}")"
  done
  json_canonical <<< "${actions}"
}

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
