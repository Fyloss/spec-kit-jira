# Baseline: Optimize Automated Test Performance

**Feature**: 009-optimize-test-performance
**Captured**: 2026-07-31 · **Re-captured**: 2026-08-02 after rebasing onto the
008 merge (`21068d6`, PR #13)
**Branch**: feat/improve-tests-2 (pre-shim, pre-runner)
**Machine**: macOS Darwin 25.5.0 (Apple Silicon)

> ⚠️ **Why this file was re-captured.** The first capture was taken on `main` at
> `e8e7bb1`, before feature 008 (`specs/008-jira-parent-hierarchy`) merged. 008
> grew the suite by ~23%, grew the conformance corpus by ~31%, added a blocking
> `lint` job, and promoted the conformance corpus from a Linux-only job to a step
> of the three-OS `unit` job. Every number and the whole gate inventory below is
> therefore restated against `21068d6`. Superseded pre-008 values are kept in
> parentheses for the record.

---

## T001 — Bash suite metrics (pre-shim)

### Test count and file count

- **`@test` count**: **955** (was 775 pre-008) — from
  `grep -rhc '^@test' tests/bash --include='*.bats' | paste -sd+ - | bc`
- **`.bats` file count**: **115** (was 95)
- **Mock-dependent files** (calling `mock_start`): **35** (was 29)
- **Conformance scenarios**: **51** (was 39)
- **PowerShell `.Tests.ps1` files**: 96

### Wall-clock baselines

**Note**: pwsh is NOT installed on this machine. The current `mock_start` implementation always spawns `pwsh`, so the 35 mock-dependent test files fail immediately with `pwsh: command not found`. These timings reflect the pre-shim state where the mock-dependent tests cannot run locally without PowerShell.

> The wall-clock figures in this subsection were taken **pre-008** and have not
> been re-measured; the suite has grown ~23% since. They are retained only as
> evidence of the two defects below, not as an SC-001 denominator.

- **(a) Serial wall-clock** `bats -r tests/bash`: Aborted (mock tests block waiting for pwsh — not measurable without PowerShell)
- **(b) Parallel wall-clock** `bats -r tests/bash --jobs "$(getconf _NPROCESSORS_ONLN)"`: Not measurable (GNU `parallel` prints "parallel: command not found" on macOS and executes 0 tests — the silent-false-green defect being fixed by FR-003)

**Non-mock tests only** (`bats -r tests/bash/ci tests/bash/engine tests/bash/lib tests/bash/hooks`): **2m 15s serial** (349 @tests across 29 files — *pre-008 measurement, not re-run*)
- Parallel: Cannot use `bats --jobs` on macOS without GNU `parallel`

**Note**: The 35 mock-dependent files hold the majority of the @tests that cannot run locally without PowerShell. After the curl shim is introduced, all 955 @tests must run without PowerShell (subject to research.md OQ-1, which is unresolved for the 9 `mock_issue_field` assertions).

**Root cause documented**: The two defects this feature fixes:
1. `bats --jobs` on macOS silently runs 0 tests without GNU `parallel` (SC-002/FR-003)
2. All 35 mock-dependent test files fail without PowerShell (SC-002)

**CI baseline** (latest `main` run): ~20–35 minutes (kcov coverage gate documented in gates.yml comment)

---

## T002 — Gate inventory (must be identical after)

Re-captured on `21068d6` (post-008). **9 blocking jobs across 3 workflows**, all
triggered on `push` + `pull_request`.

### CI workflow jobs (ci.yml)
| Job | Runs on | What it does |
|-----|---------|-------------|
| `unit` | ubuntu-latest, macos-latest, windows-latest | Bash suite (`bats --jobs`, POSIX hosts only), Pester suite (all hosts), **and the conformance corpus vs both ports** (`bash tests/conformance/ci-conformance.sh`) |
| `lint` | ubuntu-latest | **NEW in 008 (T105)** — `shellcheck scripts/bash` + `Invoke-ScriptAnalyzer scripts/powershell`. Constitution XII names lint a blocking gate; before 008 neither rule set was enforced by anything. |
| `static-checks` | ubuntu-latest | Bash CI tests (`bats -r tests/bash/ci`), PowerShell CI tests |

### Gates workflow jobs (gates.yml)
| Job | Runs on | What it does |
|-----|---------|-------------|
| `changes` | ubuntu-latest | Detects Bash-relevant changes (fail-open path filter) |
| `coverage-bash` | ubuntu-22.04 | kcov ≥ 80% primary, traceability fallback; `timeout-minutes: 30` |
| `coverage-pwsh` | ubuntu-latest | Pester ≥ 80% |
| `module-parity` | ubuntu-latest | bash/powershell leaf sets match |
| `version-string` | ubuntu-latest | Version literal single-sourced |

### Boundary workflow jobs (boundary.yml)
| Job | Runs on | What it does |
|-----|---------|-------------|
| `engine-sink-boundary` | ubuntu-latest | Gate #1: no engine/ imports sink/; Gate #2: no engine/ Atlassian identifiers |

### NOT merge gates (present in the tree, deliberately excluded from this inventory)
| Workflow / job | Trigger | Why it is not a gate |
|---|---|---|
| `windows-conformance.yml` / `conformance` | `push: [ci/windows-probe]`, `workflow_dispatch` | Manual Windows probe (4 shards), driven from a throwaway branch. No PR trigger — it can never block a merge. |
| `live.yml` / `live-zero-churn` | `push` to default, `schedule`, maintainer label | Real-Jira suite; never a fork-PR gate (spec.md Assumptions). |

### Delta vs the pre-008 capture (why SC-006 must be judged against *this* table)
1. **`lint` is new** and blocking — it was absent from the first inventory, so a
   check against that inventory would have silently tolerated dropping it.
2. **`conformance` is no longer a standalone `ci.yml` job**; it is a *step* of
   `unit` and therefore now runs on **all three OSes** rather than Linux alone.
   The corpus also grew 39 → 51 scenarios. Net: the most expensive non-coverage
   work in the pipeline multiplied by ~3.9×.
3. Two new workflows exist (`windows-conformance.yml`, `live.yml`); neither is a
   merge gate, and this feature must leave both untouched.

**SC-006 requirement**: the 9 blocking jobs above must be present, blocking, and
produce identical verdicts on identical input after the optimization.

---

## T003 — Single HTTP chokepoint confirmed

Re-verified on `21068d6` after the 008 merge — **the invariant still holds**, so
the shim design survives 008 unchanged. Result:
```
scripts/bash/sink/jira/client.sh:139:      printf '%s\n' "${cfg}" | curl --silent --config - \
```
(The line moved from 96 to 139; 008 grew `client.sh` but added no second call
site.)

The `prereq.sh` reference (`PREREQ_REQUIRED_CMDS=(curl jq git)`) is a command-existence check, not an HTTP call. **The single HTTP chokepoint invariant holds**: only `scripts/bash/sink/jira/client.sh:139` issues HTTP requests.

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
| Mock test requires pwsh | YES (35 files) | NO | None |
| Mock test requires GNU parallel | YES (`bats --jobs`) | NO | None |
| CI runner-minutes | TBD | - | ≥ 40% reduction |
| CI wall-clock | TBD | - | ≥ 30% reduction |
| Bash statement coverage | TBD | - | ≥ 80% |
| Coverage denominator (lines) | TBD | - | ≥ baseline |
| `@test` count | **955** | - | **≥ 955** |
| `.bats` file count | **115** | - | ≥ 115 |
| Conformance scenarios | **51** | - | = 51 |
| Blocking CI jobs | **9** | - | = 9 (see T002) |
