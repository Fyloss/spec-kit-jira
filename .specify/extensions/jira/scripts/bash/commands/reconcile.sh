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

: "${EXIT_CONFIG:=4}"

# _reconcile_plan_context <base-url> — the plan context: base_url plus any caller
# overrides from SPEC_KIT_JIRA_PLAN_CONTEXT (JSON). base_url always wins.
_reconcile_plan_context() {
  local base="$1" extra="${SPEC_KIT_JIRA_PLAN_CONTEXT:-}"
  [[ -z "${extra}" ]] && extra='{}'
  jq -cn --arg b "${base}" --argjson e "${extra}" '$e + {base_url:$b}'
}

# cmd_reconcile <argv...> — reconcile one specification into its Jira project.
# Echoes the run summary to stdout; returns the exit code.
cmd_reconcile() {
  local parsed json="false" dry_run="false" exit_code="0" error=""
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
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

  # ENGINE: parse the spec into neutral content, then assemble + validate.
  parse="$(parse_spec "${slug}" < "${spec_file}")"
  ctx="$(jq -cn --argjson sr "${spec_ref}" --arg pk "${project_key}" --arg es "${epic_strategy}" \
    '{spec_ref:$sr, project_key:$pk, epic_strategy:$es}')"
  if ! doc="$(interchange_build "${parse}" "${ctx}")"; then
    printf 'reconcile: the specification could not be assembled into a valid neutral document (zero writes)\n' >&2
    return "${EXIT_CONFIG}"
  fi

  # SINK: plan the ordered action set (the --dry-run report is exactly this set).
  local plan_ctx actions
  plan_ctx="$(_reconcile_plan_context "${base}")"
  actions="$(plan_writes "${doc}" "${plan_ctx}")"

  local created updated rc=0
  created="$(jq '[.[] | select(.method=="POST")] | length' <<< "${actions}")"
  updated="$(jq '[.[] | select(.method=="PUT")] | length' <<< "${actions}")"

  if [[ "${dry_run}" != "true" ]]; then
    apply_writes "${actions}"
    rc=$?
  fi

  # Report the action set with the base URL stripped to a host-relative path: the
  # site host is a coordinate that must never appear in output (Constitution IV),
  # and it also keeps the summary stable across the mock's per-run ephemeral port.
  local disp_actions
  disp_actions="$(jq -c --arg b "${base}" '[.[] | .url |= ltrimstr($b)]' <<< "${actions}")"

  local summary
  summary="$(jq -cn \
    --argjson dry "${dry_run}" --argjson c "${created}" --argjson u "${updated}" \
    --argjson x "${rc}" --argjson actions "${disp_actions}" '
    {schema_version:"1.0", command:"reconcile", dry_run:$dry,
     counts:{created:$c, updated:$u, skipped:0, warnings:0, errors:0},
     actions:$actions, exit_code:$x}' | json_canonical)"

  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${summary}"
  else
    printf '%s' "${summary}" | summary_render_prose
  fi
  return "${rc}"
}
