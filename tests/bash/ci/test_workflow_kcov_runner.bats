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
