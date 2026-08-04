#!/usr/bin/env bash
# lib/prereq.sh — Prerequisite checks (NFR-4).
#
# Runs BEFORE any Jira interaction. Bash >= 4 is required (macOS ships 3.2 and
# does not qualify — named explicitly). curl, jq, and git must be present.
# Any failure returns EXIT_PREREQ (5) so the dispatcher never touches Jira.
#
# Port infrastructure only: NO Jira knowledge, NO engine decisions.

[[ -n ${_JIRA_LIB_PREREQ:-} ]] && return 0
_JIRA_LIB_PREREQ=1

# Exit code table is shared across lib modules; `:=` keeps re-sourcing safe and
# lets whichever module loads first seed the value (cli.sh owns the full table).
: "${EXIT_PREREQ:=5}"

# Commands the Bash port requires at runtime.
PREREQ_REQUIRED_CMDS=(curl jq git)

# The bridge's repository-relative entry points, per port (003 FR-014, R6). The
# install copies the extension into `.specify/extensions/jira/` and puts NOTHING
# on PATH, so these paths — not a bare executable name — are what "the bridge"
# means in every message.
PREREQ_BRIDGE_BASH='.specify/extensions/jira/scripts/bash/spec-kit-jira.sh'
PREREQ_BRIDGE_PWSH='.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1'

# prereq_bridge_missing [extension-root] — print the entry point that is
# absent, or nothing when both ports are intact.
#
# This is the SIXTH degraded cause (003 FR-017), and it is the only one the
# bridge cannot report on from inside a run that never started. What it CAN
# detect is the half-broken install: this port running while its twin is
# missing. Reporting that as its own cause — rather than folding it into "not
# configured" or the generic prerequisite gate — is what FR-017 and T090
# require. The state where NEITHER port starts is covered by the verbatim
# fallback block in the command documents (FR-030), because there is no code
# of ours left running to say anything.
#
# No file-mode check (014, C6): the archive install route drops file modes, so
# the entry point's own permissions say nothing about whether the install is
# complete (research R1). `bash <path>` runs it regardless of mode (C1).
#
# shellcheck disable=SC2120  # [extension-root] is optional; every caller omits it
prereq_bridge_missing() {
  local root="${1:-${SPEC_KIT_JIRA_EXTENSION_ROOT:-}}"
  if [[ -z "${root}" ]]; then
    # lib/ -> bash/ -> scripts/ -> <extension root>
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  fi
  local rel
  for rel in scripts/bash/spec-kit-jira.sh scripts/powershell/spec-kit-jira.ps1; do
    if [[ ! -f "${root}/${rel}" ]]; then
      case "${rel}" in
        *bash*) printf '%s' "${PREREQ_BRIDGE_BASH}" ;;
        *) printf '%s' "${PREREQ_BRIDGE_PWSH}" ;;
      esac
      return 0
    fi
  done
  return 0
}

# _prereq_has <command> — true when the command is available.
# Honours _PREREQ_FORCE_MISSING (space-separated) so tests can simulate absence.
_prereq_has() {
  local cmd="$1"
  local forced
  for forced in ${_PREREQ_FORCE_MISSING:-}; do
    [[ "${cmd}" == "${forced}" ]] && return 1
  done
  command -v "${cmd}" > /dev/null 2>&1
}

# prereq_check — verify the runtime; return EXIT_PREREQ (5) on any failure.
prereq_check() {
  local major="${_PREREQ_BASH_MAJOR:-${BASH_VERSINFO[0]}}"
  if ((major < 4)); then
    # shellcheck disable=SC2016  # backticks are literal message text, not a subshell
    printf 'spec-kit-jira: Bash >= 4 required (found major version %s). macOS ships Bash 3.2, which does not qualify — install a newer Bash (e.g. `brew install bash`) and re-run.\n' \
      "${major}" >&2
    return "${EXIT_PREREQ}"
  fi

  local cmd
  local -a missing=()
  for cmd in "${PREREQ_REQUIRED_CMDS[@]}"; do
    _prereq_has "${cmd}" || missing+=("${cmd}")
  done

  if ((${#missing[@]} > 0)); then
    printf 'spec-kit-jira: missing required command(s): %s. Install them and re-run.\n' \
      "${missing[*]}" >&2
    return "${EXIT_PREREQ}"
  fi

  # The bridge's own entry points, reported as their OWN cause and never folded
  # into the generic "missing required command(s)" line above (003 FR-017, T090):
  # a lost file is an install problem with an install remedy, not a missing
  # tool the operator should go and install.
  local bridge
  bridge="$(prereq_bridge_missing)"
  if [[ -n "${bridge}" ]]; then
    printf 'spec-kit-jira: the bridge entry point %s was not found — the extension install is incomplete. Restore it with: %s\n' \
      "${bridge}" 'specify extension add --dev <path-to-spec-kit-jira> --force' >&2
    return "${EXIT_PREREQ}"
  fi

  return 0
}
