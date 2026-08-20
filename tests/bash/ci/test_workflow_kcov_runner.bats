#!/usr/bin/env bats
# CI-definition guard: kcov was dropped from the Ubuntu 24.04 (noble) archive, so
# any job that apt-installs it on `ubuntu-latest` dies with
#   E: Unable to locate package kcov
# before a single line of coverage is measured. Jammy (22.04) still ships it in
# universe, so every kcov-installing job must pin a runner image whose archive
# carries the package. A job that builds kcov from source is exempt: the rule
# keys on the apt install line only.

setup() {
  WORKFLOW_DIR="${BATS_TEST_DIRNAME}/../../../.github/workflows"
}

# Emits "<file>:<job>:<runs-on>" for every job whose steps apt-install kcov.
kcov_jobs() {
  awk '
    function flush() {
      if (job != "" && kcov) printf "%s:%s:%s\n", FILENAME, job, runs
    }
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_.-]+: *$/ {
      flush()
      job = $1; sub(/:$/, "", job); runs = "<unset>"; kcov = 0; next
    }
    /^    runs-on:/ { runs = $2; next }
    /apt-get install/ && /kcov/ { kcov = 1 }
    END { flush() }
  ' "$1"
}

# Emits "<timeout-minutes> <kcov-seconds> <bats-seconds>" for the step that drives
# tests/coverage/bash-coverage.sh.
coverage_step_budget() {
  awk '
    /^      - name: Measure statement coverage with kcov$/ { step = 1; next }
    step && /^      - name:/ { step = 0 }
    step && /^        timeout-minutes:/ { tm = $2; next }
    step && /SPEC_KIT_JIRA_COVERAGE_TIMEOUT:/ { kc = $2; next }
    step && /SPEC_KIT_JIRA_COVERAGE_BATS_TIMEOUT:/ { bt = $2; next }
    END { if (tm != "") printf "%s %s %s\n", tm, kc, bt }
  ' "${WORKFLOW_DIR}/gates.yml"
}

# Emits the name of every `run:` step in the coverage-bash job that carries no
# timeout-minutes of its own.
unbounded_coverage_run_steps() {
  awk '
    /^  coverage-bash:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_.-]+: *$/ { in_job = 0 }
    !in_job { next }
    /^      - (name|uses):/ {
      if (name != "" && runs && !bounded) print name
      name = ""; runs = 0; bounded = 0
      if ($2 == "name:" || $1 == "-") { sub(/^      - name: /, ""); name = $0 }
      next
    }
    /^        run:/ { runs = 1; next }
    /^        timeout-minutes:/ { bounded = 1; next }
    END { if (name != "" && runs && !bounded) print name }
  ' "${WORKFLOW_DIR}/gates.yml"
}

@test "every run step in the coverage job is wall-clock bounded" {
  # A step with no ceiling of its own burns until GitHub's 6-hour cap, and this
  # job has no job-level timeout-minutes either. MEASURED 2026-08-19 (run
  # 32274698086): `Install toolchain` — 18 seconds on every previous run — hung
  # in apt for 2 h 38 m and was still going when the run was cancelled, so the
  # coverage step it precedes never started at all. Bounding only the expensive
  # step is not enough: the cheap ones in front of it can take the job down
  # first, and they are the ones nobody thinks to look at.
  run unbounded_coverage_run_steps
  [ "${status}" -eq 0 ]
  [ -z "${output}" ] || {
    printf 'unbounded run steps in coverage-bash:\n%s\n' "${output}"
    false
  }
}

@test "the coverage step's ceiling sits above both of its inner wall clocks" {
  # The runner bounds each phase itself so that an overrun REPORTS: it prints
  # how far the exercise got, the tail of kcov.log, and which clock expired.
  # A step ceiling below the sum of those clocks makes that impossible — the
  # runner is killed mid-phase and the fallback, seeing no `rescue`, calls it a
  # genuine failure. That inversion (15 minutes of ceiling against 30 minutes of
  # inner budget) is what left this gate red and unreadable from 2026-07-28 on.
  read -r tm kcov_secs bats_secs <<< "$(coverage_step_budget)"
  [ -n "${tm}" ]
  [ -n "${kcov_secs}" ]
  [ -n "${bats_secs}" ]
  [ "$((tm * 60))" -gt "$((kcov_secs + bats_secs))" ]
}

@test "the guard actually finds the workflow jobs that apt-install kcov" {
  found=""
  for wf in "${WORKFLOW_DIR}"/*.yml; do
    found="${found}$(kcov_jobs "${wf}")"
  done
  [ -n "${found}" ]
}

@test "no workflow job apt-installs kcov on an image whose archive dropped it" {
  violations=""
  for wf in "${WORKFLOW_DIR}"/*.yml; do
    while IFS=: read -r file job runs; do
      [ -n "${job}" ] || continue
      case "${runs}" in
        ubuntu-latest | ubuntu-24.04* | ubuntu-25* | ubuntu-26*)
          violations="${violations}${file}: job '${job}' apt-installs kcov on ${runs}
"
          ;;
      esac
    done < <(kcov_jobs "${wf}")
  done
  [ -z "${violations}" ] || {
    printf '%s' "${violations}"
    false
  }
}
