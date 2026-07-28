#!/usr/bin/env bash
# spec-kit-jira.sh — entry-point dispatcher (Bash port).
#
# The single executable seam between the agent/CLI and the extension. In order:
#   1. Run prerequisite checks (NFR-4) — no Jira interaction happens before they
#      pass; a failure exits EXIT_PREREQ (5).
#   2. Parse the CLI into machine-readable state (lib/cli.sh); a usage error
#      exits EXIT_USAGE (1); --help prints usage and exits 0.
#   3. Route the selected command to its cmd_<name> entry, sourced on demand from
#      the commands directory (overridable via SPEC_KIT_JIRA_COMMANDS_DIR so the
#      dispatcher is exercisable before the real commands land).
#
# Command modules (commands/<name>.sh) define cmd_<name> and receive the raw
# argv; they own their own parsing via lib/cli.sh. Until a command is built its
# module is absent and the dispatcher reports a usage error rather than routing.

set -euo pipefail

_ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ENTRY_DIR}/lib/cli.sh"
# shellcheck source=/dev/null
source "${_ENTRY_DIR}/lib/prereq.sh"

: "${SPEC_KIT_JIRA_COMMANDS_DIR:=${_ENTRY_DIR}/commands}"

# _usage — print the usage block with explicit LF so both ports emit byte-identical
# bytes regardless of host line-ending conventions (NFR-1). $1 is the target fd.
_usage() {
  printf '%s\n' \
    'usage: spec-kit-jira <config|reconcile|mention|feature> [options]' \
    '  --dry-run                 predict actions without writing' \
    '  --json                    machine-readable run summary' \
    '  --on-drift=abort|proceed  drift handling (default: abort)' \
    '  --verbose                 verbose diagnostics' \
    '  -h, --help                show this help' >&"$1"
}

main() {
  # (1) Prerequisites gate every path — never touch Jira before this passes.
  prereq_check || return $?

  # (2) Parse into key=value state lines.
  local parsed
  parsed="$(cli_parse "$@")"

  local command="" help="false" exit_code=0 error=""
  while IFS='=' read -r key value; do
    case "${key}" in
      command) command="${value}" ;;
      help) help="${value}" ;;
      exit) exit_code="${value}" ;;
      error) error="${value}" ;;
    esac
  done <<< "${parsed}"

  if [[ "${exit_code}" != "0" ]]; then
    [[ -n "${error}" ]] && printf 'spec-kit-jira: %s\n' "${error}" >&2
    _usage 2
    return "${exit_code}"
  fi

  if [[ "${help}" == "true" ]]; then
    _usage 1
    return 0
  fi

  if [[ -z "${command}" ]]; then
    printf 'spec-kit-jira: a command is required (config|reconcile|mention|feature)\n' >&2
    _usage 2
    return "$(cli_exit_code usage)"
  fi

  # (3) Route to the command's on-demand module.
  local cmd_file="${SPEC_KIT_JIRA_COMMANDS_DIR}/${command}.sh"
  if [[ ! -f "${cmd_file}" ]]; then
    printf 'spec-kit-jira: command not available: %s\n' "${command}" >&2
    return "$(cli_exit_code usage)"
  fi
  # shellcheck source=/dev/null
  source "${cmd_file}"
  local fn="cmd_${command}"
  if ! declare -F "${fn}" > /dev/null; then
    printf 'spec-kit-jira: command entry missing: %s\n' "${fn}" >&2
    return "$(cli_exit_code usage)"
  fi
  "${fn}" "$@"
}

main "$@"
