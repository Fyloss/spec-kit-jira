#!/usr/bin/env bash
# T009 — Conformance harness.
#
#   run-scenario.sh <scenario.json> <bash|powershell> [outdir]
#
# Runs one port's entry point against a scenario and captures everything needed
# for a byte-identical cross-port comparison (NFR-1): stdout, stderr, exit code,
# the Jira API call sequence, and the full post-run repository tree. Run the
# same scenario against both ports into two outdirs and `diff -r` them; any
# divergence is a failing conformance test, not a documented quirk.
#
# Scenario schema — see scenarios/README.md. Fields:
#   name    (string)         informational
#   mock    (object)         mock-jira config (projects / faults / fault)
#   fixture (string, opt)    repo dir (relative to repo root) copied into the workdir
#   argv    (array,  opt)    arguments passed to the entry point
#   env     (object, opt)    extra environment variables for the run
#
# The entry point defaults to the canonical port path but can be overridden with
# SPEC_KIT_JIRA_ENTRY_BASH / SPEC_KIT_JIRA_ENTRY_PWSH (used to pin paths in CI
# and to exercise this harness before the real dispatcher lands, T024).
#
# Captured layout (in outdir): stdout, stderr, exit, calls.log, workdir/.

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: run-scenario.sh <scenario.json> <bash|powershell> [outdir]" >&2
  exit 1
fi

SCENARIO="$1"
PORT="$2"
OUTDIR="${3:-$(mktemp -d)}"

CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CONF_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${CONF_DIR}/mock-jira/lib.sh"

[ -f "${SCENARIO}" ] || { echo "scenario not found: ${SCENARIO}" >&2; exit 1; }
mkdir -p "${OUTDIR}"

case "${PORT}" in
  bash)
    ENTRY="${SPEC_KIT_JIRA_ENTRY_BASH:-${REPO_ROOT}/scripts/bash/spec-kit-jira.sh}"
    ;;
  powershell)
    ENTRY="${SPEC_KIT_JIRA_ENTRY_PWSH:-${REPO_ROOT}/scripts/powershell/spec-kit-jira.ps1}"
    ;;
  *)
    echo "unknown port: ${PORT} (expected bash|powershell)" >&2
    exit 1
    ;;
esac
[ -f "${ENTRY}" ] || { echo "entry point not found: ${ENTRY}" >&2; exit 1; }

# Are we git-bash (MSYS) on Windows, about to spawn a NATIVE pwsh.exe? That one
# combination mistranslates a bash argv array into a Windows command line and
# needs the wrapper below; every other host takes the plain invocation. Both
# conditions are required — cygpath also exists under Cygwin, where `uname`
# reports CYGWIN and this translation does not apply the same way.
MSYS_PWSH=""
case "$(uname -s 2> /dev/null || true)" in
  MINGW* | MSYS*) command -v cygpath > /dev/null 2>&1 && MSYS_PWSH=1 ;;
esac

# --- Isolated workdir (the "repository" the port runs against) ---------------
WORKDIR="$(mktemp -d)"
FIXTURE="$(jq -r '.fixture // empty' "${SCENARIO}")"
if [ -n "${FIXTURE}" ]; then
  [ -d "${REPO_ROOT}/${FIXTURE}" ] || { echo "fixture not found: ${FIXTURE}" >&2; exit 1; }
  cp -R "${REPO_ROOT}/${FIXTURE}/." "${WORKDIR}/"
fi

# --- Mock double -------------------------------------------------------------
MOCK_CFG="$(mktemp)"
jq '.mock // {}' "${SCENARIO}" > "${MOCK_CFG}"
mock_start "${MOCK_CFG}"
# Recorded so a caller can identify THIS run's mock precisely — a name-pattern
# scan (pgrep -f mock-server.ps1) also matches every other scenario's mock
# running concurrently under a parallel test suite.
echo "${MOCK_PID}" > "${OUTDIR}/mock.pid"
# From here on every exit path reaps the mock, including the ones `set -e` takes
# on our behalf. An orphan holds each descriptor it inherited, and whoever reads
# the other end then blocks forever rather than failing.
trap mock_stop EXIT

# --- Optional git repository (degraded-mode / branch-state scenarios) --------
# `git_branch` initialises the workdir as a git repo checked out on that branch
# (deterministic default branch so both ports see identical refs).
GIT_BRANCH="$(jq -r '.git_branch // empty' "${SCENARIO}")"
if [ -n "${GIT_BRANCH}" ]; then
  (
    cd "${WORKDIR}"
    git init -q -b main
    git -c user.email=conformance@example.invalid -c user.name=conformance \
      commit -q --allow-empty -m init
    git checkout -q -b "${GIT_BRANCH}"
  )
fi

# --- Environment -------------------------------------------------------------
# The mock base URL is set FIRST so a scenario's env can override it (e.g. to
# the empty string, which the ports treat as unset — the degraded-mode trigger).
export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
while IFS=$'\t' read -r key value; do
  [ -n "${key}" ] && export "${key}=${value}"
done < <(jq -r '(.env // {}) | to_entries[] | [.key, (.value | tostring)] | @tsv' "${SCENARIO}")

# --- Runs ----------------------------------------------------------------
# A scenario is either a single implicit run (top-level `argv`, unchanged
# behaviour) or an explicit `runs` array — each entry its own `argv` — for
# proving a SECOND invocation's behaviour against state the FIRST left
# behind (US1 idempotency, US2 zero churn): both runs share one workdir and
# one mock process. Captured as stdout.N / stderr.N / exit.N, N = 1-based;
# stdout/stderr/exit (unsuffixed) always mirror the LAST run, so a
# single-run scenario's existing consumers see no difference.
RUN_COUNT="$(jq '(.runs // []) | length' "${SCENARIO}")"
if [ "${RUN_COUNT}" -eq 0 ]; then RUN_COUNT=1; fi

set +e
for ((i = 1; i <= RUN_COUNT; i++)); do
  ARGV=()
  if [ "${RUN_COUNT}" -gt 1 ] || [ "$(jq '(.runs // []) | length' "${SCENARIO}")" -gt 0 ]; then
    while IFS= read -r arg; do ARGV+=("${arg}"); done < <(jq -r --argjson i "$((i - 1))" '.runs[$i].argv[]? // empty' "${SCENARIO}")
  else
    while IFS= read -r arg; do ARGV+=("${arg}"); done < <(jq -r '.argv[]? // empty' "${SCENARIO}")
  fi

  if [ "${PORT}" = "bash" ]; then
    if [ -n "${SPEC_KIT_JIRA_COVERAGE_INPROCESS:-}" ]; then
      # Coverage mode only (T097): kcov's bash tracing follows forked subshells but
      # NOT execve'd children, so `bash "${ENTRY}"` measures nothing. Sourcing the
      # entry point in a subshell keeps every observable identical — own cwd, own
      # argv, own redirections, own exit status, and `set -euo pipefail` scoped to
      # the subshell — while making scripts/bash/** visible to the tracer.
      # stderr is deliberately NOT captured in this mode: the tracer streams its
      # PS4 trace on fd 2, so redirecting fd 2 to a file would hide every executed
      # line from it. Coverage mode asserts nothing about stderr.
      # shellcheck source=/dev/null
      ( cd "${WORKDIR}" && source "${ENTRY}" ${ARGV[@]+"${ARGV[@]}"} ) > "${OUTDIR}/stdout.${i}"
      : > "${OUTDIR}/stderr.${i}"
    else
      ( cd "${WORKDIR}" && bash "${ENTRY}" ${ARGV[@]+"${ARGV[@]}"} ) > "${OUTDIR}/stdout.${i}" 2> "${OUTDIR}/stderr.${i}"
    fi
  elif [ -z "${MSYS_PWSH:-}" ]; then
    # The plain invocation, unchanged since T009 and green on Linux and macOS
    # for this project's whole history. Everywhere except git-bash-on-Windows
    # this is exactly right, so it stays the default: the workaround below can
    # only ever regress the platform it was written for.
    ( cd "${WORKDIR}" && pwsh -NoProfile -File "${ENTRY}" ${ARGV[@]+"${ARGV[@]}"} ) > "${OUTDIR}/stdout.${i}" 2> "${OUTDIR}/stderr.${i}"
  else
    # git-bash (MSYS) on Windows ONLY. Spawning the NATIVE pwsh.exe with
    # `-File <path> <args...>` loses or mangles trailing simple-word arguments
    # in MSYS's argv-to-Windows-command-line translation, so the entry point
    # and argv travel in FILES and pwsh's command line carries nothing but the
    # wrapper's own path. cygpath spells those paths the way pwsh.exe reads
    # them — bash here speaks POSIX ("/d/a/repo/..."), which it cannot resolve.
    entry_native="$(cygpath -w "${ENTRY}")"
    printf '%s' "${entry_native}" > "${OUTDIR}/entry.${i}"
    printf '%s\n' ${ARGV[@]+"${ARGV[@]}"} > "${OUTDIR}/argv.${i}"
    ( cd "${WORKDIR}" \
      && SPEC_KIT_JIRA_HARNESS_ENTRYFILE="$(cygpath -w "${OUTDIR}/entry.${i}")" \
         SPEC_KIT_JIRA_HARNESS_ARGVFILE="$(cygpath -w "${OUTDIR}/argv.${i}")" \
         pwsh -NoProfile -File "$(cygpath -w "${CONF_DIR}/pwsh-invoke.ps1")" \
    ) > "${OUTDIR}/stdout.${i}" 2> "${OUTDIR}/stderr.${i}"
  fi
  echo "$?" > "${OUTDIR}/exit.${i}"
done
set -e
cp "${OUTDIR}/stdout.${RUN_COUNT}" "${OUTDIR}/stdout"
cp "${OUTDIR}/stderr.${RUN_COUNT}" "${OUTDIR}/stderr"
cp "${OUTDIR}/exit.${RUN_COUNT}" "${OUTDIR}/exit"

mock_stop
cp "${MOCK_CALLLOG}" "${OUTDIR}/calls.log" 2> /dev/null || : > "${OUTDIR}/calls.log"

# --- Snapshot the post-run repository tree (written files) -------------------
rm -rf "${OUTDIR}/workdir"
mkdir -p "${OUTDIR}/workdir"
( cd "${WORKDIR}" && find . -path ./.git -prune -o -type f -print0 | while IFS= read -r -d '' f; do
  mkdir -p "${OUTDIR}/workdir/$(dirname "${f}")"
  cp "${f}" "${OUTDIR}/workdir/${f}"
done )

echo "${OUTDIR}"
