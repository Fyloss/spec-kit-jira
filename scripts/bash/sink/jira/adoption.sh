#!/usr/bin/env bash
# sink/jira/adoption.sh — Adoption discovery against Jira (SINK layer, 003 US1).
#
# Everything Jira-shaped about adoption lives here, and here only: the JQL label
# search and its cursor pagination, the per-candidate context read, the identity
# claim read, and the issue-key SHAPE validation for `--bind` (research §9 puts
# the key regex in the sink so no key-shaped literal enters the neutral layers).
#
# Discovery is READ-ONLY. The single write kind adoption ever emits is the
# identity entity-property stamp; its URL and payload are composed HERE from the
# same `identity_marker` builder the `mention` command uses, so the two paths
# cannot drift in what they stamp, and the ordered action set is executed by the
# existing `apply_writes` (research §7) — which is how the pre-write privacy
# guard and the fail-closed abort ladder are inherited rather than re-implemented.
#
# Pagination loops on `nextPageToken` until the response omits it. A truncated
# candidate list would turn a two-candidate ambiguity (which must be refused)
# into a one-candidate binding (which would be applied), so exhaustion is a
# correctness requirement, not a performance nicety (NFR-6, research §2).

[[ -n ${_JIRA_SINK_ADOPTION:-} ]] && return 0
_JIRA_SINK_ADOPTION=1

_adoption_sink_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_adoption_sink_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_adoption_sink_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_adoption_sink_dir}/client.sh"
# shellcheck source=/dev/null
source "${_adoption_sink_dir}/identity.sh"

# Page size requested from the search endpoint. The loop honours whatever the
# server actually returns; this is only the ask.
: "${ADOPT_SEARCH_PAGE_SIZE:=100}"

# The fields the candidate context needs, and the only ones ever requested.
_ADOPT_FIELDS='labels,parent,project'

# _adopt_api — the REST base, or a fail-closed error when the site is unset.
_adopt_api() {
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'adopt: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  printf '%s/rest/api/3' "${base}"
}

# _adopt_candidate_from_issue — read one search/issue payload on stdin and print
# the neutral candidate shape the engine consumes as opaque JSON (data-model §4).
# `identity` starts null; the claim read fills it.
_adopt_candidate_from_issue() {
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c '{key: .key,
          project_key: (.fields.project.key // ""),
          labels: (.fields.labels // []),
          parent_key: (.fields.parent.key // null),
          identity: null}'
  # kcov-excl-stop
}

# adopt_search_candidates <targets-json> — one paginated JQL label search per
# DISTINCT routed project (never one per spec folder), over the union of that
# project's derived label values. The JQL is assembled from those values alone,
# never from free text, so a label naming no spec in scope is not even in the
# query. Any unreliable read aborts the whole run before any write by propagating
# the transport's mapped exit code (FR-008). Prints the canonical candidate array
# ordered by key ascending.
adopt_search_candidates() {
  local targets="${1:-[]}" api
  api="$(_adopt_api)" || return $?

  # project -> the union of every label value that project's targets imply,
  # including the SUPPRESSED short forms: a value that may not bind must still be
  # discoverable, or the ambiguity it represents could never be reported.
  local plan projects
  # kcov-excl-start — jq literal (string lines are not statements)
  plan="$(jq -c '
    reduce .[] as $t ({};
      .[$t.project_key] = (((.[$t.project_key] // []) + $t.labels + ($t.probe_labels // [])) | unique))
  ' <<< "${targets}")"
  # kcov-excl-stop
  projects="$(jq -r 'keys[]' <<< "${plan}")"

  local out='[]' project
  while IFS= read -r project; do
    [[ -z "${project}" ]] && continue
    local values jql token="" prev_token=""
    values="$(jq -r --arg p "${project}" '.[$p] | map("\"" + . + "\"") | join(", ")' <<< "${plan}")"
    jql="project = \"${project}\" AND labels IN (${values})"
    while :; do
      local url page issues count
      url="${api}/search/jql?jql=$(uri_encode "${jql}")&fields=${_ADOPT_FIELDS}&maxResults=${ADOPT_SEARCH_PAGE_SIZE}"
      if [[ -n "${token}" ]]; then
        url="${url}&nextPageToken=$(uri_encode "${token}")"
      fi
      page="$(jira_request GET "${url}")" || return $?
      issues="$(jq -c '[ .issues[]? ]' <<< "${page}")"
      count="$(jq 'length' <<< "${issues}")"
      local j
      for ((j = 0; j < count; j++)); do
        local cand
        cand="$(jq -c ".[${j}]" <<< "${issues}" | _adopt_candidate_from_issue)"
        out="$(jq -c --argjson c "${cand}" '. + [$c]' <<< "${out}")"
      done
      prev_token="${token}"
      token="$(jq -r '.nextPageToken // ""' <<< "${page}")"
      # The absence of a token is the ONLY stop condition the contract offers; an
      # empty page, or a server that repeats a cursor, also ends the loop so a
      # misbehaving endpoint cannot spin forever.
      if [[ -z "${token}" || "${token}" == "${prev_token}" ]] || ((count == 0)); then
        break
      fi
    done
  done <<< "${projects}"

  jq -c 'sort_by(.key)' <<< "${out}" | json_canonical
}

# adopt_valid_issue_key <key> — the issue-key SHAPE check for `--bind`
# (research §9). It lives here, and only here, because the sink is the one layer
# permitted to carry a key-shaped literal: a project key (an upper-case letter
# followed by upper-case letters, digits or underscores), a hyphen, and the
# issue number. A malformed key is an operator typo, so the caller reports it as
# a usage error rather than searching for it.
adopt_valid_issue_key() {
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]]
}

# adopt_fetch_pinned <keys-json> — read the context of explicitly pinned issue
# keys so a pin is validated through the IDENTICAL path a discovered candidate
# is (FR-020): same project check, same claim check, same hierarchy checks. A
# malformed key is refused before any request; an unreadable key propagates its
# mapped exit code, aborting the run before any write. Prints the canonical
# candidate array.
adopt_fetch_pinned() {
  local keys="${1:-[]}" api
  local n i out='[]'
  n="$(jq 'length' <<< "${keys}")"
  ((n == 0)) && { printf '[]'; return 0; }
  api="$(_adopt_api)" || return $?

  for ((i = 0; i < n; i++)); do
    local key issue cand
    key="$(jq -r ".[${i}]" <<< "${keys}")"
    if ! adopt_valid_issue_key "${key}"; then
      printf 'adopt: malformed issue key in --bind: %s\n' "${key}" >&2
      return "$(cli_exit_code usage)"
    fi
    issue="$(jira_request GET "${api}/issue/${key}?fields=${_ADOPT_FIELDS}")" || return $?
    cand="$(printf '%s' "${issue}" | _adopt_candidate_from_issue)"
    out="$(jq -c --argjson c "${cand}" '. + [$c]' <<< "${out}")"
  done
  jq -c 'sort_by(.key)' <<< "${out}" | json_canonical
}

# adopt_read_candidate_identity <candidates-json> — one identity read per
# candidate, surfacing the stored marker onto the candidate. A 404 means
# "unclaimed" and is NOT a failure (existing identity_read behaviour); any other
# transport failure propagates its mapped code and aborts before any write.
adopt_read_candidate_identity() {
  local candidates="${1:-[]}"
  local n i out='[]'
  n="$(jq 'length' <<< "${candidates}")"
  for ((i = 0; i < n; i++)); do
    local cand key marker
    cand="$(jq -c ".[${i}]" <<< "${candidates}")"
    key="$(jq -r '.key' <<< "${cand}")"
    marker="$(identity_read "${key}")" || return $?
    if [[ -z "${marker}" ]]; then
      cand="$(jq -c '.identity = null' <<< "${cand}")"
    else
      cand="$(jq -c --argjson m "${marker}" '.identity = $m' <<< "${cand}")"
    fi
    out="$(jq -c --argjson c "${cand}" '. + [$c]' <<< "${out}")"
  done
  json_canonical <<< "${out}"
}

# adopt_stamp_actions <bindings-json> <repo> — the ONLY write adoption ever
# emits, one per binding whose status is `adopt`: a PUT of the identity entity
# property carrying origin `human`. A binding already carrying this spec's marker
# produces NO action at all — it is skipped, not re-stamped (FR-027), which is
# what makes an interrupted adoption complete on re-run with exactly one stamp
# per ticket (SC-007).
#
# The URL and the payload are composed from the same helpers `identity_write`
# uses, and the resulting set is handed to `apply_writes`, never written here.
adopt_stamp_actions() {
  local bindings="${1:-[]}" repo="${2:-}"
  local n i out='[]'
  n="$(jq 'length' <<< "${bindings}")"
  for ((i = 0; i < n; i++)); do
    local status
    status="$(jq -r ".[${i}].status" <<< "${bindings}")"
    if [[ "${status}" == "adopt" ]]; then
      local key folder spec_ref marker url action
      key="$(jq -r ".[${i}].issue_key" <<< "${bindings}")"
      folder="$(jq -r ".[${i}].spec_folder" <<< "${bindings}")"
      spec_ref="$(jq -cn --arg r "${repo}" --arg s "${folder}" '{repo: $r, spec_slug: $s}')"
      marker="$(identity_marker "${spec_ref}" "human")"
      url="$(_identity_url "${key}")"
      action="$(jq -cn --arg u "${url}" --argjson b "${marker}" '{method: "PUT", url: $u, body: $b}')"
      out="$(jq -c --argjson a "${action}" '. + [$a]' <<< "${out}")"
    fi
  done
  json_canonical <<< "${out}"
}
