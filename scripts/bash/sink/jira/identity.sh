#!/usr/bin/env bash
# sink/jira/identity.sh — Ticket identity marker (US3, T057; research §5).
#
# A bridge ticket's identity lives in a server-side ENTITY PROPERTY, never a
# user-editable label or summary (Constitution II): entity properties are stable,
# hidden from the editable UI, and survive a spec-folder rename (identity resolves
# the stored marker, not the path). The marker records the origin
# (bridge-created / human) and the spec ref; the spec ref is the discriminator for
# "claimed by another spec" (US10 / FR-051). The identity property is per-issue,
# so it is inherently per-project scoped (FR-044).
#
# The property key is a constant OURS (not an Atlassian default): `spec-kit-jira`.

[[ -n ${_JIRA_SINK_IDENTITY:-} ]] && return 0
_JIRA_SINK_IDENTITY=1

_identity_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_identity_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_identity_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_identity_dir}/client.sh"

: "${SPEC_KIT_JIRA_IDENTITY_KEY:=spec-kit-jira}"

# identity_marker <spec-ref-json> <origin> [story-id] — build the canonical
# marker value. `story` (Phase 2, contracts/story-marker.md) is the durable
# story identifier; it is omitted when absent — the feature-naming ceremony
# and the mentioned-ticket flow mirror a whole feature rather than one story,
# and those tickets are not story tickets (data-model.md "Identity marker").
identity_marker() {
  local spec_ref="$1" origin="$2" story="${3:-}"
  jq -cn --argjson s "${spec_ref}" --arg o "${origin}" --arg story "${story}" \
    '{origin:$o, repo:($s.repo // ""), spec_slug:($s.spec_slug // "")}
     + (if $story == "" then {} else {story:$story} end)' | json_canonical
}

# identity_claimed_by_other <marker-json> <spec-ref-json> — return 0 when the
# stored marker belongs to a DIFFERENT spec (different repo or spec_slug), and a
# non-zero status when it is the same spec (not claimed by another).
identity_claimed_by_other() {
  local marker="$1" spec_ref="$2" same
  same="$(jq -r --argjson s "${spec_ref}" \
    'if (.repo == ($s.repo // "")) and (.spec_slug == ($s.spec_slug // "")) then "1" else "0" end' \
    <<< "${marker}")"
  [[ "${same}" == "0" ]]
}

# _identity_url <issue-key> — the entity-property URL for the identity key.
_identity_url() {
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  printf '%s/rest/api/3/issue/%s/properties/%s' "${base}" "$1" "${SPEC_KIT_JIRA_IDENTITY_KEY}"
}

# identity_read <issue-key> — print the stored marker value (the property's
# `.value`) on stdout, or nothing when the ticket carries no identity yet. A 404
# means "unclaimed", NOT a failure (returns 0); any other transport failure
# propagates its mapped exit code (fail-closed, Constitution III).
identity_read() {
  if [[ -z "${SPEC_KIT_JIRA_BASE_URL:-}" ]]; then
    printf 'identity: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  # Run the transport in the CURRENT shell (stdout to a temp file, not a command
  # substitution) so JIRA_LAST_STATUS is visible here — a subshell would hide it.
  local url resp rc tmp
  url="$(_identity_url "$1")"
  tmp="$(mktemp)"
  jira_request GET "${url}" > "${tmp}"
  rc=$?
  resp="$(cat "${tmp}")"
  rm -f "${tmp}"
  if ((rc == 0)); then
    jq -c '.value // empty' <<< "${resp}" | json_canonical
    return 0
  fi
  # A missing property is a normal "no identity yet", not a fail-closed error.
  if [[ "${JIRA_LAST_STATUS:-}" == "404" ]]; then
    return 0
  fi
  return "${rc}"
}

# identity_write <issue-key> <spec-ref-json> <origin> [story-id] — stamp the
# identity marker on the ticket via the entity property. Returns the
# transport exit code.
identity_write() {
  local key="$1" spec_ref="$2" origin="$3" story="${4:-}"
  if [[ -z "${SPEC_KIT_JIRA_BASE_URL:-}" ]]; then
    printf 'identity: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  local url marker
  url="$(_identity_url "${key}")"
  marker="$(identity_marker "${spec_ref}" "${origin}" "${story}")"
  jira_request PUT "${url}" "${marker}" > /dev/null
}
