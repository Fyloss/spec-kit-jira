#!/usr/bin/env bats
# T019/T023 [027] — `--parent`, `--story`, `--confirm` CLI flags
# (contracts/seed-cli-contract.md §2).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/cli.sh"
}

@test "--parent and --story accumulate into \\x1f-joined streams" {
  run cli_parse seed --parent PROJ-1 --story PROJ-11 --story PROJ-12
  [[ "$output" == *"parent_seen=true"* ]]
  [[ "$output" == *"parent=PROJ-1"* ]]
  [[ "$output" == *$'stories=PROJ-11\x1fPROJ-12'* ]]
  [[ "$output" == *"exit=0"* ]]
}

@test "a free-text parent containing spaces survives intact" {
  run cli_parse seed --parent "Payment webhooks rollout" --story PROJ-11
  [[ "$output" == *"parent=Payment webhooks rollout"* ]]
}

@test "--story order is preserved exactly as typed" {
  run cli_parse seed --story PROJ-3 --story PROJ-1 --story PROJ-2
  [[ "$output" == *$'stories=PROJ-3\x1fPROJ-1\x1fPROJ-2'* ]]
}

@test "--confirm is a bare flag" {
  run cli_parse seed --confirm
  [[ "$output" == *"confirm=true"* ]]
}

@test "confirm defaults to false" {
  run cli_parse seed
  [[ "$output" == *"confirm=false"* ]]
}

@test "--parent requires a value" {
  run cli_parse seed --parent
  [[ "$output" == *"exit=1"* ]]
}

# --- T023 (D8 at CLI level, FR-055) ------------------------------------------

@test "a blank --parent value is recorded as parent_seen=true with an empty value" {
  run cli_parse seed --parent "" --story PROJ-11
  [[ "$output" == *"parent_seen=true"* ]]
  [[ "$output" == *$'\nparent=\n'* ]]
}

@test "an absent --parent flag is recorded as parent_seen=false" {
  run cli_parse seed --story PROJ-11
  [[ "$output" == *"parent_seen=false"* ]]
}

# --- §2 cardinality: --parent is "at most once" ------------------------------
# A second --parent silently overwriting the first changes which parent is
# adopted or CREATED — an irreversible write (US2) — from a typo the operator
# never sees. The contract's own cardinality column is the rule; the parser
# only cited it in a comment until now.

@test "a second --parent is a usage error, never a silent overwrite" {
  run cli_parse seed --parent PROJ-1 --parent PROJ-2 --story PROJ-11
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"at most once"* ]]
  [[ "$output" != *"parent=PROJ-2"* ]]
}

@test "a second --parent is refused even when the first value was blank (FR-055)" {
  run cli_parse seed --parent "" --parent PROJ-2
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"at most once"* ]]
}
