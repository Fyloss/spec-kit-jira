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

# --- The text-mode-jq guard (Windows) ----------------------------------------
#
# On Windows the `jq` on PATH is the native jq.exe and its stdout is a TEXT-MODE
# stream: every `\n` it writes leaves the process as CRLF. What made this so
# hard to see is that it does NOT corrupt everything. MSYS bash — the bash the
# port runs under there — strips a trailing CRLF from command substitution, so a
# single-scalar `$(jq -r '.k' ...)` arrives clean, and the great majority of the
# port's jq reads are exactly that. Only output with EMBEDDED newlines keeps its
# CRs, and then on every line but the last: a two-project key list yields
# $'COMP\r' then 'TEAM'; the canonical YAML writer put a CRLF on all but the
# final line of config.local.yml; a hook-health repair hint carried one mid
# string. The PowerShell twin joins with an explicit `n and writes through
# File::WriteAllText, which translates nothing, so every one of those is a byte
# divergence between the ports (NFR-1) — and every one of them surfaced only on
# windows-latest, only in the scenarios that happen to have more than one of
# something.
#
# Two decisions here, both deliberate.
#
# It is a WRAPPER rather than a guard at each multi-line read. Fixing the reads
# one by one was tried first and was wrong: the sites are not enumerable by
# inspection — the CR also travels INSIDE jq-built JSON strings and re-enters
# through a later read, which no grep for `while read` finds. A single seam that
# every jq invocation already passes through is the only place the whole class
# can be closed.
#
# It is INSTALLED CONDITIONALLY, and the condition is asked of jq rather than of
# the OS. On a host whose jq emits LF the wrapper is not defined at all, so the
# POSIX runtime keeps exactly the behaviour it has always had — no extra process
# per call, and no chance of this stripping a CR that a Jira description
# legitimately carries, which would be a divergence introduced by the fix. On a
# host whose jq emits CRLF that content CR is already unrecoverable — jq
# CRLF-ified it on the way out — so stripping the terminator is strictly a
# repair. Probing jq also means the PATH-stub tests exercise the real guard
# instead of a test-only flag.
if [[ "$(command jq -rn '"a\nb"' 2> /dev/null)" == *$'\r'* ]]; then
  jq() {
    # `local -` scopes the option change to this function, and `pipefail` is not
    # optional: without it the pipeline reports SED's status, and every
    # `if jq -e ...` in the port — recognition's duplicate-claim check, the
    # lifecycle-event membership test — would read as TRUE unconditionally. That
    # failure is silent and total, which is why it is enforced here rather than
    # assumed from the entry point's `set -o pipefail`: this function has to be
    # correct for a caller that never set it, including a sourced unit test.
    local -
    set -o pipefail
    # `command` is required: without it this function calls itself.
    command jq "$@" | sed $'s/\r$//'
  }
fi

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

# =============================================================================
# The bridge's runnable invocation (003 FR-014, FR-018, research R6)
# =============================================================================
#
# `specify extension add` copies this repository into the consuming repository's
# `.specify/extensions/jira/` and installs NOTHING on the machine — no binary, no
# PATH entry, no profile edit. A message that tells the operator to run a bare
# `spec-kit-jira` therefore names a command that does not exist, which is exactly
# the reported "spec-kit-jira CLI not installed" symptom.
#
# Every message that tells someone to run the bridge goes through the helper
# below. It names BOTH ports on purpose: the two ports emit byte-identical
# output (Constitution VI), so a message cannot name only the port it happens to
# be running on without breaking the conformance diff — and the operator reading
# it may well be on the other one.
JIRA_BRIDGE_BASH_ENTRY='.specify/extensions/jira/scripts/bash/spec-kit-jira.sh'
JIRA_BRIDGE_PWSH_ENTRY='.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1'

# output_bridge_invocation <args...> — the runnable, per-port invocation of the
# bridge with the given arguments. Every literal it produces is runnable exactly
# as spelled (FR-018), which tests/bash/ci/test_message_command_literals.bats
# asserts mechanically.
output_bridge_invocation() {
  printf '%s %s (on Windows: %s %s)' \
    "${JIRA_BRIDGE_BASH_ENTRY}" "$*" "${JIRA_BRIDGE_PWSH_ENTRY}" "$*"
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
  # recognised/assigned (Phase 7, US1/US2) exist only on reconcile's summary
  # — a reader confirms an unchanged re-run recognised every story and
  # created nothing, without needing --json.
  if [[ "$(jq -r '.counts | has("recognised")' <<< "${json}")" == "true" ]]; then
    local recognised assigned
    recognised="$(jq -r '.counts.recognised' <<< "${json}")"
    assigned="$(jq -r '.counts.assigned' <<< "${json}")"
    printf 'Recognised: %s, Assigned: %s\n' "${recognised}" "${assigned}"
  fi
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
