#!/usr/bin/env bats
# T024 — Entry-point dispatcher (Bash port).
# Prerequisites gate every path (NFR-4): no command runs until they pass. Then
# the CLI is parsed and the selected command routed to its cmd_<name> entry.
# Command modules are stubbed here via SPEC_KIT_JIRA_COMMANDS_DIR so the
# dispatcher is testable before the real commands (US1/US3/US10) land.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENTRY="${ROOT}/scripts/bash/spec-kit-jira.sh"
  STUBDIR="$(mktemp -d)"
  cat > "${STUBDIR}/config.sh" << 'EOF'
cmd_config() { echo "config-ran args=$*"; return 0; }
EOF
  cat > "${STUBDIR}/reconcile.sh" << 'EOF'
cmd_reconcile() { echo "reconcile-ran"; return 0; }
EOF
  cat > "${STUBDIR}/adopt.sh" << 'EOF'
cmd_adopt() { echo "adopt-ran args=$*"; return 0; }
EOF
  export SPEC_KIT_JIRA_COMMANDS_DIR="${STUBDIR}"
}

teardown() {
  rm -rf "${STUBDIR}"
}

@test "prerequisite failure exits 5 before any command runs (NFR-4)" {
  run env _PREREQ_FORCE_MISSING="jq" bash "${ENTRY}" config
  [ "$status" -eq 5 ]
  [[ "$output" != *"config-ran"* ]]
}

@test "--help exits 0 and prints usage to stdout" {
  run bash "${ENTRY}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: spec-kit-jira"* ]]
}

@test "no command is a usage error (exit 1)" {
  run bash "${ENTRY}"
  [ "$status" -eq 1 ]
}

@test "an unknown flag is a usage error (exit 1)" {
  run bash "${ENTRY}" --bogus
  [ "$status" -eq 1 ]
}

@test "an unrecognised command is a usage error (exit 1)" {
  run bash "${ENTRY}" frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" != *"-ran"* ]]
}

@test "routes config to its cmd_config entry, passing options through" {
  run bash "${ENTRY}" config --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"config-ran"* ]]
}

@test "routes reconcile to its cmd_reconcile entry" {
  run bash "${ENTRY}" reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconcile-ran"* ]]
}

@test "a routed but unbuilt command is a usage error (exit 1)" {
  run bash "${ENTRY}" mention
  [ "$status" -eq 1 ]
}

# --- adopt (003 T011) --------------------------------------------------------

@test "the usage block lists adopt (003 T011)" {
  run bash "${ENTRY}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"<config|reconcile|mention|feature|adopt>"* ]]
}

@test "the a-command-is-required message lists adopt (003 T011)" {
  run bash "${ENTRY}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(config|reconcile|mention|feature|adopt)"* ]]
}

@test "routes adopt to its cmd_adopt entry, passing options through (003 T011)" {
  run bash "${ENTRY}" adopt --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"adopt-ran"* ]]
  [[ "$output" == *"--yes"* ]]
}

@test "adopt --on-drift is a usage error at the dispatcher (003 T011)" {
  run bash "${ENTRY}" adopt --on-drift=proceed
  [ "$status" -eq 1 ]
  [[ "$output" != *"adopt-ran"* ]]
}
