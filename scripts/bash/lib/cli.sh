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
  local verbose=false help=false error="" use_team=""
  local -a positional=() styles=() enable_hooks=()

  while (($#)); do
    case "$1" in
      config | reconcile | mention | feature)
        if [[ -z "${command}" ]]; then command="$1"; else positional+=("$1"); fi
        ;;
      --dry-run) dry_run=true ;;
      --json) json=true ;;
      --verbose) verbose=true ;;
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
      --enable-hook)
        # The operator's explicit release of a held lifecycle event (003 FR-007,
        # FR-029). Repeatable. It exists because `specify extension add` rewrites
        # `enabled: true` unconditionally, so the extension cannot tell an
        # operator's re-enable from the install's — and guessing would silently
        # discard a deliberate choice (research R5). One explicit flag, named in
        # the ceremony's own report, is the honest mechanism.
        if [[ $# -lt 2 ]]; then
          error="--enable-hook requires a lifecycle event (--enable-hook <event>)"
        else
          shift
          enable_hooks+=("$1")
        fi
        ;;
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

  local args_joined styles_joined enable_hooks_joined
  args_joined="$(
    IFS=' '
    printf '%s' "${positional[*]}"
  )"
  styles_joined="$(
    IFS=' '
    printf '%s' "${styles[*]-}"
  )"
  enable_hooks_joined="$(
    IFS=' '
    printf '%s' "${enable_hooks[*]-}"
  )"

  printf 'command=%s\n' "${command}"
  printf 'dry_run=%s\n' "${dry_run}"
  printf 'json=%s\n' "${json}"
  printf 'on_drift=%s\n' "${on_drift}"
  printf 'verbose=%s\n' "${verbose}"
  printf 'help=%s\n' "${help}"
  printf 'styles=%s\n' "${styles_joined}"
  printf 'use_team=%s\n' "${use_team}"
  printf 'enable_hooks=%s\n' "${enable_hooks_joined}"
  printf 'args=%s\n' "${args_joined}"
  printf 'exit=%s\n' "${EXIT_OK}"
}
