#!/usr/bin/env bash
# commands/feature.sh — Ticket-first feature naming (002 US3, FR-013…FR-017).
#
# `cmd_feature <argv...>` is the deterministic step registered as the
# `before_specify` hook. It loads the committed `teams:` catalogue and the
# human-owned `.specify/jira/personal.yml` selection, resolves the effective
# team (honouring a cross-team `--use-team` confirmation), resolves the Jira
# ticket BEFORE naming (validate a mentioned key, else guarded-create one), and
# emits the branch name and flat folder short-name.
#
# Non-blocking by construction (FR-016/FR-017): no team selected ⇒
# {active:false}; Jira unreachable or a create refused ⇒ {active:false} plus one
# warning. The host specify flow then proceeds exactly as it does today.

[[ -n ${_JIRA_CMD_FEATURE:-} ]] && return 0
_JIRA_CMD_FEATURE=1

_cmd_feature_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../lib/cli.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../lib/config.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../engine/naming.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../sink/jira/ticket.sh"

# _feat_emit <json> <json-flag> — print the canonical result (JSON or prose).
_feat_emit() {
  local payload="$1" json="$2"
  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${payload}"
  else
    printf '%s' "${payload}" | summary_render_prose 2> /dev/null || printf '%s\n' "${payload}"
  fi
}

# cmd_feature <argv...> — see the file header. Echoes the result to stdout;
# returns the exit code.
cmd_feature() {
  local parsed json="false" dry_run="false" args="" use_team="" exit_code="0" error=""
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      use_team) use_team="${value}" ;;
      args) args="${value}" ;;
      exit) exit_code="${value}" ;;
      error) error="${value}" ;;
    esac
  done <<< "${parsed}"
  if [[ "${exit_code}" != "0" ]]; then
    [[ -n "${error}" ]] && printf 'feature: %s\n' "${error}" >&2
    return "${exit_code}"
  fi

  local dir="${JIRA_CONFIG_DIR:-.specify/jira}"

  # (1) No committed catalogue at all ⇒ pass-through (FR-017).
  if [[ ! -f "${dir}/config.yml" ]]; then
    _feat_emit '{"active":false}' "${json}"
    return 0
  fi
  local merged
  if ! merged="$(config_load "${dir}" 2> /dev/null)"; then
    _feat_emit '{"active":false}' "${json}"
    return 0
  fi
  local team_count
  team_count="$(jq -r '(.teams // []) | length' <<< "${merged}")"
  if [[ "${team_count}" -eq 0 ]]; then
    _feat_emit '{"active":false}' "${json}"
    return 0
  fi

  # (2) Personal selection (human-owned; validated; never written). An invalid
  #     file fails closed with a located error (exit 4).
  local personal
  personal="$(config_personal_load "${dir}" "${merged}")" || return $?
  local p_active p_team p_override
  p_active="$(jq -r '.active' <<< "${personal}")"
  p_team="$(jq -r '.team // ""' <<< "${personal}")"
  p_override="$(jq -c '.override // null' <<< "${personal}")"

  # No selection and no cross-team answer ⇒ pass-through (FR-017).
  if [[ "${p_active}" != "true" && -z "${use_team}" ]]; then
    _feat_emit '{"active":false}' "${json}"
    return 0
  fi

  # (3) Effective team resolution.
  local eff_id override_used="false" override='null'
  if [[ -n "${use_team}" ]]; then
    if ! jq -e --arg id "${use_team}" '([.teams[].id] | index($id)) != null' <<< "${merged}" > /dev/null; then
      printf 'feature: unknown team "%s" — valid teams: %s\n' \
        "${use_team}" "$(jq -r '[.teams[].id] | join(", ")' <<< "${merged}")" >&2
      return "$(cli_exit_code config)"
    fi
    eff_id="${use_team}"
  else
    eff_id="${p_team}"
    override="${p_override}"
    [[ "${override}" != "null" ]] && override_used="true"
  fi

  # (4) Description is required once a team is in play (FR-013 precedes naming).
  #     The optional leading positional is a mentioned issue key.
  local -a words=()
  read -ra words <<< "${args}"
  local ticket_key="" desc=""
  if [[ ${#words[@]} -gt 0 && "${words[0]}" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]]; then
    ticket_key="${words[0]}"
    desc="${words[*]:1}"
  else
    desc="${words[*]}"
  fi
  if [[ -z "${desc}" ]]; then
    printf 'feature: a feature description is required\n' >&2
    return "$(cli_exit_code usage)"
  fi

  # Resolve the effective team entry and its naming rule.
  local team_entry prefix pattern eff_project
  team_entry="$(jq -c --arg id "${eff_id}" '.teams[] | select(.id == $id)' <<< "${merged}")"
  eff_project="$(jq -r '.project' <<< "${team_entry}")"
  if [[ "${override}" != "null" ]]; then
    prefix="$(jq -r --argjson o "${override}" --argjson t "${team_entry}" '($o.folder_prefix // $t.folder_prefix)' <<< 'null')"
    pattern="$(jq -r --argjson o "${override}" --argjson t "${team_entry}" '($o.branch_pattern // $t.branch_pattern)' <<< 'null')"
  else
    prefix="$(jq -r '.folder_prefix' <<< "${team_entry}")"
    pattern="$(jq -r '.branch_pattern' <<< "${team_entry}")"
  fi

  local slug
  slug="$(naming_slug "${desc}")"

  # (5) Ticket resolution BEFORE naming.
  local number action ticket_key_out
  if [[ -n "${ticket_key}" ]]; then
    # Mentioned key: validate (read). A fail-closed read never falls back.
    local validated
    validated="$(ticket_validate "${ticket_key}")" || return $?
    local ticket_project ticket_team
    ticket_project="$(jq -r '.project // ""' <<< "${validated}")"
    ticket_team="$(jq -r --arg p "${ticket_project}" '([.teams[] | select(.project == $p) | .id] | first) // ""' <<< "${merged}")"

    # Cross-team confirmation (only when the operator did not answer it).
    if [[ -z "${use_team}" ]]; then
      if [[ -z "${ticket_team}" || "${ticket_team}" != "${p_team}" ]]; then
        local tt_json
        if [[ -z "${ticket_team}" ]]; then tt_json='null'; else tt_json="$(jq -Rn --arg v "${ticket_team}" '$v')"; fi
        _feat_emit "$(jq -cn --arg tk "${ticket_key}" --argjson tt "${tt_json}" --arg st "${p_team}" \
          '{active:true, confirmation_required:{ticket:$tk, ticket_team:$tt, selected_team:$st}}' | json_canonical)" "${json}"
        return 0
      fi
    fi

    number="$(naming_ticket_number "${ticket_key}")"
    ticket_key_out="$(jq -Rn --arg v "${ticket_key}" '$v')"
    if [[ "${dry_run}" == "true" ]]; then action="would-attach"; else action="attached"; fi
  else
    # No mentioned key: guarded create in the effective team's project.
    if [[ "${dry_run}" == "true" ]]; then
      # Predict only — zero Jira calls, no branch (no number yet).
      local short_dry
      short_dry="$(naming_short_name "${prefix}" "${slug}")"
      _feat_emit "$(jq -cn --arg t "${eff_id}" --arg sn "${short_dry}" --argjson ou "${override_used}" \
        '{active:true, team:$t, ticket:{key:null, number:null, action:"would-create"},
          branch_name:null, short_name:$sn, override_used:$ou, warnings:[]}' | json_canonical)" "${json}"
      return 0
    fi

    local typeid
    typeid="$(jq -r '.story_type_id // ""' <<< "${SPEC_KIT_JIRA_PLAN_CONTEXT:-\{\}}" 2> /dev/null)"
    local spec_ref
    spec_ref="$(jq -cn --arg r "${SPEC_KIT_JIRA_REPO:-local/repo}" --arg s "${SPEC_KIT_JIRA_SPEC_SLUG:-spec}" \
      '{repo:$r, spec_slug:$s}')"

    if [[ -z "${typeid}" || -z "${SPEC_KIT_JIRA_BASE_URL:-}" ]]; then
      _feat_fallback "${json}"
      return 0
    fi

    # The `|| rc=$?` guard keeps the entry point's errexit from aborting the
    # ceremony before the FR-016 fallback can run.
    local tmp created rc=0
    tmp="$(mktemp)"
    ticket_create "${eff_project}" "${desc}" "${typeid}" '[]' '[]' "${spec_ref}" > "${tmp}" || rc=$?
    created="$(cat "${tmp}")"
    rm -f "${tmp}"
    if ((rc == 9)); then
      return 9
    elif ((rc != 0)); then
      _feat_fallback "${json}"
      return 0
    fi
    local created_key
    created_key="$(jq -r '.key' <<< "${created}")"
    number="$(naming_ticket_number "${created_key}")"
    ticket_key_out="$(jq -Rn --arg v "${created_key}" '$v')"
    action="created"
  fi

  # (6) Naming (pure engine).
  local branch_name short_name
  branch_name="$(naming_expand_pattern "${pattern}" "${number}" "${slug}")"
  short_name="$(naming_short_name "${prefix}" "${slug}")"

  _feat_emit "$(jq -cn --arg t "${eff_id}" --argjson tk "${ticket_key_out}" --arg num "${number}" \
    --arg act "${action}" --arg bn "${branch_name}" --arg sn "${short_name}" --argjson ou "${override_used}" \
    '{active:true, team:$t, ticket:{key:$tk, number:$num, action:$act},
      branch_name:$bn, short_name:$sn, override_used:$ou, warnings:[]}' | json_canonical)" "${json}"
  return 0
}

# _feat_fallback <json-flag> — the FR-016 non-blocking fallback: {active:false}
# plus exactly one warning; one WARNING: line on stderr; exit 0.
_feat_fallback() {
  local json="$1"
  local msg="could not resolve a ticket in Jira — proceeding without one (reconciliation will attach it later)"
  printf 'WARNING: %s\n' "${msg}" >&2
  _feat_emit "$(jq -cn --arg w "${msg}" '{active:false, warnings:[$w]}' | json_canonical)" "${json}"
}
