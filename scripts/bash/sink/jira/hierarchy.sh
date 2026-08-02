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
# shellcheck source=/dev/null
source "${_hierarchy_dir}/../../lib/config.sh" # JIRA_ROLE_NAMES — the closed role set has exactly one source (010, contract §1)

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

# =============================================================================
# Role mapping (010, contracts/role-mapping.md) — the operator declares which
# issue types carry the mirror. One resolver, invoked once per project, over
# all three roles — specification, story, task — with precedence
# declared -> operator -> derived, evaluating every role before refusing
# (contract §3.2, research R1). Derivation (§3.1) is unchanged from 008 where
# it applies: `hierarchy_child_level`/`hierarchy_derive` above remain the
# level arithmetic this module reuses.
# =============================================================================

# role_candidates <issue_types_json> <role> — the candidate set for one role
# (contract §3.3): the project's non-sub-task types for specification/story,
# its sub-task types for task, in discovered order. Prints the canonical
# array of {logical_name,id,hierarchy_level,subtask}.
role_candidates() {
  local itypes="$1" role="$2"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c --arg role "${role}" '
    if $role == "task" then [ .[] | select(.subtask) ]
    else [ .[] | select(.subtask | not) ] end
  ' <<< "${itypes}"
  # kcov-excl-stop
}

# role_resolve <project_key> <issue_types_json> <declared_json> <operator_json>
# The resolver (contract §3): declared_json and operator_json are each
# {specification?, story?, task?} -> issue type name, scoped to ONE project.
# Matching (§3.3) searches the project's WHOLE issue-type list by exact name
# — never pre-scoped to the role's candidate set — so a name that exists but
# names the wrong KIND of type (e.g. a sub-task type declared for `story`)
# is caught by the subtask check below and reported as §6.5/§6.6, not as an
# unrelated §6.3 "unknown type" (this is what lets a sub-task type reported
# at level 0 be caught by the `subtask` flag rather than by its level).
# `task` is never derived (§3.1) — undeclared and unanswered, it is ABSENT,
# not unresolved (§3.4): no entry, no problem.
#
# Prints one canonical JSON object:
#   {"roles": {<role>: {logical_name,id,hierarchy_level,subtask,source}, ...},
#    "unresolved": [{role,level,candidates}, ...],       (§6.2)
#    "unknown":    [{role,name,candidates}, ...],         (§6.3)
#    "duplicate":  [{role,name,level}, ...],               (§6.4)
#    "subtask_misuse": [{role,name}, ...],                 (§6.5)
#    "task_misuse":    [{name,candidates}, ...],           (§6.6)
#    "no_parent_level": <message-string-or-null>}
role_resolve() {
  local key="$1" itypes="$2" declared="${3:-{\}}" operator="${4:-{\}}"
  [[ -z "${declared}" ]] && declared='{}'
  [[ -z "${operator}" ]] && operator='{}'
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --arg key "${key}" --argjson itypes "${itypes}" --argjson declared "${declared}" --argjson operator "${operator}" --argjson roles "$(_cfg_role_names_json)" '
    def nonSubtask: [ $itypes[] | select(.subtask | not) ];
    def subtaskTypes: [ $itypes[] | select(.subtask) ];
    def candidatesFor($role): if $role == "task" then subtaskTypes else nonSubtask end;
    (nonSubtask) as $ns
    | (if ($ns|length) > 0 then ($ns | map(.hierarchy_level|tonumber) | min) else null end) as $childLevel
    | (if $childLevel == null then [] else [ $ns[] | select((.hierarchy_level|tonumber) == $childLevel) ] end) as $childCands
    | (if $childLevel == null then [] else [ $ns[] | select((.hierarchy_level|tonumber) > $childLevel) ] end) as $above
    | (if ($above|length) > 0 then ($above | map(.hierarchy_level|tonumber) | min) else null end) as $parentLevel
    | ($childCands | map(.logical_name) | join(", ")) as $childList
    | reduce ($roles[]) as $role
        ( {roles:{}, unresolved:[], unknown:[], duplicate:[], subtask_misuse:[], task_misuse:[], no_parent_level:null}
        ; ($declared[$role] // null) as $dname
        | ($operator[$role] // null) as $oname
        | (if $dname != null then {name:$dname, source:"declared"}
           elif $oname != null then {name:$oname, source:"operator"}
           else null end) as $answer
        | if $answer != null then
            ([ $itypes[] | select(.logical_name == $answer.name) ]) as $matches
            | if ($matches|length) == 0 then
                . + {unknown: (.unknown + [{role:$role, name:$answer.name, candidates: candidatesFor($role)}])}
              elif ($matches|length) > 1 then
                . + {duplicate: (.duplicate + [{role:$role, name:$answer.name, level: ($matches[0].hierarchy_level|tostring)}])}
              else
                ($matches[0]) as $m
                | if ($role != "task") and ($m.subtask) then
                    . + {subtask_misuse: (.subtask_misuse + [{role:$role, name:$m.logical_name}])}
                  elif ($role == "task") and ($m.subtask | not) then
                    . + {task_misuse: (.task_misuse + [{name:$m.logical_name, candidates: subtaskTypes}])}
                  else
                    . + {roles: (.roles + {($role): ($m + {hierarchy_level: ($m.hierarchy_level|tostring), source: $answer.source})})}
                  end
              end
          elif $role == "task" then
            .
          elif $role == "story" then
            if $childLevel == null then . else
              ([ $ns[] | select((.hierarchy_level|tonumber) == $childLevel) ]) as $lc
              | if ($lc|length) == 1 then
                  . + {roles: (.roles + {story: ($lc[0] + {hierarchy_level: ($lc[0].hierarchy_level|tostring), source:"derived"})})}
                else
                  . + {unresolved: (.unresolved + [{role:"story", level: ($childLevel|tostring), candidates: $lc}])}
                end
            end
          else
            if $childLevel == null then .
            elif $parentLevel == null then
              . + {no_parent_level: "reconcile: project \($key) offers no issue type above its \($childList) level, so a specification has nowhere to hang. Its non-sub-task types are: \($childList). A parent level must exist in the project before it can be mirrored (zero writes)."}
            else
              ([ $above[] | select((.hierarchy_level|tonumber) == $parentLevel) ]) as $pc
              | if ($pc|length) == 1 then
                  . + {roles: (.roles + {specification: ($pc[0] + {hierarchy_level: ($pc[0].hierarchy_level|tostring), source:"derived"})})}
                else
                  . + {unresolved: (.unresolved + [{role:"specification", level: ($parentLevel|tostring), candidates: $pc}])}
                end
            end
          end
        )
  '
  # kcov-excl-stop
}

# role_has_problems <resolve-result-json> — true when role_resolve found
# anything that must refuse the run before any write.
role_has_problems() {
  jq -r '
    (.unresolved|length) + (.unknown|length) + (.duplicate|length)
    + (.subtask_misuse|length) + (.task_misuse|length) + (if .no_parent_level then 1 else 0 end) > 0
  ' <<< "$1"
}

# role_unresolved_message <project_key> <role> <level> <candidates_json> —
# contract §6.2, the closed question. Two lines.
role_unresolved_message() {
  local key="$1" role="$2" level="$3" cands="$4"
  local list; list="$(jq -r 'map(.logical_name) | join(", ")' <<< "${cands}")"
  printf 'config: project %s: the %s level (%s) holds more than one issue type: %s. The bridge will not choose one for you (zero writes).\nconfig: declare it in .specify/jira/config.yml under projects[].hierarchy.%s, or answer once with --issue-type %s=%s=<one of them>.' \
    "${key}" "${role}" "${level}" "${list}" "${role}" "${key}" "${role}"
}

# role_unresolved_json <resolve-result-json> <project_key> — the structured
# `unresolved_roles` block (contract §6.2), emitted through the output
# module, never a bare `jq` — it is multi-line JSON (research R10).
role_unresolved_json() {
  local result="$1" key="$2"
  jq -c --arg key "${key}" '
    [ .unresolved[] | {
        project: $key, role: .role, level: .level,
        candidates: [ .candidates[] | {logical_name, id} ],
        declaration: "projects[].hierarchy.\(.role)",
        flag: "--issue-type \($key)=\(.role)=<name>"
      } ]
  ' <<< "${result}"
}

# role_unknown_type_message <project_key> <role> <name> <candidates_json> —
# contract §6.3.
role_unknown_type_message() {
  local key="$1" role="$2" name="$3" cands="$4"
  local list; list="$(jq -r 'map(.logical_name) | join(", ")' <<< "${cands}")"
  printf 'config: project %s: %s names issue type "%s", which this project does not offer at that tier. It offers: %s (zero writes).' \
    "${key}" "${role}" "${name}" "${list}"
}

# role_duplicate_message <project_key> <role> <name> <level> — contract §6.4.
role_duplicate_message() {
  printf 'config: project %s: %s names "%s", which matches more than one issue type at level %s. The bridge will not choose one for you (zero writes).' \
    "$1" "$2" "$3" "$4"
}

# role_subtask_misuse_message <project_key> <role> <name> — contract §6.5.
role_subtask_misuse_message() {
  printf 'config: project %s: %s names "%s", which is a sub-task type in this project. A %s cannot be a sub-task (zero writes).' \
    "$1" "$2" "$3" "$2"
}

# role_task_misuse_message <project_key> <name> <candidates_json> — contract
# §6.6. An empty candidate list renders as the explicit words, never an
# empty string.
role_task_misuse_message() {
  local key="$1" name="$2" cands="$3"
  local list
  list="$(jq -r 'if length == 0 then "none — this project offers no sub-task type" else (map(.logical_name) | join(", ")) end' <<< "${cands}")"
  printf 'config: project %s: task names "%s", which is not a sub-task type in this project. Its sub-task types are: %s (zero writes).' \
    "${key}" "${name}" "${list}"
}

# role_ordering_message <project_key> <spec_name> <spec_level> <story_name> <story_level> — contract §6.7.
role_ordering_message() {
  printf 'config: project %s: specification names "%s" at level %s, which is not above story "%s" at level %s. A specification must sit above its stories (zero writes).' \
    "$1" "$2" "$3" "$4" "$5"
}

# role_validate <project_key> <roles_json> — contract §4 check 4 (ordering),
# over the RESOLVED roles map ({specification:{...}, story:{...}, task?:{...}}).
# Checks 2/3 (subtask flags) are enforced inside role_resolve itself, at the
# point of matching (see its header); checks 5/6 (parent-link, mandatory
# fields) remain hierarchy_mandatory_gate, unchanged, run separately. Prints
# the §6.7 message and returns 1 on an inverted ordering; prints nothing and
# returns 0 otherwise. Levels compared NUMERICALLY (`tonumber`) — the
# persisted hierarchy_level is a string (contract §4).
role_validate() {
  local key="$1" roles="$2"
  local spec_level story_level
  spec_level="$(jq -r '.specification.hierarchy_level // empty' <<< "${roles}")"
  story_level="$(jq -r '.story.hierarchy_level // empty' <<< "${roles}")"
  [[ -z "${spec_level}" || -z "${story_level}" ]] && return 0
  if ! jq -ne --argjson s "${spec_level}" --argjson c "${story_level}" '($s|tonumber) > ($c|tonumber)' > /dev/null 2>&1; then
    local spec_name story_name
    spec_name="$(jq -r '.specification.logical_name' <<< "${roles}")"
    story_name="$(jq -r '.story.logical_name' <<< "${roles}")"
    role_ordering_message "${key}" "${spec_name}" "${spec_level}" "${story_name}" "${story_level}"
    return 1
  fi
  return 0
}

# role_reconcile_ordering_message — the §8 re-validation twin of
# role_ordering_message, "reconcile:" prefixed since no config.yml write is
# in progress at that point.
role_reconcile_ordering_message() {
  printf 'reconcile: project %s: specification names "%s" at level %s, which is not above story "%s" at level %s. A specification must sit above its stories (zero writes).' \
    "$1" "$2" "$3" "$4" "$5"
}

# role_validate_reconcile <project_key> <roles_json> — contract §8 (T052):
# check 4 (ordering) re-run against the PERSISTED binding's roles at
# reconcile time, with no re-read of the project's metadata. Mirrors
# role_validate exactly except for the message prefix; an absent
# specification or story role is non-fatal (§3.4), matching role_validate.
role_validate_reconcile() {
  local key="$1" roles="$2"
  local spec_level story_level
  spec_level="$(jq -r '.specification.hierarchy_level // empty' <<< "${roles}")"
  story_level="$(jq -r '.story.hierarchy_level // empty' <<< "${roles}")"
  [[ -z "${spec_level}" || -z "${story_level}" ]] && return 0
  if ! jq -ne --argjson s "${spec_level}" --argjson c "${story_level}" '($s|tonumber) > ($c|tonumber)' > /dev/null 2>&1; then
    local spec_name story_name
    spec_name="$(jq -r '.specification.logical_name' <<< "${roles}")"
    story_name="$(jq -r '.story.logical_name' <<< "${roles}")"
    role_reconcile_ordering_message "${key}" "${spec_name}" "${spec_level}" "${story_name}" "${story_level}"
    return 1
  fi
  return 0
}

# role_supersession_note <project_key> <role> <declared_name> <local_name> —
# contract §7.2. One note, not a warning; the run succeeded.
role_supersession_note() {
  printf 'config: project %s: %s is declared as "%s" in config.yml; the local answer "%s" was superseded.' \
    "$1" "$2" "$3" "$4"
}

# role_promotion_note <project_key> <role> <name> — contract §7.3.
role_promotion_note() {
  printf 'config: project %s: commit this so your team mirrors identically —\n  hierarchy:\n    %s: "%s"' \
    "$1" "$2" "$3"
}

# role_task_recorded_note <project_key> <name> — contract §7.4.
role_task_recorded_note() {
  printf 'config: project %s: task is recorded as "%s" but is not mirrored yet — this release creates no sub-tasks.' \
    "$1" "$2"
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
