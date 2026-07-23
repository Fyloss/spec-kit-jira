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
    ENTRY="${SPEC_KIT_JIRA_ENTRY_BASH:-${REPO_ROOT}/.specify/extensions/jira/scripts/bash/spec-kit-jira.sh}"
    ;;
  powershell)
    ENTRY="${SPEC_KIT_JIRA_ENTRY_PWSH:-${REPO_ROOT}/.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1}"
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

# --- Environment -------------------------------------------------------------
while IFS=$'\t' read -r key value; do
  [ -n "${key}" ] && export "${key}=${value}"
done < <(jq -r '(.env // {}) | to_entries[] | [.key, (.value | tostring)] | @tsv' "${SCENARIO}")
export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

# --- Argv --------------------------------------------------------------------
ARGV=()
while IFS= read -r arg; do ARGV+=("${arg}"); done < <(jq -r '.argv[]? // empty' "${SCENARIO}")

# --- Run and capture ---------------------------------------------------------
set +e
if [ "${PORT}" = "bash" ]; then
  ( cd "${WORKDIR}" && bash "${ENTRY}" ${ARGV[@]+"${ARGV[@]}"} ) > "${OUTDIR}/stdout" 2> "${OUTDIR}/stderr"
else
  ( cd "${WORKDIR}" && pwsh -NoProfile -File "${ENTRY}" ${ARGV[@]+"${ARGV[@]}"} ) > "${OUTDIR}/stdout" 2> "${OUTDIR}/stderr"
fi
echo "$?" > "${OUTDIR}/exit"
set -e

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
