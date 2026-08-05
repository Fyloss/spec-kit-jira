#!/usr/bin/env bats
# T004 [018, Phase 2] — Contract test for tests/conformance/ci-conformance.sh,
# per contracts/conformance-runner.md R5/R6. Written and observed to FAIL
# before T005 existed (Constitution XIII TDD).
#
# R5: exit code 0 iff every scenario reported a verdict AND every verdict is a
#     pass. A worker that produces no result is a failure, never an omission.
# R6: the number of verdicts is printed and compared against the corpus size;
#     a shortfall is a named error, not a silent pass.
#
# A worker "producing no result" cannot be reproduced by killing a real
# scenario (that is Windows-probe territory, Constitution VI). It IS
# reproducible here by pointing the runner at a scenario glob one of whose
# members a hostile `run-scenario.sh` stub silently swallows — exactly the
# shape xargs -P would hide today, since nothing counts verdicts in or out.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  RUNNER="${ROOT}/tests/conformance/ci-conformance.sh"
  WORKDIR="$(mktemp -d)"
  mkdir -p "${WORKDIR}/tests/conformance/scenarios"
  cp -R "${ROOT}/tests/conformance/." "${WORKDIR}/tests/conformance/"
  rm -rf "${WORKDIR}/tests/conformance/scenarios"
  mkdir -p "${WORKDIR}/tests/conformance/scenarios"
}

teardown() {
  rm -rf "${WORKDIR}"
}

# A minimal corpus: N scenario files, each converted into a byte-identical
# capture by a stub harness so the run is fast and host-independent. The stub
# replaces run-scenario.sh entirely; this test's job is the accounting layer
# around it, not the scenario semantics real scenarios already cover.
_write_scenarios() {
  local n="$1" i
  for ((i = 1; i <= n; i++)); do
    printf '{"name":"stub-%d"}\n' "${i}" > "${WORKDIR}/tests/conformance/scenarios/stub-${i}.json"
  done
}

# A harness stub that always produces a matching bash/pwsh capture pair —
# used to prove the accounting layer passes cleanly when every worker reports.
_install_good_harness() {
  cat > "${WORKDIR}/tests/conformance/run-scenario.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
outdir="$3"
printf 'ok\n' > "${outdir}/stdout"
printf '0\n' > "${outdir}/exit"
: > "${outdir}/calls.log"
mkdir -p "${outdir}/workdir"
EOF
  chmod +x "${WORKDIR}/tests/conformance/run-scenario.sh"
}

# A harness stub that kills its OWN PARENT (the ci-conformance.sh worker
# invoking it) for one named scenario, before that worker ever writes a
# verdict. This is the case R5 names explicitly — a worker that produces no
# result, not one that runs and reports a failure. A harness that merely
# exits non-zero does not reproduce it: the existing diff-based report still
# fires because the calling worker survives to compare (missing) captures.
# Only a worker that dies mid-flight leaves genuinely nothing behind.
_install_dropping_harness() {
  local dropped="$1"
  cat > "${WORKDIR}/tests/conformance/run-scenario.sh" << EOF
#!/usr/bin/env bash
set -euo pipefail
scenario="\$1"
outdir="\$3"
name="\$(basename "\${scenario}" .json)"
if [ "\${name}" = "${dropped}" ]; then
  kill -9 "\${PPID}"
  sleep 5
  exit 1
fi
printf 'ok\n' > "\${outdir}/stdout"
printf '0\n' > "\${outdir}/exit"
: > "\${outdir}/calls.log"
mkdir -p "\${outdir}/workdir"
EOF
  chmod +x "${WORKDIR}/tests/conformance/run-scenario.sh"
}

@test "R6: a clean run prints a verdict count matching the corpus size" {
  _write_scenarios 3
  _install_good_harness
  run env -C "${WORKDIR}" bash tests/conformance/ci-conformance.sh
  [ "$status" -eq 0 ]
  [[ "${output}" =~ verdicts:\ 3/3 ]]
}

@test "R5/R6: a worker producing no result is a named failure, never a silent omission" {
  _write_scenarios 3
  _install_dropping_harness "stub-2"
  run env -C "${WORKDIR}" bash tests/conformance/ci-conformance.sh
  [ "$status" -ne 0 ]
  [[ "${output}" == *"stub-2"* ]]
  [[ "${output}" =~ verdicts:\ 2/3 ]]
}
