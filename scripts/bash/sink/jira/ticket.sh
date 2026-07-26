#!/usr/bin/env bash
# sink/jira/ticket.sh — Ticket read/create (SINK layer, 002 US3, FR-013).
#
# Two operations for the feature-naming ceremony, both through the existing
# transport (client.sh):
#
#   * ticket_validate <key>          — READ-ONLY GET /issue/{key}?fields=project
#     of a MENTIONED key; prints the neutral {key, project} document. A
#     fail-closed read (404/5xx/network/auth) propagates the transport's mapped
#     exit code with zero stdout (Constitution III) — a mentioned key never
#     silently falls back.
#
#   * ticket_create <project> <summary> <story-type-id> [labels] [components] [spec-ref]
#     — GUARDED WRITE POST /issue in the given project with the CALLER's resolved
#     story-type id (never a literal type name — Constitution VII). The PASS-1
#     privacy guard scans the body BEFORE the POST (BLOCK ⇒ exit 9, zero writes,
#     Constitution IX); the created ticket is identity-stamped like any
#     bridge-created artifact. Prints the neutral {key} document.

[[ -n ${_JIRA_SINK_TICKET:-} ]] && return 0
_JIRA_SINK_TICKET=1

_ticket_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ticket_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_ticket_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_ticket_dir}/client.sh"
# shellcheck source=/dev/null
source "${_ticket_dir}/privacy_guard.sh"
# shellcheck source=/dev/null
source "${_ticket_dir}/identity.sh"

# ticket_validate <issue-key> — read the mentioned key's project (fields=project).
# Prints {key, project} on stdout; a fail-closed read propagates its exit code.
ticket_validate() {
  local key="$1"
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'ticket: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  local api="${base}/rest/api/3"
  local resp
  resp="$(jira_request GET "${api}/issue/${key}?fields=project")" || return $?
  jq -cn --arg k "${key}" --argjson r "${resp}" \
    '{key: $k, project: ($r.fields.project.key // null)}' | json_canonical
}

# _ticket_create_body <project> <summary> <story-type-id> — the canonical create
# payload. The issue type is carried by ID only (never a literal name).
_ticket_create_body() {
  local project="$1" summary="$2" typeid="$3"
  jq -cn --arg p "${project}" --arg s "${summary}" --arg t "${typeid}" \
    '{fields: {project: {key: $p}, issuetype: {id: $t}, summary: $s}}'
}

# ticket_create <project> <summary> <story-type-id> [labels-json] [components-json] [spec-ref-json]
# Guarded write: PASS-1 privacy guard, POST /issue, identity stamp. Prints {key}.
ticket_create() {
  local project="$1" summary="$2" typeid="$3"
  local spec_ref="${6:-}"
  [[ -z "${spec_ref}" ]] && spec_ref='{}'
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'ticket: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  local api="${base}/rest/api/3"

  local body
  body="$(_ticket_create_body "${project}" "${summary}" "${typeid}")"

  # (1) Pre-write gate — BLOCK ⇒ exit 9, zero writes (Constitution IX).
  privacy_guard_scan "${body}" "[]" "${SPEC_KIT_JIRA_ALLOWLIST:-[]}" || return $?

  # (2) The create write. Run in the current shell (stdout to a temp file) so a
  #     failure propagates its transport exit code (non-blocking fallback lives
  #     in the command layer, never here). The `|| rc=$?` guard keeps the entry
  #     point's errexit from aborting mid-capture with a raw curl code.
  local tmp resp rc=0
  tmp="$(mktemp)"
  jira_request POST "${api}/issue" "${body}" > "${tmp}" || rc=$?
  resp="$(cat "${tmp}")"
  rm -f "${tmp}"
  ((rc != 0)) && return "${rc}"

  local key
  key="$(jq -r '.key' <<< "${resp}")"

  # (3) Identity stamp — the created ticket is a bridge-created artifact.
  identity_write "${key}" "${spec_ref}" "bridge" || return $?

  jq -cn --arg k "${key}" '{key: $k}' | json_canonical
}
