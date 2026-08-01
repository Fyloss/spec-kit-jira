#!/usr/bin/env bash
# tests/conformance/ci-conformance.sh — runs the whole conformance corpus
# against both ports and diffs the captures (NFR-1). Extracted out of
# .github/workflows/ci.yml (008 T103) so the SAME script runs on every host
# in the three-OS matrix, not just Linux — a divergence that only a real
# Windows or macOS host exposes (path separators, line endings, shell
# quoting) is exactly what a single-OS conformance run cannot catch.
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
harness="${ROOT}/tests/conformance/run-scenario.sh"
scenarios=("${ROOT}"/tests/conformance/scenarios/*.json)
if [ ${#scenarios[@]} -eq 0 ]; then
  echo "conformance corpus is empty — nothing to compare (scenarios land per user story)"
  exit 0
fi

# Portable core count: nproc (Linux), sysctl (macOS), NUMBER_OF_PROCESSORS
# (set by every GitHub-hosted Windows runner) — falls back to 4 rather than
# failing when none of the above resolves.
core_count() {
  if command -v nproc > /dev/null 2>&1; then nproc
  elif command -v sysctl > /dev/null 2>&1; then sysctl -n hw.ncpu
  elif [ -n "${NUMBER_OF_PROCESSORS:-}" ]; then printf '%s' "${NUMBER_OF_PROCESSORS}"
  else printf '4'
  fi
}

# Scenarios are independent (each gets its own mktemp workdir and an
# OS-assigned ephemeral mock port, per run-scenario.sh), so they run
# concurrently across cores instead of one after another. xargs -P exits 123
# if any invocation of run_scenario fails, which `set -e` below turns into
# this script's failure — no manual result-collection needed.
run_scenario() {
  local scenario="$1" name out_bash out_ps failed=0
  name="$(basename "${scenario}" .json)"
  out_bash="$(mktemp -d)"
  out_ps="$(mktemp -d)"
  "${harness}" "${scenario}" bash "${out_bash}"
  "${harness}" "${scenario}" powershell "${out_ps}"
  # The observable contract: stdout, exit code, Jira call sequence, and the
  # written repository tree must be byte-identical across ports.
  for artifact in stdout exit calls.log; do
    if ! diff -u "${out_bash}/${artifact}" "${out_ps}/${artifact}"; then
      echo "::error::conformance divergence in ${name} (${artifact})"
      failed=1
    fi
  done
  if ! diff -ru "${out_bash}/workdir" "${out_ps}/workdir"; then
    echo "::error::conformance divergence in ${name} (written files)"
    failed=1
  fi
  return "${failed}"
}
export -f run_scenario
export harness

printf '%s\n' "${scenarios[@]}" \
  | xargs -P "$(core_count)" -I{} bash -c 'run_scenario "$@"' _ {}
