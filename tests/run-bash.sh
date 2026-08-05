#!/usr/bin/env bash
# T011/T011b [009, US1] — dependency-free parallel Bash test runner.
# Replaces `bats --jobs` (which needs GNU `parallel` and silently runs 0
# tests without it — the defect FR-003/FR-015 exist to fix). See
# contracts/test-runner.md for the full contract.
#
#   tests/run-bash.sh [--since <ref>] [PATH ...]
#
# Internal dispatch mode (invoked by this script's own parallel fan-out, never
# by a caller directly): `run-bash.sh __run_one <file> <outdir>`.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# --- internal single-file worker (child process, own exit code) --------------
if [[ "${1:-}" == "__run_one" ]]; then
  file="$2"
  outdir="$3"
  safe="$(printf '%s' "${file}" | tr '/' '_')"
  log="${outdir}/${safe}.log"
  # This runner may itself be running under bats — the meta-tests in
  # tests/bash/ci do exactly that. An outer bats prepends its private libexec
  # dir to PATH (exported as BATS_LIBEXEC) and exports BATS_* state and
  # bats_* helper functions into every child. Debian/Ubuntu package that
  # libexec `bats` separately from the wrapper that prepares its environment,
  # so resolved bare it silently discovers 0 tests (`1..0`, exit 0). Start
  # the child bats from a clean slate: drop the injected dir from PATH, then
  # scrub the outer run's exported state.
  # A libexec dir is recognised two ways: it is the one the outer run named
  # in BATS_LIBEXEC, or it carries bats-core's internal executables (the
  # user-facing install puts only the `bats` wrapper on PATH; bats-exec-suite
  # lives in libexec alone).
  clean_path=""
  while IFS= read -r d; do
    [[ -z "${d}" ]] && continue
    [[ -n "${BATS_LIBEXEC:-}" && "${d%/}" == "${BATS_LIBEXEC%/}" ]] && continue
    [[ -e "${d}/bats-exec-suite" ]] && continue
    clean_path="${clean_path:+${clean_path}:}${d}"
  done < <(printf '%s' "${PATH}" | tr ':' '\n')
  PATH="${clean_path}"
  while IFS= read -r v; do unset "${v}"; done < <(compgen -A variable BATS_ || true)
  while IFS= read -r fn; do unset -f "${fn}"; done < <(compgen -A function bats_ || true)
  rc=0
  bats "${file}" > "${log}" 2>&1 || rc=$?
  printf '%s' "${rc}" > "${log}.rc"
  exit 0
fi

# --- CLI parsing ---------------------------------------------------------------

SINCE_REF=""
PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      SINCE_REF="${2:-}"
      shift 2
      ;;
    --since=*)
      SINCE_REF="${1#--since=}"
      shift
      ;;
    -h | --help)
      printf 'usage: %s [--since <ref>] [PATH ...]\n' "$(basename "${SELF}")"
      exit 0
      ;;
    *)
      PATHS+=("$1")
      shift
      ;;
  esac
done

ROOT="$(cd "$(dirname "${SELF}")/.." && pwd)"
DEFAULT_DIR="${ROOT}/tests/bash"
[[ ${#PATHS[@]} -eq 0 ]] && PATHS=("${DEFAULT_DIR}")

# --- discovery -------------------------------------------------------------

discover_files() {
  local p
  for p in "${PATHS[@]}"; do
    if [[ -d "${p}" ]]; then
      find "${p}" -type f -name '*.bats' | sort
    elif [[ -f "${p}" ]]; then
      printf '%s\n' "${p}"
    fi
  done
}

FILES=()
while IFS= read -r f; do [[ -n "${f}" ]] && FILES+=("${f}"); done < <(discover_files)

RUN_LABEL="FULL"

# --- change-scoped mode (--since, FR-017) — R1: local only, never from CI ----
#
# S2 fail-open: any doubt (bad ref, detached state, a shared-helper or
# runner change) runs the WHOLE discovered set above, unchanged. The diff is
# rooted at the CALLER's repository (CWD), never this script's own install
# location — the two differ under test, and could differ for a caller running
# the runner from an installed copy against a different checkout.
if [[ -n "${SINCE_REF}" ]]; then
  fail_open=0
  GIT_TOPLEVEL="$(git rev-parse --show-toplevel 2> /dev/null || true)"
  [[ -z "${GIT_TOPLEVEL}" ]] && fail_open=1

  if [[ "${fail_open}" -eq 0 ]]; then
    git -C "${GIT_TOPLEVEL}" rev-parse --verify --quiet "${SINCE_REF}^{commit}" > /dev/null 2>&1 || fail_open=1
  fi

  CHANGED=()
  if [[ "${fail_open}" -eq 0 ]]; then
    while IFS= read -r f; do [[ -n "${f}" ]] && CHANGED+=("${f}"); done \
      < <(git -C "${GIT_TOPLEVEL}" diff --name-only "${SINCE_REF}" -- . 2> /dev/null)
  fi

  SELECTED=()
  if [[ "${fail_open}" -eq 0 ]]; then
    for c in "${CHANGED[@]:-}"; do
      [[ -z "${c}" ]] && continue
      case "${c}" in
        # A shared helper, the mock backend, or the runner itself can affect
        # any test file — the affected set is undeterminable (S2).
        scripts/bash/lib/* | tests/bash/helpers/* | tests/conformance/mock-jira/* | tests/run-bash.sh)
          fail_open=1
          break
          ;;
        tests/bash/*.bats)
          SELECTED+=("${GIT_TOPLEVEL}/${c}")
          ;;
        scripts/bash/*)
          # Mirror scripts/bash/<module>/... onto tests/bash/<module>/ — the
          # nearest deterministic mapping without a full dependency graph.
          module="$(printf '%s' "${c}" | cut -d/ -f3)"
          if [[ -d "${GIT_TOPLEVEL}/tests/bash/${module}" ]]; then
            while IFS= read -r tf; do SELECTED+=("${tf}"); done \
              < <(find "${GIT_TOPLEVEL}/tests/bash/${module}" -type f -name '*.bats' | sort)
          fi
          ;;
        *) : ;; # a non-bash change (docs, workflows, ...) selects nothing on its own
      esac
    done
  fi

  if [[ "${fail_open}" -eq 1 ]]; then
    RUN_LABEL="FULL (--since could not determine an affected set — fail-open)"
  elif [[ ${#SELECTED[@]} -eq 0 ]]; then
    RUN_LABEL="FULL (--since selected nothing — fail-open, S3)"
  else
    # De-duplicate while preserving determinism.
    mapfile -t FILES < <(printf '%s\n' "${SELECTED[@]}" | sort -u)
    RUN_LABEL="PARTIAL RUN"
  fi
fi

TOTAL_FILES=${#FILES[@]}
if [[ "${TOTAL_FILES}" -eq 0 ]]; then
  printf 'run-bash.sh: ERROR: no test files discovered under %s — refusing to report success on 0 tests\n' "${PATHS[*]}" >&2
  exit 1
fi

# --- D5 (018, FR-009): LPT ordering from a committed timing profile ----------
#
# 149 uneven files on N workers leaves the makespan hostage to whichever
# heavy file starts last (research.md §4.1) — longest-processing-time-first
# ordering is the classic fix. The profile is a scheduling HINT ONLY: an
# absent or unreadable one falls back to the discovered (alphabetical)
# order rather than failing, and every discovered file still runs either
# way — this can reorder FILES, never filter it.
TIMINGS_PATH="${SPEC_KIT_JIRA_BATS_TIMINGS:-${ROOT}/tests/bash-suite-timings.txt}"
declare -A LPT_DURATIONS=()
if [[ -r "${TIMINGS_PATH}" ]]; then
  while IFS=$'\t' read -r _dur _path || [[ -n "${_dur}" ]]; do
    [[ -n "${_dur}" && -n "${_path}" ]] || continue
    LPT_DURATIONS["${_path}"]="${_dur}"
  done < "${TIMINGS_PATH}"
fi

if [[ "${#LPT_DURATIONS[@]}" -gt 0 ]]; then
  _lpt_duration() {
    local f="$1" rel
    if [[ -v "LPT_DURATIONS[${f}]" ]]; then
      printf '%s' "${LPT_DURATIONS[${f}]}"
      return
    fi
    rel="${f#"${ROOT}/"}"
    if [[ -v "LPT_DURATIONS[${rel}]" ]]; then
      printf '%s' "${LPT_DURATIONS[${rel}]}"
      return
    fi
    printf '0' # unprofiled (new since the profile was refreshed): unknown cost, sorts last
  }
  _lpt_lines=""
  for _f in "${FILES[@]}"; do
    _lpt_lines+="$(_lpt_duration "${_f}")"$'\t'"${_f}"$'\n'
  done
  mapfile -t FILES < <(printf '%s' "${_lpt_lines}" | sort -t $'\t' -k1,1 -rn | cut -f2-)
  printf 'run-bash.sh: ordering: LPT from %s (%d file(s) profiled)\n' "${TIMINGS_PATH}" "${#LPT_DURATIONS[@]}"
else
  printf 'run-bash.sh: ordering: no timing profile at %s — discovered order\n' "${TIMINGS_PATH}"
fi

printf 'run-bash.sh: mode: %s (%s)\n' "${RUN_LABEL}" "$(bats --version 2> /dev/null || printf 'bats not found')"
if [[ "${RUN_LABEL}" == "PARTIAL RUN" ]]; then
  printf 'run-bash.sh: selected %d file(s) (this is a PARTIAL RUN, not a full-suite verdict):\n' "${TOTAL_FILES}"
  printf '  %s\n' "${FILES[@]}"
fi

# --- execution: xargs -P, one bats per file; serial fallback ----------------

RESULTS_DIR="$(mktemp -d)"
trap 'rm -rf "${RESULTS_DIR}"' EXIT

# D5: workers are process-creation/IO-bound, not CPU-bound (research §4.1) —
# `-P core-count` leaves a 4-vCPU runner idle a large fraction of the time.
# SPEC_KIT_JIRA_BATS_JOBS is the probe's own knob (may exceed the core
# count deliberately); unset, the default oversubscribes by 3x.
JOBS="${SPEC_KIT_JIRA_BATS_JOBS:-}"
if [[ ! "${JOBS}" =~ ^[0-9]+$ ]] || [[ "${JOBS}" -lt 1 ]]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2> /dev/null || printf '1')"
  [[ "${JOBS}" =~ ^[0-9]+$ ]] || JOBS=1
  [[ "${JOBS}" -lt 1 ]] && JOBS=1
  JOBS=$((JOBS * 3))
fi
printf 'run-bash.sh: jobs: %s\n' "${JOBS}"

if command -v xargs > /dev/null 2>&1; then
  printf '%s\n' "${FILES[@]}" | xargs -P "${JOBS}" -I{} bash -c '
    "$1" __run_one "$2" "$3"
  ' _ "${SELF}" {} "${RESULTS_DIR}"
else
  for f in "${FILES[@]}"; do
    "${SELF}" __run_one "${f}" "${RESULTS_DIR}"
  done
fi

# --- aggregation -------------------------------------------------------------

TOTAL_TESTS=0
FAILED_FILES=0
EXECUTED_FILES=0
for f in "${FILES[@]}"; do
  safe="$(printf '%s' "${f}" | tr '/' '_')"
  log="${RESULTS_DIR}/${safe}.log"
  rcfile="${log}.rc"
  if [[ ! -f "${rcfile}" ]]; then
    printf 'run-bash.sh: ERROR: no result recorded for %s (worker never ran)\n' "${f}" >&2
    FAILED_FILES=$((FAILED_FILES + 1))
    continue
  fi
  EXECUTED_FILES=$((EXECUTED_FILES + 1))
  rc="$(cat "${rcfile}")"
  count="$(grep -m1 -E '^1\.\.[0-9]+$' "${log}" | sed -E 's/^1\.\.//')"
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  TOTAL_TESTS=$((TOTAL_TESTS + count))
  if [[ "${rc}" != "0" ]]; then
    FAILED_FILES=$((FAILED_FILES + 1))
    printf 'run-bash.sh: FAIL %s\n' "${f}"
    # The `#` diagnostic lines too, not just the verdicts: a failure that
    # only reproduces on a CI host is undebuggable from `not ok` alone.
    grep -E '^(not ok|# )' "${log}" | sed 's/^/  /'
  fi
done

printf 'run-bash.sh: summary: files executed: %d, tests executed: %d, files failed: %d\n' \
  "${EXECUTED_FILES}" "${TOTAL_TESTS}" "${FAILED_FILES}"

if [[ "${EXECUTED_FILES}" -eq 0 ]]; then
  printf 'run-bash.sh: ERROR: 0 files executed — refusing to report success\n' >&2
  exit 1
fi
if [[ "${TOTAL_TESTS}" -eq 0 ]]; then
  printf 'run-bash.sh: ERROR: 0 tests executed — refusing to report success\n' >&2
  exit 1
fi
if [[ "${FAILED_FILES}" -gt 0 ]]; then
  printf 'run-bash.sh: FAILED (%d file(s) failed)\n' "${FAILED_FILES}" >&2
  exit 1
fi

printf 'run-bash.sh: PASSED\n'
exit 0
