#!/usr/bin/env bash
# tests/coverage/bash-coverage.sh — Bash-port statement coverage gate (T097).
#
#   ./tests/coverage/bash-coverage.sh [--threshold N] [--report-dir DIR]
#                                     [--mode conformance|bats]
#
# Constitution XIII requires ≥ 80% statement coverage on both ports. The
# PowerShell port uses Pester's built-in CodeCoverage; this is the Bash twin.
#
# --- Why the default mode is NOT `kcov ... bats -r tests/bash` ----------------
# kcov instruments bats-core's OWN tracing infrastructure (bats_debug_trap,
# lib/bats-core/tracing.bash). kcov's trace output is then re-printed by bats's
# trace handler and re-instrumented, each line nesting the previous, so the run
# does not merely get slow — it never terminates, and the trace file grows
# without bound (a single observed run wrote 91.7 GB and filled the disk).
# `--mode bats` is therefore opt-in and MUST be run with an external wall-clock
# and disk guard. It remains the measurement worth having, because the bats
# suites are where the error and edge paths are asserted; if it can be made to
# terminate on Linux it should become the default.
#
# --- What the default (conformance) mode measures -----------------------------
# The conformance corpus driven through the real dispatcher end-to-end, plus the
# dispatcher/usage paths no scenario reaches. kcov's bash tracing follows sourced
# files and forked subshells but not execve'd children, so both the harness and
# the entry point are *sourced* (the harness honours
# SPEC_KIT_JIRA_COVERAGE_INPROCESS for exactly this reason; the conformance suite
# asserts that mode is behaviourally identical to the forked one).
#
# This mode is a LOWER BOUND, not the whole picture: it drives happy paths and
# the refusals scenarios encode, so modules whose branches are exercised mainly
# by unit tests (lib/credentials.sh, engine/drift.sh, sink/jira/client.sh,
# engine/interchange.sh) score far below their real tested coverage.
#
# Exits 0 when coverage meets the threshold, 1 when it falls short, 2 on a setup
# problem (kcov missing, unusable interpreter, no coverage produced).

set -uo pipefail

THRESHOLD=80
REPORT_DIR=""
MODE="drive"
TARGET="${SPEC_KIT_JIRA_COVERAGE_MODE:-conformance}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --mode) TARGET="$2"; shift 2 ;;
    --exercise) MODE="exercise"; shift ;;
    -h | --help)
      printf '%s\n' \
        "usage: bash-coverage.sh [--threshold N] [--report-dir DIR] [--mode conformance|bats]" \
        "  conformance (default)  bounded: the conformance corpus through the real dispatcher" \
        "  bats                   the full bats suite — see the header; needs an external" \
        "                         wall-clock and disk guard, it is known to run away"
      exit 0
      ;;
    *) printf 'bash-coverage.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "${TARGET}" in
  conformance | bats) ;;
  *) printf 'bash-coverage.sh: unknown mode: %s (expected conformance|bats)\n' "${TARGET}" >&2; exit 2 ;;
esac
export SPEC_KIT_JIRA_COVERAGE_MODE="${TARGET}"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
HARNESS="${REPO_ROOT}/tests/conformance/run-scenario.sh"

# --- Exercise mode: everything below runs INSIDE kcov -------------------------

exercise_scenarios() {
  # Every conformance scenario through the real dispatcher. Sourced, not exec'd,
  # so the tracer follows into scripts/bash/**.
  local scenario out i=0
  export SPEC_KIT_JIRA_COVERAGE_INPROCESS=1
  for scenario in "${REPO_ROOT}"/tests/conformance/scenarios/*.json; do
    [ -f "${scenario}" ] || continue
    i=$((i + 1))
    out="${SCRATCH}/scenario-${i}"
    mkdir -p "${out}"
    # shellcheck source=/dev/null
    ( source "${HARNESS}" "${scenario}" bash "${out}" ) > /dev/null 2>&1
  done
}

exercise_dispatcher() {
  # Dispatcher and usage paths: no scenario asserts them, but they are real code.
  local entry="${REPO_ROOT}/scripts/bash/spec-kit-jira.sh"
  local work="${SCRATCH}/dispatcher"
  mkdir -p "${work}"
  # shellcheck source=/dev/null
  ( cd "${work}" && source "${entry}" --help ) > /dev/null 2>&1          # help, exit 0
  # shellcheck source=/dev/null
  ( cd "${work}" && source "${entry}" ) > /dev/null 2>&1                 # no command
  # shellcheck source=/dev/null
  ( cd "${work}" && source "${entry}" nosuchcommand ) > /dev/null 2>&1   # unknown command
  # shellcheck source=/dev/null
  ( cd "${work}" && source "${entry}" config --nosuchflag ) > /dev/null 2>&1  # usage error
}

exercise_libraries() {
  # Pure library/engine surface the end-to-end corpus cannot drive into every
  # branch (serialisers, validators, naming rules). Kept to public entry points.
  local d="${REPO_ROOT}/scripts/bash"
  (
    # shellcheck source=/dev/null
    source "${d}/lib/output.sh"
    summary_build_json reconcile false 1 2 3 0 0 0 > /dev/null
    summary_build_json config true 0 0 0 1 1 4 > /dev/null
    printf '%s' "$(summary_build_json reconcile true 1 0 0 2 1 2)" | summary_render_prose > /dev/null
    uri_encode 'a b/c&d=é' > /dev/null
    printf '%s' '{"b":1,"a":[2,3]}' | json_canonical > /dev/null
    output_warn 'coverage exercise' 2> /dev/null
  ) > /dev/null 2>&1
  (
    # shellcheck source=/dev/null
    source "${d}/engine/naming.sh"
    naming_ticket_number 'ABC-123' > /dev/null      # prefix-shaped
    naming_ticket_number 'notakey' > /dev/null       # returned unchanged
    naming_expand_pattern 'ijt-<ID>/<FEATURE_NAME>' 123 'invoice-export' > /dev/null
    naming_slug 'Invoice Export — Phase 2!' > /dev/null
    naming_short_name 'ijt-' 'invoice-export' > /dev/null      # prefix prepended
    naming_short_name 'ijt-' 'ijt-invoice-export' > /dev/null  # prefix not duplicated
  ) > /dev/null 2>&1
}

if [ "${MODE}" = "exercise" ]; then
  SCRATCH="${SPEC_KIT_JIRA_COVERAGE_SCRATCH:-$(mktemp -d)}"
  export SCRATCH
  if [ "${TARGET}" = "bats" ]; then
    bats -r "${REPO_ROOT}/tests/bash" > /dev/null 2>&1
    exit 0
  fi
  exercise_scenarios
  exercise_dispatcher
  exercise_libraries
  exit 0
fi

# --- Drive mode: set up kcov, run exercise mode under it, report --------------

if ! command -v kcov > /dev/null 2>&1; then
  printf 'bash-coverage.sh: kcov not found — install it (brew install kcov / apt-get install kcov)\n' >&2
  exit 2
fi

if [ -z "${REPORT_DIR}" ]; then
  REPORT_DIR="${REPO_ROOT}/coverage/bash"
fi
mkdir -p "${REPORT_DIR}"

# kcov runs the traced script under its --bash-parser, which defaults to
# /bin/bash — and that default is the ONLY interpreter it can drive on macOS:
# pointing --bash-parser at a Homebrew bash 5 (any path, either --bash-method)
# aborts with "Failed to exchange stderr for pipe: Bad file descriptor", because
# kcov's stderr-for-pipe swap only survives against Apple's SIP-signed binary.
# Apple's /bin/bash is 3.2, which this port deliberately does not support
# (${var,,} and friends), so every run would die on the bash>=4 prerequisite gate
# with exit 5 and measure nothing. Refuse up front with that explanation rather
# than reporting a meaningless 0%. On Linux /bin/bash is >= 4 and the default
# works, which is where the CI gate job runs.
BASH_PARSER="${SPEC_KIT_JIRA_COVERAGE_BASH:-/bin/bash}"
# The expansion is deliberately deferred to the child shell being probed.
# shellcheck disable=SC2016
parser_major="$("${BASH_PARSER}" -c 'printf %s "${BASH_VERSINFO[0]}"' 2> /dev/null)"
if [ -z "${parser_major}" ] || [ "${parser_major}" -lt 4 ]; then
  printf 'bash-coverage.sh: kcov must run the port under %s, which is bash %s.\n' \
    "${BASH_PARSER}" "${parser_major:-unknown}" >&2
  printf '  This port requires bash >= 4, so coverage measured here would be meaningless.\n' >&2
  printf '  kcov cannot drive a non-Apple bash on macOS ("Failed to exchange stderr for\n' >&2
  printf '  pipe"), so run this gate on Linux — the CI "Bash coverage" job does exactly\n' >&2
  printf '  that. To override the interpreter anyway: SPEC_KIT_JIRA_COVERAGE_BASH=<path>.\n' >&2
  exit 2
fi

kcov --bash-parser="${BASH_PARSER}" --include-path="${REPO_ROOT}/scripts/bash" \
  "${REPORT_DIR}" "${SELF}" --exercise > "${REPORT_DIR}/kcov.log"
kcov_rc=$?

# kcov writes <report-dir>/<script>.<hash>/coverage.json; the merged directory
# only appears for multi-target runs, so resolve whichever exists.
SUMMARY="$(find "${REPORT_DIR}" -name coverage.json -maxdepth 3 2> /dev/null | head -1)"
if [ -z "${SUMMARY}" ] || [ ! -f "${SUMMARY}" ]; then
  printf 'bash-coverage.sh: kcov produced no coverage.json (rc=%s); see %s/kcov.log\n' \
    "${kcov_rc}" "${REPORT_DIR}" >&2
  exit 2
fi

percent="$(jq -r '.percent_covered' "${SUMMARY}")"
covered="$(jq -r '.covered_lines' "${SUMMARY}")"
total="$(jq -r '.total_lines' "${SUMMARY}")"

printf 'Bash statement coverage: %s%% (%s/%s lines)\n' "${percent}" "${covered}" "${total}"
printf '\nPer file (ascending):\n'
jq -r '.files[] | [(.percent_covered | tonumber), .covered_lines, .total_lines, .file]
       | @tsv' "${SUMMARY}" \
  | sort -n \
  | awk -F'\t' '{ n = split($4, p, "/"); printf "  %6.2f%%  %4d/%-4d  %s\n", $1, $2, $3, p[n-2] "/" p[n-1] "/" p[n] }'

# Integer comparison so the gate needs no bc/python.
pct_int="${percent%%.*}"
if [ "${pct_int:-0}" -lt "${THRESHOLD}" ]; then
  printf '\nFAIL: %s%% is below the %s%% gate (Constitution XIII)\n' "${percent}" "${THRESHOLD}" >&2
  exit 1
fi
printf '\nPASS: %s%% meets the %s%% gate (Constitution XIII)\n' "${percent}" "${THRESHOLD}"
exit 0
