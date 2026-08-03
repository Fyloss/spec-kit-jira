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

# The template's literal placeholder project key (templates/config.yml.template):
# a configured key equal to it is treated as UNSET (002 US2, FR-005). The
# constant lives here, beside the template's config consumer.
: "${JIRA_CONFIG_PLACEHOLDER_KEY:=PROJ}"

# config_key_is_placeholder <key> — the FR-005 placeholder rule.
config_key_is_placeholder() {
  [[ "$1" == "${JIRA_CONFIG_PLACEHOLDER_KEY}" ]]
}

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

# Parser state (globals, reset per parse). Parallel arrays hold the retained
# (non-blank, non-comment) lines' indentation, trimmed content, and 1-based
# SOURCE line number (blank/comment lines are dropped from the arrays but still
# count, since a parse-failure message must name the line as the operator sees
# it in the file); a cursor walks them via mutually-recursive block parsers.
_cfg_indents=()
_cfg_lines=()
_cfg_linenos=()
_cfg_n=0
_cfg_i=0
_cfg_file=""

# _CFG_ERR — the formatted parse-failure message (contracts/parse-failure.md
# §2), or empty when clear. Set by _cfg_raise_parse_failure /
# _cfg_raise_duplicate_key; every parser loop below returns immediately once
# it is set (a flag, not a `return`-code-per-frame throw, so the propagation
# is identical to the PowerShell port's mirrored flag — Constitution VI).
_CFG_ERR=""

# _cfg_strip_inline_comment <line> — drop a ` #...` trailing comment that is not
# inside quotes. Prints the cleaned line.
_cfg_strip_inline_comment() {
  local line="$1"
  local out="" i=0 n=${#line} ch nxt in_s=0 in_d=0 prev=""
  while ((i < n)); do
    ch="${line:i:1}"
    if [[ ${in_d} -eq 1 && "${ch}" == "\\" ]]; then
      # Escape-aware (contracts/yaml-string-escaping.md §2.3): a `\` inside a
      # double-quoted region consumes the following character without
      # changing quote state, so an escaped `"` cannot close the region.
      nxt="${line:i+1:1}"
      out+="${ch}${nxt}"
      prev="${nxt}"
      i=$((i + 2))
      continue
    fi
    if [[ "${ch}" == "'" && ${in_d} -eq 0 ]]; then
      in_s=$((1 - in_s))
    elif [[ "${ch}" == '"' && ${in_s} -eq 0 ]]; then
      in_d=$((1 - in_d))
    elif [[ "${ch}" == "#" && ${in_s} -eq 0 && ${in_d} -eq 0 && (-z "${prev}" || "${prev}" == " " || "${prev}" == $'\t') ]]; then
      break
    fi
    out+="${ch}"
    prev="${ch}"
    i=$((i + 1))
  done
  # rtrim
  out="${out%"${out##*[![:space:]]}"}"
  printf '%s' "${out}"
}

# _cfg_prep <file> — populate the parser arrays from a YAML file.
_cfg_prep() {
  local file="$1" raw indent body lineno=0
  _cfg_file="${file}"
  _cfg_indents=()
  _cfg_lines=()
  _cfg_linenos=()
  _cfg_n=0
  _cfg_i=0
  _CFG_ERR=""
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    lineno=$((lineno + 1))
    raw="${raw%$'\r'}"                          # tolerate CRLF
    body="${raw#"${raw%%[![:space:]]*}"}"       # content without leading ws
    [[ -z "${body}" ]] && continue              # blank line
    [[ "${body}" == "#"* ]] && continue         # full-line comment
    indent=$((${#raw} - ${#body}))
    body="$(_cfg_strip_inline_comment "${body}")"
    [[ -z "${body}" ]] && continue
    _cfg_indents+=("${indent}")
    _cfg_lines+=("${body}")
    _cfg_linenos+=("${lineno}")
    _cfg_n=$((_cfg_n + 1))
  done < "${file}"
}

# _cfg_redact_shape <line> <ere-pattern> <case_insensitive:0|1> — replace every
# match of pattern in line with [redacted]. Prints the result.
_cfg_redact_shape() {
  local line="$1" pattern="$2" ci="$3" hay match prefix start len
  while :; do
    if [[ "${ci}" == "1" ]]; then hay="${line,,}"; else hay="${line}"; fi
    [[ "${hay}" =~ ${pattern} ]] || break
    match="${BASH_REMATCH[0]}"
    [[ -z "${match}" ]] && break
    prefix="${hay%%"${match}"*}"
    start=${#prefix}
    len=${#match}
    line="${line:0:start}[redacted]${line:start+len}"
  done
  printf '%s' "${line}"
}

# _cfg_redact_line <content> — replace every credential-shaped substring with
# [redacted] before a parse-failure line is formatted (contracts/parse-failure.md
# §2.1): the BLOCK-tier shapes the privacy guard recognises (an Atlassian API
# token prefix, a real *.atlassian.net host) and the WARN-tier email shape
# (Constitution IX). Applied to the WHOLE line — a line that failed the
# mapping-entry test has no reliable delimiter, so there is no value half to
# isolate.
_cfg_redact_line() {
  local line="$1"
  line="$(_cfg_redact_shape "${line}" 'ATATT[A-Za-z0-9._=+/-]{2,}' 0)"
  line="$(_cfg_redact_shape "${line}" '[a-z0-9][a-z0-9-]*\.atlassian\.net' 1)"
  line="$(_cfg_redact_shape "${line}" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 1)"
  printf '%s' "${line}"
}

# _cfg_raise_parse_failure <cursor-index> — set _CFG_ERR to the three-line
# message of contracts/parse-failure.md §2 for the retained line at that
# index. The line's content is redacted before it is formatted (§2.1).
_cfg_raise_parse_failure() {
  local idx="$1" line content
  line="${_cfg_linenos[idx]}"
  content="$(_cfg_redact_line "${_cfg_lines[idx]}")"
  _CFG_ERR="$(printf 'config: %s:%s: cannot parse this line as a mapping entry: %s\nconfig: a key must be followed by ": " — quote the key if it contains a colon, e.g. "Blocked: waiting": "10001"\nconfig: re-run /speckit.jira.config to regenerate %s from the Jira instance.' \
    "${_cfg_file}" "${line}" "${content}" "${_cfg_file}")"
}

# _cfg_raise_duplicate_key <cursor-index> <key> <first-lineno> — set _CFG_ERR
# to the duplicate-key message of contracts/parse-failure.md §1 (FR-016). The
# key is redacted like any other printed line content (§2.1).
_cfg_raise_duplicate_key() {
  local idx="$1" key="$2" first_line="$3" line redacted_key
  line="${_cfg_linenos[idx]}"
  redacted_key="$(_cfg_redact_line "${key}")"
  _CFG_ERR="$(printf 'config: %s:%s: duplicate key %s — already defined at line %s\nconfig: two entries cannot claim the same name; delete or rename one of them.\nconfig: re-run /speckit.jira.config to regenerate %s from the Jira instance.' \
    "${_cfg_file}" "${line}" "${redacted_key}" "${first_line}" "${_cfg_file}")"
}

# _cfg_map_entry_key <content> — locate a mapping entry's DELIMITER COLON by
# structure, not by an enumerated key charset (contracts/yaml-key-grammar.md
# §1): a key of any script and ordinary punctuation is recognised, while a bare
# URL value (colon followed by a non-whitespace character) is not. On success,
# sets _CFG_KEY (verbatim for a quoted key, right-trimmed for a bare one) and
# _CFG_REST (the left-trimmed value text) and returns 0. On failure — no
# delimiter colon found, or the key is empty after trimming (§1.2 step 4,
# §1.1 by the same rule) — clears both and returns 1: "not a mapping entry",
# not yet a verdict on whether that is fatal (§1.4 leaves that to the caller).
# _cfg_decode_escapes <body> — undo the writer's escaping (contracts/
# yaml-string-escaping.md §2.1): a left-to-right walk where `\"` becomes `"`
# and `\\` becomes `\`; any other backslash, including one at the end of the
# body, is kept literal (FR-012) rather than treated as a parse failure.
_cfg_decode_escapes() {
  local s="$1"
  [[ "${s}" != *"\\"* ]] && { printf '%s' "${s}"; return; }
  local out="" i=0 n=${#s} ch nxt
  while ((i < n)); do
    ch="${s:i:1}"
    if [[ "${ch}" == "\\" ]]; then
      nxt="${s:i+1:1}"
      if [[ "${nxt}" == '"' || "${nxt}" == "\\" ]]; then
        out+="${nxt}"
        i=$((i + 2))
        continue
      fi
    fi
    out+="${ch}"
    i=$((i + 1))
  done
  printf '%s' "${out}"
}

_CFG_KEY=""
_CFG_REST=""
_cfg_map_entry_key() {
  local content="$1"
  local n=${#content}
  _CFG_KEY=""
  _CFG_REST=""
  ((n == 0)) && return 1
  local first="${content:0:1}"
  if [[ "${first}" == '"' || "${first}" == "'" ]]; then
    # Quoted key (§1.1): the key is bounded by the NEXT occurrence of the same
    # quote character. When that quote is `"`, the scan is escape-aware
    # (contracts/yaml-string-escaping.md §2.3): a `\` consumes the following
    # character without ending the key, so the closing quote is the next `"`
    # not preceded by an escaping backslash. A single-quoted key has no
    # escape sequences at all (§2.2). The character immediately after the
    # closing quote must be the delimiter colon, itself followed by
    # whitespace or end of line.
    local q="${first}" i close=-1
    if [[ "${q}" == '"' ]]; then
      for ((i = 1; i < n; i++)); do
        if [[ "${content:i:1}" == "\\" ]]; then
          i=$((i + 1))
          continue
        fi
        if [[ "${content:i:1}" == "${q}" ]]; then close=${i}; break; fi
      done
    else
      for ((i = 1; i < n; i++)); do
        if [[ "${content:i:1}" == "${q}" ]]; then close=${i}; break; fi
      done
    fi
    ((close < 0)) && return 1
    local colon_idx=$((close + 1))
    [[ "${content:colon_idx:1}" != ":" ]] && return 1
    local after_idx=$((colon_idx + 1)) nxt
    nxt="${content:after_idx:1}"
    [[ -n "${nxt}" && "${nxt}" != " " && "${nxt}" != $'\t' ]] && return 1
    local key="${content:1:close-1}"
    [[ -z "${key}" ]] && return 1
    [[ "${q}" == '"' ]] && key="$(_cfg_decode_escapes "${key}")"
    _CFG_KEY="${key}"
    local tail="${content:after_idx}"
    _CFG_REST="${tail#"${tail%%[![:space:]]*}"}"
    return 0
  fi
  # Bare key (§1.2): scan left to right for the first `:` followed by
  # whitespace or end of line. Deliberately NOT quote-aware — `Won't Do: "1"`
  # must parse, and a quote-aware scan would open a single-quote region at the
  # apostrophe and never find the delimiter (research R1).
  local i
  for ((i = 0; i < n; i++)); do
    [[ "${content:i:1}" == ":" ]] || continue
    local after_idx=$((i + 1)) nxt
    nxt="${content:after_idx:1}"
    if [[ -z "${nxt}" || "${nxt}" == " " || "${nxt}" == $'\t' ]]; then
      local key="${content:0:i}"
      key="${key%"${key##*[![:space:]]}"}"
      [[ -z "${key}" ]] && return 1
      _CFG_KEY="${key}"
      local tail="${content:after_idx}"
      _CFG_REST="${tail#"${tail%%[![:space:]]*}"}"
      return 0
    fi
  done
  return 1
}

# _cfg_is_map_entry <content> — true when the line opens a mapping entry
# (contracts/yaml-key-grammar.md §1). Also used as a non-fatal DISPATCH by
# _cfg_parse_sequence to decide whether `- x` opens a mapping or is a plain
# scalar item (§1.4) — a "no" here must never be treated as an error.
_cfg_is_map_entry() {
  _cfg_map_entry_key "$1"
}

# _cfg_scalar_json <raw> — encode a YAML scalar as a JSON value.
_cfg_scalar_json() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  case "${s}" in
    '"'*'"')
      s="${s#\"}"; s="${s%\"}"
      s="$(_cfg_decode_escapes "${s}")"
      jq -Rn --arg v "${s}" '$v'
      ;;
    "'"*"'")
      s="${s#\'}"; s="${s%\'}"
      jq -Rn --arg v "${s}" '$v'
      ;;
    true) printf 'true' ;;
    false) printf 'false' ;;
    null | '~' | '') printf 'null' ;;
    # The two EMPTY flow forms, and only those. They are in the subset because
    # config_to_yaml emits exactly them for an empty collection, and the writer
    # is documented above as a fixed point of this reader — without these, a
    # file this module wrote reads back with the strings "[]" and "{}" where it
    # wrote collections. Non-empty flow collections stay out of scope.
    '[]') printf '[]' ;;
    '{}') printf '{}' ;;
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
  local -A seen=()
  while ((_cfg_i < _cfg_n)); do
    [[ "${_cfg_indents[_cfg_i]}" != "${ind}" ]] && break
    local content="${_cfg_lines[_cfg_i]}"
    [[ "${content}" == "-" || "${content}" == "- "* ]] && break
    if ! _cfg_map_entry_key "${content}"; then
      _cfg_raise_parse_failure "${_cfg_i}"
      return
    fi
    key="${_CFG_KEY}"
    rest="${_CFG_REST}"
    # A key repeated at this mapping's own level is malformed (FR-016,
    # yaml-key-grammar.md §1.5) — the same name at a DIFFERENT level is legal,
    # so `seen` is local to this frame, freshly scoped by every recursive call.
    if [[ -n "${seen[${key}]+x}" ]]; then
      _cfg_raise_duplicate_key "${_cfg_i}" "${key}" "${seen[${key}]}"
      return
    fi
    seen["${key}"]="${_cfg_linenos[_cfg_i]}"
    ((_cfg_i++))
    if [[ -n "${rest}" ]]; then
      val="$(_cfg_scalar_json "${rest}")"
    elif ((_cfg_i < _cfg_n)) && ((_cfg_indents[_cfg_i] > ind)); then
      _cfg_parse_value; val="${_CFG_RET}"
      [[ -n "${_CFG_ERR}" ]] && return
    elif ((_cfg_i < _cfg_n)) && ((_cfg_indents[_cfg_i] == ind)) \
      && { [[ "${_cfg_lines[_cfg_i]}" == "-" ]] || [[ "${_cfg_lines[_cfg_i]}" == "- "* ]]; }; then
      # A block sequence may sit at its PARENT KEY's indentation rather than
      # under it. Both forms are valid YAML and this one is PyYAML's default —
      # which matters because PyYAML is what `specify extension add` serialises
      # the hook registry with:
      #
      #     hooks:
      #       before_specify:
      #       - extension: jira        <- same indent as the key
      #
      # Requiring a greater indent made this reader stop at the key and return
      # null for its value, so the registry of every real installation parsed as
      # `{"installed":null}` and hook health called a healthy repository
      # unreadable (003 T010).
      _cfg_parse_sequence "${ind}"; val="${_CFG_RET}"
      [[ -n "${_CFG_ERR}" ]] && return
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
        [[ -n "${_CFG_ERR}" ]] && return
      else
        item="null"
      fi
    elif _cfg_is_map_entry "${rest}"; then
      # The dash introduces a mapping whose first key sits at column ind+2.
      # Rewrite the current line as that first entry and parse a mapping there.
      _cfg_lines[_cfg_i]="${rest}"
      _cfg_indents[_cfg_i]=$((ind + 2))
      _cfg_parse_mapping $((ind + 2)); item="${_CFG_RET}"
      [[ -n "${_CFG_ERR}" ]] && return
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
  if [[ -n "${_CFG_ERR}" ]]; then
    printf '%s\n' "${_CFG_ERR}" >&2
    return "${EXIT_CONFIG}"
  fi
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
# json_canonical) and emitted DOUBLE-QUOTED, unconditionally (contract
# yaml-key-grammar.md §2.1) — four key forms (an embedded `: `, a ` #`, a
# leading `- `, and padding whitespace) cannot round-trip bare, and quoting
# every key neutralises all four with one rule instead of a "does this key need
# quoting?" predicate duplicated across ports (research R2). The reader keeps
# accepting bare keys, because the committable config.yml and the host's
# PyYAML-written extensions.yml use them. String values stay double-quoted (the
# reader strips the quotes verbatim, so any numeric-looking id round-trips as a
# string, exactly as the reader produces). The PowerShell port
# (ConvertTo-JiraConfigYaml) emits byte-identical output.
#
# `"` and `\` in a key or string value are escaped (`\"`, `\\`) rather than
# refused — the reader undoes exactly those two sequences (013, research R3).
# A key or a string value containing a line break still cannot be represented
# in this dialect, so the writer REFUSES it (research R5/R8): EXIT_CONFIG,
# naming the path, never the value (Constitution IV).

# _cfg_write_refusal_errors — read a JSON value on stdin; print one error line
# per key or string value the writer cannot represent (contract §2.3). The
# value itself is NEVER printed — only the path at which it occurred.
# shellcheck disable=SC2016  # `\(...)` is jq string interpolation, not shell expansion
# kcov-excl-start — jq literal (string lines are not statements)
_CFG_WRITE_REFUSAL_JQ='
def disppath:
  reduce .[] as $p (""; . + (if ($p|type)=="number" then "[\($p)]"
                             elif . == "" then $p else "." + $p end));
def badchars: test("[\n\r]");
( [ paths as $p
    | ($p[-1]) as $last
    | select(($last|type)=="string") | select($last|badchars)
    | "\($p[:-1]|disppath): a key here contains a line break, which this writer cannot represent"
  ]
  + [ paths(scalars) as $p
      | select(getpath($p)|type=="string") | select(getpath($p)|badchars)
      | "\($p|disppath): a string value here contains a line break, which this writer cannot represent"
    ]
) | unique | .[]'
# kcov-excl-stop

# _cfg_yaml_emit_jq — the recursive jq emitter (2-space block indent, sorted
# object keys, `- ` sequences, every key double-quoted). Kept as a single
# self-recursive function because jq forbids mutual recursion between separate
# defs.
# shellcheck disable=SC2016  # `\(...)`-free; single-quoted jq program
# kcov-excl-start — jq literal (string lines are not statements)
_CFG_YAML_EMIT_JQ='
def yesc: (. / "\\" | join("\\\\")) | (. / "\"" | join("\\\""));
def yscalar:
  if type=="string" then "\"" + (.|yesc) + "\""
  elif type=="boolean" then (if . then "true" else "false" end)
  elif type=="null" then "null"
  else tostring end;
def qkey: "\"" + (.|yesc) + "\"";
def yemit(ind):
  if type=="object" then
    (to_entries | sort_by(.key) | map(
      .key as $k | .value as $v |
      (if ($v|type)=="object" then
         (if ($v|length)==0 then ind+($k|qkey)+": {}" else ind+($k|qkey)+":\n"+($v|yemit(ind+"  ")) end)
       elif ($v|type)=="array" then
         (if ($v|length)==0 then ind+($k|qkey)+": []" else ind+($k|qkey)+":\n"+($v|yemit(ind+"  ")) end)
       else ind+($k|qkey)+": "+($v|yscalar) end)
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
# Refuses (EXIT_CONFIG) a key or string value containing `"` or `\`, printing a
# named error per offending path and nothing else — no partial YAML is ever
# emitted for a document this writer cannot faithfully represent.
#
# This is the port's largest MULTI-LINE jq read and the only one whose bytes land
# in a file the operator keeps, so it is where a text-mode jq on Windows was seen
# first: config.local.yml came out with a CRLF on every line but the last while
# the PowerShell twin wrote LF, and ci-conformance.sh failed the written-files
# diff (NFR-1). The line endings are not repaired here — lib/output.sh installs
# one guard around jq itself, for the whole class.
config_to_yaml() {
  local input errs
  input="$(cat)"
  errs="$(printf '%s' "${input}" | jq -r "${_CFG_WRITE_REFUSAL_JQ}" 2> /dev/null)"
  if [[ -n "${errs}" ]]; then
    local line
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      printf 'config: %s\n' "${line}" >&2
    done <<< "${errs}"
    return "${EXIT_CONFIG}"
  fi
  printf '%s' "${input}" | jq -rS "${_CFG_YAML_EMIT_JQ}"
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
def branchpattern:
  (type == "string")
  and (([match("<ID>"; "g")] | length) == 1)
  and (([match("<FEATURE_NAME>"; "g")] | length) == 1)
  and ((gsub("<ID>"; "") | gsub("<FEATURE_NAME>"; "")) | test("^[a-z0-9/_-]*$"));
[
  (if (.projects|type) != "array" or (.projects|length) < 1
   then "projects must be a non-empty array" else empty end),
  (if (.routing_default|type) != "string" or ((.routing_default|projkey) != true)
   then "routing_default must be a valid project key" else empty end),
  (keys_unsorted[] | select(IN("version_compat","projects","routing","routing_default","privacy","teams","field_defaults")|not)
   | "unknown top-level key: \(.)"),
  ( . as $top
    | ($top.projects // []) | map(.key) as $declaredKeys
    | ($top.field_defaults // {}) | to_entries[] as $proj
    | ($proj.key) as $pk | ($proj.value) as $pv
    | (
        (if ($declaredKeys | index($pk)) == null then
          "field_defaults.\($pk) names a project key that is not declared in projects[]"
        else empty end),
        (if ($pv|type) != "object" then
          "field_defaults.\($pk) must be a mapping"
        else empty end),
        (select($pv|type == "object") | $pv as $pv2
          | (
              (if ($pv2|has("ask")) and (($pv2.ask|type) != "boolean") then
                "field_defaults.\($pk).ask must be a boolean"
              else empty end),
              ($pv2 | to_entries[] | select(.key != "ask")) as $te
              | ($te.key) as $ftype | ($te.value) as $fields
              | (
                  (if ($fields|type) != "object" then
                    "field_defaults.\($pk).\($ftype) must be a mapping of field label to value"
                  else empty end),
                  (select($fields|type == "object") | $fields | to_entries[] |
                    select( ((.value|type) as $vt | ($vt != "string" and $vt != "number" and $vt != "boolean")) or (.value == "") )
                    | "field_defaults.\($pk).\($ftype).\(.key) must be a non-empty value")
                )
            )
        )
      )
  ),
  ((.teams // []) | to_entries[] | .key as $i | .value as $t |
    ( [ (if (($t.id // "") | test("^[a-z][a-z0-9]*$") | not)
         then "teams[\($i)].id is invalid" else empty end),
        (if (($t.project // "") | projkey | not)
         then "teams[\($i)].project is not a valid project key" else empty end),
        (if (($t.folder_prefix // "") | test("^[a-z0-9][a-z0-9-]*-$") | not)
         then "teams[\($i)].folder_prefix is invalid" else empty end),
        (if (($t.branch_pattern // "") | branchpattern | not)
         then "teams[\($i)].branch_pattern is invalid" else empty end)
      ][] )),
  ((.teams // []) as $ts | (range(1; ($ts | length)) as $i |
    ( (if ([$ts[0:$i][].id] | index($ts[$i].id)) != null
       then "teams[\($i)].id duplicates an earlier team id" else empty end),
      (if ([$ts[0:$i][].folder_prefix] | index($ts[$i].folder_prefix)) != null
       then "teams[\($i)].folder_prefix duplicates an earlier folder_prefix" else empty end) ))),
  ((.projects // []) | to_entries[] | .key as $i | .value as $p |
    ( [ (if (($p.key // "")|projkey) != true then "projects[\($i)].key is not a valid project key" else empty end),
        (if ($p | has("style")) and ($p.style|IN("company_managed","team_managed")|not) then "projects[\($i)].style is invalid" else empty end),
        ( ["epic_strategy","task_strategy","link_type"][] as $retired
          | if ($p | has($retired))
            then "projects[\($i)] declares `\($retired)`, which this version of spec-kit-jira no longer uses. Delete the line"
            else empty end ),
        (if ($p | has("phase_status_map")) and
            (($p.phase_status_map|type) != "object" or ([$p.phase_status_map[]|type] | any(. != "string")))
         then "projects[\($i)].phase_status_map must be a mapping of lifecycle-event name to status name" else empty end),
        (if ($p | has("halted_statuses")) and (($p.halted_statuses|type) as $t | $t != "array" and $t != "string")
         then "projects[\($i)].halted_statuses must be a list of status names" else empty end),
        (if ($p | has("hierarchy")) then
           (if ($p.hierarchy|type) != "object"
            then "projects[\($i)].hierarchy must be a mapping of role to issue type name"
            else
              ( $p.hierarchy | keys_unsorted[] | select(IN($roles[])|not)
                | "projects[\($i)].hierarchy declares unknown role `\(.)`; the roles are specification, story, task" ),
              ( $p.hierarchy | to_entries[] | select((.value|type) != "string" or .value == "")
                | "projects[\($i)].hierarchy.\(.key) must be a non-empty issue type name" )
            end)
         else empty end)
      ][] ) )
] | flatten'
# kcov-excl-stop

# shellcheck disable=SC2016  # `\(...)` is jq string interpolation, not shell expansion
# kcov-excl-start — jq literal (string lines are not statements)
_CFG_LOCAL_ERRORS_JQ='
[
  (keys_unsorted[] | select(IN("site_alias","resolved_ids","overrides","hooks")|not)
   | "unknown config.local key: \(.)"),
  (if has("hooks") then
     ( .hooks
       | ( (if (type) != "object" then "hooks must be a mapping" else empty end),
           (select(type == "object")
            | (keys_unsorted[] | select(. != "disabled") | "unknown hooks key: \(.)"),
              (if has("disabled") and ((.disabled|type) != "array")
               then "hooks.disabled must be a list of lifecycle event names" else empty end)) ) )
   else empty end),
  ((.resolved_ids // {}) | to_entries[] | .key as $k | .value as $v
   | ( (if (($v|type) == "object") and ($v | has("style"))
          and ($v.style | IN("company_managed","team_managed") | not)
        then "resolved_ids.\($k).style is invalid" else empty end),
       (if (($v|type) == "object") and ($v | has("style_source"))
          and ($v.style_source | IN("api","operator") | not)
        then "resolved_ids.\($k).style_source is invalid" else empty end),
       (if (($v|type) == "object") and ($v | has("roles")) then
          (if ($v.roles|type) != "object"
           then "resolved_ids.\($k).roles must be a mapping"
           else
             ( $v.roles | keys_unsorted[] | select(IN($roles[])|not)
               | "resolved_ids.\($k).roles declares unknown role `\(.)`" ),
             ( $v.roles | to_entries[] | select((.value|type) == "object") | select(.value | has("source"))
               | select((.value.source | IN("declared","operator","derived") | not))
               | "resolved_ids.\($k).roles.\(.key).source is invalid" )
           end)
        else empty end) ))
] | flatten'
# kcov-excl-stop

# _cfg_schema_errors <jq-program> — read JSON on stdin, print each error line.
# `$roles` is the closed role set (JIRA_ROLE_NAMES), bound once here so
# neither jq program below repeats the literal.
_cfg_schema_errors() {
  jq -r --argjson roles "$(_cfg_role_names_json)" "${1} | .[]" 2> /dev/null
}

# =============================================================================
# The operator disable record (003 T012, FR-007/FR-029)
# =============================================================================
#
# `specify extension add` writes `enabled: true` unconditionally for every entry
# it re-adds, with no read of the existing value (003 research R5). So the hook
# registry CANNOT remember that the operator disabled an event: the next install
# or upgrade silently re-enables it. Constitution X forbids that outcome, and
# FR-022 forbids the obvious fix of writing the value back.
#
# The decision is therefore recorded here instead, in the gitignored local
# binding, which lives outside `.specify/extensions/` and survives a reinstall by
# Principle V — and it is honoured at DISPATCH, so it holds even in the window
# between an install that re-enabled the entry and the next ceremony.

# The closed set of seven lifecycle events — the `hooks.disabled` enum of
# contracts/config.local.schema.json. It is declared here because this module
# encodes that schema; hooks/register_hooks.sh consumes it rather than
# redeclaring it, so the set has exactly one source (data-model § Lifecycle event).
JIRA_HOOK_EVENT_NAMES=(before_specify after_specify after_clarify after_plan after_tasks after_implement after_analyze)

# _cfg_hook_events_json — the closed set as a JSON array.
_cfg_hook_events_json() {
  printf '%s\n' "${JIRA_HOOK_EVENT_NAMES[@]}" | jq -cR . | jq -cs .
}

# The closed role set (010, contracts/role-mapping.md §1) — the repository's
# own artifact vocabulary (specification, story, task), never Jira's.
# Declared once per port, following the JIRA_HOOK_EVENT_NAMES precedent above,
# so the set has exactly one source; sink/jira/hierarchy.sh and both
# `for role_key in` loops in commands/config.sh consume it rather than
# redeclaring it. The PowerShell port's mirror is $script:JiraRoleNames
# (lib/Config.psm1).
JIRA_ROLE_NAMES=(specification story task)

# _cfg_role_names_json — the closed role set as a JSON array.
_cfg_role_names_json() {
  printf '%s\n' "${JIRA_ROLE_NAMES[@]}" | jq -cR . | jq -cs .
}

# config_field_defaults_for <project_key> <merged-cfg-json> — one project's
# `field_defaults` entry (011, data-model.md §1): `{ask, <Type>: {<Label>:
# <Value>}, ...}`. `ask` defaults to `true` when the project records none at
# all (FR-014) — the ceremony's question stays on until a team turns it off.
# A project with no `field_defaults` entry gets `{ask:true}` (research R6:
# absence is the off switch — nothing else in the map, nothing merged
# downstream). Prints the canonical object.
config_field_defaults_for() {
  local key="$1" cfg="$2"
  # NOT `$fd.ask // true`: jq's `//` treats a literal `false` the same as
  # absent, so a team that recorded `ask: false` would silently read back as
  # `true` (FR-014's whole off switch, undone by one operator precedence
  # surprise). `has("ask")` is the only correct absence test.
  jq -c --arg k "${key}" '
    ((.field_defaults // {})[$k] // {}) as $fd
    | {ask: (if ($fd | has("ask")) then $fd.ask else true end)} + ($fd | del(.ask))
  ' <<< "${cfg}" | json_canonical
}

# config_field_defaults_yaml <field-defaults-map-json> — the canonical YAML
# text of the whole top-level `field_defaults:` mapping (011, T042), keys
# sorted at every level so a re-run over unchanged input reproduces identical
# bytes (FR-007). Reuses `config_to_yaml`'s scalar quoting/refusal rules
# rather than a second YAML renderer — the region's content is a JSON value
# like any other this port writes. No trailing newline (matches
# `config_to_yaml`; the caller adds exactly one).
config_field_defaults_yaml() {
  local map="${1:-}"
  [[ -z "${map}" ]] && map='{}'
  jq -cn --argjson m "${map}" '{field_defaults: $m}' | config_to_yaml
}

# _cfg_local_path <config_dir> — the local binding's path.
_cfg_local_path() {
  printf '%s/config.local.yml' "${1:-${JIRA_CONFIG_DIR}}"
}

# _cfg_local_json <config_dir> — the local binding as JSON. An ABSENT file
# yields `{}` (never bound). A PRESENT-but-unreadable file PROPAGATES the
# located parse failure and EXIT_CONFIG (contracts/parse-failure.md §4): an
# unreadable binding is not evidence of an empty one, and swallowing it here
# was the defect this feature closes (research R5).
_cfg_local_json() {
  local f
  f="$(_cfg_local_path "$1")"
  [[ -f "${f}" ]] || { printf '{}'; return 0; }
  config_yaml_to_json "${f}"
}

# config_hooks_disabled_read [config_dir] — the recorded set as a canonical JSON
# array of event names, sorted and deduplicated. An absent record is the empty
# set. A name outside the closed set is REPORTED on stderr and ignored rather
# than failing the run: this file is human-editable, and a typo must not stop
# the mirror (data-model § Operator disable record, Validation).
config_hooks_disabled_read() {
  local dir="${1:-${JIRA_CONFIG_DIR}}" json events unknown rc=0
  # An unreadable binding is not evidence that no hook is disabled — an
  # operator-disabled event must be honoured forever (Constitution X), so a
  # read failure PROPAGATES rather than defaulting to the empty set.
  json="$(_cfg_local_json "${dir}")" || rc=$?
  ((rc != 0)) && return "${rc}"
  events="$(_cfg_hook_events_json)"

  unknown="$(jq -r --argjson e "${events}" \
    '((.hooks.disabled // []) | if type == "array" then . else [] end)
     | map(select(. as $x | $e | index($x) == null)) | unique | .[]' <<< "${json}" 2> /dev/null)"
  if [[ -n "${unknown}" ]]; then
    local name
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      printf 'config: %s: unknown lifecycle event in hooks.disabled: %s — ignored\n' \
        "$(_cfg_local_path "${dir}")" "${name}" >&2
    done <<< "${unknown}"
  fi

  jq -c --argjson e "${events}" \
    '((.hooks.disabled // []) | if type == "array" then . else [] end)
     | map(select(. as $x | $e | index($x) != null)) | unique' <<< "${json}" 2> /dev/null \
    || printf '[]'
}

# _cfg_hooks_disabled_set <config_dir> <dry_run> <new-set-json> — persist the
# record, preserving every other key the operator owns (site_alias, overrides)
# and every machine-owned key (resolved_ids). Writes through the canonical
# serialiser, so a re-run producing the same set writes byte-identical bytes.
_cfg_hooks_disabled_set() {
  local dir="$1" dry="$2" newset="$3" f json merged yaml rc=0
  f="$(_cfg_local_path "${dir}")"
  # An unreadable binding must never be silently REPLACED by a fresh one built
  # from an empty seed — that would discard whatever the operator's file held
  # that this reader could not parse (Constitution III: fail-closed on writes).
  json="$(_cfg_local_json "${dir}")" || rc=$?
  ((rc != 0)) && return "${rc}"
  merged="$(jq -cS --argjson d "${newset}" '
    . as $root
    | .hooks = (($root.hooks // {}) + {disabled: $d})
    | if (.hooks.disabled | length) == 0 then (.hooks |= del(.disabled)) else . end
    | if (.hooks | length) == 0 then del(.hooks) else . end' <<< "${json}")"
  [[ "${dry}" == "true" ]] && return 0
  yaml="$(printf '%s' "${merged}" | config_to_yaml)"
  mkdir -p "${dir}"
  printf '%s\n' "${yaml}" > "${f}"
}

# config_hooks_disabled_add <event> [config_dir] [dry_run] — record the operator's
# decision to disable one event. Prints `recorded`, `unchanged`, or `ignored`
# (an unknown name). Under dry-run the status is computed and nothing is written
# (Constitution XI). Never fails the run.
config_hooks_disabled_add() {
  local event="$1" dir="${2:-${JIRA_CONFIG_DIR}}" dry="${3:-false}"
  if ! jq -e --arg x "${event}" --argjson e "$(_cfg_hook_events_json)" \
    '$e | index($x) != null' <<< '{}' > /dev/null 2>&1; then
    printf 'config: not a lifecycle event: %s — nothing recorded\n' "${event}" >&2
    printf 'ignored'
    return 0
  fi
  local current rc=0
  current="$(config_hooks_disabled_read "${dir}")" || rc=$?
  ((rc != 0)) && return "${rc}"
  if jq -e --arg x "${event}" 'index($x) != null' <<< "${current}" > /dev/null 2>&1; then
    printf 'unchanged'
    return 0
  fi
  _cfg_hooks_disabled_set "${dir}" "${dry}" \
    "$(jq -c --arg x "${event}" '. + [$x] | unique' <<< "${current}")" || return $?
  printf 'recorded'
}

# config_hooks_disabled_remove <event> [config_dir] [dry_run] — the operator's
# explicit release (FR-029: removable only by an explicit operator action).
# Prints `released` or `unrecorded`. Under dry-run the status is computed and
# nothing is written (Constitution XI).
config_hooks_disabled_remove() {
  local event="$1" dir="${2:-${JIRA_CONFIG_DIR}}" dry="${3:-false}"
  local current rc=0
  current="$(config_hooks_disabled_read "${dir}")" || rc=$?
  ((rc != 0)) && return "${rc}"
  if ! jq -e --arg x "${event}" 'index($x) != null' <<< "${current}" > /dev/null 2>&1; then
    printf 'unrecorded'
    return 0
  fi
  _cfg_hooks_disabled_set "${dir}" "${dry}" \
    "$(jq -c --arg x "${event}" 'map(select(. != $x))' <<< "${current}")" || return $?
  printf 'released'
}

# =============================================================================
# Personal team selection (002 US3, FR-011/FR-012) — .specify/jira/personal.yml
# =============================================================================

# The personal-file schema as a declarative jq program (mirrors
# contracts/personal-config.schema.json): only `team` and an optional
# `override` (folder_prefix / branch_pattern, catalogue-entry rules).
# shellcheck disable=SC2016  # `\(...)` is jq string interpolation, not shell expansion
# kcov-excl-start — jq literal (string lines are not statements)
_CFG_PERSONAL_ERRORS_JQ='
def branchpattern:
  (type == "string")
  and (([match("<ID>"; "g")] | length) == 1)
  and (([match("<FEATURE_NAME>"; "g")] | length) == 1)
  and ((gsub("<ID>"; "") | gsub("<FEATURE_NAME>"; "")) | test("^[a-z0-9/_-]*$"));
[
  (keys_unsorted[] | select(IN("team","override")|not) | "unknown personal key: \(.)"),
  (if ((.team // "") | test("^[a-z][a-z0-9]*$") | not) then "team is invalid" else empty end),
  (if has("override") then
     ( .override
       | ( (keys_unsorted[] | select(IN("folder_prefix","branch_pattern")|not)
            | "unknown override key: \(.)"),
           (if has("folder_prefix") and ((.folder_prefix // "") | test("^[a-z0-9][a-z0-9-]*-$") | not)
            then "override.folder_prefix is invalid" else empty end),
           (if has("branch_pattern") and ((.branch_pattern // "") | branchpattern | not)
            then "override.branch_pattern is invalid" else empty end) ) )
   else empty end)
] | flatten | .[]'
# kcov-excl-stop

# config_personal_load [config_dir] [merged-config-json] — load the human-owned
# personal team selection. NEVER writes the file. Absent file => the inactive
# result {active:false} (FR-011: never required). Credential-shaped values are
# refused without echoing; an unknown `team` produces a located error listing
# the valid catalogue ids; `override` passes the catalogue-entry validation.
# Prints the canonical {active, team, override} JSON on stdout.
config_personal_load() {
  # The optional [merged-config-json] defaults to valid JSON ({}) — a literal
  # backslash default would make every jq read below spray parse errors.
  local dir="${1:-${JIRA_CONFIG_DIR}}" cfg="${2:-}"
  [[ -z "${cfg}" ]] && cfg='{}'
  local pf="${dir}/personal.yml"
  if [[ ! -f "${pf}" ]]; then
    printf '{"active":false}'
    return 0
  fi

  local pjson
  if ! pjson="$(config_yaml_to_json "${pf}")"; then
    return "${EXIT_CONFIG}"
  fi
  printf '%s' "${pjson}" | _cfg_credential_errors | _cfg_report_errors "credential" "${pf}" || return "${EXIT_CONFIG}"
  printf '%s' "${pjson}" | jq -r "${_CFG_PERSONAL_ERRORS_JQ}" 2> /dev/null \
    | _cfg_report_errors "personal" "${pf}" || return "${EXIT_CONFIG}"

  # The selected team must exist in the committed catalogue (FR-011).
  local team ids
  team="$(jq -r '.team // ""' <<< "${pjson}")"
  if ! jq -e --arg t "${team}" '([.teams[]?.id] | index($t)) != null' <<< "${cfg}" > /dev/null; then
    ids="$(jq -r '[.teams[]?.id] | join(", ")' <<< "${cfg}")"
    [[ -z "${ids}" ]] && ids="(none)"
    printf 'config: personal (%s): unknown team "%s" — valid teams: %s\n' \
      "${pf}" "${team}" "${ids}" >&2
    return "${EXIT_CONFIG}"
  fi

  jq -cn --arg t "${team}" \
    --argjson o "$(jq -c '.override // null' <<< "${pjson}")" \
    '{active: true, team: $t, override: $o}' | json_canonical
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
