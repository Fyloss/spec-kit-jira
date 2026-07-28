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
  local command="" dry_run=false json=false on_drift=abort on_drift_set=false
  local verbose=false repair_hooks=false help=false error="" use_team="" yes=false
  local -a positional=() styles=() binds=() specs=()

  while (($#)); do
    case "$1" in
      config | reconcile | mention | feature | adopt)
        if [[ -z "${command}" ]]; then command="$1"; else positional+=("$1"); fi
        ;;
      --dry-run) dry_run=true ;;
      --json) json=true ;;
      --verbose) verbose=true ;;
      --repair-hooks) repair_hooks=true ;;
      # `adopt` pre-confirms the apply phase with --yes (003 research §6); the
      # plan is still printed first.
      --yes) yes=true ;;
      --bind)
        # Repeatable explicit binding (003 US4): <folder>[:us<N>]=<KEY>. Only the
        # STRUCTURE is checked here — non-empty on both sides of `=`. The key's
        # SHAPE is validated in the sink, so no key-shaped literal enters the
        # neutral layers (research §9).
        if [[ $# -lt 2 ]]; then
          error="--bind requires a value (--bind <folder>[:us<N>]=<KEY>)"
        else
          shift
          if [[ "$1" == *=* && -n "${1%%=*}" && -n "${1#*=}" ]]; then
            binds+=("$1")
          else
            error="invalid --bind value: $1 (expected <folder>[:us<N>]=<KEY>)"
          fi
        fi
        ;;
      --spec)
        # Repeatable adoption scope (003 US6): the spec folders a run considers.
        if [[ $# -lt 2 ]]; then
          error="--spec requires a value (--spec <folder>)"
        else
          shift
          if [[ -n "$1" ]]; then
            specs+=("$1")
          else
            error="--spec requires a non-empty folder name"
          fi
        fi
        ;;
      --help | -h) help=true ;;
      --style)
        # Repeatable operator answer to the closed style question (002 US1):
        # --style KEY=VALUE with VALUE restricted to the two enum members.
        if [[ $# -lt 2 ]]; then
          error="--style requires a value (--style KEY=VALUE)"
        else
          shift
          if [[ "$1" =~ ^[A-Z][A-Z0-9_]+=(company_managed|team_managed)$ ]]; then
            styles+=("$1")
          else
            error="invalid --style value: $1 (expected <PROJECT_KEY>=company_managed|team_managed)"
          fi
        fi
        ;;
      --use-team)
        # The answer to the cross-team closed confirmation (002 US3, FR-014).
        if [[ $# -lt 2 ]]; then
          error="--use-team requires a value (--use-team <id>)"
        else
          shift
          use_team="$1"
        fi
        ;;
      --on-drift=*)
        on_drift="${1#*=}"
        on_drift_set=true
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

  # `adopt` performs no transition and reads no status, so drift has no meaning
  # for it. The check runs after the loop because the command may be declared
  # after the flag (adopt-cli-contract §Flags).
  if [[ -z "${error}" && "${command}" == "adopt" && "${on_drift_set}" == "true" ]]; then
    error="--on-drift is not accepted by adopt (adoption performs no transition)"
  fi

  if [[ -n "${error}" ]]; then
    printf 'exit=%s\n' "${EXIT_USAGE}"
    printf 'error=%s\n' "${error}"
    return 0
  fi

  local args_joined styles_joined binds_joined specs_joined
  args_joined="$(
    IFS=' '
    printf '%s' "${positional[*]}"
  )"
  styles_joined="$(
    IFS=' '
    printf '%s' "${styles[*]-}"
  )"
  binds_joined="$(
    IFS=' '
    printf '%s' "${binds[*]-}"
  )"
  specs_joined="$(
    IFS=' '
    printf '%s' "${specs[*]-}"
  )"

  printf 'command=%s\n' "${command}"
  printf 'dry_run=%s\n' "${dry_run}"
  printf 'json=%s\n' "${json}"
  printf 'on_drift=%s\n' "${on_drift}"
  printf 'verbose=%s\n' "${verbose}"
  printf 'repair_hooks=%s\n' "${repair_hooks}"
  printf 'help=%s\n' "${help}"
  printf 'styles=%s\n' "${styles_joined}"
  printf 'use_team=%s\n' "${use_team}"
  printf 'yes=%s\n' "${yes}"
  printf 'binds=%s\n' "${binds_joined}"
  printf 'specs=%s\n' "${specs_joined}"
  printf 'args=%s\n' "${args_joined}"
  printf 'exit=%s\n' "${EXIT_OK}"
}
