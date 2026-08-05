#!/usr/bin/env bats
# T008/T009 [018, Phase 2] — the blocking-inventory contract guard, per
# contracts/blocking-inventory.md B1-B5. Branch protection's required-check
# list lives outside this repository and cannot be read from it, so this
# table is a contract, not a convention: a job this repository renames
# silently stops being required, and nothing else would catch it.
#
# A failure here means the CONTRACT TABLE below is wrong relative to the
# workflow files, not that a workflow needs changing — this feature makes no
# job-topology change (D1/FR-002), so the guard is written directly against
# today's `.github/workflows/*.yml`, which already satisfies it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  WORKFLOWS_DIR="${ROOT}/.github/workflows"
  CI_YML="${WORKFLOWS_DIR}/ci.yml"
  GATES_YML="${WORKFLOWS_DIR}/gates.yml"
  BOUNDARY_YML="${WORKFLOWS_DIR}/boundary.yml"
}

# --- B1: nine job definitions, eleven check-run names, byte-identical -------

@test "B1: ci.yml carries exactly the frozen job ids and check-run names" {
  run grep -n '^  unit:' "${CI_YML}"; [ "$status" -eq 0 ]
  run grep -n 'name: Unit suites (\${{ matrix.os }})' "${CI_YML}"; [ "$status" -eq 0 ]
  run grep -n 'ubuntu-latest, macos-latest, windows-latest' "${CI_YML}"; [ "$status" -eq 0 ]

  run grep -n '^  lint:' "${CI_YML}"; [ "$status" -eq 0 ]
  run grep -n 'name: Lint (shellcheck, PSScriptAnalyzer)' "${CI_YML}"; [ "$status" -eq 0 ]

  run grep -n '^  static-checks:' "${CI_YML}"; [ "$status" -eq 0 ]
  run grep -n 'name: Static checks (manifest, messages, registry writes)' "${CI_YML}"; [ "$status" -eq 0 ]
}

@test "B1: gates.yml carries exactly the frozen job ids and check-run names" {
  run grep -n '^  changes:' "${GATES_YML}"; [ "$status" -eq 0 ]
  run grep -n 'name: Detect Bash-relevant changes' "${GATES_YML}"; [ "$status" -eq 0 ]

  run grep -n '^  coverage-bash:' "${GATES_YML}"; [ "$status" -eq 0 ]
  run grep -n 'name: Bash coverage >= 80% (kcov primary, traceability fallback)' "${GATES_YML}"; [ "$status" -eq 0 ]

  run grep -n '^  coverage-pwsh:' "${GATES_YML}"; [ "$status" -eq 0 ]
  run grep -n 'name: PowerShell coverage >= 80% (Pester)' "${GATES_YML}"; [ "$status" -eq 0 ]

  run grep -n '^  module-parity:' "${GATES_YML}"; [ "$status" -eq 0 ]
  run grep -n 'name: Twin ports mirror module-for-module' "${GATES_YML}"; [ "$status" -eq 0 ]

  run grep -n '^  version-string:' "${GATES_YML}"; [ "$status" -eq 0 ]
  run grep -n 'name: Version literal single-sourced (SC-006, FR-021/022)' "${GATES_YML}"; [ "$status" -eq 0 ]
}

@test "B1: boundary.yml carries exactly the frozen job id and check-run name" {
  run grep -n '^  engine-sink-boundary:' "${BOUNDARY_YML}"; [ "$status" -eq 0 ]
  run grep -n 'name: engine/ carries zero Jira knowledge' "${BOUNDARY_YML}"; [ "$status" -eq 0 ]
}

@test "B1: exactly nine job definitions exist across the three blocking workflows" {
  count=0
  for job in 'unit:' 'lint:' 'static-checks:'; do
    run grep -c "^  ${job}" "${CI_YML}"
    count=$((count + output))
  done
  for job in 'changes:' 'coverage-bash:' 'coverage-pwsh:' 'module-parity:' 'version-string:'; do
    run grep -c "^  ${job}" "${GATES_YML}"
    count=$((count + output))
  done
  run grep -c '^  engine-sink-boundary:' "${BOUNDARY_YML}"
  count=$((count + output))
  [ "${count}" -eq 9 ]
}

# --- B3: no third workflow acquires an unscoped pull_request or a push on main

@test "B3: only ci.yml, gates.yml and boundary.yml carry an unscoped pull_request trigger" {
  # "Unscoped" = a bare `pull_request:` with no `types:` restriction directly
  # beneath it. live.yml's pull_request is types:[labeled] — scoped, and
  # exempted by name below rather than by this pattern, so a future widening
  # of live.yml's own trigger is still caught.
  offenders=""
  for f in "${WORKFLOWS_DIR}"/*.yml; do
    base="$(basename "${f}")"
    case "${base}" in
      ci.yml | gates.yml | boundary.yml) continue ;;
    esac
    if awk '/^  pull_request:$/ { getline; if ($0 !~ /^    types:/) { found = 1 } } END { exit !found }' "${f}"; then
      offenders="${offenders}${base} "
    fi
  done
  [ -z "${offenders}" ] || { printf 'unscoped pull_request trigger in: %s\n' "${offenders}"; false; }
}

@test "B3: only ci.yml, gates.yml, boundary.yml and live.yml push on the default branch" {
  offenders=""
  for f in "${WORKFLOWS_DIR}"/*.yml; do
    base="$(basename "${f}")"
    case "${base}" in
      ci.yml | gates.yml | boundary.yml | live.yml) continue ;;
    esac
    if awk '/^  push:$/ { getline; if ($0 ~ /branches:.*\[main\]/ || $0 ~ /branches:.*main/) { found = 1 } } END { exit !found }' "${f}"; then
      offenders="${offenders}${base} "
    fi
  done
  [ -z "${offenders}" ] || { printf 'push-on-main trigger in: %s\n' "${offenders}"; false; }
}

@test "B3: the two named exemptions are exactly live.yml and windows-conformance.yml" {
  # live.yml: push:[main] (Constitution XII) — named exemption, not absolute.
  run grep -n 'branches: \[main\]' "${WORKFLOWS_DIR}/live.yml"
  [ "$status" -eq 0 ]
  # windows-conformance.yml: push on a throwaway probe branch, never main.
  run grep -n 'branches: \[ci/windows-probe\]' "${WORKFLOWS_DIR}/windows-conformance.yml"
  [ "$status" -eq 0 ]
  run grep -n 'branches: \[main\]' "${WORKFLOWS_DIR}/windows-conformance.yml"
  [ "$status" -ne 0 ]
}

# --- B4: work off the blocking gate lands in schedule+workflow_dispatch only -

@test "B4: bash-suite-stability.yml is schedule + workflow_dispatch only" {
  run grep -n '^  schedule:' "${WORKFLOWS_DIR}/bash-suite-stability.yml"
  [ "$status" -eq 0 ]
  run grep -n '^  workflow_dispatch:' "${WORKFLOWS_DIR}/bash-suite-stability.yml"
  [ "$status" -eq 0 ]
  run grep -n '^  push:' "${WORKFLOWS_DIR}/bash-suite-stability.yml"
  [ "$status" -ne 0 ]
  run grep -n '^  pull_request' "${WORKFLOWS_DIR}/bash-suite-stability.yml"
  [ "$status" -ne 0 ]
}
