#!/usr/bin/env bash
# lib/config.sh — Team config storage: two-layer load/merge, schema validation,
# credential-shape rejection, and the single-source version reader.
#
# The config files are YAML, but the Bash port ships no `yq` (runtime deps are
# curl/jq/git only). We therefore parse a DELIBERATELY RESTRICTED YAML subset —
# the exact dialect the config command writes and the self-documenting template
# teaches: 2-space block indentation, `key: value` mappings, `- ` sequences,
# plain / single- / double-quoted scalars, `true`/`false`/`null`, `#` comments,
# blank lines. Flow collections and anchors are out of scope (Constitution XV).
#
# Validation encodes contracts/config.schema.json and config.local.schema.json
# as declarative jq programs (the same technique as engine/interchange.sh). A
# credential-shaped value (ATATT token, real *.atlassian.net host, or an email
# address) is refused with EXIT_CONFIG (4); the offending value is NEVER echoed
# (NFR-3). The PowerShell port (lib/Config.psm1) mirrors this module function
# for function; the YAML→JSON output is proven byte-identical by the parity test.
#
# Port infrastructure only: NO Jira knowledge.

[[ -n ${_JIRA_LIB_CONFIG:-} ]] && return 0
_JIRA_LIB_CONFIG=1

# Exit code table is shared across lib modules; `:=` keeps re-sourcing safe.
: "${EXIT_CONFIG:=4}"
: "${JIRA_CONFIG_DIR:=.specify/jira}"

_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_CONFIG_LIB_DIR}/output.sh"   # json_canonical (byte-parity serialiser)

# =============================================================================
# Version single-source (T032, FR-021/FR-022)
# =============================================================================

# _config_extension_yml — resolve the extension.yml path (overridable for tests).
_config_extension_yml() {
  if [[ -n "${SPEC_KIT_JIRA_EXTENSION_YML:-}" ]]; then
    printf '%s' "${SPEC_KIT_JIRA_EXTENSION_YML}"
  else
    # lib/ -> bash/ -> scripts/ -> <extension root>/extension.yml
    printf '%s' "${_CONFIG_LIB_DIR}/../../../extension.yml"
  fi
}

# config_extension_version — print the single source-of-truth version string,
# read from the `version:` field of extension.yml. No other version marker may
# exist in the tree (SC-006, CI-grep-enforced).
config_extension_version() {
  local yml
  yml="$(_config_extension_yml)"
  if [[ ! -f "${yml}" ]]; then
    printf 'config: extension metadata not found: %s\n' "${yml}" >&2
    return "${EXIT_CONFIG}"
  fi
  # The official manifest schema nests the field under the `extension:` block
  # (indented), so only an INDENTED `version:` matches — the top-level
  # `schema_version:` and `requires.speckit_version:` never can.
  local line
  line="$(grep -E '^[[:space:]]+version:[[:space:]]*' "${yml}" | head -n1)"
  if [[ -z "${line}" ]]; then
    printf 'config: no version field in %s\n' "${yml}" >&2
    return "${EXIT_CONFIG}"
  fi
  # Strip the key and any surrounding whitespace/quotes.
  local value="${line#*version:}"
  value="${value#"${value%%[![:space:]]*}"}"   # ltrim
  value="${value%"${value##*[![:space:]]}"}"    # rtrim
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  printf '%s' "${value}"
}

# config_assert_single_version_source — refuse any hand-maintained version marker
# outside the extension (FR-022). Returns EXIT_CONFIG (4) if one is found.
config_assert_single_version_source() {
  local stray="${JIRA_CONFIG_DIR}/VERSION"
  if [[ -f "${stray}" ]]; then
    printf 'config: a stray version marker exists at %s — the version is single-sourced from extension.yml (FR-022); remove it.\n' \
      "${stray}" >&2
    return "${EXIT_CONFIG}"
  fi
  return 0
}

# =============================================================================
# YAML subset -> JSON (T030)
# =============================================================================

# Parser state (globals, reset per parse). Two parallel arrays hold the retained
# (non-blank, non-comment) lines' indentation and trimmed content; a cursor walks
# them via mutually-recursive block parsers.
_cfg_indents=()
_cfg_lines=()
_cfg_n=0
_cfg_i=0

# _cfg_strip_inline_comment <line> — drop a ` #...` trailing comment that is not
# inside quotes. Prints the cleaned line.
_cfg_strip_inline_comment() {
  local line="$1" out="" i ch in_s=0 in_d=0 prev=""
  for ((i = 0; i < ${#line}; i++)); do
    ch="${line:i:1}"
    if [[ "${ch}" == "'" && ${in_d} -eq 0 ]]; then
      in_s=$((1 - in_s))
    elif [[ "${ch}" == '"' && ${in_s} -eq 0 ]]; then
      in_d=$((1 - in_d))
    elif [[ "${ch}" == "#" && ${in_s} -eq 0 && ${in_d} -eq 0 && (-z "${prev}" || "${prev}" == " " || "${prev}" == $'\t') ]]; then
      break
    fi
    out+="${ch}"
    prev="${ch}"
  done
  # rtrim
  out="${out%"${out##*[![:space:]]}"}"
  printf '%s' "${out}"
}

# _cfg_prep <file> — populate the parser arrays from a YAML file.
_cfg_prep() {
  local file="$1" raw indent body
  _cfg_indents=()
  _cfg_lines=()
  _cfg_n=0
  _cfg_i=0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%$'\r'}"                          # tolerate CRLF
    body="${raw#"${raw%%[![:space:]]*}"}"       # content without leading ws
    [[ -z "${body}" ]] && continue              # blank line
    [[ "${body}" == "#"* ]] && continue         # full-line comment
    indent=$((${#raw} - ${#body}))
    body="$(_cfg_strip_inline_comment "${body}")"
    [[ -z "${body}" ]] && continue
    _cfg_indents+=("${indent}")
    _cfg_lines+=("${body}")
    _cfg_n=$((_cfg_n + 1))
  done < "${file}"
}

# _cfg_is_map_entry <content> — true when the line opens a `key:` mapping entry
# (as opposed to a bare scalar such as a URL). The key charset is intentionally
# narrow; `key:` and `key: value` match, `https://x` does not. The apostrophe is
# included because discovered status names ("Won't Do") are legal map keys.
_cfg_is_map_entry() {
  local re="^[A-Za-z0-9_.' -]+:([[:space:]].*)?$"
  [[ "$1" =~ $re ]]
}

# _cfg_scalar_json <raw> — encode a YAML scalar as a JSON value.
_cfg_scalar_json() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  case "${s}" in
    '"'*'"')
      s="${s#\"}"; s="${s%\"}"
      jq -Rn --arg v "${s}" '$v'
      ;;
    "'"*"'")
      s="${s#\'}"; s="${s%\'}"
      jq -Rn --arg v "${s}" '$v'
      ;;
    true) printf 'true' ;;
    false) printf 'false' ;;
    null | '~' | '') printf 'null' ;;
    *) jq -Rn --arg v "${s}" '$v' ;;
  esac
}

# The recursive block parsers mutate the shared cursor `_cfg_i`, so they MUST NOT
# be invoked through command substitution (a subshell would discard the cursor
# advance). They return their JSON fragment through the global `_CFG_RET` instead.
_CFG_RET=""

# _cfg_parse_value — dispatch to sequence or mapping at the cursor's indent.
_cfg_parse_value() {
  ((_cfg_i >= _cfg_n)) && { _CFG_RET="null"; return; }
  local ind="${_cfg_indents[_cfg_i]}" content="${_cfg_lines[_cfg_i]}"
  if [[ "${content}" == "-" || "${content}" == "- "* ]]; then
    _cfg_parse_sequence "${ind}"
  else
    _cfg_parse_mapping "${ind}"
  fi
}

# _cfg_parse_mapping <indent> — parse consecutive `key:`/`key: value` lines.
_cfg_parse_mapping() {
  local ind="$1" parts=() key rest val
  while ((_cfg_i < _cfg_n)); do
    [[ "${_cfg_indents[_cfg_i]}" != "${ind}" ]] && break
    local content="${_cfg_lines[_cfg_i]}"
    [[ "${content}" == "-" || "${content}" == "- "* ]] && break
    _cfg_is_map_entry "${content}" || break
    key="${content%%:*}"
    key="${key%"${key##*[![:space:]]}"}"        # rtrim key
    rest="${content#*:}"
    rest="${rest#"${rest%%[![:space:]]*}"}"      # ltrim value
    ((_cfg_i++))
    if [[ -n "${rest}" ]]; then
      val="$(_cfg_scalar_json "${rest}")"
    elif ((_cfg_i < _cfg_n)) && ((_cfg_indents[_cfg_i] > ind)); then
      _cfg_parse_value; val="${_CFG_RET}"
    else
      val="null"
    fi
    parts+=("$(jq -Rn --arg k "${key}" '$k')":"${val}")
  done
  local IFS=,
  _CFG_RET="{${parts[*]}}"
}

# _cfg_parse_sequence <indent> — parse consecutive `- ...` items.
_cfg_parse_sequence() {
  local ind="$1" items=() rest item
  while ((_cfg_i < _cfg_n)); do
    [[ "${_cfg_indents[_cfg_i]}" != "${ind}" ]] && break
    local content="${_cfg_lines[_cfg_i]}"
    [[ "${content}" == "-" || "${content}" == "- "* ]] || break
    if [[ "${content}" == "-" ]]; then
      rest=""
    else
      rest="${content:2}"
    fi
    if [[ -z "${rest}" ]]; then
      ((_cfg_i++))
      if ((_cfg_i < _cfg_n)) && ((_cfg_indents[_cfg_i] > ind)); then
        _cfg_parse_value; item="${_CFG_RET}"
      else
        item="null"
      fi
    elif _cfg_is_map_entry "${rest}"; then
      # The dash introduces a mapping whose first key sits at column ind+2.
      # Rewrite the current line as that first entry and parse a mapping there.
      _cfg_lines[_cfg_i]="${rest}"
      _cfg_indents[_cfg_i]=$((ind + 2))
      _cfg_parse_mapping $((ind + 2)); item="${_CFG_RET}"
    else
      ((_cfg_i++))
      item="$(_cfg_scalar_json "${rest}")"
    fi
    items+=("${item}")
  done
  local IFS=,
  _CFG_RET="[${items[*]}]"
}

# config_yaml_to_json <file> — parse the YAML subset and print canonical JSON.
config_yaml_to_json() {
  local file="$1" json
  [[ -f "${file}" ]] || { printf 'config: file not found: %s\n' "${file}" >&2; return 1; }
  _cfg_prep "${file}"
  _cfg_parse_value
  json="${_CFG_RET}"
  # Canonicalise (and prove well-formed). A malformed subset surfaces here.
  printf '%s' "${json}" | jq -cS . 2> /dev/null || {
    printf 'config: %s is not valid config YAML\n' "${file}" >&2
    return 1
  }
}

# =============================================================================
# JSON -> canonical YAML (T044) — the deterministic writer
# =============================================================================

# The config command writes the machine-owned config.local.yml (the resolved-id
# table filled by discovery). To make a re-run byte-identical (FR-003), the
# writer is DETERMINISTIC and a FIXED POINT of the reader above: emitting a value
# then re-parsing it yields the same value. Keys are sorted (ordinal, matching
# json_canonical) and emitted plain (the reader does not accept quoted keys);
# string values are double-quoted (the reader strips the quotes verbatim, so any
# numeric-looking id round-trips as a string, exactly as the reader produces).
# The PowerShell port (ConvertTo-JiraConfigYaml) emits byte-identical output.
#
# The restricted subset carries no `"`/`\` in keys or values (Jira logical names
# and ids do not); the reader's naive quote handling makes those safe to omit.

# _cfg_yaml_emit_jq — the recursive jq emitter (2-space block indent, sorted
# object keys, `- ` sequences). Kept as a single self-recursive function because
# jq forbids mutual recursion between separate defs.
# shellcheck disable=SC2016  # `\(...)`-free; single-quoted jq program
# kcov-excl-start — jq literal (string lines are not statements)
_CFG_YAML_EMIT_JQ='
def yscalar:
  if type=="string" then "\"" + . + "\""
  elif type=="boolean" then (if . then "true" else "false" end)
  elif type=="null" then "null"
  else tostring end;
def yemit(ind):
  if type=="object" then
    (to_entries | sort_by(.key) | map(
      .key as $k | .value as $v |
      (if ($v|type)=="object" then
         (if ($v|length)==0 then ind+$k+": {}" else ind+$k+":\n"+($v|yemit(ind+"  ")) end)
       elif ($v|type)=="array" then
         (if ($v|length)==0 then ind+$k+": []" else ind+$k+":\n"+($v|yemit(ind+"  ")) end)
       else ind+$k+": "+($v|yscalar) end)
    ) | join("\n"))
  elif type=="array" then
    (map(
      (if (type=="object" or type=="array") then ind+"-\n"+(yemit(ind+"  "))
       else ind+"- "+yscalar end)
    ) | join("\n"))
  else . end;
yemit("")'
# kcov-excl-stop

# config_to_yaml — read a JSON value on stdin, print its canonical YAML on stdout
# (no trailing newline; the caller adds exactly one when writing the file).
config_to_yaml() {
  jq -rS "${_CFG_YAML_EMIT_JQ}"
}

# =============================================================================
# Credential-shape rejection (T031, FR-023)
# =============================================================================

# _cfg_credential_errors — read a JSON object on stdin; print one error line per
# credential-shaped string value found (excluding privacy.allowlist, FR-053).
# The value itself is NEVER printed (NFR-3) — only its path and the matched shape.
_cfg_credential_errors() {
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -r '
    def disppath:
      reduce .[] as $p (""; . + (if ($p|type)=="number" then "[\($p)]"
                                 elif . == "" then $p else "." + $p end));
    [ paths(scalars) as $p
      | select( ($p[0] // "") != "privacy" )
      | { path: ($p|disppath), v: (getpath($p)|tostring) }
      | ( if (.v|test("^ATATT")) then "\(.path): Atlassian API token"
          elif (.v|test("[a-z0-9][a-z0-9-]*\\.atlassian\\.net")) then "\(.path): Atlassian Cloud host"
          elif (.v|test("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$")) then "\(.path): email address"
          else empty end )
    ] | .[]
  ' 2> /dev/null
  # kcov-excl-stop
}

# =============================================================================
# Status classification + phase->status mapping (T039, FR-011/FR-034)
# =============================================================================

# config_classify_statuses <statuses-json> [phase-status-map-json] [halted-json]
# Classify each discovered status into mapped|post-scope|halted|unknown. The
# classification is SEEDED objectively from Jira's statusCategory (done ->
# post-scope, everything else -> unknown) and refined by the operator: a status a
# phase maps to is `mapped` (overriding the done seed, research §4); an operator-
# designated stop state is `halted`. There is NO built-in "ideal" status/phase
# default table — the operator's configured workflow is authoritative (FR-012).
# Prints the canonical {status_name: category} object.
config_classify_statuses() {
  local statuses="$1" psmap="${2:-}" halted="${3:-}"
  [[ -z "${psmap}" ]] && psmap='{}'
  [[ -z "${halted}" ]] && halted='[]'
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -n --argjson st "${statuses}" --argjson pm "${psmap}" --argjson hd "${halted}" '
    ($pm | [.[]]) as $targets
    | reduce $st[] as $s ({};
        .[$s.name] = (
          if ($s.name | IN($targets[])) then "mapped"
          elif ($s.name | IN($hd[])) then "halted"
          elif ($s.status_category == "done") then "post-scope"
          else "unknown" end))
  ' | json_canonical
  # kcov-excl-stop
}

# config_phase_status_targets <phase-status-map-json> — the DISTINCT statuses a
# phase->status map resolves to. Many-to-one: two consecutive phases on one
# status collapse to a single target, so no transition is produced (FR-011).
config_phase_status_targets() {
  local psmap="${1:-}"
  [[ -z "${psmap}" ]] && psmap='{}'
  jq -n --argjson pm "${psmap}" '[ $pm[] ] | unique' | json_canonical
}

# =============================================================================
# Schema validation (T030) — encodes config.schema.json / config.local.schema.json
# =============================================================================

# shellcheck disable=SC2016  # `\(...)` is jq string interpolation, not shell expansion
# kcov-excl-start — jq literal (string lines are not statements)
_CFG_TEAM_ERRORS_JQ='
def projkey: test("^[A-Z][A-Z0-9_]+$");
[
  (if (.projects|type) != "array" or (.projects|length) < 1
   then "projects must be a non-empty array" else empty end),
  (if (.routing_default|type) != "string" or ((.routing_default|projkey) != true)
   then "routing_default must be a valid project key" else empty end),
  (keys_unsorted[] | select(IN("version_compat","projects","routing","routing_default","privacy")|not)
   | "unknown top-level key: \(.)"),
  ((.projects // []) | to_entries[] | .key as $i | .value as $p |
    ( [ (if (($p.key // "")|projkey) != true then "projects[\($i)].key is not a valid project key" else empty end),
        (if ($p | has("style")) and ($p.style|IN("company_managed","team_managed")|not) then "projects[\($i)].style is invalid" else empty end),
        (if ($p.epic_strategy|IN("per_repo","per_feature")|not) then "projects[\($i)].epic_strategy is invalid" else empty end),
        (if ($p.task_strategy|IN("subtask","linked_story")|not) then "projects[\($i)].task_strategy is invalid" else empty end),
        (if ($p.task_strategy == "linked_story" and (($p.link_type // "")|length) < 1)
         then "projects[\($i)].link_type is required when task_strategy=linked_story" else empty end)
      ][] ) )
] | flatten'
# kcov-excl-stop

# shellcheck disable=SC2016  # `\(...)` is jq string interpolation, not shell expansion
# kcov-excl-start — jq literal (string lines are not statements)
_CFG_LOCAL_ERRORS_JQ='
[
  (keys_unsorted[] | select(IN("site_alias","resolved_ids","overrides")|not)
   | "unknown config.local key: \(.)"),
  ((.resolved_ids // {}) | to_entries[] | .key as $k | .value as $v
   | ( (if (($v|type) == "object") and ($v | has("style"))
          and ($v.style | IN("company_managed","team_managed") | not)
        then "resolved_ids.\($k).style is invalid" else empty end),
       (if (($v|type) == "object") and ($v | has("style_source"))
          and ($v.style_source | IN("api","operator") | not)
        then "resolved_ids.\($k).style_source is invalid" else empty end) ))
] | flatten'
# kcov-excl-stop

# _cfg_schema_errors <jq-program> — read JSON on stdin, print each error line.
_cfg_schema_errors() {
  jq -r "${1} | .[]" 2> /dev/null
}

# =============================================================================
# Load / merge orchestration (T030)
# =============================================================================

# _cfg_report_errors <label> <file> — read error lines on stdin; if any, prefix
# each with context and return EXIT_CONFIG; else return 0.
_cfg_report_errors() {
  local label="$1" file="$2" any=0 line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    any=1
    printf 'config: %s (%s): %s\n' "${label}" "${file}" "${line}" >&2
  done
  ((any)) && return "${EXIT_CONFIG}"
  return 0
}

# config_load [config_dir] — load config.yml (+ optional config.local.yml),
# credential-scan and schema-validate both layers, merge local overrides over
# the team config, and print the merged JSON on stdout. Returns EXIT_CONFIG (4)
# on any credential-shape or schema violation, or a missing/invalid config.yml.
config_load() {
  local dir="${1:-${JIRA_CONFIG_DIR}}"
  local team="${dir}/config.yml"
  local local_f="${dir}/config.local.yml"

  if [[ ! -f "${team}" ]]; then
    printf 'config: %s not found — run /speckit.jira.config first.\n' "${team}" >&2
    return "${EXIT_CONFIG}"
  fi

  local team_json
  team_json="$(config_yaml_to_json "${team}")" || return "${EXIT_CONFIG}"

  printf '%s' "${team_json}" | _cfg_credential_errors | _cfg_report_errors "credential" "${team}" || return "${EXIT_CONFIG}"
  printf '%s' "${team_json}" | _cfg_schema_errors "${_CFG_TEAM_ERRORS_JQ}" | _cfg_report_errors "schema" "${team}" || return "${EXIT_CONFIG}"

  local merged="${team_json}"
  if [[ -f "${local_f}" ]]; then
    local local_json
    local_json="$(config_yaml_to_json "${local_f}")" || return "${EXIT_CONFIG}"
    printf '%s' "${local_json}" | _cfg_credential_errors | _cfg_report_errors "credential" "${local_f}" || return "${EXIT_CONFIG}"
    printf '%s' "${local_json}" | _cfg_schema_errors "${_CFG_LOCAL_ERRORS_JQ}" | _cfg_report_errors "schema" "${local_f}" || return "${EXIT_CONFIG}"
    # Recursive object merge of the local `overrides` over the team config. jq's
    # `*` replaces ARRAYS wholesale, which would silently DROP every project the
    # local override does not repeat — so `projects` is merged per-entry BY KEY:
    # each override entry deep-merges into the team entry with the same key,
    # unmatched team entries survive, and unmatched override entries are appended.
    # kcov-excl-start — jq literal (string lines are not statements)
    merged="$(jq -cSn --argjson t "${team_json}" --argjson l "${local_json}" '
      ($l.overrides // {}) as $o
      | ($t * $o)
      | if ($o | has("projects")) and (($t.projects? | type) == "array") and (($o.projects | type) == "array")
        then .projects = (
          ($t.projects | map(.key)) as $keys
          | ($t.projects
             | map(. as $p | (first($o.projects[] | select(.key == $p.key)) // null) as $ov
                   | if $ov == null then $p else $p * $ov end))
            + ($o.projects | map(select((.key as $k | $keys | index($k)) == null)))
        )
        else . end')"
    # kcov-excl-stop
  fi

  printf '%s' "${merged}"
}
