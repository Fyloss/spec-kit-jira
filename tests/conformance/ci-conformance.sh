#!/usr/bin/env bash
# tests/conformance/ci-conformance.sh — runs the whole conformance corpus
# against both ports and diffs the captures (NFR-1). Extracted out of
# .github/workflows/ci.yml (008 T103) so the SAME script runs on every host
# in the three-OS matrix, not just Linux — a divergence that only a real
# Windows or macOS host exposes (path separators, line endings, shell
# quoting) is exactly what a single-OS conformance run cannot catch.
#
# When THIS script fails on windows-latest and nowhere else, do not reach for a
# local emulation of Windows: two were tried (a stub jq on PATH reproducing
# jq.exe's text-mode CRLF stdout, and the CR guard in lib/output.sh forced on
# against the real jq) and both passed the whole corpus while the runner failed
# fifteen scenarios. Use .github/workflows/windows-conformance.yml instead — it
# runs this script, and only this script, on a real Windows host from a
# throwaway branch, without opening a pull request. Its header carries the
# invocation.
# Every function here reaches its call site indirectly — through `bash -c`
# under xargs, or from a function that does — which shellcheck reads as never
# invoked.
# shellcheck disable=SC2329
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
harness="${ROOT}/tests/conformance/run-scenario.sh"
scenarios=("${ROOT}"/tests/conformance/scenarios/*.json)
if [ ${#scenarios[@]} -eq 0 ]; then
  echo "conformance corpus is empty — nothing to compare (scenarios land per user story)"
  exit 0
fi

# Optional sharding, for a matrix of runners splitting one corpus.
#
# On windows-latest the corpus is the whole cost — 33 of a 33-minute job, with
# setup and checkout accounting for eight seconds between them — and the reason
# is structural: every scenario pays for a PowerShell mock server, a native
# pwsh.exe and MSYS's emulated fork, on a host where the in-runner parallelism
# is capped at 2 because a wider fan-out killed the runner outright. Splitting
# across runners buys back the wall clock that cap costs without reintroducing
# the pressure that made it necessary.
#
# The slice is round-robin rather than contiguous: the glob is alphabetical, so
# scenarios cluster by user story, and consecutive blocks would hand one runner
# every reconcile case (four HTTP writes and a second run apiece) while another
# gets a handful of refusals that exit before their first request.
shard_total="${SPEC_KIT_JIRA_SHARD_TOTAL:-1}"
shard_index="${SPEC_KIT_JIRA_SHARD_INDEX:-0}"
if [ "${shard_total}" -gt 1 ]; then
  sharded=()
  for i in "${!scenarios[@]}"; do
    [ "$((i % shard_total))" -eq "${shard_index}" ] && sharded+=("${scenarios[i]}")
  done
  scenarios=(${sharded[@]+"${sharded[@]}"})
  printf 'shard %s of %s — %s scenarios\n' "${shard_index}" "${shard_total}" "${#scenarios[@]}"
  if [ ${#scenarios[@]} -eq 0 ]; then
    echo "this shard has no scenarios — nothing to compare"
    exit 0
  fi
fi

# One report file per failing scenario, folded into a SINGLE annotation at the
# end (see the summary block). Per-scenario annotations were the obvious shape
# and the wrong one: GitHub keeps only the first ten per check run, so with
# fifteen scenarios failing the later ones vanish.
#
# Which is also why the per-scenario lines below are plain output and NOT
# `::error::`. Emitting both was tried on the first real Windows probe: the ten
# per-scenario annotations consumed the whole budget and the summary — the one
# carrying the actual bytes, and the only channel that survives a job log
# needing admin rights to read — was dropped on the floor.
REPORT_DIR="$(mktemp -d)"
# One empty marker file per scenario that actually completed inside
# run_scenario, written unconditionally on both the pass and the fail path
# (R5/R6). This is deliberately independent of REPORT_DIR, which only ever
# held failures: a worker that is killed mid-flight — by the host, not by a
# scenario divergence — leaves no marker here, so a verdict shortfall is
# detected even when nothing about the diff itself went wrong.
VERDICT_DIR="$(mktemp -d)"
# One "<bash> <pwsh>" line per scenario, in seconds, read from the duration
# file run-scenario.sh writes per port leg (R9). SC-009's amortised cost is
# derived from this directory's total, published beside the wall-clock rather
# than left for the next corpus growth to discover the hard way.
TIMING_DIR="$(mktemp -d)"
trap 'rm -rf "${REPORT_DIR}" "${VERDICT_DIR}" "${TIMING_DIR}"' EXIT
export REPORT_DIR VERDICT_DIR TIMING_DIR
SCRIPT_T0="${EPOCHREALTIME}"

# Portable core count: nproc (Linux), sysctl (macOS), NUMBER_OF_PROCESSORS
# (set by every GitHub-hosted Windows runner) — falls back to 4 rather than
# failing when none of the above resolves.
#
# Git-bash on Windows is capped hard, and deliberately. A scenario there costs
# far more than a process: MSYS emulates fork, every scenario spawns a
# PowerShell mock server plus a native pwsh.exe, and the text-mode-jq guard in
# lib/output.sh doubles the process count of the Bash port on that host alone.
# Run unthrottled, the windows-latest job died with "the hosted runner lost
# communication with the server" partway through the corpus — which also meant
# the divergences after that point were never reported at all, and a partial
# log read as a short list of failures rather than a truncated one.
core_count() {
  # R4 (NEW): an explicit override always wins, on every host — this is the
  # probe's own knob for asking "does concurrency N survive" without moving
  # the MSYS default, and is unused by ci.yml (guarded by
  # test_conformance_no_cross_os_shard.bats's cross-OS-shard sibling check).
  if [[ "${SPEC_KIT_JIRA_CONFORMANCE_JOBS:-}" =~ ^[0-9]+$ ]] && [ "${SPEC_KIT_JIRA_CONFORMANCE_JOBS}" -gt 0 ]; then
    printf '%s' "${SPEC_KIT_JIRA_CONFORMANCE_JOBS}"
    return 0
  fi
  case "$(uname -s 2> /dev/null || true)" in
    MINGW* | MSYS* | CYGWIN*) printf '2'; return 0 ;;
  esac
  if command -v nproc > /dev/null 2>&1; then nproc
  elif command -v sysctl > /dev/null 2>&1; then sysctl -n hw.ncpu
  elif [ -n "${NUMBER_OF_PROCESSORS:-}" ]; then printf '%s' "${NUMBER_OF_PROCESSORS}"
  else printf '4'
  fi
}

# _size <file> — the file's length in bytes, or `absent`.
_size() {
  if [ -f "$1" ]; then wc -c < "$1" | tr -d '[:space:]'; else printf 'absent'; fi
}

# _byte_at <file> <1-based offset> — that byte in hex, or `EOF` past the end.
_byte_at() {
  local hex
  hex="$(dd if="$1" bs=1 skip="$(($2 - 1))" count=1 2> /dev/null | od -An -tx1 | tr -d '[:space:]')"
  if [ -n "${hex}" ]; then printf '%s' "${hex}"; else printf 'EOF'; fi
}

# byte_diff <label> <bash-capture> <pwsh-capture> — one line naming the FIRST
# differing byte and both sides' lengths.
#
# `diff -u` is what a reader wants when the two sides differ in CONTENT, and it
# is useless when they differ in a byte that does not render: the divergence
# that started this — a CRLF where the twin wrote LF — printed fifty-five
# identical-looking lines on both sides of the diff and named nothing. The hex
# here is the part that cannot be misread.
byte_diff() {
  local label="$1" a="$2" b="$3" loc off
  loc="$(cmp "${a}" "${b}" 2>&1 || true)"
  # Both spellings on purpose: GNU cmp reports "byte 9", BSD cmp "char 9". A
  # pattern for one of them alone reads as "no offset found" on the other host,
  # which is how a report meant to survive a cross-platform diff would have
  # gone quiet on exactly half the platforms it exists for.
  off="$(printf '%s' "${loc}" | sed -E -n 's/.*(byte|char) ([0-9]+).*/\2/p')"
  # cmp names both captures by absolute path; the reader wants the port.
  loc="${loc//${a}/bash}"
  loc="${loc//${b}/pwsh}"
  if [ -n "${off}" ]; then
    printf '  %s: first difference at byte %s — bash=%s pwsh=%s (sizes %s / %s)\n' \
      "${label}" "${off}" "$(_byte_at "${a}" "${off}")" "$(_byte_at "${b}" "${off}")" \
      "$(_size "${a}")" "$(_size "${b}")"
  else
    printf '  %s: %s (sizes %s / %s)\n' \
      "${label}" "${loc}" "$(_size "${a}")" "$(_size "${b}")"
  fi
}
export -f _size _byte_at byte_diff

# Scenarios are independent (each gets its own mktemp workdir and an
# OS-assigned ephemeral mock port, per run-scenario.sh), so they run
# concurrently across cores instead of one after another. xargs -P exits 123
# if any invocation of run_scenario fails, which this script turns into its
# own failure below — no manual result-collection needed.
run_scenario() {
  local scenario="$1" name out_bash out_ps failed=0 detail="" line f rel bash_dur ps_dur
  name="$(basename "${scenario}" .json)"
  out_bash="$(mktemp -d)"
  out_ps="$(mktemp -d)"
  "${harness}" "${scenario}" bash "${out_bash}"
  "${harness}" "${scenario}" powershell "${out_ps}"
  # R9/W3: each leg's own duration, as run-scenario.sh recorded it — read
  # here rather than timed around the call above, so the number reflects the
  # harness's cost (mock start, the port invocation, the workdir snapshot),
  # not this function's own overhead.
  bash_dur="$(cat "${out_bash}/duration" 2> /dev/null || printf '?')"
  ps_dur="$(cat "${out_ps}/duration" 2> /dev/null || printf '?')"
  printf 'timing: %s bash=%ss pwsh=%ss\n' "${name}" "${bash_dur}" "${ps_dur}"
  printf '%s %s\n' "${bash_dur}" "${ps_dur}" > "${TIMING_DIR}/${name}"
  # The observable contract: stdout, exit code, Jira call sequence, and the
  # written repository tree must be byte-identical across ports.
  for artifact in stdout exit calls.log; do
    if ! diff -u "${out_bash}/${artifact}" "${out_ps}/${artifact}"; then
      echo "conformance divergence in ${name} (${artifact})"
      detail="${detail}$(byte_diff "${artifact}" "${out_bash}/${artifact}" "${out_ps}/${artifact}")"$'\n'
      failed=1
    fi
  done
  if ! diff -ru "${out_bash}/workdir" "${out_ps}/workdir"; then
    echo "conformance divergence in ${name} (written files)"
    while IFS= read -r line; do
      case "${line}" in
        "Files "*" and "*" differ")
          f="${line#Files }"
          f="${f%% and *}"
          rel="${f#"${out_bash}/workdir/"}"
          detail="${detail}$(byte_diff "workdir/${rel}" "${f}" "${out_ps}/workdir/${rel}")"$'\n'
          ;;
        *) detail="${detail}  ${line}"$'\n' ;;
      esac
    done < <(diff -rq "${out_bash}/workdir" "${out_ps}/workdir" 2>&1 || true)
    failed=1
  fi
  if [ "${failed}" -ne 0 ]; then
    { printf '%s\n' "${name}"; printf '%s' "${detail}"; } > "${REPORT_DIR}/${name}"
  fi
  # Written LAST, and unconditionally on both the pass and the fail path: a
  # worker killed before reaching this line (R5's "produces no result") leaves
  # no marker, which is exactly the shortfall R6 counts against the corpus.
  : > "${VERDICT_DIR}/${name}"
  return "${failed}"
}
export -f run_scenario
export harness

status=0
printf '%s\n' "${scenarios[@]}" \
  | xargs -P "$(core_count)" -I{} bash -c 'run_scenario "$@"' _ {} || status=$?

# R6: the verdict count is printed and checked against the corpus size,
# independent of `status` above — a worker that xargs itself lost (killed,
# never scheduled) would otherwise report only through xargs's own exit code,
# with nothing naming which scenario went missing.
verdicts=("${VERDICT_DIR}"/*)
verdict_count=${#verdicts[@]}
scenario_count=${#scenarios[@]}
printf 'verdicts: %s/%s\n' "${verdict_count}" "${scenario_count}"
if [ "${verdict_count}" -lt "${scenario_count}" ]; then
  missing=()
  for s in "${scenarios[@]}"; do
    n="$(basename "${s}" .json)"
    [ -e "${VERDICT_DIR}/${n}" ] || missing+=("${n}")
  done
  printf '::error title=Conformance worker accounting::%s of %s scenarios reported no verdict: %s\n' \
    "$((scenario_count - verdict_count))" "${scenario_count}" "${missing[*]}"
  status=1
fi

# SC-009: the amortised per-scenario cost, published beside the wall-clock so
# the next corpus growth can be sized before it turns a budget red. Summed
# from TIMING_DIR rather than re-derived from the wall-clock alone, since the
# wall-clock reflects the chosen concurrency and the per-scenario figure must
# not.
SCRIPT_T1="${EPOCHREALTIME}"
wall_clock="$(awk -v a="${SCRIPT_T0}" -v b="${SCRIPT_T1}" 'BEGIN { printf "%.3f", b - a }')"
if [ "${scenario_count}" -gt 0 ]; then
  amortised="$(cat "${TIMING_DIR}"/* 2> /dev/null \
    | awk -v n="${scenario_count}" '{ sum += $1 + $2 } END { printf "%.3f", (n > 0 ? sum / n : 0) }')"
  printf 'amortised per-scenario cost: %ss (wall-clock %ss / %s scenarios)\n' \
    "${amortised}" "${wall_clock}" "${scenario_count}"
fi

# One annotation carrying the whole report. A workflow command is a single
# line, so the newlines are percent-encoded (`%` first, or the encoding would
# eat its own escapes); GitHub renders them back.
reports=("${REPORT_DIR}"/*)
if [ ${#reports[@]} -gt 0 ]; then
  summary="$(cat "${reports[@]}")"
  printf '\n===== byte-level divergence report (%s scenarios) =====\n%s\n' \
    "${#reports[@]}" "${summary}"
  printf '::error title=Conformance divergence (%s scenarios)::%s\n' \
    "${#reports[@]}" \
    "$(printf '%s' "${summary}" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN { ORS = "" } { print $0 "%0A" }')"
fi

exit "${status}"
