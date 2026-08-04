#!/usr/bin/env bash
# sink/jira/plan_apply.sh — The Jira write path (US11 gate; extended by US3).
#
# `apply_writes` executes an ordered action set against Jira. Its FIRST
# responsibility (US11, T049) is the mandatory pre-write privacy gate: every
# action's content payload is scanned through the BLOCK guard BEFORE any write is
# performed. A single blocked payload aborts the whole apply with EXIT_BLOCK (9)
# and ZERO writes — there is no gap through which a leak could reach Jira
# (Constitution IV, FR-052).
#
# US3 (T058) fleshes out plan_writes / the richer action set (create / update /
# transition / comment / link / label, estimation create-only). This module owns
# the guard-then-write ordering; the guard placement is invariant across that
# extension.
#
# Action shape: [ {method, url, body?}, ... ]. Only the content `body` is scanned
# (the request URL necessarily targets the real host and is not content).

[[ -n ${_JIRA_SINK_PLAN_APPLY:-} ]] && return 0
_JIRA_SINK_PLAN_APPLY=1

_plan_apply_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/privacy_guard.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/client.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/adf.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/ticket.sh" # jira_create_fields_base — the shared creation-fields builder (research R3)
# The sink may consume the neutral engine (the boundary only forbids engine->sink).
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../engine/drift.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../engine/idempotency.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../engine/story_marker.sh" # R5 steps 4/6 — mark `creating`, stamp + record per ticket
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../engine/task_marker.sh" # Phase 3, US1 — the task tier's own marker grammar, same seam
# shellcheck source=/dev/null
source "${_plan_apply_dir}/identity.sh" # stamp the identity marker on each created ticket (R5 step 6)

# plan_resolve_field_defaults <issue_types_json> <defaultable_fields_by_type_json>
# <recorded_json> <answers_json> — 011, research R2/R3, contract §3.1/§3.2,
# data-model.md §3: join the labels one project's `field_defaults` holds (and
# this run's `--field-value` answers) to the field ids the binding's
# `defaultable_fields` holds, for that project.
#
#   issue_types_json: [{logical_name, id}, ...] — resolves a Type NAME to an
#     issue-type id.
#   defaultable_fields_by_type_json: {type_id: [{logical_name, field_id, ...}]}
#     — resolves a Label to a field id, WITHIN the type its default was
#     recorded for (FR-018 — a label is never resolved against a different
#     type's fields).
#   recorded_json: the project's `field_defaults` entry (config_field_defaults_for's
#     output) — {ask, <Type>: {<Label>: <Value>}, ...}. The literal key
#     `ask` is never mistaken for an issue-type name.
#   answers_json: [{type, label, value}, ...] — this run's `--field-value`
#     answers, already scoped to this project by the caller.
#
# Precedence (contract §3.1): an answer wins over the recorded default for
# the same (type, label); a value with neither is absent from the result
# entirely (research R6 — absence is the off switch). An unresolvable type
# name or field label is reported in `unresolved`, never silently dropped
# (FR-008/FR-026).
#
# Prints one canonical object:
#   {"field_defaults": {type_id: {field_id: value}},
#    "field_default_sources": {type_id: {field_id: "team-config"|"operator-answer"}},
#    "unresolved": [{type, label, reason}, ...]}
plan_resolve_field_defaults() {
  local itypes="${1:-[]}" defaultable="${2:-{\}}" recorded="${3:-{\}}" answers="${4:-[]}"
  [[ -z "${itypes}" ]] && itypes='[]'
  [[ -z "${defaultable}" ]] && defaultable='{}'
  [[ -z "${recorded}" ]] && recorded='{}'
  [[ -z "${answers}" ]] && answers='[]'
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson itypes "${itypes}" --argjson df "${defaultable}" --argjson rec "${recorded}" --argjson ans "${answers}" '
    def typeId($name): (first($itypes[] | select(.logical_name == $name)) // null) | .id;
    def fieldIdFor($tid; $label): (first((($df[$tid]) // [])[] | select(.logical_name == $label)) // null) | .field_id;
    ( [ ($rec | to_entries[] | select(.key != "ask")) as $te
        | ($te.key) as $type | ($te.value | to_entries[]) as $fe
        | {type: $type, label: $fe.key, value: $fe.value, source: "team-config"} ]
      + [ $ans[] | {type: .type, label: .label, value: .value, source: "operator-answer"} ]
    ) as $entries
    | reduce $entries[] as $e
        ( {field_defaults: {}, field_default_sources: {}, unresolved: []}
        ; (typeId($e.type)) as $tid
          | if $tid == null then
              . + {unresolved: (.unresolved + [{type: $e.type, label: $e.label, reason: "unknown issue type"}])}
            else
              (fieldIdFor($tid; $e.label)) as $fid
              | if $fid == null then
                  . + {unresolved: (.unresolved + [{type: $e.type, label: $e.label, reason: "unknown field label"}])}
                else
                  .field_defaults[$tid][$fid] = $e.value
                  | .field_default_sources[$tid][$fid] = $e.source
                end
            end
        )
  ' | json_canonical
  # kcov-excl-stop
}

# plan_confirmation_fields <issue_types_json> <defaultable_fields_by_type_json>
# <field_defaults_by_type_json> <pending_type_ids_json> — 011, contract §3.3,
# data-model.md §4: the `fields` array of the consolidated question, scoped to
# the issue types that actually have a creation pending THIS run (never a
# type the project merely offers — that is what keeps §5.1/FR-028 true and
# what distinguishes a trigger from a mere offer).
#
# For each pending type, a field is included exactly when it is about to be
# **sent** (its field_id is a key of field_defaults_by_type_json[type], value
# taken from there) OR it is **required** and NOT about to be sent (included
# with recorded_value null — the case an answer, not a confirmation, is
# needed). A merely-defaultable, optional, unresolved field is never
# included — it is not a trigger (contract §3.3).
#
# An empty result means neither §3.3 trigger fires: the caller asks nothing.
#
# Prints the canonical `fields` array of data-model.md §4:
#   [{issue_type, label, recorded_value, required, allowed_values}, ...]
plan_confirmation_fields() {
  local itypes="${1:-[]}" defaultable="${2:-{\}}" defaults="${3:-{\}}" pending="${4:-[]}"
  [[ -z "${itypes}" ]] && itypes='[]'
  [[ -z "${defaultable}" ]] && defaultable='{}'
  [[ -z "${defaults}" ]] && defaults='{}'
  [[ -z "${pending}" ]] && pending='[]'
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson itypes "${itypes}" --argjson df "${defaultable}" --argjson fd "${defaults}" --argjson pending "${pending}" '
    def typeName($tid): (first($itypes[] | select(.id == $tid)) // null) | .logical_name // $tid;
    [ $pending[] as $tid
      | (($df[$tid]) // [])[] as $f
      | ($fd[$tid][$f.field_id] // null) as $sent
      | select($sent != null or $f.required == true)
      | { issue_type: typeName($tid), label: $f.logical_name,
          recorded_value: $sent, required: $f.required,
          allowed_values: ($f.allowed_values // []) } ]
  ' | json_canonical
  # kcov-excl-stop
}

# plan_writes <neutral-doc-json> <plan-context-json> — resolve the validated
# neutral document into an ordered write plan (US3, T058; Phase 5, US2,
# T072, R7). Each story becomes a create OR an update, with logical values
# resolved to ids (FR-017 priority by logical name) and the estimation
# written to the discovered field ON CREATE ONLY (FR-018 — never re-sent on
# update). The `--dry-run` report is exactly this plan (FR-033); no Jira
# mutation happens here. apply_writes_with_recognition performs it.
#
# plan-context carries the resolved facts the engine cannot know:
#   { base_url, story_type_id, priority_ids:{P1,P2,P3}, estimation_field_id|null,
#     tickets:{<local_id>: <existing-issue-key>},   (a local_id absent => create)
#     ticket_origins:{<local_id>: "bridge-created"|"human"},  (optional, US7)
#     ticket_descriptions:{<local_id>: <existing-adf-doc>},   (optional, US7)
#     ticket_parents:{<local_id>: <existing-parent-key>},   (optional, T109;
#       only entries whose child ALREADY carries a parent — a flat mirror
#       with none is Out of Scope, "no migration")
#     parent_type_id, parent_key|absent (a recognised parent's key),
#     parent_local_id (the parent marker's id, for a creation),
#     parent_current|absent ({summary, description}, for the zero-churn
#       comparison), parent_origin|absent ("bridge"|"human") }
# When a ticket carries a human origin and its existing description, the
# update's description is rendered through the managed-panel splice so the
# human-authored prose above the panel is preserved verbatim (FR-038);
# absent that context the whole description is bridge-owned.
#
# Returns {parent, stories} (data-model.md §6): `parent` is `null` when a
# recognised parent's bridge-owned content already matches (zero churn); a
# PUT when it differs; a POST — carrying `local_id` and `role:"parent"` —
# when no parent is yet recognised. Every STORY creation carries the literal
# placeholder `fields.parent.key = "<resolved at apply time>"`, resolved by
# apply_writes_with_recognition once the parent's real key is known (the
# parent is always performed first — contracts/parent-marker.md "Ordering
# within one run"). An update re-touches the parent link only when the
# child already carries a DIFFERENT one (T109); a child carrying none at
# all (a flat mirror from before this feature) is left alone — Out of
# Scope, "no migration".
plan_writes() {
  local doc="$1" ctx="$2"
  local base story_type estid project field_defaults
  base="$(jq -r '.base_url // ""' <<< "${ctx}")"
  story_type="$(jq -r '.story_type_id // ""' <<< "${ctx}")"
  estid="$(jq -r '.estimation_field_id // ""' <<< "${ctx}")"
  # 011, research R2: {type_id: {field_id: value}}. Absent ⇒ the merge below
  # is a no-op (FR-028) — jira_create_fields_base itself scopes it to the
  # type being created, so a default recorded for the OTHER written type
  # never reaches this payload (FR-018).
  field_defaults="$(jq -c '.field_defaults // {}' <<< "${ctx}")"
  # The payload's project comes from the neutral document's validated
  # routing.project_key — never from the plan context — so it cannot disagree
  # with the run summary's resolved project (research R2, FR-023).
  project="$(jq -r '.routing.project_key // ""' <<< "${doc}")"

  local stories="[]" n i
  n="$(jq '.stories | length' <<< "${doc}")"
  for ((i = 0; i < n; i++)); do
    local story sid title prio est ticket priority_id adf fields action base_fields
    story="$(jq -c ".stories[${i}]" <<< "${doc}")"
    sid="$(jq -r '.local_id' <<< "${story}")"
    title="$(jq -r '.title' <<< "${story}")"
    prio="$(jq -r '.priority_logical' <<< "${story}")"
    est="$(jq -c '.estimation // null' <<< "${story}")"
    ticket="$(jq -r --arg s "${sid}" '.tickets[$s] // ""' <<< "${ctx}")"
    priority_id="$(jq -r --arg p "${prio}" '.priority_ids[$p] // ""' <<< "${ctx}")"
    adf="$(adf_render_description "${story}")"

    if [[ -z "${ticket}" ]]; then
      # FR-024 assembly guard: refuse an incomplete creation BEFORE it is ever
      # emitted, rather than sending it for the destination service to reject.
      if [[ -z "${project}" || -z "${story_type}" ]]; then
        printf 'plan_writes: refusing to assemble a creation for "%s" with no project or issue type (zero writes)\n' "${sid}" >&2
        return 1
      fi
      # CREATE: the shared mandatory base (research R3, FR-025) + description +
      # priority + estimation (create-only) + the parent-key placeholder
      # (T072/T073), resolved once the parent's create response is read. A
      # bridge-created ticket owns its whole description (no delimiter, FR-040).
      base_fields="$(jira_create_fields_base "${project}" "${title}" "${story_type}" "${field_defaults}")"
      fields="$(jq -cn --argjson base "${base_fields}" --argjson d "${adf}" \
        '$base + {description:$d, parent:{key:"<resolved at apply time>"}}')"
      [[ -n "${priority_id}" ]] && fields="$(jq -c --arg pid "${priority_id}" '. + {priority:{id:$pid}}' <<< "${fields}")"
      if [[ -n "${estid}" && "${est}" != "null" ]]; then
        fields="$(jq -c --arg fid "${estid}" --argjson v "${est}" '. + {($fid): $v}' <<< "${fields}")"
      fi
      action="$(jq -cn --arg u "${base}/rest/api/3/issue" --argjson f "${fields}" --arg sid "${sid}" \
        '{method:"POST", url:$u, body:{fields:$f}, local_id:$sid, role:"story"}')"
    else
      # UPDATE: content + priority; the estimation is NEVER re-sent (FR-018).
      # The parent link is corrected only when the child already names a
      # DIFFERENT parent (T109, below) — never when it names none at all
      # (Out of Scope, "no migration"). On a human-origin ticket the
      # description is spliced into the managed panel so the human prose
      # above it survives (FR-038).
      local origin existing
      origin="$(jq -r --arg s "${sid}" '.ticket_origins[$s] // ""' <<< "${ctx}")"
      if [[ -n "${origin}" && "${origin}" != "bridge-created" ]]; then
        existing="$(jq -c --arg s "${sid}" '.ticket_descriptions[$s] // {}' <<< "${ctx}")"
        adf="$(adf_render_managed_description "${story}" "${origin}" "${existing}")"
      fi
      fields="$(jq -cn --arg t "${title}" --argjson d "${adf}" '{summary:$t, description:$d}')"
      [[ -n "${priority_id}" ]] && fields="$(jq -c --arg pid "${priority_id}" '. + {priority:{id:$pid}}' <<< "${fields}")"

      # Parent-link correction (T109): a child ALREADY linked to a parent
      # (never a flat mirror carrying none — that is Out of Scope, "no
      # migration") whose current parent disagrees with the resolved one is
      # re-linked. The resolved key is either already known (a recognised
      # parent) or, when the parent is being created this same run, filled
      # in later by the same "<resolved at apply time>" placeholder every
      # story creation already uses (apply_writes_with_recognition step 11).
      local cur_parent target_parent
      cur_parent="$(jq -r --arg s "${sid}" '.ticket_parents[$s] // ""' <<< "${ctx}")"
      if [[ -n "${cur_parent}" ]]; then
        target_parent="$(jq -r '.parent_key // ""' <<< "${ctx}")"
        if [[ -n "${target_parent}" ]]; then
          [[ "${cur_parent}" != "${target_parent}" ]] && fields="$(jq -c --arg k "${target_parent}" '. + {parent:{key:$k}}' <<< "${fields}")"
        else
          fields="$(jq -c '. + {parent:{key:"<resolved at apply time>"}}' <<< "${fields}")"
        fi
      fi

      action="$(jq -cn --arg u "${base}/rest/api/3/issue/${ticket}" --argjson f "${fields}" \
        '{method:"PUT", url:$u, body:{fields:$f}, role:"story"}')"
    fi
    stories="$(jq -c --argjson a "${action}" '. + [$a]' <<< "${stories}")"
  done

  local parent; parent="$(_plan_writes_parent "${doc}" "${ctx}" "${base}")"
  jq -cn --argjson p "${parent}" --argjson s "${stories}" '{parent:$p, stories:$s}' | json_canonical
}

# _plan_writes_parent <neutral-doc-json> <plan-context-json> <base-url> —
# the parent half of plan_writes' return shape (Phase 5, US2, T072/T076).
# `epic.local_id`/`epic.title`/`epic.description` come from the neutral
# document; the recognised-parent facts come from the plan context.
_plan_writes_parent() {
  local doc="$1" ctx="$2" base="$3"
  local parent_type project epic_title epic_local_id
  parent_type="$(jq -r '.parent_type_id // ""' <<< "${ctx}")"
  project="$(jq -r '.routing.project_key // ""' <<< "${doc}")"
  epic_title="$(jq -r '.epic.title // ""' <<< "${doc}")"
  epic_local_id="$(jq -r '.epic.local_id // ""' <<< "${doc}")"

  local epic_adf; epic_adf="$(adf_render_description "$(jq -c '.epic' <<< "${doc}")")"

  local parent_key; parent_key="$(jq -r '.parent_key // ""' <<< "${ctx}")"

  if [[ -z "${parent_key}" ]]; then
    # CREATE: no parent recognised yet. 011, research R2: same field_defaults
    # map the story branch reads, scoped to the parent type by the shared
    # builder itself.
    local base_fields fields field_defaults
    field_defaults="$(jq -c '.field_defaults // {}' <<< "${ctx}")"
    base_fields="$(jira_create_fields_base "${project}" "${epic_title}" "${parent_type}" "${field_defaults}")"
    fields="$(jq -cn --argjson base "${base_fields}" --argjson d "${epic_adf}" '$base + {description:$d}')"
    jq -cn --arg u "${base}/rest/api/3/issue" --argjson f "${fields}" --arg lid "${epic_local_id}" \
      '{method:"POST", url:$u, body:{fields:$f}, local_id:$lid, role:"parent"}'
    return 0
  fi

  # A recognised parent: compare its bridge-owned content before planning a
  # write (T076) — a human-origin parent's description is rendered through
  # the SAME managed-panel splice a human-origin story uses (FR-039's rule,
  # extended to the parent), so its prose above the panel survives, and is
  # then compared on its managed section alone.
  local current origin status
  current="$(jq -c '.parent_current // null' <<< "${ctx}")"
  origin="$(jq -r '.parent_origin // ""' <<< "${ctx}")"

  if [[ -n "${origin}" && "${origin}" != "bridge" ]]; then
    local existing; existing="$(jq -c '.description // {}' <<< "${current}")"
    epic_adf="$(adf_render_managed_description "$(jq -c '.epic' <<< "${doc}")" "${origin}" "${existing}")"
  fi
  local desired_fields; desired_fields="$(jq -cn --arg t "${epic_title}" --argjson d "${epic_adf}" '{summary:$t, description:$d}')"

  if [[ "${current}" == "null" ]]; then
    status="changed"
  elif [[ -n "${origin}" && "${origin}" != "bridge" ]]; then
    local desc_st other_st cur_desc new_desc cur_rest des_rest
    cur_desc="$(jq -c '.description // {}' <<< "${current}")"
    new_desc="$(jq -c '.description // {}' <<< "${desired_fields}")"
    desc_st="$(plan_managed_description_status "${cur_desc}" "${new_desc}")"
    cur_rest="$(jq -c 'del(.description)' <<< "${current}")"
    des_rest="$(jq -c 'del(.description)' <<< "${desired_fields}")"
    other_st="$(idempotency_field_status "${cur_rest}" "${des_rest}")"
    if [[ "${desc_st}" == "unchanged" && "${other_st}" == "unchanged" ]]; then status="unchanged"; else status="changed"; fi
  else
    status="$(idempotency_field_status "${current}" "${desired_fields}")"
  fi

  if [[ "${status}" == "unchanged" ]]; then
    printf 'null'
    return 0
  fi
  jq -cn --arg u "${base}/rest/api/3/issue/${parent_key}" --argjson f "${desired_fields}" \
    '{method:"PUT", url:$u, body:{fields:$f}, role:"parent"}'
}

# plan_managed_description_status <current-desc-json> <new-desc-json>
#   FR-039: decide description churn on the managed section ALONE. Both descriptions
#   are split at the panel marker and only their managed portions are compared, so a
#   human edit to the prose above the panel never counts as churn. Echoes
#   "unchanged" | "changed".
plan_managed_description_status() {
  local current="$1" new="$2" marker cm nm
  marker="$(adf_managed_marker)"
  cm="$(jq -c '.content // []' <<< "${current}" | managed_section_panel_split "${marker}" | jq -c '.managed')"
  nm="$(jq -c '.content // []' <<< "${new}" | managed_section_panel_split "${marker}" | jq -c '.managed')"
  if [[ "$(json_canonical <<< "${cm}")" == "$(json_canonical <<< "${nm}")" ]]; then
    printf 'unchanged'
  else
    printf 'changed'
  fi
}

# plan_writes_tasks <neutral-doc-json> <plan-context-json> — resolve the
# task tier of the validated neutral document into an ordered array of
# write actions (Phase 3, US1, T038; contract §4). Iterates
# `stories[].tasks[]`: a task is never planned under anything but its own
# story (FR-007) because that is the only place it is nested.
#
# plan-context additionally carries:
#   { task_type_id, tickets:{<task local_id>: <existing key>},
#     ticket_current:{<task local_id>: {summary, description}},
#     field_defaults:{type_id:{field_id:value}} }
#
# Returns the `tasks` array of data-model.md §4: a CREATE for a task with no
# recorded ticket, carrying `local_id`, `parent_local_id` (its story's own
# local_id — read directly off the document's nesting) and the
# `<resolved at apply time>` parent placeholder; a PUT carrying only the
# fields that differ for a task whose content changed (FR-019), with a
# `warning` naming the ticket and the divergent field(s) attached to that
# same action (FR-020); nothing for an unchanged task (FR-015).
plan_writes_tasks() {
  local doc="$1" ctx="$2"
  local base task_type project field_defaults
  base="$(jq -r '.base_url // ""' <<< "${ctx}")"
  task_type="$(jq -r '.task_type_id // ""' <<< "${ctx}")"
  field_defaults="$(jq -c '.field_defaults // {}' <<< "${ctx}")"
  project="$(jq -r '.routing.project_key // ""' <<< "${doc}")"

  local actions="[]" sn si
  sn="$(jq '.stories | length' <<< "${doc}")"
  for ((si = 0; si < sn; si++)); do
    local story story_local_id tn ti
    story="$(jq -c ".stories[${si}]" <<< "${doc}")"
    story_local_id="$(jq -r '.local_id' <<< "${story}")"
    tn="$(jq '(.tasks // []) | length' <<< "${story}")"
    for ((ti = 0; ti < tn; ti++)); do
      local task tid title ticket summary adf fields action base_fields
      task="$(jq -c ".tasks[${ti}]" <<< "${story}")"
      tid="$(jq -r '.local_id' <<< "${task}")"
      title="$(jq -r '.title' <<< "${task}")"
      ticket="$(jq -r --arg t "${tid}" '.tickets[$t] // ""' <<< "${ctx}")"
      summary="$(adf_task_summary "${title}")"
      adf="$(adf_render_task_description "${task}")"

      if [[ -z "${ticket}" ]]; then
        if [[ -z "${project}" || -z "${task_type}" ]]; then
          printf 'plan_writes_tasks: refusing to assemble a creation for "%s" with no project or issue type (zero writes)\n' "${tid}" >&2
          return 1
        fi
        base_fields="$(jira_create_fields_base "${project}" "${summary}" "${task_type}" "${field_defaults}")"
        fields="$(jq -cn --argjson base "${base_fields}" --argjson d "${adf}" \
          '$base + {description:$d, parent:{key:"<resolved at apply time>"}}')"
        action="$(jq -cn --arg u "${base}/rest/api/3/issue" --argjson f "${fields}" \
          --arg lid "${tid}" --arg pid "${story_local_id}" \
          '{method:"POST", url:$u, body:{fields:$f}, local_id:$lid, parent_local_id:$pid, role:"task"}')"
      else
        local current desired st
        current="$(jq -c --arg t "${tid}" '.ticket_current[$t] // null' <<< "${ctx}")"
        desired="$(jq -cn --arg s "${summary}" --argjson d "${adf}" '{summary:$s, description:$d}')"
        if [[ "${current}" == "null" ]]; then
          st="changed"
        else
          st="$(idempotency_field_status "${current}" "${desired}")"
        fi
        [[ "${st}" == "unchanged" ]] && continue

        # FR-019: only the fields that differ are written. FR-020: the same
        # comparison names the divergent field(s) in a warning before the
        # overwrite — current == null means no prior state was read at all,
        # so nothing narrower than the full desired set can be sent, and
        # there is no known field to name.
        local filtered diverged warning=""
        if [[ "${current}" == "null" ]]; then
          filtered="${desired}"
        else
          filtered="$(jq -cn --argjson cur "${current}" --argjson des "${desired}" \
            '[ $des | to_entries[] | select(.value != ($cur[.key])) ] | from_entries')"
          diverged="$(jq -rn --argjson cur "${current}" --argjson des "${desired}" \
            '[ $des | to_entries[] | select(.value != ($cur[.key])) | .key ] | join(", ")')"
          warning="${ticket} diverges from the specification on \"${diverged}\"; only the differing field(s) will be written"
        fi

        if [[ -n "${warning}" ]]; then
          action="$(jq -cn --arg u "${base}/rest/api/3/issue/${ticket}" --argjson f "${filtered}" --arg w "${warning}" \
            '{method:"PUT", url:$u, body:{fields:$f}, role:"task", warning:$w}')"
        else
          action="$(jq -cn --arg u "${base}/rest/api/3/issue/${ticket}" --argjson f "${filtered}" \
            '{method:"PUT", url:$u, body:{fields:$f}, role:"task"}')"
        fi
      fi
      actions="$(jq -c --argjson a "${action}" '. + [$a]' <<< "${actions}")"
    done
  done
  json_canonical <<< "${actions}"
}

# _plan_transition_action <base_url> <key> <transition_id> <blockers-json> <label>
#   The single transition-POST emission site (012, T091), shared by
#   plan_lifecycle (story tier) and plan_lifecycle_tasks (task tier) rather
#   than each building its own. Returns {action, note} — note is empty when
#   the ticket carries no open blocking link.
_plan_transition_action() {
  local base="$1" key="$2" transition_id="$3" blockers="$4" label="$5"
  local taction
  taction="$(jq -cn --arg u "${base}/rest/api/3/issue/${key}/transitions" --arg tid "${transition_id}" \
    '{method:"POST", url:$u, body:{transition:{id:$tid}}}')"
  local note=""
  local bcount; bcount="$(jq 'length' <<< "${blockers}")"
  if [[ "${bcount}" -gt 0 ]]; then
    local blist
    blist="$(jq -r 'join(", ")' <<< "${blockers}")"
    note="transition of \"${label}\" proceeds with open blocking links (${blist}); human-created links are left unchanged"
  fi
  jq -cn --argjson a "${taction}" --arg n "${note}" '{action:$a, note:(if $n == "" then null else $n end)}'
}

# plan_lifecycle <content-actions-json> <neutral-doc-json> <lifecycle-ctx-json>
#   Fold the US6 lifecycle-safety rules over the planned content actions and emit
#   the final action set plus the human-facing warnings/notes. PURE: no Jira reads
#   or writes happen here; the current Jira facts (status, its classification,
#   Flagged marker, open blockers, the transition id) arrive in the lifecycle
#   context — the seam the config/discovery integration fills from a fail-closed
#   read. content-actions[i] corresponds to neutral-doc.stories[i] (plan_writes
#   emits one content action per story, in order).
#
# lifecycle-ctx: { on_drift, base_url, order:[status,...],
#   tickets:{ <local_id>: { key, current:{fields...}, status, category, target,
#                           transition_id, flagged, blockers:[...] } } }
#
# Rules applied per story:
#   - Zero churn (FR-030): an UPDATE whose desired fields already match the
#     ticket's `current` fields is dropped — no content write.
#   - Drift (FR-031/034/035): the drift engine decides the transition. `withhold`
#     suppresses the transition (content still reconciles); `halt` stops every
#     write to the ticket and surfaces the remediations; `transition` emits the
#     transition action. --on-drift=proceed authorises a backward pull.
#   - Flagged (FR-036): a flagged ticket has its transition withheld and the flag
#     surfaced; the bridge never sets or removes the flag (no flag write is emitted).
#   - Human links (FR-037): the bridge emits no link mutation, so human links are
#     never modified; advancing past open blockers adds an info note, not a block.
# Returns { actions, warnings, notes } (canonical).
plan_lifecycle() {
  local actions="$1" doc="$2" lc="$3"
  local on_drift order n i
  on_drift="$(jq -r '.on_drift // "abort"' <<< "${lc}")"
  order="$(jq -c '.order // []' <<< "${lc}")"
  n="$(jq '.stories | length' <<< "${doc}")"

  local kept="[]" warns="[]" notes="[]"
  for ((i = 0; i < n; i++)); do
    local sid action method tk
    sid="$(jq -r ".stories[${i}].local_id" <<< "${doc}")"
    action="$(jq -c ".[${i}] // null" <<< "${actions}")"
    [[ "${action}" == "null" ]] && continue
    method="$(jq -r '.method' <<< "${action}")"
    tk="$(jq -c --arg s "${sid}" '.tickets[$s] // {}' <<< "${lc}")"

    local drop_content="false" do_transition="false"
    # --- Zero churn: drop an unchanged UPDATE ---------------------------------
    if [[ "${method}" == "PUT" ]]; then
      local current
      current="$(jq -c '.current // null' <<< "${tk}")"
      if [[ "${current}" != "null" ]]; then
        local desired origin st
        desired="$(jq -c '.body.fields' <<< "${action}")"
        origin="$(jq -r '.origin // ""' <<< "${tk}")"
        if [[ -n "${origin}" && "${origin}" != "bridge-created" ]]; then
          # FR-039: on a human-origin ticket the description diff is computed on the
          # managed section alone; the other fields compare normally.
          local desc_st other_st cur_desc new_desc cur_rest des_rest
          cur_desc="$(jq -c '.description // {}' <<< "${current}")"
          new_desc="$(jq -c '.description // {}' <<< "${desired}")"
          desc_st="$(plan_managed_description_status "${cur_desc}" "${new_desc}")"
          cur_rest="$(jq -c 'del(.description)' <<< "${current}")"
          des_rest="$(jq -c 'del(.description)' <<< "${desired}")"
          other_st="$(idempotency_field_status "${cur_rest}" "${des_rest}")"
          [[ "${desc_st}" == "unchanged" && "${other_st}" == "unchanged" ]] && drop_content="true"
        else
          st="$(idempotency_field_status "${current}" "${desired}")"
          [[ "${st}" == "unchanged" ]] && drop_content="true"
        fi
      fi
    fi

    # --- Drift / Flagged: decide the transition -------------------------------
    local status target category flagged transition_id key
    status="$(jq -r '.status // ""' <<< "${tk}")"
    target="$(jq -r '.target // ""' <<< "${tk}")"
    category="$(jq -r '.category // "unknown"' <<< "${tk}")"
    flagged="$(jq -r '.flagged // false' <<< "${tk}")"
    transition_id="$(jq -r '.transition_id // ""' <<< "${tk}")"
    key="$(jq -r '.key // ""' <<< "${tk}")"

    if [[ -n "${status}" && -n "${target}" && "${status}" != "${target}" ]]; then
      if [[ "${flagged}" == "true" ]]; then
        warns="$(jq -c --arg w "ticket \"${sid}\" carries the Flagged (impediment) marker; its transition is withheld and the flag is left untouched" '. + [$w]' <<< "${warns}")"
      else
        local di dec d cw dwarns
        di="$(jq -cn --arg cs "${status}" --arg cc "${category}" --arg ts "${target}" --argjson o "${order}" --arg od "${on_drift}" \
          '{current_status:$cs, current_category:$cc, target_status:$ts, order:$o, on_drift:$od}')"
        dec="$(drift_evaluate "${di}")"
        d="$(jq -r '.decision' <<< "${dec}")"
        cw="$(jq -r '.content_writes' <<< "${dec}")"
        dwarns="$(jq -c '.warnings' <<< "${dec}")"
        warns="$(jq -c --argjson dw "${dwarns}" '. + $dw' <<< "${warns}")"
        [[ "${cw}" == "false" ]] && drop_content="true"
        [[ "${d}" == "transition" ]] && do_transition="true"
      fi
    fi

    [[ "${drop_content}" == "false" ]] && kept="$(jq -c --argjson a "${action}" '. + [$a]' <<< "${kept}")"

    if [[ "${do_transition}" == "true" && -n "${transition_id}" && -n "${key}" ]]; then
      local base tres note
      base="$(jq -r '.base_url // ""' <<< "${lc}")"
      tres="$(_plan_transition_action "${base}" "${key}" "${transition_id}" "$(jq -c '.blockers // []' <<< "${tk}")" "${sid}")"
      kept="$(jq -c --argjson a "$(jq -c '.action' <<< "${tres}")" '. + [$a]' <<< "${kept}")"
      note="$(jq -r '.note // empty' <<< "${tres}")"
      [[ -n "${note}" ]] && notes="$(jq -c --arg n "${note}" '. + [$n]' <<< "${notes}")"
    fi
  done

  jq -cn --argjson a "${kept}" --argjson w "${warns}" --argjson no "${notes}" \
    '{actions:$a, warnings:$w, notes:$no}' | json_canonical
}

# plan_lifecycle_tasks <content-actions-json> <completion-ctx-json>
#   The task tier's own completion pass (012, US5, contract §6) — a sibling of
#   plan_lifecycle, never routed through it: task completion is a binary
#   done/not-done model, not a named multi-status order, and every divergence
#   is reported by ticket key, never by a status name (FR-030/FR-032). PURE:
#   this function decides nothing about Jira — the candidates, the chosen
#   transition (if any) and the withheld field arrive already resolved by the
#   caller's discovery_task_transition read (research R5). It only ever ADDS
#   transition actions to content-actions; content zero-churn is
#   plan_writes_tasks's own concern (FR-015), so a reworded-and-checked task
#   in the same run keeps both its content PUT and its transition POST,
#   neither suppressing the other (Edge Cases).
#
# completion-ctx: { base_url, tasks:{ <task local_id>: {
#   key, blockers:[...],
#   already_done_diverged: bool,
#   forward: {transition_id, candidates:[{id,name}], withheld_field} | null,
#   backward: {transition_id, candidates:[{id,name}], withheld_field} | null
# } } }. `forward` is present only for a checked task whose sub-task is not
# already done-category (FR-031 — an unchanged re-run supplies no entry at
# all, so this loop issues nothing for it). `backward` is present only when
# the caller already resolved the operator's backward-pull authorisation
# (FR-032) — this function never consults --on-drift itself.
#
# Returns { actions, warnings, notes } (canonical).
plan_lifecycle_tasks() {
  local actions="$1" cc="$2"
  local base; base="$(jq -r '.base_url // ""' <<< "${cc}")"

  local kept="${actions}" warns="[]" notes="[]"
  local ids; ids="$(jq -r '.tasks | keys[]' <<< "${cc}")"
  while IFS= read -r tid; do
    [[ -z "${tid}" ]] && continue
    local t key blockers
    t="$(jq -c --arg t "${tid}" '.tasks[$t]' <<< "${cc}")"
    key="$(jq -r '.key // ""' <<< "${t}")"
    [[ -z "${key}" ]] && continue
    blockers="$(jq -c '.blockers // []' <<< "${t}")"

    local diverged; diverged="$(jq -r '.already_done_diverged // false' <<< "${t}")"
    if [[ "${diverged}" == "true" ]]; then
      warns="$(jq -c --arg w "sub-task ${key} is already at a done status while its task is unchecked in tasks.md; it is left as is unless this run is authorised to pull it backward" \
        '. + [$w]' <<< "${warns}")"
    fi

    local fwd; fwd="$(jq -c '.forward // null' <<< "${t}")"
    if [[ "${fwd}" != "null" ]]; then
      local tid_f cands n withheld
      tid_f="$(jq -r '.transition_id // ""' <<< "${fwd}")"
      cands="$(jq -c '.candidates // []' <<< "${fwd}")"
      n="$(jq 'length' <<< "${cands}")"
      withheld="$(jq -c '.withheld_field // null' <<< "${fwd}")"
      if [[ -n "${tid_f}" ]]; then
        local tres note
        tres="$(_plan_transition_action "${base}" "${key}" "${tid_f}" "${blockers}" "${key}")"
        kept="$(jq -c --argjson a "$(jq -c '.action' <<< "${tres}")" '. + [$a]' <<< "${kept}")"
        note="$(jq -r '.note // empty' <<< "${tres}")"
        [[ -n "${note}" ]] && notes="$(jq -c --arg n "${note}" '. + [$n]' <<< "${notes}")"
      elif [[ "${withheld}" != "null" ]]; then
        local fname
        fname="$(jq -r '.logical_name' <<< "${withheld}")"
        warns="$(jq -c --arg w "sub-task ${key} reaches a done status only through a transition that requires \"${fname}\"; the transition is withheld — set it directly in Jira, or record a default for that field" \
          '. + [$w]' <<< "${warns}")"
      elif [[ "${n}" -eq 0 ]]; then
        warns="$(jq -c --arg w "sub-task ${key} has no transition to a status this project classifies as done; nothing was transitioned" \
          '. + [$w]' <<< "${warns}")"
      else
        local names
        names="$(jq -r '[.[].name] | join(", ")' <<< "${cands}")"
        warns="$(jq -c --arg w "sub-task ${key} offers more than one transition to a status this project classifies as done (${names}); the bridge does not choose one" \
          '. + [$w]' <<< "${warns}")"
      fi
    fi

    local bwd; bwd="$(jq -c '.backward // null' <<< "${t}")"
    if [[ "${bwd}" != "null" ]]; then
      local tid_b
      tid_b="$(jq -r '.transition_id // ""' <<< "${bwd}")"
      if [[ -n "${tid_b}" ]]; then
        local tres note
        tres="$(_plan_transition_action "${base}" "${key}" "${tid_b}" "${blockers}" "${key}")"
        kept="$(jq -c --argjson a "$(jq -c '.action' <<< "${tres}")" '. + [$a]' <<< "${kept}")"
        note="$(jq -r '.note // empty' <<< "${tres}")"
        [[ -n "${note}" ]] && notes="$(jq -c --arg n "${note}" '. + [$n]' <<< "${notes}")"
      fi
    fi
  done <<< "${ids}"

  jq -cn --argjson a "${kept}" --argjson w "${warns}" --argjson no "${notes}" \
    '{actions:$a, warnings:$w, notes:$no}' | json_canonical
}

# _apply_known_coords <extra-json> — the known-coordinate set the guard checks:
# the real site host derived from SPEC_KIT_JIRA_BASE_URL plus any caller extras.
_apply_known_coords() {
  local extra="${1:-[]}" base="${SPEC_KIT_JIRA_BASE_URL:-}" host=""
  host="$(sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#:[0-9]+$##' <<< "${base}")"
  jq -cn --arg h "${host}" --argjson e "${extra}" \
    '($e + (if $h == "" then [] else [$h] end)) | unique'
}

# _plan_apply_report_rejection <method> <url> <action-json> <defaultable-by-type-json>
# — 011, contract §3.7, FR-019: when a CREATE (POST .../issue) fails with a 400
# whose Jira error body names a field this run defaulted, print the human
# translation to stderr (mirrors privacy_guard_scan's own self-printing
# pattern) before the caller returns fail-closed. A rejection on any other
# field, method, or status is left to the existing generic failure path —
# nothing is printed here for it.
_plan_apply_report_rejection() {
  local method="$1" url="$2" action="$3" defaultable_by_type="${4:-{\}}"
  [[ "${method}" == "POST" && "${url}" == */issue && "${JIRA_LAST_STATUS:-}" == "400" ]] || return 0
  local msg
  msg="$(ticket_field_rejection_message "${defaultable_by_type}" "${action}" "${JIRA_LAST_ERROR_BODY:-{\}}")"
  [[ -n "${msg}" ]] && printf '%s\n' "${msg}" >&2
}

# apply_writes <actions-json> [extra-known-coords-json] — guard every payload,
# then perform the writes in order. Returns EXIT_BLOCK (9) with zero writes if any
# payload is blocked; otherwise returns the worst (highest) transport exit code.
apply_writes() {
  local actions="$1" extra="${2:-[]}"
  local coords allow
  coords="$(_apply_known_coords "${extra}")"
  # The allowlist (US12, FR-053) neutralises allowlisted Confluence links/domains so
  # they never false-block; it is empty unless the caller supplies one out of band.
  allow="${SPEC_KIT_JIRA_ALLOWLIST:-[]}"

  local n
  n="$(jq 'length' <<< "${actions}")"

  # (1) Pre-write gate — scan every content payload before writing anything.
  local i body
  for ((i = 0; i < n; i++)); do
    body="$(jq -c ".[${i}].body // {}" <<< "${actions}")"
    privacy_guard_scan "${body}" "${coords}" "${allow}" || return $?
  done

  # (2) Write pass — all payloads cleared; perform each write in order. A
  # fail-closed transport result (exit >= 2: fail_closed or auth) ABORTS the
  # remaining writes for this spec and is returned verbatim — no further mutation
  # is attempted once a read/write is unreliable (FR-032, monotonic escalation).
  local worst=0 method url rc
  for ((i = 0; i < n; i++)); do
    method="$(jq -r ".[${i}].method" <<< "${actions}")"
    url="$(jq -r ".[${i}].url" <<< "${actions}")"
    body="$(jq -c ".[${i}].body // empty" <<< "${actions}")"
    if [[ -n "${body}" ]]; then
      jira_request "${method}" "${url}" "${body}" > /dev/null
    else
      jira_request "${method}" "${url}" > /dev/null
    fi
    rc=$?
    ((rc > worst)) && worst=${rc}
    ((rc >= 2)) && return "${worst}"
  done
  return "${worst}"
}

# apply_writes_with_recognition <plan-json> <spec-ref-json> <spec-file>
#   [known-parent-key] [extra-known-coords-json] [defaultable-fields-by-type-json]
#   [tasks-actions-json] [tasks-file] [known-story-keys-json]
#   Mirror of apply_writes's guard-then-write discipline (US11), extended
#   with R5 steps 4 and 6, and with Phase 5/US2's parent-first ordering
#   (contracts/parent-marker.md "Ordering within one run", steps 8-11).
#   plan-json is plan_writes' {parent, stories} shape.
#
#   The parent (when present) is performed FIRST; its response key is read
#   before any story is written, and every story creation's
#   fields.parent.key placeholder ("<resolved at apply time>") is resolved
#   to that key -- the just-created key, or known-parent-key (the plan
#   context's already-known parent_key) when the parent was unchanged or
#   updated rather than created. Every story whose action is a creation is
#   marked `creating` in spec-file, in the SAME splice that marks the
#   parent `creating` (step 9); then, for each ticket actually created
#   (parent or story), its identity marker is stamped and its `creating`
#   mark is replaced with the recorded key IN spec-file -- per ticket,
#   IMMEDIATELY, never batched (step 6/11): a run interrupted between one
#   create's response and its record leaves every OTHER story's identifier
#   untouched and creatable by the next run.
#
#   defaultable-fields-by-type-json (011, contract §3.7, FR-019): the
#   binding's defaultable_fields map, {type_id: [{logical_name, field_id,
#   ...}]}. Omitted or empty ⇒ a rejected creation falls through to the
#   existing generic failure path unchanged (FR-028).
#
#   tasks-actions-json (Phase 3, US1, T040; contract §5): plan_writes_tasks'
#   output — {method, url, body, local_id?, parent_local_id?, role:"task"}
#   per action. Every task body joins the SAME pre-write guard sweep as the
#   parent and every story, before the first write of the run (FR-025).
#   Tasks are applied LAST, after every story (contract "Order within one
#   run: epic -> stories -> tasks"). Each task creation's parent-key
#   placeholder is resolved from known-story-keys-json (the caller's
#   already-recognised story keys — the plan context's own `tickets` map)
#   merged with the keys created earlier in THIS run, so a story created in
#   the same run parents its tasks without a second reconcile (Edge Cases).
#   tasks-file is where the task marker is spliced (tasks.md — the SECOND
#   tracked file the bridge writes into), separate from spec-file; omitted
#   or empty means no task action is applied and no file is touched, which
#   is what keeps a run with no `task` role byte-for-byte identical
#   (FR-011). Each created sub-task's key is recorded into tasks-file
#   IMMEDIATELY, never batched (FR-013), on the same terms as a story.
apply_writes_with_recognition() {
  local plan="$1" spec_ref="$2" spec_file="$3" known_parent_key="${4:-}" extra="${5:-[]}"
  local defaultable_by_type="${6:-}"
  # NOT "${9:-{}}" inline: bash's brace-matching for a `${...}` parameter
  # expansion misparses a `{}`-shaped default value, corrupting how the
  # REST OF THE FUNCTION is parsed (the exact, previously-reproduced
  # failure documented on _reconcile_plan_context). Default it in a
  # separate, brace-free statement instead.
  local tasks_actions="${7:-[]}" tasks_file="${8:-}" known_story_keys="${9:-}"
  [[ -z "${defaultable_by_type}" ]] && defaultable_by_type='{}'
  [[ -z "${tasks_actions}" ]] && tasks_actions='[]'
  [[ -z "${known_story_keys}" ]] && known_story_keys='{}'
  local coords allow
  coords="$(_apply_known_coords "${extra}")"
  allow="${SPEC_KIT_JIRA_ALLOWLIST:-[]}"

  local parent stories
  parent="$(jq -c '.parent' <<< "${plan}")"
  stories="$(jq -c '.stories' <<< "${plan}")"

  # (1) Pre-write gate -- scan every payload, parent then stories then
  # tasks, before writing anything.
  local body
  if [[ "${parent}" != "null" ]]; then
    body="$(jq -c '.body // {}' <<< "${parent}")"
    privacy_guard_scan "${body}" "${coords}" "${allow}" || return $?
  fi
  local n i
  n="$(jq 'length' <<< "${stories}")"
  for ((i = 0; i < n; i++)); do
    body="$(jq -c ".[${i}].body // {}" <<< "${stories}")"
    privacy_guard_scan "${body}" "${coords}" "${allow}" || return $?
  done
  local tn
  tn="$(jq 'length' <<< "${tasks_actions}")"
  for ((i = 0; i < tn; i++)); do
    body="$(jq -c ".[${i}].body // {}" <<< "${tasks_actions}")"
    privacy_guard_scan "${body}" "${coords}" "${allow}" || return $?
  done

  # (2) R5 step 4 / contract step 9 -- mark the parent (when it is a
  # creation) and every planned story creation `creating`, in ONE splice.
  local current new_content parent_local_id=""
  current="$(cat "${spec_file}" 2> /dev/null; printf x)"; current="${current%x}"
  new_content="${current}"
  if [[ "${parent}" != "null" ]] && [[ "$(jq -r '.method' <<< "${parent}")" == "POST" ]]; then
    parent_local_id="$(jq -r '.local_id // ""' <<< "${parent}")"
    if [[ -n "${parent_local_id}" ]]; then
      new_content="$(printf '%s' "${new_content}" | spec_marker_mark_creating "${parent_local_id}"; printf x)"; new_content="${new_content%x}"
    fi
  fi
  local creating_ids
  creating_ids="$(jq -c '[.[] | select(.method=="POST" and (.url|endswith("/issue")) and (.local_id // "") != "") | .local_id]' <<< "${stories}")"
  if [[ "$(jq 'length' <<< "${creating_ids}")" -gt 0 ]]; then
    new_content="$(printf '%s' "${new_content}" | story_marker_mark_creating "${creating_ids}"; printf x)"; new_content="${new_content%x}"
  fi
  if [[ "${new_content}" != "${current}" ]]; then
    marker_splice_write_file "${spec_file}" "${new_content}" > /dev/null
  fi

  # (2b) Same step, for the task tier's OWN file: mark every planned task
  # creation `creating` in tasks-file. A no-op when tasks-file is empty
  # (no `task` role declared).
  if [[ -n "${tasks_file}" ]]; then
    local tcurrent tnew_content task_creating_ids
    tcurrent="$(cat "${tasks_file}" 2> /dev/null; printf x)"; tcurrent="${tcurrent%x}"
    tnew_content="${tcurrent}"
    task_creating_ids="$(jq -c '[.[] | select(.method=="POST" and (.url|endswith("/issue")) and (.local_id // "") != "") | .local_id]' <<< "${tasks_actions}")"
    if [[ "$(jq 'length' <<< "${task_creating_ids}")" -gt 0 ]]; then
      tnew_content="$(printf '%s' "${tnew_content}" | task_marker_mark_creating "${task_creating_ids}"; printf x)"; tnew_content="${tnew_content%x}"
    fi
    if [[ "${tnew_content}" != "${tcurrent}" ]]; then
      marker_splice_write_file "${tasks_file}" "${tnew_content}" > /dev/null
    fi
  fi

  # (3) Write pass -- the parent FIRST (step 10): its response key is read
  # before the first story action is scanned for writing.
  local worst=0 method url rc resp parent_key="${known_parent_key}"
  if [[ "${parent}" != "null" ]]; then
    method="$(jq -r '.method' <<< "${parent}")"
    url="$(jq -r '.url' <<< "${parent}")"
    body="$(jq -c '.body // empty' <<< "${parent}")"
    resp="$(mktemp)"
    if [[ -n "${body}" ]]; then jira_request "${method}" "${url}" "${body}" > "${resp}"; else jira_request "${method}" "${url}" > "${resp}"; fi
    rc=$?
    ((rc > worst)) && worst=${rc}
    if ((rc >= 2)); then
      _plan_apply_report_rejection "${method}" "${url}" "${parent}" "${defaultable_by_type}"
      rm -f "${resp}"
      return "${worst}"
    fi
    if [[ "${method}" == "POST" ]]; then
      parent_key="$(jq -r '.key // empty' < "${resp}")"
      if [[ -n "${parent_key}" && -n "${parent_local_id}" ]]; then
        identity_write "${parent_key}" "${spec_ref}" "bridge" "" "parent" || true
        local cur new
        cur="$(cat "${spec_file}" 2> /dev/null; printf x)"; cur="${cur%x}"
        new="$(printf '%s' "${cur}" | spec_marker_record_ticket "${parent_local_id}" "${parent_key}"; printf x)"; new="${new%x}"
        marker_splice_write_file "${spec_file}" "${new}" > /dev/null
      fi
    fi
    rm -f "${resp}"
  fi

  # (4) Story writes (step 11) -- the parent-key placeholder resolved to
  # the key just created, or the already-known parent_key when the parent
  # was recognised (unchanged or updated) rather than created. Seeded from
  # known_story_keys (the plan context's already-recognised story keys) so
  # a task's own parent resolution (step 5) can find a story that was
  # recognised rather than created this run.
  local story_key_map="${known_story_keys}"
  n="$(jq 'length' <<< "${stories}")"
  for ((i = 0; i < n; i++)); do
    local action
    action="$(jq -c ".[${i}]" <<< "${stories}")"
    if [[ -n "${parent_key}" ]]; then
      action="$(jq -c --arg k "${parent_key}" \
        'if (.body.fields.parent.key? == "<resolved at apply time>") then .body.fields.parent.key = $k else . end' \
        <<< "${action}")"
    fi
    method="$(jq -r '.method' <<< "${action}")"
    url="$(jq -r '.url' <<< "${action}")"
    body="$(jq -c '.body // empty' <<< "${action}")"
    resp="$(mktemp)"
    if [[ -n "${body}" ]]; then
      jira_request "${method}" "${url}" "${body}" > "${resp}"
    else
      jira_request "${method}" "${url}" > "${resp}"
    fi
    rc=$?
    ((rc > worst)) && worst=${rc}
    if ((rc >= 2)); then
      _plan_apply_report_rejection "${method}" "${url}" "${action}" "${defaultable_by_type}"
      rm -f "${resp}"
      return "${worst}"
    fi

    if [[ "${method}" == "POST" && "${url}" == */issue ]]; then
      local key local_id
      key="$(jq -r '.key // empty' < "${resp}")"
      local_id="$(jq -r '.local_id // empty' <<< "${action}")"
      if [[ -n "${key}" && -n "${local_id}" ]]; then
        identity_write "${key}" "${spec_ref}" "bridge" "${local_id}" "story" || true
        local cur new
        cur="$(cat "${spec_file}" 2> /dev/null; printf x)"; cur="${cur%x}"
        new="$(printf '%s' "${cur}" | story_marker_record_ticket "${local_id}" "${key}"; printf x)"; new="${new%x}"
        marker_splice_write_file "${spec_file}" "${new}" > /dev/null
        story_key_map="$(jq -c --arg id "${local_id}" --arg k "${key}" '. + {($id): $k}' <<< "${story_key_map}")"
      fi
    fi
    rm -f "${resp}"
  done

  # (5) Task writes (Phase 3, US1, T040; contract §5) -- LAST, after every
  # story. Each creation's parent-key placeholder resolves from
  # story_key_map, which by now carries both keys created this run and the
  # caller's already-known ones. A task attributed to a story whose issue
  # does not exist yet and is not being created this run has no entry in
  # story_key_map; it is left unresolved and its write is skipped, exactly
  # as contract §4 rule 5 requires — it reconciles on the next run once the
  # story exists.
  tn="$(jq 'length' <<< "${tasks_actions}")"
  for ((i = 0; i < tn; i++)); do
    local taction tparent_local_id tparent_key
    taction="$(jq -c ".[${i}]" <<< "${tasks_actions}")"
    tparent_local_id="$(jq -r '.parent_local_id // empty' <<< "${taction}")"
    if [[ -n "${tparent_local_id}" ]]; then
      tparent_key="$(jq -r --arg id "${tparent_local_id}" '.[$id] // empty' <<< "${story_key_map}")"
      if [[ -z "${tparent_key}" ]]; then
        continue
      fi
      taction="$(jq -c --arg k "${tparent_key}" \
        'if (.body.fields.parent.key? == "<resolved at apply time>") then .body.fields.parent.key = $k else . end' \
        <<< "${taction}")"
    fi
    method="$(jq -r '.method' <<< "${taction}")"
    url="$(jq -r '.url' <<< "${taction}")"
    body="$(jq -c '.body // empty' <<< "${taction}")"
    resp="$(mktemp)"
    if [[ -n "${body}" ]]; then
      jira_request "${method}" "${url}" "${body}" > "${resp}"
    else
      jira_request "${method}" "${url}" > "${resp}"
    fi
    rc=$?
    ((rc > worst)) && worst=${rc}
    if ((rc >= 2)); then
      _plan_apply_report_rejection "${method}" "${url}" "${taction}" "${defaultable_by_type}"
      rm -f "${resp}"
      return "${worst}"
    fi

    if [[ "${method}" == "POST" && "${url}" == */issue && -n "${tasks_file}" ]]; then
      local tkey tlocal_id
      tkey="$(jq -r '.key // empty' < "${resp}")"
      tlocal_id="$(jq -r '.local_id // empty' <<< "${taction}")"
      if [[ -n "${tkey}" && -n "${tlocal_id}" ]]; then
        identity_write "${tkey}" "${spec_ref}" "bridge" "${tlocal_id}" "task" || true
        local tcur tnew
        tcur="$(cat "${tasks_file}" 2> /dev/null; printf x)"; tcur="${tcur%x}"
        tnew="$(printf '%s' "${tcur}" | task_marker_record_ticket "${tlocal_id}" "${tkey}"; printf x)"; tnew="${tnew%x}"
        marker_splice_write_file "${tasks_file}" "${tnew}" > /dev/null
      fi
    fi
    rm -f "${resp}"
  done
  return "${worst}"
}
