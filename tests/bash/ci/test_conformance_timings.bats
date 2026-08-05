#!/usr/bin/env bats
# T006 [018, Phase 2] — Contract test for tests/conformance/ci-conformance.sh
# and tests/conformance/run-scenario.sh, per contracts/conformance-runner.md R9
# and SC-009. Written and observed to FAIL before T007 existed (Constitution
# XIII TDD).
#
# R9: per-scenario, per-port timings are emitted so amortised cost can be
#     published beside wall-clock.
#
# The harness contract under test is simple: run-scenario.sh writes a
# `duration` file (seconds, decimal) into its OUTDIR. This file stubs that
# contract directly rather than actually running the ports, so the test stays
# fast and deterministic; T007 is what makes the real run-scenario.sh honour
# it, and the full corpus re-run after T007 lands is where that half is
# checked.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  WORKDIR="$(mktemp -d)"
  mkdir -p "${WORKDIR}/tests/conformance/scenarios"
  cp -R "${ROOT}/tests/conformance/." "${WORKDIR}/tests/conformance/"
  rm -rf "${WORKDIR}/tests/conformance/scenarios"
  mkdir -p "${WORKDIR}/tests/conformance/scenarios"
}

teardown() {
  rm -rf "${WORKDIR}"
}

_write_scenarios() {
  local n="$1" i
  for ((i = 1; i <= n; i++)); do
    printf '{"name":"stub-%d"}\n' "${i}" > "${WORKDIR}/tests/conformance/scenarios/stub-${i}.json"
  done
}

# A harness stub honouring the `duration` file contract: bash legs report
# 0.100s, pwsh legs report 0.400s — deliberately unequal, so a summary that
# silently used only one port's figure would be caught.
_install_timed_harness() {
  cat > "${WORKDIR}/tests/conformance/run-scenario.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
port="$2"
outdir="$3"
printf 'ok\n' > "${outdir}/stdout"
printf '0\n' > "${outdir}/exit"
: > "${outdir}/calls.log"
mkdir -p "${outdir}/workdir"
if [ "${port}" = "bash" ]; then
  printf '0.100\n' > "${outdir}/duration"
else
  printf '0.400\n' > "${outdir}/duration"
fi
EOF
  chmod +x "${WORKDIR}/tests/conformance/run-scenario.sh"
}

@test "R9: each scenario reports a per-port duration" {
  _write_scenarios 1
  _install_timed_harness
  run env -C "${WORKDIR}" bash tests/conformance/ci-conformance.sh
  [ "$status" -eq 0 ]
  [[ "${output}" =~ timing:\ stub-1\ bash=0\.100s\ pwsh=0\.400s ]]
}

@test "R9/SC-009: the run prints an amortised per-scenario cost" {
  _write_scenarios 2
  _install_timed_harness
  run env -C "${WORKDIR}" bash tests/conformance/ci-conformance.sh
  [ "$status" -eq 0 ]
  [[ "${output}" =~ amortised\ per-scenario\ cost ]]
}
