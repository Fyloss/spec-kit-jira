#!/usr/bin/env bash
# sink/jira/designator.sh — Designator grammar, URL reduction, host
# comparison, order and de-duplication (027, research R2,
# contracts/designator-grammar.md).
#
# SINK module: owns the issue-key regex and the Atlassian host comparison,
# both of which Constitution VIII's boundary grep forbids in an engine
# script. Every function here is a pure function of its arguments — no
# network call is issued anywhere in this file.

[[ -n ${_JIRA_SINK_DESIGNATOR:-} ]] && return 0
_JIRA_SINK_DESIGNATOR=1

_designator_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_designator_dir}/../../lib/output.sh"

# _desig_trim <string> — strip leading and trailing whitespace, fork-free
# (docs/11-process-budget.md).
_desig_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# _desig_strip_cr <string> — trim exactly one trailing CR (research R11): a
# SINGLE-character suffix strip, never a `$'\r\n'` pair inside a glob.
_desig_strip_cr() {
  printf '%s' "${1%$'\r'}"
}

# designator_reduce_key <raw> — §2: the key grammar, applied after
# upper-casing. Prints the upper-cased key and returns 0 on a match; prints
# nothing and returns 1 otherwise.
designator_reduce_key() {
  local raw up
  raw="$(_desig_strip_cr "$1")"
  up="$(printf '%s' "${raw}" | tr '[:lower:]' '[:upper:]')"
  if [[ "${up}" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]]; then
    printf '%s' "${up}"
    return 0
  fi
  return 1
}

# _desig_percent_decode <string> — percent-decode, no external process per
# call (docs/11-process-budget.md).
_desig_percent_decode() {
  local s="$1" out="" i=0 len=${#1} c hex
  while ((i < len)); do
    c="${s:i:1}"
    if [[ "${c}" == "%" && $((i + 2)) -lt $((len + 1)) ]]; then
      hex="${s:i+1:2}"
      if [[ "${hex}" =~ ^[0-9A-Fa-f]{2}$ ]]; then
        out+="$(printf '%b' "\\x${hex}")"
        i=$((i + 3))
        continue
      fi
    fi
    out+="${c}"
    i=$((i + 1))
  done
  printf '%s' "${out}"
}

# designator_reduce_url_candidate <raw> — §3, rules 1-4: strip the fragment,
# then (2) a `selectedIssue` query parameter, else (3) the segment after
# `/browse/`, else (4) the final path segment. Prints the RAW (not yet
# upper-cased or grammar-validated) candidate and returns 0; returns 1 when
# no rule applies (rule 5: REF-DESIGNATOR, left to the caller).
designator_reduce_url_candidate() {
  local raw nofrag noquery query=""
  raw="$(_desig_strip_cr "$1")"
  nofrag="${raw%%#*}"
  if [[ "${nofrag}" == *"?"* ]]; then
    query="${nofrag#*\?}"
    noquery="${nofrag%%\?*}"
  else
    noquery="${nofrag}"
  fi

  if [[ -n "${query}" ]]; then
    local -a kv
    IFS='&' read -ra kv <<< "${query}"
    local pair sel=""
    for pair in "${kv[@]}"; do
      if [[ "${pair}" == selectedIssue=* ]]; then
        sel="${pair#selectedIssue=}"
      fi
    done
    if [[ -n "${sel}" ]]; then
      _desig_percent_decode "${sel}"
      return 0
    fi
  fi

  if [[ "${noquery}" == *"/browse/"* ]]; then
    local after seg
    after="${noquery#*/browse/}"
    seg="${after%%/*}"
    if [[ -n "${seg}" ]]; then
      printf '%s' "${seg}"
      return 0
    fi
  fi

  local last="${noquery##*/}"
  if [[ -n "${last}" ]] && designator_reduce_key "${last}" > /dev/null; then
    printf '%s' "${last}"
    return 0
  fi

  return 1
}

# _desig_url_parts <url> — prints "scheme host port" (space-separated; port
# empty when unspecified); returns 1 when <url> does not carry a scheme.
_desig_url_parts() {
  local url="$1"
  if [[ "${url}" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]+) ]]; then
    local scheme="${BASH_REMATCH[1],,}" hostport="${BASH_REMATCH[2]}" host port=""
    if [[ "${hostport}" == *:* ]]; then
      host="${hostport%%:*}"
      port="${hostport#*:}"
    else
      host="${hostport}"
    fi
    printf '%s %s %s' "${scheme}" "${host}" "${port}"
    return 0
  fi
  return 1
}

# designator_host_match <url> <base-url> — §4: compare scheme, host
# (case-insensitively, minus one trailing dot), and port (after the
# scheme's default). A path prefix on <base-url> is ignored. Returns 0 on a
# match.
designator_host_match() {
  local us bs
  us="$(_desig_url_parts "$1")" || return 1
  bs="$(_desig_url_parts "$2")" || return 1
  local u_scheme u_host u_port b_scheme b_host b_port
  read -r u_scheme u_host u_port <<< "${us}"
  read -r b_scheme b_host b_port <<< "${bs}"
  u_host="${u_host%.}"
  b_host="${b_host%.}"
  u_host="${u_host,,}"
  b_host="${b_host,,}"
  [[ "${u_scheme}" == "${b_scheme}" ]] || return 1
  [[ "${u_host}" == "${b_host}" ]] || return 1
  local default_port=""
  case "${u_scheme}" in
    https) default_port=443 ;;
    http) default_port=80 ;;
  esac
  [[ -z "${u_port}" ]] && u_port="${default_port}"
  [[ -z "${b_port}" ]] && b_port="${default_port}"
  [[ "${u_port}" == "${b_port}" ]]
}

# designator_classify <role> <raw> <base-url> — the single-designator
# resolver (§2-§5). <role> is "specification" or "story". Prints canonical
# JSON:
#   {"role":..,"raw":..,"form":"key","key":".."}
#   {"role":..,"raw":..,"form":"url","key":".."}
#   {"role":..,"raw":..,"form":"free_text","text":".."}   (specification only)
#   {"role":..,"raw":..,"refuse":"REF-DESIGNATOR"|"REF-HOST"}
designator_classify() {
  local role="$1" raw="$2" base="$3" key

  if key="$(designator_reduce_key "${raw}")"; then
    jq -cn --arg r "${role}" --arg raw "${raw}" --arg k "${key}" \
      '{role:$r, raw:$raw, form:"key", key:$k}' | json_canonical
    return 0
  fi

  if [[ "${raw}" == *"://"* ]]; then
    local candidate up
    if candidate="$(designator_reduce_url_candidate "${raw}")" \
      && up="$(designator_reduce_key "${candidate}")"; then
      if ! designator_host_match "${raw}" "${base}"; then
        jq -cn --arg r "${role}" --arg raw "${raw}" '{role:$r, raw:$raw, refuse:"REF-HOST"}' | json_canonical
        return 0
      fi
      jq -cn --arg r "${role}" --arg raw "${raw}" --arg k "${up}" \
        '{role:$r, raw:$raw, form:"url", key:$k}' | json_canonical
      return 0
    fi
    jq -cn --arg r "${role}" --arg raw "${raw}" '{role:$r, raw:$raw, refuse:"REF-DESIGNATOR"}' | json_canonical
    return 0
  fi

  if [[ "${role}" == "specification" ]]; then
    local trimmed
    trimmed="$(_desig_trim "$(_desig_strip_cr "${raw}")")"
    if [[ -n "${trimmed}" ]]; then
      jq -cn --arg r "${role}" --arg raw "${raw}" --arg t "${raw}" \
        '{role:$r, raw:$raw, form:"free_text", text:$t}' | json_canonical
      return 0
    fi
  fi

  jq -cn --arg r "${role}" --arg raw "${raw}" '{role:$r, raw:$raw, refuse:"REF-DESIGNATOR"}' | json_canonical
}

# designator_dedupe <json-array-of-classified> — §6/FR-008/FR-054: assigns
# `position` (0-based, argv order, among same-role designators) to every
# key/url-form entry, and detects a reduced key occurring more than once —
# within one role, or across both roles (naming one issue as both roles).
# Prints:
#   {"ok":true,"designators":[{...,"position":N}, ...]}
#   {"ok":false,"duplicates":["KEY", ...]}
# A `refuse`-carrying entry is passed through untouched under "designators"
# when ok — de-duplication only inspects resolved keys.
designator_dedupe() {
  local input="$1"
  local dups
  dups="$(jq -c '[ .[] | select(has("refuse") | not) | .key ] | group_by(.) | map(select(length>1) | .[0]) | unique' <<< "${input}")"
  local dup_count
  dup_count="$(jq 'length' <<< "${dups}")"
  if ((dup_count > 0)); then
    jq -cn --argjson d "${dups}" '{ok:false, duplicates:$d}' | json_canonical
    return 0
  fi

  jq -c '
    reduce .[] as $item
      ( {out:[], seen:{}, story_pos:0}
      ; if ($item | has("refuse")) then
          . + {out: (.out + [$item])}
        elif $item.role == "story" then
          . + {out: (.out + [$item + {position: .story_pos}]), story_pos: (.story_pos + 1)}
        else
          . + {out: (.out + [$item + {position: 0}])}
        end
      ) | {ok:true, designators: .out}
  ' <<< "${input}" | json_canonical
}
