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

  return 0
}
