#!/usr/bin/env bash
# commands/config.sh — Config-command building blocks (SINK-facing, T040).
#
# US2 lands the mapping-validation and strategy-persistence pieces the config
# command orchestrates; the full `cmd_config` entry point (the deterministic
# ceremony) is authored in US1 (T044/T045) and defined here then.
#
# Mapping validation refuses an impossible mapping at config time (FR-007): a
# team-managed project supports only an Epic parent and Sub-task children
# (research §3), so a hierarchy level ABOVE Epic is rejected with EXIT_CONFIG (4).
# The "Epic" tier is identified from the DISCOVERED binding — the top non-subtask
# hierarchy level — never a name compiled into the script (Constitution VII).
#
# Strategy persistence builds the project mapping entry by LOGICAL name; the
# config command writes it into config.yml.

[[ -n ${_JIRA_CMD_CONFIG:-} ]] && return 0
_JIRA_CMD_CONFIG=1

_cmd_config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_cmd_config_dir}/../lib/cli.sh"
# shellcheck source=/dev/null
source "${_cmd_config_dir}/../lib/output.sh"

: "${EXIT_CONFIG:=4}"

# config_validate_mapping <style> <hierarchy-json> <binding-json>
# Refuse a team-managed hierarchy level above the discovered Epic tier (FR-007).
# The top parent is the non-subtask issue type with the greatest hierarchy_level
# in the binding; any configured level positioned above it is impossible. Prints
# a located error naming the level and the style, and returns EXIT_CONFIG (4).
# Company-managed projects carry no such restriction. Returns 0 when valid.
config_validate_mapping() {
  local style="$1" hierarchy="$2" binding="$3"
  [[ "${style}" != "team_managed" ]] && return 0

  local top
  top="$(jq -r '[.issue_types[] | select(.subtask == false)] | max_by(.hierarchy_level) | .logical_name' <<< "${binding}")"

  # Levels listed above the top parent (earlier in the top-down hierarchy list).
  local offenders
  offenders="$(jq -r --arg top "${top}" '
    (. // []) as $h
    | ($h | index($top)) as $ti
    | if $ti == null then empty else $h[0:$ti][] end
  ' <<< "${hierarchy}")"

  if [[ -n "${offenders}" ]]; then
    local first
    first="$(printf '%s\n' "${offenders}" | head -n1)"
    printf "mapping: hierarchy level '%s' sits above %s; team-managed projects support only an %s parent and Sub-task children (project style: team_managed)\n" \
      "${first}" "${top}" "${top}" >&2
    return "${EXIT_CONFIG}"
  fi
  return 0
}

# config_project_mapping <key> <style> <epic_strategy> <task_strategy> [link_type]
# Build the canonical project mapping entry by logical name. When task_strategy is
# `linked_story`, a link_type is REQUIRED (FR-009) — its absence is refused with
# EXIT_CONFIG (4). Prints the canonical project object on stdout.
config_project_mapping() {
  local key="$1" style="$2" epic_strategy="$3" task_strategy="$4" link_type="${5:-}"

  if [[ "${task_strategy}" == "linked_story" && -z "${link_type}" ]]; then
    printf 'mapping: task_strategy=linked_story requires a link_type (FR-009)\n' >&2
    return "${EXIT_CONFIG}"
  fi

  jq -n \
    --arg key "${key}" --arg style "${style}" \
    --arg epic "${epic_strategy}" --arg task "${task_strategy}" \
    --arg link "${link_type}" '
    {key: $key, style: $style, epic_strategy: $epic, task_strategy: $task}
    + (if $link == "" then {} else {link_type: $link} end)
  ' | json_canonical
}
