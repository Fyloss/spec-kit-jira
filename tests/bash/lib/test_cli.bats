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

@test "config accepts --repair-hooks" {
  run cli_parse config --repair-hooks
  [[ "$output" == *"repair_hooks=true"* ]]
}

# --- adopt command surface (003 T007) ----------------------------------------

@test "parse accepts the adopt command (003 T007)" {
  run cli_parse adopt
  [[ "$output" == *"command=adopt"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "adopt accepts the boolean --yes flag (003 T007)" {
  run cli_parse adopt --yes
  [[ "$output" == *"command=adopt"* ]]
  [[ "$output" == *"yes=true"* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "--yes defaults to false (003 T007)" {
  run cli_parse adopt
  [[ "$output" == *"yes=false"* ]]
}

@test "adopt rejects --on-drift with a usage error (003 T007, adopt-cli-contract)" {
  run cli_parse adopt --on-drift=proceed
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"error="* ]]
  [[ "$output" == *"--on-drift"* ]]
}

@test "adopt rejects --on-drift declared before the command (003 T007)" {
  run cli_parse --on-drift=abort adopt
  [[ "$output" == *"exit=1"* ]]
}

@test "reconcile still accepts --on-drift (003 T007 regression)" {
  run cli_parse reconcile --on-drift=proceed
  [[ "$output" == *"exit=0"* ]]
  [[ "$output" == *"on_drift=proceed"* ]]
}

# --- --bind (003 T119, US4) --------------------------------------------------

@test "--bind is repeatable and carries every value (003 T119)" {
  run cli_parse adopt --bind 003-a=ADO-1 --bind 004-b:us2=ADO-9
  [[ "$output" == *"exit=0"* ]]
  [[ "$output" == *"binds=003-a=ADO-1 004-b:us2=ADO-9"* ]]
}

@test "--bind defaults to empty (003 T119)" {
  run cli_parse adopt
  [[ "$output" == *"binds="* ]]
  [[ "$output" != *"binds=0"* ]]
}

@test "--bind is validated STRUCTURALLY: non-empty on both sides of = (003 T119)" {
  run cli_parse adopt --bind "=ADO-1"
  [[ "$output" == *"exit=1"* ]]
  run cli_parse adopt --bind "003-a="
  [[ "$output" == *"exit=1"* ]]
  run cli_parse adopt --bind "no-equals-sign"
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"--bind"* ]]
}

@test "--bind without a value is a usage error (003 T119)" {
  run cli_parse adopt --bind
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"requires a value"* ]]
}

@test "the parser applies NO issue-key shape check — that lives in the sink (research §9)" {
  # A structurally valid pin whose key is not key-shaped still parses; the sink
  # is the only layer allowed to know what a key looks like.
  run cli_parse adopt --bind "003-a=not-a-key"
  [[ "$output" == *"exit=0"* ]]
  [[ "$output" == *"binds=003-a=not-a-key"* ]]
}

# --- --spec (003 T153, US6) --------------------------------------------------

@test "--spec is repeatable and carries every value (003 T153)" {
  run cli_parse adopt --spec 003-a --spec 004-b
  [[ "$output" == *"exit=0"* ]]
  [[ "$output" == *"specs=003-a 004-b"* ]]
}

@test "--spec defaults to empty, meaning every folder on disk (003 T153)" {
  run cli_parse adopt
  [[ "$output" == *"specs="* ]]
}

@test "--spec without a value is a usage error (003 T153)" {
  run cli_parse adopt --spec
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"requires a value"* ]]
}

@test "--spec with an empty value is a usage error (003 T153)" {
  run cli_parse adopt --spec ""
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"non-empty"* ]]
}

@test "--bind and --spec combine, in the order given (003 T119, T153)" {
  run cli_parse adopt --spec 003-a --bind 003-a=ADO-1 --spec 004-b --yes
  [[ "$output" == *"exit=0"* ]]
  [[ "$output" == *"specs=003-a 004-b"* ]]
  [[ "$output" == *"binds=003-a=ADO-1"* ]]
  [[ "$output" == *"yes=true"* ]]
}

@test "the full adopt flag surface is byte-identical across ports (003 T119, T153)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local bash_out ps_out
  bash_out="$(cli_parse adopt --spec 003-a --bind 003-a=ADO-1 --bind 004-b:us2=ADO-9 --spec 004-b --yes --json)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Cli.psm1' -Force; [Console]::Out.Write((Invoke-JiraCliParse @('adopt','--spec','003-a','--bind','003-a=ADO-1','--bind','004-b:us2=ADO-9','--spec','004-b','--yes','--json')))")"
  [ "$bash_out" = "$ps_out" ]
}

@test "adopt parse output is byte-identical across ports (003 T007, NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash_out="$(cli_parse adopt --yes --dry-run --json)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Cli.psm1' -Force; [Console]::Out.Write((Invoke-JiraCliParse @('adopt','--yes','--dry-run','--json')))")"
  [ "$bash_out" = "$ps_out" ]
}

@test "parse output is byte-identical across ports" {
  args="reconcile --dry-run --json --on-drift=proceed --verbose"
  bash_out="$(cli_parse $args)"
  # shellcheck disable=SC2086
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Cli.psm1' -Force; [Console]::Out.Write((Invoke-JiraCliParse @('reconcile','--dry-run','--json','--on-drift=proceed','--verbose')))")"
  [ "$bash_out" = "$ps_out" ]
}
