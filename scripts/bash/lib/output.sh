#!/usr/bin/env bash
# lib/output.sh — Canonical serialisation + run-summary rendering.
#
# The canonical serialiser is the byte-parity contract (Constitution VI, NFR-1,
# research §11): stable key ordering, compact, raw UTF-8, no trailing newline.
# Both ports MUST emit identical bytes for identical input; the PowerShell port
# reimplements the same canonical form (see lib/Output.psm1) rather than relying
# on ConvertTo-Json's native formatting.
#
# Port infrastructure only: NO Jira knowledge.

[[ -n ${_JIRA_LIB_OUTPUT:-} ]] && return 0
_JIRA_LIB_OUTPUT=1

# json_canonical — read JSON on stdin, write the canonical form to stdout.
#   - keys sorted (-S), compact (-c)
#   - raw UTF-8 (jq does not \u-escape non-ASCII)
#   - no trailing newline (command substitution strips jq's)
json_canonical() {
  printf '%s' "$(jq -cS .)"
}

# uri_encode <string> — percent-encode for a query component, applying the
# @uri rule and the %20->+ normalisation (research §11).
uri_encode() {
  local encoded
  encoded="$(jq -rn --arg s "$1" '$s|@uri')"
  printf '%s' "${encoded//%20/+}"
}

# output_warn <message> — the WARNING channel (NFR-5). Always to stderr so it
# never contaminates a --json summary on stdout.
output_warn() {
  printf 'WARNING: %s\n' "$1" >&2
}

# summary_build_json <command> <dry_run> <created> <updated> <skipped> <warnings> <errors> <exit_code>
# Build the canonical --json run summary (run-summary.schema.json). Commands may
# extend the object; this is the required core.
summary_build_json() {
  jq -cn \
    --arg cmd "$1" --argjson dry "$2" \
    --argjson c "$3" --argjson u "$4" --argjson s "$5" \
    --argjson w "$6" --argjson e "$7" --argjson x "$8" \
    '{schema_version:"1.0",command:$cmd,dry_run:$dry,counts:{created:$c,updated:$u,skipped:$s,warnings:$w,errors:$e},exit_code:$x}' \
    | json_canonical
}

# summary_render_prose — read a run-summary JSON on stdin, render human prose
# (the default output). Byte-identical to the PowerShell port.
summary_render_prose() {
  local json
  json="$(cat)"
  local command dry created updated skipped warnings errors exit_code suffix=""
  command="$(jq -r '.command' <<< "${json}")"
  dry="$(jq -r '.dry_run // false' <<< "${json}")"
  created="$(jq -r '.counts.created' <<< "${json}")"
  updated="$(jq -r '.counts.updated' <<< "${json}")"
  skipped="$(jq -r '.counts.skipped' <<< "${json}")"
  warnings="$(jq -r '.counts.warnings' <<< "${json}")"
  errors="$(jq -r '.counts.errors' <<< "${json}")"
  exit_code="$(jq -r '.exit_code' <<< "${json}")"
  [[ "${dry}" == "true" ]] && suffix=" (dry-run)"
  printf 'Command: %s%s\n' "${command}" "${suffix}"
  printf 'Created: %s, Updated: %s, Skipped: %s\n' "${created}" "${updated}" "${skipped}"
  printf 'Warnings: %s, Errors: %s\n' "${warnings}" "${errors}"
  # The config ceremony's effects, reported separately (FR-054). Rendered in a
  # fixed order (discovery, hooks, readme, gitignore) so both ports match
  # byte-for-byte.
  if [[ "$(jq -r 'has("effects")' <<< "${json}")" == "true" ]]; then
    printf 'Effects:\n'
    local effect status detail line
    for effect in discovery hooks readme gitignore; do
      status="$(jq -r --arg e "${effect}" '.effects[$e].status // empty' <<< "${json}")"
      [[ -z "${status}" ]] && continue
      detail="$(jq -r --arg e "${effect}" '.effects[$e].detail // empty' <<< "${json}")"
      line="  ${effect}: ${status}"
      [[ -n "${detail}" ]] && line="${line} — ${detail}"
      printf '%s\n' "${line}"
      # The per-project style audit (FR-003) is nested under the discovery
      # effect so a wrong binding can be audited from the default output, not
      # only from --json. jq's `keys` sorts by code point, which is the
      # PowerShell port's ordinal sort.
      if [[ "${effect}" == "discovery" ]]; then
        local pkey pstyle psource
        while IFS= read -r pkey; do
          [[ -z "${pkey}" ]] && continue
          pstyle="$(jq -r --arg k "${pkey}" '.effects.discovery.projects[$k].style // empty' <<< "${json}")"
          [[ -z "${pstyle}" ]] && continue
          psource="$(jq -r --arg k "${pkey}" '.effects.discovery.projects[$k].style_source // empty' <<< "${json}")"
          printf '    %s: %s (%s)\n' "${pkey}" "${pstyle}" "${psource}"
        done <<< "$(jq -r '(.effects.discovery.projects // {}) | keys[]?' <<< "${json}")"
      fi
    done
  fi
  # Adopted tickets and what this run added to each (003 FR-018). The default
  # output is what a Product Owner reads, so the reassurance that nothing outside
  # the managed panel was touched belongs here, not only in --json.
  if [[ "$(jq -r 'has("adopted") and ((.adopted | length) > 0)' <<< "${json}")" == "true" ]]; then
    printf 'Adopted:\n'
    local aline
    while IFS= read -r aline; do
      [[ -z "${aline}" ]] && continue
      printf '  %s\n' "${aline}"
    done <<< "$(jq -r '.adopted[] | "\(.ticket): \(.action)"' <<< "${json}")"
  fi
  # The degraded run's provisional team proposals and copy-pasteable re-run
  # guidance (FR-008/FR-009): the agent command doc relays them verbatim, so
  # they must exist in the default output, not only in --json.
  if [[ "$(jq -r 'has("provisional") and ((.provisional | length) > 0)' <<< "${json}")" == "true" ]]; then
    printf 'Provisional teams: %s\n' "$(jq -r '[.provisional[].team_prefix] | join(", ")' <<< "${json}")"
  fi
  if [[ "$(jq -r 'has("rerun_guidance")' <<< "${json}")" == "true" ]]; then
    printf 'Rerun: %s\n' "$(jq -r '.rerun_guidance' <<< "${json}")"
  fi
  printf 'Exit: %s\n' "${exit_code}"
}
