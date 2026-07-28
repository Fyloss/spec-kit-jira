#!/usr/bin/env bash
# commands/adopt.sh — The adopt command (003 US1…US6).
#
# The constitution's SECOND controlled exception to "the filesystem is the source
# of truth": a deliberate, one-time, operator-confirmed adoption that binds an
# already-populated Jira backlog to the spec artifacts already on disk, writing
# nothing but the identity marker.
#
# Strictly two-phase (FR-006). No write of any kind may occur in phase 1, ever:
#
#   1. DISCOVERY (read-only) — enablement gate, prefix validation, scope and pin
#      resolution, target derivation, one paginated JQL label search per routed
#      project, one identity read per candidate, classification, print the plan.
#   2. APPLY (only after confirmation) — one
#      PUT /issue/{key}/properties/spec-kit-jira per binding, origin `human`,
#      handed to the existing apply_writes so the BLOCK-tier privacy guard, the
#      fail-closed abort ladder, and the dry-run action-set prediction all come
#      for free (FR-028, FR-008, FR-023).
#
# Adoption emits NO other write kind: no create, delete, transition, comment,
# link, relabel, description, or summary write (FR-007).
#
# Confirmation (research §6): --yes pre-confirms; a terminal is prompted; a
# decline is an operator CHOICE and exits 0, not a failure. With neither a
# terminal nor --yes the run collapses onto its own --dry-run path and names
# --yes as the way to proceed — no new exit code is introduced for any of it.
# SPEC_KIT_JIRA_ADOPT_ANSWER supplies that answer where no terminal exists (the
# conformance corpus), exactly as SPEC_KIT_JIRA_PLAN_CONTEXT supplies reconcile's.

[[ -n ${_JIRA_CMD_ADOPT:-} ]] && return 0
_JIRA_CMD_ADOPT=1

_cmd_adopt_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_cmd_adopt_dir}/../lib/cli.sh"
# shellcheck source=/dev/null
source "${_cmd_adopt_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_cmd_adopt_dir}/../lib/config.sh"
# shellcheck source=/dev/null
source "${_cmd_adopt_dir}/../engine/parse.sh"
# shellcheck source=/dev/null
source "${_cmd_adopt_dir}/../engine/adoption.sh"
# shellcheck source=/dev/null
source "${_cmd_adopt_dir}/../sink/jira/adoption.sh"
# shellcheck source=/dev/null
source "${_cmd_adopt_dir}/../sink/jira/plan_apply.sh"

# The directory the spec folders live in, relative to the repository root
# (overridable so a suite can point at a fixture tree).
: "${SPEC_KIT_JIRA_SPECS_DIR:=specs}"

# The plan's column geometry, shared by both ports so the printed plan is
# byte-identical for identical state (SC-008).
_ADOPT_COL_TARGET=36
_ADOPT_COL_KEY=9
_ADOPT_COL_STATUS=15

# _adopt_spec_folders — every spec folder on disk, one per line, sorted
# ascending. A folder is a directory under the specs root; nothing else in the
# tree is ever considered.
_adopt_spec_folders() {
  local root="${SPEC_KIT_JIRA_SPECS_DIR}" d
  [[ -d "${root}" ]] || return 0
  for d in "${root}"/*/; do
    [[ -d "${d}" ]] || continue
    d="${d%/}"
    printf '%s\n' "${d##*/}"
  done | LC_ALL=C sort
}

# _adopt_story_ordinals <folder> — the ordinals of the user stories the spec
# declares, as a JSON array. The ordinals are the ones the bridge ALREADY assigns
# in parse_spec, so the label grammar introduces no new identifier.
_adopt_story_ordinals() {
  local file="${SPEC_KIT_JIRA_SPECS_DIR}/$1/spec.md" parsed
  if [[ ! -f "${file}" ]]; then
    printf '[]'
    return 0
  fi
  if ! parsed="$(parse_spec "$1" < "${file}" 2> /dev/null)"; then
    printf '[]'
    return 0
  fi
  jq -c '[ (.stories // []) | to_entries[] | .key + 1 ]' <<< "${parsed}"
}

# _adopt_summary <dry_run> <adoption-block> <actions> <counts...> <exit>
_adopt_summary() {
  local dry="$1" adoption="$2" actions="$3" updated="$4" skipped="$5" errors="$6" rc="$7"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson dry "${dry}" --argjson ad "${adoption}" --argjson ac "${actions}" \
    --argjson u "${updated}" --argjson s "${skipped}" --argjson e "${errors}" --argjson x "${rc}" '
    {schema_version: "1.0", command: "adopt", dry_run: $dry,
     counts: {created: 0, updated: $u, skipped: $s, warnings: 0, errors: $e},
     actions: $ac, adoption: $ad, exit_code: $x}' | json_canonical
  # kcov-excl-stop
}

# _adopt_print_plan <adoption-block> — the prose plan (Principle XVI, default
# output): one line per spec folder in scope, each refusal followed by its
# copy-pasteable remediation, then the out-of-scope roll-up. Printed BEFORE any
# write, always.
_adopt_print_plan() {
  local ad="$1" n i
  printf 'Adoption plan (adoption.enabled: %s, label prefix: %s)\n\n' \
    "$(jq -r '.enabled' <<< "${ad}")" "$(jq -r '.label_prefix' <<< "${ad}")"

  # Spec Edge Cases: an empty plan is a success, but never a silent one. Without
  # this line the operator reads a bare header and has to infer that nothing
  # happened (Constitution XVI).
  if [[ "$(jq '.bindings | length' <<< "${ad}")" -eq 0 &&
        "$(jq '.refusals | length' <<< "${ad}")" -eq 0 &&
        "$(jq '.out_of_scope | length' <<< "${ad}")" -eq 0 ]]; then
    printf '  nothing was found: no spec folder is in scope, so nothing was searched for and nothing will be written\n'
  fi

  n="$(jq '.bindings | length' <<< "${ad}")"
  for ((i = 0; i < n; i++)); do
    local b display key status reason
    b="$(jq -c ".bindings[${i}]" <<< "${ad}")"
    display="$(adoption_display_name "$(jq -r '.spec_folder' <<< "${b}")" "$(jq -r '.level' <<< "${b}")" \
      "$(jq -r 'if .story_ordinal == null then "" else (.story_ordinal | tostring) end' <<< "${b}")")"
    key="$(jq -r '.issue_key' <<< "${b}")"
    if [[ "$(jq -r '.status' <<< "${b}")" == "already-adopted" ]]; then
      status="already adopted"
      reason="skipped"
    else
      status="adopt"
      if [[ "$(jq -r '.reason' <<< "${b}")" == "explicit-binding" ]]; then
        reason="explicit binding"
        local overrode
        overrode="$(jq -r '.overrode_key // ""' <<< "${b}")"
        [[ -n "${overrode}" ]] && reason="explicit binding, overrides ${overrode}"
      else
        reason="label match"
      fi
    fi
    printf '  %-*s%s %-*s %-*s (%s)\n' \
      "${_ADOPT_COL_TARGET}" "${display}" '→' "${_ADOPT_COL_KEY}" "${key}" \
      "${_ADOPT_COL_STATUS}" "${status}" "${reason}"
  done

  n="$(jq '.refusals | length' <<< "${ad}")"
  for ((i = 0; i < n; i++)); do
    local r display detail keys
    r="$(jq -c ".refusals[${i}]" <<< "${ad}")"
    display="$(adoption_display_name "$(jq -r '.spec_folder' <<< "${r}")" "$(jq -r '.level' <<< "${r}")" \
      "$(jq -r 'if .story_ordinal == null then "" else (.story_ordinal | tostring) end' <<< "${r}")")"
    detail="$(jq -r '.reason | gsub("-"; " ")' <<< "${r}")"
    keys="$(jq -r '.issue_keys | join(", ")' <<< "${r}")"
    [[ -n "${keys}" ]] && detail="${detail}: ${keys}"
    printf '  %-*s%s %-*s %-*s (%s)\n' \
      "${_ADOPT_COL_TARGET}" "${display}" '—' "${_ADOPT_COL_KEY}" "" \
      "${_ADOPT_COL_STATUS}" "REFUSED" "${detail}"
    printf '      remediation: %s\n' "$(jq -r '.remediation' <<< "${r}")"
  done

  if [[ "$(jq '.out_of_scope | length' <<< "${ad}")" -gt 0 ]]; then
    printf '\n  out of scope: %s\n' "$(jq -r '.out_of_scope | join(", ")' <<< "${ad}")"
  fi
  printf '\n'
}

# _adopt_print_actions <actions-json> — the action set the run performs, with the
# site host stripped to a host-relative path (Constitution IV: the host is a
# coordinate that never appears in output).
_adopt_print_actions() {
  local actions="$1" n i
  n="$(jq 'length' <<< "${actions}")"
  if ((n == 0)); then
    printf 'Actions: none\n'
    return 0
  fi
  printf 'Actions:\n'
  for ((i = 0; i < n; i++)); do
    printf '  %s %s\n' "$(jq -r ".[${i}].method" <<< "${actions}")" "$(jq -r ".[${i}].url" <<< "${actions}")"
  done
}

# _adopt_emit <json?> <summary-json> — the run summary, prose by default.
_adopt_emit() {
  if [[ "$1" == "true" ]]; then
    printf '%s\n' "$2"
  else
    printf '%s' "$2" | summary_render_prose
  fi
}

# cmd_adopt <argv...> — see the file header. Echoes the plan and the run summary
# to stdout; returns the exit code.
cmd_adopt() {
  local parsed json="false" dry_run="false" yes="false" exit_code="0" error=""
  local binds_raw="" specs_raw=""
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      yes) yes="${value}" ;;
      binds) binds_raw="${value}" ;;
      specs) specs_raw="${value}" ;;
      exit) exit_code="${value}" ;;
      error) error="${value}" ;;
    esac
  done <<< "${parsed}"

  if [[ "${exit_code}" != "0" ]]; then
    [[ -n "${error}" ]] && printf 'adopt: %s\n' "${error}" >&2
    return "${exit_code}"
  fi

  local binds_json specs_json
  binds_json="$(_adopt_words_to_json "${binds_raw}")"
  specs_json="$(_adopt_words_to_json "${specs_raw}")"

  # ---- (1) Configuration ---------------------------------------------------
  local cfg
  cfg="$(config_load)" || return $?

  local prefix enabled
  enabled="$(jq -r 'if (.adoption.enabled // false) == true then "true" else "false" end' <<< "${cfg}")"
  prefix="$(jq -r '.adoption.label_prefix // "speckit-adopt:"' <<< "${cfg}")"

  # ---- (2) Enablement gate — before ANY read against a candidate ticket -----
  # FR-001 / SC-009: while adoption is disabled a labelled ticket is never read
  # as a candidate and never written to.
  if [[ "${enabled}" != "true" ]]; then
    printf 'adopt: adoption is disabled — set adoption.enabled to true in %s/config.yml to enable it; no ticket was read and nothing was written\n' \
      "${JIRA_CONFIG_DIR}" >&2
    local ad
    ad="$(_adopt_adoption_block "false" "${prefix}" "false" '[]' '[]' '[]')"
    _adopt_emit "${json}" "$(_adopt_summary "${dry_run}" "${ad}" '[]' 0 0 0 "$(cli_exit_code config)")"
    return "$(cli_exit_code config)"
  fi

  # ---- (3) Scope and pins (usage errors stop the run with zero writes) ------
  local all_folders scope_result in_scope out_of_scope pins
  all_folders="$(_adopt_spec_folders | jq -cR . | jq -cs .)"

  if ! scope_result="$(adoption_scope "${all_folders}" "${specs_json}")"; then
    printf 'adopt: %s\n' "${scope_result}" >&2
    return "$(cli_exit_code usage)"
  fi
  in_scope="$(jq -c '.in_scope' <<< "${scope_result}")"
  out_of_scope="$(jq -c '.out_of_scope' <<< "${scope_result}")"

  if ! pins="$(adoption_pins_resolve "${binds_json}" "${all_folders}")"; then
    printf 'adopt: %s\n' "${pins}" >&2
    return "$(cli_exit_code usage)"
  fi

  # ---- (4) Targets ---------------------------------------------------------
  local specs='[]' folder ordinals
  while IFS= read -r folder; do
    [[ -z "${folder}" ]] && continue
    ordinals="$(_adopt_story_ordinals "${folder}")"
    specs="$(jq -c --arg f "${folder}" --argjson o "${ordinals}" \
      '. + [{folder: $f, story_ordinals: $o}]' <<< "${specs}")"
  done <<< "$(jq -r '.[]' <<< "${in_scope}")"

  local longest prefix_error
  longest="$(adoption_longest_suffix "${specs}")"
  if ! prefix_error="$(adoption_validate_prefix "${prefix}" "${longest}")"; then
    printf 'adopt: config (%s/config.yml): %s\n' "${JIRA_CONFIG_DIR}" "${prefix_error}" >&2
    local ad
    ad="$(_adopt_adoption_block "true" "${prefix}" "false" '[]' '[]' "${out_of_scope}")"
    _adopt_emit "${json}" "$(_adopt_summary "${dry_run}" "${ad}" '[]' 0 0 0 "$(cli_exit_code config)")"
    return "$(cli_exit_code config)"
  fi

  local targets
  targets="$(adoption_targets "${specs}" "${prefix}" "${cfg}")" || return $?

  # ---- (5) Discovery (read-only) -------------------------------------------
  local candidates
  candidates="$(adopt_search_candidates "${targets}")" || return $?
  candidates="$(_adopt_merge_pinned "${candidates}" "${pins}")" || return $?
  candidates="$(adopt_read_candidate_identity "${candidates}")" || return $?

  # ---- (6) Classification --------------------------------------------------
  local repo plan bindings refusals
  repo="${SPEC_KIT_JIRA_REPO:-local/repo}"
  plan="$(adoption_classify "${targets}" "${candidates}" "${pins}" "${repo}")"
  bindings="$(jq -c '.bindings' <<< "${plan}")"
  refusals="$(jq -c '.refusals' <<< "${plan}")"

  # ---- (7) The action set IS the dry-run prediction (FR-023) ---------------
  local actions disp_actions base
  base="${SPEC_KIT_JIRA_BASE_URL:-}"
  actions="$(adopt_stamp_actions "${bindings}" "${repo}")"
  disp_actions="$(jq -c --arg b "${base}" '[ .[] | .url |= ltrimstr($b) ]' <<< "${actions}")"

  # ---- (8) Confirmation ----------------------------------------------------
  local confirmed="false" prompted="false" declined="false" no_terminal="false"
  if [[ "${dry_run}" == "true" ]]; then
    : # a dry run never prompts and never writes
  elif [[ "${yes}" == "true" ]]; then
    confirmed="true"
  else
    local answer=""
    if [[ -n "${SPEC_KIT_JIRA_ADOPT_ANSWER:-}" ]]; then
      prompted="true"
      answer="${SPEC_KIT_JIRA_ADOPT_ANSWER}"
    elif [[ -t 0 ]]; then
      prompted="true"
      IFS= read -r answer || answer=""
    else
      no_terminal="true"
    fi
    if [[ "${prompted}" == "true" ]]; then
      case "${answer}" in
        y | Y | yes | Yes | YES) confirmed="true" ;;
        *) declined="true" ;;
      esac
    fi
  fi

  # ---- (9) Report the plan BEFORE any write --------------------------------
  local ad
  ad="$(_adopt_adoption_block "true" "${prefix}" "${confirmed}" "${bindings}" "${refusals}" "${out_of_scope}")"
  if [[ "${json}" != "true" ]]; then
    _adopt_print_plan "${ad}"
    if [[ "${confirmed}" != "true" ]]; then
      _adopt_print_actions "${disp_actions}"
    fi
    if [[ "${prompted}" == "true" ]]; then
      printf 'Apply this plan? [y/N] %s\n' "$([[ "${confirmed}" == "true" ]] && printf 'y' || printf 'n')"
    fi
    if [[ "${declined}" == "true" ]]; then
      printf 'Adoption cancelled: nothing was written.\n'
    fi
    if [[ "${no_terminal}" == "true" ]]; then
      printf 'Adoption not applied: no terminal is attached. Re-run with --yes to apply this plan.\n'
    fi
    if [[ "${dry_run}" == "true" ]]; then
      printf 'Dry run: nothing was written.\n'
    fi
  fi

  # ---- (10) Apply ----------------------------------------------------------
  # Any per-binding refusal makes the run exit 4 whether confirmed or declined;
  # when classes co-occur the HIGHEST applicable code wins (FR-013).
  local rc=0 apply_rc=0
  if [[ "$(jq 'length' <<< "${refusals}")" -gt 0 ]]; then
    rc="$(cli_exit_code config)"
  fi
  if [[ "${confirmed}" == "true" && "$(jq 'length' <<< "${actions}")" -gt 0 ]]; then
    apply_writes "${actions}" || apply_rc=$?
    ((apply_rc > rc)) && rc="${apply_rc}"
  fi

  local updated skipped errors
  updated="$(jq '[ .[] | select(.status == "adopt") ] | length' <<< "${bindings}")"
  skipped="$(jq '[ .[] | select(.status == "already-adopted") ] | length' <<< "${bindings}")"
  errors="$(jq 'length' <<< "${refusals}")"

  _adopt_emit "${json}" "$(_adopt_summary "${dry_run}" "${ad}" "${disp_actions}" "${updated}" "${skipped}" "${errors}" "${rc}")"
  return "${rc}"
}

# _adopt_words_to_json <space-joined> — a repeatable flag's values as a JSON
# array. Values carry no whitespace (a folder name and a key never do), which is
# what makes the space-joined parse state safe.
_adopt_words_to_json() {
  local raw="$1" out='[]' word
  [[ -z "${raw}" ]] && { printf '[]'; return 0; }
  for word in ${raw}; do
    out="$(jq -c --arg w "${word}" '. + [$w]' <<< "${out}")"
  done
  printf '%s' "${out}"
}

# _adopt_adoption_block <enabled> <prefix> <confirmed> <bindings> <refusals> <out-of-scope>
# The adoption summary block (contracts/adoption-plan.schema.json). It is also
# exactly the --dry-run report, which is why FR-023's "identical action set" is a
# structural guarantee rather than a behavioural promise.
_adopt_adoption_block() {
  jq -cn --argjson e "$1" --arg p "$2" --argjson c "$3" \
    --argjson b "$4" --argjson r "$5" --argjson o "$6" '
    {enabled: $e, label_prefix: $p, confirmed: $c,
     bindings: $b, refusals: $r, out_of_scope: $o}' | json_canonical
}

# _adopt_merge_pinned <candidates-json> <pins-json> — read the context of every
# pinned key that discovery did not already return, and merge it into the
# candidate set. A pin is then validated through the IDENTICAL path a discovered
# candidate is — same project check, same claim check, same hierarchy checks,
# producing the same refusal classes and exit codes (FR-020).
_adopt_merge_pinned() {
  local candidates="$1" pins="${2:-[]}"
  local missing
  # kcov-excl-start — jq literal (string lines are not statements)
  missing="$(jq -c --argjson c "${candidates}" '
    ([ $c[].key ]) as $known
    | [ .[] | .issue_key ] | unique
    | map(select(. as $k | ($known | index($k)) == null))' <<< "${pins}")"
  # kcov-excl-stop
  if [[ "$(jq 'length' <<< "${missing}")" -eq 0 ]]; then
    printf '%s' "${candidates}"
    return 0
  fi
  local fetched
  fetched="$(adopt_fetch_pinned "${missing}")" || return $?
  jq -c --argjson a "${candidates}" --argjson b "${fetched}" \
    '($a + $b) | unique_by(.key) | sort_by(.key)' <<< 'null' | json_canonical
}
