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
source "${_cmd_reconcile_dir}/../sink/jira/hierarchy.sh" # the mandatory-field gate (Phase 6, US3)
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../sink/jira/recognition.sh" # R5 step 2 — recognise recorded tickets
# shellcheck source=/dev/null
source "${_cmd_reconcile_dir}/../sink/jira/plan_apply.sh"
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
  local base="$1" key="$2" dir="$3" cfg="$4" recog="${5:-}"
  # NOT "${5:-{}}" as the default inline: bash's brace-matching for a
  # `${...}` parameter expansion misparses a `{}`-shaped default value,
  # corrupting how the REST OF THE FUNCTION is parsed (a real, reproduced
  # failure — jq calls dozens of lines later raised a phantom "Unmatched
  # '}'"). Default it in a separate, brace-free statement instead.
  [[ -z "${recog}" ]] && recog='{}'
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

  jq -cn --arg b "${base}" --arg st "${story_type}" --argjson pids "${priority_ids}" --arg ef "${est_field}" \
    --arg pt "${parent_type_id}" --argjson psl "${parent_supports_link}" \
    --argjson tk "${tickets}" --argjson to "${ticket_origins}" --argjson td "${ticket_descriptions}" \
    --argjson tp "${ticket_parents}" '
    {base_url:$b}
    + (if $st == "" then {} else {story_type_id:$st} end)
    + (if $pt == "" then {} else {parent_type_id:$pt} end)
    + {parent_supports_link: $psl}
    + (if ($pids|length) == 0 then {} else {priority_ids:$pids} end)
    + (if $ef == "" then {} else {estimation_field_id:$ef} end)
    + (if ($tk|length) == 0 then {} else {tickets:$tk} end)
    + (if ($to|length) == 0 then {} else {ticket_origins:$to} end)
    + (if ($td|length) == 0 then {} else {ticket_descriptions:$td} end)
    + (if ($tp|length) == 0 then {} else {ticket_parents:$tp} end)'
}

# cmd_reconcile <argv...> — reconcile one specification into its Jira project.
# Echoes the run summary to stdout; returns the exit code.
cmd_reconcile() {
  local parsed json="false" dry_run="false" on_drift="abort" exit_code="0" error=""
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      on_drift) on_drift="${value}" ;;
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

  # Phase 6, US4: the phase->status map and halted-status list this run's
  # lifecycle-safety rules resolve against — declared per project, exactly
  # like priority_map (FR-006). Absent a declaration both default to empty,
  # the same inert behaviour every existing repository already has.
  local phase_status_map halted_statuses
  phase_status_map="$(_reconcile_phase_status_map "${project_key}" "${cfg}")"
  halted_statuses="$(_reconcile_halted_statuses "${project_key}" "${cfg}")"

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
  # first, the parent second — same pass, same file, ONE splice.
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
  if [[ "${need_write}" == "true" && "${dry_run}" != "true" ]]; then
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

  # Mandatory-field gate (Phase 6, US3, T086/T087/T088; contracts/
  # hierarchy-resolution.md §4/§5): runs after derivation and before
  # recognition, so no read and no write has happened yet. Reads the SAME
  # persisted binding the plan context reads later; a binding that cannot
  # be read yet, or resolves to no bound project, is reported exactly as
  # the plan-context path already reports it — that error surfaces at its
  # usual point below rather than being duplicated here.
  local gate_binding rc_gate_binding=0
  gate_binding="$(_reconcile_local_binding_for "${project_key}" "${cfg_dir}")" || rc_gate_binding=$?
  if [[ "${rc_gate_binding}" -eq 0 ]]; then
    local gate_child_type; gate_child_type="$(jq -r '.child_type.id // empty' <<< "${gate_binding}")"
    if [[ -n "${gate_child_type}" ]]; then
      local gate_result gate_status
      gate_result="$(hierarchy_mandatory_gate "${gate_binding}" "${project_key}")"
      gate_status="$(jq -r '.status' <<< "${gate_result}")"
      if [[ "${gate_status}" != "ok" ]]; then
        _reconcile_fault "${EXIT_CONFIG}" "$(jq -r '.message' <<< "${gate_result}")"
        return $?
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

  # SINK: the plan context (US2, FR-007–FR-011; Phase 3, US1: tickets/
  # ticket_origins/ticket_descriptions now come from recognition's `bound`
  # map instead of only from the override). An explicit
  # SPEC_KIT_JIRA_PLAN_CONTEXT overrides the derived object wholesale;
  # otherwise it is built from the resolved project's persisted binding.
  local plan_ctx rc_pc=0
  plan_ctx="$(_reconcile_plan_context "${base}" "${project_key}" "${cfg_dir}" "${cfg}" "${recog}")" || rc_pc=$?
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

  local plan
  if ! plan="$(plan_writes "${doc_for_write}" "${plan_ctx}")"; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the write plan could not be assembled (zero writes)'
    return $?
  fi
  local parent_action actions
  parent_action="$(jq -c '.parent' <<< "${plan}")"
  actions="$(jq -c '.stories' <<< "${plan}")"

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
  local has_lifecycle="${has_override_lifecycle}"
  [[ "${warn_count}" -gt 0 ]] && has_lifecycle="true"

  if [[ "${dry_run}" != "true" ]]; then
    # `|| rc=$?` keeps a fail-closed apply (exit >= 2) from aborting the command
    # under the dispatcher's `set -e`, so the run summary always prints (FR-032).
    # R5 steps 4/6, contract steps 8-11: apply_writes_with_recognition performs
    # the parent first, marks every planned creation `creating` before the
    # first create, and stamps + records each created ticket's key
    # IMMEDIATELY, per ticket — never batched.
    local apply_plan known_parent_key=""
    apply_plan="$(jq -cn --argjson p "${parent_action}" --argjson s "${actions}" '{parent:$p, stories:$s}')"
    [[ "${parent_state}" == "bound" ]] && known_parent_key="$(jq -r '.key' <<< "${recog_parent}")"
    apply_writes_with_recognition "${apply_plan}" "${spec_ref}" "${spec_file}" "${known_parent_key}" || rc=$?
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

  # Report the action set with the base URL stripped to a host-relative path: the
  # site host is a coordinate that must never appear in output (Constitution IV),
  # and it also keeps the summary stable across the mock's per-run ephemeral port.
  # `local_id` is internal bookkeeping (which story a creation stamps) and is
  # never part of the published action shape.
  # The reported action list stays FLAT (T080a): the parent — when present —
  # is reported first, exactly like any other action, host-relative and
  # stripped of its internal local_id bookkeeping.
  local disp_actions disp_parent
  disp_actions="$(jq -c --arg b "${base}" '[.[] | .url |= ltrimstr($b) | del(.local_id)]' <<< "${actions}")"
  if [[ "${parent_action}" != "null" ]]; then
    disp_parent="$(jq -c --arg b "${base}" '.url |= ltrimstr($b) | del(.local_id)' <<< "${parent_action}")"
    disp_actions="$(jq -c --argjson p "${disp_parent}" '[$p] + .' <<< "${disp_actions}")"
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
    --argjson rec "${recognised_count}" --argjson asg "${assigned_count}" --argjson sk "${skipped_count}" '
    {schema_version:"1.0", command:"reconcile", dry_run:$dry,
     counts:{created:$c, updated:$u, skipped:$sk, warnings:$wc, errors:0,
             recognised:$rec, assigned:$asg},
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
