#!/usr/bin/env bats
# T018 (partial) [018] — Contract test for the concurrency OVERRIDE half of
# contracts/conformance-runner.md R4: "the in-step concurrency is the host
# default unless SPEC_KIT_JIRA_CONFORMANCE_JOBS overrides it." Written and
# observed to FAIL before the override existed (Constitution XIII TDD).
#
# This file intentionally does NOT yet assert R4's other clause — "on MSYS
# the default may exceed 2 only with a recorded probe run" — because that
# clause names a specific degree only T026's probe run can supply. Pulled
# forward from Phase 3 (T018/T021) because T010's W2 measurement (corpus
# survival at concurrency 3 and 4, on the real Windows probe) has no way to
# ask for a specific degree without this override existing first; see
# baseline.md's note on this dependency. T018 extends this file with the
# proven-degree assertion once T026 supplies the number.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  WORKDIR="$(mktemp -d)"
  mkdir -p "${WORKDIR}/tests/conformance/scenarios"
  cp -R "${ROOT}/tests/conformance/." "${WORKDIR}/tests/conformance/"
  rm -rf "${WORKDIR}/tests/conformance/scenarios"
  mkdir -p "${WORKDIR}/tests/conformance/scenarios"
  OVERLAP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORKDIR}" "${OVERLAP_DIR}"
}

_write_scenarios() {
  local n="$1" i
  for ((i = 1; i <= n; i++)); do
    printf '{"name":"stub-%d"}\n' "${i}" > "${WORKDIR}/tests/conformance/scenarios/stub-${i}.json"
  done
}

# A harness stub that records its own [start,end] interval (both legs
# combined) under a name derived from the scenario, so the test can count how
# many intervals overlap at any instant — the observable signature of actual
# concurrency, independent of timing noise on a shared CI host.
_install_overlap_harness() {
  cat > "${WORKDIR}/tests/conformance/run-scenario.sh" << EOF
#!/usr/bin/env bash
set -euo pipefail
scenario="\$1"
outdir="\$3"
name="\$(basename "\${scenario}" .json)"
printf '%s\n' "\${EPOCHREALTIME}" > "${OVERLAP_DIR}/\${name}.\$2.start"
sleep 0.3
printf '%s\n' "\${EPOCHREALTIME}" > "${OVERLAP_DIR}/\${name}.\$2.end"
printf 'ok\n' > "\${outdir}/stdout"
printf '0\n' > "\${outdir}/exit"
: > "\${outdir}/calls.log"
mkdir -p "\${outdir}/workdir"
printf '0.001\n' > "\${outdir}/duration"
EOF
  chmod +x "${WORKDIR}/tests/conformance/run-scenario.sh"
}

# Max simultaneous [start,end] intervals across all recorded legs — no
# dependency beyond sort/awk (this repo's bats+jq-only test convention,
# AGENTS.md): a +1 event per start, a -1 event per end, sorted by timestamp,
# running sum's peak.
_max_overlap() {
  {
    for f in "${OVERLAP_DIR}"/*.start; do
      [ -e "${f}" ] || continue
      printf '%s 1\n' "$(cat "${f}")"
    done
    for f in "${OVERLAP_DIR}"/*.end; do
      [ -e "${f}" ] || continue
      printf '%s -1\n' "$(cat "${f}")"
    done
  } | sort -n | awk '{ cur += $2; if (cur > peak) peak = cur } END { print peak }'
}

@test "R4: SPEC_KIT_JIRA_CONFORMANCE_JOBS=1 forces serial execution (no overlap)" {
  _write_scenarios 6
  _install_overlap_harness
  run env -C "${WORKDIR}" SPEC_KIT_JIRA_CONFORMANCE_JOBS=1 bash tests/conformance/ci-conformance.sh
  [ "$status" -eq 0 ]
  peak="$(_max_overlap)"
  [ "${peak}" -eq 1 ]
}

@test "R4: SPEC_KIT_JIRA_CONFORMANCE_JOBS overrides the host default upward" {
  _write_scenarios 6
  _install_overlap_harness
  run env -C "${WORKDIR}" SPEC_KIT_JIRA_CONFORMANCE_JOBS=6 bash tests/conformance/ci-conformance.sh
  [ "$status" -eq 0 ]
  peak="$(_max_overlap)"
  [ "${peak}" -gt 1 ]
}
