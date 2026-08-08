#!/usr/bin/env bash
# T005 — Scripted `curl` replacement for the Bash port's mock backend.
#
# Installed first on PATH by `mock_start` (lib.sh) so jira_request()
# (scripts/bash/sink/jira/client.sh) reaches this instead of a real socket.
# Serves canned fixtures + a per-run issue store, with no process and no port.
# See contracts/curl-shim.md for the behavioural contract this implements.
#
# Two calling shapes reach this script:
#   1. jira_request's `--config -` shape (url/request/data on stdin).
#   2. Direct test/driver calls: `curl -s [-f] [-X M] [-d DATA] [-o F] [-D F] [-w FMT] URL`
#      (mock_issue_field, and several .bats files that poke the mock directly).
#
# State (per mock_start session, all under the recorded MOCK_TMPDIR):
#   MOCK_CONFIG_PATH — the active configs/*.json (routing + faults)
#   MOCK_STATE_PATH  — mutable issue store: {"issues":{...},"counters":{...}}
#   MOCK_FIXTURE_DIR — the shared fixtures/ directory
#   MOCK_CALLLOG     — every request appended here, "METHOD target" (NFR-1)
#   MOCK_BASE_URL    — a sentinel; the shim keys on the path, never the host

set -u

# ---- argv parsing -----------------------------------------------------------

_silent=0
_fail=0
_method=""
_config_file=""
_output=""
_dumpheader=""
_writeout=""
_url=""
_data=""

_args=("$@")
_i=0
while [[ ${_i} -lt ${#_args[@]} ]]; do
  _a="${_args[${_i}]}"
  case "${_a}" in
    --silent) _silent=1 ;;
    -s) _silent=1 ;;
    --fail) _fail=1 ;;
    -f) _fail=1 ;;
    -sf | -fs) _silent=1; _fail=1 ;;
    --config)
      _i=$((_i + 1)); _config_file="${_args[${_i}]:-}"
      ;;
    -X | --request)
      _i=$((_i + 1)); _method="${_args[${_i}]:-}"
      ;;
    -H | --header)
      _i=$((_i + 1)) # header contents are never inspected or stored (NFR-3)
      ;;
    -d | --data)
      _i=$((_i + 1)); _data="${_args[${_i}]:-}"
      ;;
    -o | --output)
      _i=$((_i + 1)); _output="${_args[${_i}]:-}"
      ;;
    -D | --dump-header)
      _i=$((_i + 1)); _dumpheader="${_args[${_i}]:-}"
      ;;
    -w | --write-out)
      _i=$((_i + 1)); _writeout="${_args[${_i}]:-}"
      ;;
    -*) : ;; # unrecognized-but-harmless flag: ignored (YAGNI, contracts/curl-shim.md)
    *) _url="${_a}" ;;
  esac
  _i=$((_i + 1))
done

# ---- optional config-on-stdin (jira_request's shape) -------------------------

_cfg_url=""
_cfg_method=""
_cfg_data_file=""

_shim_unquote() {
  local s="$1"
  s="${s%\"}"
  s="${s#\"}"
  printf '%s' "${s}"
}

if [[ "${_config_file}" == "-" ]]; then
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    [[ -z "${_line}" ]] && continue
    _k="${_line%%=*}"
    _v="${_line#*=}"
    _k="$(printf '%s' "${_k}" | sed 's/[[:space:]]*$//')"
    _v="$(printf '%s' "${_v}" | sed 's/^[[:space:]]*//')"
    _v="$(_shim_unquote "${_v}")"
    case "${_k}" in
      url) _cfg_url="${_v}" ;;
      request) _cfg_method="${_v}" ;;
      data) [[ "${_v}" == @* ]] && _cfg_data_file="${_v#@}" ;;
      header) : ;; # NEVER read or log (the Authorization header lives here)
      *) : ;;
    esac
  done
fi

url="${_url:-${_cfg_url}}"
method="${_method:-${_cfg_method:-GET}}"
method="${method^^}"

body=""
if [[ -n "${_data}" ]]; then
  if [[ "${_data}" == @* ]]; then
    body="$(cat "${_data#@}" 2> /dev/null || true)"
  else
    body="${_data}"
  fi
elif [[ -n "${_cfg_data_file}" ]]; then
  body="$(cat "${_cfg_data_file}" 2> /dev/null || true)"
fi

# ---- resolve target (path + query, host stripped) -----------------------------

target="${url#"${MOCK_BASE_URL}"}"
path="${target%%\?*}"
query=""
[[ "${target}" == *"?"* ]] && query="${target#*\?}"

# ---- call log — appended before fault handling, mirroring mock-server.ps1 -----

printf '%s %s\n' "${method}" "${target}" >> "${MOCK_CALLLOG}"

# ---- helpers ------------------------------------------------------------------

_reason_phrase() {
  case "$1" in
    200) printf 'OK' ;;
    201) printf 'Created' ;;
    204) printf 'No Content' ;;
    401) printf 'Unauthorized' ;;
    403) printf 'Forbidden' ;;
    404) printf 'Not Found' ;;
    429) printf 'Too Many Requests' ;;
    500) printf 'Internal Server Error' ;;
    *) printf 'Unknown' ;;
  esac
}

# _shim_urldecode <percent-encoded> — the inverse of jq's `@uri` (017,
# duplicate_probe's jql query), test-infrastructure only.
_shim_urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

# _shim_label_search <query-string> — 017, contracts/duplicate-probe.md §3/§4:
# a jql search keyed on `labels = "<label>"` (the duplicate probe's own
# query shape, distinct from discovery's `parent=<key>` sibling search,
# which keeps routing to the static search-siblings fixture unchanged).
# Looks the decoded label up in the active config's `.labelSearch` map
# (label -> array of keys); unconfigured or unmatched ⇒ zero issues (the
# "clear" verdict) — today's behaviour for every test that never sets it.
_shim_label_search() {
  local decoded label keys
  decoded="$(_shim_urldecode "$1")"
  label="$(printf '%s' "${decoded}" | sed -nE 's/.*labels = "([^"]*)".*/\1/p')"
  keys="$(jq -c --arg l "${label}" '(.labelSearch[$l] // [])' "${MOCK_CONFIG_PATH}" 2> /dev/null)"
  [[ -z "${keys}" || "${keys}" == "null" ]] && keys='[]'
  RESP_STATUS=200
  RESP_BODY="$(jq -cn --argjson k "${keys}" '{issues: ($k | map({key: .}))}')"
}

_read_fixture() {
  local name="$1" file="${MOCK_FIXTURE_DIR}/$1.json"
  if [[ -f "${file}" ]]; then
    RESP_STATUS=200
    RESP_BODY="$(cat "${file}")"
  else
    RESP_STATUS=500
    RESP_BODY="{\"error\":\"missing fixture ${name}\"}"
  fi
}

_shim_get_style() {
  jq -r --arg p "$1" '
    (.projects // {}) as $pr
    | ($pr | to_entries | map(select(("/" + .key + "(/|$)") as $pat | $p | test($pat))) | .[0].value) // "company"
  ' "${MOCK_CONFIG_PATH}"
}

_shim_get_meta_style() {
  case "$1" in
    company | team | french | safe | nonlatin | flat | hier-ambiguous | consumer | linebreak | taskm) printf '%s' "$1" ;;
    *) printf 'company' ;;
  esac
}

_shim_get_issuetype_style() {
  jq -r --arg p "$1" --arg d "$2" '
    (.issueTypeStyle // {}) as $its
    | ($its | to_entries | map(select(("/" + .key + "(/|$)") as $pat | $p | test($pat))) | .[0].value) // $d
  ' "${MOCK_CONFIG_PATH}"
}

_shim_get_createmeta_fields_name() {
  local path="$1" meta_style="$2" name
  name="$(jq -r --arg p "${path}" '
    (.createmetaFields // {}) as $cf
    | ($cf | to_entries | map(select(("/" + .key + "(/|$)") as $pat | $p | test($pat))) | .[0].value) // empty
  ' "${MOCK_CONFIG_PATH}")"
  if [[ -n "${name}" ]]; then
    printf 'createmeta-fields-%s' "${name}"
    return
  fi
  if [[ "${path}" =~ /issuetypes/([^/]+)$ ]]; then
    local typeid="${BASH_REMATCH[1]}" pertype
    pertype="createmeta-fields-${meta_style}-${typeid}"
    if [[ -f "${MOCK_FIXTURE_DIR}/${pertype}.json" ]]; then
      printf '%s' "${pertype}"
      return
    fi
  fi
  printf 'createmeta-fields-%s' "${meta_style}"
}

_shim_get_fault() {
  jq -c --arg p "$1" '
    (.faults // {}) as $f
    | ( ($f | to_entries | map(select(("/" + .key + "(/|-|$)") as $pat | $p | test($pat))) | .[0].value) // (.fault // null) )
  ' "${MOCK_CONFIG_PATH}"
}

_shim_project_search_page() {
  local start_at=0 max_results=50 part
  IFS='&' read -ra _parts <<< "${query}"
  for part in "${_parts[@]}"; do
    case "${part}" in
      startAt=*) start_at="${part#startAt=}" ;;
      maxResults=*) max_results="${part#maxResults=}" ;;
    esac
  done
  local page_size
  page_size="$(jq -r '.pageSize // 0' "${MOCK_CONFIG_PATH}")"
  if [[ "${page_size}" -gt 0 && "${page_size}" -lt "${max_results}" ]]; then
    max_results="${page_size}"
  fi
  RESP_STATUS=200
  RESP_BODY="$(jq -c --argjson startAt "${start_at}" --argjson maxResults "${max_results}" '
    (.projects // {}) as $pr
    | ($pr | keys) as $ks
    | ($ks | length) as $total
    | ([$startAt, $total] | min) as $s
    | ([$startAt + $maxResults, $total] | min) as $e
    | ($ks[$s:$e] | map(
        . as $k
        | {key:$k, name:($k + " project")}
        + (
            if $pr[$k] == "company" then {style:"classic", simplified:false}
            elif $pr[$k] == "team" then {style:"next-gen", simplified:true}
            elif $pr[$k] == "contradictory" then {style:"classic", simplified:true}
            else {}
            end
          )
      )) as $values
    | {startAt:$startAt, maxResults:$maxResults, total:$total, isLast: (($startAt + $maxResults) >= $total), values:$values}
  ' "${MOCK_CONFIG_PATH}")"
}

_shim_create_issue() {
  local body_json="$1"
  [[ -z "${body_json}" ]] && body_json='{}'
  jq -e . > /dev/null 2>&1 <<< "${body_json}" || body_json='{}'
  local project_key created_key style wrap
  project_key="$(jq -r '.fields.project.key // "COMP"' <<< "${body_json}")"
  created_key="$(jq -r '.createdKey // ""' "${MOCK_CONFIG_PATH}")"
  style="$(jq -r --arg pk "${project_key}" '(.issueTypeStyle // {})[$pk] // ""' "${MOCK_CONFIG_PATH}")"
  wrap="$(jq -c --arg pk "${project_key}" --arg ck "${created_key}" --arg style "${style}" --argjson body "${body_json}" '
    (.counters[$pk] // 0) as $c
    | ($c + 1) as $next
    | (if $ck != "" then $ck else ($pk + "-" + ($next | tostring)) end) as $key
    | (if $ck == "" then (.counters[$pk] = $next) else . end) as $withCounter
    | ($body.fields // {}) as $sf
    | (if $style == "french" then {name: "À faire", statusCategory: {key: "new"}}
       else {name: "To Do", statusCategory: {key: "new"}}
       end) as $defaultStatus
    | {
        summary: ($sf.summary // ""),
        description: ($sf.description // null),
        priority: ($sf.priority // null),
        status: $defaultStatus,
        issuelinks: [],
        parent: ($sf.parent // null),
        issuetype: ($sf.issuetype // null),
        labels: ($sf.labels // [])
      } as $fields
    | ($withCounter | .issues[$key] = {fields: $fields, properties: {}}) as $state
    | {state: $state, key: $key}
  ' "${MOCK_STATE_PATH}")"
  local tmp
  tmp="$(mktemp)"
  jq -c '.state' <<< "${wrap}" > "${tmp}"
  mv "${tmp}" "${MOCK_STATE_PATH}"
  CREATED_KEY="$(jq -r '.key' <<< "${wrap}")"
  RESP_STATUS=201
  RESP_BODY="{\"id\":\"99001\",\"key\":\"${CREATED_KEY}\",\"self\":\"/rest/api/3/issue/99001\"}"
}

# _shim_issue_bulkfetch <body-json> — 021 US4, contracts/recognition-prefetch.md
# T046: composes its response from the SAME per-key store `/rest/api/3/issue/
# {key}` already serves, honouring the requested `fields`/`properties`, and
# returning issues in the state store's own (insertion) order — never request
# order, so a test can prove P4 (matched by key, not position). A key is
# omitted, exactly as the real endpoint's own documentation states, when it is
# either absent from the store (deleted) or faulted on its own per-key path
# (not visible) — deleted and forbidden are equally just "not returned",
# reusing the SAME fault config a direct per-key GET test already uses, never
# a second source of truth.
_shim_issue_bulkfetch() {
  local body_json="$1"
  [[ -z "${body_json}" ]] && body_json='{}'
  jq -e . > /dev/null 2>&1 <<< "${body_json}" || body_json='{}'

  local fields_csv props_csv want_subtasks="false"
  fields_csv="$(jq -r '(.fields // []) | join(",")' <<< "${body_json}")"
  props_csv="$(jq -r '(.properties // []) | join(",")' <<< "${body_json}")"
  [[ ",${fields_csv}," == *",subtasks,"* ]] && want_subtasks="true"

  local ids_json n i issues="[]"
  ids_json="$(jq -c '.issueIdsOrKeys // []' <<< "${body_json}")"
  n="$(jq 'length' <<< "${ids_json}")"
  for ((i = 0; i < n; i++)); do
    local reqkey matchkey fault
    reqkey="$(jq -r ".[${i}]" <<< "${ids_json}")"
    matchkey="$(jq -r --arg rk "${reqkey}" \
      '.issues | keys[] | select(ascii_downcase == ($rk | ascii_downcase))' \
      "${MOCK_STATE_PATH}" | head -n1)"
    [[ -z "${matchkey}" ]] && continue
    fault="$(_shim_get_fault "/rest/api/3/issue/${matchkey}")"
    [[ "${fault}" != "null" ]] && continue

    local entry
    entry="$(jq -c --arg k "${matchkey}" --arg props "${props_csv}" --argjson want_sub "${want_subtasks}" '
      .issues[$k] as $i
      | ($i.fields
          + (if $want_sub then
              {subtasks: [ .issues | to_entries[] | select(.value.fields.parent.key == $k)
                | {key: .key, fields: {issuetype: (.value.fields.issuetype // {id: null})}} ]}
            else {} end)
        ) as $flds
      | {key: $k, fields: $flds}
      + (if $props != "" then
          {properties: ( ($props | split(",")) as $names
            | reduce $names[] as $n ({}; . + (if ($i.properties | has($n)) then {($n): $i.properties[$n]} else {} end)) )}
        else {} end)
    ' "${MOCK_STATE_PATH}")"
    issues="$(jq -c --argjson e "${entry}" '. + [$e]' <<< "${issues}")"
  done

  # Project fields down to the caller's requested list — the mock stores every
  # field the per-key GET already knows, so this mirrors Jira's own selection.
  if [[ -n "${fields_csv}" ]]; then
    issues="$(jq -c --arg fields "${fields_csv}" '
      ($fields | split(",")) as $want
      | map(.fields |= (to_entries | map(select(.key as $k | $want | index($k) != null)) | from_entries))
    ' <<< "${issues}")"
  fi

  RESP_STATUS=200
  RESP_BODY="$(jq -cn --argjson issues "${issues}" '{issues:$issues, issueErrors:[]}')"
}

_shim_issue_put() {
  local key="$1" body_json="$2" tmp
  [[ -z "${body_json}" ]] && body_json='{}'
  jq -e . > /dev/null 2>&1 <<< "${body_json}" || body_json='{}'
  tmp="$(mktemp)"
  jq -c --arg k "${key}" --argjson body "${body_json}" '
    if (.issues | has($k)) then
      ($body.fields // {}) as $sf
      | .issues[$k].fields = (.issues[$k].fields + $sf)
    else . end
  ' "${MOCK_STATE_PATH}" > "${tmp}"
  mv "${tmp}" "${MOCK_STATE_PATH}"
  RESP_STATUS=204
  RESP_BODY=""
}

_shim_issue_get() {
  local key="$1" props_csv="" fields_csv="" want_subtasks="false" exists
  if [[ "${query}" =~ (^|\&)properties=([^\&]+) ]]; then
    props_csv="${BASH_REMATCH[2]}"
  fi
  if [[ "${query}" =~ (^|\&)fields=([^\&]+) ]]; then
    fields_csv="${BASH_REMATCH[2]}"
  fi
  [[ ",${fields_csv}," == *",subtasks,"* ]] && want_subtasks="true"
  exists="$(jq -r --arg k "${key}" '(.issues | has($k))' "${MOCK_STATE_PATH}")"
  if [[ "${exists}" == "true" ]]; then
    RESP_STATUS=200
    RESP_BODY="$(jq -c --arg k "${key}" --arg props "${props_csv}" --argjson want_sub "${want_subtasks}" '
      .issues[$k] as $i
      | ($i.fields
          + (if $want_sub then
              {subtasks: [ .issues | to_entries[] | select(.value.fields.parent.key == $k)
                | {key: .key, fields: {issuetype: (.value.fields.issuetype // {id: null})}} ]}
            else {} end)
        ) as $flds
      | {key: $k, fields: $flds}
      + (if $props != "" then
          {properties: ( ($props | split(",")) as $names
            | reduce $names[] as $n ({}; . + (if ($i.properties | has($n)) then {($n): $i.properties[$n]} else {} end)) )}
        else {} end)
    ' "${MOCK_STATE_PATH}")"
  else
    _read_fixture 'issue-mentioned'
  fi
}

_shim_property_put() {
  local key="$1" prop_key="$2" value_json="$3" tmp
  tmp="$(mktemp)"
  if jq -e . > /dev/null 2>&1 <<< "${value_json}"; then
    jq -c --arg k "${key}" --arg pk "${prop_key}" --argjson v "${value_json}" '
      if (.issues | has($k)) then .issues[$k].properties[$pk] = $v else . end
    ' "${MOCK_STATE_PATH}" > "${tmp}"
  else
    jq -c --arg k "${key}" --arg pk "${prop_key}" --arg v "${value_json}" '
      if (.issues | has($k)) then .issues[$k].properties[$pk] = $v else . end
    ' "${MOCK_STATE_PATH}" > "${tmp}"
  fi
  mv "${tmp}" "${MOCK_STATE_PATH}"
  RESP_STATUS=204
  RESP_BODY=""
}

_shim_get_transitions() {
  jq -c --arg k "$1" '(.transitions // {})[$k] // []' "${MOCK_CONFIG_PATH}"
}

_shim_get_identity_marker() {
  jq -c --arg p "$1" '
    (.identity // {}) as $id
    | ($id | to_entries | map(select(("/rest/api/3/issue/" + .key + "/properties/") as $pat | $p | test($pat))) | .[0].value) // null
  ' "${MOCK_CONFIG_PATH}"
}

_shim_property_get() {
  local key="$1" prop_key="$2" has
  has="$(jq -r --arg k "${key}" --arg pk "${prop_key}" '(.issues | has($k)) and (.issues[$k].properties | has($pk))' "${MOCK_STATE_PATH}")"
  if [[ "${has}" == "true" ]]; then
    RESP_STATUS=200
    RESP_BODY="$(jq -c --arg pk "${prop_key}" --arg k "${key}" '{key: $pk, value: .issues[$k].properties[$pk]}' "${MOCK_STATE_PATH}")"
    return
  fi
  local marker
  marker="$(_shim_get_identity_marker "${path}")"
  if [[ "${marker}" != "null" ]]; then
    RESP_STATUS=200
    RESP_BODY="$(jq -c --argjson v "${marker}" -n '{key: "spec-kit-jira", value: $v}')"
    return
  fi
  RESP_STATUS=404
  RESP_BODY='{"errorMessages":["not found"],"errors":{}}'
}

# ---- fault check (before routing; call already logged above) ------------------

RESP_STATUS=404
RESP_BODY='{"errorMessages":["not found"],"errors":{}}'
RESP_HEADERS_EXTRA=()

fault_path="${path}"
if [[ "${method}" == "POST" && "${path}" == "/rest/api/3/issue" ]]; then
  _pk="$(jq -r '.fields.project.key // empty' 2> /dev/null <<< "${body}")"
  [[ -n "${_pk}" ]] && fault_path="/${_pk}"
fi
fault_json="$(_shim_get_fault "${fault_path}")"

# `ifFieldPresent` (018, T068, FR-011): a fault that only fires while the
# request body's `.fields` still carries the named key — lets a test
# simulate a tracker rejecting an oversized description on the first PUT
# and accepting the same request once the caller strips that field on retry.
if [[ "${fault_json}" != "null" ]]; then
  if_field="$(jq -r '.ifFieldPresent // empty' <<< "${fault_json}")"
  if [[ -n "${if_field}" ]]; then
    has_field="$(jq -r --arg f "${if_field}" '(.fields | has($f)) // false' 2> /dev/null <<< "${body}")"
    [[ "${has_field}" == "true" ]] || fault_json="null"
  fi
fi

if [[ "${fault_json}" != "null" ]]; then
  is_network="$(jq -r '.network // false' <<< "${fault_json}")"
  if [[ "${is_network}" == "true" ]]; then
    # Dropped connection: no response at all, matching jira_request's
    # curl_rc != 0 -> network-level failure branch.
    exit 7
  fi
  RESP_STATUS="$(jq -r '.status' <<< "${fault_json}")"
  # `errors` (011, FR-019): an optional field-validation body, {field_id:
  # reason}, so a fault can exercise the recorded-default-rejected path —
  # everything else keeps the pre-existing generic injected body.
  RESP_BODY="$(jq -cn --arg st "${RESP_STATUS}" --argjson errs "$(jq -c '.errors // {}' <<< "${fault_json}")" \
    '{errorMessages: ["injected fault \($st)"], errors: $errs}')"
  retry_after="$(jq -r '.retryAfter // empty' <<< "${fault_json}")"
  [[ -n "${retry_after}" ]] && RESP_HEADERS_EXTRA+=("Retry-After: ${retry_after}")
else
  # ---- route resolution (mirrors mock-server.ps1 Resolve-Route) ---------------
  style="$(_shim_get_style "${path}")"
  meta_style="$(_shim_get_meta_style "$(_shim_get_issuetype_style "${path}" "${style}")")"
  # 012, T006a: the same per-project override issue-type names use also
  # picks the project statuses fixture, when a dedicated one exists — falling
  # back to the base style otherwise, so every pre-existing override without
  # its own statuses fixture keeps behaving exactly as before. See
  # mock-server.ps1's mirror of this comment for why.
  if [[ -f "${MOCK_FIXTURE_DIR}/statuses-${meta_style}.json" ]]; then
    status_style="${meta_style}"
  else
    status_style="$(_shim_get_meta_style "${style}")"
  fi

  if [[ "${path}" == "/__mock/health" ]]; then
    RESP_STATUS=200
    RESP_BODY='{"ok":true}'
  elif [[ "${path}" == "/rest/api/3/project/search" && "${method}" == "GET" ]]; then
    _shim_project_search_page
  elif [[ "${path}" =~ ^/rest/api/3/project/[^/]+/statuses$ ]]; then
    _read_fixture "statuses-${status_style}"
  elif [[ "${path}" =~ ^/rest/api/3/project/[^/]+$ ]]; then
    _read_fixture "project-${style}"
  elif [[ "${path}" =~ ^/rest/api/3/issue/createmeta/[^/]+/issuetypes/[^/]+$ ]]; then
    _read_fixture "$(_shim_get_createmeta_fields_name "${path}" "${meta_style}")"
  elif [[ "${path}" =~ ^/rest/api/3/issue/createmeta/[^/]+/issuetypes$ ]]; then
    _read_fixture "createmeta-issuetypes-${meta_style}"
  elif [[ "${path}" == "/rest/api/3/priority" ]]; then
    _read_fixture 'priority'
  elif [[ "${path}" == "/rest/api/3/field" ]]; then
    _read_fixture 'field'
  elif [[ "${path}" == "/rest/api/3/issue" && "${method}" == "POST" ]]; then
    _shim_create_issue "${body}"
  elif [[ "${path}" == "/rest/api/3/issue/bulkfetch" && "${method}" == "POST" ]]; then
    _shim_issue_bulkfetch "${body}"
  elif [[ "${path}" =~ ^/rest/api/3/issue/([^/]+)/transitions$ ]]; then
    ikey="${BASH_REMATCH[1]}"
    if [[ "${method}" == "POST" ]]; then
      RESP_STATUS=204
      RESP_BODY=""
    elif [[ "${method}" == "GET" ]]; then
      RESP_STATUS=200
      RESP_BODY="$(jq -cn --argjson t "$(_shim_get_transitions "${ikey}")" '{expand:"transitions", transitions:$t}')"
    fi
  elif [[ "${path}" =~ ^/rest/api/3/issue/[^/]+/remotelink$ && "${method}" == "GET" ]]; then
    _read_fixture 'remotelinks'
  elif [[ ( "${path}" == "/rest/api/3/search" || "${path}" == "/rest/api/3/search/jql" ) && "${method}" == "GET" && "${query}" == *"labels"* ]]; then
    _shim_label_search "${query}"
  elif [[ ( "${path}" == "/rest/api/3/search" || "${path}" == "/rest/api/3/search/jql" ) && "${method}" == "GET" ]]; then
    _read_fixture 'search-siblings'
  elif [[ "${path}" =~ ^/rest/api/3/issue/([^/]+)/properties/([^/]+)$ ]]; then
    ikey="${BASH_REMATCH[1]}" propkey="${BASH_REMATCH[2]}"
    if [[ "${method}" == "PUT" ]]; then
      _shim_property_put "${ikey}" "${propkey}" "${body}"
    elif [[ "${method}" == "GET" ]]; then
      _shim_property_get "${ikey}" "${propkey}"
    fi
  elif [[ "${path}" =~ ^/rest/api/3/issue/([^/]+)$ ]]; then
    ikey="${BASH_REMATCH[1]}"
    if [[ "${method}" == "GET" ]]; then
      if [[ "${query}" =~ (^|\&)fields=project(\&|$) ]]; then
        pkey="${ikey%%-*}"
        in_projects="$(jq -r --arg pk "${pkey}" '(.projects // {}) | has($pk)' "${MOCK_CONFIG_PATH}")"
        if [[ "${in_projects}" == "true" ]]; then
          RESP_STATUS=200
          RESP_BODY="{\"key\":\"${ikey}\",\"fields\":{\"project\":{\"key\":\"${pkey}\"}}}"
        else
          RESP_STATUS=404
          RESP_BODY='{"errorMessages":["not found"],"errors":{}}'
        fi
      else
        _shim_issue_get "${ikey}"
      fi
    elif [[ "${method}" == "PUT" ]]; then
      _shim_issue_put "${ikey}" "${body}"
    fi
  fi
fi

# ---- emit the response, matching jira_request's flag shape --------------------

if [[ -n "${_output}" ]]; then
  printf '%s' "${RESP_BODY}" > "${_output}"
elif [[ ! ( "${_fail}" == 1 && "${RESP_STATUS}" -ge 400 ) ]]; then
  printf '%s' "${RESP_BODY}"
fi

if [[ -n "${_dumpheader}" ]]; then
  _headers="HTTP/1.1 ${RESP_STATUS} $(_reason_phrase "${RESP_STATUS}")
Content-Type: application/json"
  for _h in "${RESP_HEADERS_EXTRA[@]:-}"; do
    [[ -n "${_h}" ]] && _headers="${_headers}
${_h}"
  done
  _headers="${_headers}
"
  if [[ "${_dumpheader}" == "-" ]]; then
    printf '%s\n' "${_headers}"
  else
    printf '%s\n' "${_headers}" > "${_dumpheader}"
  fi
fi

if [[ -n "${_writeout}" ]]; then
  printf '%s' "${_writeout//\%\{http_code\}/${RESP_STATUS}}"
fi

if [[ "${_fail}" == 1 && "${RESP_STATUS}" -ge 400 ]]; then
  exit 22
fi
exit 0
