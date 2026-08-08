#!/usr/bin/env bash
# sink/jira/prefetch.sh — the recognition prefetch (021 US4;
# contracts/recognition-prefetch.md). One POST .../issue/bulkfetch per 100
# recorded keys, issued once from the command layer, in place of one GET per
# key. The governing rule: the prefetch may only ever remove requests — it
# may never change an outcome. _recognition_read/_recognition_read_parent
# consult prefetch_get first and fall through to their existing unchanged GET
# on any miss (contract §3), so every classification this module cannot
# express (a deleted vs. a forbidden key) resolves exactly as it does today.

[[ -n ${_JIRA_SINK_PREFETCH:-} ]] && return 0
_JIRA_SINK_PREFETCH=1

_prefetch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_prefetch_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_prefetch_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_prefetch_dir}/client.sh"

: "${SPEC_KIT_JIRA_IDENTITY_KEY:=spec-kit-jira}"

# The union of every reader's field list (contract §5) — requested once,
# regardless of which reader later calls prefetch_get for a given hit.
_PREFETCH_FIELDS="summary,description,priority,status,issuelinks,parent,labels,subtasks,Flagged"

# _PREFETCH_MAP: lower-cased key -> canonical {"gone":false,"marker":...,
# "fields":{...}} JSON, matching what _recognition_read itself prints. A
# non-exported bash global, scoped to this process only (Constitution XIII);
# prefetch_reset exists so tests never leak state across cases.
declare -gA _PREFETCH_MAP=()

# prefetch_reset — empties the map. Test support (contract §2).
prefetch_reset() {
  _PREFETCH_MAP=()
}

# prefetch_load <key>… — chunks the keys at 100, issues one
# POST /issue/bulkfetch per chunk, populates the map. Returns 0 always (P2/
# P6): neither a zero-key call nor a bulkfetch failure is ever fail-closed —
# the authoritative per-key read has not happened yet, and a miss here is
# resolved by the reader's own unchanged GET (contract §3).
prefetch_load() {
  prefetch_reset
  (($# == 0)) && return 0

  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  local url="${base}/rest/api/3/issue/bulkfetch"
  local -a keys=("$@")
  local total=${#keys[@]} offset=0

  while ((offset < total)); do
    local -a chunk=("${keys[@]:offset:100}")
    offset=$((offset + 100))

    local ids_json body resp rc tmp
    ids_json="$(printf '%s\n' "${chunk[@]}" | jq -R . | jq -sc .)"
    body="$(jq -cn --argjson ids "${ids_json}" --arg fields "${_PREFETCH_FIELDS}" --arg k "${SPEC_KIT_JIRA_IDENTITY_KEY}" \
      '{issueIdsOrKeys:$ids, fields:($fields | split(",")), properties:[$k]}')"

    tmp="$(mktemp)"
    jira_request POST "${url}" "${body}" > "${tmp}"
    rc=$?
    resp="$(cat "${tmp}")"
    rm -f "${tmp}"

    # P2: a non-2xx empties the map — no partial optimisation survives a
    # chunk failure, so every key this load call named falls through to
    # today's per-key read at today's cost.
    if ((rc != 0)); then
      prefetch_reset
      return 0
    fi

    local n i
    n="$(jq -r '.issues | length' <<< "${resp}" 2> /dev/null)"
    [[ "${n}" =~ ^[0-9]+$ ]] || n=0
    for ((i = 0; i < n; i++)); do
      local issue key entry lower
      issue="$(jq -c ".issues[${i}]" <<< "${resp}")"
      key="$(jq -r '.key // empty' <<< "${issue}")"
      [[ -z "${key}" ]] && continue
      entry="$(jq -c --arg k "${SPEC_KIT_JIRA_IDENTITY_KEY}" \
        '{gone:false, marker:(.properties[$k] // null), fields:(.fields // {})}' <<< "${issue}" | json_canonical)"
      lower="$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]')"
      _PREFETCH_MAP["${lower}"]="${entry}"
    done
  done
  return 0
}

# prefetch_get <key> <fields-csv> — prints the cached entry (P4: matched by
# key, case-insensitively — never by position) projected to <fields-csv>
# (P3), through json_canonical, matching _recognition_read's own shape.
# Returns 1 and prints nothing on a miss.
prefetch_get() {
  local key="$1" fields_csv="$2" lower entry
  lower="$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]')"
  entry="${_PREFETCH_MAP[${lower}]:-}"
  [[ -z "${entry}" ]] && return 1

  jq -c --arg fields "${fields_csv}" \
    '(.fields // {}) as $f
     | (($fields | split(",")) - [""]) as $want
     | {gone:false, marker:.marker, fields:($f | to_entries | map(select(.key as $k | $want | index($k) != null)) | from_entries)}' \
    <<< "${entry}" | json_canonical
}
