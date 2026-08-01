# Contract: Bash test runner (`tests/run-bash.sh`)

The single entry point CI and developers use to run the Bash suite. Replaces
`bats --jobs` (which requires GNU `parallel` and silently runs 0 tests without
it).

## CLI

```
tests/run-bash.sh [--since <ref>] [PATH ...]
```

- `PATH` (optional, repeatable): test file or directory. Default: `tests/bash`.
- `--since <ref>` (optional): **change-scoped local mode** (FR-017) — run only the
  test files affected by the diff against `<ref>`. See below.

## Change-scoped mode (`--since`)

Purpose: the developer/agent inner loop, where re-running all 955 tests after
every edit is the dominant cost (SC-001b: ≤ 60 s for a single-module diff).

| # | Guarantee | Rationale |
| --- | --- | --- |
| S1 | **Local only.** No CI workflow may invoke `--since`; CI always runs the full suite. | The Out-of-Scope exclusion on tiering governs CI gates; this mode must never touch one. |
| S2 | **Fail-open.** If the affected set cannot be determined (no `<ref>`, detached state, a change to a shared helper or to the runner itself), run the **whole** suite. | Never a false green — the same discipline FR-003 imposes on the parallel path. |
| S3 | Never selects **zero** files silently: an empty selection means "run everything", not "run nothing". | The defect this feature exists to fix, in a new disguise. |
| S4 | Prints which files were selected and why, plus an explicit note that this is a partial run. | Constitution XVI; the developer must never mistake it for a full-suite verdict. |

## Guarantees

| # | Guarantee | Rationale |
| --- | --- | --- |
| R1 | Runs with only `bats` + `jq` present — no GNU `parallel`, no PowerShell. | SC-002. |
| R2 | Executes **every** discovered test; never reports success while running 0. | FR-003 / SC-003. |
| R3 | Parallelizes across cores via `xargs -P`; falls back to serial if concurrency is unavailable — never by skipping tests. | Decision 3. |
| R4 | Exit code 0 **iff** all shards passed **and** executed-file count > 0; otherwise non-zero with a named, actionable message. | FR-003, Constitution XVI. |
| R5 | Prints an aggregated summary including the number of test files and tests executed. | Observability, R2 evidence. |
| R6 | Deterministic: no flakiness introduced vs. serial `bats` (per-file isolation, no shared state). | FR-012 / SC-009. |

## Verification (`tests/bash/ci/test_run_bash_runner.bats`, tests-first per FR-015)

1. With GNU `parallel` forced off `PATH`, the runner executes the full suite and
   the executed-test count equals the expected total (never 0). *(regression for
   the silent-zero-tests defect)*
2. A deliberately failing test makes the runner exit non-zero.
3. The runner's summary reports a test count > 0.
4. `--since` with an undeterminable diff runs the **full** suite (S2), not zero.
5. `--since` on a diff touching one Bash module selects that module's test files
   and completes within the SC-001b budget.
6. No file under `.github/workflows/` invokes `run-bash.sh --since` (S1) —
   asserted by the CI-guard suite.
