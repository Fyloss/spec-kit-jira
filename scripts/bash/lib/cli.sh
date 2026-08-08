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

# _cli_field_flag_parts <value> — split a `--field-default`/`--field-value`
# argument on the FIRST THREE `=` separators only (011, T017/T019): the value
# (fourth segment) may itself contain `=` or whitespace, and is never split
# further. Prints "pkey<TAB>itype<TAB>label<TAB>value" and returns 0 when the
# shape is well-formed (a valid project key, and a non-empty type and label);
# prints nothing and returns 1 otherwise. Content validity — an empty VALUE,
# one outside allowed_values, an unknown type or label — is the ceremony's
# job at record time (contract §2.4), not this shape check's.
_cli_field_flag_parts() {
  local rest="$1" pkey itype label value
  [[ "${rest}" != *"="* ]] && return 1
  pkey="${rest%%=*}"; rest="${rest#*=}"
  [[ "${rest}" != *"="* ]] && return 1
  itype="${rest%%=*}"; rest="${rest#*=}"
  [[ "${rest}" != *"="* ]] && return 1
  label="${rest%%=*}"; rest="${rest#*=}"
  value="${rest}"
  [[ -z "${pkey}" || -z "${itype}" || -z "${label}" ]] && return 1
  [[ "${pkey}" =~ ^[A-Z][A-Z0-9_]+$ ]] || return 1
  printf '%s\t%s\t%s\t%s' "${pkey}" "${itype}" "${label}" "${value}"
}

# cli_field_answers_for <project-key> <field-flags-string> — one project's
# --field-default/--field-value answers for this run (011, contract §2.4/
# §3.5), reduced to `[{type, label, value}]` in argv order. `field_flags` is
# cli_parse's \x1f-joined field_defaults/field_values stream (NOT
# space-joined like every other repeatable flag — a field VALUE may itself
# contain spaces). Shared by the config ceremony and the reconcile command,
# so a malformed token is parsed identically wherever it is answered.
cli_field_answers_for() {
  local key="$1" field_flags="$2" tok parts pkey itype label value out='[]'
  while IFS=$'\x1f' read -r -d $'\x1f' tok || [[ -n "${tok}" ]]; do
    [[ -z "${tok}" ]] && continue
    parts="$(_cli_field_flag_parts "${tok}")" || continue
    IFS=$'\t' read -r pkey itype label value <<< "${parts}"
    [[ "${pkey}" == "${key}" ]] || continue
    out="$(jq -c --arg t "${itype}" --arg l "${label}" --arg v "${value}" '. + [{type: $t, label: $l, value: $v}]' <<< "${out}")"
  done <<< "${field_flags}$(printf '\x1f')"
  printf '%s' "${out}"
}

# cli_parse <args...> — parse the command line; print key=value state lines.
cli_parse() {
  local command="" dry_run=false force=false json=false on_drift=abort
  local verbose=false help=false error="" use_team="" accept_defaults=false
  local -a positional=() styles=() enable_hooks=() child_types=() issue_types=()
  local -a field_defaults=() field_values=()

  while (($#)); do
    case "$1" in
      config | reconcile | mention | feature)
        if [[ -z "${command}" ]]; then command="$1"; else positional+=("$1"); fi
        ;;
      --dry-run) dry_run=true ;;
      --force) force=true ;;
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
      --child-type)
        # Repeatable operator answer to the child-type closed question (008
        # T044, research R1/R2): --child-type KEY=<logical name>, asked only
        # when the child hierarchy level holds several candidates. The
        # logical name is opaque text (Constitution VII) — no shape beyond
        # "non-empty" is enforced here. Kept as the accepted alias for
        # --issue-type KEY=story=<name> (010, contract §2.2, research R2) so
        # no existing invocation, script or runbook breaks.
        if [[ $# -lt 2 ]]; then
          error="--child-type requires a value (--child-type KEY=<logical name>)"
        else
          shift
          if [[ "$1" =~ ^[A-Z][A-Z0-9_]+=[^[:space:]]+$ ]]; then
            child_types+=("$1")
            issue_types+=("${1%%=*}=story=${1#*=}")
          else
            error="invalid --child-type value: $1 (expected <PROJECT_KEY>=<logical name>, no whitespace)"
          fi
        fi
        ;;
      --issue-type)
        # Repeatable operator answer to the closed role question (010,
        # contract §2.2): --issue-type KEY=role=<logical name>, last
        # occurrence per (KEY, role) wins. <role> is the closed set
        # specification|story|task; the name itself is opaque text
        # (Constitution VII) — no shape beyond "non-empty" is enforced here.
        if [[ $# -lt 2 ]]; then
          error="--issue-type requires a value (--issue-type KEY=role=<logical name>)"
        else
          shift
          if [[ "$1" =~ ^[A-Z][A-Z0-9_]+=(specification|story|task)=[^[:space:]]+$ ]]; then
            issue_types+=("$1")
          else
            error="invalid --issue-type value: $1 (expected <PROJECT_KEY>=<specification|story|task>=<logical name>, no whitespace)"
          fi
        fi
        ;;
      --field-default)
        # The recording flag of FR-006/contract §2.4: repeatable
        # <PROJECT_KEY>=<Type>=<Label>=<Value>, validated the same way
        # --issue-type is — a malformed shape is a usage error here; an
        # empty/disallowed VALUE is the ceremony's content refusal (§2.4),
        # not this one's.
        if [[ $# -lt 2 ]]; then
          error="--field-default requires a value (--field-default KEY=Type=Label=Value)"
        else
          shift
          if _cli_field_flag_parts "$1" > /dev/null; then
            field_defaults+=("$1")
          else
            error="invalid --field-default value: $1 (expected <PROJECT_KEY>=<Type>=<Label>=<Value>)"
          fi
        fi
        ;;
      --field-value)
        # The per-run answer of FR-012/contract §3.5 — same shape, same
        # validation, applied for this run only rather than persisted.
        if [[ $# -lt 2 ]]; then
          error="--field-value requires a value (--field-value KEY=Type=Label=Value)"
        else
          shift
          if _cli_field_flag_parts "$1" > /dev/null; then
            field_values+=("$1")
          else
            error="invalid --field-value value: $1 (expected <PROJECT_KEY>=<Type>=<Label>=<Value>)"
          fi
        fi
        ;;
      --accept-defaults)
        # Contract §3.3/§3.10 — proceed with the recorded defaults, asking no
        # consolidated question this run.
        accept_defaults=true
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

  local args_joined styles_joined enable_hooks_joined child_types_joined issue_types_joined
  local field_defaults_joined field_values_joined
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
  child_types_joined="$(
    IFS=' '
    printf '%s' "${child_types[*]-}"
  )"
  issue_types_joined="$(
    IFS=' '
    printf '%s' "${issue_types[*]-}"
  )"
  # Joined with ASCII Unit Separator (\x1f), not a space: a --field-default/
  # --field-value VALUE may itself contain spaces (011, T017), so the
  # space-joined scheme every other repeatable flag uses here would let one
  # entry's value swallow the next entry's KEY=Type=Label on a downstream
  # `for tok in ${field_defaults}` word-split. \x1f cannot appear in an
  # operator-typed argv token, so it is a safe token boundary.
  field_defaults_joined="$(
    IFS=$'\x1f'
    printf '%s' "${field_defaults[*]-}"
  )"
  field_values_joined="$(
    IFS=$'\x1f'
    printf '%s' "${field_values[*]-}"
  )"

  printf 'command=%s\n' "${command}"
  printf 'dry_run=%s\n' "${dry_run}"
  printf 'force=%s\n' "${force}"
  printf 'json=%s\n' "${json}"
  printf 'on_drift=%s\n' "${on_drift}"
  printf 'verbose=%s\n' "${verbose}"
  printf 'help=%s\n' "${help}"
  printf 'styles=%s\n' "${styles_joined}"
  printf 'child_types=%s\n' "${child_types_joined}"
  printf 'issue_types=%s\n' "${issue_types_joined}"
  printf 'use_team=%s\n' "${use_team}"
  printf 'enable_hooks=%s\n' "${enable_hooks_joined}"
  printf 'field_defaults=%s\n' "${field_defaults_joined}"
  printf 'field_values=%s\n' "${field_values_joined}"
  printf 'accept_defaults=%s\n' "${accept_defaults}"
  printf 'args=%s\n' "${args_joined}"
  printf 'exit=%s\n' "${EXIT_OK}"
}
