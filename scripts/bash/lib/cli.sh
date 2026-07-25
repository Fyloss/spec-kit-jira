#!/usr/bin/env bash
# lib/cli.sh — CLI arg parsing + the shared exit-code table.
#
# The exit-code table (contracts/cli-contract.md) is the single source of the
# numeric codes, shared by every module and asserted byte-identically across
# ports. Parsing emits machine-readable key=value lines (FR-002) in a fixed key
# order so the two ports produce identical bytes; the dispatcher reads `exit=`
# and exits accordingly (parse itself never terminates the process).
#
# Port infrastructure only: NO Jira knowledge.

[[ -n ${_JIRA_LIB_CLI:-} ]] && return 0
_JIRA_LIB_CLI=1

# Exit-code table (monotonically escalating — Constitution III). `:=` keeps
# re-sourcing safe across modules.
: "${EXIT_OK:=0}"
: "${EXIT_USAGE:=1}"
: "${EXIT_FAILCLOSED:=2}"
: "${EXIT_AUTH:=3}"
: "${EXIT_CONFIG:=4}"
: "${EXIT_PREREQ:=5}"
: "${EXIT_BLOCK:=9}"

# cli_exit_code <symbol> — resolve a symbolic name to its numeric exit code.
cli_exit_code() {
  case "$1" in
    ok) printf '%s' "${EXIT_OK}" ;;
    usage) printf '%s' "${EXIT_USAGE}" ;;
    fail_closed) printf '%s' "${EXIT_FAILCLOSED}" ;;
    auth) printf '%s' "${EXIT_AUTH}" ;;
    config) printf '%s' "${EXIT_CONFIG}" ;;
    prereq) printf '%s' "${EXIT_PREREQ}" ;;
    block) printf '%s' "${EXIT_BLOCK}" ;;
    *) return 1 ;;
  esac
}

# cli_parse <args...> — parse the command line; print key=value state lines.
cli_parse() {
  local command="" dry_run=false json=false on_drift=abort
  local verbose=false repair_hooks=false help=false error=""
  local -a positional=()

  while (($#)); do
    case "$1" in
      config | reconcile | mention)
        if [[ -z "${command}" ]]; then command="$1"; else positional+=("$1"); fi
        ;;
      --dry-run) dry_run=true ;;
      --json) json=true ;;
      --verbose) verbose=true ;;
      --repair-hooks) repair_hooks=true ;;
      --help | -h) help=true ;;
      --on-drift=*)
        on_drift="${1#*=}"
        if [[ "${on_drift}" != abort && "${on_drift}" != proceed ]]; then
          error="invalid --on-drift value: ${on_drift} (expected abort|proceed)"
        fi
        ;;
      --on-drift) error="--on-drift requires a value (--on-drift=abort|proceed)" ;;
      --*) error="unknown flag: $1" ;;
      *) positional+=("$1") ;;
    esac
    [[ -n "${error}" ]] && break
    shift
  done

  if [[ -n "${error}" ]]; then
    printf 'exit=%s\n' "${EXIT_USAGE}"
    printf 'error=%s\n' "${error}"
    return 0
  fi

  local args_joined
  args_joined="$(
    IFS=' '
    printf '%s' "${positional[*]}"
  )"

  printf 'command=%s\n' "${command}"
  printf 'dry_run=%s\n' "${dry_run}"
  printf 'json=%s\n' "${json}"
  printf 'on_drift=%s\n' "${on_drift}"
  printf 'verbose=%s\n' "${verbose}"
  printf 'repair_hooks=%s\n' "${repair_hooks}"
  printf 'help=%s\n' "${help}"
  printf 'args=%s\n' "${args_joined}"
  printf 'exit=%s\n' "${EXIT_OK}"
}
