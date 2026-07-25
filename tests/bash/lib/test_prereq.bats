#!/usr/bin/env bats
# T010 — Prerequisite-check tests (NFR-4): Bash >= 4 (macOS 3.2 named), curl/jq/git.
# The check MUST exit 5 before any Jira interaction.

setup() {
  LIB_DIR="${BATS_TEST_DIRNAME}/../../../scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/prereq.sh"
}

@test "prereq_check passes on a fully-provisioned host" {
  run prereq_check
  [ "$status" -eq 0 ]
}

@test "prereq_check exits 5 when Bash major version is below 4" {
  _PREREQ_BASH_MAJOR=3 run prereq_check
  [ "$status" -eq 5 ]
}

@test "prereq_check names macOS 3.2 explicitly on an old Bash" {
  _PREREQ_BASH_MAJOR=3 run prereq_check
  [[ "$output" == *"3.2"* ]]
  [[ "$output" == *"Bash"* ]]
}

@test "prereq_check exits 5 when a required command is missing" {
  _PREREQ_FORCE_MISSING="jq" run prereq_check
  [ "$status" -eq 5 ]
  [[ "$output" == *"jq"* ]]
}

@test "prereq_check reports every missing command, not just the first" {
  _PREREQ_FORCE_MISSING="jq curl" run prereq_check
  [ "$status" -eq 5 ]
  [[ "$output" == *"jq"* ]]
  [[ "$output" == *"curl"* ]]
}
