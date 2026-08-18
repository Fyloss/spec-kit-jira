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
  cat > "${STUBDIR}/seed.sh" << 'EOF'
cmd_seed() { echo "seed-ran"; return 0; }
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

# T005 (027) — `seed` is a recognised command word, routed exactly like
# every other command.
@test "routes seed to its cmd_seed entry" {
  run bash "${ENTRY}" seed
  [ "$status" -eq 0 ]
  [[ "$output" == *"seed-ran"* ]]
}

# =============================================================================
# T028 [030] — every command dispatch entry calls the resolution chokepoint
# (contracts/connection-settings.md C1.5). Enumerated from the dispatch
# table's own commands directory, not hand-listed — a command file added
# later is picked up automatically, and a missed one fails this test rather
# than working only when the operator also exported the variable.
# =============================================================================

@test "T028 — every file in scripts/bash/commands/ calls config_resolve_connection" {
  local dir="${ROOT}/scripts/bash/commands"
  local f missing=""
  for f in "${dir}"/*.sh; do
    grep -q 'config_resolve_connection' "${f}" || missing="${missing}${missing:+, }$(basename "${f}")"
  done
  [ -z "${missing}" ] || {
    printf 'missing the chokepoint call: %s\n' "${missing}" >&2
    false
  }
}

@test "T028 — the dispatch table has exactly the five entry points this assertion covers" {
  # A sixth command file added later without updating this count is a signal
  # to re-examine the enumeration, not a silent pass.
  local dir="${ROOT}/scripts/bash/commands"
  local n
  n="$(find "${dir}" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')"
  [ "${n}" -eq 5 ]
}
