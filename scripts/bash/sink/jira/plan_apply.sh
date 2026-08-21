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
# shellcheck source=/dev/null
source "${_plan_apply_dir}/transitions.sh" # 023 — the declared-step read + name resolution
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
source "${_plan_apply_dir}/../../engine/spec_marker.sh" # the parent's own `creating` mark + key record (regression: apply_writes_with_recognition calls spec_marker_mark_creating/spec_marker_record_ticket but no caller sourced this module, so a parent creation silently printed "command not found" onto this function's stdout)
# shellcheck source=/dev/null
source "${_plan_apply_dir}/identity.sh" # stamp the identity marker on each created ticket (R5 step 6)

# 017, contracts/provenance-label.md §4: Jira Cloud's documented label-length
# cap. One named constant so a tracker that differs is a one-line correction.
: "${JIRA_LABEL_MAX_LENGTH:=255}"

# _plan_apply_label_decision <defaultable-fields-by-type-json> <type-id>
#   <type-logical-name> <project-key> <provenance-label> <slug>
#   017, contract §4's two degradation triggers. Prints
#   {"label":"<token-or-empty>","warning":"<text-or-empty>"}. Neither trigger
#   ever refuses or drops a write — the label is simply omitted, with one
#   named warning.
_plan_apply_label_decision() {
  local dft="${1:-{\}}" type_id="$2" type_name="$3" project="$4" prov="$5" slug="$6"
  [[ -z "${dft}" ]] && dft='{}'
  [[ -z "${prov}" ]] && { printf '{"label":"","warning":""}'; return 0; }

  # (b) The label is too long — checked first: an over-long label is never
  # sent regardless of the type's own capability, and its warning names the
  # SLUG (the operator's remedy), never the type.
  if ((${#prov} > JIRA_LABEL_MAX_LENGTH)); then
    jq -cn --arg s "${slug}" --argjson n "${#prov}" --argjson lim "${JIRA_LABEL_MAX_LENGTH}" \
      '{label:"", warning:"the provenance label for \"\($s)\" is \($n) characters, past the tracker'"'"'s \($lim)-character limit; every ticket was mirrored without it"}'
    return 0
  fi

  # (a) The type cannot hold labels — "present" means the key EXISTS in the
  # type's defaultable_fields entry (recorded `defaultable: false` included),
  # never whether it is itself defaultable (research R6/contract §4): that
  # entry is exactly discovery's evidence that the type's create screen
  # OFFERS labels at all. A type with no defaultable_fields entry recorded
  # predates the metadata and must not gain a second refusal — it sends.
  local has_entry has_labels
  has_entry="$(jq -r --arg t "${type_id}" 'has($t)' <<< "${dft}")"
  if [[ "${has_entry}" == "true" ]]; then
    has_labels="$(jq -r --arg t "${type_id}" '[.[$t][] | select(.field_id=="labels")] | length > 0' <<< "${dft}")"
    if [[ "${has_labels}" != "true" ]]; then
      jq -cn --arg lbl "${prov}" --arg tn "${type_name}" --arg p "${project}" \
        '{label:"", warning:"the provenance label \"\($lbl)\" could not be applied to \($tn) in \($p); every ticket was mirrored without it"}'
      return 0
    fi
  fi
  jq -cn --arg lbl "${prov}" '{label:$lbl, warning:""}'
}

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
# 015, research R1/R2/R3, contract §1.3, data-model.md §2: alongside the
# recorded map, emit `field_defaults_encoded` — the same map with each value
# shaped for the field's declared `schema_type` (an `option` field as
# `{"value": v}`, a named-entity field as `{"name": v}`, everything else,
# including `user` and a non-string value, unchanged). Only the plan
# context's assignment reads the encoded map; every other consumer keeps
# reading `field_defaults` untouched (research R2).
#
# Prints one canonical object:
#   {"field_defaults": {type_id: {field_id: value}},
#    "field_defaults_encoded": {type_id: {field_id: value shaped for the wire}},
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
    def fieldMetaFor($tid; $label): (first((($df[$tid]) // [])[] | select(.logical_name == $label)) // null);
    def encodeValue($meta; $v):
      if ($v | type) != "string" then $v
      elif ($meta.schema_type // "") == "option" then {value: $v}
      elif ((["priority","resolution","version","component","group"]) | index($meta.schema_type // "")) != null then {name: $v}
      else $v end;
    ( [ ($rec | to_entries[] | select(.key != "ask")) as $te
        | ($te.key) as $type | ($te.value | to_entries[]) as $fe
        | {type: $type, label: $fe.key, value: $fe.value, source: "team-config"} ]
      + [ $ans[] | {type: .type, label: .label, value: .value, source: "operator-answer"} ]
    ) as $entries
    | reduce $entries[] as $e
        ( {field_defaults: {}, field_defaults_encoded: {}, field_default_sources: {}, unresolved: []}
        ; (typeId($e.type)) as $tid
          | if $tid == null then
              . + {unresolved: (.unresolved + [{type: $e.type, label: $e.label, reason: "unknown issue type"}])}
            else
              (fieldMetaFor($tid; $e.label)) as $meta
              | if $meta == null then
                  . + {unresolved: (.unresolved + [{type: $e.type, label: $e.label, reason: "unknown field label"}])}
                else
                  ($meta.field_id) as $fid
                  | .field_defaults[$tid][$fid] = $e.value
                  | .field_defaults_encoded[$tid][$fid] = encodeValue($meta; $e.value)
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

# _plan_apply_managed_field <render-json> [ticket-label]
#   018, T026, contract §3 rows 1/4 (FR-012/FR-020a/FR-020b): given
#   adf_render_managed_description's or adf_render_managed_task_description's
#   {status, doc} and a label identifying the ticket for a warning (the
#   ticket's key on an UPDATE; empty on a CREATE, which never warns since a
#   creation has no existing content to be ambiguous about), decide the
#   description FIELD to send and any warning to surface. Prints canonical
#   {doc, warning}: doc is JSON `null` when the boundary is malformed — the
#   caller MUST omit the description key entirely rather than send null, so
#   every other field of that ticket still reconciles (FR-012); warning is ""
#   when none applies.
# 022, FR-041, contract §7: the sink's practical ceiling for a rendered
# description, in bytes of the canonical ADF JSON — Jira Cloud's documented
# text-field limit. A story whose checklist pushes it past this withholds
# ONE field rather than failing the run.
: "${_PLAN_APPLY_DESCRIPTION_SIZE_CEILING:=32767}"

_plan_apply_managed_field() {
  local render="$1" label="${2:-}" status doc warning=""
  status="$(jq -r '.status' <<< "${render}")"
  case "${status}" in
    malformed)
      doc="null"
      warning="${label} carries more than one boundary marker in its description; nothing was written to it. A human must remove the duplicate."
      ;;
    migrated-warned)
      doc="$(jq -c '.doc' <<< "${render}")"
      warning="${label}'s previous mirrored content could not be identified and is preserved above the boundary; it may now appear twice."
      ;;
    *)
      doc="$(jq -c '.doc' <<< "${render}")"
      ;;
  esac
  # 022, FR-041, contract §7: a rendered description (the checklist
  # included) that exceeds the sink's ceiling withholds THAT ONE field —
  # every other field of the story, and every other story, still
  # reconciles. Reuses the SAME whole-field drop as the malformed row
  # above, rather than a second way to fail a field.
  if [[ "${doc}" != "null" ]] && (($(printf '%s' "${doc}" | wc -c) > _PLAN_APPLY_DESCRIPTION_SIZE_CEILING)); then
    doc="null"
    warning="${label}'s rendered description exceeds what Jira accepts and was not written — nothing changed in Jira. Reduce the number of tasks in this story, or switch this project to subtask mode."
  fi
  jq -cn --argjson d "${doc}" --arg w "${warning}" '{doc:$d, warning:$w}'
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
#     ticket_origins:{<local_id>: "bridge"|"human"},  (018, T072: populated for
#       every recognised ticket now — kept for other consumers, but no longer
#       read here; see below)
#     ticket_descriptions:{<local_id>: <existing-adf-doc>},   (optional, US7)
#     ticket_parents:{<local_id>: <existing-parent-key>},   (optional, T109;
#       only entries whose child ALREADY carries a parent — a flat mirror
#       with none is Out of Scope, "no migration")
#     parent_type_id, parent_key|absent (a recognised parent's key),
#     parent_local_id (the parent marker's id, for a creation),
#     parent_current|absent ({summary, description}, for the zero-churn
#       comparison) }
# 018, T026/T072: the managed-panel splice is now UNCONDITIONAL and
# origin-independent (contract §3) — every recognised ticket's update is
# rendered through it, so human-authored prose above the boundary is
# preserved verbatim (FR-007) regardless of origin. "bridge-created" is
# retired; recognition.sh's own spelling, "bridge", is the one this file
# and adf.sh now share (test_recognition.bats asserts it).
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
  # 022, contract §1/§7: the resolved task_mirror mode, threaded into the
  # renderer as "checklist" or "off" — constant for the whole run, so
  # resolved once rather than per story.
  local checklist_mode="off"
  [[ "$(jq -r '.task_mirror // ""' <<< "${ctx}")" == "checklist" ]] && checklist_mode="checklist"

  # Provenance label (017, contracts/provenance-label.md §1/§4): derived once
  # per run, from the document's own validated spec_ref — the "speckit-"
  # prefix is a sink literal, the engine never learns the word "label".
  # The degradation decision (§4's two triggers) is resolved ONCE for the
  # story type here and reused by every story this run creates or updates,
  # so at most one warning is ever emitted for it.
  local slug provenance_label defaultable_by_type issue_types_list story_type_name
  slug="$(jq -r '.spec_ref.spec_slug // ""' <<< "${doc}")"
  provenance_label=""
  [[ -n "${slug}" ]] && provenance_label="speckit-${slug}"
  defaultable_by_type="$(jq -c '.defaultable_fields_by_type // {}' <<< "${ctx}")"
  issue_types_list="$(jq -c '.issue_types // []' <<< "${ctx}")"
  story_type_name="$(jq -r --arg t "${story_type}" '(first(.[] | select(.id==$t)) // null) | .logical_name // $t' <<< "${issue_types_list}")"
  local story_label="" story_label_warning=""
  local plan_warnings="[]"
  # 022, data-model.md §4: the checklist tallies, accumulated per story
  # below and returned distinct from the specification/story/sub-task
  # counts. Zero cost when checklist mode is off — the accumulators simply
  # never increment.
  local cl_created=0 cl_updated=0 cl_unchanged=0 cl_entries_completed=0
  if [[ -n "${provenance_label}" ]]; then
    local story_decision
    story_decision="$(_plan_apply_label_decision "${defaultable_by_type}" "${story_type}" "${story_type_name}" "${project}" "${provenance_label}" "${slug}")"
    story_label="$(jq -r '.label' <<< "${story_decision}")"
    story_label_warning="$(jq -r '.warning' <<< "${story_decision}")"
    [[ -n "${story_label_warning}" ]] && plan_warnings="$(jq -c --arg w "${story_label_warning}" '. + [$w]' <<< "${plan_warnings}")"
  fi

  # 024, C1.2: native accumulation (a bash array of already-JSON actions,
  # joined with ONE `jq -cs` after the loop) rather than a `. + [$a]` merge
  # re-parsed on every story — the same O(n²)-avoidance already applied in
  # parse.sh (T026) and recognition.sh.
  local -a stories_arr=()
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

    if [[ -z "${ticket}" ]]; then
      # FR-024 assembly guard: refuse an incomplete creation BEFORE it is ever
      # emitted, rather than sending it for the destination service to reject.
      if [[ -z "${project}" || -z "${story_type}" ]]; then
        printf 'plan_writes: refusing to assemble a creation for "%s" with no project or issue type (zero writes)\n' "${sid}" >&2
        return 1
      fi
      # CREATE: the shared mandatory base (research R3, FR-025) + description +
      # priority + estimation (create-only) + the parent-key placeholder
      # (T072/T073), resolved once the parent's create response is read. Every
      # ticket the mirror creates now carries the boundary from its first byte
      # (018, T026, FR-006/FR-010) — a creation never warns (no prior content).
      local create_render create_field
      create_render="$(adf_render_managed_description "${story}" "" "" "${checklist_mode}")"
      create_field="$(_plan_apply_managed_field "${create_render}" "${title}")"
      adf="$(jq -c '.doc' <<< "${create_field}")"
      local create_warn; create_warn="$(jq -r '.warning' <<< "${create_field}")"
      [[ -n "${create_warn}" ]] && plan_warnings="$(jq -c --arg w "${create_warn}" '. + [$w]' <<< "${plan_warnings}")"
      base_fields="$(jira_create_fields_base "${project}" "${title}" "${story_type}" "${field_defaults}" "${story_label}")"
      fields="$(jq -cn --argjson base "${base_fields}" --argjson d "${adf}" \
        '$base + (if $d == null then {} else {description:$d} end) + {parent:{key:"<resolved at apply time>"}}')"
      [[ -n "${priority_id}" ]] && fields="$(jq -c --arg pid "${priority_id}" '. + {priority:{id:$pid}}' <<< "${fields}")"
      if [[ -n "${estid}" && "${est}" != "null" ]]; then
        fields="$(jq -c --arg fid "${estid}" --argjson v "${est}" '. + {($fid): $v}' <<< "${fields}")"
      fi
      # 018, T048, contracts/summary-record.md §2: a creation's payload
      # always carries a summary, so it always establishes the record.
      # 022, data-model.md §3: the checklist digest joins it, computed from
      # the SAME story content, present only in checklist mode.
      local identity_stamp create_checklist_digest=""
      if [[ "${checklist_mode}" == "checklist" ]]; then
        create_checklist_digest="$(adf_checklist_digest "${story}")"
        [[ -n "${create_checklist_digest}" ]] && cl_created=$((cl_created + 1))
      fi
      identity_stamp="$(jq -cn --arg st "${sid}" --arg sm "${title}" --arg cd "${create_checklist_digest}" \
        '{origin:"bridge", story:$st, role:"story", summary:$sm} + (if $cd == "" then {} else {checklist:$cd} end)')"
      action="$(jq -cn --arg u "${base}/rest/api/3/issue" --argjson f "${fields}" --arg sid "${sid}" --argjson stamp "${identity_stamp}" \
        '{method:"POST", url:$u, body:{fields:$f}, local_id:$sid, role:"story", identity_stamp:$stamp}')"
    else
      # UPDATE: content + priority; the estimation is NEVER re-sent (FR-018).
      # The parent link is corrected only when the child already names a
      # DIFFERENT parent (T109, below) — never when it names none at all
      # (Out of Scope, "no migration"). The managed-panel path is now
      # UNCONDITIONAL (018, T026): every recognised story's description is
      # spliced through the origin-independent resolution, so any human prose
      # above the boundary survives (FR-007) regardless of origin.
      local existing story_origin render field warn
      existing="$(jq -c --arg s "${sid}" '.ticket_descriptions[$s] // {}' <<< "${ctx}")"
      story_origin="$(jq -r --arg s "${sid}" '.ticket_origins[$s] // ""' <<< "${ctx}")"
      render="$(adf_render_managed_description "${story}" "${existing}" "${story_origin}" "${checklist_mode}")"
      field="$(_plan_apply_managed_field "${render}" "${ticket}")"
      adf="$(jq -c '.doc' <<< "${field}")"
      warn="$(jq -r '.warning' <<< "${field}")"
      [[ -n "${warn}" ]] && plan_warnings="$(jq -c --arg w "${warn}" '. + [$w]' <<< "${plan_warnings}")"

      # 022, contract §6: the four-row checklist drift decision — did a
      # PERSON edit the checklist on the ticket since the mirror last wrote
      # it? A three-way digest comparison (current on the ticket, recorded
      # in the identity property, desired now), mirroring
      # plan_summary_drift_status's shape but the OPPOSITE outcome: warn
      # then WRITE regardless (FR-026) — tasks.md stays the source of truth
      # in both directions, never withheld.
      if [[ "${checklist_mode}" == "checklist" ]]; then
        local cl_marker cl_existing_managed cl_current_nodes cl_current_digest cl_recorded_digest cl_desired_digest
        cl_marker="$(adf_managed_marker)"
        cl_existing_managed="$(jq -c '.content // []' <<< "${existing}" | managed_section_panel_split "${cl_marker}" | jq -c '.managed')"
        cl_current_nodes="$(_adf_checklist_slice "${cl_existing_managed}")"
        cl_current_digest="$(_adf_checklist_nodes_digest "${cl_current_nodes}")"
        cl_recorded_digest="$(jq -r --arg s "${sid}" '.ticket_last_checklists[$s] // ""' <<< "${ctx}")"
        cl_desired_digest="$(adf_checklist_digest "${story}")"

        # 022, data-model.md §4: created/updated/unchanged classified from
        # CURRENT vs DESIRED (zero churn is current==desired) — independent
        # of the drift record above, which answers a different question.
        local cl_desired_nodes cl_entries_delta
        cl_desired_nodes="$(_adf_checklist_nodes "${story}")"
        if [[ "${cl_current_nodes}" == "[]" ]]; then
          [[ "${cl_desired_nodes}" != "[]" ]] && cl_created=$((cl_created + 1))
        elif [[ "${cl_current_digest}" == "${cl_desired_digest}" ]]; then
          cl_unchanged=$((cl_unchanged + 1))
        else
          cl_updated=$((cl_updated + 1))
        fi
        # entries.completed: positional zip of the two flattened glyph
        # sequences (entries carry no identity, contract §3) — a length
        # change (a task added/removed) degrades to undercounting rather
        # than a false match, which is the safe direction for a tally.
        cl_entries_delta="$(jq -n --argjson cur "${cl_current_nodes}" --argjson des "${cl_desired_nodes}" '
          def glyphs: [ .[] | select(.type=="bulletList") | .content[] | (.content[0].content[0].text // "" | startswith("☑")) ];
          ($cur|glyphs) as $c | ($des|glyphs) as $d
          | [range(0; ([$c,$d]|map(length)|min)) | select($c[.]==false and $d[.]==true)] | length
        ')"
        cl_entries_completed=$((cl_entries_completed + cl_entries_delta))

        if [[ -n "${cl_recorded_digest}" && "${cl_current_digest}" != "${cl_recorded_digest}" && "${cl_desired_digest}" != "${cl_current_digest}" ]]; then
          local cl_warn; cl_warn="reconcile: ticket ${ticket}'s checklist differs from the one the mirror last wrote — a human appears to have edited it since. tasks.md is the source of truth and the checklist has been rewritten from it; no box in tasks.md was changed."
          plan_warnings="$(jq -c --arg w "${cl_warn}" '. + [$w]' <<< "${plan_warnings}")"
        fi
      fi

      # Summary drift (018, T048, contracts/summary-record.md §4): decided
      # before `fields` is built, so an omission never reaches the payload.
      local current_summary recorded_summary on_drift_mode summary_decision final_summary identity_stamp
      current_summary="$(jq -r --arg s "${sid}" '.ticket_summaries[$s] // ""' <<< "${ctx}")"
      recorded_summary="$(jq -r --arg s "${sid}" '.ticket_last_summaries[$s] // ""' <<< "${ctx}")"
      on_drift_mode="$(jq -r '.on_drift // "abort"' <<< "${ctx}")"
      summary_decision="$(plan_summary_drift_status "${current_summary}" "${recorded_summary}" "${title}" "${on_drift_mode}")"
      final_summary="$(jq -r '.summary // empty' <<< "${summary_decision}")"
      identity_stamp="null"
      if [[ -z "${final_summary}" ]]; then
        plan_warnings="$(jq -c --arg w "reconcile: ticket ${ticket} diverges from the specification on \"summary\" — a human appears to have renamed it since the last write; nothing was sent. Pass --on-drift=proceed to restore the specification's title." '. + [$w]' <<< "${plan_warnings}")"
      fi

      if [[ "${adf}" == "null" ]]; then
        fields="$(jq -cn '{}')"
      else
        fields="$(jq -cn --argjson d "${adf}" '{description:$d}')"
      fi
      if [[ -n "${final_summary}" ]]; then
        fields="$(jq -c --arg t "${final_summary}" '. + {summary:$t}' <<< "${fields}")"
        # 022, data-model.md §3: the checklist digest joins the SAME stamp,
        # computed from the SAME story content, present only in checklist
        # mode. Recorded whenever the story writes at all — not only when
        # the checklist itself changed — so the record never lags behind
        # what the ticket currently carries.
        local update_checklist_digest=""
        [[ "${checklist_mode}" == "checklist" ]] && update_checklist_digest="$(adf_checklist_digest "${story}")"
        identity_stamp="$(jq -cn --arg o "$(jq -r --arg s "${sid}" '.ticket_origins[$s] // "bridge"' <<< "${ctx}")" \
          --arg st "${sid}" --arg sm "${final_summary}" --arg cd "${update_checklist_digest}" \
          '{origin:$o, story:$st, role:"story", summary:$sm} + (if $cd == "" then {} else {checklist:$cd} end)')"
      fi
      [[ -n "${priority_id}" ]] && fields="$(jq -c --arg pid "${priority_id}" '. + {priority:{id:$pid}}' <<< "${fields}")"

      # Provenance label union (017, contract §2/§3): the desired list is
      # the ticket's CURRENT labels plus the provenance token — Jira's PUT
      # replaces the whole array, so the union is simultaneously the merge
      # rule (FR-012) and the zero-churn rule (FR-013). Omitted entirely
      # when the label is degraded (empty story_label) — an existing label
      # set is never touched on a project that cannot hold the token.
      if [[ -n "${story_label}" ]]; then
        local existing_labels
        existing_labels="$(jq -c --arg s "${sid}" '.ticket_labels[$s] // []' <<< "${ctx}")"
        fields="$(jq -c --argjson cur "${existing_labels}" --arg lbl "${story_label}" \
          '. + {labels: (($cur + [$lbl]) | unique)}' <<< "${fields}")"
      fi

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

      action="$(jq -cn --arg u "${base}/rest/api/3/issue/${ticket}" --argjson f "${fields}" --argjson stamp "${identity_stamp}" \
        '{method:"PUT", url:$u, body:{fields:$f}, role:"story"} + (if $stamp == null then {} else {identity_stamp:$stamp} end)')"
    fi
    stories_arr+=("${action}")
  done
  ((${#stories_arr[@]} > 0)) && stories="$(printf '%s\n' "${stories_arr[@]}" | jq -cs '.')"

  # The parent type's own label decision (017, contract §4) — resolved here,
  # independently of the story type's, and reused whether the parent is
  # created or updated this run. At most one further warning.
  local parent_type parent_type_name parent_label=""
  parent_type="$(jq -r '.parent_type_id // ""' <<< "${ctx}")"
  if [[ -n "${provenance_label}" && -n "${parent_type}" ]]; then
    parent_type_name="$(jq -r --arg t "${parent_type}" '(first(.[] | select(.id==$t)) // null) | .logical_name // $t' <<< "${issue_types_list}")"
    local parent_decision parent_label_warning
    parent_decision="$(_plan_apply_label_decision "${defaultable_by_type}" "${parent_type}" "${parent_type_name}" "${project}" "${provenance_label}" "${slug}")"
    parent_label="$(jq -r '.label' <<< "${parent_decision}")"
    parent_label_warning="$(jq -r '.warning' <<< "${parent_decision}")"
    [[ -n "${parent_label_warning}" ]] && plan_warnings="$(jq -c --arg w "${parent_label_warning}" '. + [$w]' <<< "${plan_warnings}")"
  fi

  # The task type's own label decision (017 FR-009, extended to 012's task
  # tier) — resolved here beside the story's and the parent's, so all three
  # degradation warnings leave through this function's single `warnings`
  # channel. The resolved token travels back as `task_label` because
  # `plan_writes_tasks` returns a bare action array and has no warnings
  # channel of its own. Absent when no `task` role resolved, which keeps a
  # run with no task tier byte-identical to before this feature.
  local task_type task_type_name task_label=""
  task_type="$(jq -r '.task_type_id // ""' <<< "${ctx}")"
  if [[ -n "${provenance_label}" && -n "${task_type}" ]]; then
    task_type_name="$(jq -r --arg t "${task_type}" '(first(.[] | select(.id==$t)) // null) | .logical_name // $t' <<< "${issue_types_list}")"
    local task_decision task_label_warning
    task_decision="$(_plan_apply_label_decision "${defaultable_by_type}" "${task_type}" "${task_type_name}" "${project}" "${provenance_label}" "${slug}")"
    task_label="$(jq -r '.label' <<< "${task_decision}")"
    task_label_warning="$(jq -r '.warning' <<< "${task_decision}")"
    [[ -n "${task_label_warning}" ]] && plan_warnings="$(jq -c --arg w "${task_label_warning}" '. + [$w]' <<< "${plan_warnings}")"
  fi

  local parent_result parent
  parent_result="$(_plan_writes_parent "${doc}" "${ctx}" "${base}" "${parent_label}")"
  parent="$(jq -c '.action' <<< "${parent_result}")"
  plan_warnings="$(jq -c --argjson w "$(jq -c '.warnings' <<< "${parent_result}")" '. + $w' <<< "${plan_warnings}")"
  # $s carries the whole story plan — ~140 KB at a hundred stories, past
  # Linux's 128 KiB per-argument cap. json_build keeps it out of argv.
  local _plan
  # Captured, not piped straight into json_canonical: on an empty input jq
  # writes nothing and exits 0, so a json_build failure would be swallowed
  # and an EMPTY plan returned as a success. This is the write path.
  # 022, data-model.md §4: the checklist tallies, present only when
  # checklist mode was active this run — distinct from the specification/
  # story/sub-task counts (FR-036), and absent entirely otherwise so a
  # subtask-mode or unrecorded run stays byte-for-byte unchanged (FR-002).
  local checklist_counts="null"
  if [[ "${checklist_mode}" == "checklist" ]]; then
    checklist_counts="$(jq -cn --argjson cr "${cl_created}" --argjson up "${cl_updated}" \
      --argjson un "${cl_unchanged}" --argjson ec "${cl_entries_completed}" \
      '{created:$cr, updated:$up, unchanged:$un, entries_completed:$ec}')"
  fi
  # shellcheck disable=SC2016  # a jq filter: $p/$s/$w/$tl/$cc are jq variables
  _plan="$(json_build \
    '{parent:$p, stories:$s}
     + (if $tl == "" then {} else {task_label:$tl} end)
     + (if ($w|length) == 0 then {} else {warnings:$w} end)
     + (if $cc == null then {} else {checklist_counts:$cc} end)' \
    p "${parent}" s "${stories}" w "${plan_warnings}" \
    tl "$(jq -cn --arg t "${task_label}" '$t')" \
    cc "${checklist_counts}")" || return $?
  printf '%s' "${_plan}" | json_canonical
}

# _plan_writes_parent <neutral-doc-json> <plan-context-json> <base-url> —
# the parent half of plan_writes' return shape (Phase 5, US2, T072/T076).
# `epic.local_id`/`epic.title`/`epic.description` come from the neutral
# document; the recognised-parent facts come from the plan context.
_plan_writes_parent() {
  local doc="$1" ctx="$2" base="$3" parent_label="${4:-}"
  local parent_type project epic_title epic_local_id
  parent_type="$(jq -r '.parent_type_id // ""' <<< "${ctx}")"
  project="$(jq -r '.routing.project_key // ""' <<< "${doc}")"
  epic_title="$(jq -r '.epic.title // ""' <<< "${doc}")"
  epic_local_id="$(jq -r '.epic.local_id // ""' <<< "${doc}")"

  local parent_key; parent_key="$(jq -r '.parent_key // ""' <<< "${ctx}")"
  local warnings="[]"

  if [[ -z "${parent_key}" ]]; then
    # CREATE: no parent recognised yet. 011, research R2: same field_defaults
    # map the story branch reads, scoped to the parent type by the shared
    # builder itself. Every ticket the mirror creates now carries the
    # boundary from its first byte (018, T026, FR-006/FR-010) — a creation
    # never warns (no prior content).
    local epic_adf base_fields fields field_defaults
    epic_adf="$(jq -c '.doc' <<< "$(adf_render_managed_description "$(jq -c '.epic' <<< "${doc}")")")"
    field_defaults="$(jq -c '.field_defaults // {}' <<< "${ctx}")"
    base_fields="$(jira_create_fields_base "${project}" "${epic_title}" "${parent_type}" "${field_defaults}" "${parent_label}")"
    fields="$(jq -cn --argjson base "${base_fields}" --argjson d "${epic_adf}" '$base + {description:$d}')"
    # 018, T048, contracts/summary-record.md §2: a creation's payload always
    # carries a summary, so it always establishes the record.
    local action identity_stamp
    identity_stamp="$(jq -cn --arg sm "${epic_title}" '{origin:"bridge", role:"parent", summary:$sm}')"
    action="$(jq -cn --arg u "${base}/rest/api/3/issue" --argjson f "${fields}" --arg lid "${epic_local_id}" --argjson stamp "${identity_stamp}" \
      '{method:"POST", url:$u, body:{fields:$f}, local_id:$lid, role:"parent", identity_stamp:$stamp}')"
    jq -cn --argjson a "${action}" --argjson w "${warnings}" '{action:$a, warnings:$w}'
    return 0
  fi

  # A recognised parent: the managed-panel path is now UNCONDITIONAL (018,
  # T026) — every recognised parent's description is spliced through the
  # origin-independent resolution (contract §3), so human prose above the
  # boundary survives (FR-007) on the parent exactly as on a story.
  local current
  current="$(jq -c '.parent_current // null' <<< "${ctx}")"

  local existing parent_origin render field epic_adf warn
  existing="$(jq -c '.description // {}' <<< "${current}")"
  parent_origin="$(jq -r '.parent_origin // ""' <<< "${ctx}")"
  render="$(adf_render_managed_description "$(jq -c '.epic' <<< "${doc}")" "${existing}" "${parent_origin}")"
  field="$(_plan_apply_managed_field "${render}" "${parent_key}")"
  epic_adf="$(jq -c '.doc' <<< "${field}")"
  warn="$(jq -r '.warning' <<< "${field}")"
  [[ -n "${warn}" ]] && warnings="$(jq -c --arg w "${warn}" '. + [$w]' <<< "${warnings}")"

  # Summary drift (018, T048, contracts/summary-record.md §4): decided
  # before `desired_fields` is built, so an omission never reaches the
  # payload (mirror of the story branch in plan_writes).
  local current_summary recorded_summary on_drift_mode summary_decision final_summary identity_stamp
  current_summary="$(jq -r '.summary // ""' <<< "${current}")"
  recorded_summary="$(jq -r '.parent_last_summary // ""' <<< "${ctx}")"
  on_drift_mode="$(jq -r '.on_drift // "abort"' <<< "${ctx}")"
  summary_decision="$(plan_summary_drift_status "${current_summary}" "${recorded_summary}" "${epic_title}" "${on_drift_mode}")"
  final_summary="$(jq -r '.summary // empty' <<< "${summary_decision}")"
  identity_stamp="null"
  if [[ -z "${final_summary}" ]]; then
    warnings="$(jq -c --arg w "reconcile: ticket ${parent_key} diverges from the specification on \"summary\" — a human appears to have renamed it since the last write; nothing was sent. Pass --on-drift=proceed to restore the specification's title." '. + [$w]' <<< "${warnings}")"
  fi

  local desired_fields
  if [[ "${epic_adf}" == "null" ]]; then
    desired_fields="$(jq -cn '{}')"
  else
    desired_fields="$(jq -cn --argjson d "${epic_adf}" '{description:$d}')"
  fi
  if [[ -n "${final_summary}" ]]; then
    desired_fields="$(jq -c --arg t "${final_summary}" '. + {summary:$t}' <<< "${desired_fields}")"
    identity_stamp="$(jq -cn --arg o "$(jq -r '.parent_origin // "bridge"' <<< "${ctx}")" --arg sm "${final_summary}" \
      '{origin:$o, role:"parent", summary:$sm}')"
  fi

  # Provenance label union (017, contract §2/§3), on the recognised-parent
  # branch — same union rule as the story branch, and folded into
  # desired_fields BEFORE the zero-churn comparison below so a settled
  # parent's label participates in it exactly like every other field.
  if [[ -n "${parent_label}" ]]; then
    local existing_parent_labels
    existing_parent_labels="$(jq -c '.labels // []' <<< "${current}")"
    [[ "${current}" == "null" ]] && existing_parent_labels='[]'
    desired_fields="$(jq -c --argjson cur "${existing_parent_labels}" --arg lbl "${parent_label}" \
      '. + {labels: (($cur + [$lbl]) | unique)}' <<< "${desired_fields}")"
  fi

  local status
  if [[ "${current}" == "null" ]]; then
    status="changed"
  else
    local desc_st="unchanged" other_st cur_rest des_rest
    if jq -e 'has("description")' <<< "${desired_fields}" > /dev/null 2>&1; then
      local cur_desc new_desc
      cur_desc="$(jq -c '.description // {}' <<< "${current}")"
      new_desc="$(jq -c '.description' <<< "${desired_fields}")"
      desc_st="$(plan_managed_description_status "${cur_desc}" "${new_desc}")"
    fi
    cur_rest="$(jq -c 'del(.description)' <<< "${current}")"
    des_rest="$(jq -c 'del(.description)' <<< "${desired_fields}")"
    other_st="$(idempotency_field_status "${cur_rest}" "${des_rest}")"
    if [[ "${desc_st}" == "unchanged" && "${other_st}" == "unchanged" ]]; then status="unchanged"; else status="changed"; fi
  fi

  if [[ "${status}" == "unchanged" ]]; then
    jq -cn --argjson w "${warnings}" '{action:null, warnings:$w}'
    return 0
  fi
  local action
  action="$(jq -cn --arg u "${base}/rest/api/3/issue/${parent_key}" --argjson f "${desired_fields}" --argjson stamp "${identity_stamp}" \
    '{method:"PUT", url:$u, body:{fields:$f}, role:"parent"} + (if $stamp == null then {} else {identity_stamp:$stamp} end)')"
  jq -cn --argjson a "${action}" --argjson w "${warnings}" '{action:$a, warnings:$w}'
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

# _summary_normalise <string> — contract summary-record.md §3: strip leading
# and trailing whitespace, then collapse every internal run of whitespace to
# a single space. For COMPARISON only — never applied to a value recorded or
# sent.
_summary_normalise() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# plan_summary_drift_status <current-summary> <recorded-summary-or-empty>
# <desired-summary> [<on-drift>] — 018, T048, contracts/summary-record.md §4:
# the whole decision table, collapsed into one function every tier calls
# identically. Prints {summary: <string>|null}: the value to send (present),
# or null when the field must be OMITTED from the payload — the caller's own
# signal to skip this field and emit exactly one warning naming the ticket.
#
#   recorded-summary-or-empty absent (no record yet) -> send desired, never
#     omit (FR-018: no record means no warning).
#   recorded present, normalised(current) == normalised(recorded) -> no
#     human intervened since the last write; send desired (FR-017, a silent
#     retitle when the specification's title changed).
#   recorded present, normalised(current) != normalised(recorded), but
#     normalised(current) == normalised(desired) -> the human already
#     renamed it to exactly the specification's title; nothing to protect
#     the human FROM, so this is never treated as drift (§6 scenario table).
#   recorded present, current differs from BOTH recorded and desired ->
#     genuine drift: `--on-drift=proceed` sends desired (FR-016, restores
#     and counts as an ordinary update); otherwise (the default) the field
#     is omitted (FR-015) — the caller's job to warn, since only it knows
#     the ticket key.
plan_summary_drift_status() {
  local current="$1" recorded="${2:-}" desired="$3" on_drift="${4:-abort}"
  if [[ -z "${recorded}" ]]; then
    jq -cn --arg d "${desired}" '{summary:$d}'
    return 0
  fi
  local nc nr
  nc="$(_summary_normalise "${current}")"
  nr="$(_summary_normalise "${recorded}")"
  if [[ "${nc}" == "${nr}" ]]; then
    jq -cn --arg d "${desired}" '{summary:$d}'
    return 0
  fi
  local nd
  nd="$(_summary_normalise "${desired}")"
  if [[ "${nc}" == "${nd}" ]]; then
    jq -cn --arg d "${desired}" '{summary:$d}'
    return 0
  fi
  if [[ "${on_drift}" == "proceed" ]]; then
    jq -cn --arg d "${desired}" '{summary:$d}'
  else
    jq -cn '{summary:null}'
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
  local doc="$1" ctx="$2" task_label="${3:-}"
  local base task_type project field_defaults
  base="$(jq -r '.base_url // ""' <<< "${ctx}")"
  task_type="$(jq -r '.task_type_id // ""' <<< "${ctx}")"
  field_defaults="$(jq -c '.field_defaults // {}' <<< "${ctx}")"
  project="$(jq -r '.routing.project_key // ""' <<< "${doc}")"

  local actions="[]" warnings="[]" sn si
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

      if [[ -z "${ticket}" ]]; then
        if [[ -z "${project}" || -z "${task_type}" ]]; then
          printf 'plan_writes_tasks: refusing to assemble a creation for "%s" with no project or issue type (zero writes)\n' "${tid}" >&2
          return 1
        fi
        # Every ticket the mirror creates now carries the boundary from its
        # first byte (018, T026, FR-006/FR-010) — a creation never warns.
        adf="$(jq -c '.doc' <<< "$(adf_render_managed_task_description "${task}")")"
        base_fields="$(jira_create_fields_base "${project}" "${summary}" "${task_type}" "${field_defaults}" "${task_label}")"
        fields="$(jq -cn --argjson base "${base_fields}" --argjson d "${adf}" \
          '$base + {description:$d, parent:{key:"<resolved at apply time>"}}')"
        # 018, T048, contracts/summary-record.md §2: a creation's payload
        # always carries a summary, so it always establishes the record.
        local identity_stamp
        identity_stamp="$(jq -cn --arg st "${tid}" --arg sm "${summary}" '{origin:"bridge", story:$st, role:"task", summary:$sm}')"
        action="$(jq -cn --arg u "${base}/rest/api/3/issue" --argjson f "${fields}" \
          --arg lid "${tid}" --arg pid "${story_local_id}" --argjson stamp "${identity_stamp}" \
          '{method:"POST", url:$u, body:{fields:$f}, local_id:$lid, parent_local_id:$pid, role:"task", identity_stamp:$stamp}')"
      else
        local current desired st
        current="$(jq -c --arg t "${tid}" '.ticket_current[$t] // null' <<< "${ctx}")"

        # The managed-panel path is now UNCONDITIONAL (018, T026): every
        # recognised sub-task's description is spliced through the
        # origin-independent resolution (contract §3), so human prose above
        # the boundary survives (FR-007) on the task tier exactly as on a
        # story or the parent.
        local existing task_origin render field warn
        existing="$(jq -c '.description // {}' <<< "${current}")"
        task_origin="$(jq -r --arg t "${tid}" '.ticket_origins[$t] // ""' <<< "${ctx}")"
        render="$(adf_render_managed_task_description "${task}" "${existing}" "${task_origin}")"
        field="$(_plan_apply_managed_field "${render}" "${ticket}")"
        adf="$(jq -c '.doc' <<< "${field}")"
        warn="$(jq -r '.warning' <<< "${field}")"
        [[ -n "${warn}" ]] && warnings="$(jq -c --arg w "${warn}" '. + [$w]' <<< "${warnings}")"

        # Summary drift (018, T048, contracts/summary-record.md §4/§5):
        # decided before `desired` is built. The desired value is the task
        # tier's own (possibly shortened) summary — the exact string a
        # payload carries is what the record keeps (contract §2).
        local current_summary recorded_summary on_drift_mode summary_decision final_summary identity_stamp summary_changed
        current_summary="$(jq -r '.summary // ""' <<< "${current}")"
        recorded_summary="$(jq -r --arg t "${tid}" '.ticket_last_summaries[$t] // ""' <<< "${ctx}")"
        on_drift_mode="$(jq -r '.on_drift // "abort"' <<< "${ctx}")"
        summary_decision="$(plan_summary_drift_status "${current_summary}" "${recorded_summary}" "${summary}" "${on_drift_mode}")"
        final_summary="$(jq -r '.summary // empty' <<< "${summary_decision}")"
        identity_stamp="null"
        summary_changed="false"
        if [[ -z "${final_summary}" ]]; then
          warnings="$(jq -c --arg w "reconcile: ticket ${ticket} diverges from the specification on \"summary\" — a human appears to have renamed it since the last write; nothing was sent. Pass --on-drift=proceed to restore the specification's title." '. + [$w]' <<< "${warnings}")"
        elif [[ "${final_summary}" != "${current_summary}" ]]; then
          summary_changed="true"
        fi

        if [[ "${adf}" == "null" ]]; then
          desired="$(jq -cn '{}')"
        else
          desired="$(jq -cn --argjson d "${adf}" '{description:$d}')"
        fi
        [[ -n "${final_summary}" ]] && desired="$(jq -c --arg s "${final_summary}" '. + {summary:$s}' <<< "${desired}")"
        # Provenance label union (017 FR-009/FR-011/FR-012/FR-013 on the task
        # tier): the desired list is the sub-task's CURRENT labels plus the
        # provenance token, both `unique`-normalised — which is at once the
        # merge rule, the one-time back-fill trigger, and the zero-churn rule,
        # because the comparison below is over the desired keys.
        if [[ -n "${task_label}" ]]; then
          local cur_labels
          cur_labels="$(jq -c '(.labels // [])' <<< "${current}")"
          desired="$(jq -c --argjson cur "${cur_labels}" --arg lbl "${task_label}" \
            '. + {labels: (($cur + [$lbl]) | unique)}' <<< "${desired}")"
        fi

        # Churn (FR-009): the description key, when present, is decided on
        # its managed section alone — an edit confined to the human prefix
        # is not churn. `summary` is excluded from the generic field-diff
        # below and merged back separately (summary_changed), exactly like
        # description — its own divergence is reported through the summary-
        # record's warning above, not the generic per-field one. Every other
        # field compares as before this feature.
        local desc_st="unchanged" other_st cur_rest des_rest
        cur_rest="$(jq -c 'del(.description, .summary)' <<< "${current}")"
        des_rest="$(jq -c 'del(.description, .summary)' <<< "${desired}")"
        if [[ "${current}" != "null" ]] && jq -e 'has("description")' <<< "${desired}" > /dev/null 2>&1; then
          local cur_desc new_desc
          cur_desc="$(jq -c '.description // {}' <<< "${current}")"
          new_desc="$(jq -c '.description' <<< "${desired}")"
          desc_st="$(plan_managed_description_status "${cur_desc}" "${new_desc}")"
        fi
        if [[ "${current}" == "null" ]]; then
          st="changed"
        else
          other_st="$(idempotency_field_status "${cur_rest}" "${des_rest}")"
          if [[ "${desc_st}" == "unchanged" && "${other_st}" == "unchanged" && "${summary_changed}" == "false" ]]; then st="unchanged"; else st="changed"; fi
        fi
        [[ "${st}" == "unchanged" ]] && continue

        # FR-019: only the fields that differ are written. FR-020: the same
        # comparison names the divergent field(s) in a warning before the
        # overwrite — current == null means no prior state was read at all,
        # so nothing narrower than the full desired set can be sent, and
        # there is no known field to name. The description field's own
        # divergence is reported through the boundary's warnings above, not
        # this per-field one, so it is compared and merged separately.
        local filtered diverged warning=""
        if [[ "${current}" == "null" ]]; then
          filtered="${desired}"
        else
          filtered="$(jq -cn --argjson cur "${cur_rest}" --argjson des "${des_rest}" \
            '[ $des | to_entries[] | select(.value != ($cur[.key])) ] | from_entries')"
          if [[ "${desc_st}" == "changed" ]]; then
            filtered="$(jq -c --argjson d "$(jq -c '.description' <<< "${desired}")" '. + {description:$d}' <<< "${filtered}")"
          fi
          if [[ "${summary_changed}" == "true" ]]; then
            filtered="$(jq -c --arg s "${final_summary}" '. + {summary:$s}' <<< "${filtered}")"
          fi
          # `labels` is excluded from the divergence naming (017 FR-011): a
          # sub-task that merely lacks its provenance label has not diverged
          # from the specification, and back-filling it must stay as silent
          # on the task tier as it is on the story tier.
          diverged="$(jq -rn --argjson cur "${cur_rest}" --argjson des "${des_rest}" \
            '[ $des | to_entries[] | select(.key != "labels") | select(.value != ($cur[.key])) | .key ] | join(", ")')"
          [[ -n "${diverged}" ]] && warning="${ticket} diverges from the specification on \"${diverged}\"; only the differing field(s) will be written"
        fi

        # identity_stamp (018, T048, contracts/summary-record.md §2): the
        # record is written only after a payload that ACTUALLY carries
        # `summary` — decided from `filtered`, the payload this action will
        # really send, not from whether a value was merely computed above.
        if jq -e 'has("summary")' > /dev/null 2>&1 <<< "${filtered}"; then
          identity_stamp="$(jq -cn --arg o "$(jq -r --arg t "${tid}" '.ticket_origins[$t] // "bridge"' <<< "${ctx}")" \
            --arg st "${tid}" --arg sm "${final_summary}" '{origin:$o, story:$st, role:"task", summary:$sm}')"
        fi

        if [[ -n "${warning}" ]]; then
          action="$(jq -cn --arg u "${base}/rest/api/3/issue/${ticket}" --argjson f "${filtered}" --arg w "${warning}" --argjson stamp "${identity_stamp}" \
            '{method:"PUT", url:$u, body:{fields:$f}, role:"task", warning:$w} + (if $stamp == null then {} else {identity_stamp:$stamp} end)')"
        else
          action="$(jq -cn --arg u "${base}/rest/api/3/issue/${ticket}" --argjson f "${filtered}" --argjson stamp "${identity_stamp}" \
            '{method:"PUT", url:$u, body:{fields:$f}, role:"task"} + (if $stamp == null then {} else {identity_stamp:$stamp} end)')"
        fi
      fi
      actions="$(jq -c --argjson a "${action}" '. + [$a]' <<< "${actions}")"
    done
  done
  local _out
  # shellcheck disable=SC2016  # a jq filter: $a/$w are jq variables
  _out="$(json_build '{actions:$a, warnings:$w}' a "${actions}" w "${warnings}")" || return $?
  printf '%s' "${_out}" | json_canonical
}

# _plan_transition_action <base_url> <key> <transition_id> <blockers-json> <label>
#   [role] [declared-step]
#   The single transition-POST emission site (012, T091), shared by
#   plan_lifecycle (story tier) and plan_lifecycle_tasks (task tier) rather
#   than each building its own. Returns {action, note} — note is empty when
#   the ticket carries no open blocking link. `role`/`declared-step` (023,
#   T115) ride along on the action itself — never sent to Jira,
#   `_plan_apply_write` only reads method/url/body off it — so a write-time
#   rejection can be reported naming the ticket, its role, and the step it
#   was headed for (FR-038) without a second lookup. Passed only by the
#   transition-resolution.md call sites (contract §2); the task tier's own
#   done/not-done completion pass predates 023 and is out of this
#   requirement's scope, so its calls leave both empty.
_plan_transition_action() {
  local base="$1" key="$2" transition_id="$3" blockers="$4" label="$5" role="${6:-}" declared_step="${7:-}"
  local taction
  taction="$(jq -cn --arg u "${base}/rest/api/3/issue/${key}/transitions" --arg tid "${transition_id}" \
    --arg role "${role}" --arg step "${declared_step}" \
    '{method:"POST", url:$u, body:{transition:{id:$tid}}}
     + (if $role != "" then {role:$role, declared_step:$step} else {} end)')"
  local note=""
  local bcount; bcount="$(jq 'length' <<< "${blockers}")"
  if [[ "${bcount}" -gt 0 ]]; then
    local blist
    blist="$(jq -r 'join(", ")' <<< "${blockers}")"
    note="transition of \"${label}\" proceeds with open blocking links (${blist}); human-created links are left unchanged"
  fi
  jq -cn --argjson a "${taction}" --arg n "${note}" '{action:$a, note:(if $n == "" then null else $n end)}'
}

# _plan_transition_warning <outcome-json> <role> <key> <declared-step>
#   <current-status> — contracts/transition-resolution.md §4's verbatim
#   wording for the three non-move outcomes (never called for "move"). Every
#   non-move outcome now carries exactly one warning naming the ticket, its
#   role, what did not happen, and what a human can do (FR-038,
#   Principle XVI) — replacing the silent drop plan_lifecycle used to
#   produce whenever `transition_id` was empty.
_plan_transition_warning() {
  local outcome="$1" role="$2" key="$3" declared="$4" current="$5"
  local role_label; role_label="$(tr '[:lower:]' '[:upper:]' <<< "${role:0:1}")${role:1}"
  local kind; kind="$(jq -r '.outcome' <<< "${outcome}")"
  case "${kind}" in
    ambiguous)
      local n names
      n="$(jq '.candidates | length' <<< "${outcome}")"
      names="$(jq -r '[.candidates[] | "\(.name) (\(.id))"] | join(", ")' <<< "${outcome}")"
      printf '%s ticket %s was not moved to "%s": %s transitions land on it (%s). The bridge invents no preference — perform the one you want by hand, or narrow the workflow.' \
        "${role_label}" "${key}" "${declared}" "${n}" "${names}"
      ;;
    gated)
      local field; field="$(jq -r '.gated_field.logical_name' <<< "${outcome}")"
      printf '%s ticket %s was not moved to "%s": completing that transition requires "%s", which the bridge does not hold and never guesses. Set it by hand, then reconcile.' \
        "${role_label}" "${key}" "${declared}" "${field}"
      ;;
    unreachable)
      local rn rl
      rn="$(jq '.reachable | length' <<< "${outcome}")"
      if ((rn > 0)); then
        rl="$(jq -r '.reachable | join(", ")' <<< "${outcome}")"
        printf '%s ticket %s was not moved to "%s": no transition from "%s" lands on it. Reachable from here: %s. Move it by hand, or map this event to one of those.' \
          "${role_label}" "${key}" "${declared}" "${current}" "${rl}"
      else
        printf '%s ticket %s was not moved to "%s": no transition from "%s" is available at all. Move it by hand, or map this event to a reachable step.' \
          "${role_label}" "${key}" "${declared}" "${current}"
      fi
      ;;
  esac
}

# plan_lifecycle <content-actions-json> <neutral-doc-json> <lifecycle-ctx-json>
#   [parent-content-action-json]
#   Fold the US6 lifecycle-safety rules over the planned content actions and emit
#   the final action set plus the human-facing warnings/notes. PURE except for
#   the read transitions_load issues (see below): the current Jira facts
#   (status, its classification, Flagged marker, open blockers) arrive in the
#   lifecycle context — the seam the config/discovery integration fills from a
#   fail-closed read. content-actions[i] corresponds to neutral-doc.stories[i]
#   (plan_writes emits one content action per story, in order).
#
#   023, research R6/contract §5 U8: the OPTIONAL 4th argument is the
#   parent's own content action (`_plan_writes_parent`'s return, or "null"/
#   absent) — the same per-ticket body below runs over the parent too, keyed
#   by `lc.parent_local_id`, so its decisions and warning wording are
#   identical to a story's BY CONSTRUCTION. Its content is never re-appended
#   to the returned `actions`: `_plan_writes_parent` already decided it and
#   it travels through the plan's own `parent` slot; only the parent's
#   TRANSITION (if any) joins the returned array, exactly like a transition
#   already rides alongside a story's content action there.
#
# lifecycle-ctx: { on_drift, base_url, order:{<role>:[status,...]},
#   parent_local_id, tickets:{ <local_id>: { key, current:{fields...}, status,
#     category, target, role, transition_id, flagged, blockers:[...] } } }
#
# Rules applied per ticket:
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
#   - Resolution (023, contract transition-resolution.md §1-§4): when the
#     ticket's context ALREADY carries a `transition_id` (the
#     SPEC_KIT_JIRA_LIFECYCLE test seam supplying one directly), it is used
#     as-is — unchanged from before this feature. Otherwise the ticket joins
#     the due set: one read (transitions_load, called ONCE for the whole due
#     set — T047) resolves every candidate move by destination NAME, never
#     category (contract M1). A `move` outcome fills transition_id and emits
#     it exactly as today; every other outcome emits exactly one warning
#     naming the ticket, never a silent drop (contract §4).
#
# Returns { actions, warnings, notes } (canonical) on success. On a
# transitions-read failure (contract §2 F2 — the authoritative read
# exhausted retries), returns the failing exit code with
# {"fail_closed_key": "<key>"} on stdout instead — fail-closed for the WHOLE
# specification: the content actions already gathered are discarded, never
# returned, so the caller writes nothing for this run.
plan_lifecycle() {
  local actions="$1" doc="$2" lc="$3" parent_action="${4:-null}"
  local on_drift order_by_role n i
  on_drift="$(jq -r '.on_drift // "abort"' <<< "${lc}")"
  order_by_role="$(jq -c '.order // {}' <<< "${lc}")"

  # 024, contracts/spawn-budget.md C1.2/C1.3: the loop below used to re-read
  # `.stories[i].local_id`, `.[i]` (the action), `.method`, and six fields of
  # the matched ticket — ten `jq` calls per story, every one of them a pure
  # read — with their OWN `jq` call per story. One call decodes all of it
  # for the WHOLE array instead, matching `.[i] // null`'s exact semantics
  # (a shorter `actions` array than `doc.stories`, `$acts[$i]` past the end,
  # is `null` in jq too — the same as the per-index `// null` it replaces).
  local _lc_sep=$'\x1f'
  local -a _lc_sid=() _lc_action=() _lc_method=() _lc_tk=() _lc_status=() _lc_target=() \
    _lc_category=() _lc_flagged=() _lc_transition_id=() _lc_key=() _lc_blockers=() _lc_role=()
  local _lc_i=0 _f1 _f2 _f3 _f4 _f5 _f6 _f7 _f8 _f9 _f10 _f11 _f12
  # 024, T053 real-machine finding: `actions` and `doc` both grow with story
  # count, and Linux caps a SINGLE jq argument at MAX_ARG_STRLEN (128 KiB)
  # independently of the much larger total ARG_MAX (research/#31's original
  # fix for the same class of defect, at different call sites — see
  # lib/output.sh's `json_build`). A hundred-story specification's `actions`
  # crossed that cap here and failed with E2BIG on Linux only (never on
  # macOS, which has no per-argument limit) — reproduced in a Ubuntu
  # container, not inferred. `json_build` itself is `-cn`-shaped (null input,
  # builds a JSON value) and this call is `-r` over a real `<<<` input, so
  # its exact mechanism — a temp file plus `--slurpfile` instead of
  # `--argjson` — is inlined here rather than forcing this call into
  # `json_build`'s shape.
  local _lc_acts_f _lc_lc_f _lc_acts_arg _lc_lc_arg
  _lc_acts_f="$(mktemp)"; printf '%s' "${actions}" > "${_lc_acts_f}"
  _lc_lc_f="$(mktemp)"; printf '%s' "${lc}" > "${_lc_lc_f}"
  _lc_acts_arg="$(json_path_arg "${_lc_acts_f}")"
  _lc_lc_arg="$(json_path_arg "${_lc_lc_f}")"
  while IFS="${_lc_sep}" read -r _f1 _f2 _f3 _f4 _f5 _f6 _f7 _f8 _f9 _f10 _f11 _f12; do
    _lc_sid[_lc_i]="${_f1}"; _lc_action[_lc_i]="${_f2}"; _lc_method[_lc_i]="${_f3}"
    _lc_tk[_lc_i]="${_f4}"; _lc_status[_lc_i]="${_f5}"; _lc_target[_lc_i]="${_f6}"
    _lc_category[_lc_i]="${_f7}"; _lc_flagged[_lc_i]="${_f8}"; _lc_transition_id[_lc_i]="${_f9}"
    _lc_key[_lc_i]="${_f10}"; _lc_blockers[_lc_i]="${_f11}"; _lc_role[_lc_i]="${_f12}"
    _lc_i=$((_lc_i + 1))
  done < <(jq -r --arg sep "${_lc_sep}" --slurpfile acts_f "${_lc_acts_arg}" --slurpfile lc_f "${_lc_lc_arg}" '
    ($acts_f[0]) as $acts | ($lc_f[0]) as $lc |
    .stories | to_entries[] | (.value.local_id) as $sid | (($acts[.key]) // null) as $act |
    (($lc.tickets[$sid]) // {}) as $tk | [
      $sid,
      ($act | tostring),
      (if $act == null then "" else ($act.method // "") end),
      ($tk | tostring),
      ($tk.status // ""), ($tk.target // ""), ($tk.category // "unknown"),
      (($tk.flagged // false) | tostring), ($tk.transition_id // ""), ($tk.key // ""),
      ($tk.blockers // [] | tostring), ($tk.role // "story")
    ] | join($sep)
  ' <<< "${doc}")
  rm -f "${_lc_acts_f}" "${_lc_lc_f}"
  n="${_lc_i}"

  # 023, research R6: the parent gets one more entry in the SAME arrays, so
  # the per-ticket body below — zero-churn drop, flagged check,
  # drift_evaluate, transition — runs over it unchanged (contract §5 U8).
  # Appended after the decode-once call rather than inside it: there is
  # exactly one parent per run, so the extra `jq` calls here cost nothing
  # the decode-once shape (built for the STORY count) exists to avoid.
  local -a _lc_is_parent=()
  local parent_lid; parent_lid="$(jq -r '.parent_local_id // ""' <<< "${lc}")"
  if [[ -n "${parent_lid}" ]]; then
    local ptk parent_entry_action; ptk="$(jq -c --arg id "${parent_lid}" '.tickets[$id] // {}' <<< "${lc}")"
    # 023 fix: the parent has no pending CONTENT write on a run where its
    # content is unchanged (parent_action is the literal string "null"
    # then) — that must never suppress its own lifecycle-safety
    # evaluation, exactly as a story with no content change still reaches
    # drift_evaluate. A story always has a real action to decode-once
    # here; the parent, gated separately in reconcile.sh, does not — so an
    # empty placeholder stands in only when there is no real one, never
    # treated as a content write (_lc_is_parent[n] below already excludes
    # the parent from `kept` unconditionally).
    parent_entry_action="${parent_action}"
    [[ "${parent_entry_action}" == "null" ]] && parent_entry_action='{}'
    _lc_sid[n]="${parent_lid}"
    _lc_action[n]="${parent_entry_action}"
    _lc_method[n]="$(jq -r '.method // ""' <<< "${parent_entry_action}")"
    _lc_tk[n]="${ptk}"
    _lc_status[n]="$(jq -r '.status // ""' <<< "${ptk}")"
    _lc_target[n]="$(jq -r '.target // ""' <<< "${ptk}")"
    _lc_category[n]="$(jq -r '.category // "unknown"' <<< "${ptk}")"
    _lc_flagged[n]="$(jq -r '(.flagged // false) | tostring' <<< "${ptk}")"
    _lc_transition_id[n]="$(jq -r '.transition_id // ""' <<< "${ptk}")"
    _lc_key[n]="$(jq -r '.key // ""' <<< "${ptk}")"
    _lc_blockers[n]="$(jq -c '.blockers // []' <<< "${ptk}")"
    _lc_role[n]="$(jq -r '.role // "specification"' <<< "${ptk}")"
    _lc_is_parent[n]="true"
    n=$((n + 1))
  fi

  local kept="[]" warns="[]" notes="[]" parent_content_dropped="false"
  local -a due_idx=()
  for ((i = 0; i < n; i++)); do
    local sid action method tk
    sid="${_lc_sid[i]}"
    action="${_lc_action[i]}"
    [[ "${action}" == "null" ]] && continue
    method="${_lc_method[i]}"
    tk="${_lc_tk[i]}"

    local drop_content="false"
    # --- Zero churn: drop an unchanged UPDATE ---------------------------------
    # The managed-panel path is now UNCONDITIONAL (018, T026): every
    # recognised ticket's description churn is decided on its managed
    # section alone (FR-009), regardless of origin.
    if [[ "${method}" == "PUT" ]]; then
      local current
      current="$(jq -c '.current // null' <<< "${tk}")"
      if [[ "${current}" != "null" ]]; then
        local desired desc_st="unchanged" other_st cur_rest des_rest
        desired="$(jq -c '.body.fields' <<< "${action}")"
        if jq -e 'has("description")' <<< "${desired}" > /dev/null 2>&1; then
          local cur_desc new_desc
          cur_desc="$(jq -c '.description // {}' <<< "${current}")"
          new_desc="$(jq -c '.description' <<< "${desired}")"
          desc_st="$(plan_managed_description_status "${cur_desc}" "${new_desc}")"
        fi
        cur_rest="$(jq -c 'del(.description)' <<< "${current}")"
        des_rest="$(jq -c 'del(.description)' <<< "${desired}")"
        other_st="$(idempotency_field_status "${cur_rest}" "${des_rest}")"
        [[ "${desc_st}" == "unchanged" && "${other_st}" == "unchanged" ]] && drop_content="true"
      fi
    fi

    # --- Drift / Flagged: decide the transition -------------------------------
    local status target category flagged transition_id key role_order
    status="${_lc_status[i]}"
    target="${_lc_target[i]}"
    category="${_lc_category[i]}"
    flagged="${_lc_flagged[i]}"
    transition_id="${_lc_transition_id[i]}"
    key="${_lc_key[i]}"
    # 023, data-model.md §1: `order` is now PER ROLE — a specification and a
    # story on different workflows are never compared against each other's
    # step order (contract role-lifecycle-config.md §5 I1).
    role_order="$(jq -c --arg r "${_lc_role[i]:-story}" '.[$r] // []' <<< "${order_by_role}")"

    if [[ -n "${status}" && -n "${target}" && "${status}" != "${target}" ]]; then
      if [[ "${flagged}" == "true" ]]; then
        warns="$(jq -c --arg w "ticket \"${sid}\" carries the Flagged (impediment) marker; its transition is withheld and the flag is left untouched" '. + [$w]' <<< "${warns}")"
      else
        local di dec d cw dwarns
        di="$(jq -cn --arg cs "${status}" --arg cc "${category}" --arg ts "${target}" --argjson o "${role_order}" --arg od "${on_drift}" \
          '{current_status:$cs, current_category:$cc, target_status:$ts, order:$o, on_drift:$od}')"
        dec="$(drift_evaluate "${di}")"
        d="$(jq -r '.decision' <<< "${dec}")"
        cw="$(jq -r '.content_writes' <<< "${dec}")"
        dwarns="$(jq -c '.warnings' <<< "${dec}")"
        warns="$(jq -c --argjson dw "${dwarns}" '. + $dw' <<< "${warns}")"
        [[ "${cw}" == "false" ]] && drop_content="true"
        if [[ "${d}" == "transition" && -n "${key}" ]]; then
          if [[ -n "${transition_id}" ]]; then
            # The SPEC_KIT_JIRA_LIFECYCLE test seam already supplies an id
            # directly — unchanged from before this feature; resolution is
            # never consulted for a ticket that already has one.
            local tres note
            tres="$(_plan_transition_action "$(jq -r '.base_url // ""' <<< "${lc}")" "${key}" "${transition_id}" "${_lc_blockers[i]}" "${sid}")"
            kept="$(jq -c --argjson a "$(jq -c '.action' <<< "${tres}")" '. + [$a]' <<< "${kept}")"
            note="$(jq -r '.note // empty' <<< "${tres}")"
            [[ -n "${note}" ]] && notes="$(jq -c --arg n "${note}" '. + [$n]' <<< "${notes}")"
          else
            due_idx+=("${i}")
          fi
        fi
      fi
    fi

    if [[ "${_lc_is_parent[i]:-false}" == "true" ]]; then
      # 023, U8: the parent's own halt decision (drop_content, set only by
      # drift_evaluate's "halted" branch) is never routed through `kept` —
      # the parent's content write is a SEPARATE code path in the caller
      # (reconcile.sh's own parent-first write, never this array) — so it
      # must ride back out as its own field or the caller has no way to
      # learn a halted parent's content must stay unwritten too, exactly
      # like a halted story's.
      parent_content_dropped="${drop_content}"
    elif [[ "${drop_content}" == "false" ]]; then
      kept="$(jq -c --argjson a "${action}" '. + [$a]' <<< "${kept}")"
    fi
  done

  # Resolution (023, contract transition-resolution.md §1/§2): the read is
  # issued only for the due set assembled above — D1-D5 already hold for
  # every entry in due_idx — and ONCE for the whole set, never per ticket
  # (T047). A failure fails closed for the WHOLE specification: the content
  # actions already gathered above are discarded (never returned), not only
  # the moves (contract §2 F2).
  if ((${#due_idx[@]} > 0)); then
    local -a due_keys=()
    local di
    for di in "${due_idx[@]}"; do due_keys+=("${_lc_key[di]}"); done
    local rc_tl=0
    transitions_load "${due_keys[@]}" || rc_tl=$?
    if ((rc_tl != 0)); then
      jq -cn --arg k "${due_keys[0]}" '{fail_closed_key:$k}'
      return "${rc_tl}"
    fi
    local base; base="$(jq -r '.base_url // ""' <<< "${lc}")"

    # 023, T182 (Phase 14, Convergence): decode-once resolution — one jq call
    # resolves EVERY due ticket's outcome at once against the transitions
    # map transitions_load already populated in-process (_TRANSITIONS_MAP),
    # replacing what used to be transitions_get + transitions_resolve (2 jq
    # spawns each, transitions_resolve's own call plus json_canonical's)
    # PLUS a redundant outer `.outcome`/`.transition_id` re-parse, per due
    # ticket (FR-028, SC-013, contract transition-resolution.md §6 B3).
    # _plan_transition_action/_plan_transition_warning are left unchanged:
    # they are shared with reconcile.sh's own task-tier due-set and with
    # the transition_id-already-known branch above, so widening past this
    # read/parse plumbing into shared per-item business logic is the
    # "separate, larger, riskier refactor" T155 already deferred.
    local _tr_sep=$'\x1f'
    local -a due_sids=()
    for di in "${due_idx[@]}"; do due_sids+=("${_lc_sid[di]}"); done

    # _TRANSITIONS_MAP's keys are lower-cased Jira issue keys
    # (`[a-z][a-z0-9]*-[0-9]+`, transitions_load's own trust boundary) and
    # its values are already-canonical compact JSON — safe to concatenate
    # into one object with no escaping, exactly as transitions_load builds
    # its own combined request array.
    local _tr_map="{" _tr_map_first=true _tr_mk
    for _tr_mk in "${!_TRANSITIONS_MAP[@]}"; do
      if ${_tr_map_first}; then _tr_map_first=false; else _tr_map+=","; fi
      _tr_map+="\"${_tr_mk}\":${_TRANSITIONS_MAP[${_tr_mk}]}"
    done
    _tr_map+="}"
    local _tr_map_f; _tr_map_f="$(mktemp)"
    printf '%s' "${_tr_map}" > "${_tr_map_f}"
    local _tr_map_arg; _tr_map_arg="$(json_path_arg "${_tr_map_f}")"

    local -a _tr_kind=() _tr_tid=() _tr_outcome=()
    local _tr_i=0 _r1 _r2 _r3
    while IFS="${_tr_sep}" read -r _r1 _r2 _r3; do
      _tr_kind[_tr_i]="${_r1}"; _tr_tid[_tr_i]="${_r2}"; _tr_outcome[_tr_i]="${_r3}"
      _tr_i=$((_tr_i + 1))
    done < <(jq -rn --argjson lc "${lc}" --slurpfile trmap_f "${_tr_map_arg}" --arg sep "${_tr_sep}" '
      ($trmap_f[0]) as $trmap
      | ($ARGS.positional) as $sids
      | $sids[] as $sid
      | ($lc.tickets[$sid]) as $tk
      | (($tk.key // "") | ascii_downcase) as $kl
      | ($trmap[$kl] // {moves: []}) as $rec
      | (($tk.target) // "") as $declared
      | ($rec.moves // []) as $moves
      | [ $moves[] | select(.to == $declared) ] as $cands
      | ($cands | length) as $n
      | ( if $n == 1 and $cands[0].gated_field == null then
            {outcome:"move", transition_id: $cands[0].id}
          elif $n == 1 then
            {outcome:"gated", gated_field: $cands[0].gated_field}
          elif $n >= 2 then
            {outcome:"ambiguous", candidates: [ $cands[] | {id, name} ]}
          else
            {outcome:"unreachable", reachable: [ $moves[].to ]}
          end
        ) as $o
      | [ $o.outcome, ($o.transition_id // ""), ($o | tojson) ] | join($sep)
    ' --args -- "${due_sids[@]}")
    rm -f "${_tr_map_f}"

    local -a _tr_kept=() _tr_new_warns=() _tr_new_notes=()
    local _tr_j
    for ((_tr_j = 0; _tr_j < ${#due_idx[@]}; _tr_j++)); do
      local di="${due_idx[_tr_j]}"
      local rkey rsid rtarget rstatus rrole kind outcome
      rkey="${_lc_key[di]}"; rsid="${_lc_sid[di]}"; rtarget="${_lc_target[di]}"
      rstatus="${_lc_status[di]}"; rrole="${_lc_role[di]:-story}"
      kind="${_tr_kind[_tr_j]}"; outcome="${_tr_outcome[_tr_j]}"
      if [[ "${kind}" == "move" ]]; then
        local tid tres note
        tid="${_tr_tid[_tr_j]}"
        tres="$(_plan_transition_action "${base}" "${rkey}" "${tid}" "${_lc_blockers[di]}" "${rsid}" "${rrole}" "${rtarget}")"
        _tr_kept+=("$(jq -c '.action' <<< "${tres}")")
        note="$(jq -r '.note // empty' <<< "${tres}")"
        [[ -n "${note}" ]] && _tr_new_notes+=("${note}")
      else
        local w; w="$(_plan_transition_warning "${outcome}" "${rrole}" "${rkey}" "${rtarget}" "${rstatus}")"
        _tr_new_warns+=("${w}")
      fi
    done

    # One merge each, regardless of how many due tickets resolved to that
    # branch — the same "decode/encode once" shape as the arrays above,
    # replacing what used to be a `. + [$x]` jq call per due ticket.
    if ((${#_tr_kept[@]} > 0)); then
      local _tr_kept_f; _tr_kept_f="$(mktemp)"
      printf '%s\n' "${_tr_kept[@]}" > "${_tr_kept_f}"
      # json_path_arg, like the two calls above in this file: the path is being
      # handed to jq to OPEN, and a native jq.exe cannot resolve an MSYS
      # `/tmp/…`. This one was missed when the other two were translated.
      kept="$(jq -c --slurpfile add "$(json_path_arg "${_tr_kept_f}")" '. + $add' <<< "${kept}")"
      rm -f "${_tr_kept_f}"
    fi
    if ((${#_tr_new_warns[@]} > 0)); then
      local _tr_warns_f; _tr_warns_f="$(mktemp)"
      printf '%s\n' "${_tr_new_warns[@]}" > "${_tr_warns_f}"
      warns="$(jq -c --argjson add "$(jq -Rs 'split("\n") | map(select(length > 0))' "${_tr_warns_f}")" '. + $add' <<< "${warns}")"
      rm -f "${_tr_warns_f}"
    fi
    if ((${#_tr_new_notes[@]} > 0)); then
      local _tr_notes_f; _tr_notes_f="$(mktemp)"
      printf '%s\n' "${_tr_new_notes[@]}" > "${_tr_notes_f}"
      notes="$(jq -c --argjson add "$(jq -Rs 'split("\n") | map(select(length > 0))' "${_tr_notes_f}")" '. + $add' <<< "${notes}")"
      rm -f "${_tr_notes_f}"
    fi
  fi

  local _out
  # shellcheck disable=SC2016  # a jq filter: $a/$w/$no/$pcd are jq variables
  _out="$(json_build '{actions:$a, warnings:$w, notes:$no, parent_content_dropped:$pcd}' \
    a "${kept}" w "${warns}" no "${notes}" pcd "${parent_content_dropped}")" || return $?
  printf '%s' "${_out}" | json_canonical
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

  # shellcheck disable=SC2016  # a jq filter: $a/$w/$no are jq variables
  local _out
  # shellcheck disable=SC2016  # a jq filter: $a/$w/$no are jq variables
  _out="$(json_build '{actions:$a, warnings:$w, notes:$no}' \
    a "${kept}" w "${warns}" no "${notes}")" || return $?
  printf '%s' "${_out}" | json_canonical
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
  if [[ "${method}" == "POST" && "${url}" == */transitions ]]; then
    _plan_apply_report_transition_rejection "${url}" "${action}"
    return 0
  fi
  [[ "${method}" == "POST" && "${url}" == */issue && "${JIRA_LAST_STATUS:-}" == "400" ]] || return 0
  local msg
  msg="$(ticket_field_rejection_message "${defaultable_by_type}" "${action}" "${JIRA_LAST_ERROR_BODY:-{\}}")"
  [[ -n "${msg}" ]] && printf '%s\n' "${msg}" >&2
}

# _plan_apply_report_transition_rejection <url> <action-json> — 023, T115,
# FR-035/FR-038: the tracker rejected a move `_plan_transition_action`
# already decided was available (a human moved the ticket between the read
# and this write, or the tracker's own workflow changed underneath it). A
# no-op unless `action` carries the `role`/`declared_step` pair only the
# transition-resolution.md call sites attach (see `_plan_transition_action`)
# — the task tier's own done/not-done completion pass predates 023 and stays
# silent here, exactly as before this feature. No retry, no re-ask of
# available moves, no substitute move within this run: the caller already
# returns immediately after calling this (contract §2 U6).
_plan_apply_report_transition_rejection() {
  local url="$1" action="$2"
  local role; role="$(jq -r '.role // empty' <<< "${action}")"
  [[ -z "${role}" ]] && return 0
  local declared key role_label errbody reason
  declared="$(jq -r '.declared_step // empty' <<< "${action}")"
  key="$(sed -E 's#.*/issue/##; s#/transitions$##' <<< "${url}")"
  role_label="$(tr '[:lower:]' '[:upper:]' <<< "${role:0:1}")${role:1}"
  errbody="${JIRA_LAST_ERROR_BODY:-{\}}"
  jq -e . > /dev/null 2>&1 <<< "${errbody}" || errbody='{}'
  reason="$(jq -r '
    [ (.errorMessages // [])[], ((.errors // {}) | to_entries[] | "\(.key): \(.value)") ] | join("; ")
  ' <<< "${errbody}")"
  [[ -z "${reason}" ]] && reason="the tracker gave no reason"
  printf 'reconcile: %s ticket %s was not moved to "%s": the tracker rejected the transition — %s. It was not retried, and no other move was attempted for it, within this run; reconcile will read its available moves again next run.\n' \
    "${role_label}" "${key}" "${declared}" "${reason}" >&2
}

# _plan_apply_write <method> <url> <body-json-or-empty> <resp-file> — the
# single write primitive every write loop in this file goes through. 018,
# T068, contract managed-description §2, FR-011: on a PUT whose body carries
# a `description` field and Jira rejects it (400, `errors.description`
# present), the write is retried ONCE with `description` stripped from the
# payload and one warning is printed to stderr naming the ticket key —
# EVERY OTHER field of that ticket still reconciles, and the caller sees the
# retried result (success or otherwise), never the original rejection: the
# host's exit code is unaffected by a description-only rejection. A
# rejection that does not name `description`, or a non-PUT method, is left
# to the existing generic failure path (the caller's own rc >= 2 handling)
# untouched.
# _plan_apply_stamp_identity <issue-key> <spec-ref-json> <action-json> —
# 018, T048, contracts/summary-record.md §2: stamp the identity marker with
# `action.identity_stamp` when the action carries one — a no-op when it
# does not (the payload never carried `summary`, so nothing is recorded).
# Called after EVERY successful write (create or update), on both tiers'
# every role, so this is the single site that decides whether the record
# advances this run.
_plan_apply_stamp_identity() {
  local key="$1" spec_ref="$2" action="$3"
  local stamp; stamp="$(jq -c '.identity_stamp // null' <<< "${action}")"
  [[ "${stamp}" == "null" || -z "${key}" ]] && return 0
  local origin story role summary
  origin="$(jq -r '.origin // "bridge"' <<< "${stamp}")"
  story="$(jq -r '.story // ""' <<< "${stamp}")"
  role="$(jq -r '.role // ""' <<< "${stamp}")"
  summary="$(jq -r '.summary // ""' <<< "${stamp}")"
  identity_write "${key}" "${spec_ref}" "${origin}" "${story}" "${role}" "${summary}" || true
}

_plan_apply_write() {
  local method="$1" url="$2" body="$3" resp="$4"
  if [[ -n "${body}" ]]; then
    jira_request "${method}" "${url}" "${body}" > "${resp}"
  else
    jira_request "${method}" "${url}" > "${resp}"
  fi
  local rc=$?
  if ((rc >= 2)) && [[ "${method}" == "PUT" && "${JIRA_LAST_STATUS:-}" == "400" && -n "${body}" ]]; then
    local has_desc
    has_desc="$(jq -r '(.fields | has("description")) // false' <<< "${body}" 2> /dev/null)"
    if [[ "${has_desc}" == "true" ]]; then
      local errbody="${JIRA_LAST_ERROR_BODY:-{\}}"
      jq -e . > /dev/null 2>&1 <<< "${errbody}" || errbody='{}'
      local desc_reason
      desc_reason="$(jq -r '.errors.description // empty' <<< "${errbody}")"
      if [[ -n "${desc_reason}" ]]; then
        local key
        key="$(sed -E 's#.*/issue/##' <<< "${url}")"
        printf 'reconcile: Jira rejected the description for %s — %s. No description was written for %s; every other field still reconciled.\n' \
          "${key}" "${desc_reason}" "${key}" >&2
        local stripped
        stripped="$(jq -c 'del(.fields.description)' <<< "${body}")"
        jira_request "${method}" "${url}" "${stripped}" > "${resp}"
        rc=$?
      fi
    fi
  fi
  return "${rc}"
}

# _plan_apply_privacy_projection <body-json> — 018, T018, contract §5, FR-024a:
# the projection of a payload handed to the pre-write privacy scan, excluding
# the description's preserved human prefix. The guard's own rules (privacy_guard.sh)
# are untouched; only what reaches them changes. The preserved prefix is a
# verbatim round-trip — read from this ticket and written back to it — so it
# cannot carry anything into the tracker the tracker does not already hold.
# Splits the description's content at the managed-panel marker (structural,
# not configurable) and scans only the managed portion (the marker node
# onward) plus every other field, exactly as before this feature. A payload
# with no description field, a description that is not an ADF object, or a
# description with no content array, is unchanged.
_plan_apply_privacy_projection() {
  local body="$1" content
  content="$(jq -c '(.fields.description.content)? // null' <<< "${body}")"
  [[ "${content}" == "null" || -z "${content}" ]] && { printf '%s' "${body}"; return 0; }
  local managed
  managed="$(printf '%s' "${content}" | managed_section_panel_split "$(adf_managed_marker)" | jq -c '.managed')"
  jq -c --argjson m "${managed}" 'if (.fields.description | type) == "object" then (.fields.description.content = $m) else . end' <<< "${body}"
}

# _apply_writes_decode_rows <actions-json> <sep> — one row per action,
# `<sep>`-joined method/url/body(compact JSON or the literal "null"). The
# WHOLE array decoded by one `jq` call regardless of action count (024,
# C1.2) — split out so the count itself is directly testable
# (test_plan_apply_spawn_budget.bats), the same shape as parse.sh's
# `_parse_lines_to_json`.
_apply_writes_decode_rows() {
  local actions="$1" sep="$2"
  jq -r --arg sep "${sep}" '.[] | [.method, .url, ((.body // null) | tostring)] | join($sep)' <<< "${actions}"
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

  # 024, C1.2/C1.3: both loops below used to re-read `.method`/`.url`/`.body`
  # off `actions` with their OWN `jq` call per action, per loop (up to 3N+3N
  # calls for N actions). One `jq -c` call decodes the WHOLE array into
  # parallel bash arrays instead — `\x1f` (not a literal tab: bash's `read`
  # treats tab as IFS *whitespace* and silently squeezes an empty field, the
  # same defect fixed in recognition.sh) separates the three columns, `\n`
  # separates the rows; `.body`'s own compact JSON can never contain a raw
  # 0x1f byte (jq escapes every control character in a string value), so it
  # is safe as a field inside this row.
  local _aw_sep=$'\x1f'
  local -a _amethod=() _aurl=() _abody=()
  local _aw_i=0 _aw_method _aw_url _aw_body
  while IFS="${_aw_sep}" read -r _aw_method _aw_url _aw_body; do
    _amethod[_aw_i]="${_aw_method}"
    _aurl[_aw_i]="${_aw_url}"
    _abody[_aw_i]="${_aw_body}"
    _aw_i=$((_aw_i + 1))
  done < <(_apply_writes_decode_rows "${actions}" "${_aw_sep}")
  local n="${_aw_i}"

  # (1) Pre-write gate — scan every content payload before writing anything.
  local i body
  for ((i = 0; i < n; i++)); do
    body="${_abody[i]}"
    [[ "${body}" == "null" ]] && body="{}"
    privacy_guard_scan "$(_plan_apply_privacy_projection "${body}")" "${coords}" "${allow}" || return $?
  done

  # (2) Write pass — all payloads cleared; perform each write in order. A
  # fail-closed transport result (exit >= 2: fail_closed or auth) ABORTS the
  # remaining writes for this spec and is returned verbatim — no further mutation
  # is attempted once a read/write is unreliable (FR-032, monotonic escalation).
  local worst=0 method url rc
  for ((i = 0; i < n; i++)); do
    method="${_amethod[i]}"
    url="${_aurl[i]}"
    body="${_abody[i]}"
    [[ "${body}" == "null" ]] && body=""
    _plan_apply_write "${method}" "${url}" "${body}" /dev/null
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
#
#   015, research R4, contract §4.2, data-model.md §5: prints one canonical
#   outcome on stdout, {"created": [{key, role, local_id}, ...]} — an entry
#   only after Jira returned a key for that creation, in apply order (the
#   parent first when present, then stories, then 012's tasks) — before
#   returning on each of the four post-write exits (normal completion, parent
#   rejection, story rejection, task rejection). NOT printed on the three
#   pre-write privacy-guard returns above (rule O4): the caller reads empty
#   output as zero created. Nothing else is written to this function's stdout;
#   the rejection message stays on stderr. `role` is "parent", "story", or
#   "task"; the caller filters, because the task tier carries its OWN tally
#   (`counts.tasks`, 012 FR-011) and must not inflate `counts.created`.
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
  local created_out='[]'

  local parent stories
  parent="$(jq -c '.parent' <<< "${plan}")"
  stories="$(jq -c '.stories' <<< "${plan}")"

  # (1) Pre-write gate -- scan every payload, parent then stories then
  # tasks, before writing anything.
  local body
  if [[ "${parent}" != "null" ]]; then
    body="$(jq -c '.body // {}' <<< "${parent}")"
    privacy_guard_scan "$(_plan_apply_privacy_projection "${body}")" "${coords}" "${allow}" || return $?
  fi
  local n i
  n="$(jq 'length' <<< "${stories}")"
  for ((i = 0; i < n; i++)); do
    body="$(jq -c ".[${i}].body // {}" <<< "${stories}")"
    privacy_guard_scan "$(_plan_apply_privacy_projection "${body}")" "${coords}" "${allow}" || return $?
  done
  local tn
  tn="$(jq 'length' <<< "${tasks_actions}")"
  for ((i = 0; i < tn; i++)); do
    body="$(jq -c ".[${i}].body // {}" <<< "${tasks_actions}")"
    privacy_guard_scan "$(_plan_apply_privacy_projection "${body}")" "${coords}" "${allow}" || return $?
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
    _plan_apply_write "${method}" "${url}" "${body}" "${resp}"
    rc=$?
    ((rc > worst)) && worst=${rc}
    if ((rc >= 2)); then
      _plan_apply_report_rejection "${method}" "${url}" "${parent}" "${defaultable_by_type}"
      rm -f "${resp}"
      jq -cn --argjson c "${created_out}" '{created:$c}' | json_canonical
      return "${worst}"
    fi
    if [[ "${method}" == "POST" ]]; then
      parent_key="$(jq -r '.key // empty' < "${resp}")"
      if [[ -n "${parent_key}" && -n "${parent_local_id}" ]]; then
        local cur new
        cur="$(cat "${spec_file}" 2> /dev/null; printf x)"; cur="${cur%x}"
        new="$(printf '%s' "${cur}" | spec_marker_record_ticket "${parent_local_id}" "${parent_key}"; printf x)"; new="${new%x}"
        marker_splice_write_file "${spec_file}" "${new}" > /dev/null
        created_out="$(jq -cn --argjson c "${created_out}" --arg k "${parent_key}" --arg lid "${parent_local_id}" \
          '$c + [{key:$k, role:"parent", local_id:$lid}]')"
      fi
    fi
    _plan_apply_stamp_identity "${parent_key}" "${spec_ref}" "${parent}"
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
    _plan_apply_write "${method}" "${url}" "${body}" "${resp}"
    rc=$?
    ((rc > worst)) && worst=${rc}
    if ((rc >= 2)); then
      _plan_apply_report_rejection "${method}" "${url}" "${action}" "${defaultable_by_type}"
      rm -f "${resp}"
      jq -cn --argjson c "${created_out}" '{created:$c}' | json_canonical
      return "${worst}"
    fi

    if [[ "${method}" == "POST" && "${url}" == */issue ]]; then
      local key local_id
      key="$(jq -r '.key // empty' < "${resp}")"
      local_id="$(jq -r '.local_id // empty' <<< "${action}")"
      if [[ -n "${key}" && -n "${local_id}" ]]; then
        local cur new
        cur="$(cat "${spec_file}" 2> /dev/null; printf x)"; cur="${cur%x}"
        new="$(printf '%s' "${cur}" | story_marker_record_ticket "${local_id}" "${key}"; printf x)"; new="${new%x}"
        marker_splice_write_file "${spec_file}" "${new}" > /dev/null
        story_key_map="$(jq -c --arg id "${local_id}" --arg k "${key}" '. + {($id): $k}' <<< "${story_key_map}")"
        created_out="$(jq -cn --argjson c "${created_out}" --arg k "${key}" --arg lid "${local_id}" \
          '$c + [{key:$k, role:"story", local_id:$lid}]')"
      fi
      _plan_apply_stamp_identity "${key}" "${spec_ref}" "${action}"
    elif [[ "${method}" == "PUT" ]]; then
      _plan_apply_stamp_identity "$(sed -E 's#.*/issue/##' <<< "${url}")" "${spec_ref}" "${action}"
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
    _plan_apply_write "${method}" "${url}" "${body}" "${resp}"
    rc=$?
    ((rc > worst)) && worst=${rc}
    if ((rc >= 2)); then
      _plan_apply_report_rejection "${method}" "${url}" "${taction}" "${defaultable_by_type}"
      rm -f "${resp}"
      jq -cn --argjson c "${created_out}" '{created:$c}' | json_canonical
      return "${worst}"
    fi

    if [[ "${method}" == "POST" && "${url}" == */issue ]]; then
      local tkey tlocal_id
      tkey="$(jq -r '.key // empty' < "${resp}")"
      tlocal_id="$(jq -r '.local_id // empty' <<< "${taction}")"
      if [[ -n "${tkey}" && -n "${tlocal_id}" && -n "${tasks_file}" ]]; then
        local tcur tnew
        tcur="$(cat "${tasks_file}" 2> /dev/null; printf x)"; tcur="${tcur%x}"
        tnew="$(printf '%s' "${tcur}" | task_marker_record_ticket "${tlocal_id}" "${tkey}"; printf x)"; tnew="${tnew%x}"
        marker_splice_write_file "${tasks_file}" "${tnew}" > /dev/null
        created_out="$(jq -cn --argjson c "${created_out}" --arg k "${tkey}" --arg lid "${tlocal_id}" \
          '$c + [{key:$k, role:"task", local_id:$lid}]')"
      fi
      _plan_apply_stamp_identity "${tkey}" "${spec_ref}" "${taction}"
    elif [[ "${method}" == "PUT" ]]; then
      _plan_apply_stamp_identity "$(sed -E 's#.*/issue/##' <<< "${url}")" "${spec_ref}" "${taction}"
    fi
    rm -f "${resp}"
  done
  jq -cn --argjson c "${created_out}" '{created:$c}' | json_canonical
  return "${worst}"
}
