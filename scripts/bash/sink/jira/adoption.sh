#!/usr/bin/env bash
# sink/jira/adoption.sh — The resolution read (027, research R4/R5,
# contract seed-cli-contract.md §6).
#
# A SECOND bulk-read module, distinct from prefetch.sh (research R4):
# prefetch.sh is deliberately fail-OPEN — "the prefetch may only ever remove
# requests — it may never change an outcome" — and this module inverts that
# posture. FR-038 requires a run that named issues to REFUSE on an
# unreliable read rather than degrade, because degrading manufactures the
# duplicates this feature exists to prevent. Do NOT modify prefetch.sh.

[[ -n ${_JIRA_SINK_ADOPTION:-} ]] && return 0
_JIRA_SINK_ADOPTION=1

_adoption_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_adoption_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_adoption_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_adoption_dir}/client.sh"

: "${SPEC_KIT_JIRA_IDENTITY_KEY:=spec-kit-jira}"

# The R5 field union — six named fields, nothing else (FR-020 forbids
# comment bodies; Principle XV forbids a field no requirement consumes).
_ADOPTION_FIELDS="summary,description,status,issuetype,project,parent"

# _ADOPTION_MAP: lower-cased key -> canonical {"fields":{...},"marker":...}
# JSON. A non-exported bash global, process-scoped only.
declare -gA _ADOPTION_MAP=()

# adoption_reset — empties the map. Test support.
adoption_reset() {
  _ADOPTION_MAP=()
}

# adoption_load <key>... — chunks the keys at 100, issues one
# POST /issue/bulkfetch per chunk, populates the map. FAIL-CLOSED (research
# R4): a chunk failure empties the map and returns the mapped transport exit
# code — the opposite of prefetch_load's always-0 contract.
adoption_load() {
  adoption_reset
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
    # docs/11-process-budget.md: one jq -n over the whole chunk's ids array,
    # and the body reaches jira_request as a function argument — never as an
    # argument to an EXECVE'd external process, which is the actual hazard
    # MAX_ARG_STRLEN names. jira_request itself routes it through a temp
    # file before handing it to curl (sink/jira/client.sh).
    body="$(jq -cn --argjson ids "${ids_json}" --arg fields "${_ADOPTION_FIELDS}" --arg k "${SPEC_KIT_JIRA_IDENTITY_KEY}" \
      '{issueIdsOrKeys:$ids, fields:($fields | split(",")), properties:[$k]}')"

    tmp="$(mktemp)"
    jira_request POST "${url}" "${body}" > "${tmp}"
    rc=$?
    resp="$(cat "${tmp}")"
    rm -f "${tmp}"

    if ((rc != 0)); then
      adoption_reset
      return "${rc}"
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
        '{fields:(.fields // {}), marker:(.properties[$k] // null)}' <<< "${issue}" | json_canonical)"
      lower="$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]')"
      _ADOPTION_MAP["${lower}"]="${entry}"
    done
  done
  return 0
}

# adoption_get <key> — the resolved entry (case-insensitive key match), or
# nothing with a non-zero return on a miss.
adoption_get() {
  local key="$1" lower entry
  lower="$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]')"
  entry="${_ADOPTION_MAP[${lower}]:-}"
  [[ -z "${entry}" ]] && return 1
  printf '%s' "${entry}"
}

# _adopt_trim <string> — leading/trailing whitespace, fork-free.
_adopt_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# adoption_evaluate <routed-project> <role> <key> <declared-type-name>
# <terminal-statuses-csv> <spec-ref-json> — the six per-key refusal classes
# (REF-UNRESOLVED, REF-ROLE, REF-ROUTING, REF-TERMINAL, REF-CLAIMED,
# REF-THIN), evaluated in that order. <declared-type-name>,
# <terminal-statuses-csv>, and <spec-ref-json> may each be empty to skip
# their check. Prints canonical JSON {"code":"...","key":"...","message":"..."}
# with `code` empty when the issue is clean.
adoption_evaluate() {
  local routed_project="$1" role="$2" key="$3" declared_type="$4" terminal_csv="$5" spec_ref="${6:-}"
  local entry
  if ! entry="$(adoption_get "${key}")"; then
    # FR-037: never claims to distinguish deleted from forbidden — bulkfetch
    # reports both as absence, and this module has no other source to ask.
    jq -cn --arg k "${key}" \
      '{code:"REF-UNRESOLVED", key:$k, message:("designator " + $k + " was not found in the read — check the key, then check that the credentials can open it in a browser")}' \
      | json_canonical
    return 0
  fi

  local itype_name project_key status_name desc marker
  itype_name="$(jq -r '.fields.issuetype.name // ""' <<< "${entry}")"
  project_key="$(jq -r '.fields.project.key // ""' <<< "${entry}")"
  status_name="$(jq -r '.fields.status.name // ""' <<< "${entry}")"
  desc="$(jq -r '.fields.description as $d | if ($d | type) == "string" then $d else ([$d | .. | .text? // empty] | join(" ")) end' <<< "${entry}")"
  marker="$(jq -c '.marker // null' <<< "${entry}")"

  if [[ -n "${declared_type}" && "${itype_name}" != "${declared_type}" ]]; then
    jq -cn --arg k "${key}" --arg found "${itype_name}" --arg want "${declared_type}" \
      '{code:"REF-ROLE", key:$k, message:("issue " + $k + " has type " + $found + ", not the declared " + $want + " for the " + $ARGS.positional[0] + " role")}' \
      --args "${role}" | json_canonical
    return 0
  fi

  if [[ -n "${routed_project}" && "${project_key}" != "${routed_project}" ]]; then
    jq -cn --arg k "${key}" --arg p "${project_key}" --arg r "${routed_project}" \
      '{code:"REF-ROUTING", key:$k, message:("issue " + $k + " belongs to project " + $p + ", not the routed project " + $r)}' \
      | json_canonical
    return 0
  fi

  if [[ -n "${terminal_csv}" ]]; then
    local -a terms
    IFS=',' read -ra terms <<< "${terminal_csv}"
    local t
    for t in "${terms[@]}"; do
      if [[ "${status_name}" == "${t}" ]]; then
        jq -cn --arg k "${key}" --arg s "${status_name}" \
          '{code:"REF-TERMINAL", key:$k, message:("issue " + $k + " is in the terminal status " + $s + " — reopen it, or name a different one")}' \
          | json_canonical
        return 0
      fi
    done
  fi

  if [[ -n "${spec_ref}" && "${marker}" != "null" ]]; then
    local claimed
    claimed="$(jq -r --argjson s "${spec_ref}" \
      'if (.repo == ($s.repo // "")) and (.spec_slug == ($s.spec_slug // "")) then "0" else "1" end' <<< "${marker}")"
    if [[ "${claimed}" == "1" ]]; then
      jq -cn --arg k "${key}" \
        '{code:"REF-CLAIMED", key:$k, message:("issue " + $k + " already carries an identity marker for another specification")}' \
        | json_canonical
      return 0
    fi
  fi

  if [[ -z "$(_adopt_trim "${desc}")" ]]; then
    jq -cn --arg k "${key}" \
      '{code:"REF-THIN", key:$k, message:("the description of issue " + $k + " has no non-whitespace character — write it in Jira, or do not name it")}' \
      | json_canonical
    return 0
  fi

  jq -cn --arg k "${key}" '{code:"", key:$k}' | json_canonical
}

# adoption_multiproject_violation <story-keys-json-array> — REF-MULTIPROJECT:
# the distinct set of resolved project keys among the given story-role keys,
# when it holds more than one; an empty array otherwise.
adoption_multiproject_violation() {
  local keys_json="$1" projects="[]" key project entry
  local n i
  n="$(jq 'length' <<< "${keys_json}")"
  for ((i = 0; i < n; i++)); do
    key="$(jq -r ".[${i}]" <<< "${keys_json}")"
    entry="$(adoption_get "${key}")" || continue
    project="$(jq -r '.fields.project.key // empty' <<< "${entry}")"
    [[ -z "${project}" ]] && continue
    projects="$(jq -c --arg p "${project}" '. + [$p] | unique' <<< "${projects}")"
  done
  local count
  count="$(jq 'length' <<< "${projects}")"
  if ((count > 1)); then
    printf '%s' "${projects}" | json_canonical
  else
    printf '[]'
  fi
}

# adoption_aggregate_refusals <json-array-of-evaluate-results> — filters to
# only the refusing entries (Principle XVI, C-4): the whole set is reported
# together, never one refusal per run.
adoption_aggregate_refusals() {
  jq -c '[ .[] | select(.code != "") ]' <<< "$1" | json_canonical
}
