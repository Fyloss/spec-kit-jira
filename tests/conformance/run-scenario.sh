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
#   steps   (array,  opt)    MULTI-COMMAND scenarios: [{argv:[...], env:{...}}, …]
#                            run in order against the SAME workdir and the SAME
#                            mock, so a sequence such as adopt -> reconcile ->
#                            reconcile is one comparable capture. Each step's
#                            `env` is layered over the scenario's. stdout and
#                            stderr accumulate; `exit` carries one code per step,
#                            LF-separated. `argv` and `steps` are mutually
#                            exclusive; with `argv` the capture is exactly as
#                            before (one command, one exit line).
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

# --- Run and capture ---------------------------------------------------------
# run_step <step-json> — execute one command, APPENDING its stdout/stderr to the
# capture and its exit code to the exit file. The step's own `env` is exported
# for that command only, so a sequence can vary the seams (plan context,
# lifecycle facts) between steps.
run_step() {
  local step="$1"
  local -a argv=()
  while IFS= read -r arg; do argv+=("${arg}"); done < <(jq -r '.argv[]? // empty' <<< "${step}")

  local -a envkeys=()
  while IFS=$'\t' read -r key value; do
    [ -n "${key}" ] || continue
    envkeys+=("${key}")
    export "${key}=${value}"
  done < <(jq -r '(.env // {}) | to_entries[] | [.key, (.value | tostring)] | @tsv' <<< "${step}")

  set +e
  if [ "${PORT}" = "bash" ]; then
    if [ -n "${SPEC_KIT_JIRA_COVERAGE_INPROCESS:-}" ]; then
      # Coverage mode only (T097): kcov's bash tracing follows forked subshells
      # but NOT execve'd children, so `bash "${ENTRY}"` measures nothing.
      # Sourcing the entry point in a subshell keeps every observable identical —
      # own cwd, own argv, own redirections, own exit status, and
      # `set -euo pipefail` scoped to the subshell — while making
      # scripts/bash/** visible to the tracer. stderr is deliberately NOT
      # captured in this mode: the tracer streams its PS4 trace on fd 2, so
      # redirecting fd 2 to a file would hide every executed line from it.
      # shellcheck source=/dev/null
      ( cd "${WORKDIR}" && source "${ENTRY}" ${argv[@]+"${argv[@]}"} ) >> "${OUTDIR}/stdout"
    else
      ( cd "${WORKDIR}" && bash "${ENTRY}" ${argv[@]+"${argv[@]}"} ) >> "${OUTDIR}/stdout" 2>> "${OUTDIR}/stderr"
    fi
  else
    ( cd "${WORKDIR}" && pwsh -NoProfile -File "${ENTRY}" ${argv[@]+"${argv[@]}"} ) >> "${OUTDIR}/stdout" 2>> "${OUTDIR}/stderr"
  fi
  echo "$?" >> "${OUTDIR}/exit"
  set -e

  local k
  for k in ${envkeys[@]+"${envkeys[@]}"}; do unset "${k}"; done
}

: > "${OUTDIR}/stdout"
: > "${OUTDIR}/stderr"
: > "${OUTDIR}/exit"

if [ "$(jq -r 'has("steps")' "${SCENARIO}")" = "true" ]; then
  while IFS= read -r step; do
    [ -n "${step}" ] || continue
    run_step "${step}"
  done < <(jq -c '.steps[]' "${SCENARIO}")
else
  run_step "$(jq -c '{argv: (.argv // [])}' "${SCENARIO}")"
fi

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
