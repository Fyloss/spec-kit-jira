#!/usr/bin/env bats
# T007 — Per-phase timing (spec FR-001…FR-006, contracts/timing-report.md).
#
# Off by default; every function is a no-op unless SPEC_KIT_JIRA_TIMING is set.
# The clock tiers of research R1 are forced deterministically via
# _TIMING_FORCE_CLOCK_TIER (the same shape as lib/prereq.sh's
# _PREREQ_BASH_MAJOR) so tier 2 and tier 3 are exercised on any host, including
# one whose real Bash qualifies for tier 1.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/timing.sh"
  export SPEC_KIT_JIRA_TIMING=1
}

# _skip_unless_locale <locale> — quickstart.md §1a (T001): a comma-decimal
# locale test MUST NOT silently pass when the locale is absent from the host
# it runs on — an explicit, visible skip, never a no-op that reports green.
# `locale -a`'s own spelling varies by host (`fr_FR.utf8`, `fr_FR.UTF-8`), so
# match case-insensitively and tolerate either. This check was documented in
# quickstart.md as already wired into every test that needs it, but was never
# actually implemented until 2026-08-12, when a CI run on a runner missing
# both locales turned the arithmetic failure this task exists to prevent into
# exactly that failure: `[: bash: warning: setlocale ...: integer expression
# expected` — the locale-unavailable case surfacing as a bogus assertion
# failure instead of a named skip.
_skip_unless_locale() {
  local loc="$1"
  locale -a 2> /dev/null | grep -qi "^${loc%%.*}\.utf-\{0,1\}8\$" \
    || skip "${loc} not generated on this host"
}

teardown() {
  unset SPEC_KIT_JIRA_TIMING _TIMING_FAKE_CLOCK _TIMING_FORCE_CLOCK_TIER JIRA_REQUEST_COUNT
}

# --- Activation ---------------------------------------------------------------

@test "every function is a no-op when SPEC_KIT_JIRA_TIMING is unset" {
  unset SPEC_KIT_JIRA_TIMING
  timing_phase_begin prereq
  timing_phase_end prereq
  run timing_report
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "every function is a no-op when SPEC_KIT_JIRA_TIMING is empty" {
  export SPEC_KIT_JIRA_TIMING=""
  timing_phase_begin prereq
  timing_phase_end prereq
  run timing_report
  [ -z "${output}" ]
}

# --- Clock tiers (research R1) ------------------------------------------------

@test "tier 1 (EPOCHREALTIME) produces a positive millisecond reading" {
  _TIMING_FORCE_CLOCK_TIER=1
  _timing_now_ms
  [[ "${_TIMING_NOW_MS}" =~ ^[0-9]+$ ]]
  [ "${_TIMING_NOW_MS}" -gt 0 ]
}

@test "tier 2 (probed date +%s%N) produces a positive millisecond reading" {
  _TIMING_FORCE_CLOCK_TIER=2
  _timing_now_ms
  [[ "${_TIMING_NOW_MS}" =~ ^[0-9]+$ ]]
  [ "${_TIMING_NOW_MS}" -gt 0 ]
}

@test "tier 3 (whole seconds) produces a millisecond reading that is a multiple of 1000" {
  _TIMING_FORCE_CLOCK_TIER=3
  _timing_now_ms
  [[ "${_TIMING_NOW_MS}" =~ ^[0-9]+$ ]]
  [ "$((_TIMING_NOW_MS % 1000))" -eq 0 ]
}

@test "tier 3 announces its degradation in the report, and only tier 3 does" {
  _TIMING_FORCE_CLOCK_TIER=3
  timing_phase_begin prereq
  timing_phase_end prereq
  run timing_report
  [[ "${output}" == "timing: this host has no sub-second clock; durations are whole seconds"* ]]
}

@test "tier 1 does not announce degradation" {
  _TIMING_FORCE_CLOCK_TIER=1
  timing_phase_begin prereq
  timing_phase_end prereq
  run timing_report
  [[ "${output}" != *"no sub-second clock"* ]]
}

# --- The fixed-width report shape (contracts/timing-report.md §2) ------------

@test "the report renders the fixed-width shape with an injected clock" {
  _TIMING_FAKE_CLOCK="0 12 12 19 19 107 107 148 148 157 157 891 891 954 954 3795"
  JIRA_REQUEST_COUNT=0
  timing_phase_begin prereq
  timing_phase_end prereq
  timing_phase_begin state
  timing_phase_end state
  timing_phase_begin config
  timing_phase_end config
  timing_phase_begin parse
  timing_phase_end parse
  timing_phase_begin gate
  timing_phase_end gate
  timing_phase_begin recognition
  JIRA_REQUEST_COUNT=2
  timing_phase_end recognition
  timing_phase_begin plan
  timing_phase_end plan
  timing_phase_begin apply
  JIRA_REQUEST_COUNT=13
  timing_phase_end apply
  run timing_report
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "timing: prereq          12 ms    0 requests" ]
  [ "${lines[1]}" = "timing: state            7 ms    0 requests" ]
  [ "${lines[2]}" = "timing: config          88 ms    0 requests" ]
  [ "${lines[3]}" = "timing: parse           41 ms    0 requests" ]
  [ "${lines[4]}" = "timing: gate             9 ms    0 requests" ]
  [ "${lines[5]}" = "timing: recognition    734 ms    2 requests" ]
  [ "${lines[6]}" = "timing: plan            63 ms    0 requests" ]
  [ "${lines[7]}" = "timing: apply         2841 ms   11 requests" ]
  [ "${lines[8]}" = "timing: total         3795 ms   13 requests" ]
}

@test "a phase not reached is not printed, and phases print in fixed order regardless of call order" {
  _TIMING_FAKE_CLOCK="0 5 0 3"
  timing_phase_begin apply
  timing_phase_end apply
  timing_phase_begin prereq
  timing_phase_end prereq
  run timing_report
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == timing:\ prereq* ]]
  [[ "${lines[1]}" == timing:\ apply* ]]
  [[ "${lines[2]}" == timing:\ total* ]]
}

@test "a short-circuited run reports prereq, state, and the total, and nothing else" {
  _TIMING_FAKE_CLOCK="0 12 12 19"
  timing_phase_begin prereq
  timing_phase_end prereq
  timing_phase_begin state
  timing_phase_end state
  run timing_report
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == timing:\ prereq* ]]
  [[ "${lines[1]}" == timing:\ state* ]]
  [[ "${lines[2]}" == timing:\ total* ]]
}

@test "requests counts the JIRA_REQUEST_COUNT delta across the phase" {
  _TIMING_FAKE_CLOCK="1000 1500"
  JIRA_REQUEST_COUNT=4
  timing_phase_begin recognition
  JIRA_REQUEST_COUNT=7
  timing_phase_end recognition
  run timing_report
  [[ "${lines[0]}" == "timing: recognition    500 ms    3 requests" ]]
}

# --- The _TIMING_FAKE_CLOCK seam ----------------------------------------------

@test "_TIMING_FAKE_CLOCK yields deterministic durations, consumed in order" {
  _TIMING_FAKE_CLOCK="100 250"
  _timing_now_ms
  [ "${_TIMING_NOW_MS}" = "100" ]
  _timing_now_ms
  [ "${_TIMING_NOW_MS}" = "250" ]
}

@test "_TIMING_FAKE_CLOCK returns its last reading again once exhausted" {
  _TIMING_FAKE_CLOCK="10 20"
  _timing_now_ms
  _timing_now_ms
  [ "${_TIMING_NOW_MS}" = "20" ]
  _timing_now_ms
  [ "${_TIMING_NOW_MS}" = "20" ]
}

@test "no real clock is read when _TIMING_FAKE_CLOCK is set, even under a forced tier" {
  _TIMING_FAKE_CLOCK="42"
  _TIMING_FORCE_CLOCK_TIER=3
  _timing_now_ms
  [ "${_TIMING_NOW_MS}" = "42" ]
}

# --- Locale-independent clock reading (spec FR-001…FR-006, contracts/clock-reading.md) ---
#
# T004-T006. V1-V3 must assert the DURATION, never the absence of an error
# (FR-005): research R1 measured the pre-fix code as error-free for roughly
# nine readings in ten while returning a bogus duration derived from the
# fractional microseconds alone (magnitude ~10^5-10^8, unrelated to real
# elapsed time) — an error-absence test passes against that ~90% of the time.
# A short real sleep, checked against a generous tolerance, fails reliably
# against the bug either way: the ~10% loud branch aborts arithmetic
# evaluation (nonzero status), and the ~90% silent branch returns a duration
# many orders of magnitude outside the tolerance.

@test "T004: tier 1 clock reports a correct duration under fr_FR.UTF-8 (comma decimal)" {
  _skip_unless_locale fr_FR.UTF-8
  run env LC_ALL=fr_FR.UTF-8 bash -c '
    source "'"${LIB_DIR}"'/timing.sh"
    _TIMING_FORCE_CLOCK_TIER=1
    _timing_now_ms; start="${_TIMING_NOW_MS}"
    sleep 0.15
    _timing_now_ms; end="${_TIMING_NOW_MS}"
    printf "%s" "$(( end - start ))"
  '
  [ "${status}" -eq 0 ]
  [ "${output}" -ge 100 ]
  [ "${output}" -le 3000 ]
}

@test "T005: tier 1 clock reports a correct duration under de_DE.UTF-8 (comma decimal)" {
  _skip_unless_locale de_DE.UTF-8
  run env LC_ALL=de_DE.UTF-8 bash -c '
    source "'"${LIB_DIR}"'/timing.sh"
    _TIMING_FORCE_CLOCK_TIER=1
    _timing_now_ms; start="${_TIMING_NOW_MS}"
    sleep 0.15
    _timing_now_ms; end="${_TIMING_NOW_MS}"
    printf "%s" "$(( end - start ))"
  '
  [ "${status}" -eq 0 ]
  [ "${output}" -ge 100 ]
  [ "${output}" -le 3000 ]
}

@test "T005: tier 1 clock reports a correct duration under LC_ALL=C (dot decimal)" {
  run env LC_ALL=C bash -c '
    source "'"${LIB_DIR}"'/timing.sh"
    _TIMING_FORCE_CLOCK_TIER=1
    _timing_now_ms; start="${_TIMING_NOW_MS}"
    sleep 0.15
    _timing_now_ms; end="${_TIMING_NOW_MS}"
    printf "%s" "$(( end - start ))"
  '
  [ "${status}" -eq 0 ]
  [ "${output}" -ge 100 ]
  [ "${output}" -le 3000 ]
}

@test "T005: the injected-clock report is byte-identical across C, fr_FR.UTF-8, and de_DE.UTF-8" {
  _skip_unless_locale fr_FR.UTF-8
  _skip_unless_locale de_DE.UTF-8
  local report_c report_fr report_de
  report_c="$(env LC_ALL=C bash -c '
    source "'"${LIB_DIR}"'/timing.sh"
    export SPEC_KIT_JIRA_TIMING=1
    _TIMING_FAKE_CLOCK="0 12 12 19"
    timing_phase_begin prereq; timing_phase_end prereq
    timing_phase_begin state; timing_phase_end state
    timing_report
  ' 2>&1)"
  report_fr="$(env LC_ALL=fr_FR.UTF-8 bash -c '
    source "'"${LIB_DIR}"'/timing.sh"
    export SPEC_KIT_JIRA_TIMING=1
    _TIMING_FAKE_CLOCK="0 12 12 19"
    timing_phase_begin prereq; timing_phase_end prereq
    timing_phase_begin state; timing_phase_end state
    timing_report
  ' 2>&1)"
  report_de="$(env LC_ALL=de_DE.UTF-8 bash -c '
    source "'"${LIB_DIR}"'/timing.sh"
    export SPEC_KIT_JIRA_TIMING=1
    _TIMING_FAKE_CLOCK="0 12 12 19"
    timing_phase_begin prereq; timing_phase_end prereq
    timing_phase_begin state; timing_phase_end state
    timing_report
  ' 2>&1)"
  [ "${report_c}" = "${report_fr}" ]
  [ "${report_fr}" = "${report_de}" ]
}

# --- Fail-open: the instrument never decides an outcome (contracts/clock-reading.md §2) ---
#
# T006. `_TIMING_FORCE_RAW_CLOCK` stands in for whatever the active tier would
# have read (EPOCHREALTIME, `date +%s%N`, or `date +%s`), letting a test force
# a malformed reading deterministically — EPOCHREALTIME itself cannot be
# assigned (bash treats it as a live dynamic variable; an assignment is
# silently discarded on read).

@test "T006: a malformed reading on tier 1 does not abort the shell under set -e" {
  run bash -c '
    set -euo pipefail
    source "'"${LIB_DIR}"'/timing.sh"
    _TIMING_FORCE_CLOCK_TIER=1
    _TIMING_FORCE_RAW_CLOCK="not-a-clock-reading"
    _timing_now_ms
    printf "survived %s" "${_TIMING_NOW_MS}"
  '
  [ "${status}" -eq 0 ]
  [[ "${output}" == survived* ]]
}

@test "T006: a malformed reading on tier 2 does not abort the shell under set -e" {
  run bash -c '
    set -euo pipefail
    source "'"${LIB_DIR}"'/timing.sh"
    _TIMING_FORCE_CLOCK_TIER=2
    _TIMING_FORCE_RAW_CLOCK=""
    _timing_now_ms
    printf "survived %s" "${_TIMING_NOW_MS}"
  '
  [ "${status}" -eq 0 ]
  [[ "${output}" == survived* ]]
}

@test "T006: a malformed reading on tier 3 does not abort the shell under set -e" {
  run bash -c '
    set -euo pipefail
    source "'"${LIB_DIR}"'/timing.sh"
    _TIMING_FORCE_CLOCK_TIER=3
    _TIMING_FORCE_RAW_CLOCK="garbage"
    _timing_now_ms
    printf "survived %s" "${_TIMING_NOW_MS}"
  '
  [ "${status}" -eq 0 ]
  [[ "${output}" == survived* ]]
}

@test "T006: a malformed reading emits nothing extra on stderr (C2.4)" {
  run bash -c '
    source "'"${LIB_DIR}"'/timing.sh"
    export SPEC_KIT_JIRA_TIMING=1
    _TIMING_FORCE_CLOCK_TIER=1
    _TIMING_FORCE_RAW_CLOCK="garbage"
    timing_phase_begin prereq
    timing_phase_end prereq
    timing_report
  '
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"no sub-second clock"* ]]
}

@test "T006: a run with a forced malformed reading writes nothing extra and exits like timing-off (V5)" {
  run bash -c '
    set -euo pipefail
    source "'"${LIB_DIR}"'/timing.sh"
    export SPEC_KIT_JIRA_TIMING=1
    _TIMING_FORCE_CLOCK_TIER=1
    _TIMING_FORCE_RAW_CLOCK="garbage"
    timing_phase_begin prereq
    timing_phase_end prereq
    echo "reconcile outcome unaffected"
  '
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reconcile outcome unaffected"* ]]
}

# A set-but-empty _TIMING_FAKE_CLOCK supplies zero readings, so the cursor
# clamp computes index -1 over an empty array. §4 says an under-supplied
# fixture shows 0 ms phases rather than crashing a run, and that has to hold
# at zero readings too — the more so because bash's "bad array subscript"
# goes to STDERR, which is the very channel the report writes on and the
# corpus diffs byte-for-byte (invariant T5: nothing but `timing:` lines).
@test "_TIMING_FAKE_CLOCK set to whitespace only reads 0 ms, silently" {
  _TIMING_FAKE_CLOCK="   "
  run _timing_now_ms
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  _timing_now_ms
  [ "${_TIMING_NOW_MS}" = "0" ]
}

# --- B4 (023, T151, spawn-budget.md §4): the timing report's phase
# attribution is real, not just internally consistent, when feature 023's
# own requests are in play -----------------------------------------------

@test "B4 -- feature 023's transitions reads land wholly in the plan phase, and per-phase counts sum to calls.log's total (023, T151)" {
  local root="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${root}/tests/bash/helpers/calls_log.bash"
  local outdir="${BATS_TMPDIR}/timing_budget_b4_$$"
  rm -rf "${outdir}"

  SPEC_KIT_JIRA_HARNESS_ENV="SPEC_KIT_JIRA_TIMING=1" \
    bash "${root}/tests/conformance/run-scenario.sh" \
    "${root}/tests/conformance/scenarios/us023-sixty-stories-due.json" bash "${outdir}" > /dev/null

  local total_calls total_reported
  total_calls="$(helper_calls_total "${outdir}/calls.log")"
  total_reported="$(grep '^timing: total' "${outdir}/stderr" | sed -E 's/^timing: total +[0-9]+ ms +([0-9]+) requests.*/\1/')"
  [ "${total_calls}" -gt 0 ]
  [ "${total_reported}" = "${total_calls}" ]

  # The harness's own log, never timing's self-report, is what "attributed
  # to plan" is checked against: every availability read this feature issues
  # (GET .../transitions?expand=…) is a plan-phase request (transitions_load
  # is called only from inside plan_lifecycle/plan_lifecycle_tasks, both
  # invoked between reconcile.sh's own plan begin/end marks), and this
  # scenario's due set issues nothing else during plan — so the two counts
  # are exactly equal, not just plan-request-count > 0.
  local transitions_reads plan_reported
  transitions_reads="$(grep -c '^GET .*/transitions?expand=' "${outdir}/calls.log")"
  plan_reported="$(grep '^timing: plan ' "${outdir}/stderr" | sed -E 's/^timing: plan +[0-9]+ ms +([0-9]+) requests.*/\1/')"
  [ "${transitions_reads}" -gt 0 ]
  [ "${plan_reported}" = "${transitions_reads}" ]

  # The write half of the same feature (the transition POST) is issued from
  # apply_writes, called only after reconcile.sh's own apply begin mark —
  # so it is counted under apply, never folded back into plan.
  local transitions_writes apply_reported
  transitions_writes="$(grep -c '^POST .*/transitions' "${outdir}/calls.log")"
  apply_reported="$(grep '^timing: apply ' "${outdir}/stderr" | sed -E 's/^timing: apply +[0-9]+ ms +([0-9]+) requests.*/\1/')"
  [ "${transitions_writes}" -gt 0 ]
  [ "${apply_reported}" -ge "${transitions_writes}" ]

  rm -rf "${outdir}"
}
