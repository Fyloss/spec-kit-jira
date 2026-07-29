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

# _reconcile_is_held <event> — 0 when the operator disabled this event.
#
# Read at DISPATCH, before any prerequisite check and before any network work, so
# the decision holds even in the window between an install that re-enabled the
# registry entry and the next ceremony (003 FR-007, FR-020, research R5 step 2).
# The registry's own `enabled` field is deliberately NOT consulted here: the
# install rewrites it to `true` unconditionally, so it cannot carry the answer.
_reconcile_is_held() {
  local event="$1"
  [[ -z "${event}" ]] && return 1
  jq -e --arg e "${event}" 'index($e) != null' \
    <<< "$(config_hooks_disabled_read 2> /dev/null)" > /dev/null 2>&1
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
  _reconcile_notice "${message}"
  [[ -n "${SPEC_KIT_JIRA_HOOK_CONTEXT:-}" ]] && return 0
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

# _reconcile_epic_strategy <project-key> <cfg-json> — this run's epic strategy
# (FR-006): the resolved project's own declaration in the team config. Falls
# back to the legacy per_repo default only when that project carries no
# declaration at all (an override-only invocation whose project key is not
# even declared in config.yml) — never a silently-preferred default over a
# real declaration.
_reconcile_epic_strategy() {
  local key="$1" cfg="$2" v
  v="$(jq -r --arg k "${key}" '(.projects // [])[] | select(.key==$k) | .epic_strategy // empty' <<< "${cfg}")"
  [[ -z "${v}" ]] && v="per_repo"
  printf '%s' "${v}"
}

# _reconcile_local_binding_for <project-key> <config-dir> — the persisted
# binding's resolved_ids entry for one project, read directly from the
# machine-owned local layer (independent of config.yml — a project key may be
# supplied entirely by override, US2). Prints the entry JSON and returns 0 on
# success. Returns 2 when the local layer is missing ENTIRELY (never bound at
# all — the existing not-configured notice, not a fault). Returns 3 when the
# file exists but holds no entry for this project (FR-010, project-not-bound).
_reconcile_local_binding_for() {
  local key="$1" dir="$2" f entry
  f="$(_cfg_local_path "${dir}")"
  [[ -f "${f}" ]] || return 2
  entry="$(_cfg_local_json "${dir}" | jq -c --arg k "${key}" '.resolved_ids[$k] // empty' 2>/dev/null)"
  [[ -z "${entry}" || "${entry}" == "null" ]] && return 3
  printf '%s' "${entry}"
  return 0
}

# _reconcile_plan_context <base-url> <project-key> <config-dir> <merged-cfg-json>
#   The plan context (US2, FR-007–FR-011, FR-013): base_url plus either the
#   caller's SPEC_KIT_JIRA_PLAN_CONTEXT override (wholesale) or the creation
#   context built from the resolved project's persisted binding — story_type_id,
#   the two-step-resolved priority_ids, and estimation_field_id. base_url
#   always wins. Returns 2 / 3 exactly as _reconcile_local_binding_for when no
#   override is set and the binding cannot be read.
_reconcile_plan_context() {
  local base="$1" key="$2" dir="$3" cfg="$4"
  local extra="${SPEC_KIT_JIRA_PLAN_CONTEXT:-}"
  if [[ -n "${extra}" ]]; then
    jq -cn --arg b "${base}" --argjson e "${extra}" '$e + {base_url:$b}'
    return 0
  fi

  local binding rc=0
  binding="$(_reconcile_local_binding_for "${key}" "${dir}")" || rc=$?
  [[ "${rc}" -ne 0 ]] && return "${rc}"

  local story_type priority_map priorities est_field priority_ids
  story_type="$(jq -r '.issue_types.Story // empty' <<< "${binding}")"
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

  jq -cn --arg b "${base}" --arg st "${story_type}" --argjson pids "${priority_ids}" --arg ef "${est_field}" '
    {base_url:$b}
    + (if $st == "" then {} else {story_type_id:$st} end)
    + (if ($pids|length) == 0 then {} else {priority_ids:$pids} end)
    + (if $ef == "" then {} else {estimation_field_id:$ef} end)'
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
  local hook_event
  hook_event="$(_reconcile_hook_event)"
  if _reconcile_is_held "${hook_event}"; then
    return 0
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
  # needs it — a run whose project key and epic strategy are BOTH overridden
  # never reads config.yml at all (contract "Precedence"). config.yml's
  # absence maps to the same not-configured notice as a missing base URL; a
  # present-but-invalid config.yml surfaces through config_load's own
  # EXIT_CONFIG path.
  local folder slug repo
  folder="$(cd "$(dirname "${spec_file}")" && pwd)"
  slug="${SPEC_KIT_JIRA_SPEC_SLUG:-$(basename "${folder}")}"
  repo="${SPEC_KIT_JIRA_REPO:-local/repo}"

  local override_project="${SPEC_KIT_JIRA_PROJECT_KEY:-}" override_epic="${SPEC_KIT_JIRA_EPIC_STRATEGY:-}"
  local cfg_dir="${JIRA_CONFIG_DIR:-.specify/jira}" cfg="{}"
  if [[ -z "${override_project}" || -z "${override_epic}" ]]; then
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

  local epic_strategy
  if [[ -n "${override_epic}" ]]; then
    epic_strategy="${override_epic}"
  else
    epic_strategy="$(_reconcile_epic_strategy "${project_key}" "${cfg}")"
  fi

  local spec_ref parse ctx doc
  spec_ref="$(jq -cn --arg r "${repo}" --arg s "${slug}" --arg f "${folder}" \
    '{repo:$r, spec_slug:$s, folder:$f}')"

  # ENGINE: parse the spec into neutral content, then assemble + validate. Every
  # substitution is GUARDED: under the dispatcher's live `set -euo pipefail` an
  # unguarded failure would kill the process with a raw exit code, skipping the
  # mapped error path (FR-032: mapped exits, zero writes).
  if ! parse="$(parse_spec "${slug}" < "${spec_file}")"; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the specification could not be parsed (zero writes)'
    return $?
  fi
  ctx="$(jq -cn --argjson sr "${spec_ref}" --arg pk "${project_key}" --arg es "${epic_strategy}" \
    '{spec_ref:$sr, project_key:$pk, epic_strategy:$es}')"
  if ! doc="$(interchange_build "${parse}" "${ctx}")"; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the specification could not be assembled into a valid neutral document (zero writes)'
    return $?
  fi

  # SINK: the plan context (US2, FR-007–FR-011). An explicit
  # SPEC_KIT_JIRA_PLAN_CONTEXT overrides the derived object wholesale;
  # otherwise it is built from the resolved project's persisted binding.
  local plan_ctx actions rc_pc=0
  plan_ctx="$(_reconcile_plan_context "${base}" "${project_key}" "${cfg_dir}" "${cfg}")" || rc_pc=$?
  if [[ "${rc_pc}" -eq 2 ]]; then
    _reconcile_notice \
      'Jira mirror skipped: this repository is not bound to a Jira project yet.' \
      'Nothing was mirrored, and this spec-kit command completed normally.' \
      'To bind it, run /speckit.jira.config.'
    return 0
  elif [[ "${rc_pc}" -eq 3 ]]; then
    _reconcile_fault "${EXIT_CONFIG}" "reconcile: the project \"${project_key}\" has not been bound yet — run /speckit.jira.config to discover its issue types and priorities (zero writes)"
    return $?
  fi
  if ! actions="$(plan_writes "${doc}" "${plan_ctx}")"; then
    _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the write plan could not be assembled (zero writes)'
    return $?
  fi

  # US6 lifecycle safety: when the current-Jira facts are supplied (the seam the
  # config/discovery integration fills from a fail-closed read), fold in zero-churn
  # idempotency, status-category drift, Flagged withholding, and the blocker note.
  # The filtering runs in BOTH dry-run and real mode so the --dry-run report equals
  # the real run's action set exactly (FR-033).
  local warns="[]" notes="[]" has_lifecycle="false"
  local lifecycle="${SPEC_KIT_JIRA_LIFECYCLE:-}"
  if [[ -n "${lifecycle}" ]]; then
    has_lifecycle="true"
    if ! lifecycle="$(jq -c --arg b "${base}" --arg od "${on_drift}" '. + {base_url:$b, on_drift:$od}' <<< "${lifecycle}" 2> /dev/null)"; then
      _reconcile_fault "${EXIT_CONFIG}" 'reconcile: SPEC_KIT_JIRA_LIFECYCLE is not valid JSON (zero writes)'
      return $?
    fi
    local lresult
    if ! lresult="$(plan_lifecycle "${actions}" "${doc}" "${lifecycle}")"; then
      _reconcile_fault "${EXIT_CONFIG}" 'reconcile: the lifecycle plan could not be assembled (zero writes)'
      return $?
    fi
    actions="$(jq -c '.actions' <<< "${lresult}")"
    warns="$(jq -c '.warnings' <<< "${lresult}")"
    notes="$(jq -c '.notes' <<< "${lresult}")"
  fi

  # created counts only create-endpoint POSTs; a transition is also a POST but is
  # not a ticket creation, so it is excluded from the created tally.
  local created updated warn_count rc=0
  created="$(jq '[.[] | select(.method=="POST" and (.url|endswith("/issue")))] | length' <<< "${actions}")"
  updated="$(jq '[.[] | select(.method=="PUT")] | length' <<< "${actions}")"
  warn_count="$(jq 'length' <<< "${warns}")"

  if [[ "${dry_run}" != "true" ]]; then
    # `|| rc=$?` keeps a fail-closed apply (exit >= 2) from aborting the command
    # under the dispatcher's `set -e`, so the run summary always prints (FR-032).
    apply_writes "${actions}" || rc=$?
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
  local disp_actions
  disp_actions="$(jq -c --arg b "${base}" '[.[] | .url |= ltrimstr($b)]' <<< "${actions}")"

  # The warnings/notes keys appear only when the lifecycle facts were supplied, so
  # the content-only reconcile (US3) summary is byte-for-byte unchanged.
  local summary
  summary="$(jq -cn \
    --argjson dry "${dry_run}" --argjson c "${created}" --argjson u "${updated}" \
    --argjson x "${rc}" --argjson actions "${disp_actions}" \
    --argjson wc "${warn_count}" --argjson w "${warns}" --argjson no "${notes}" \
    --argjson hl "${has_lifecycle}" --argjson hooks "${hooks_health}" '
    {schema_version:"1.0", command:"reconcile", dry_run:$dry,
     counts:{created:$c, updated:$u, skipped:0, warnings:$wc, errors:0},
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
