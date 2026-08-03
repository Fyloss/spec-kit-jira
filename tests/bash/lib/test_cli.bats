#!/usr/bin/env bats
# T014 — CLI arg-parsing + exit-code table (contracts/cli-contract.md).
# Flags: --dry-run/--json/--on-drift/--verbose/--help/--repair-hooks.
# Codes: 0/1/2/3/4/5/9. Parse emits machine-readable key=value lines (FR-002).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  PS_LIB="${ROOT}/scripts/powershell/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/cli.sh"
}

@test "exit-code table is exactly 0/1/2/3/4/5/9" {
  [ "$(cli_exit_code ok)" = "0" ]
  [ "$(cli_exit_code usage)" = "1" ]
  [ "$(cli_exit_code fail_closed)" = "2" ]
  [ "$(cli_exit_code auth)" = "3" ]
  [ "$(cli_exit_code config)" = "4" ]
  [ "$(cli_exit_code prereq)" = "5" ]
  [ "$(cli_exit_code block)" = "9" ]
}

@test "parse a bare command with defaults" {
  run cli_parse config
  [[ "$output" == *"command=config"* ]]
  [[ "$output" == *"dry_run=false"* ]]
  [[ "$output" == *"on_drift=abort"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "parse --dry-run and --json" {
  run cli_parse reconcile --dry-run --json
  [[ "$output" == *"dry_run=true"* ]]
  [[ "$output" == *"json=true"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "parse --on-drift=proceed" {
  run cli_parse reconcile --on-drift=proceed
  [[ "$output" == *"on_drift=proceed"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "invalid --on-drift value is a usage error (exit=1)" {
  run cli_parse reconcile --on-drift=bogus
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"error="* ]]
}

@test "unknown flag is a usage error (exit=1)" {
  run cli_parse reconcile --nope
  [[ "$output" == *"exit=1"* ]]
}

@test "--help sets help and exits 0" {
  run cli_parse --help
  [[ "$output" == *"help=true"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "mention carries its issue-key argument" {
  run cli_parse mention PROJ-123
  [[ "$output" == *"command=mention"* ]]
  [[ "$output" == *"args=PROJ-123"* ]]
}

@test "--repair-hooks is REJECTED as an unknown flag (003 T073, FR-022)" {
  # The flag existed only to perform a registry write FR-022 now forbids. It is
  # removed rather than kept as a no-op: a flag named "repair" that no longer
  # repairs anything would be worse than none (Principle XV, XVI). Rejecting it
  # loudly also tells an operator with it in a script exactly what happened.
  run cli_parse config --repair-hooks
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"unknown flag: --repair-hooks"* ]]
  [[ "$output" != *"repair_hooks="* ]]
}

@test "T077 — parse --issue-type KEY=role=name" {
  run cli_parse config --issue-type CONSUMER=specification=Epic
  [[ "$output" == *"issue_types=CONSUMER=specification=Epic"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "T077 — --issue-type is repeatable and last occurrence per (KEY, role) wins" {
  run cli_parse config --issue-type CONSUMER=specification=Epic --issue-type CONSUMER=story=Story --issue-type CONSUMER=specification=Initiative
  local list; list="$(sed -n 's/^issue_types=//p' <<< "$output")"
  [ "$list" = "CONSUMER=specification=Epic CONSUMER=story=Story CONSUMER=specification=Initiative" ]
  # last-occurrence-wins is config.sh's job over this ordered list; cli_parse's
  # contract is only to preserve argv order, which config.sh then folds.
}

@test "T077 — a malformed --issue-type value is a usage error (exit=1), not a configuration error" {
  run cli_parse config --issue-type CONSUMER=nope=Epic
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"error="* ]]
}

@test "T077 — --issue-type requires a role from the closed set" {
  run cli_parse config --issue-type CONSUMER=Epic
  [[ "$output" == *"exit=1"* ]]
}

@test "T077 — --child-type KEY=name still parses as the story alias" {
  run cli_parse config --child-type CONSUMER=Story
  [[ "$output" == *"child_types=CONSUMER=Story"* ]]
  [[ "$output" == *"issue_types=CONSUMER=story=Story"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "parse output is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  args="reconcile --dry-run --json --on-drift=proceed --verbose"
  bash_out="$(cli_parse $args)"
  # shellcheck disable=SC2086
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Cli.psm1' -Force; [Console]::Out.Write((Invoke-JiraCliParse @('reconcile','--dry-run','--json','--on-drift=proceed','--verbose')))")"
  [ "$bash_out" = "$ps_out" ]
}

@test "T017 [011] — parse --field-default KEY=Type=Label=Value" {
  run cli_parse config --field-default CONSUMER=Epic=Business=Platform
  [[ "$output" == *"field_defaults=CONSUMER=Epic=Business=Platform"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "T017 [011] — --field-default is repeatable, argv order preserved, joined with \\x1f (not a space, so a spaced value cannot swallow the next entry)" {
  run cli_parse config --field-default CONSUMER=Epic=Owner=A --field-default CONSUMER=Story=Team=B
  local list; list="$(sed -n 's/^field_defaults=//p' <<< "$output")"
  [ "$list" = "$(printf 'CONSUMER=Epic=Owner=A\x1fCONSUMER=Story=Team=B')" ]
}

@test "T017 [011] — --field-default's value may itself contain '=' (split on the first three separators only)" {
  run cli_parse config --field-default 'CONSUMER=Epic=Owner=a=b=c'
  [[ "$output" == *"field_defaults=CONSUMER=Epic=Owner=a=b=c"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "T017 [011] — --field-default's value may contain spaces" {
  run cli_parse config --field-default 'CONSUMER=Epic=Business Owner=Platform Team'
  [[ "$output" == *"field_defaults=CONSUMER=Epic=Business Owner=Platform Team"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "T017 [011] — a malformed --field-default value (missing a segment) is a usage error, same message shape as --issue-type" {
  run cli_parse config --field-default CONSUMER=Epic
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"invalid --field-default value"* ]]
}

@test "T017 [011] — --field-default requires a value" {
  run cli_parse config --field-default
  [[ "$output" == *"exit=1"* ]]
}

@test "T017 [011] — parse --field-value KEY=Type=Label=Value, repeatable, same shape as --field-default" {
  run cli_parse reconcile --field-value CONSUMER=Epic=Owner=A --field-value CONSUMER=Story=Team=B
  local list; list="$(sed -n 's/^field_values=//p' <<< "$output")"
  [ "$list" = "$(printf 'CONSUMER=Epic=Owner=A\x1fCONSUMER=Story=Team=B')" ]
  [[ "$output" == *"exit=0"* ]]
}

@test "T017 [011] — two --field-default values that each contain a space are still separable (the \\x1f join, not a space, is the boundary)" {
  run cli_parse config --field-default 'CONSUMER=Epic=Business Owner=Platform Team' --field-default 'CONSUMER=Story=Team=Payments'
  local list; list="$(sed -n 's/^field_defaults=//p' <<< "$output")"
  [ "$list" = "$(printf 'CONSUMER=Epic=Business Owner=Platform Team\x1fCONSUMER=Story=Team=Payments')" ]
}

@test "T017 [011] — the field_defaults line is byte-identical across ports for two spaced, repeated values" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash_out="$(cli_parse config --field-default 'CONSUMER=Epic=Business Owner=Platform Team' --field-default 'CONSUMER=Story=Team=Payments')"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Cli.psm1' -Force; [Console]::Out.Write((Invoke-JiraCliParse @('config','--field-default','CONSUMER=Epic=Business Owner=Platform Team','--field-default','CONSUMER=Story=Team=Payments')))")"
  [ "$bash_out" = "$ps_out" ]
}

@test "T017 [011] — a malformed --field-value value is a usage error" {
  run cli_parse reconcile --field-value CONSUMER=Epic
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"invalid --field-value value"* ]]
}

@test "T017 [011] — --accept-defaults is a boolean flag" {
  run cli_parse reconcile --accept-defaults
  [[ "$output" == *"accept_defaults=true"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "T017 [011] — --accept-defaults defaults to false" {
  run cli_parse reconcile
  [[ "$output" == *"accept_defaults=false"* ]]
}
