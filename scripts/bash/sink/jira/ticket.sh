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

# jira_create_fields_base <project> <summary> <issue-type-id>
#   [<field_defaults_by_type_json>] [<provenance-label>]
# — the mandatory base every creation path must produce: {project, issuetype,
# summary} (research R3, FR-025), plus (011, research R2) any recorded
# defaults for the type actually being created. Both `_ticket_create_body`
# and `plan_writes` build on this single builder so the two creation paths
# cannot drift apart again. The issue type is carried by ID only (never a
# literal name — Constitution VII).
#
# field_defaults_by_type_json is the WHOLE plan-context map, {type_id:
# {field_id: value}} — this function itself scopes the merge to `typeid`,
# so a caller cannot get FR-018 wrong by passing the wrong sub-map: a
# default recorded for a different issue type never reaches this payload.
# Omitted or empty ⇒ the merge is a no-op (FR-028, research R6).
#
# provenance-label (017, contracts/provenance-label.md §2) is OPTIONAL and
# passed by `plan_writes` (the mirror) ONLY — `_ticket_create_body` (the
# feature ceremony) never passes it, because in the normal `before_specify`
# state the specification folder does not exist yet and `commands/feature.sh`
# builds `spec_ref.spec_slug` as the literal fallback "spec"; passing it
# through would stamp `speckit-spec` — a label naming no specification — onto
# every ceremony ticket. When given, it is merged into `labels` AFTER the
# field-defaults spread above, as a union with whatever default the type
# records, so a recorded `labels` default is preserved rather than
# overwritten (contract §2 "Merge order on creation is load-bearing"). When
# empty, no `labels` key is produced at all.
jira_create_fields_base() {
  local project="$1" summary="$2" typeid="$3" defaults_by_type="${4:-}" provenance="${5:-}"
  [[ -z "${defaults_by_type}" ]] && defaults_by_type='{}'
  jq -cn --arg p "${project}" --arg s "${summary}" --arg t "${typeid}" --argjson dbt "${defaults_by_type}" --arg prov "${provenance}" \
    '{project: {key: $p}, issuetype: {id: $t}, summary: $s} + (($dbt[$t]) // {})
     + (if $prov == "" then {} else {labels: (((($dbt[$t]) // {}).labels // []) + [$prov] | unique)} end)'
}

# ticket_field_rejection_message <defaultable_fields_by_type_json> <action_json>
# <error_body_json> — 011, contract §3.7, FR-019: when Jira rejects a creation
# because a value THIS RUN sent — from a recorded default or a this-run
# answer — is no longer valid, translate Jira's raw error body into one line
# per rejected field, naming it by its Jira label and the value that was
# sent, and the rejection in Jira's own words — never the raw API body.
#
# Only a field that (a) this run actually SENT in the action's own body and
# (b) is one of the type's defaultable_fields is reported here — a rejection
# on a bridge-supplied field (summary, description, …) is a different defect
# and is left to the existing generic failure path. Prints one line per
# rejected field, newline-joined, empty when Jira's rejected fields do not
# overlap anything this run defaulted.
ticket_field_rejection_message() {
  local df="${1:-}" action="${2:-{\}}" errbody="${3:-{\}}"
  [[ -z "${df}" ]] && df='{}'
  [[ -z "${errbody}" ]] && errbody='{}'
  jq -e . > /dev/null 2>&1 <<< "${errbody}" || errbody='{}'
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -rn --argjson df "${df}" --argjson a "${action}" --argjson e "${errbody}" '
    (($a.body.fields.issuetype.id) // "") as $tid
    | (($df[$tid]) // []) as $fields
    | (($e.errors) // {}) | to_entries[] | . as $err
    | (first($fields[] | select(.field_id == $err.key)) // null) as $meta
    | select($meta != null and ($a.body.fields | has($err.key)))
    | "reconcile: Jira rejected the value for \"\($meta.logical_name)\" — sent \($a.body.fields[$err.key] | tostring), rejected because: \($err.value). Nothing was substituted and the creation was not retried."
  '
  # kcov-excl-stop
}

# _ticket_create_body <project> <summary> <story-type-id> — the canonical create
# payload: wraps jira_create_fields_base unchanged. Deliberately passes NO
# provenance argument (017, contract §2): the feature ceremony's single-item
# creation stays unlabelled at creation, and its specification's first
# reconcile back-fills the label like any other unlabelled ticket.
_ticket_create_body() {
  local project="$1" summary="$2" typeid="$3"
  jq -cn --argjson base "$(jira_create_fields_base "${project}" "${summary}" "${typeid}")" \
    '{fields: $base}'
}

# ticket_create <project> <summary> <story-type-id> [labels-json] [components-json] [spec-ref-json] [role]
# Guarded write: PASS-1 privacy guard, POST /issue, identity stamp. Prints {key}.
# <role> (027, FR-023) is optional and empty by default — the feature
# ceremony's own ordinary ticket has no role in the 027 sense; a seed-created
# parent passes "parent" so reconcile's own recognition can tell a
# bridge-created parent from any other bridge-created issue.
ticket_create() {
  local project="$1" summary="$2" typeid="$3"
  local spec_ref="${6:-}" role="${7:-}"
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
  # The summary this create sent becomes the LAST-WRITTEN summary record
  # (018, contracts/summary-record.md §1/§2): a later reconcile compares
  # against it, never against the text that seeded the create.
  identity_write "${key}" "${spec_ref}" "bridge" "" "${role}" "${summary}" || return $?

  jq -cn --arg k "${key}" '{key: $k}' | json_canonical
}
