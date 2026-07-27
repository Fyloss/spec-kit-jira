#!/usr/bin/env bats
# Coverage-runner guard: the `bash-coverage` CI job hit the runner's 20-minute
# wall with no report and no diagnostics. Three structural defects made that
# outcome both possible and unreadable, and each is pinned here.
#
#   1. kcov collects the trace by swapping the traced program's fd 2. Every
#      exercise phase ran under `> /dev/null 2>&1`, which points fd 2 at
#      /dev/null and silently discards every traced line — the run could only
#      ever have reported "no coverage produced".
#   2. Nothing bounded the kcov run or the scenarios it drives, so a single
#      stuck child consumed the whole step budget and GitHub killed the job
#      before the script could say where it stalled.
#   3. An aborted scenario left its pwsh mock running, and a surviving child
#      holds the tracer's pipe open, so kcov never sees EOF.
#
# These are file-shape assertions on purpose: the failure they guard against
# only reproduces on a Linux host with kcov installed, which is exactly the
# environment this suite cannot assume.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  COVERAGE="${ROOT}/tests/coverage/bash-coverage.sh"
  HARNESS="${ROOT}/tests/conformance/run-scenario.sh"
  MOCK_LIB="${ROOT}/tests/conformance/mock-jira/lib.sh"
}

# The code that runs INSIDE kcov, where fd 2 belongs to the tracer. Comments are
# dropped: this section documents the very redirections it must not perform.
exercise_section() {
  awk '/^# --- Exercise mode/ { on = 1 } /^# --- Drive mode/ { on = 0 }
       on && $0 !~ /^[[:space:]]*#/' "${COVERAGE}"
}

@test "the guard reads a non-empty exercise section" {
  run exercise_section
  [ "$status" -eq 0 ]
  [ -n "${output}" ]
}

@test "no exercise phase redirects fd 2 — that is the tracer's channel" {
  offenders="$(exercise_section | grep -n '2>' || true)"
  [ -z "${offenders}" ] || {
    printf 'fd 2 is redirected inside the exercise section:\n%s\n' "${offenders}"
    false
  }
}

@test "every exercised entry point reads stdin from /dev/null" {
  # Only the entry points matter: a library sourced inside a phase inherits the
  # stdin that phase already pinned.
  unguarded="$(exercise_section \
    | grep -E 'source "\$\{(HARNESS|entry)\}' \
    | grep -v '< /dev/null' || true)"
  [ -z "${unguarded}" ] || {
    printf 'these sourced entry points can block on stdin:\n%s\n' "${unguarded}"
    false
  }
}

@test "the kcov run is wall-clock bounded" {
  run grep -Eq '^[[:space:]]*(run_bounded|timeout)[^|]*kcov' "${COVERAGE}"
  [ "$status" -eq 0 ]
}

@test "the wall-clock bound is overridable and has a default" {
  run grep -q 'SPEC_KIT_JIRA_COVERAGE_TIMEOUT' "${COVERAGE}"
  [ "$status" -eq 0 ]
}

@test "the exercise records progress somewhere the drive side can read" {
  run grep -q 'PROGRESS' "${COVERAGE}"
  [ "$status" -eq 0 ]
}

@test "the harness stops the mock on any exit path" {
  run grep -Eq '^[[:space:]]*trap .*mock_stop.* EXIT' "${HARNESS}"
  [ "$status" -eq 0 ]
}

@test "the mock never inherits the caller's stdio" {
  launch="$(grep -n 'pwsh "\${args\[@\]}"' "${MOCK_LIB}")"
  [ -n "${launch}" ]
  [[ "${launch}" == *"< /dev/null"* ]]
  [[ "${launch}" == *"> "* ]]
  [[ "${launch}" == *"2> "* ]]
}
