#!/usr/bin/env bash
# lib/timing.sh — Per-phase wall time and request count (spec FR-001…FR-006,
# contracts/timing-report.md).
#
# Off by default: SPEC_KIT_JIRA_TIMING unset or empty makes every function
# here a no-op, so the mode costs nothing when nobody asked for it. On, it
# marks the eight fixed phases of data-model.md §2 and prints one line per
# phase reached plus a total, to stderr only, in the fixed-width shape the
# corpus diffs byte-for-byte across ports under an injected clock.
#
# Port infrastructure only: NO Jira knowledge.

[[ -n ${_JIRA_LIB_TIMING:-} ]] && return 0
_JIRA_LIB_TIMING=1

# The eight phases, in the one fixed order data-model.md §2 requires.
# timing_report iterates this list and skips whatever was not reached — it
# never sorts by call order, so a phase begun out of sequence still prints in
# its canonical place.
TIMING_PHASE_ORDER=(prereq state config parse gate recognition plan apply)

declare -g -A _TIMING_START_MS=()
declare -g -A _TIMING_START_REQ=()
declare -g -A _TIMING_ELAPSED_MS=()
declare -g -A _TIMING_REQS=()
_TIMING_CLOCK_TIER=""
_TIMING_DEGRADED=0
_TIMING_FAKE_CLOCK_IDX=0

# timing_enabled — true when SPEC_KIT_JIRA_TIMING is set to any non-empty value.
timing_enabled() {
  [[ -n "${SPEC_KIT_JIRA_TIMING:-}" ]]
}

# _timing_resolve_clock — pick a clock tier once, cached in _TIMING_CLOCK_TIER
# so no phase mark re-probes (research R1).
#
# Honours _TIMING_FORCE_CLOCK_TIER (1, 2, or 3) so a test can exercise tier 2
# and tier 3 on a host whose real Bash qualifies for tier 1 — the same shape
# as lib/prereq.sh's _PREREQ_BASH_MAJOR seam.
_timing_resolve_clock() {
  [[ -n "${_TIMING_CLOCK_TIER}" ]] && return 0

  if [[ -n "${_TIMING_FORCE_CLOCK_TIER:-}" ]]; then
    _TIMING_CLOCK_TIER="${_TIMING_FORCE_CLOCK_TIER}"
  elif [[ -n "${EPOCHREALTIME:-}" ]]; then
    _TIMING_CLOCK_TIER=1
  else
    local probe
    probe="$(date +%s%N 2> /dev/null)"
    if [[ "${probe}" =~ ^[0-9]+$ ]]; then
      _TIMING_CLOCK_TIER=2
    else
      _TIMING_CLOCK_TIER=3
    fi
  fi

  [[ "${_TIMING_CLOCK_TIER}" == "3" ]] && _TIMING_DEGRADED=1
  return 0
}

# _timing_fake_clock_next — consume one whitespace-separated reading from
# _TIMING_FAKE_CLOCK, in order, into _TIMING_NOW_MS. Returns the last reading
# again once exhausted rather than failing (contracts/timing-report.md §4):
# an under-supplied fixture shows 0 ms phases instead of crashing a run.
#
# Sets a global rather than printing, and is never called through `$( … )`:
# the cursor it advances (_TIMING_FAKE_CLOCK_IDX) is exactly the kind of
# state a command-substitution subshell discards on exit (research R3).
_timing_fake_clock_next() {
  local -a readings
  # shellcheck disable=SC2206  # word-splitting on whitespace is the intended parse
  readings=(${_TIMING_FAKE_CLOCK})
  local n="${#readings[@]}"
  # A set-but-empty fixture supplies zero readings, which would clamp the
  # cursor to -1 and index an empty array — "bad array subscript" on STDERR,
  # the very channel the report writes on and the corpus diffs byte-for-byte
  # (invariant T5). §4's "degrade, never crash" has to hold at zero too.
  if ((n == 0)); then
    _TIMING_NOW_MS=0
    return 0
  fi
  local idx="${_TIMING_FAKE_CLOCK_IDX}"
  (( idx >= n )) && idx=$((n - 1))
  _TIMING_NOW_MS="${readings[idx]}"
  if (( idx < n - 1 )); then
    _TIMING_FAKE_CLOCK_IDX=$((idx + 1))
  fi
  return 0
}

# _timing_now_ms — set _TIMING_NOW_MS to the current reading, in milliseconds,
# from whichever clock tier is active. _TIMING_FAKE_CLOCK, when set, always
# wins: no real clock is read, which is what keeps a timing scenario's stderr
# byte-identical across runs and across ports.
#
# Sets a global rather than printing, and callers must call it directly
# rather than through `$( … )` — command substitution's subshell would
# discard the clock-tier resolution and the degraded-mode flag exactly as it
# discards the fake-clock cursor above.
_timing_now_ms() {
  if [[ -n "${_TIMING_FAKE_CLOCK:-}" ]]; then
    _timing_fake_clock_next
    return 0
  fi

  _timing_resolve_clock
  case "${_TIMING_CLOCK_TIER}" in
    1)
      # No fork at all: pure parameter expansion, so the instrument does not
      # distort what it measures.
      local sec="${EPOCHREALTIME%.*}"
      local usec="${EPOCHREALTIME#*.}"
      _TIMING_NOW_MS=$(( sec * 1000 + (10#${usec} / 1000) ))
      ;;
    2)
      local ns
      ns="$(date +%s%N)"
      _TIMING_NOW_MS=$(( ns / 1000000 ))
      ;;
    *)
      _TIMING_NOW_MS=$(( $(date +%s) * 1000 ))
      ;;
  esac
  return 0
}

# timing_phase_begin <phase> — mark the start of one phase. A no-op when
# timing is off.
timing_phase_begin() {
  timing_enabled || return 0
  local phase="$1"
  _timing_now_ms
  _TIMING_START_MS["${phase}"]="${_TIMING_NOW_MS}"
  _TIMING_START_REQ["${phase}"]="${JIRA_REQUEST_COUNT:-0}"
}

# timing_phase_end <phase> — mark the end of one phase, recording elapsed
# wall time and the JIRA_REQUEST_COUNT delta since the matching begin. A
# no-op when timing is off, and silently ignored if there is no matching
# begin (never errors the run it is instrumenting).
timing_phase_end() {
  timing_enabled || return 0
  local phase="$1"
  local start="${_TIMING_START_MS[${phase}]:-}"
  [[ -z "${start}" ]] && return 0
  _timing_now_ms
  _TIMING_ELAPSED_MS["${phase}"]=$(( _TIMING_NOW_MS - start ))
  local start_req="${_TIMING_START_REQ[${phase}]:-0}"
  _TIMING_REQS["${phase}"]=$(( ${JIRA_REQUEST_COUNT:-0} - start_req ))
}

# timing_report — print one line per phase reached, in fixed order, plus a
# total, to stderr. A no-op when timing is off or no phase was reached.
timing_report() {
  timing_enabled || return 0

  local phase reached=0
  for phase in "${TIMING_PHASE_ORDER[@]}"; do
    [[ -n "${_TIMING_ELAPSED_MS[${phase}]+set}" ]] && reached=1
  done
  (( reached )) || return 0

  if (( _TIMING_DEGRADED )); then
    printf 'timing: this host has no sub-second clock; durations are whole seconds\n' >&2
  fi

  local total_ms=0 total_req=0 ms req
  for phase in "${TIMING_PHASE_ORDER[@]}"; do
    [[ -n "${_TIMING_ELAPSED_MS[${phase}]+set}" ]] || continue
    ms="${_TIMING_ELAPSED_MS[${phase}]}"
    req="${_TIMING_REQS[${phase}]:-0}"
    printf 'timing: %-11s %6s ms %4s requests\n' "${phase}" "${ms}" "${req}" >&2
    total_ms=$(( total_ms + ms ))
    total_req=$(( total_req + req ))
  done
  printf 'timing: %-11s %6s ms %4s requests\n' "total" "${total_ms}" "${total_req}" >&2
}
