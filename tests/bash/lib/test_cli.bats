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

@test "parse output is byte-identical across ports" {
  args="reconcile --dry-run --json --on-drift=proceed --verbose"
  bash_out="$(cli_parse $args)"
  # shellcheck disable=SC2086
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Cli.psm1' -Force; [Console]::Out.Write((Invoke-JiraCliParse @('reconcile','--dry-run','--json','--on-drift=proceed','--verbose')))")"
  [ "$bash_out" = "$ps_out" ]
}
