#!/usr/bin/env bash
# tests/coverage/bash-coverage.sh — Bash-port statement coverage gate (T097).
#
#   ./tests/coverage/bash-coverage.sh [--threshold N] [--report-dir DIR]
#                                     [--mode full|conformance|bats]
#
# Constitution XIII requires ≥ 80% statement coverage on both ports, computed on
# the MOCKED UNIT SUITES. The PowerShell port uses Pester's built-in
# CodeCoverage; this is the Bash twin.
#
# --- Why this needs two collectors instead of one -----------------------------
# kcov cannot run bats. It instruments bats-core's OWN tracing infrastructure
# (bats_debug_trap, lib/bats-core/tracing.bash); kcov's trace output is then
# re-printed by bats's trace handler and re-instrumented, each line nesting the
# previous, so the run does not merely get slow — it never terminates, and the
# trace file grows without bound (a single observed run wrote 91.7 GB and filled
# the disk). --exclude-path does not help: it filters reporting, not tracing.
#
# So the two collectors split the work along the only seam that exists:
#
#   * kcov owns the DENOMINATOR — which lines are statements — and measures the
#     conformance corpus end-to-end through the real dispatcher. It is the tool
#     Constitution XIII names, and it stays the authority on what counts.
#   * A plain bash xtrace owns the rest of the NUMERATOR. The bats suite runs
#     with PS4 carrying `file:line` and BASH_XTRACEFD pointing at a dedicated fd,
#     which nothing in bats-core reads or re-prints — no feedback loop, no kcov.
#     SHELLOPTS=xtrace is exported, so the trace follows execve'd children too,
#     which is more than kcov manages.
#
# The merge counts a line as covered when either exercise ran it, and counts
# ONLY lines kcov calls statements: a traced line kcov does not instrument
# (the opening line of an excluded jq literal, say) can never inflate the score.
#
# --- Why --exclude-region is not optional -------------------------------------
# kcov's bash line parser counts the continuation lines of a multi-line jq
# literal as statements, and no execution can ever hit them: the whole literal
# traces as ONE statement at its opening line. The port brackets those regions
# with `# kcov-excl-start` / `# kcov-excl-stop` (533 lines across 8 files), and
# without --exclude-region they sit permanently in the denominator — which alone
# capped engine/drift.sh at 17% and the port at 59%.
#
# --- What the tracer must never do --------------------------------------------
# PS4 expands in EVERY traced shell, including `bash -c` children the suite runs
# under `set -u`. `${BASH_SOURCE}` without a default makes those children print
# "BASH_SOURCE: unbound variable" on their own stderr, which lands in the output
# bats captured and turns green tests red. Measuring must not change what the
# suite sees, so the marker uses `${BASH_SOURCE:-}`.
#
# Exits 0 when coverage meets the threshold, 1 when it falls short, 2 on a setup
# problem (kcov missing, unusable interpreter, no coverage produced).

set -uo pipefail

THRESHOLD=80
REPORT_DIR=""
MODE="drive"
TARGET="${SPEC_KIT_JIRA_COVERAGE_MODE:-full}"
MERGE_COBERTURA=""
MERGE_TRACED=""

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
HARNESS="${REPO_ROOT}/tests/conformance/run-scenario.sh"

# The trace marker. Bash repeats PS4's FIRST CHARACTER once per nesting depth,
# so a frame three functions deep arrives as `###skjcov#...`; the extractor
# matches `#+` for exactly that reason. Anything that matches on the literal
# two-character marker instead silently drops every nested frame — which made
# credentials.sh and client.sh look untouched.
# The expansion belongs to each traced shell, not to this one.
# shellcheck disable=SC2016
TRACE_PS4='#skjcov#${BASH_SOURCE:-}:${LINENO}#skjcov# '
# fd 8, spelled out at every use because `exec` cannot take a variable
# descriptor. Not fd 2: that is the port's own stderr, and under kcov it belongs
# to kcov. Not fd 3 either — bats-core reports its own results on that one.
TRACE_FD=8

while [ "$#" -gt 0 ]; do
  case "$1" in
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --mode) TARGET="$2"; shift 2 ;;
    --exercise) MODE="exercise"; shift ;;
    --extract-trace) MODE="extract"; shift ;;
    --merge-report)
      MODE="merge"
      MERGE_COBERTURA="$2"
      MERGE_TRACED="$3"
      shift 3
      ;;
    -h | --help)
      printf '%s\n' \
        "usage: bash-coverage.sh [--threshold N] [--report-dir DIR] [--mode full|conformance|bats]" \
        "  full (default)  kcov over the conformance corpus + the traced bats suite, merged" \
        "  conformance     kcov over the conformance corpus alone (a lower bound)" \
        "  bats            the traced bats suite alone — hit counts, no denominator," \
        "                  so no gate; the one mode that runs where kcov cannot"
      exit 0
      ;;
    *) printf 'bash-coverage.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "${TARGET}" in
  full | conformance | bats) ;;
  *)
    printf 'bash-coverage.sh: unknown mode: %s (expected full|conformance|bats)\n' "${TARGET}" >&2
    exit 2
    ;;
esac
export SPEC_KIT_JIRA_COVERAGE_MODE="${TARGET}"

# Runs a command under a wall clock. GNU coreutils ships `timeout` on every
# Linux CI image; macOS has it only as Homebrew's `gtimeout`. With neither, run
# unbounded — refusing would block the one host where kcov works at all.
run_bounded() {
  local secs="$1"
  shift
  if command -v timeout > /dev/null; then
    timeout --kill-after=30 "${secs}" "$@"
  elif command -v gtimeout > /dev/null; then
    gtimeout --kill-after=30 "${secs}" "$@"
  else
    "$@"
  fi
}

# --- Reading the two collectors -----------------------------------------------

# stdin: a raw xtrace stream. stdout: the distinct `scripts/bash/<path>:<line>`
# frames it contains, repo-relative, with the `..` a sourced module reports
# (commands/../lib/config.sh) resolved so both collectors name a file the same
# way. Everything else — bats-core's own frames, `environment:0`, the port's
# ordinary output — is dropped.
extract_trace() {
  # The prefilter is not cosmetic: the raw stream is the whole suite's
  # execution, bats machinery included, and better than 99 of every 100 lines
  # are not port frames. A regex engine per line cannot keep up with the writer,
  # and a FIFO that fills backpressures the very suite being measured.
  LC_ALL=C grep -F 'scripts/bash/' \
    | LC_ALL=C awk '
    function norm(p) { while (p ~ /[^\/]+\/\.\.\//) sub(/[^\/]+\/\.\.\//, "", p); return p }
    {
      if (match($0, /^#+skjcov#[^#]*#skjcov#/) == 0) next
      frame = substr($0, RSTART, RLENGTH)
      sub(/^#+skjcov#/, "", frame)
      sub(/#skjcov#$/, "", frame)
      at = index(frame, "scripts/bash/")
      if (at == 0) next
      print norm(substr(frame, at))
    }
  ' | sort -u
}

# Merges kcov's per-line report with the traced frames and prints the gate's
# verdict. kcov's cobertura.xml is the per-line record (coverage.json carries
# only per-file totals); its <source> root plus each class's filename gives the
# absolute path the trace also reports.
merge_report() {
  local cobertura="$1" traced="$2" threshold="$3"
  awk -v traced="${traced}" -v threshold="${threshold}" '
    function norm(p) { while (p ~ /[^\/]+\/\.\.\//) sub(/[^\/]+\/\.\.\//, "", p); return p }
    function rel(p,   at) {
      at = index(p, "scripts/bash/")
      return at == 0 ? "" : norm(substr(p, at))
    }
    function tail3(p,   n, parts) {
      n = split(p, parts, "/")
      if (n < 3) return p
      return parts[n - 2] "/" parts[n - 1] "/" parts[n]
    }
    BEGIN {
      while ((getline line < traced) > 0)
        if (line != "") hit[line] = 1
      close(traced)
    }
    /<source>/ {
      s = $0
      sub(/.*<source>/, "", s)
      sub(/<\/source>.*/, "", s)
      sub(/\/$/, "", s)
      src = s
      next
    }
    /<class / {
      cur = ""
      if (match($0, /filename="[^"]*"/)) {
        f = substr($0, RSTART + 10, RLENGTH - 11)
        cur = rel(substr(f, 1, 1) == "/" ? f : src "/" f)
      }
      next
    }
    /<line / {
      if (cur == "") next
      if (match($0, /number="[^"]*"/) == 0) next
      num = substr($0, RSTART + 8, RLENGTH - 9)
      hits = 0
      if (match($0, /hits="[^"]*"/)) hits = substr($0, RSTART + 6, RLENGTH - 7) + 0
      key = cur ":" num
      if (key in seen) next
      seen[key] = 1
      files[cur] = 1
      total[cur]++
      if (hits > 0 || (key in hit)) covered[cur]++
      next
    }
    END {
      t = 0; c = 0
      for (f in files) { t += total[f]; c += covered[f] + 0 }
      if (t == 0) {
        print "bash-coverage.sh: the report names no measurable statement" > "/dev/stderr"
        exit 2
      }
      pct = 100 * c / t
      printf "Bash statement coverage: %.2f%% (%d/%d lines)\n", pct, c, t
      printf "\nPer file (ascending):\n"
      n = 0
      for (f in files) {
        n++
        rows[n] = sprintf("%9.2f|%6.2f%%  %4d/%-4d  %s", \
          100 * (covered[f] + 0) / total[f], 100 * (covered[f] + 0) / total[f], \
          covered[f] + 0, total[f], tail3(f))
      }
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if ((rows[i] + 0) > (rows[j] + 0)) { tmp = rows[i]; rows[i] = rows[j]; rows[j] = tmp }
      for (i = 1; i <= n; i++) { sub(/^[^|]*\|/, "  ", rows[i]); print rows[i] }
      if (pct + 0 < threshold + 0) {
        printf "\nFAIL: %.2f%% is below the %s%% gate (Constitution XIII)\n", pct, threshold \
          > "/dev/stderr"
        exit 1
      }
      printf "\nPASS: %.2f%% meets the %s%% gate (Constitution XIII)\n", pct, threshold
      exit 0
    }
  ' "${cobertura}"
}

if [ "${MODE}" = "extract" ]; then
  extract_trace
  exit 0
fi

if [ "${MODE}" = "merge" ]; then
  merge_report "${MERGE_COBERTURA}" "${MERGE_TRACED}" "${THRESHOLD}"
  exit $?
fi

# --- Exercise mode: everything below runs INSIDE kcov -------------------------
#
# TWO INVARIANTS HOLD FOR EVERY LINE BELOW, and both are guarded by
# tests/bash/ci/test_coverage_runner_bounds.bats:
#
#   * NEVER redirect fd 2. kcov collects the trace by swapping the traced
#     program's stderr for a pipe, so `2> /dev/null` on a phase discards every
#     line that phase executed — the run measures nothing and says nothing.
#     The port's real stderr therefore reaches the CI log; kcov forwards what
#     it cannot parse as a trace line. That noise is the price of measuring.
#   * ALWAYS read stdin from /dev/null. A phase that reaches a prompt would
#     otherwise wait on the CI runner's stdin until the step is killed.

# Progress is written to a file, not to a stream: stdout belongs to kcov.log and
# stderr belongs to the tracer, so a stalled run would report nothing at all
# through either. The drive side prints this file afterwards — including when
# the wall clock fires, which is the case it exists for.
progress() {
  printf '[%4ds] %s\n' "${SECONDS}" "$*" >> "${PROGRESS}"
}

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
    progress "scenario ${i}: $(basename "${scenario}")"
    # shellcheck source=/dev/null
    ( source "${HARNESS}" "${scenario}" bash "${out}" ) > /dev/null < /dev/null
  done
  progress "scenarios done (${i} run)"
}

exercise_dispatcher() {
  # Dispatcher and usage paths: no scenario asserts them, but they are real code.
  local entry="${REPO_ROOT}/scripts/bash/spec-kit-jira.sh"
  local work="${SCRATCH}/dispatcher"
  mkdir -p "${work}"
  progress "dispatcher paths"
  # shellcheck source=/dev/null
  ( cd "${work}" && source "${entry}" --help ) > /dev/null < /dev/null          # help, exit 0
  # shellcheck source=/dev/null
  ( cd "${work}" && source "${entry}" ) > /dev/null < /dev/null                 # no command
  # shellcheck source=/dev/null
  ( cd "${work}" && source "${entry}" nosuchcommand ) > /dev/null < /dev/null   # unknown command
  # shellcheck source=/dev/null
  ( cd "${work}" && source "${entry}" config --nosuchflag ) > /dev/null < /dev/null  # usage error
}

exercise_libraries() {
  # Pure library/engine surface the end-to-end corpus cannot drive into every
  # branch (serialisers, validators, naming rules). Kept to public entry points.
  local d="${REPO_ROOT}/scripts/bash"
  progress "library entry points"
  (
    # shellcheck source=/dev/null
    source "${d}/lib/output.sh"
    summary_build_json reconcile false 1 2 3 0 0 0 > /dev/null
    summary_build_json config true 0 0 0 1 1 4 > /dev/null
    printf '%s' "$(summary_build_json reconcile true 1 0 0 2 1 2)" | summary_render_prose > /dev/null
    uri_encode 'a b/c&d=é' > /dev/null
    printf '%s' '{"b":1,"a":[2,3]}' | json_canonical > /dev/null
    output_warn 'coverage exercise'
  ) > /dev/null < /dev/null
  (
    # shellcheck source=/dev/null
    source "${d}/engine/naming.sh"
    naming_ticket_number 'ABC-123' > /dev/null      # prefix-shaped
    naming_ticket_number 'notakey' > /dev/null       # returned unchanged
    naming_expand_pattern 'ijt-<ID>/<FEATURE_NAME>' 123 'invoice-export' > /dev/null
    naming_slug 'Invoice Export — Phase 2!' > /dev/null
    naming_short_name 'ijt-' 'invoice-export' > /dev/null      # prefix prepended
    naming_short_name 'ijt-' 'ijt-invoice-export' > /dev/null  # prefix not duplicated
  ) > /dev/null < /dev/null
}

if [ "${MODE}" = "exercise" ]; then
  SCRATCH="${SPEC_KIT_JIRA_COVERAGE_SCRATCH:-$(mktemp -d)}"
  export SCRATCH
  PROGRESS="${SCRATCH}/progress.log"
  : > "${PROGRESS}"
  progress "exercise start (mode=${TARGET})"
  exercise_scenarios
  exercise_dispatcher
  exercise_libraries
  progress "exercise complete"
  exit 0
fi

# --- Drive mode: set up the collectors, run them, merge, report ----------------

if [ -z "${REPORT_DIR}" ]; then
  REPORT_DIR="${REPO_ROOT}/coverage/bash"
fi
mkdir -p "${REPORT_DIR}"

# The exercise scratch sits beside the report dir rather than inside it — kcov
# owns that directory — but still under coverage/, so CI uploads it with the
# rest: when a run stalls, progress.log is the only record of where.
SCRATCH="${REPORT_DIR%/}-scratch"
rm -rf "${SCRATCH}"
mkdir -p "${SCRATCH}"
export SPEC_KIT_JIRA_COVERAGE_SCRATCH="${SCRATCH}"
PROGRESS="${SCRATCH}/progress.log"
TRACED="${SCRATCH}/traced.lines"
: > "${TRACED}"

KCOV_TIMEOUT="${SPEC_KIT_JIRA_COVERAGE_TIMEOUT:-600}"
BATS_TIMEOUT="${SPEC_KIT_JIRA_COVERAGE_BATS_TIMEOUT:-1200}"

# Runs the bats suite with its trace on fd 8. The filter reads a FIFO rather
# than a temp file because the raw stream is the whole suite's execution, bats
# machinery included — gigabytes that never need to exist. Waiting on the
# filter's own PID (not a bare `wait`) is what makes the collected file
# complete before the merge reads it.
trace_bats() {
  local fifo="${SCRATCH}/trace.fifo" filter_pid
  rm -f "${fifo}"
  mkfifo "${fifo}"
  ( extract_trace < "${fifo}" > "${TRACED}" ) &
  filter_pid=$!
  exec 8> "${fifo}"

  printf 'Tracing the bats suite (fd %s)...\n' "${TRACE_FD}"
  # SHELLOPTS carries xtrace into execve'd children, which is how the dispatcher
  # runs get measured; it is passed through `env` because the variable is
  # readonly in a running shell and cannot be assigned as a command prefix.
  run_bounded "${BATS_TIMEOUT}" env \
    PS4="${TRACE_PS4}" \
    BASH_XTRACEFD=8 \
    SHELLOPTS=xtrace \
    bats -r "${REPO_ROOT}/tests/bash" > /dev/null < /dev/null
  bats_rc=$?

  exec 8>&-
  wait "${filter_pid}"

  if [ "${bats_rc}" -eq 124 ]; then
    printf 'bash-coverage.sh: the traced bats run did not finish within %ss.\n' "${BATS_TIMEOUT}" >&2
    printf '  Raise SPEC_KIT_JIRA_COVERAGE_BATS_TIMEOUT if the suite is genuinely this long.\n' >&2
    return 2
  fi
  # A red suite is the unit job's business, not this one's: a failed test still
  # covered the lines it ran, and a test that aborts early only ever measures
  # LESS. Reported, never fatal — unless nothing was measured at all.
  if [ "${bats_rc}" -ne 0 ]; then
    printf 'note: the bats suite exited %s under tracing; coverage from aborted tests is missing.\n' \
      "${bats_rc}"
  fi
  if [ ! -s "${TRACED}" ]; then
    printf 'bash-coverage.sh: the traced bats run produced no port frames at all.\n' >&2
    printf '  Either bats is not installed, or the trace never reached fd %s.\n' "${TRACE_FD}" >&2
    return 2
  fi
  printf 'Traced %s distinct statements from the bats suite.\n\n' "$(wc -l < "${TRACED}" | tr -d ' ')"
  return 0
}

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
require_kcov() {
  if ! command -v kcov > /dev/null 2>&1; then
    printf 'bash-coverage.sh: kcov not found — install it (brew install kcov / apt-get install kcov)\n' >&2
    return 2
  fi
  BASH_PARSER="${SPEC_KIT_JIRA_COVERAGE_BASH:-/bin/bash}"
  local parser_major
  # The expansion is deliberately deferred to the child shell being probed.
  # shellcheck disable=SC2016
  parser_major="$("${BASH_PARSER}" -c 'printf %s "${BASH_VERSINFO[0]}"' 2> /dev/null)"
  if [ -z "${parser_major}" ] || [ "${parser_major}" -lt 4 ]; then
    printf 'bash-coverage.sh: kcov must run the port under %s, which is bash %s.\n' \
      "${BASH_PARSER}" "${parser_major:-unknown}" >&2
    printf '  This port requires bash >= 4, so coverage measured here would be meaningless.\n' >&2
    printf '  kcov cannot drive a non-Apple bash on macOS ("Failed to exchange stderr for\n' >&2
    printf '  pipe"), so run this gate on Linux — the CI "Bash coverage" job does exactly\n' >&2
    printf '  that. To measure only what runs anywhere, use --mode bats.\n' >&2
    return 2
  fi
  return 0
}

# A wall clock, because the failure this guards against is a hang, not a crash:
# kcov reads the trace until every descendant has closed the pipe, so one child
# that outlives the exercise makes the run wait for an EOF that never comes.
# Without a bound of our own the CI runner kills the step and takes the
# diagnostics with it. Note that kcov's OWN stderr is never redirected — kcov
# swaps it for the traced program's pipe, and pointing it at anything but a
# terminal or the job log makes it abort with "Failed to exchange stderr for
# pipe: Bad file descriptor".
run_kcov() {
  : > "${PROGRESS}"
  run_bounded "${KCOV_TIMEOUT}" kcov \
    --bash-parser="${BASH_PARSER}" --include-path="${REPO_ROOT}/scripts/bash" \
    --exclude-region='kcov-excl-start:kcov-excl-stop' \
    "${REPORT_DIR}" "${SELF}" --exercise > "${REPORT_DIR}/kcov.log" < /dev/null
  local kcov_rc=$?

  if [ -s "${PROGRESS}" ]; then
    printf 'Exercise progress:\n'
    sed 's/^/  /' "${PROGRESS}"
    printf '\n'
  fi

  # 124 is `timeout`'s expiry code.
  if [ "${kcov_rc}" -eq 124 ]; then
    printf 'bash-coverage.sh: the kcov run did not finish within %ss.\n' "${KCOV_TIMEOUT}" >&2
    printf '  The progress above shows how far the exercise got. A run that stops\n' >&2
    printf '  making progress is a child outliving its phase: kcov waits for every\n' >&2
    printf '  inherited descriptor to close before it writes a report.\n' >&2
    printf '  Raise the bound with SPEC_KIT_JIRA_COVERAGE_TIMEOUT if the work is\n' >&2
    printf '  genuinely this long. Last lines of %s/kcov.log:\n' "${REPORT_DIR}" >&2
    tail -20 "${REPORT_DIR}/kcov.log" 2> /dev/null | sed 's/^/    /' >&2
    return 2
  fi

  # kcov writes <report-dir>/<script>.<hash>/cobertura.xml; the merged directory
  # only appears for multi-target runs, so resolve whichever exists.
  COBERTURA="$(find "${REPORT_DIR}" -maxdepth 3 -name cobertura.xml 2> /dev/null | head -1)"
  if [ -z "${COBERTURA}" ] || [ ! -f "${COBERTURA}" ]; then
    printf 'bash-coverage.sh: kcov produced no cobertura.xml (rc=%s); see %s/kcov.log\n' \
      "${kcov_rc}" "${REPORT_DIR}" >&2
    return 2
  fi
  return 0
}

# --- What each mode collects, then the single shared verdict ------------------

case "${TARGET}" in
  bats)
    # The one mode that runs where kcov cannot. No kcov means no denominator,
    # so this reports hit counts for gap-finding and gates on nothing.
    trace_bats || exit $?
    printf 'Statements traced per file (no denominator without kcov — not a gate):\n'
    awk -F: '{ n = split($1, p, "/"); c[p[n - 2] "/" p[n - 1] "/" p[n]]++ }
             END { for (f in c) printf "  %5d  %s\n", c[f], f }' "${TRACED}" | sort -k1 -n
    exit 0
    ;;
  conformance)
    require_kcov || exit $?
    run_kcov || exit $?
    ;;
  full)
    require_kcov || exit $?
    run_kcov || exit $?
    trace_bats || exit $?
    ;;
esac

merge_report "${COBERTURA}" "${TRACED}" "${THRESHOLD}"
exit $?
