#!/usr/bin/env bash
# commands/mention.sh — The mention command (US10, T088; FR-049/FR-050/FR-051).
#
# `cmd_mention <issue-key>` adopts an existing, human-authored Jira ticket into a
# spec: it reads the ticket's identity marker, and
#   * if the ticket already carries ANOTHER spec's identity, it makes ZERO writes
#     and refuses with an actionable message (reopen the original spec, or proceed
#     with a new ticket linked to this one) — EXIT_CONFIG (4), FR-051;
#   * otherwise it performs the read-only content fetch (FR-050, so the drafted
#     spec.md starts informed), stamps the spec's identity on the ticket, updates
#     only that ticket, and logs the mutation in the run summary (FR-049).
#
# The spec ref (repo + slug) — which the sink cannot know — is supplied via the
# environment, exactly as the reconcile command supplies it (US8 routing fills
# these from config in the wired flow). The identity origin recorded is `human`:
# the mentioned ticket pre-existed the bridge, so its description is thereafter
# treated as human-authored (US7 managed-panel splice) on subsequent reconciles.

[[ -n ${_JIRA_CMD_MENTION:-} ]] && return 0
_JIRA_CMD_MENTION=1

_cmd_mention_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_cmd_mention_dir}/../lib/cli.sh"
# shellcheck source=/dev/null
source "${_cmd_mention_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_cmd_mention_dir}/../sink/jira/identity.sh"
# shellcheck source=/dev/null
source "${_cmd_mention_dir}/../sink/jira/discovery.sh"

# cmd_mention <argv...> — read/edit one mentioned ticket. Echoes the run summary
# to stdout; returns the exit code.
cmd_mention() {
  local parsed json="false" dry_run="false" args="" exit_code="0" error=""
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      args) args="${value}" ;;
      exit) exit_code="${value}" ;;
      error) error="${value}" ;;
    esac
  done <<< "${parsed}"
  if [[ "${exit_code}" != "0" ]]; then
    [[ -n "${error}" ]] && printf 'mention: %s\n' "${error}" >&2
    return "${exit_code}"
  fi

  # The issue key is the sole required positional argument (cli-contract.md).
  local issue_key="${args%% *}"
  if [[ -z "${issue_key}" ]]; then
    printf 'mention: an issue key argument is required (mention PROJ-123)\n' >&2
    return "$(cli_exit_code usage)"
  fi

  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'mention: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi

  local spec_ref
  spec_ref="$(jq -cn --arg r "${SPEC_KIT_JIRA_REPO:-local/repo}" --arg s "${SPEC_KIT_JIRA_SPEC_SLUG:-spec}" \
    '{repo:$r, spec_slug:$s}')"

  # (1) Identity read — a fail-closed read (non-404) aborts before any write.
  local marker
  marker="$(identity_read "${issue_key}")" || return $?

  # (2) FR-051: a ticket already claimed by ANOTHER spec is refused with zero writes.
  if [[ -n "${marker}" ]] && identity_claimed_by_other "${marker}" "${spec_ref}"; then
    local other
    other="$(jq -r '"\(.repo // "?")/\(.spec_slug // "?")"' <<< "${marker}")"
    printf 'mention: %s is already claimed by another spec (%s); reopen that spec, or proceed with a new ticket linked to %s\n' \
      "${issue_key}" "${other}" "${issue_key}" >&2
    local rsummary
    rsummary="$(jq -cn --argjson dry "${dry_run}" '
      {schema_version:"1.0", command:"mention", dry_run:$dry,
       counts:{created:0, updated:0, skipped:0, warnings:0, errors:1},
       mutations:[], exit_code:4}' | json_canonical)"
    if [[ "${json}" == "true" ]]; then
      printf '%s\n' "${rsummary}"
    else
      printf '%s' "${rsummary}" | summary_render_prose
    fi
    return "$(cli_exit_code config)"
  fi

  # (3) FR-050 read-only fetch — the ticket's content and context. A fail-closed
  #     read aborts before the stamp (Constitution III). The fetched neutral doc is
  #     materialised for the drafting agent when SPEC_KIT_JIRA_MENTION_OUT is set.
  local fetch
  fetch="$(fetch_mentioned "${issue_key}")" || return $?
  if [[ -n "${SPEC_KIT_JIRA_MENTION_OUT:-}" && "${dry_run}" != "true" ]]; then
    printf '%s\n' "${fetch}" > "${SPEC_KIT_JIRA_MENTION_OUT}"
  fi

  # (4) FR-049: stamp the spec's identity (origin human) and log the mutation. The
  #     --dry-run twin predicts the same single mutation without performing it.
  if [[ "${dry_run}" != "true" ]]; then
    identity_write "${issue_key}" "${spec_ref}" "human" || return $?
  fi

  local summary
  summary="$(jq -cn --argjson dry "${dry_run}" --arg k "${issue_key}" '
    {schema_version:"1.0", command:"mention", dry_run:$dry,
     counts:{created:0, updated:1, skipped:0, warnings:0, errors:0},
     mutations:[{ticket:$k, action:"stamped spec identity marker"}],
     exit_code:0}' | json_canonical)"

  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${summary}"
  else
    printf '%s' "${summary}" | summary_render_prose
  fi
  return 0
}
