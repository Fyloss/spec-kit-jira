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

# Captured BEFORE the `:=` default two lines down mutates JIRA_CONFIG_DIR —
# the one place this library can still tell "the caller set this" apart from
# "nobody did, so here is a relative fallback every reader assumes" (031,
# C1.1). config_resolve_dir needs this precisely because the VALUE alone is
# ambiguous once that default has run: an operator's environment setting
# JIRA_CONFIG_DIR before this process even starts is indistinguishable, by
# value, from the sentinel this line is about to assign.
: "${_JIRA_CONFIG_DIR_EXPLICIT:=$([[ -n "${JIRA_CONFIG_DIR:-}" ]] && echo true || echo false)}"
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
# inside quotes. Sets _CFG_STRIPPED.
#
# 024, FR-018/FR-041, research R8: this is called once per retained configuration
# line, so it MUST NOT be invoked through `$( … )` — a command substitution
# around a shell function forks a subshell, and on a production-sized
# config.local.yml (8 658 lines) the parser's six such call sites cost 26 000-
# 35 000 forks and ~25 s of its 31 s. It returns through a global for the same
# reason `_cfg_map_entry_key` sets `_CFG_KEY`/`_CFG_REST` and `_cfg_parse_value`
# sets `_CFG_RET`.
_CFG_STRIPPED=""
_cfg_strip_inline_comment() {
  local line="$1"
  # Fast path (024, T061): no `#` at all means nothing to strip — skip the
  # quote-tracking scan entirely and just rtrim, the same way the slow
  # path's own last step does (with no `#`, that loop copies every
  # character through unchanged, so the two are equivalent).
  if [[ "${line}" != *'#'* ]]; then
    _CFG_STRIPPED="${line%"${line##*[![:space:]]}"}"
    return 0
  fi
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
  _CFG_STRIPPED="${out}"
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
    _cfg_strip_inline_comment "${body}"; body="${_CFG_STRIPPED}"
    [[ -z "${body}" ]] && continue
    _cfg_indents+=("${indent}")
    _cfg_lines+=("${body}")
    _cfg_linenos+=("${lineno}")
    _cfg_n=$((_cfg_n + 1))
  done < "${file}"
}

# _cfg_json_encode <text> — JSON-string-encode TEXT exactly as `jq -Rn --arg v
# … '$v'` would, quotes included: " \ and the named control escapes, \u00XX
# for other C0 controls, raw UTF-8 otherwise (non-ASCII is never \u-escaped).
# No subprocess (024, contracts/spawn-budget.md C1.2) — the YAML parser calls
# this once per key and once per string scalar, so a config file of N lines
# used to cost up to 2N `jq` spawns (~6 ms/line unmanaged hardware, per
# research); this is the same escaper as engine/markdown.sh's
# `_md_json_escape`, duplicated rather than sourced across the lib->engine
# layer boundary this module's own header declares ("Port infrastructure
# only").
#
# 024, FR-018/FR-041, research R8: sets _CFG_JSON rather than printing. Removing
# the `jq` spawn was only half the cost — capturing this function's stdout with
# `$( … )` forked a subshell per key and per scalar, which on a production-sized
# configuration was the larger half. It MUST NOT be called through `$( … )`.
_CFG_JSON=""
_cfg_json_encode() {
  local s="$1"
  # Fast path (024, T061): most config string values (project keys, labels,
  # ids) contain none of the six named escapes or a control character, so
  # skip the per-character loop below entirely for them — one pattern match
  # instead of up to N character comparisons. `[[:cntrl:]]` covers every
  # byte the slow path treats specially (\n \r \t \b \f are all < 0x20);
  # NUL cannot occur in a bash string at all, so it needs no separate check.
  # shellcheck disable=SC1003 # a literal backslash glob character, not an escape mistake
  if [[ "${s}" != *'"'* && "${s}" != *'\'* && ! "${s}" =~ [[:cntrl:]] ]]; then
    _CFG_JSON="\"${s}\""
    return 0
  fi
  local out="" c code i n
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    case "${c}" in
      '"') out+='\"' ;;
      $'\\') out+=$'\\\\' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      *)
        printf -v code '%d' "'${c}"
        if ((code < 32)); then
          printf -v c '\\u%04x' "${code}"
          out+="${c}"
        else
          out+="${c}"
        fi
        ;;
    esac
  done
  _CFG_JSON="\"${out}\""
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

# _cfg_decode_escapes <body> — undo the writer's escaping (contracts/
# yaml-string-escaping.md §2.1): a left-to-right walk where `\"` becomes `"`
# and `\\` becomes `\`; any other backslash, including one at the end of the
# body, is kept literal (FR-012) rather than treated as a parse failure.
# Sets _CFG_DECODED rather than printing (024, FR-018/FR-041 — see
# _cfg_strip_inline_comment): it is called once per quoted key and once per
# quoted scalar, so a `$( … )` here is a fork per value.
_CFG_DECODED=""
_cfg_decode_escapes() {
  local s="$1"
  [[ "${s}" != *"\\"* ]] && { _CFG_DECODED="${s}"; return; }
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
  _CFG_DECODED="${out}"
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
    if [[ "${q}" == '"' ]]; then _cfg_decode_escapes "${key}"; key="${_CFG_DECODED}"; fi
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

# _cfg_scalar_json <raw> — encode a YAML scalar as a JSON value into
# _CFG_SCALAR. Called once per mapping value and once per sequence item, so it
# MUST NOT be invoked through `$( … )` (024, FR-018/FR-041, research R8).
_CFG_SCALAR=""
_cfg_scalar_json() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  case "${s}" in
    '"'*'"')
      s="${s#\"}"; s="${s%\"}"
      _cfg_decode_escapes "${s}"; s="${_CFG_DECODED}"
      _cfg_json_encode "${s}"; _CFG_SCALAR="${_CFG_JSON}"
      ;;
    "'"*"'")
      s="${s#\'}"; s="${s%\'}"
      _cfg_json_encode "${s}"; _CFG_SCALAR="${_CFG_JSON}"
      ;;
    true) _CFG_SCALAR='true' ;;
    false) _CFG_SCALAR='false' ;;
    null | '~' | '') _CFG_SCALAR='null' ;;
    # The two EMPTY flow forms, and only those. They are in the subset because
    # config_to_yaml emits exactly them for an empty collection, and the writer
    # is documented above as a fixed point of this reader — without these, a
    # file this module wrote reads back with the strings "[]" and "{}" where it
    # wrote collections. Non-empty flow collections stay out of scope.
    '[]') _CFG_SCALAR='[]' ;;
    '{}') _CFG_SCALAR='{}' ;;
    *) _cfg_json_encode "${s}"; _CFG_SCALAR="${_CFG_JSON}" ;;
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
      _cfg_scalar_json "${rest}"; val="${_CFG_SCALAR}"
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
      #       - extension: jira-mirror        <- same indent as the key
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
    _cfg_json_encode "${key}"
    parts+=("${_CFG_JSON}":"${val}")
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
      _cfg_scalar_json "${rest}"; item="${_CFG_SCALAR}"
    fi
    items+=("${item}")
  done
  local IFS=,
  _CFG_RET="[${items[*]}]"
}

# _CFG_YAML_CACHE_DIR — subshell-proof, process-scoped cache of parsed
# config sources (024, T057/T059, FR-009/FR-038/FR-040). `config_yaml_to_json`
# is read through `$( … )` at every call site (`config_load`, `_cfg_local_json`,
# the personal-config reader), so an in-shell-variable cache set inside one of
# those subshells is discarded when it exits — the same defect research R2
# found for the request counter. A directory on disk is not: one file per
# source path holds its last-parsed canonical JSON, and a second file logs
# every path actually opened-and-parsed (never a cache HIT), which is what
# `config_yaml_parse_count` (T059's counting stand-in) reads back. Unprimed
# (`config_yaml_cache_prime` never called), every call is a fresh parse — the
# pre-024 behaviour — so a caller that never primes it is unaffected.
: "${_CFG_YAML_CACHE_DIR:=}"

# config_yaml_cache_prime — start a FRESH cache for one run, in the MAIN
# shell (research R2/R3, the same discipline as cred_prime_cache and
# jira_request_count_prime): call this once at the start of a run, never
# from inside a `$( … )` subshell, or the path itself is lost when that
# subshell exits and every later call re-primes into a directory nothing
# else can see. Deliberately NOT guarded to prime only once per process
# (unlike jira_request_count_prime): `reconcile.sh` calls this exactly once
# per logical run, but a caller that invokes `cmd_reconcile` more than once
# in the SAME process — every test in this suite does, and nothing rules it
# out for a real embedder — must not have the second call silently reuse the
# first run's cache, which would serve stale content for any source a
# THIRD-PARTY write (a test's own fixture edit; a real operator editing the
# file between two logical runs) changed on disk in between (FR-013's spirit,
# generalised beyond this run's own writes).
config_yaml_cache_prime() {
  _CFG_YAML_CACHE_DIR="$(mktemp -d)" || _CFG_YAML_CACHE_DIR=""
}

# _cfg_yaml_cache_key <file> — a filename-safe key for the cache/log below.
# The literal argument string, not a resolved realpath: every call site in
# this codebase builds the path from the same `dir` variable consistently
# within one run, so the string itself is already a stable key, and resolving
# a realpath would cost a fork this cache exists to avoid paying.
_cfg_yaml_cache_key() {
  local k="$1"
  printf '%s' "${k//\//_}"
}

# config_yaml_cache_invalidate <file> — drop a cached parse (FR-013). The
# only writer of a config source, `_cfg_hooks_disabled_set`, calls this right
# after writing, so a later read in the same process — if that process ever
# primes the cache, which today only `reconcile.sh` does — is never served a
# pre-write answer instead of a fresh parse.
config_yaml_cache_invalidate() {
  [[ -z "${_CFG_YAML_CACHE_DIR}" ]] && return 0
  rm -f "${_CFG_YAML_CACHE_DIR}/$(_cfg_yaml_cache_key "$1")" 2> /dev/null
  return 0
}

# config_yaml_parse_count <file> — how many times config_yaml_to_json has
# actually opened and parsed this path from disk so far (a cache HIT does not
# count). Test-only seam for T033/FR-038/FR-040. 0 when priming never
# happened or the path was never read.
config_yaml_parse_count() {
  local log="${_CFG_YAML_CACHE_DIR}/.parse.log" n
  [[ -f "${log}" ]] || { printf '0'; return 0; }
  n="$(grep -Fxc -- "$1" "${log}" 2> /dev/null)"
  printf '%s' "${n:-0}"
}

# config_yaml_to_json <file> — parse the YAML subset and print canonical
# JSON. Memoised per absolute-path-string within a run when the cache above
# has been primed (T057): a source asked for twice in the same process is
# opened and parsed once, the second caller served the first caller's
# canonical output. FR-012's diagnostic parity is unaffected — only a
# SUCCESSFUL parse is cached, so a still-malformed source keeps failing (and
# reporting) on every call, exactly as before this cache existed.
#
# Containment (FR-014, Constitution IV, NFR-3): a credential-shaped value is
# never written to the cache file, even on an otherwise-successful parse.
# Before this cache existed, config_yaml_to_json's output only ever lived in
# a shell variable — never on disk — and `config_load`'s OWN credential scan
# (which runs on the caller's side, after this function returns) is what
# refuses it. Caching unconditionally would put that value on disk in the
# window between this function returning and the caller's scan running,
# which is new exposure this feature must not introduce. `_cfg_credential_errors`
# is therefore run here too, cache-side only — it does not change what this
# function returns or its exit code, only whether the disk copy is made.
config_yaml_to_json() {
  local file="$1" json cachefile=""
  [[ -f "${file}" ]] || { printf 'config: file not found: %s\n' "${file}" >&2; return 1; }
  if [[ -n "${_CFG_YAML_CACHE_DIR}" ]]; then
    cachefile="${_CFG_YAML_CACHE_DIR}/$(_cfg_yaml_cache_key "${file}")"
    if [[ -f "${cachefile}" ]]; then
      local cached=""
      IFS= read -r -d '' cached < "${cachefile}" 2> /dev/null
      printf '%s' "${cached}"
      return 0
    fi
    printf '%s\n' "${file}" >> "${_CFG_YAML_CACHE_DIR}/.parse.log" 2> /dev/null
  fi
  _cfg_prep "${file}"
  _cfg_parse_value
  if [[ -n "${_CFG_ERR}" ]]; then
    printf '%s\n' "${_CFG_ERR}" >&2
    return "${EXIT_CONFIG}"
  fi
  json="${_CFG_RET}"
  # Canonicalise (and prove well-formed). A malformed subset surfaces here.
  local canon
  canon="$(printf '%s' "${json}" | jq -cS . 2> /dev/null)" || {
    printf 'config: %s is not valid config YAML\n' "${file}" >&2
    return 1
  }
  if [[ -n "${cachefile}" ]] && [[ -z "$(printf '%s' "${canon}" | _cfg_credential_errors)" ]]; then
    printf '%s' "${canon}" > "${cachefile}" 2> /dev/null
  fi
  printf '%s' "${canon}"
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
# Refuses (EXIT_CONFIG) a key or string value containing a line break, printing
# a named error per offending path and nothing else — no partial YAML is ever
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

# _cfg_credential_errors [exempt-path ...] — read a JSON object on stdin; print
# one error line per credential-shaped string value found. `privacy` stays
# exempt unconditionally, on every surface (excluding privacy.allowlist,
# FR-053). Each additional argument names one more top-level key this
# particular surface legitimately holds a credential-shaped value at — the
# base-url key of config.yml, the email key of personal.yml (030, data-model.md
# §4, research R4). The token shape (`^ATATT`) is never affected by this list —
# only the extension is parameterized, the mechanism (`select`) is not (FR-020).
_cfg_credential_errors() {
  local exempt_json
  exempt_json="$(printf '%s\n' "$@" | jq -R . | jq -cs .)"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -r --argjson ex "${exempt_json}" '
    def disppath:
      reduce .[] as $p (""; . + (if ($p|type)=="number" then "[\($p)]"
                                 elif . == "" then $p else "." + $p end));
    def exempt: ((.[0] // "") as $k | ($k == "privacy") or (($ex | index($k)) != null));
    [ paths(scalars) as $p
      | { path: ($p|disppath), v: (getpath($p)|tostring), exempt: ($p|exempt) }
      | ( if (.v|test("^ATATT")) then "\(.path): Atlassian API token"
          elif .exempt then empty
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
  (keys_unsorted[] | select(IN("version_compat","projects","routing","routing_default","privacy","teams","field_defaults","task_mirror","base_url")|not)
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
  (if (has("task_mirror")) and ((.task_mirror|type) != "object") then
    "task_mirror must be a mapping"
   else empty end),
  ( . as $top
    | ($top.projects // []) | map(.key) as $declaredKeys
    | (select(($top.task_mirror // {})|type == "object") | $top.task_mirror // {}) | to_entries[] as $tm
    | ($tm.key) as $tmk | ($tm.value) as $tmv
    | (
        (if ($declaredKeys | index($tmk)) == null then
          "task_mirror.\($tmk) names a project key that is not declared in projects[]"
        else empty end),
        (if ($tmv|IN("subtask","checklist")|not) then
          "task_mirror.\($tmk) is '\''\($tmv)'\'' — accepted values are: subtask, checklist (answer with --task-mirror '\''\($tmk)=checklist'\'')"
        else empty end)
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
        (if ($p | has("phase_status_map")) then
           ($p.phase_status_map) as $psm
           | (if ($psm|type) != "object" then
               "projects[\($i)].phase_status_map must be a mapping of lifecycle-event name to status name, or of hierarchy role to that role'\''s own mapping"
             else
               ($psm | keys_unsorted) as $ks
               | ($ks | all(. as $k | $events | index($k) != null)) as $all_events
               | ($ks | all(. as $k | $roles | index($k) != null)) as $all_roles
               | if ($ks | length) == 0 then empty
                 elif $all_events then
                   ( $psm | to_entries[] | select((.value|type) != "string" or .value == "")
                     | "projects[\($i)].phase_status_map.\(.key) must be a non-empty status name" )
                 elif $all_roles then
                   ( $psm | to_entries[] as $re
                     | ($re.key) as $role | ($re.value) as $rv
                     | ( (if ($rv|type) != "object" then
                            "projects[\($i)].phase_status_map.\($role) must be a mapping of lifecycle-event name to status name"
                          else empty end),
                         (select($rv|type == "object") | $rv | keys_unsorted[] | select(IN($events[])|not)
                           | "projects[\($i)].phase_status_map.\($role) declares unknown lifecycle event `\(.)`"),
                         (select($rv|type == "object") | $rv | to_entries[] | select((.value|type) != "string" or .value == "")
                           | "projects[\($i)].phase_status_map.\($role).\(.key) must be a non-empty status name")
                       ) )
                 elif ($ks | any(. as $k | ($events | index($k) != null) or ($roles | index($k) != null))) then
                   "projects[\($i)].phase_status_map mixes lifecycle events and hierarchy roles; declare either one mapping for the story role, or one mapping per role (specification, story, task)"
                 else
                   ( $ks[] | "projects[\($i)].phase_status_map declares unknown key `\(.)`; the lifecycle events are after_specify, after_clarify, after_plan, after_tasks, after_implement, after_analyze and the roles are specification, story, task" )
                 end
             end)
         else empty end),
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

# _CFG_CONFIG_ERRORS_JQ (030, data-model.md §2/§2a, contracts/connection-
# settings.md §2) — base_url validation, reported under its OWN "config" label
# rather than "schema": an absolute URL with a host and nothing else (no
# trailing slash, path, query or fragment); scheme https anywhere, or http ONLY
# at one of the three loopback literals (research R10) — never a hostname that
# merely resolves to one, so the check stays a pure string function with no DNS
# lookup. Absent key is accepted (the environment may supply it instead,
# C2.7); present-and-empty is refused (an empty declaration is a mistake, not
# an opt-out).
# shellcheck disable=SC2016  # `\(...)` is jq string interpolation, not shell expansion
# kcov-excl-start — jq literal (string lines are not statements)
_CFG_CONFIG_ERRORS_JQ='
def https_url: test("^https://[^/?#]+$");
def loopback_http: test("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:[0-9]+)?$");
[
  (if has("base_url") then
     (.base_url) as $u
     | (if ($u == "") then "base_url is invalid"
        elif ($u | https_url) then empty
        elif ($u | loopback_http) then empty
        else "base_url is invalid" end)
   else empty end)
] | flatten | .[]'
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
# `$roles` is the closed role set (JIRA_ROLE_NAMES) and `$events` the closed
# lifecycle-event set (JIRA_HOOK_EVENT_NAMES, minus before_specify — 023,
# contract role-lifecycle-config.md §2 accepts only the six after-events),
# bound once here so neither jq program below repeats the literal.
_cfg_schema_errors() {
  jq -r --argjson roles "$(_cfg_role_names_json)" --argjson events "$(_cfg_after_event_names_json)" "${1} | .[]" 2> /dev/null
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

# _cfg_after_event_names_json — the six after-events only (JIRA_HOOK_EVENT_NAMES
# minus before_specify), the closed key set a role's lifecycle mapping accepts
# (023, contracts/lifecycle-event.md §1, contracts/role-lifecycle-config.md §2).
_cfg_after_event_names_json() {
  printf '%s\n' "${JIRA_HOOK_EVENT_NAMES[@]:1}" | jq -cR . | jq -cs .
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

# config_task_mirror_for <project_key> <merged-cfg-json> — one project's
# `task_mirror` value (022, data-model.md §1): `subtask`, `checklist`, or the
# empty string when the team has recorded nothing for this project. Absence
# is a third state, not a default (contract §1) — the caller, not this
# function, resolves the empty string into effective behaviour (contract
# §7). Mirrors config_field_defaults_for in name, placement and return
# discipline.
config_task_mirror_for() {
  local key="$1" cfg="$2"
  jq -r --arg k "${key}" '(.task_mirror // {})[$k] // ""' <<< "${cfg}"
}

# config_task_mirror_yaml <task-mirror-map-json> — the canonical YAML text of
# the whole top-level `task_mirror:` mapping (022, contract §3), keys sorted
# so a re-run over unchanged input reproduces identical bytes. Mirrors
# config_field_defaults_yaml in name, placement and return discipline.
config_task_mirror_yaml() {
  local map="${1:-}"
  [[ -z "${map}" ]] && map='{}'
  jq -cn --argjson m "${map}" '{task_mirror: $m}' | config_to_yaml
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
  # FR-013: a later read in THIS process must see the write just made, not a
  # pre-write cache entry. No-op unless a caller has primed the cache above —
  # today only `reconcile.sh` does, and `reconcile.sh` never reaches this
  # function, so this is dormant until something changes that.
  config_yaml_cache_invalidate "${f}"
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
  (keys_unsorted[] | select(IN("team","override","email")|not) | "unknown personal key: \(.)"),
  (if has("team") then
     (if ((.team // "") | test("^[a-z][a-z0-9]*$") | not) then "team is invalid" else empty end)
   else empty end),
  (if has("email") then
     (if ((.email // "") | test("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$") | not)
      then "email is invalid" else empty end)
   else empty end),
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

# config_personal_load [config_dir] [merged-config-json] [soft_load] — load
# the human-owned personal team selection. NEVER writes the file. Absent
# file => the inactive result {active:false} (FR-011: never required).
# Credential-shaped values are refused without echoing; an unknown `team`
# produces a located error listing the valid catalogue ids; `override`
# passes the catalogue-entry validation. Prints the canonical {active, team,
# override} JSON on stdout. The three inactive branches also carry a `state`
# field (data-model.md §1: `no-personal-file` / `no-team-key` /
# `personal-unloadable`) — internal vocabulary for callers that want to name
# the resolution state (031, FR-010); every existing reader extracts only
# the fields it already knew about and ignores the rest.
#
# [soft_load] (031, FR-013 vs FR-017 — research D3 and the C6.2a amendment
# both narrow non-blocking treatment to a file that CANNOT BE LOADED at all:
# a parse failure, a credential-shaped value, or a schema violation. Set to
# "true" ONLY by the `feature` command's naming path, it turns exactly THOSE
# three failures into {"active":false,"state":"personal-unloadable"} (exit 0,
# reported via the same stderr lines this function already prints) instead
# of EXIT_CONFIG. The catalogue-membership check below is NEVER softened —
# it is not a load failure, it is a well-formed file naming something that
# does not exist, and FR-017 requires that this "behaviour is unchanged":
# a located error, exit 4, whether or not the catalogue itself is empty.
config_personal_load() {
  # The optional [merged-config-json] defaults to valid JSON ({}) — a literal
  # backslash default would make every jq read below spray parse errors.
  local dir="${1:-${JIRA_CONFIG_DIR}}" cfg="${2:-}" soft_load="${3:-false}"
  [[ -z "${cfg}" ]] && cfg='{}'
  local pf="${dir}/personal.yml"
  if [[ ! -f "${pf}" ]]; then
    printf '{"active":false,"state":"no-personal-file"}'
    return 0
  fi

  local pjson
  if ! pjson="$(config_yaml_to_json "${pf}")"; then
    [[ "${soft_load}" == "true" ]] && { printf '{"active":false,"state":"personal-unloadable"}'; return 0; }
    return "${EXIT_CONFIG}"
  fi
  # See the identical guard in config_load — an empty personal.yml is a
  # normal state (the ceremony writes only comments and a `# team:` line
  # left commented, and an operator may blank it further).
  [[ "${pjson}" == "null" ]] && pjson="{}"
  if ! printf '%s' "${pjson}" | _cfg_credential_errors "email" | _cfg_report_errors "credential" "${pf}"; then
    [[ "${soft_load}" == "true" ]] && { printf '{"active":false,"state":"personal-unloadable"}'; return 0; }
    return "${EXIT_CONFIG}"
  fi
  if ! printf '%s' "${pjson}" | jq -r "${_CFG_PERSONAL_ERRORS_JQ}" 2> /dev/null | _cfg_report_errors "personal" "${pf}"; then
    [[ "${soft_load}" == "true" ]] && { printf '{"active":false,"state":"personal-unloadable"}'; return 0; }
    return "${EXIT_CONFIG}"
  fi

  # An absent `team` key is "no team selected" — identical to an absent file
  # (030, FR-027, contracts/connection-settings.md C4.1/C4.4). The catalogue-
  # membership check below is skipped entirely in this state, or a repository
  # whose catalogue declares no teams would fail the moment personal.yml
  # exists — exactly the file the config ceremony now creates by default.
  if [[ "$(jq -r 'has("team")' <<< "${pjson}")" != "true" ]]; then
    printf '{"active":false,"state":"no-team-key"}'
    return 0
  fi

  # The selected team must exist in the committed catalogue (FR-011,
  # FR-017 — NEVER gated on [soft_load], see the function header).
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

# _cfg_absolutize <path> — spell <path> absolute against the working
# directory, without ever routing it through `cd` (the target need not
# exist — FR-008's whole point is a directory that may not).
_cfg_absolutize() {
  # pwd -P, not pwd: the physical, symlink-resolved cwd. Bash's own logical
  # $PWD (what plain `pwd` reports after a `cd`) survives inside the SAME
  # process, but a freshly spawned process — the PowerShell port, spawned as
  # its own process by the conformance harness after the SAME `cd` — reports
  # its OS-level cwd via getcwd(), which is always the physical path. On
  # macOS /var is itself a symlink to /private/var, so `mktemp -d` output
  # spelled through plain `pwd` and through a fresh process's cwd disagree —
  # -P is what keeps this port's spelling identical to the other one's
  # (C5.1), not merely absolute.
  local combined
  case "$1" in
    /*) combined="$1" ;;
    *) combined="$(pwd -P)/$1" ;;
  esac
  _cfg_normalize_path "${combined}"
}

# _cfg_normalize_path <absolute-path> — collapse "." and ".." segments
# LEXICALLY, never touching the filesystem — the same normalisation
# [System.IO.Path]::GetFullPath applies on the PowerShell port for the SAME
# explicit-override inputs (JIRA_CONFIG_DIR / SPECIFY_INIT_DIR). Without
# this, a caller supplying "foo/../.specify/jira" spells two different
# strings on the two ports for the identical logical location — pure string
# concatenation preserves the literal "foo/..", GetFullPath collapses it —
# breaking FR-009/C5.1's byte-identical-path requirement (031, code review).
# Bash 3.2-compatible: no negative array indices.
_cfg_normalize_path() {
  local input="${1#/}" part
  local -a segments=() out=()
  local IFS='/'
  # shellcheck disable=SC2206
  segments=(${input})
  for part in "${segments[@]}"; do
    case "${part}" in
      '' | '.') continue ;;
      '..')
        if [[ ${#out[@]} -gt 0 ]]; then
          unset "out[$((${#out[@]} - 1))]"
          out=("${out[@]}")
        fi
        ;;
      *) out+=("${part}") ;;
    esac
  done
  local result="" seg
  for seg in "${out[@]}"; do
    result="${result}/${seg}"
  done
  printf '%s' "${result:-/}"
}

# config_resolve_dir — the configuration directory, in the FR-007/FR-014
# priority order (contract C1.1): an explicitly set JIRA_CONFIG_DIR; else
# SPECIFY_INIT_DIR + /.specify/jira; else the nearest ancestor of the working
# directory that carries a .specify/ directory, plus /jira (C1.2: upward
# only, stopping at the filesystem root — never a git invocation, research
# D1). Prints the resolved directory, always absolute (FR-009), and returns
# 0. Returns 1 and prints nothing when neither override is set and no
# ancestor carries .specify/ (FR-008) — the caller reports that, it is never
# silently swallowed here.
#
# "${JIRA_CONFIG_DIR}" here is compared against the literal string this same
# library defaults it to at source time (line ~24, `: "${JIRA_CONFIG_DIR:=.
# specify/jira}"`, shared by every command, not just `feature`) — that
# default IS the relative fallback FR-014 exists to replace, so it is the
# one value this function treats as "nothing was explicitly chosen" rather
# than as an override.
config_resolve_dir() {
  # Explicit wins on EITHER signal: the marker captured before this library's
  # own default ran (an operator's environment, set before this process even
  # started — code review), OR a value that plainly differs from the
  # sentinel (the common case: a test or caller exporting a real path AFTER
  # sourcing). Only "re-exported to the exact literal default string, after
  # sourcing" stays ambiguous — a degenerate input no real caller has reason
  # to construct, since it asks for exactly the behaviour that would apply
  # anyway had it never been set.
  if [[ "${_JIRA_CONFIG_DIR_EXPLICIT}" == "true" ]] \
    || [[ -n "${JIRA_CONFIG_DIR:-}" && "${JIRA_CONFIG_DIR}" != '.specify/jira' ]]; then
    _cfg_absolutize "${JIRA_CONFIG_DIR}"
    return 0
  fi
  if [[ -n "${SPECIFY_INIT_DIR:-}" ]]; then
    printf '%s/.specify/jira' "$(_cfg_absolutize "${SPECIFY_INIT_DIR}")"
    return 0
  fi
  local d
  d="$(pwd -P)"
  while :; do
    if [[ -d "${d}/.specify" ]]; then
      printf '%s/.specify/jira' "${d}"
      return 0
    fi
    [[ "${d}" == "/" ]] && break
    d="$(dirname "${d}")"
  done
  return 1
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
  # An empty file parses to jq `null` (YAML's own "empty document" reading) —
  # coerced to `{}` here so every jq program below can assume an object
  # without each one repeating a `(. // {})` guard. Without this, `keys_unsorted`
  # and `has(...)` throw on a null top level, a jq crash (exit 5) that
  # `pipefail` turns into a silent EXIT_CONFIG with no message at all.
  [[ "${team_json}" == "null" ]] && team_json="{}"

  printf '%s' "${team_json}" | _cfg_credential_errors "base_url" | _cfg_report_errors "credential" "${team}" || return "${EXIT_CONFIG}"
  printf '%s' "${team_json}" | _cfg_schema_errors "${_CFG_TEAM_ERRORS_JQ}" | _cfg_report_errors "schema" "${team}" || return "${EXIT_CONFIG}"
  printf '%s' "${team_json}" | jq -r "${_CFG_CONFIG_ERRORS_JQ}" 2> /dev/null \
    | _cfg_report_errors "config" "${team}" || return "${EXIT_CONFIG}"

  local merged="${team_json}"
  if [[ -f "${local_f}" ]]; then
    local local_json
    local_json="$(config_yaml_to_json "${local_f}")" || return "${EXIT_CONFIG}"
    # See the identical guard on team_json above — an empty config.local.yml
    # is a normal, common state (nothing has been resolved locally yet).
    [[ "${local_json}" == "null" ]] && local_json="{}"
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

# =============================================================================
# The resolution chokepoint (030, plan.md §Key design decision,
# contracts/connection-settings.md §1)
# =============================================================================

# config_resolve_connection [config_dir] [merged-cfg-json] — seed
# SPEC_KIT_JIRA_BASE_URL and JIRA_EMAIL into the PROCESS ENVIRONMENT from
# config.yml / personal.yml, ONLY when the variable is unset or EMPTY — the
# empty string counts as unset (the conformance harness relies on this idiom
# exactly, C1.4). Call once per run, after config_load, before any Jira call
# (C1.1). Never overwrites a non-empty value (C1.2/C1.3): environment-first
# precedence falls out of the assignment itself rather than a rule every one
# of the 72 existing readers must honour (research R1).
#
# [merged-cfg-json], when supplied, is used AS-IS for base_url — no second
# config_load. feature.sh already loads and handles config.yml's own errors
# (a malformed file is a pass-through there, not a hard failure); re-validating
# it here would silently contradict that. Omitted, config.yml is loaded here
# IF PRESENT; an ABSENT file is tolerated (US4: env-only, unattended, no
# config files at all) — only a PRESENT and malformed one fails closed
# (EXIT_CONFIG), because a file on disk that cannot be read correctly is a
# fail-closed condition, not a value silently outranked (C6.2).
#
# [personal_json], when supplied (031), is the caller's OWN, ALREADY-computed
# config_personal_load result — used AS-IS to decide whether email-seeding
# applies, no second config_personal_load call. Only the `feature` command's
# naming path supplies this: it validates personal.yml itself, earlier, with
# [soft_load]=true (FR-013, C3.3) — a load failure there is a pass-through,
# never reaches this function at all, so by the time this call happens
# personal.yml is KNOWN to be either well-formed-and-inactive or well-formed-
# and-active; either way it needs no re-validation, only its `email` field
# (which config_personal_load's return object never carries). A catalogue-
# membership failure (FR-017) is NOT swallowable this way — it is checked by
# the caller BEFORE this function is ever reached, so it always fails closed
# there, unconditionally (contract C3.4: every OTHER caller — seed/mention/
# reconcile/config, all of which reach the network — omits this argument and
# gets the full, unconditional config_personal_load validation below).
config_resolve_connection() {
  local dir="${1:-${JIRA_CONFIG_DIR}}" cfg="${2:-}" personal_json="${3:-}"
  if [[ -z "${cfg}" ]]; then
    cfg='{}'
    if [[ -f "${dir}/config.yml" ]]; then
      cfg="$(config_load "${dir}")" || return "${EXIT_CONFIG}"
    fi
  fi

  if [[ -z "${SPEC_KIT_JIRA_BASE_URL:-}" ]]; then
    local base_url
    base_url="$(jq -r '.base_url // ""' <<< "${cfg}")"
    [[ -n "${base_url}" ]] && export SPEC_KIT_JIRA_BASE_URL="${base_url}"
  fi

  # A present personal.yml is validated UNCONDITIONALLY (C6.2: "a malformed
  # setting refuses the run whether or not the environment would have
  # supplied a valid one") — never gated on whether JIRA_EMAIL happens to be
  # set already. Only the SEEDING of the variable is conditional.
  local pf="${dir}/personal.yml"
  if [[ -f "${pf}" ]]; then
    if [[ -z "${personal_json}" ]]; then
      # config_personal_load's return object never carries `email` — every
      # branch of it is pinned to data-model.md §3's five-state table, none of
      # which mentions the key. Call it anyway, for its validation side effect
      # (a malformed team or email fails closed here, EXIT_CONFIG), then read
      # the field straight from the parsed file.
      config_personal_load "${dir}" "${cfg}" > /dev/null || return $?
    elif [[ "$(jq -r '.state // ""' <<< "${personal_json}")" == "personal-unloadable" ]]; then
      # The caller already knows this file is broken and already reported it
      # (031). Nothing downstream on that pass-through path makes a Jira
      # request, so there is no email worth seeding from a file that cannot
      # be re-parsed anyway.
      return 0
    fi
    if [[ -z "${JIRA_EMAIL:-}" ]]; then
      local pjson email
      pjson="$(config_yaml_to_json "${pf}")" || return "${EXIT_CONFIG}"
      email="$(jq -r '.email // ""' <<< "${pjson}")"
      [[ -n "${email}" ]] && export JIRA_EMAIL="${email}"
    fi
  fi
  return 0
}
