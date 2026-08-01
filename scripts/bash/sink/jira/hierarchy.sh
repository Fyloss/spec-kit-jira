#!/usr/bin/env bash
# sink/jira/hierarchy.sh — Hierarchy derivation and the mandatory-field gate
# (008 T042/T043/T086/T087). See contracts/hierarchy-resolution.md.
#
# The child level is the lowest hierarchy_level occupied by a non-sub-task
# type; the type at that level is a recorded operator/derived answer, never
# derived here (research R1/R2 — the level is ambiguous in nearly every real
# project, so the TYPE is read from the persisted binding's `child_type`).
# The parent level is the lowest level strictly above the child level that is
# occupied by a non-sub-task type; UNLIKE the child, the parent TYPE is
# derived here, because a genuinely ambiguous parent tier is the edge case
# rather than the norm (contract §3).
#
# No Atlassian default type name, status name or field id appears anywhere in
# this file (Constitution VII) — every name is read from the project's own
# metadata.

[[ -n ${_JIRA_SINK_HIERARCHY:-} ]] && return 0
_JIRA_SINK_HIERARCHY=1

_hierarchy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_hierarchy_dir}/../../lib/output.sh"

# hierarchy_child_level <issue_types_json> — the lowest hierarchy_level over
# non-sub-task types (contract §2). Prints the level as a bare integer, or
# nothing when there are no non-sub-task types at all.
hierarchy_child_level() {
  local itypes="$1"
  jq -r '[ .[] | select(.subtask | not) | .hierarchy_level ] | if length > 0 then min else empty end' <<< "${itypes}"
}

# hierarchy_derive <project_key> <issue_types_json> — the full parent-level
# derivation (contract §3), plus the child level it is measured above.
# Prints one canonical JSON object:
#   {"status":"ok","child_level":N,"parent_level":N,
#    "parent":{"logical_name":"…","id":"…"}}
#   {"status":"no-parent-level","child_level":N,"message":"…"}
#   {"status":"parent-level-ambiguous","child_level":N,"candidates":[…],"message":"…"}
# `<LIST>` in every message is the candidates' logical names in discovered
# order, comma-separated (contract §6) — never an id.
hierarchy_derive() {
  local key="$1" itypes="$2"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --arg key "${key}" --argjson t "${itypes}" '
    ($t | map(select(.subtask | not))) as $cand
    | ($cand | map(.hierarchy_level) | min) as $childLevel
    | ($cand | map(select(.hierarchy_level == $childLevel))) as $childCands
    | ($cand | map(select(.hierarchy_level > $childLevel))) as $above
    | ($childCands | map(.logical_name) | join(", ")) as $childList
    | if ($above | length) == 0 then
        { status: "no-parent-level", child_level: $childLevel,
          message: "reconcile: project \($key) offers no issue type above its \($childList) level, so a specification has nowhere to hang. Its non-sub-task types are: \($childList). A parent level must exist in the project before it can be mirrored (zero writes)." }
      else
        ($above | map(.hierarchy_level) | min) as $parentLevel
        | ($above | map(select(.hierarchy_level == $parentLevel))) as $parentCands
        | if ($parentCands | length) == 1 then
            { status: "ok", child_level: $childLevel, parent_level: $parentLevel,
              parent: { logical_name: $parentCands[0].logical_name, id: $parentCands[0].id } }
          else
            ($parentCands | map(.logical_name) | join(", ")) as $parentList
            | { status: "parent-level-ambiguous", child_level: $childLevel,
                candidates: $parentCands,
                message: "reconcile: project \($key) offers more than one issue type at the level above \($childList): \($parentList). The bridge will not choose one for you (zero writes)." }
          end
      end
  '
  # kcov-excl-stop
}

# hierarchy_child_type_unresolved_message <project_key> — contract §6.
hierarchy_child_type_unresolved_message() {
  printf 'reconcile: project %s has no recorded issue type for user stories. Run /speckit.jira.config to record it (zero writes)' "$1"
}

# hierarchy_parent_link_unavailable_message <project_key> <child_logical_name> — contract §6.
hierarchy_parent_link_unavailable_message() {
  printf 'reconcile: issue type %s in project %s does not accept a parent reference, so its stories cannot hang from a parent (zero writes)' "$2" "$1"
}

# hierarchy_binding_shape_stale_message <project_key> — contract §6.
hierarchy_binding_shape_stale_message() {
  printf 'reconcile: the local binding for %s predates parent support and does not record issue-type hierarchy. The project is bound — its binding is simply a version behind. Run /speckit.jira.config to refresh it (zero writes)' "$1"
}

# hierarchy_mandatory_fields_message <unsatisfiable_json> — contract §5. Input:
# [{"type_name":"…","fields":["…","…"]}, …]. One refusal naming every
# unsatisfiable field of every written type, fields named by their Jira
# `name`, never a customfield_NNNNN id.
hierarchy_mandatory_fields_message() {
  local unsat="$1"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -r '
    map("Issue type \"\(.type_name)\" requires fields this bridge cannot supply: "
        + (.fields | map("\"" + . + "\"") | join(", ")) + ".")
    | join(" ")
  ' <<< "${unsat}"
  # kcov-excl-stop
}

# hierarchy_unsatisfiable_fields <required_fields_json> <has_parent_link:true|false> — contract §5:
# which required fields the bridge can supply. required_fields_json is a
# single type's list [{"logical_name":"…","field_id":"…"}]. Prints the
# unsatisfiable logical_names as a canonical array.
hierarchy_unsatisfiable_fields() {
  local fields="$1" has_link="${2:-false}"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson f "${fields}" --argjson link "${has_link}" '
    [ $f[] | select(
        (.field_id | IN("summary","description","issuetype","project","priority","reporter")) or
        (.field_id == "parent" and $link)
        | not)
      | .logical_name ]
  '
  # kcov-excl-stop
}

# hierarchy_mandatory_gate <binding_json> [project_key] — Phase 6, US3,
# T086/T087/T088: the parent-link-unavailable refusal (contract §4, research
# R4) and the mandatory-field gate (contract §5), run over BOTH written
# types. Runs after derivation and before recognition (contract §5, §7), so
# no read and no write has happened yet.
#
# binding_json: the persisted binding's resolved_ids.<KEY> shape —
# {child_type, parent_type, parent_link_available, required_fields}.
#
# The parent-link check runs FIRST: it is a structural prerequisite (whether
# the child type's own create metadata offers a `parent` field at all), not
# a per-field satisfiability question — plan_writes sends fields.parent on
# every child creation unconditionally, so a project offering no such field
# would otherwise reach a rejected write.
#
# Prints one canonical JSON object:
#   {"status":"ok"}
#   {"status":"parent-link-unavailable", "reason":"parent-link-unavailable", "message":".."}
#   {"status":"unsatisfiable", "reason":"mandatory-fields-unsatisfiable", "message":".."}
hierarchy_mandatory_gate() {
  local binding="$1" project="${2:-}"
  local child_id child_name parent_id parent_name has_link
  child_id="$(jq -r '.child_type.id' <<< "${binding}")"
  child_name="$(jq -r '.child_type.logical_name' <<< "${binding}")"
  parent_id="$(jq -r '.parent_type.id' <<< "${binding}")"
  parent_name="$(jq -r '.parent_type.logical_name' <<< "${binding}")"
  has_link="$(jq -r --arg t "${child_id}" '(.parent_link_available[$t] // false)' <<< "${binding}")"

  if [[ "${has_link}" != "true" ]]; then
    jq -cn --arg r "parent-link-unavailable" --arg m "$(hierarchy_parent_link_unavailable_message "${project}" "${child_name}")" \
      '{status:$r, reason:$r, message:$m}'
    return 0
  fi

  local child_fields parent_fields child_unsat parent_unsat unsat="[]"
  child_fields="$(jq -c --arg t "${child_id}" '.required_fields[$t] // []' <<< "${binding}")"
  parent_fields="$(jq -c --arg t "${parent_id}" '.required_fields[$t] // []' <<< "${binding}")"
  # The parent's own `parent` field, were one ever required, is always
  # unsatisfiable — a parent has no parent (contract §5).
  child_unsat="$(hierarchy_unsatisfiable_fields "${child_fields}" "true")"
  parent_unsat="$(hierarchy_unsatisfiable_fields "${parent_fields}" "false")"

  if [[ "$(jq 'length' <<< "${parent_unsat}")" -gt 0 ]]; then
    unsat="$(jq -c --arg n "${parent_name}" --argjson f "${parent_unsat}" '. + [{type_name:$n, fields:$f}]' <<< "${unsat}")"
  fi
  if [[ "$(jq 'length' <<< "${child_unsat}")" -gt 0 ]]; then
    unsat="$(jq -c --arg n "${child_name}" --argjson f "${child_unsat}" '. + [{type_name:$n, fields:$f}]' <<< "${unsat}")"
  fi

  if [[ "$(jq 'length' <<< "${unsat}")" -eq 0 ]]; then
    jq -cn '{status:"ok"}'
    return 0
  fi

  local msg; msg="$(hierarchy_mandatory_fields_message "${unsat}")"
  jq -cn --arg m "reconcile: ${msg} Nothing was written (zero writes). Either make these fields optional for these types in the project's field configuration, or create the parent and its stories by hand and record their keys in specs/…/spec.md." \
    '{status:"unsatisfiable", reason:"mandatory-fields-unsatisfiable", message:$m}'
}
