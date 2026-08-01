# Quickstart & Validation: Optimize Automated Test Performance

**Feature**: 009-optimize-test-performance

This guide proves the feature end-to-end: the Bash suite runs fast with only
`bats`+`jq`, never a false green, with every gate and coverage floor intact.
See [contracts/](./contracts/) and [data-model.md](./data-model.md) for details.

## Prerequisites

- **Fast local path**: `bats` and `jq` only. No PowerShell, no GNU `parallel`.
- **Coverage / conformance / PowerShell parity**: additionally PowerShell 7+ and
  (Linux) `kcov` — CI-side gates.

## Run the Bash suite (the fast path)

```bash
tests/run-bash.sh                 # full suite, parallel across cores
tests/run-bash.sh tests/bash/sink # a subset
```

Expected: completes in ≤ half the pre-change wall-clock (SC-001), prints a summary
with a test count > 0, and exits 0 on a green tree.

## Validation scenarios

### V1 — Zero extra tooling (SC-002)
On a machine with only `bats`+`jq` (no PowerShell, no GNU `parallel`):
```bash
command -v pwsh || echo "no pwsh (expected)"
command -v parallel || echo "no GNU parallel (expected)"
tests/run-bash.sh
```
**Pass**: every test executes; 0 skipped/failed for missing tooling; exit 0.

### V2 — Never a false green (SC-003 / FR-003)
Force GNU `parallel` off `PATH` and confirm the runner still runs everything:
```bash
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'parallel' | paste -sd: -)" \
  tests/run-bash.sh | tee /tmp/run.log
grep -E 'tests? (executed|run): [1-9]' /tmp/run.log   # count must be > 0
```
**Pass**: executed-test count > 0 (never zero); a deliberately broken test makes
the runner exit non-zero. (Automated in `tests/bash/ci/test_run_bash_runner.bats`.)

### V3 — Speed came from removing the pwsh mock, not from removing tests (SC-001/SC-007)
```bash
# Assert the mock-driving tests start no pwsh process:
grep -rl mock_start tests/bash | wc -l          # 35 files still present (post-008)
tests/run-bash.sh tests/bash/sink/test_client.bats   # green, no pwsh started
```
**Pass**: all mock tests pass with the shim; no test file was deleted or disabled.

### V3b — Change-scoped inner loop (SC-001b / FR-017)
```bash
time tests/run-bash.sh                      # full suite — must be ≤ 5 min (SC-001)
time tests/run-bash.sh --since HEAD~1       # affected files only — must be ≤ 60 s
tests/run-bash.sh --since nonexistent-ref   # must fail OPEN: runs the FULL suite
grep -rn 'run-bash.sh --since' .github/     # must return nothing (S1: local only)
```
**Pass**: both budgets met; an undeterminable diff runs everything, never zero; no
workflow invokes the scoped mode.

### V3c — Windows keeps its full guarantee (SC-011 / FR-018 / FR-019)
```bash
# On the CI run, per OS leg of the `unit` job:
#   - Pester suite executed in full
#   - conformance scenario count == 51 on EVERY host, including windows-latest
```
**Pass**: no host reports fewer than 51 scenarios. A host with a subset means the
corpus was sharded ACROSS OSes — forbidden by FR-018, and a FAIL rather than a
speed-up.

### V4 — Mock driver contract & faults (contracts/curl-shim.md)
```bash
bats tests/bash/ci/test_mock_shim_contract.bats
```
**Pass**: 200/201/401/404/429+Retry-After/network-fault and the call log all
behave per the contract; the `Authorization` header never appears in the log.

### V5 — Coverage floor & denominator unchanged (SC-008 / FR-005)
```bash
tests/coverage/bash-coverage.sh --mode full --threshold 80
```
**Pass**: ≥ 80% Bash statement coverage; measured line count (denominator) is
not smaller than before; PASS message printed. Runs materially faster (no pwsh
under kcov).

### V6 — Cross-port parity still enforced (SC-010 / FR-006)
```bash
# Run one scenario against both ports and diff (as CI does):
out_b=$(mktemp -d); out_p=$(mktemp -d)
tests/conformance/run-scenario.sh tests/conformance/scenarios/us3-feature-create.json bash "$out_b"
tests/conformance/run-scenario.sh tests/conformance/scenarios/us3-feature-create.json powershell "$out_p"
diff -u "$out_b/calls.log" "$out_p/calls.log" && diff -ru "$out_b/workdir" "$out_p/workdir"
```
**Pass**: byte-identical captures. Injecting a deliberate divergence makes the
diff (and CI) fail — parity detection is unimpaired.

### V7 — Green under maximum parallelism (SC-009 / FR-007)
```bash
# Local gate: 5 runs. The 20-run evidence lives in the scheduled CI job —
# 20 local runs cost ~7 hours, which would defeat this feature's purpose.
for i in $(seq 1 5); do tests/run-bash.sh >/dev/null || { echo "flake at run $i"; break; }; done
```
**Pass**: 5/5 green locally and 20/20 green in the scheduled CI job; no test
locates a process/file/port by name pattern or machine-wide scan.

## CI validation (SC-004 / SC-005 / SC-005b / SC-006 / SC-011)

- Check the **absolute budgets**, not reductions: `coverage-bash` ≤ **15 min**
  (SC-004), push → complete merge decision ≤ **20 min** (SC-005), and total
  runner-minutes below a green run of `21068d6` (SC-005b).
- Confirm the blocking gate set is identical — **9 jobs across 3 workflows**:
  `unit` ×3 OS (bats + Pester + full conformance corpus), `lint`, `static-checks`,
  `changes`, `coverage-bash`, `coverage-pwsh`, `module-parity`, `version-string`,
  `engine-sink-boundary`. No gate dropped or downgraded (SC-006 / FR-010).
- Confirm **every** OS leg ran all 51 conformance scenarios and that
  `windows-latest` ran Pester in full, both still blocking (SC-011 / FR-019).
- Confirm Pester and `specify-cli` are served from cache on a warm run and that a
  cache miss still produces a correct (slower) run.
