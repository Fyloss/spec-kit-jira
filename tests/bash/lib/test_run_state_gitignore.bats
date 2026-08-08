#!/usr/bin/env bats
# T025 [Phase 4, US2] — contracts/run-state.md §6/FR-026: `git status
# --porcelain` stays clean after the state directory is written, even in a
# repository whose root `.gitignore` predates this feature (never mentions
# `.specify/jira/state`), because `run_state_record` writes its own
# self-ignoring `.gitignore` (a bare `*`) before writing the state document.
#
# Tested directly against `run_state_record` (`lib/run_state.sh`, T018),
# which already exists and already writes that self-ignoring `.gitignore` —
# a genuine lock-in test on already-shipped code today, like T024, not a
# forward-looking guard: reconcile.sh not yet calling it does not change
# whether the guarantee under test already holds.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/run_state.sh"

  WORK="$(mktemp -d)"
  git -C "${WORK}" init -q
  # Deliberately predates this feature: no mention of .specify/jira/state.
  printf 'node_modules/\n*.log\n' > "${WORK}/.gitignore"
  mkdir -p "${WORK}/specs/021-example"
  SPEC="${WORK}/specs/021-example/spec.md"
  printf '# Feature Specification: Example\n' > "${SPEC}"
  git -C "${WORK}" add -A
  git -C "${WORK}" -c user.name="Test" -c user.email="test@example.com" commit -q -m "initial"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
}

teardown() {
  rm -rf "${WORK}"
}

@test "T025 — git status --porcelain stays clean after the state directory is written" {
  [ -z "$(git -C "${WORK}" status --porcelain)" ]

  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""

  [ -f "${WORK}/.specify/jira/state/.gitignore" ]
  [ -f "${WORK}/.specify/jira/state/021-example.json" ]
  [ -z "$(git -C "${WORK}" status --porcelain)" ]
}
