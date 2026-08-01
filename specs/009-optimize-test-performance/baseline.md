# Baseline: Optimize Automated Test Performance

**Feature**: 009-optimize-test-performance
**Captured**: 2026-07-31
**Branch**: feat/improve-tests-2 (pre-shim, pre-runner)
**Machine**: macOS Darwin 25.5.0 (Apple Silicon)

---

## T001 — Bash suite metrics (pre-shim)

### Test count and file count

- **`@test` count**: 775 (from `grep -rhc '^@test' tests/bash --include='*.bats' | paste -sd+ - | bc`)
- **`.bats` file count**: 95
- **Mock-dependent files** (calling `mock_start`): 29

### Wall-clock baselines

**Note**: pwsh is NOT installed on this machine. The current `mock_start` implementation always spawns `pwsh`, so the 29 mock-dependent test files fail immediately with `pwsh: command not found`. These timings reflect the pre-shim state where the mock-dependent tests cannot run locally without PowerShell.

- **(a) Serial wall-clock** `bats -r tests/bash`: Aborted (mock tests block waiting for pwsh — not measurable without PowerShell)
- **(b) Parallel wall-clock** `bats -r tests/bash --jobs "$(getconf _NPROCESSORS_ONLN)"`: Not measurable (GNU `parallel` prints "parallel: command not found" on macOS and executes 0 tests — the silent-false-green defect being fixed by FR-003)

**Non-mock tests only** (`bats -r tests/bash/ci tests/bash/engine tests/bash/lib tests/bash/hooks`): **2m 15s serial** (349 @tests across 29 files)
- Parallel: Cannot use `bats --jobs` on macOS without GNU `parallel`

**Note**: The 29 mock-dependent files contain approximately 426 @tests that cannot run locally without PowerShell. After the curl shim is introduced, all 775 @tests will run without PowerShell.

**Root cause documented**: The two defects this feature fixes:
1. `bats --jobs` on macOS silently runs 0 tests without GNU `parallel` (SC-002/FR-003)
2. All 29 mock-dependent test files fail without PowerShell (SC-002)

**CI baseline** (latest `main` run): ~20–35 minutes (kcov coverage gate documented in gates.yml comment)

---

## T002 — Gate inventory (must be identical after)

From `.github/workflows/ci.yml` and `.github/workflows/gates.yml`:

### CI workflow jobs (ci.yml)
| Job | Runs on | What it does |
|-----|---------|-------------|
| `unit` | ubuntu-latest, macos-latest, windows-latest | Bash suite (`bats --jobs`), Pester suite |
| `static-checks` | ubuntu-latest | Bash CI tests (`bats -r tests/bash/ci`), PowerShell CI tests |
| `conformance` | ubuntu-latest | All scenarios vs both ports, diff captures |

### Gates workflow jobs (gates.yml)
| Job | Runs on | What it does |
|-----|---------|-------------|
| `changes` | ubuntu-latest | Detects Bash-relevant changes (fail-open path filter) |
| `coverage-bash` | ubuntu-22.04 | kcov ≥ 80% primary, traceability fallback |
| `coverage-pwsh` | ubuntu-latest | Pester ≥ 80% |
| `module-parity` | ubuntu-latest | bash/powershell leaf sets match |
| `version-string` | ubuntu-latest | Version literal single-sourced |

### Boundary workflow jobs (boundary.yml)
| Job | Runs on | What it does |
|-----|---------|-------------|
| `engine-sink-boundary` | ubuntu-latest | Gate #1: no engine/ imports sink/; Gate #2: no engine/ Atlassian identifiers |

**SC-006 requirement**: This gate set must be byte-for-byte identical after the optimization.

---

## T003 — Single HTTP chokepoint confirmed

Result: `grep -rn 'curl ' scripts/bash | grep -v '#'` returns:
```
scripts/bash/sink/jira/client.sh:96:      printf '%s\n' "${cfg}" | curl --silent --config - \
```

The `prereq.sh` reference (`PREREQ_REQUIRED_CMDS=(curl jq git)`) is a command-existence check, not an HTTP call. **The single HTTP chokepoint invariant holds**: only `scripts/bash/sink/jira/client.sh:96` issues HTTP requests.

Shim design confirmed viable (only one place to intercept).

---

## SC-001 Target (like-for-like)

SC-001 is judged parallel-vs-parallel:
- **Baseline (b)**: `bats -r tests/bash --jobs N` (0 tests on macOS, ~N minutes on Linux CI)
- **Optimized**: `tests/run-bash.sh` (parallel via `xargs -P`, no GNU parallel)
- **Target**: ≤ half of baseline (b)

---

## FR-009 Scope Decision

The optimization satisfies "avoid re-executing work a diff cannot change" via:
1. **Toolchain caching** (T016): Pester module and `specify-cli` cached across CI runs
2. **Existing `changes` path filter** (preserved in T017): already in gates.yml

**OUT OF SCOPE**: New gate-skipping or affectedness-based conditional execution (test-tiering that changes what gates run on a PR). The existing `changes` filter is the ONLY path-based gate adjustment; no new ones are introduced.

---

## Post-implementation measurements (to be filled in)

| Metric | Baseline | Achieved | Target |
|--------|----------|----------|--------|
| Local wall-clock (parallel, `run-bash.sh`) | TBD | - | ≤ ½ baseline |
| Mock test requires pwsh | YES (29 files) | NO | None |
| Mock test requires GNU parallel | YES (`bats --jobs`) | NO | None |
| CI runner-minutes | TBD | - | ≥ 40% reduction |
| CI wall-clock | TBD | - | ≥ 30% reduction |
| Bash statement coverage | TBD | - | ≥ 80% |
| Coverage denominator (lines) | TBD | - | ≥ baseline |
| `@test` count | 775 | - | ≥ 775 |
