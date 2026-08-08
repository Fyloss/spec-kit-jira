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
