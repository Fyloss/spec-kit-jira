#!/usr/bin/env bash
# sink/jira/duplicate_probe.sh — User Story 4 (017, contracts/duplicate-probe.md).
#
# A best-effort, read-only check for tickets already labelled with this
# specification's provenance label, consulted only before CREATING a parent
# the specification holds no marker for. It queries the same eventually
# consistent index recognition.sh deliberately never reads (feature 005
# removed search from recognition for exactly this reason) — its false
# negative leaves today's behaviour unchanged, and its true positive
# prevents a write, so it can only fail to help. SC-001 rests on the marker
# line, not on this.
#
# THIS IS THE DROPPABLE SLICE (contract §0): delete this file, its
# PowerShell twin, and the three call-site lines in reconcile.sh to remove
# User Story 4 entirely — nothing else depends on it.

[[ -n ${_JIRA_SINK_DUPLICATE_PROBE:-} ]] && return 0
_JIRA_SINK_DUPLICATE_PROBE=1

_dup_probe_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_dup_probe_dir}/client.sh"
# shellcheck source=/dev/null
source "${_dup_probe_dir}/../../lib/output.sh" # uri_encode — the %20->+ normalisation (research §11)

# duplicate_probe_check <base-url> <project-key> <label> — contract §3's
# query, issued through the existing jira_request transport (same
# credentials, same retry policy, same base-URL stripping). Prints exactly
# one of:
#   {"verdict":"clear"}
#   {"verdict":"hit","keys":["<sorted>",...]}
#   {"verdict":"unavailable"}
# Never returns non-zero itself: jira_request's own non-2xx (contract §4 —
# ANY non-2xx, not only a network failure) folds into "unavailable" rather
# than propagating as a transport error, so the caller never needs a
# separate error path.
duplicate_probe_check() {
  local base="$1" project="$2" label="$3"
  local jql_raw jql url resp
  jql_raw="$(jq -rn --arg p "${project}" --arg l "${label}" \
    '"project = \"" + $p + "\" AND labels = \"" + $l + "\""')"
  jql="$(uri_encode "${jql_raw}")"
  url="${base}/rest/api/3/search/jql?jql=${jql}&fields=key&maxResults=50"
  if ! resp="$(jira_request GET "${url}")"; then
    printf '{"verdict":"unavailable"}'
    return 0
  fi
  local keys
  keys="$(jq -c '[(.issues // [])[].key] | sort' <<< "${resp}" 2> /dev/null)"
  [[ -z "${keys}" ]] && keys='[]'
  if [[ "$(jq 'length' <<< "${keys}")" -eq 0 ]]; then
    printf '{"verdict":"clear"}'
  else
    jq -cn --argjson k "${keys}" '{verdict:"hit", keys:$k}'
  fi
}
