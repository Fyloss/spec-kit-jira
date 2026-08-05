#!/usr/bin/env bash
# commands/reconcile.sh — The reconcile command (US3, T059).
#
# Wires the neutral ENGINE to the Jira SINK: it parses a specification into
# neutral content (title ladder, never-empty description, Gherkin, Design,
# priority, estimation), assembles and schema-VALIDATES the neutral document
# (a validation failure blocks every write, Constitution VIII), plans the ordered
# create/update action set, and applies it through the mandatory pre-write BLOCK
# guard (US11 — no write can bypass it). The declared estimation is written on
# create only and never re-sent on update; every created Story carries a readable
# ladder title and a non-empty structured description.
#
# The reconcile-time facts the engine cannot know (base URL, resolved issue-type
# and priority ids, the estimation field id, and existing ticket refs) are
# supplied as a JSON plan context via SPEC_KIT_JIRA_PLAN_CONTEXT — the seam that
# US2/US8 config integration fills from the discovered binding. base_url always
# comes from SPEC_KIT_JIRA_BASE_URL.

[[ -n ${_JIRA_CMD_RECONCILE:-} ]] && return 0
_JIRA_CMD_RECONCILE=1

_cmd_reconcile_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../lib/cli.sh"
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../engine/parse.sh"
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../engine/interchange.sh"
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../engine/story_marker.sh" # R5 step 1 — assign identifiers
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../engine/task_marker.sh" # Phase 3, US1 — the task tier's own identifier
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../engine/tasks_parse.sh" # Phase 3, US1 — the neutral tasks.md reader
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../sink/jira/hierarchy.sh" # the mandatory-field gate (Phase 6, US3)
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../sink/jira/recognition.sh" # R5 step 2 — recognise recorded tickets
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../sink/jira/plan_apply.sh"
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../sink/jira/discovery.sh" # Phase 8, US5 — the completion pass's transitions read
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../sink/jira/duplicate_probe.sh" # US4, droppable — the second, best-effort guard
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../hooks/register_hooks.sh" # hook health — READ ONLY (003 FR-022)
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../lib/config.sh"          # the operator disable record
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../lib/prereq.sh"          # the bridge-unavailable cause

: "${EXIT_CONFIG:=4}"

# _reconcile_hook_event — the lifecycle event this run was dispatched for, or
# empty when the bridge was invoked directly. The agent sets it from the hook it
# is performing; it is the only thing that tells the bridge WHICH event fired.
_reconcile_hook_event() {
  printf '%s' "${SPEC_KIT_JIRA_HOOK_EVENT:-}"
}

# _reconcile_is_held <event> — 0 when the operator disabled this event, 1 when
# not, EXIT_CONFIG when the disable record cannot be read. A read failure must
# never be silently treated as "not held" — an unreadable binding might be
# hiding an operator's disable decision (Constitution X, contracts/
# parse-failure.md §4: config_hooks_disabled_read propagates).
#
# Read at DISPATCH, before any prerequisite check and before any network work, so
# the decision holds even in the window between an install that re-enabled the
# registry entry and the next ceremony (003 FR-007, FR-020, research R5 step 2).
# The registry's own `enabled` field is deliberately NOT consulted here: the
# install rewrites it to `true` unconditionally, so it cannot carry the answer.
_reconcile_is_held() {
  local event="$1" disabled rc=0
  [[ -z "${event}" ]] && return 1
  disabled="$(config_hooks_disabled_read)" || rc=$?
  ((rc != 0)) && return "${rc}"
  jq -e --arg e "${event}" 'index($e) != null' <<< "${disabled}" > /dev/null 2>&1
}

# _reconcile_notice <line...> — the SINGLE message a degraded run is allowed
# (FR-016). Everything goes to stderr so it never contaminates a --json summary,
# and the caller emits it exactly once per run.
_reconcile_notice() {
  printf '%s\n' "$@" >&2
}

# _reconcile_fault <exit-code> <message> — report one bridge fault and return the
# code the caller should return.
#
# In HOOK CONTEXT that code is always 0: under `optional: false` the agent
# performs this step as part of the host command, and FR-015 admits no exception
# — a hook failure of ANY kind must leave the host command's outcome untouched.
# Every early-return failure path goes through here for that reason. The
# downgrade used to happen at one point near the end of the run, which meant the
# faults that returned early — an unparseable spec, an invalid lifecycle payload
# — still failed the host command. Outside hook context the mapped exit code is
# returned unchanged, so a direct invocation still fails closed (Constitution III).
_reconcile_fault() {
  local code="$1" message="$2"
  # Phase 6, US4 (T053 audit): in hook context every early-return fault gets
  # the SAME standardised WARNING wording the late apply-failure path uses
  # below — the caller's specific, actionable message is kept (it names the
  # true cause better than a generic per-code label would), just wrapped so
  # every degraded path reads identically under a hook (FR-016).
  if [[ -n "${SPEC_KIT_JIRA_HOOK_CONTEXT:-}" ]]; then
    printf 'WARNING: %s (exit %s). This spec-kit command completed normally.\n' "${message}" "${code}" >&2
    return 0
  fi
  _reconcile_notice "${message}"
  return "${code}"
}

# _reconcile_resolve_routing <folder> <cfg-json> — resolve this run's project
# key from the merged team config (US1, FR-001–FR-004). Labels are not yet
# extracted by the parser (Assumptions: "extending what the parser extracts is
# out of scope"), so folder-prefix rules and routing_default are what this
# resolves in practice; label-conditioned rules simply never match. Prints the
# resolved key, or nothing with a non-zero return when routing_resolve itself
# could not resolve one (routing-unresolved, US3).
_reconcile_resolve_routing() {
  local folder="$1" cfg="$2"
  routing_resolve "$(basename "${folder}")" '[]' "${cfg}" 2>/dev/null
}

# _reconcile_phase_status_map <project-key> <cfg-json> — the resolved
# project's declared phase->status map (Phase 6, US4, research R9), or {}
# when the project declares none — the same inert default the phase-status
# machinery has always had (config_classify_statuses/config_phase_status_
# targets already default gracefully to an empty map).
_reconcile_phase_status_map() {
  local key="$1" cfg="$2" v
  v="$(jq -c --arg k "${key}" '(.projects // [])[] | select(.key==$k) | .phase_status_map // {}' <<< "${cfg}")"
  [[ -z "${v}" ]] && v='{}'
  printf '%s' "${v}"
}

# _reconcile_halted_statuses <project-key> <cfg-json> — the resolved
# project's declared operator stop-states (Phase 6, US4), or [] when none.
_reconcile_halted_statuses() {
  local key="$1" cfg="$2" v
  v="$(jq -c --arg k "${key}" '(.projects // [])[] | select(.key==$k) | .halted_statuses // []' <<< "${cfg}")"
  [[ -z "${v}" ]] && v='[]'
  # The team-config YAML reader does not parse an inline flow-style array
  # (`halted_statuses: ["Blocked"]`) — only a block-style list — so a
  # declaration written that way arrives here as a plain JSON STRING
  # holding the literal array text. Recover it rather than silently
  # treating the whole declaration as empty.
  if [[ "$(jq -r 'type' <<< "${v}" 2> /dev/null)" == "string" ]]; then
    local inner; inner="$(jq -r '.' <<< "${v}")"
    if jq -e 'type=="array"' <<< "${inner}" > /dev/null 2>&1; then
      v="${inner}"
    else
      v='[]'
    fi
  fi
  printf '%s' "${v}"
}

# _reconcile_phase_order <phase-status-map-json> — the DISTINCT statuses a
# phase->status map resolves to, IN THE FIXED CANONICAL LIFECYCLE-EVENT ORDER
# (extension.yml's own hook list) — deliberately NOT config_phase_status_
# targets, whose own tested contract accepts arbitrary phase names and
# therefore returns them SORTED, not chronologically (config_load's merge
# also sorts the map's own keys, so declaration order can never be recovered
# from the map alone). Reconcile's phase names ARE the fixed lifecycle
# events, so this local helper can use that closed vocabulary to restore the
# true chronological order drift's ahead/behind comparison depends on
# (Phase 6, US4, research R9).
_reconcile_phase_order() {
  local psmap="${1:-}"
  [[ -z "${psmap}" ]] && psmap='{}'
  jq -cn --argjson pm "${psmap}" '
    ["before_specify","after_specify","after_clarify","after_plan","after_tasks","after_implement","after_analyze"]
    | map($pm[.] // empty)
    | reduce .[] as $s ([]; if (index($s) != null) then . else . + [$s] end)
  ' | json_canonical
}

# _reconcile_field_default_notes <project-key> <issue-types-json>
# <defaultable-fields-by-type-json> <resolved-defaults-json> <actions-json>
# <parent-action-json> <ask> <accept-defaults> — 011, contract §4.1/§4.2:
# for every field this run actually sent that came from a recorded default or
# a this-run answer (never a bridge-supplied field — those are not part of
# `resolved-defaults-json`), one provenance line naming the field, the value,
# and its source; for a source of `operator-answer`, one further line with the
# `/speckit.jira.config --field-default …` command that would make the
# override permanent (FR-021). Deduplicated by (type, field) — reported once
# per run, not once per creation (mirrors FR-011's "each field once"). When at
# least one field was filled AND the confirmation question never fired because
# `ask` is off or `--accept-defaults` was given, one final line states which
# reason applied (§4.2, FR-015). Prints one line per note, newline-joined,
# empty when nothing was defaulted this run (FR-028 — the off switch).
_reconcile_field_default_notes() {
  local pkey="$1" itypes="${2:-[]}" df="${3:-{\}}" resolved="${4:-{\}}" \
    actions="${5:-[]}" parent="${6:-null}" ask="$7" accept="$8" dry_run="${9:-false}"
  [[ -z "${itypes}" ]] && itypes='[]'
  [[ -z "${df}" ]] && df='{}'
  [[ -z "${resolved}" ]] && resolved='{}'
  [[ -z "${actions}" ]] && actions='[]'
  [[ -z "${parent}" ]] && parent='null'
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -rn --arg pkey "${pkey}" --argjson itypes "${itypes}" --argjson df "${df}" \
    --argjson resolved "${resolved}" --argjson actions "${actions}" --argjson parent "${parent}" \
    --arg ask "${ask}" --arg accept "${accept}" --arg dry "${dry_run}" '
    def typeName($tid): (first($itypes[] | select(.id == $tid)) // null) | .logical_name // $tid;
    def labelFor($tid; $fid): (first((($df[$tid]) // [])[] | select(.field_id == $fid)) // null) | .logical_name // $fid;
    ( ([$parent] + $actions) | map(select(. != null and .method == "POST" and (.url | endswith("/issue"))))) as $creates
    | ( [ $creates[] | (.body.fields.issuetype.id) as $tid
          | ((($resolved.field_defaults[$tid]) // {}) | keys[]) as $fid
          | { tid: $tid, fid: $fid,
              value: ($resolved.field_defaults[$tid][$fid]),
              source: ($resolved.field_default_sources[$tid][$fid] // "team-config") } ]
      | unique_by([.tid, .fid])
    ) as $entries
    | ( $entries[]
        | "config: project \($pkey): \(labelFor(.tid; .fid)) (\(typeName(.tid))) = \"\(.value)\" — sent from \(.source)" ),
      ( $entries[] | select(.source == "operator-answer")
        | "config: project \($pkey): make this override permanent — /speckit.jira.config \($pkey) --field-default '\''\($pkey)=\(typeName(.tid))=\(labelFor(.tid; .fid))=\(.value)'\''" ),
      ( if ($entries | length) == 0 then empty
        elif $dry == "true" then
          "config: project \($pkey): this is a preview (--dry-run) — no question was asked and nothing was written"
        elif $accept == "true" then
          "config: project \($pkey): the confirmation question was skipped — --accept-defaults was given"
        elif $ask == "false" then
          "config: project \($pkey): the confirmation question was skipped — field-defaults confirmation is off for this project (ask: false)"
        else empty end)
  '
  # kcov-excl-stop
}

# _reconcile_local_binding_for <project-key> <config-dir> — the persisted
# binding's resolved_ids entry for one project, read directly from the
# machine-owned local layer (independent of config.yml — a project key may be
# supplied entirely by override, US2). Prints the entry JSON and returns 0 on
# success. Returns 2 when the local layer is missing ENTIRELY (never bound at
# all — the existing not-configured notice, not a fault). Returns 3 when the
# file exists but holds no entry for this project (FR-010, project-not-bound).
_reconcile_local_binding_for() {
  local key="$1" dir="$2" f json entry rc=0
  f="$(_cfg_local_path "${dir}")"
  [[ -f "${f}" ]] || return 2
  # An unreadable binding is not "not bound" — it must fail closed with zero
  # Jira writes (FR-010, Constitution III), distinct from 2 (never bound at
  # all) and 3 (bound, no entry for this project).
  json="$(_cfg_local_json "${dir}")" || rc=$?
  ((rc != 0)) && return "${rc}"
  entry="$(jq -c --arg k "${key}" '.resolved_ids[$k] // empty' <<< "${json}" 2>/dev/null)"
  [[ -z "${entry}" || "${entry}" == "null" ]] && return 3
  # binding-shape-stale (008 T016, research R5): a binding written before
  # this feature stores issue_types as a name-to-id MAP, not the hierarchy-
  # carrying list (data-model.md §3). Detected here, before any type
  # resolution is attempted, so an old binding never falls through to
  # plan_writes with an empty issue type — it refuses with its OWN message
  # instead (contracts/hierarchy-resolution.md §1, §6), never the "not bound
  # yet" text: the project IS bound, its binding is simply a version behind.
  local itypes_type
  itypes_type="$(jq -r 'if has("issue_types") then (.issue_types|type) else "absent" end' <<< "${entry}")"
  [[ "${itypes_type}" == "object" ]] && return 6
  printf '%s' "${entry}"
  return 0
}

# _reconcile_plan_context <base-url> <project-key> <config-dir> <merged-cfg-json>
#   [recognition-result-json]
#   The plan context (US2, FR-007–FR-011, FR-013): base_url plus either the
#   caller's SPEC_KIT_JIRA_PLAN_CONTEXT override (wholesale) or the creation
#   context built from the resolved project's persisted binding — story_type_id,
#   the two-step-resolved priority_ids, estimation_field_id, and (Phase 3, US1)
#   the recognised tickets/origins/descriptions maps, filled from the
#   recognition result's `bound` map rather than only from the override
#   (data-model.md "Plan context — tickets, ticket_origins, ticket_descriptions").
#   base_url always wins. Returns 2 / 3 exactly as _reconcile_local_binding_for
#   when no override is set and the binding cannot be read.
_reconcile_plan_context() {
  local base="$1" key="$2" dir="$3" cfg="$4" recog="${5:-}" field_values="${6:-}" tasks_recog="${7:-}"
  # NOT "${5:-{}}" as the default inline: bash's brace-matching for a
  # `${...}` parameter expansion misparses a `{}`-shaped default value,
  # corrupting how the REST OF THE FUNCTION is parsed (a real, reproduced
  # failure — jq calls dozens of lines later raised a phantom "Unmatched
  # '}'"). Default it in a separate, brace-free statement instead.
  [[ -z "${recog}" ]] && recog='{}'
  [[ -z "${tasks_recog}" ]] && tasks_recog='{}'
  local extra="${SPEC_KIT_JIRA_PLAN_CONTEXT:-}"
  if [[ -n "${extra}" ]]; then
    jq -cn --arg b "${base}" --argjson e "${extra}" '$e + {base_url:$b}'
    return 0
  fi

  local binding rc=0
  binding="$(_reconcile_local_binding_for "${key}" "${dir}")" || rc=$?
  [[ "${rc}" -ne 0 ]] && return "${rc}"

  local story_type priority_map priorities est_field priority_ids
  local parent_type_id parent_supports_link
  # child_type.id, not the literal .issue_types.Story (008 T046/R5): the
  # binding's issue_types is a hierarchy-carrying LIST now, and the child
  # type is whatever the persisted binding recorded — derived or an operator
  # answer (contracts/hierarchy-resolution.md §2).
  story_type="$(jq -r '.child_type.id // empty' <<< "${binding}")"
  # child-type-unresolved (contract §6): a binding in the new shape but with
  # no recorded child_type (never configured past discovery, or the ceremony
  # left it unresolved) refuses by name — never a silent empty story type
  # reaching plan_writes far later (research R5's obscure-failure defect).
  [[ -z "${story_type}" ]] && return 7
  parent_type_id="$(jq -r '.parent_type.id // empty' <<< "${binding}")"
  parent_supports_link="$(jq -r --arg t "${story_type}" '(.parent_link_available[$t] // false)' <<< "${binding}")"
  priority_map="$(jq -c --arg k "${key}" '(.projects // [])[] | select(.key==$k) | .priority_map // {}' <<< "${cfg}")"
  [[ -z "${priority_map}" ]] && priority_map='{}'
  priorities="$(jq -c '.priorities // {}' <<< "${binding}")"
  est_field="$(jq -r '.estimation_field_id // empty' <<< "${binding}")"

  # Recorded field defaults (011, research R2): resolved to {issue-type-id:
  # {field-id: value}} at plan time, the same shape jira_create_fields_base
  # merges into a create payload. Absence is the off switch (FR-028) — with
  # nothing recorded and no --field-value answer this resolves to {}, and
  # the omitted key below leaves plan_writes' output byte-identical to
  # before this feature.
  local fd_itypes fd_df fd_recorded fd_answers field_defaults
  fd_itypes="$(jq -c '.issue_types // []' <<< "${binding}")"
  fd_df="$(jq -c '.defaultable_fields // {}' <<< "${binding}")"
  fd_recorded="$(config_field_defaults_for "${key}" "${cfg}")"
  fd_answers="$(cli_field_answers_for "${key}" "${field_values}")"
  # 015, research R1/R2, contract §2: the plan context is the SENDING side —
  # it reads the encoded map, shaped for the wire, while every display-facing
  # consumer elsewhere in this file keeps reading the recorded map unchanged.
  field_defaults="$(plan_resolve_field_defaults "${fd_itypes}" "${fd_df}" "${fd_recorded}" "${fd_answers}" | jq -c '.field_defaults_encoded')"

  # Two-step priority resolution (FR-008): level -> logical name (team config)
  # -> identifier (persisted binding). Either step yielding nothing omits the
  # level rather than blocking the run (FR-011).
  priority_ids="$(jq -cn --argjson pm "${priority_map}" --argjson pr "${priorities}" '
    reduce (["P1","P2","P3"][]) as $lvl ({}; . + (
      ($pm[$lvl] // "") as $logical
      | if $logical == "" then {}
        else (($pr[$logical] // "") as $id | if $id == "" then {} else {($lvl): $id} end)
        end
    ))')"

  # ticket_origins (FR-038) is populated ONLY for a non-bridge origin: a
  # "bridge" origin means plan_writes owns the whole description (the US3
  # behaviour, unchanged) — the same meaning an absent map entry has always
  # had. Including "bridge" here would wrongly route a bridge-created
  # ticket through the human-origin managed-panel splice.
  local tickets ticket_origins ticket_descriptions ticket_parents
  tickets="$(jq -c '(.bound // {}) | with_entries(.value |= .key)' <<< "${recog}")"
  ticket_origins="$(jq -c '(.bound // {}) | with_entries(select(.value.origin != "bridge")) | with_entries(.value |= .origin)' <<< "${recog}")"
  ticket_descriptions="$(jq -c '(.bound // {}) | with_entries(.value |= .current.description)' <<< "${recog}")"
  # ticket_parents (T109): only the entries whose CURRENT parent is non-null —
  # a flat mirror with no parent at all is left alone (plan.md "No
  # migration"); a child linked to the wrong parent is what plan_writes
  # corrects.
  ticket_parents="$(jq -c '(.bound // {}) | with_entries(select(.value.current.parent != null)) | with_entries(.value |= .current.parent)' <<< "${recog}")"
  # ticket_labels (017, US2, contracts/provenance-label.md §2/§3): each
  # recognised ticket's CURRENT labels, already unique-normalised by
  # recognition — omitted entirely when empty, like every neighbouring map.
  local ticket_labels
  ticket_labels="$(jq -c '(.bound // {}) | with_entries(.value |= .current.labels)' <<< "${recog}")"

  # defaultable_fields_by_type / issue_types (017, contract §4): the RAW
  # per-type map discovery already records, plus the type-id -> logical-name
  # list — read here only so plan_writes can answer "does this type's
  # create screen offer labels at all", and name the type in its warning,
  # without a second discovery pass. Omitted when the binding predates them
  # (R6's "not recorded at all ⇒ send" branch reads this same absence).
  local defaultable_fields_by_type issue_types_list
  defaultable_fields_by_type="$(jq -c '.defaultable_fields // {}' <<< "${binding}")"
  issue_types_list="$(jq -c '.issue_types // []' <<< "${binding}")"

  # Phase 3, US1: the task tier's own type id and the recognised sub-tasks'
  # keys/current content, merged into the SAME tickets map (safe — task and
  # story local_ids are disjoint by construction) plus a task-only
  # ticket_current map that plan_writes_tasks compares against for zero
  # churn (contract §4 rule 3). Both are empty, and task_type_id absent,
  # when no `task` role resolved — leaving this function's output
  # byte-identical to before this feature (FR-011).
  local task_type_id task_tickets ticket_current
  task_type_id="$(jq -r '.roles.task.id // empty' <<< "${binding}")"
  task_tickets="$(jq -c '(.bound // {}) | with_entries(.value |= .key)' <<< "${tasks_recog}")"
  tickets="$(jq -c --argjson tt "${task_tickets}" '. + $tt' <<< "${tickets}")"
  ticket_current="$(jq -c '(.bound // {}) | with_entries(.value |= .current)' <<< "${tasks_recog}")"

  jq -cn --arg b "${base}" --arg st "${story_type}" --argjson pids "${priority_ids}" --arg ef "${est_field}" \
    --arg pt "${parent_type_id}" --argjson psl "${parent_supports_link}" \
    --argjson tk "${tickets}" --argjson to "${ticket_origins}" --argjson td "${ticket_descriptions}" \
    --argjson tp "${ticket_parents}" --argjson fd "${field_defaults}" --argjson tl "${ticket_labels}" \
    --argjson dft "${defaultable_fields_by_type}" --argjson itl "${issue_types_list}" \
    --arg tt "${task_type_id}" --argjson tc "${ticket_current}" '
    {base_url:$b}
    + (if $st == "" then {} else {story_type_id:$st} end)
    + (if $pt == "" then {} else {parent_type_id:$pt} end)
    + {parent_supports_link: $psl}
    + (if ($pids|length) == 0 then {} else {priority_ids:$pids} end)
    + (if $ef == "" then {} else {estimation_field_id:$ef} end)
    + (if ($tk|length) == 0 then {} else {tickets:$tk} end)
    + (if ($to|length) == 0 then {} else {ticket_origins:$to} end)
    + (if ($td|length) == 0 then {} else {ticket_descriptions:$td} end)
    + (if ($tp|length) == 0 then {} else {ticket_parents:$tp} end)
    + (if ($tl|length) == 0 then {} else {ticket_labels:$tl} end)
    + (if ($dft|length) == 0 then {} else {defaultable_fields_by_type:$dft} end)
    + (if ($itl|length) == 0 then {} else {issue_types:$itl} end)
    + (if ($fd|length) == 0 then {} else {field_defaults:$fd} end)
    + (if $tt == "" then {} else {task_type_id:$tt} end)
    + (if ($tc|length) == 0 then {} else {ticket_current:$tc} end)'
}

# cmd_reconcile <argv...> — reconcile one specification into its Jira project.
# Echoes the run summary to stdout; returns the exit code.
cmd_reconcile() {
  local parsed json="false" dry_run="false" on_drift="abort" exit_code="0" error=""
  local field_values="" accept_defaults="false"
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      on_drift) on_drift="${value}" ;;
      field_values) field_values="${value}" ;;
      accept_defaults) accept_defaults="${value}" ;;
      exit) exit_code="${value}" ;;
      error) error="${value}" ;;
    esac
  done <<< "${parsed}"
  if [[ "${exit_code}" != "0" ]]; then
    [[ -n "${error}" ]] && printf 'reconcile: %s\n' "${error}" >&2
    return "${exit_code}"
  fi

  # (0) DISPATCH GUARD — the operator's disable decision, honoured before any
  # prerequisite check, any config read and any network call (FR-020). The exit
  # is INERT: no Jira call, and no warning either. A warning here would be noise
  # on every single lifecycle command for an event the operator deliberately
  # turned off, which is precisely what FR-020 forbids.
  local hook_event rc_held=0
  hook_event="$(_reconcile_hook_event)"
  _reconcile_is_held "${hook_event}" || rc_held=$?
  if ((rc_held == 0)); then
    return 0
  elif ((rc_held == EXIT_CONFIG)); then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the operator disable record could not be read (zero writes)'
    return $?
  fi

  # The spec file is the first positional argument.
  local spec_file=""
  local a
  for a in "$@"; do
    case "${a}" in
      reconcile | -*) continue ;;
      *) spec_file="${a}"; break ;;
    esac
  done
  if [[ -z "${spec_file}" || ! -f "${spec_file}" ]]; then
    _reconcile_fault "$(cli_exit_code usage)" 'reconcile: a readable spec file argument is required'
    return $?
  fi

  # TARGET GUARD (User Story 1, FR-001–FR-008, contracts/target-guard.md
  # §1–§3): only a feature folder's own spec.md is ever mirrored. This runs
  # before any configuration read, any network call and any file write — the
  # earliest point at which the target is known (research R1: after the
  # dispatch guard above, so an event the operator disabled stays silent).
  # Basename comparison ONLY — never a glob, a suffix test or a substring
  # search (research R3; the MSYS pattern hazard is why, see
  # docs/10-windows-portability.md). Byte equality, case-sensitive.
  local target_name; target_name="$(basename "${spec_file}")"
  if [[ "${target_name}" != "spec.md" ]]; then
    local sibling_spec target_msg
    sibling_spec="$(dirname "${spec_file}")/spec.md"
    if [[ -f "${sibling_spec}" ]]; then
      target_msg="reconcile: \"${spec_file}\" is not a feature specification — only a feature folder's spec.md is ever mirrored (zero writes); the target for this folder is \"${sibling_spec}\""
    else
      target_msg="reconcile: \"${spec_file}\" is not a feature specification — only a feature folder's spec.md is ever mirrored (zero writes); no spec.md exists in that folder"
    fi
    _reconcile_fault "$(cli_exit_code usage)" "${target_msg}"
    return $?
  fi

  # NOT YET CONFIGURED (FR-017 first cause, FR-019). This is the normal state of
  # a freshly installed repository, not an error: the lifecycle step behaves
  # exactly as it would without the extension, apart from one notice. At most
  # three lines, exit 0 — a hook must never turn "you haven't set this up yet"
  # into a failed spec-kit command.
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    _reconcile_notice \
      'Jira mirror skipped: this repository is not bound to a Jira project yet.' \
      'Nothing was mirrored, and this spec-kit command completed normally.' \
      'To bind it, run /speckit.jira.config.'
    return 0
  fi

  # BRIDGE UNAVAILABLE (FR-017 sixth cause, T090). Reported as its OWN cause and
  # never folded into "not configured" above or the generic prerequisite gate: a
  # missing or non-executable entry point is an incomplete install with an
  # install remedy. The state where NEITHER port starts cannot be reported from
  # here at all — nothing of ours is running — which is why the command documents
  # carry the verbatim fallback block for it (FR-030).
  local bridge_missing
  bridge_missing="$(prereq_bridge_missing)"
  if [[ -n "${bridge_missing}" ]]; then
    _reconcile_notice \
      "Jira mirror skipped: the bridge entry point ${bridge_missing} was not found or is not executable; the extension install is incomplete. This spec-kit command completed normally and nothing was mirrored to Jira. Restore it with: specify extension add --dev <path-to-spec-kit-jira> --force"
    return 0
  fi

  # Spec ref: folder from the path, slug from the folder name; repo from the
  # environment. Routing + creation-context resolution (US1/US2, FR-001–FR-013):
  # per value, an explicit override wins; otherwise the value is derived from
  # the repository's own config, read exactly once and only when something
  # needs it — a run whose project key, epic strategy AND plan context are ALL
  # overridden never reads config.yml at all (contract "Precedence"). A run
  # overriding only the project key and epic strategy still needs config.yml
  # for priority_map, since the plan context (unless itself overridden) is
  # built from it (T057, FR-008). config.yml's absence maps to the same
  # not-configured notice as a missing base URL; a present-but-invalid
  # config.yml surfaces through config_load's own EXIT_CONFIG path.
  local folder slug repo
  folder="$(cd "$(dirname "${spec_file}")" && pwd)"
  slug="${SPEC_KIT_JIRA_SPEC_SLUG:-$(basename "${folder}")}"
  repo="${SPEC_KIT_JIRA_REPO:-local/repo}"

  local override_project="${SPEC_KIT_JIRA_PROJECT_KEY:-}"
  local cfg_dir="${JIRA_CONFIG_DIR:-.specify/jira}" cfg="{}"
  if [[ -z "${override_project}" || -z "${SPEC_KIT_JIRA_PLAN_CONTEXT:-}" ]]; then
    if [[ ! -f "${cfg_dir}/config.yml" ]]; then
      _reconcile_notice \
        'Jira mirror skipped: this repository is not bound to a Jira project yet.' \
        'Nothing was mirrored, and this spec-kit command completed normally.' \
        'To bind it, run /speckit.jira.config.'
      return 0
    fi
    if ! cfg="$(config_load "${cfg_dir}")"; then
      _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the team configuration could not be loaded (zero writes)'
      return $?
    fi
  fi

  local project_key project_from_config="false"
  if [[ -n "${override_project}" ]]; then
    project_key="${override_project}"
  elif ! project_key="$(_reconcile_resolve_routing "${folder}" "${cfg}")"; then
    _reconcile_fault "${EXIT_CONFIG}" "reconcile: routing could not be resolved — no rule in ${cfg_dir}/config.yml matched \"$(basename "${folder}")\" and no routing_default is configured; add routing_default to config.yml"
    return $?
  else
    project_from_config="true"
  fi

  # FR-005: refuse an absent, syntactically invalid, or placeholder key — before
  # any network call, so zero writes ever occur for it. The removed built-in
  # PROJ fallback could never have produced a successful write; refusing an
  # override equal to the placeholder is the one intentional behaviour change.
  if [[ -z "${project_key}" || ! "${project_key}" =~ ^[A-Z][A-Z0-9_]+$ ]]; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the resolved project key is missing or syntactically invalid (zero writes)'
    return $?
  fi
  if config_key_is_placeholder "${project_key}"; then
    _reconcile_fault "${EXIT_CONFIG}" "reconcile: the project is still set to the shipped placeholder \"${project_key}\" — run /speckit.jira.config to bind a real project (zero writes)"
    return $?
  fi

  # US3 unknown-project: a routing rule (or routing_default/team route) named a
  # project the team config never declares in projects[] — distinct from an
  # override, which may legitimately name a project outside config.yml.
  if [[ "${project_from_config}" == "true" ]] \
    && ! jq -e --arg k "${project_key}" '(.projects // [])[] | select(.key == $k)' <<< "${cfg}" > /dev/null 2>&1; then
    _reconcile_fault "${EXIT_CONFIG}" "reconcile: a routing rule names project \"${project_key}\", which is not declared in ${cfg_dir}/config.yml's projects[] — correct the rule in config.yml (zero writes)"
    return $?
  fi

  local spec_ref
  spec_ref="$(jq -cn --arg r "${repo}" --arg s "${slug}" --arg f "${folder}" \
    '{repo:$r, spec_slug:$s, folder:$f}')"

  # Stray-marker scan (FR-007, contracts/target-guard.md §4): runs on every
  # valid target, dry-run included, and never changes the exit code. Computed
  # once, here, and folded into the run summary's warnings array below.
  local stray_files; stray_files="$(marker_splice_stray_files "${folder}")"

  # Phase 6, US4: the phase->status map and halted-status list this run's
  # lifecycle-safety rules resolve against — declared per project, exactly
  # like priority_map (FR-006). Absent a declaration both default to empty,
  # the same inert behaviour every existing repository already has.
  local phase_status_map halted_statuses
  phase_status_map="$(_reconcile_phase_status_map "${project_key}" "${cfg}")"
  halted_statuses="$(_reconcile_halted_statuses "${project_key}" "${cfg}")"

  # Mandatory-field gate (Phase 6, US3, T086/T087/T088; contracts/
  # hierarchy-resolution.md §4/§5), moved ahead of spec-marker assignment by
  # Phase 4 (US2, T065): a run that turns out to stop for the consolidated
  # question (below) must write NEITHER spec.md's markers NOR anything to
  # Jira, so the marker file write further down is gated on `fd_ask_pending`
  # too. Runs after derivation and before recognition, so no read and no
  # write has happened yet. Reads the SAME persisted binding the plan
  # context reads later; a binding that cannot be read yet, or resolves to
  # no bound project, is reported exactly as the plan-context path already
  # reports it — that error surfaces at its usual point below rather than
  # being duplicated here.
  local fd_ask_pending="false" fd_itypes="[]" fd_df="{}" fd_defaults_by_type="{}"
  local gate_resolved="{}" gate_ask="true"
  local gate_binding rc_gate_binding=0
  gate_binding="$(_reconcile_local_binding_for "${project_key}" "${cfg_dir}")" || rc_gate_binding=$?
  # Phase 3, US1: the task tier's own type id, read from the SAME binding —
  # its presence is what "a task role is declared" means (FR-011). Reading
  # tasks.md is gated on this, further down, never on the file's mere
  # existence.
  local task_type_id_candidate=""
  [[ "${rc_gate_binding}" -eq 0 ]] && task_type_id_candidate="$(jq -r '.roles.task.id // empty' <<< "${gate_binding}")"
  if [[ "${rc_gate_binding}" -eq 0 ]]; then
    local gate_child_type; gate_child_type="$(jq -r '.child_type.id // empty' <<< "${gate_binding}")"
    if [[ -n "${gate_child_type}" ]]; then
      # Recorded field defaults (011, research R2/R5, contract §3.3/§3.4/
      # §3.10): a required field with a recorded default or a this-run
      # --field-value answer is now satisfiable. A required field that
      # remains unsatisfiable still refuses here UNCHANGED when the operator
      # cannot be asked — `ask` is off, --accept-defaults was given, or this
      # is a --dry-run (§4.3: the preview never asks, only ever previews or
      # refuses). Otherwise the refusal is DEFERRED to the consolidated
      # question below (fd_ask_pending), fired only once the plan shows a
      # creation is actually pending (FR-013) — never merely offered
      # (FR-028). Absence is the off switch: with nothing recorded and no
      # answer this resolves to {}, and the gate's behaviour is
      # byte-identical to before this feature.
      local gate_recorded gate_answers gate_resolved gate_result gate_status gate_ask
      fd_itypes="$(jq -c '.issue_types // []' <<< "${gate_binding}")"
      fd_df="$(jq -c '.defaultable_fields // {}' <<< "${gate_binding}")"
      gate_recorded="$(config_field_defaults_for "${project_key}" "${cfg}")"
      gate_answers="$(cli_field_answers_for "${project_key}" "${field_values}")"
      gate_resolved="$(plan_resolve_field_defaults "${fd_itypes}" "${fd_df}" "${gate_recorded}" "${gate_answers}")"
      fd_defaults_by_type="$(jq -c '.field_defaults' <<< "${gate_resolved}")"
      gate_ask="$(jq -r '.ask' <<< "${gate_recorded}")"

      gate_result="$(hierarchy_mandatory_gate "${gate_binding}" "${project_key}" "${fd_defaults_by_type}")"
      gate_status="$(jq -r '.status' <<< "${gate_result}")"
      local gate_askable="false"
      [[ "${gate_ask}" == "true" && "${accept_defaults}" != "true" && "${dry_run}" != "true" ]] && gate_askable="true"
      if [[ "${gate_status}" == "unsatisfiable" && "${gate_askable}" == "true" ]]; then
        fd_ask_pending="true"
      elif [[ "${gate_status}" != "ok" ]]; then
        _reconcile_fault "${EXIT_CONFIG}" "$(jq -r '.message' <<< "${gate_result}")"
        return $?
      elif [[ "${gate_askable}" == "true" && "$(jq -r '. != {}' <<< "${fd_defaults_by_type}")" == "true" ]]; then
        # gate_status == ok but at least one default is resolved: a recorded
        # default might be about to land on a pending creation (§3.3 trigger
        # 1) — confirmed once the plan is known, below.
        fd_ask_pending="true"
      fi
    fi

    # §8 re-validation (Phase 6, US4, T052; contract §8): check 4 (ordering)
    # re-run against the PERSISTED binding's roles, `reconcile:` prefixed, no
    # re-read of the project's metadata. Checks 5/6 are already re-validated
    # above via hierarchy_mandatory_gate, which reads the same dual-written
    # child_type/parent_type keys regardless of this feature. A binding with
    # no `roles` key — written before 010, or a project whose mapping was
    # never resolved past style — stays non-fatal.
    local gate_roles
    gate_roles="$(jq -c '.roles // empty' <<< "${gate_binding}")"
    if [[ -n "${gate_roles}" ]]; then
      local reconcile_ordering_msg
      if ! reconcile_ordering_msg="$(role_validate_reconcile "${project_key}" "${gate_roles}")"; then
        _reconcile_fault "${EXIT_CONFIG}" "${reconcile_ordering_msg}"
        return $?
      fi
    fi
  fi

  # R5 step 1 — ASSIGN (Phase 2/3, contracts/story-marker.md, research R5):
  # every story section with no marker at all gets a durable identifier,
  # spliced into spec.md. A dry run computes the SAME assignment but never
  # writes it (FR-016) — the in-memory assigned text is what the rest of
  # THIS run parses, so a dry run predicts the exact identifiers a following
  # real run would use. An unwritable spec.md fails closed BEFORE any Jira
  # write (FR-012): no ticket may ever exist for a story whose identifier was
  # never recorded.
  local raw_spec pre_parse assigned_count=0
  raw_spec="$(cat "${spec_file}" 2> /dev/null; printf x)"; raw_spec="${raw_spec%x}"
  if ! pre_parse="$(printf '%s' "${raw_spec}" | parse_spec "${slug}")"; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the specification could not be parsed (zero writes)'
    return $?
  fi
  assigned_count="$(jq '[.stories[] | select((.marker.state // "absent")=="absent")] | length' <<< "${pre_parse}")"
  local parent_needs_assign; parent_needs_assign="$(jq -r '(.epic.marker.state // "absent")=="absent"' <<< "${pre_parse}")"

  # Ordering within one run, step 1/2 (contracts/parent-marker.md): stories
  # first, the parent second — same pass, same file, ONE splice. Deferred
  # (never written here) when fd_ask_pending — see it performed later,
  # after the plan shows whether the consolidated question actually fires.
  local assigned_spec="${raw_spec}"
  local need_write="false"
  if ((assigned_count > 0)); then
    assigned_spec="$(printf '%s' "${assigned_spec}" | story_marker_assign; printf x)"; assigned_spec="${assigned_spec%x}"
    need_write="true"
  fi
  if [[ "${parent_needs_assign}" == "true" ]]; then
    assigned_spec="$(printf '%s' "${assigned_spec}" | spec_marker_assign; printf x)"; assigned_spec="${assigned_spec%x}"
    need_write="true"
  fi
  if [[ "${need_write}" == "true" && "${dry_run}" != "true" && "${fd_ask_pending}" != "true" ]]; then
    if ! marker_splice_write_file "${spec_file}" "${assigned_spec}" > /dev/null 2>&1; then
      _reconcile_fault "${EXIT_CONFIG}" "reconcile: ${spec_file} could not be written — no ticket may be created before its identifier is recorded (zero writes)"
      return $?
    fi
  fi

  local parse ctx doc
  if ! parse="$(printf '%s' "${assigned_spec}" | parse_spec "${slug}")"; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the specification could not be parsed (zero writes)'
    return $?
  fi
  ctx="$(jq -cn --argjson sr "${spec_ref}" --arg pk "${project_key}" \
    '{spec_ref:$sr, project_key:$pk}')"
  if ! doc="$(interchange_build "${parse}" "${ctx}")"; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the specification could not be assembled into a valid neutral document (zero writes)'
    return $?
  fi

  # The implementation plan (Phase 7, US5; data-model.md §7; spec FR-026/
  # FR-027/FR-028): plan.md sits alongside spec.md in the same feature
  # folder. A missing file, or a file with no `## Summary` section, yields
  # no blocks and no warning (FR-028) — parse_plan_summary already handles
  # both.
  local plan_file plan_blocks
  plan_file="$(dirname "${spec_file}")/plan.md"
  if [[ -f "${plan_file}" ]]; then
    plan_blocks="$(parse_plan_summary < "${plan_file}")"
  else
    plan_blocks="[]"
  fi
  if [[ "$(jq 'length' <<< "${plan_blocks}")" -gt 0 ]]; then
    doc="$(jq -c --argjson pb "${plan_blocks}" '.epic.description.blocks += $pb' <<< "${doc}")"
  fi

  # R5 step 2a — RECOGNISE THE PARENT (Phase 5, US2, T070/T077;
  # contracts/parent-marker.md "Ordering within one run" step 5). One read
  # by the recorded key, before any story is recognised. A blocked parent
  # blocks the WHOLE specification — no story is planned (FR-012).
  local epic_marker recog_parent rc_recog_parent=0
  epic_marker="$(jq -c '.epic.marker' <<< "${doc}")"
  recog_parent="$(recognition_parent_run "${epic_marker}" "${spec_ref}" "${project_key}" "${spec_file}")" || rc_recog_parent=$?
  if ((rc_recog_parent != 0)); then
    _reconcile_fault "${rc_recog_parent}" 'reconcile: the parent could not be recognised (zero writes)'
    return $?
  fi
  local parent_state; parent_state="$(jq -r '.state' <<< "${recog_parent}")"
  if [[ "${parent_state}" == "blocked" ]]; then
    local parent_detail; parent_detail="$(jq -r '.detail' <<< "${recog_parent}")"
    _reconcile_fault "${EXIT_CONFIG}" "reconcile: ${parent_detail}"
    return $?
  fi

  local dup_probe_warning=""

  # R5 step 2b — RECOGNISE the stories (Phase 3, US1;
  # contracts/recognition-contract.md): one read per recorded ticket,
  # verified against the SAME identity marker the read returns. A read
  # failure is NEVER downgraded to "no ticket exists" (FR-004) — it fails
  # the WHOLE specification closed here.
  local stories_slim recog rc_recog=0
  stories_slim="$(jq -c '[.stories[] | {local_id, marker}]' <<< "${doc}")"
  recog="$(recognition_run "${stories_slim}" "${spec_ref}" "${project_key}" "${spec_file}")" || rc_recog=$?
  if ((rc_recog != 0)); then
    _reconcile_fault "${rc_recog}" 'reconcile: a ticket could not be recognised (zero writes)'
    return $?
  fi

  # FR-011/FR-016/FR-021: a blocked story is excluded from the document
  # handed to plan_writes, and the rest of the specification reconciles
  # normally — a blocked story never blocks its siblings.
  local blocked_ids doc_for_write
  blocked_ids="$(jq -c '[.blocked[].story]' <<< "${recog}")"
  doc_for_write="$(jq -c --argjson bids "${blocked_ids}" \
    '.stories |= [.[] | . as $s | select(($bids | index($s.local_id)) == null)]' <<< "${doc}")"

  # Phase 3, US1 (contract §1-§3): the task tier. `tasks.md` is read ONLY
  # when a `task` role resolved in the binding (task_type_id_candidate) —
  # its mere presence on disk is never enough (FR-011). Its absence, once
  # the role IS declared, is a silent no-op (FR-001).
  local tasks_file="" tasks_actions="[]" tasks_recog='{"bound":{},"new":[],"blocked":[]}'
  local task_role_active="false" task_warns="[]" task_withheld_count=0
  local task_skip_notes="[]"
  # Edge Cases, T084: a task checked before its sub-task has ever been
  # created — the completion pass below has no key to read transitions for
  # yet, so it defers here; resolved once the create below (if it completes)
  # stamps a key into tasks_file.
  local pending_create_complete_ids="[]"
  if [[ -n "${task_type_id_candidate}" ]]; then
    local candidate_tasks_file
    candidate_tasks_file="$(dirname "${spec_file}")/tasks.md"
    if [[ -f "${candidate_tasks_file}" ]]; then
      task_role_active="true"
      tasks_file="${candidate_tasks_file}"
      local tasks_raw
      tasks_raw="$(cat "${tasks_file}" 2> /dev/null; printf x)"; tasks_raw="${tasks_raw%x}"

      # Task-tier verdict (Phase 5, US6, T065; data-model.md §5): a THIRD
      # gate, separate from hierarchy_mandatory_gate, over the single type
      # carrying the `task` role alone. Run BEFORE any marker is assigned
      # or spliced into tasks.md, so a withheld task is never given a
      # durable identifier (FR-039) — and before the lifecycle filter, so
      # the whole tier is dropped by construction (FR-038) rather than by
      # omission further down.
      local task_gate_result task_gate_status
      task_gate_result="$(hierarchy_task_gate "${gate_binding}" "${project_key}" "${fd_defaults_by_type}")"
      task_gate_status="$(jq -r '.status' <<< "${task_gate_result}")"

      if [[ "${task_gate_status}" != "ok" ]]; then
        # Attribute against the RAW, unmarked text — purely to learn
        # whether any task would actually have been written this run. A
        # tier with nothing to mirror in the first place is not "withheld"
        # (T056): the note, and the per-field detail below, fire only when
        # at least one task is attributed.
        local tasks_parsed_raw
        tasks_parsed_raw="$(printf '%s' "${tasks_raw}" | tasks_parse_document)"
        task_withheld_count="$(jq --argjson tp "${tasks_parsed_raw}" -r '
          ($tp.tasks // []) as $all
          | (.stories | length) as $n
          | [$all[] | select(.attribution.story_ordinal != null
                              and .attribution.story_ordinal >= 1
                              and .attribution.story_ordinal <= $n)] | length
        ' <<< "${doc_for_write}")"
        if ((task_withheld_count > 0)); then
          local task_type_name
          task_type_name="$(jq -r '.roles.task.logical_name' <<< "${gate_binding}")"
          local task_gate_fields task_gate_field_count i=0
          task_gate_fields="$(jq -c '.fields' <<< "${task_gate_result}")"
          task_gate_field_count="$(jq 'length' <<< "${task_gate_fields}")"
          while ((i < task_gate_field_count)); do
            local field_entry field_name field_line
            field_entry="$(jq -c ".[${i}]" <<< "${task_gate_fields}")"
            field_name="$(jq -r '.logical_name' <<< "${field_entry}")"
            if [[ "$(jq -r 'has("reason")' <<< "${field_entry}")" == "true" ]]; then
              local field_reason; field_reason="$(jq -r '.reason' <<< "${field_entry}")"
              field_line="$(hierarchy_task_field_undefaultable_line "${field_name}" "${field_reason}" "${task_type_name}")"
            else
              field_line="$(hierarchy_task_field_unsatisfiable_line "${field_name}" "${project_key}" "${task_type_name}")"
            fi
            task_warns="$(jq -c --arg l "${field_line}" '. + [$l]' <<< "${task_warns}")"
            # Not `((i++))`: its VALUE is the pre-increment 0 on the first
            # pass, which `set -e` treats as failure and aborts the run.
            i=$((i + 1))
          done
          task_warns="$(jq -c '. + ["reconcile: the task tier was withheld this run — a required field of its issue type could not be satisfied; the specification and story tiers still reconciled"]' <<< "${task_warns}")"
        fi
      else
        local tasks_assigned tasks_for_doc
        tasks_assigned="$(printf '%s' "${tasks_raw}" | task_marker_assign; printf x)"; tasks_assigned="${tasks_assigned%x}"
        if [[ "${tasks_assigned}" != "${tasks_raw}" && "${dry_run}" != "true" ]]; then
          marker_splice_write_file "${tasks_file}" "${tasks_assigned}" > /dev/null 2>&1 || true
        fi
        tasks_for_doc="${tasks_raw}"
        [[ "${dry_run}" != "true" ]] && tasks_for_doc="${tasks_assigned}"

        local tasks_parsed
        tasks_parsed="$(printf '%s' "${tasks_for_doc}" | tasks_parse_document)"

        # Attribution resolves against the specification's OWN stories, in
        # document order (contract §3): an ordinal outside that range is
        # dangling (FR-004), no ordinal at all is unattributed (FR-028) —
        # neither ever reaches the document. Nesting a task under its
        # story's own `tasks` array is what makes "attributed to a story
        # this specification does not contain" unrepresentable downstream.
        doc_for_write="$(jq -c --argjson tp "${tasks_parsed}" '
          ($tp.tasks // []) as $all
          | (.stories | length) as $n
          | ($all | map(select(.attribution.story_ordinal != null
                                and .attribution.story_ordinal >= 1
                                and .attribution.story_ordinal <= $n))) as $attributed
          | .stories |= (to_entries | map(
              (.key + 1) as $ord | .value as $s
              | ($attributed | map(select(.attribution.story_ordinal == $ord))) as $ts
              | if ($ts | length) > 0 then ($s + {tasks: $ts}) else $s end
            ))
        ' <<< "${doc_for_write}")"

        # Neither an unattributed nor a dangling task ever reaches the
        # document (contract §3): this is the only place either can still be
        # named, by task_ref, with its reason (FR-004, FR-028).
        task_skip_notes="$(jq -cn --argjson tp "${tasks_parsed}" --argjson n "$(jq '.stories | length' <<< "${doc_for_write}")" \
          --arg tf "${candidate_tasks_file}" --arg sf "${spec_file}" '
          [ ($tp.tasks // [])[]
            | if (.attribution.story_ordinal == null) then
                "\(.task_ref) in \($tf) carries no story attribution and was not mirrored."
              elif (.attribution.story_ordinal < 1 or .attribution.story_ordinal > $n) then
                "\(.task_ref) in \($tf) is attributed to User Story \(.attribution.story_ordinal), which \($sf) does not contain, and was not mirrored."
              else empty
              end
          ]')"

        # A task-tier schema violation (FR-018's duplicate identifier, most
        # commonly) withholds the WHOLE tier rather than the whole run —
        # declaring a `task` role must never make the mirror worse than not
        # declaring one. The specification and story tiers keep reconciling.
        if ! printf '%s' "${doc_for_write}" | interchange_validate > /dev/null 2>&1; then
          doc_for_write="$(jq -c '.stories |= map(del(.tasks))' <<< "${doc_for_write}")"
          task_warns="$(jq -c '. + ["reconcile: the task tier could not be validated (a malformed or duplicate task identifier) and was withheld this run; the specification and story tiers still reconciled"]' <<< "${task_warns}")"
          task_role_active="false"
        else
          # R5 step 2c — recognise the tasks, on the SAME terms as a story
          # (Phase 2, T029/T030): one read per recorded key, verified
          # against the SAME identity marker the read returns.
          local tasks_slim rc_tasks_recog=0
          tasks_slim="$(jq -c '[.stories[] | (.tasks // [])[] | {local_id, marker}]' <<< "${doc_for_write}")"
          if [[ "$(jq 'length' <<< "${tasks_slim}")" -gt 0 ]]; then
            tasks_recog="$(recognition_run "${tasks_slim}" "${spec_ref}" "${project_key}" "${tasks_file}" "task")" || rc_tasks_recog=$?
            if ((rc_tasks_recog != 0)); then
              _reconcile_fault "${rc_tasks_recog}" 'reconcile: a sub-task could not be recognised (zero writes)'
              return $?
            fi
            local tasks_blocked_ids
            tasks_blocked_ids="$(jq -c '[.blocked[].story]' <<< "${tasks_recog}")"
            doc_for_write="$(jq -c --argjson bids "${tasks_blocked_ids}" \
              '.stories |= [.[] | if has("tasks") then .tasks |= [.[] | . as $t | select(($bids | index($t.local_id)) == null)] else . end]' \
              <<< "${doc_for_write}")"
            task_warns="$(jq -c --argjson bw "$(jq -c '[.blocked[].detail]' <<< "${tasks_recog}")" '. + $bw' <<< "${task_warns}")"
          fi
        fi
      fi
    fi
  fi

  # US3 (T073): orphan (FR-021) and re-attribution (FR-022) reporting — both
  # pure notes, never a write. Scoped to a story already bound in Jira
  # (`recog`'s `subtasks` extra, story-kind only) and to this run's OWN task
  # issue type, so a genuinely unrelated hand-made sub-task is never mistaken
  # for one this bridge created (contracts/task-tier.md §8 "never adopts a
  # hand-made sub-task"). Runs whenever the project has a task role bound —
  # independent of task_role_active, so a sub-task orphaned by deleting
  # tasks.md itself (the most extreme case of "removed from tasks.md") is
  # still caught, not only one orphaned by deleting its own entry.
  local task_notes="[]"
  if [[ -n "${task_type_id_candidate}" ]]; then
    local orphan_notes
    orphan_notes="$(jq -cn --argjson recog "${recog}" --argjson doc "${doc_for_write}" --argjson trecog "${tasks_recog}" \
      --arg ttid "${task_type_id_candidate}" --arg tf "${candidate_tasks_file}" '
      [ ($doc.stories // [])[] as $s
        | ($recog.bound[$s.local_id].key // null) as $skey
        | select($skey != null)
        | ($recog.bound[$s.local_id].subtasks // []) as $subs
        | ([($s.tasks // [])[] as $t | ($trecog.bound[$t.local_id].key // null)] | map(select(. != null))) as $expected
        | $subs[] as $sub
        | select($sub.issuetype_id == $ttid)
        | select(($expected | index($sub.key)) == null)
        | "\($sub.key) is recorded in Jira as a sub-task of \($skey), but \($tf) no longer attributes any task to it; nothing was changed in Jira."
      ]')"

    local reattribution_notes
    reattribution_notes="$(jq -cn --argjson recog "${recog}" --argjson doc "${doc_for_write}" --argjson trecog "${tasks_recog}" \
      --arg tf "${candidate_tasks_file}" '
      [ ($doc.stories // [])[] as $s
        | ($recog.bound[$s.local_id].key // null) as $target_key
        | select($target_key != null)
        | ($s.tasks // [])[] as $t
        | ($trecog.bound[$t.local_id].key // null) as $tkey
        | ($trecog.bound[$t.local_id].current.parent // null) as $cur_parent
        | select($tkey != null and $cur_parent != null and $cur_parent != $target_key)
        | "\($tkey) is attributed to \($target_key) in \($tf), but is recorded in Jira under \($cur_parent); nothing was re-parented."
      ]')"

    task_notes="$(jq -c --argjson b "${reattribution_notes}" '. + $b' <<< "${orphan_notes}")"
  fi
  task_notes="$(jq -c --argjson s "${task_skip_notes}" '. + $s' <<< "${task_notes}")"

  # SINK: the plan context (US2, FR-007–FR-011; Phase 3, US1: tickets/
  # ticket_origins/ticket_descriptions now come from recognition's `bound`
  # map instead of only from the override). An explicit
  # SPEC_KIT_JIRA_PLAN_CONTEXT overrides the derived object wholesale;
  # otherwise it is built from the resolved project's persisted binding.
  local plan_ctx rc_pc=0
  plan_ctx="$(_reconcile_plan_context "${base}" "${project_key}" "${cfg_dir}" "${cfg}" "${recog}" "${field_values}" "${tasks_recog}")" || rc_pc=$?
  if [[ "${rc_pc}" -eq 2 ]]; then
    _reconcile_notice \
      'Jira mirror skipped: this repository is not bound to a Jira project yet.' \
      'Nothing was mirrored, and this spec-kit command completed normally.' \
      'To bind it, run /speckit.jira.config.'
    return 0
  elif [[ "${rc_pc}" -eq 3 ]]; then
    _reconcile_fault "${EXIT_CONFIG}" "reconcile: the project \"${project_key}\" has not been bound yet — run /speckit.jira.config to discover its issue types and priorities (zero writes)"
    return $?
  elif [[ "${rc_pc}" -eq 6 ]]; then
    _reconcile_fault "${EXIT_CONFIG}" "reconcile: the local binding for ${project_key} predates parent support and does not record issue-type hierarchy. The project is bound — its binding is simply a version behind. Run /speckit.jira.config to refresh it (zero writes)"
    return $?
  elif [[ "${rc_pc}" -eq 7 ]]; then
    _reconcile_fault "${EXIT_CONFIG}" "reconcile: project ${project_key} has no recorded issue type for user stories. Run /speckit.jira.config to record it (zero writes)"
    return $?
  elif [[ "${rc_pc}" -eq "${EXIT_CONFIG}" ]]; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the local Jira binding could not be read (zero writes)'
    return $?
  fi
  # Merge the parent's recognition facts into the plan context (T077): a
  # bound parent carries its key, current content (for zero churn) and
  # origin; a new/absent parent contributes nothing extra.
  if [[ "${parent_state}" == "bound" ]]; then
    local parent_key_known parent_current_known parent_origin_known
    parent_key_known="$(jq -r '.key' <<< "${recog_parent}")"
    parent_current_known="$(jq -c '.current' <<< "${recog_parent}")"
    parent_origin_known="$(jq -r '.origin // "bridge"' <<< "${recog_parent}")"
    plan_ctx="$(jq -c --arg k "${parent_key_known}" --argjson c "${parent_current_known}" --arg o "${parent_origin_known}" \
      '. + {parent_key:$k, parent_current:$c, parent_origin:$o}' <<< "${plan_ctx}")"
  fi

  # DUPLICATE PROBE (User Story 4, P3, droppable; FR-022–FR-026,
  # contracts/duplicate-probe.md §2): fires only when about to CREATE a
  # parent — parent_state "new" (no marker recorded) AND the plan context
  # actually resolved a parent_type_id (a hierarchy with no parent type
  # never creates one) — and only once every OTHER pre-write refusal above
  # (routing, project validity, the stale-binding read) has already cleared,
  # so a run that was going to refuse anyway never issues this read first.
  # At most one request per run. Read-only, best-effort — a false negative
  # here leaves today's behaviour unchanged (SC-001 rests on the marker
  # line, not on this).
  if [[ "${parent_state}" == "new" && -n "$(jq -r '.parent_type_id // ""' <<< "${plan_ctx}")" ]]; then
    local dup_label dup_result dup_verdict
    dup_label="speckit-${slug}"
    dup_result="$(duplicate_probe_check "${base}" "${project_key}" "${dup_label}")"
    dup_verdict="$(jq -r '.verdict' <<< "${dup_result}")"
    if [[ "${dup_verdict}" == "hit" ]]; then
      local dup_keys
      dup_keys="$(jq -r '.keys | join(", ")' <<< "${dup_result}")"
      _reconcile_fault "${EXIT_CONFIG}" "reconcile: project ${project_key} already holds tickets labelled \"${dup_label}\" (${dup_keys}) but this specification records no ticket of its own — bind each with the bridge's \`mention <issue-key>\` command, or remove the label from them (zero writes)"
      return $?
    elif [[ "${dup_verdict}" == "unavailable" ]]; then
      dup_probe_warning="the duplicate-label check could not be performed on this site; the run proceeded on its recorded markers alone"
    fi
  fi

  local plan
  if ! plan="$(plan_writes "${doc_for_write}" "${plan_ctx}")"; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the write plan could not be assembled (zero writes)'
    return $?
  fi
  local parent_action actions plan_label_warnings
  parent_action="$(jq -c '.parent' <<< "${plan}")"
  actions="$(jq -c '.stories' <<< "${plan}")"
  # Label-degradation warnings (017, contract §4): at most one per type, per
  # run — never an exit-code change, never a refusal.
  plan_label_warnings="$(jq -c '.warnings // []' <<< "${plan}")"
  # The task type's resolved provenance token (017 FR-009 on 012's tier),
  # decided inside plan_writes beside the story's and the parent's so its own
  # degradation warning travels with theirs. Empty when no `task` role
  # resolved, or when the type cannot hold the label.
  local task_label; task_label="$(jq -r '.task_label // ""' <<< "${plan}")"

  # Phase 3, US1 (contract §4): the task tier's own plan, over the SAME
  # document and context — never through plan_lifecycle, which only knows
  # the two existing tiers. Skipped whenever the tier is inactive, so
  # `tasks_actions` stays the "[]" it was initialised to and every
  # downstream read of it is a no-op (FR-011).
  if [[ "${task_role_active}" == "true" ]]; then
    if ! tasks_actions="$(plan_writes_tasks "${doc_for_write}" "${plan_ctx}" "${task_label}")"; then
      task_warns="$(jq -c '. + ["reconcile: the task tier'"'"'s write plan could not be assembled and was withheld this run"]' <<< "${task_warns}")"
      tasks_actions="[]"
    fi
  fi

  # Phase 8, US5 (contract §6; research R5): the task tier's own completion
  # pass. Scoped to a task ALREADY bound this run (tasks_recog.bound) — a
  # task whose sub-task does not yet exist is skipped entirely (a future run
  # completes it once it does; T084 is the same-run case, not yet resolved).
  # A task whose `done` bit already agrees with its sub-task's classification
  # contributes no entry at all, so this loop issues zero reads for it
  # (FR-031's "an unchanged re-run issues none"). The backward pull is
  # resolved here, never inside the PURE plan_lifecycle_tasks: only the
  # command layer knows --on-drift.
  if [[ "${task_role_active}" == "true" ]]; then
    local completion_tasks='{}' completion_ids completion_id
    completion_ids="$(jq -r '[.stories[] | (.tasks // [])[] | .local_id] | .[]' <<< "${doc_for_write}")"
    while IFS= read -r completion_id; do
      [[ -z "${completion_id}" ]] && continue
      local c_bound; c_bound="$(jq -c --arg id "${completion_id}" '.bound[$id] // null' <<< "${tasks_recog}")"
      if [[ "${c_bound}" == "null" ]]; then
        local c_pending_done
        c_pending_done="$(jq -r --arg id "${completion_id}" \
          '[.stories[] | (.tasks // [])[] | select(.local_id == $id) | .done] | first' <<< "${doc_for_write}")"
        if [[ "${c_pending_done}" == "true" ]]; then
          pending_create_complete_ids="$(jq -c --arg id "${completion_id}" '. + [$id]' <<< "${pending_create_complete_ids}")"
        fi
        continue
      fi
      local c_key c_status_category c_blockers c_done c_entry
      c_key="$(jq -r '.key' <<< "${c_bound}")"
      c_status_category="$(jq -r '.status_category // ""' <<< "${c_bound}")"
      c_blockers="$(jq -c '.blockers // []' <<< "${c_bound}")"
      c_done="$(jq -r --arg id "${completion_id}" \
        '[.stories[] | (.tasks // [])[] | select(.local_id == $id) | .done] | first' <<< "${doc_for_write}")"
      c_entry="null"

      if [[ "${c_done}" == "true" && "${c_status_category}" != "done" ]]; then
        local c_fwd rc_fwd=0
        c_fwd="$(discovery_task_transition "${c_key}" forward)" || rc_fwd=$?
        if ((rc_fwd != 0)); then
          _reconcile_fault "${rc_fwd}" "reconcile: sub-task ${c_key}'s available transitions could not be read (zero writes)"
          return $?
        fi
        c_entry="$(jq -cn --arg k "${c_key}" --argjson b "${c_blockers}" --argjson f "${c_fwd}" '{key:$k, blockers:$b, forward:$f}')"
      elif [[ "${c_done}" == "false" && "${c_status_category}" == "done" ]]; then
        local c_bwd="null"
        if [[ "${on_drift}" == "proceed" ]]; then
          local rc_bwd=0
          c_bwd="$(discovery_task_transition "${c_key}" backward)" || rc_bwd=$?
          if ((rc_bwd != 0)); then
            _reconcile_fault "${rc_bwd}" "reconcile: sub-task ${c_key}'s available transitions could not be read (zero writes)"
            return $?
          fi
        fi
        c_entry="$(jq -cn --arg k "${c_key}" --argjson b "${c_blockers}" --argjson bw "${c_bwd}" \
          '{key:$k, blockers:$b, already_done_diverged:true, backward:$bw}')"
      fi

      if [[ "${c_entry}" != "null" ]]; then
        completion_tasks="$(jq -c --arg id "${completion_id}" --argjson e "${c_entry}" '. + {($id):$e}' <<< "${completion_tasks}")"
      fi
    done <<< "${completion_ids}"

    if [[ "$(jq 'length' <<< "${completion_tasks}")" -gt 0 ]]; then
      local completion_ctx completion_result
      completion_ctx="$(jq -cn --arg b "${base}" --argjson t "${completion_tasks}" '{base_url:$b, tasks:$t}')"
      completion_result="$(plan_lifecycle_tasks "${tasks_actions}" "${completion_ctx}")"
      tasks_actions="$(jq -c '.actions' <<< "${completion_result}")"
      task_warns="$(jq -c --argjson w "$(jq -c '.warnings' <<< "${completion_result}")" '. + $w' <<< "${task_warns}")"
      task_notes="$(jq -c --argjson n "$(jq -c '.notes' <<< "${completion_result}")" '. + $n' <<< "${task_notes}")"
    fi
  fi

  # US6 lifecycle safety (Phase 4, US2): the lifecycle context is now built
  # from recognition's `bound` map on EVERY run — not only under the
  # SPEC_KIT_JIRA_LIFECYCLE test override, which continues to win wholesale
  # (unchanged seam). Zero-churn dropping (FR-030) fires whenever a ticket
  # was recognised, which is what makes an unchanged re-run write nothing at
  # all; the drift/Flagged/blocker rules stay inert until Phase 6 supplies a
  # `target` from a lifecycle event. The filtering runs in BOTH dry-run and
  # real mode so the --dry-run report equals the real run's action set
  # exactly (FR-033).
  local warns="[]" notes="[]" has_override_lifecycle="false"
  local lifecycle="${SPEC_KIT_JIRA_LIFECYCLE:-}"
  if [[ -n "${lifecycle}" ]]; then
    has_override_lifecycle="true"
    if ! lifecycle="$(jq -c --arg b "${base}" --arg od "${on_drift}" '. + {base_url:$b, on_drift:$od}' <<< "${lifecycle}" 2> /dev/null)"; then
      _reconcile_fault "${EXIT_CONFIG}" 'reconcile: SPEC_KIT_JIRA_LIFECYCLE is not valid JSON (zero writes)'
      return $?
    fi
  else
    # origin is omitted when "bridge" (mirrors the plan context's
    # ticket_origins filter above): plan_lifecycle's own churn check
    # branches on origin exactly as plan_writes does, and a "bridge" value
    # would wrongly route a bridge-created ticket through the human-origin
    # managed-panel comparison, which always reads "unchanged" for a
    # description that never carried the panel marker in the first place.
    # target (Phase 6, US4, research R9): the status the CURRENT lifecycle
    # event maps to, via the routed project's phase_status_map — empty when
    # this run has no hook event (a direct invocation) or the event has no
    # declared mapping, which leaves drift evaluation inert exactly as it is
    # today (R9's stated fallback). category classifies each recognised
    # ticket's OWN status the same way config_classify_statuses seeds it:
    # mapped (a declared phase target) overrides an operator-designated
    # halted state, which overrides Jira's own "done" statusCategory
    # (post-scope), else unknown.
    local order target
    order="$(_reconcile_phase_order "${phase_status_map}")"
    target="$(jq -r --arg e "${hook_event}" '.[$e] // ""' <<< "${phase_status_map}")"
    lifecycle="$(jq -c --arg b "${base}" --arg od "${on_drift}" --argjson ord "${order}" \
      --argjson pm "${phase_status_map}" --argjson hd "${halted_statuses}" --arg tgt "${target}" \
      '($pm | [.[]]) as $mapped_targets
       | {base_url:$b, on_drift:$od, order:$ord,
          tickets: ((.bound // {}) | with_entries(.value |= (
            { key: .key, current: .current, blockers: .blockers,
              status: .status,
              category: (
                if (.status | IN($mapped_targets[])) then "mapped"
                elif (.status | IN($hd[])) then "halted"
                elif .status_category == "done" then "post-scope"
                else "unknown" end),
              target: $tgt,
              flagged: .flagged }
            + (if .origin == "bridge" then {} else {origin: .origin} end)
          )))}' \
      <<< "${recog}")"
  fi
  local lresult
  if ! lresult="$(plan_lifecycle "${actions}" "${doc_for_write}" "${lifecycle}")"; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the lifecycle plan could not be assembled (zero writes)'
    return $?
  fi
  actions="$(jq -c '.actions' <<< "${lresult}")"
  warns="$(jq -c '.warnings' <<< "${lresult}")"
  notes="$(jq -c '.notes' <<< "${lresult}")"

  # Every blocked story produces exactly one warning from the diagnostics
  # catalogue (FR-011, FR-016, FR-021) — folded into the same channel the
  # lifecycle rules use, so a reader sees every reason a story's Jira write
  # did not happen in one place.
  warns="$(jq -c --argjson bw "$(jq -c '[.blocked[].detail]' <<< "${recog}")" '. + $bw' <<< "${warns}")"
  # Phase 3, US1: the task tier's own warnings — a withheld tier, a
  # recognition block, or a plan failure — join the same channel.
  warns="$(jq -c --argjson tw "${task_warns}" '. + $tw' <<< "${warns}")"
  # T073 (FR-021, FR-022): orphan and re-attribution reports join the notes
  # channel — reported once, never acted on.
  notes="$(jq -c --argjson tn "${task_notes}" '. + $tn' <<< "${notes}")"

  # Stray-marker warning (FR-007, contracts/target-guard.md §4): one entry
  # naming every match, computed above, before the plan or Jira were even
  # reached — never blocks, never changes the exit code.
  if [[ -n "${stray_files}" ]]; then
    warns="$(jq -c --arg w "spec-kit-jira markers were found in files this mirror never writes: ${stray_files} — they are inert, were left untouched, and can be removed by hand" \
      '. + [$w]' <<< "${warns}")"
  fi
  warns="$(jq -c --argjson lw "${plan_label_warnings}" '. + $lw' <<< "${warns}")"
  # Duplicate-probe "unavailable" warning (User Story 4, contract §4):
  # computed above, on the planning pass — never blocks, never changes the
  # exit code.
  if [[ -n "${dup_probe_warning}" ]]; then
    warns="$(jq -c --arg w "${dup_probe_warning}" '. + [$w]' <<< "${warns}")"
  fi

  # created/updated count only their own endpoints; a transition is also a
  # POST but is not a ticket creation, so it is excluded from the created
  # tally. skipped (FR-023) is what plan_lifecycle silently dropped as
  # no-op: every recognised ticket whose write would have been a no-op.
  local created updated warn_count rc=0
  created="$(jq '[.[] | select(.method=="POST" and (.url|endswith("/issue")))] | length' <<< "${actions}")"
  updated="$(jq '[.[] | select(.method=="PUT")] | length' <<< "${actions}")"
  # The parent's own creation/update counts toward the same tallies (T079).
  if [[ "${parent_action}" != "null" ]]; then
    case "$(jq -r '.method' <<< "${parent_action}")" in
      POST) created=$((created + 1)) ;;
      PUT) updated=$((updated + 1)) ;;
    esac
  fi
  warn_count="$(jq 'length' <<< "${warns}")"
  local recognised_count; recognised_count="$(jq '.bound | length' <<< "${recog}")"
  local skipped_count; skipped_count="$(jq --argjson u "${updated}" '(.bound | length) - $u' <<< "${recog}")"
  ((skipped_count < 0)) && skipped_count=0
  local note_count; note_count="$(jq 'length' <<< "${notes}")"
  local has_lifecycle="${has_override_lifecycle}"
  [[ "${warn_count}" -gt 0 || "${note_count}" -gt 0 ]] && has_lifecycle="true"

  # The consolidated question (Phase 4, US2, T065/T067; contract §3.3/§3.4;
  # data-model.md §4): fired only now that recognition and planning show
  # whether a creation is actually pending (FR-013) — fd_ask_pending above
  # was merely a STRUCTURAL candidate, computed before recognition ran.
  # Scoped to the types that actually have a creation pending THIS run
  # (never a type the project merely offers — FR-028). Zero writes on this
  # path: neither the marker file (deferred above) nor any Jira call has
  # happened yet.
  local fd_task_creates_pending
  fd_task_creates_pending="$(jq '[.[] | select(.method=="POST" and (.url|endswith("/issue")))] | length' <<< "${tasks_actions}")"
  if [[ "${fd_ask_pending}" == "true" && ( "${created}" -gt 0 || "${fd_task_creates_pending}" -gt 0 ) ]]; then
    local fd_pending_types
    fd_pending_types="$(jq -c '[.[] | select(.method=="POST" and (.url|endswith("/issue"))) | .body.fields.issuetype.id] | unique' <<< "${actions}")"
    if [[ "${parent_action}" != "null" && "$(jq -r '.method' <<< "${parent_action}")" == "POST" ]]; then
      fd_pending_types="$(jq -c --argjson p "${parent_action}" '. + [$p.body.fields.issuetype.id] | unique' <<< "${fd_pending_types}")"
    fi
    # T066a (FR-040): the task tier's own pending creations join the SAME
    # set of types the confirmation is scoped to — a run creating all three
    # tiers still asks exactly one question, naming every tier's field.
    fd_pending_types="$(jq -c --argjson t "${tasks_actions}" \
      '. + [$t[] | select(.method=="POST" and (.url|endswith("/issue"))) | .body.fields.issuetype.id] | unique' \
      <<< "${fd_pending_types}")"
    local fd_fields; fd_fields="$(plan_confirmation_fields "${fd_itypes}" "${fd_df}" "${fd_defaults_by_type}" "${fd_pending_types}")"
    if [[ "$(jq -r 'length' <<< "${fd_fields}")" -gt 0 ]]; then
      local fd_confirmation fd_creations_pending
      fd_creations_pending=$((created + fd_task_creates_pending))
      fd_confirmation="$(jq -cn --arg proj "${project_key}" --argjson f "${fd_fields}" --argjson cp "${fd_creations_pending}" \
        --arg rw "/speckit.jira.reconcile ${spec_file} --accept-defaults" \
        '{status:"confirmation-pending", project:$proj, fields:$f, creations_pending:$cp, resume_with:$rw}' | json_canonical)"
      if [[ "${json}" == "true" ]]; then
        printf '%s\n' "${fd_confirmation}"
      else
        local fd_labels; fd_labels="$(jq -r '[.fields[].label] | join(", ")' <<< "${fd_confirmation}")"
        printf 'Jira mirror paused: confirm %s before %s creation(s) are written.\n' "${fd_labels}" "${fd_creations_pending}"
        printf 'Resume with: %s\n' "$(jq -r '.resume_with' <<< "${fd_confirmation}")"
      fi
      return 0
    elif [[ "${gate_status:-}" == "unsatisfiable" ]]; then
      # The gate found a pending creation's type structurally unsatisfiable,
      # but no field-level detail could be built for it — the binding
      # predates defaultable-field discovery for that type (no
      # `defaultable_fields` entry). Refuse via the gate's own message
      # rather than silently writing a payload missing a required field.
      _reconcile_fault "${EXIT_CONFIG}" "$(jq -r '.message' <<< "${gate_result}")"
      return $?
    fi
  fi

  # The marker write deferred above, now that we know the question did not
  # fire (either fd_ask_pending was never true, or it was but neither §3.3
  # trigger held once the plan was known).
  if [[ "${fd_ask_pending}" == "true" && "${need_write}" == "true" ]]; then
    if ! marker_splice_write_file "${spec_file}" "${assigned_spec}" > /dev/null 2>&1; then
      _reconcile_fault "${EXIT_CONFIG}" "reconcile: ${spec_file} could not be written — no ticket may be created before its identifier is recorded (zero writes)"
      return $?
    fi
  fi

  if [[ "${dry_run}" != "true" ]]; then
    # `|| rc=$?` keeps a fail-closed apply (exit >= 2) from aborting the command
    # under the dispatcher's `set -e`, so the run summary always prints (FR-032).
    # R5 steps 4/6, contract steps 8-11: apply_writes_with_recognition performs
    # the parent first, marks every planned creation `creating` before the
    # first create, and stamps + records each created ticket's key
    # IMMEDIATELY, per ticket — never batched.
    local apply_plan known_parent_key="" apply_outcome=""
    apply_plan="$(jq -cn --argjson p "${parent_action}" --argjson s "${actions}" '{parent:$p, stories:$s}')"
    [[ "${parent_state}" == "bound" ]] && known_parent_key="$(jq -r '.key' <<< "${recog_parent}")"
    # Phase 3, US1: the task tier's own writes join the SAME apply call —
    # the pre-write privacy sweep must cover every payload of the run
    # before any of them is written (FR-025) — never a second call.
    # known_story_keys seeds the parent-key resolution with every story
    # ALREADY recognised; a story created in this same run is added to the
    # map as the apply pass reaches it.
    local known_story_keys='{}'
    [[ "${task_role_active}" == "true" ]] && known_story_keys="$(jq -c '.bound | with_entries(.value |= .key)' <<< "${recog}")"
    apply_outcome="$(apply_writes_with_recognition "${apply_plan}" "${spec_ref}" "${spec_file}" "${known_parent_key}" "[]" "${fd_df}" \
      "${tasks_actions}" "${tasks_file}" "${known_story_keys}")" || rc=$?
    # 015, research R4, contract §4.3/§5: `created` now reports what Jira
    # actually confirmed, not what was merely planned — empty stdout (the
    # three pre-write privacy-guard returns, the task sweep included) reads
    # as zero created. The
    # `parent`/`story` filter keeps 012's sub-tasks out of this tier's tally:
    # they are counted separately in `counts.tasks.created` (012 FR-011).
    if [[ -z "${apply_outcome}" ]]; then
      created=0
    else
      created="$(jq '[(.created // [])[] | select(.role == "parent" or .role == "story")] | length' <<< "${apply_outcome}")"
    fi
  fi

  # Edge Cases (contract §6, final line; T084): a task checked before its
  # sub-task ever existed is created and transitioned in this SAME run. The
  # completion pass above deferred it — no key existed yet to read
  # transitions for. Resolved now that the create above (if it completed)
  # stamped a key into tasks_file; pending_create_complete_ids stays empty
  # whenever nothing qualifies, so this block is a no-op otherwise. Never
  # uses _reconcile_fault here: a write has already happened by this point,
  # so the run summary must still print rather than early-return.
  if [[ "${dry_run}" != "true" ]] && [[ "$(jq 'length' <<< "${pending_create_complete_ids}")" -gt 0 ]]; then
    local pcc_doc pcc_ctx_tasks='{}' pcc_id
    pcc_doc="$(tasks_parse_document < "${tasks_file}")"
    for pcc_id in $(jq -r '.[]' <<< "${pending_create_complete_ids}"); do
      local pcc_key
      pcc_key="$(jq -r --arg id "${pcc_id}" \
        '[.tasks[] | select(.local_id == $id) | .marker.ticket // empty] | first // empty' <<< "${pcc_doc}")"
      [[ -z "${pcc_key}" ]] && continue
      local pcc_fwd rc_pcc_fwd=0
      pcc_fwd="$(discovery_task_transition "${pcc_key}" forward)" || rc_pcc_fwd=$?
      if ((rc_pcc_fwd != 0)); then
        ((rc_pcc_fwd > rc)) && rc="${rc_pcc_fwd}"
        continue
      fi
      pcc_ctx_tasks="$(jq -c --arg id "${pcc_id}" --arg k "${pcc_key}" --argjson f "${pcc_fwd}" \
        '. + {($id): {key:$k, blockers:[], forward:$f}}' <<< "${pcc_ctx_tasks}")"
    done

    if [[ "$(jq 'length' <<< "${pcc_ctx_tasks}")" -gt 0 ]]; then
      local pcc_ctx pcc_result pcc_actions
      pcc_ctx="$(jq -cn --arg b "${base}" --argjson t "${pcc_ctx_tasks}" '{base_url:$b, tasks:$t}')"
      pcc_result="$(plan_lifecycle_tasks '[]' "${pcc_ctx}")"
      pcc_actions="$(jq -c '.actions' <<< "${pcc_result}")"
      if [[ "$(jq 'length' <<< "${pcc_actions}")" -gt 0 ]]; then
        local pcc_rc=0
        # 015 contract §4.2: the apply prints its confirmed-creation outcome on
        # stdout. This pass only transitions already-created sub-tasks, so the
        # outcome carries nothing this tier counts — but it MUST still be
        # captured, or it would land in the middle of the run summary.
        apply_writes_with_recognition '{"parent":null,"stories":[]}' "${spec_ref}" "${spec_file}" "" "[]" "${fd_df}" \
          "${pcc_actions}" "${tasks_file}" '{}' > /dev/null || pcc_rc=$?
        if ((pcc_rc == 0)); then
          tasks_actions="$(jq -c --argjson a "${pcc_actions}" '. + $a' <<< "${tasks_actions}")"
        else
          ((pcc_rc > rc)) && rc="${pcc_rc}"
        fi
      fi
      warns="$(jq -c --argjson w "$(jq -c '.warnings' <<< "${pcc_result}")" '. + $w' <<< "${warns}")"
      notes="$(jq -c --argjson n "$(jq -c '.notes' <<< "${pcc_result}")" '. + $n' <<< "${notes}")"
      warn_count="$(jq 'length' <<< "${warns}")"
      note_count="$(jq 'length' <<< "${notes}")"
      [[ "${warn_count}" -gt 0 || "${note_count}" -gt 0 ]] && has_lifecycle="true"
    fi
  fi

  # T071: the catalogued `re-routed` notice, once the new key is recorded.
  # Recognition tags a re-routed story with its former key and project
  # (recog.rerouted); the new key is only known after the create response,
  # so the command layer re-reads the just-written spec_file for it. Skipped
  # under --dry-run (no key is ever recorded there) and skipped for a story
  # whose creation did not complete this run — a future run reports it then.
  # T079/parent-marker.md `parent-recreated`: a summary note, not a refusal
  # — the recorded parent no longer existed, so a new one was created and
  # the record was updated. The new key is only known after the create
  # response, so re-read the just-written spec_file for it.
  if [[ "${dry_run}" != "true" ]] && [[ "${parent_state}" == "new" ]] && [[ "$(jq -r '.recreated_from.key // ""' <<< "${recog_parent}")" != "" ]]; then
    local former_parent_key post_epic_content post_epic_info new_parent_key
    former_parent_key="$(jq -r '.recreated_from.key' <<< "${recog_parent}")"
    post_epic_content="$(cat "${spec_file}" 2> /dev/null; printf x)"; post_epic_content="${post_epic_content%x}"
    post_epic_info="$(spec_marker_document_info "${post_epic_content}")"
    new_parent_key="$(jq -r '.ticket // empty' <<< "${post_epic_info}")"
    if [[ -n "${new_parent_key}" ]]; then
      notes="$(jq -c --arg d \
        "${former_parent_key}, recorded as the parent of ${spec_file}, no longer exists in Jira; a new parent was created and the record updated (now ${new_parent_key})." \
        '. + [$d]' <<< "${notes}")"
      has_lifecycle="true"
    fi
  fi

  local rerouted; rerouted="$(jq -c '.rerouted // {}' <<< "${recog}")"
  if [[ "${dry_run}" != "true" ]] && [[ "$(jq 'length' <<< "${rerouted}")" -gt 0 ]]; then
    local post_content post_parse
    post_content="$(cat "${spec_file}" 2> /dev/null; printf x)"; post_content="${post_content%x}"
    if post_parse="$(printf '%s' "${post_content}" | parse_spec "${slug}" 2> /dev/null)"; then
      local rid
      for rid in $(jq -r 'keys[]' <<< "${rerouted}"); do
        local new_key
        new_key="$(jq -r --arg id "${rid}" \
          '.stories[] | select(.local_id == $id and .marker.state == "bound") | .marker.ticket // empty' \
          <<< "${post_parse}")"
        if [[ -n "${new_key}" ]]; then
          local former_key former_project
          former_key="$(jq -r --arg id "${rid}" '.[$id].former_key' <<< "${rerouted}")"
          former_project="$(jq -r --arg id "${rid}" '.[$id].former_project' <<< "${rerouted}")"
          notes="$(jq -c --arg d \
            "Story ${rid} in ${spec_file} was previously mirrored as ${former_key} in project ${former_project}, which is no longer the project this specification routes to; ${former_key} was left untouched and the story was mirrored into ${project_key} as ${new_key}. Nothing was moved or deleted." \
            '. + [$d]' <<< "${notes}")"
          has_lifecycle="true"
        fi
      done
    fi
  fi

  # Hook health is READ and reported on every run (FR-047). Nothing here writes
  # the registry, in any state — reading it is the extension's whole
  # relationship with that file (003 FR-022). The path is relative to the
  # repository root (cwd), overridable for tests.
  local ext_path hooks_health
  ext_path="${SPEC_KIT_JIRA_EXTENSIONS_YML:-.specify/extensions.yml}"
  hooks_health="$(register_hooks_health "${ext_path}" "$(config_hooks_disabled_read 2> /dev/null)")" || true
  [[ -z "${hooks_health}" ]] && hooks_health='{"disabled":[],"duplicated":[],"held_disabled":[],"missing":[],"present":[],"unreadable":false}'

  # FR-046 / 003 FR-015: in hook context a bridge failure NEVER fails the host
  # command — after surfacing a single actionable WARNING the exit is downgraded
  # to 0, so the mirror can fail without ever affecting the spec-kit command that
  # triggered it. The warning names the true cause and only commands that can be
  # run as spelled (FR-017, FR-018): `reconcile --repair-hooks` used to be named
  # here and no longer exists, because repairing the registry is a write FR-022
  # forbids.
  if [[ -n "${SPEC_KIT_JIRA_HOOK_CONTEXT:-}" && "${rc}" -ne 0 ]]; then
    local cause
    case "${rc}" in
      2) cause="Jira could not be reached, or a read failed closed" ;;
      3) cause="Jira rejected the credentials" ;;
      4) cause="the configuration was refused" ;;
      5) cause="a prerequisite is missing" ;;
      9) cause="the privacy guard blocked the write" ;;
      *) cause="the mirror did not complete" ;;
    esac
    printf 'WARNING: Jira mirror not completed — %s (exit %s). This spec-kit command completed normally. Run /speckit.jira.config to re-check the binding.\n' \
      "${cause}" "${rc}" >&2
    rc=0
  fi

  # FR-026: an unattributed or dangling task is never a fault (rc stays 0),
  # so it is invisible to the block above — but a lifecycle hook still gets
  # only ONE warning, not one per task. The run summary's own `notes` (below)
  # keeps naming each one individually; only the stderr side collapses.
  if [[ -n "${SPEC_KIT_JIRA_HOOK_CONTEXT:-}" && "${rc}" -eq 0 ]]; then
    local task_skip_count
    task_skip_count="$(jq 'length' <<< "${task_skip_notes}")"
    if ((task_skip_count > 0)); then
      printf 'WARNING: %s task(s) could not be mirrored (no story attribution, or attributed to a story the specification does not contain); see the run summary for detail. This spec-kit command completed normally.\n' \
        "${task_skip_count}" >&2
    fi
  fi

  # Field-default provenance (011, T073, contract §4.1/§4.2): every field this
  # run actually sent that came from a recorded default or a this-run answer,
  # attributed to its source, plus the promotion command for an override and
  # the skipped-confirmation reason. Reads the SAME resolved map the gate
  # already computed (gate_resolved) — never a second resolution pass, so the
  # preview and the real run cannot disagree (§4.3). Empty when nothing was
  # defaulted this run (FR-028 — the off switch).
  local fd_notes fd_notes_actions
  # Phase 3, US1 (FR-042): the task tier's own creations join the SAME
  # provenance sweep, so a defaulted sub-task field is attributed exactly
  # like a story's or the parent's — never a second, sub-task-specific
  # reporting surface.
  fd_notes_actions="$(jq -c --argjson t "${tasks_actions}" '. + $t' <<< "${actions}")"
  fd_notes="$(_reconcile_field_default_notes "${project_key}" "${fd_itypes}" "${fd_df}" "${gate_resolved}" \
    "${fd_notes_actions}" "${parent_action}" "${gate_ask}" "${accept_defaults}" "${dry_run}")"
  if [[ -n "${fd_notes}" ]]; then
    notes="$(jq -c --arg n "${fd_notes}" '. + ($n | split("\n"))' <<< "${notes}")"
    has_lifecycle="true"
  fi

  # Report the action set with the base URL stripped to a host-relative path: the
  # site host is a coordinate that must never appear in output (Constitution IV),
  # and it also keeps the summary stable across the mock's per-run ephemeral port.
  # `local_id` is internal bookkeeping (which story a creation stamps) and is
  # never part of the published action shape.
  # The reported action list stays FLAT (T080a): the parent — when present —
  # is reported first, exactly like any other action, host-relative and
  # stripped of its internal local_id bookkeeping.
  local disp_actions disp_parent
  # A story's own local_id is stripped UNLESS a task role is active — kept
  # then, it is the only way a --dry-run preview names WHICH story a
  # sub-task belongs to (FR-024), since `fields.parent.key` stays the
  # "<resolved at apply time>" placeholder for a same-run story creation.
  # Never kept for a no-task-role run, so FR-011's byte-identical guarantee
  # is unaffected.
  if [[ "${task_role_active}" == "true" ]]; then
    disp_actions="$(jq -c --arg b "${base}" '[.[] | .url |= ltrimstr($b)]' <<< "${actions}")"
  else
    disp_actions="$(jq -c --arg b "${base}" '[.[] | .url |= ltrimstr($b) | del(.local_id)]' <<< "${actions}")"
  fi
  # Phase 3, US1 (Constitution XI): task actions join the SAME displayed
  # list, last — a --dry-run preview that reports counts.tasks but never
  # shows what it counted would not be an honest preview. `parent_local_id`
  # is kept (only the task's own local_id is stripped) so it can be matched
  # against the story action's local_id kept above.
  if [[ "${task_role_active}" == "true" ]]; then
    local disp_task_actions
    disp_task_actions="$(jq -c --arg b "${base}" '[.[] | .url |= ltrimstr($b) | del(.local_id)]' <<< "${tasks_actions}")"
    disp_actions="$(jq -c --argjson t "${disp_task_actions}" '. + $t' <<< "${disp_actions}")"
  fi
  if [[ "${parent_action}" != "null" ]]; then
    disp_parent="$(jq -c --arg b "${base}" '.url |= ltrimstr($b) | del(.local_id)' <<< "${parent_action}")"
    disp_actions="$(jq -c --argjson p "${disp_parent}" '[$p] + .' <<< "${disp_actions}")"
  fi

  # Phase 3, US1 (data-model.md §6, SC-006): the task tier's own nested
  # counts, emitted ONLY when a `task` role is declared (research R8) —
  # absence, not a zeroed-out object, is the off switch that keeps a run
  # with no `task` role byte-for-byte identical to before this feature
  # (FR-011). created/updated read straight off the plan actions actually
  # applied (never through plan_lifecycle, which the task tier does not
  # go through); unchanged is every other attributed task.
  local task_counts="null"
  if [[ "${task_role_active}" == "true" ]]; then
    local task_created task_updated task_transitioned task_total task_unchanged
    task_created="$(jq '[.[] | select(.method=="POST" and (.url|endswith("/issue")))] | length' <<< "${tasks_actions}")"
    task_updated="$(jq '[.[] | select(.method=="PUT")] | length' <<< "${tasks_actions}")"
    # Phase 8, US5: a transition is also a POST, so it is named separately from
    # `/issue` creations here exactly as it is excluded from `created` above.
    task_transitioned="$(jq '[.[] | select(.method=="POST" and (.url|endswith("/transitions")))] | length' <<< "${tasks_actions}")"
    task_total="$(jq '[.stories[] | (.tasks // [])[]] | length' <<< "${doc_for_write}")"
    task_unchanged=$((task_total - task_created - task_updated))
    ((task_unchanged < 0)) && task_unchanged=0
    local task_skipped
    task_skipped="$(jq 'length' <<< "${task_skip_notes}")"
    task_counts="$(jq -cn --argjson cr "${task_created}" --argjson up "${task_updated}" --argjson tr "${task_transitioned}" \
      --argjson un "${task_unchanged}" --argjson wh "${task_withheld_count}" --argjson sk "${task_skipped}" \
      '{created:$cr, updated:$up, transitioned:$tr, unchanged:$un, skipped:$sk, withheld:$wh}')"
  fi

  # The warnings/notes keys appear when the lifecycle facts were supplied OR
  # a story was blocked, so the content-only reconcile (US3) summary with
  # neither is byte-for-byte unchanged.
  local summary
  summary="$(jq -cn \
    --argjson dry "${dry_run}" --argjson c "${created}" --argjson u "${updated}" \
    --argjson x "${rc}" --argjson actions "${disp_actions}" \
    --argjson wc "${warn_count}" --argjson w "${warns}" --argjson no "${notes}" \
    --argjson hl "${has_lifecycle}" --argjson hooks "${hooks_health}" \
    --argjson rec "${recognised_count}" --argjson asg "${assigned_count}" --argjson sk "${skipped_count}" \
    --argjson tc "${task_counts}" '
    {schema_version:"1.0", command:"reconcile", dry_run:$dry,
     counts:({created:$c, updated:$u, skipped:$sk, warnings:$wc, errors:0,
              recognised:$rec, assigned:$asg}
             + (if $tc == null then {} else {tasks:$tc} end)),
     actions:$actions}
    + (if $hl then {warnings:$w, notes:$no} else {} end)
    + {hook_health:$hooks, exit_code:$x}' | json_canonical)"

  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${summary}"
  else
    printf '%s' "${summary}" | summary_render_prose
  fi
  return "${rc}"
}
