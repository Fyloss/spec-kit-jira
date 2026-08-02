#!/usr/bin/env bats
# T014 [009, US2] — CI-definition guard: ci.yml must invoke the dependency-free
# tests/run-bash.sh for the Bash suite, never `bats --jobs` (which needs GNU
# `parallel` and silently runs 0 tests without it — FR-003). Every blocking
# gate from the pre-change inventory (baseline.md T002) must still exist
# (SC-006/FR-010).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CI_YML="${ROOT}/.github/workflows/ci.yml"
  GATES_YML="${ROOT}/.github/workflows/gates.yml"
  BOUNDARY_YML="${ROOT}/.github/workflows/boundary.yml"
}

@test "ci.yml runs the Bash suite through tests/run-bash.sh, never bats --jobs" {
  run grep -n 'tests/run-bash.sh' "${CI_YML}"
  [ "$status" -eq 0 ]
  run grep -n -- '--jobs' "${CI_YML}"
  [ "$status" -ne 0 ]
}

@test "ci.yml never installs GNU parallel for the Bash run (Decision 3)" {
  run grep -niE '(apt-get|brew) install.*[^a-z]parallel([^a-z]|$)' "${CI_YML}"
  [ "$status" -ne 0 ]
}

@test "ci.yml no longer requires PowerShell for the Bash unit run's own step" {
  # The unit job's Pester step is unaffected; this guards specifically that the
  # run-bash.sh invocation carries no pwsh dependency in its own step body.
  run grep -A2 'tests/run-bash.sh' "${CI_YML}"
  [[ "$output" != *pwsh* ]]
}

@test "every pre-change blocking job still exists (SC-006/FR-010)" {
  for job in 'unit:' 'lint:' 'static-checks:'; do
    run grep -n "^  ${job}" "${CI_YML}"
    [ "$status" -eq 0 ]
  done
  for job in 'changes:' 'coverage-bash:' 'coverage-pwsh:' 'module-parity:' 'version-string:'; do
    run grep -n "^  ${job}" "${GATES_YML}"
    [ "$status" -eq 0 ]
  done
  run grep -n '^  engine-sink-boundary:' "${BOUNDARY_YML}"
  [ "$status" -eq 0 ]
}

@test "the three-OS matrix on the unit job is unchanged" {
  run grep -n 'ubuntu-latest, macos-latest, windows-latest' "${CI_YML}"
  [ "$status" -eq 0 ]
}
