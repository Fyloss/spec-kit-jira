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
source "${_cmd_reconcile_dir}/../hooks/register_hooks.sh" # hook health + one-command repair (US9)

: "${EXIT_CONFIG:=4}"

# _reconcile_plan_context <base-url> — the plan context: base_url plus any caller
# overrides from SPEC_KIT_JIRA_PLAN_CONTEXT (JSON). base_url always wins.
_reconcile_plan_context() {
  local base="$1" extra="${SPEC_KIT_JIRA_PLAN_CONTEXT:-}"
  [[ -z "${extra}" ]] && extra='{}'
  jq -cn --arg b "${base}" --argjson e "${extra}" '$e + {base_url:$b}'
}

# _reconcile_adopted_report <neutral-doc-json> <plan-context-json>
#   003 FR-018: report, per ADOPTED ticket, that it was adopted and what this
#   reconcile added to it. A ticket is adopted when its plan context declares a
#   non-bridge origin — the marker adoption stamped. What was added is decided by
#   whether the existing description already carried the managed-panel marker:
#   absent means this is the FIRST reconcile after adoption and the panel is
#   being added BELOW the human prose; present means the panel is being updated
#   in place. Either way nothing outside the panel is touched, which is what the
#   wording has to convey to a Product Owner reading the summary.
#   Prints the canonical array (empty when no ticket is adopted).
_reconcile_adopted_report() {
  local doc="$1" ctx="$2" n i out='[]'
  n="$(jq '.stories | length' <<< "${doc}")"
  for ((i = 0; i < n; i++)); do
    local sid origin ticket
    sid="$(jq -r ".stories[${i}].local_id" <<< "${doc}")"
    origin="$(jq -r --arg s "${sid}" '.ticket_origins[$s] // ""' <<< "${ctx}")"
    ticket="$(jq -r --arg s "${sid}" '.tickets[$s] // ""' <<< "${ctx}")"
    if [[ -n "${ticket}" && -n "${origin}" && "${origin}" != "bridge-created" ]]; then
      local existing had_marker action
      existing="$(jq -c --arg s "${sid}" '.ticket_descriptions[$s] // {}' <<< "${ctx}")"
      had_marker="$(jq -c '.content // []' <<< "${existing}" \
        | managed_section_panel_split "$(adf_managed_marker)" | jq -r '.had_marker')"
      if [[ "${had_marker}" == "true" ]]; then
        action="adopted ticket: the managed panel was updated; nothing outside it was touched"
      else
        action="adopted ticket: the managed panel was added below the existing description; nothing outside it was touched"
      fi
      out="$(jq -c --arg t "${ticket}" --arg a "${action}" '. + [{ticket:$t, action:$a}]' <<< "${out}")"
    fi
  done
  json_canonical <<< "${out}"
}

# cmd_reconcile <argv...> — reconcile one specification into its Jira project.
# Echoes the run summary to stdout; returns the exit code.
cmd_reconcile() {
  local parsed json="false" dry_run="false" on_drift="abort" repair_hooks="false" exit_code="0" error=""
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      on_drift) on_drift="${value}" ;;
      repair_hooks) repair_hooks="${value}" ;;
      exit) exit_code="${value}" ;;
      error) error="${value}" ;;
    esac
  done <<< "${parsed}"
  if [[ "${exit_code}" != "0" ]]; then
    [[ -n "${error}" ]] && printf 'reconcile: %s\n' "${error}" >&2
    return "${exit_code}"
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
    printf 'reconcile: a readable spec file argument is required\n' >&2
    return "$(cli_exit_code usage)"
  fi

  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'reconcile: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi

  # Spec ref: folder from the path, slug from the folder name; repo/project/epic
  # strategy from the environment (US8 routing supplies these from config later).
  local folder slug repo project_key epic_strategy
  folder="$(cd "$(dirname "${spec_file}")" && pwd)"
  slug="${SPEC_KIT_JIRA_SPEC_SLUG:-$(basename "${folder}")}"
  repo="${SPEC_KIT_JIRA_REPO:-local/repo}"
  project_key="${SPEC_KIT_JIRA_PROJECT_KEY:-PROJ}"
  epic_strategy="${SPEC_KIT_JIRA_EPIC_STRATEGY:-per_repo}"

  local spec_ref parse ctx doc
  spec_ref="$(jq -cn --arg r "${repo}" --arg s "${slug}" --arg f "${folder}" \
    '{repo:$r, spec_slug:$s, folder:$f}')"

  # ENGINE: parse the spec into neutral content, then assemble + validate. Every
  # substitution is GUARDED: under the dispatcher's live `set -euo pipefail` an
  # unguarded failure would kill the process with a raw exit code, skipping the
  # mapped error path (FR-032: mapped exits, zero writes).
  if ! parse="$(parse_spec "${slug}" < "${spec_file}")"; then
    printf 'reconcile: the specification could not be parsed (zero writes)\n' >&2
    return "${EXIT_CONFIG}"
  fi
  ctx="$(jq -cn --argjson sr "${spec_ref}" --arg pk "${project_key}" --arg es "${epic_strategy}" \
    '{spec_ref:$sr, project_key:$pk, epic_strategy:$es}')"
  if ! doc="$(interchange_build "${parse}" "${ctx}")"; then
    printf 'reconcile: the specification could not be assembled into a valid neutral document (zero writes)\n' >&2
    return "${EXIT_CONFIG}"
  fi

  # SINK: plan the ordered action set (the --dry-run report is exactly this set).
  local plan_ctx actions
  plan_ctx="$(_reconcile_plan_context "${base}")"
  if ! actions="$(plan_writes "${doc}" "${plan_ctx}")"; then
    printf 'reconcile: the write plan could not be assembled (zero writes)\n' >&2
    return "${EXIT_CONFIG}"
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
      printf 'reconcile: SPEC_KIT_JIRA_LIFECYCLE is not valid JSON (zero writes)\n' >&2
      return "${EXIT_CONFIG}"
    fi
    local lresult
    if ! lresult="$(plan_lifecycle "${actions}" "${doc}" "${lifecycle}")"; then
      printf 'reconcile: the lifecycle plan could not be assembled (zero writes)\n' >&2
      return "${EXIT_CONFIG}"
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

  # US9 self-healing: --repair-hooks performs the one-command hook repair reachable
  # from any run (FR-047); every run then reports hook health in the summary. The
  # path is relative to the repository root (cwd), overridable for tests.
  local ext_path hooks_health
  ext_path="${SPEC_KIT_JIRA_EXTENSIONS_YML:-.specify/extensions.yml}"
  if [[ "${repair_hooks}" == "true" ]]; then
    register_hooks_write "${ext_path}" "${dry_run}" > /dev/null || true
  fi
  hooks_health="$(register_hooks_health "${ext_path}")" || true
  [[ -z "${hooks_health}" ]] && hooks_health='{"disabled":[],"missing":[],"present":[]}'

  # FR-046: in hook context a bridge failure NEVER fails the host command — after
  # surfacing a single actionable WARNING the exit is downgraded to 0, so the mirror
  # can fail without ever affecting the spec-kit command that triggered it.
  if [[ -n "${SPEC_KIT_JIRA_HOOK_CONTEXT:-}" && "${rc}" -ne 0 ]]; then
    printf 'WARNING: the Jira mirror did not complete (exit %s); the host command is unaffected. Run reconcile --repair-hooks or /speckit.jira.config to recover.\n' "${rc}" >&2
    rc=0
  fi

  # Report the action set with the base URL stripped to a host-relative path: the
  # site host is a coordinate that must never appear in output (Constitution IV),
  # and it also keeps the summary stable across the mock's per-run ephemeral port.
  local disp_actions
  disp_actions="$(jq -c --arg b "${base}" '[.[] | .url |= ltrimstr($b)]' <<< "${actions}")"

  # The warnings/notes keys appear only when the lifecycle facts were supplied, so
  # the content-only reconcile (US3) summary is byte-for-byte unchanged.
  # 003 FR-018: adopted tickets are reported by name, with what was added. The
  # key appears only when at least one ticket is adopted, so a reconcile over a
  # purely bridge-created corpus keeps its summary byte-for-byte unchanged.
  local adopted
  adopted="$(_reconcile_adopted_report "${doc}" "${plan_ctx}")"

  local summary
  summary="$(jq -cn \
    --argjson dry "${dry_run}" --argjson c "${created}" --argjson u "${updated}" \
    --argjson x "${rc}" --argjson actions "${disp_actions}" \
    --argjson wc "${warn_count}" --argjson w "${warns}" --argjson no "${notes}" \
    --argjson hl "${has_lifecycle}" --argjson hooks "${hooks_health}" \
    --argjson ad "${adopted}" '
    {schema_version:"1.0", command:"reconcile", dry_run:$dry,
     counts:{created:$c, updated:$u, skipped:0, warnings:$wc, errors:0},
     actions:$actions}
    + (if $hl then {warnings:$w, notes:$no} else {} end)
    + (if ($ad | length) > 0 then {adopted:$ad} else {} end)
    + {hook_health:$hooks, exit_code:$x}' | json_canonical)"

  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${summary}"
  else
    printf '%s' "${summary}" | summary_render_prose
  fi
  return "${rc}"
}
