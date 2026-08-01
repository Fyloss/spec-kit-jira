# Contract: Bash test runner (`tests/run-bash.sh`)

The single entry point CI and developers use to run the Bash suite. Replaces
`bats --jobs` (which requires GNU `parallel` and silently runs 0 tests without
it).

## CLI

```
tests/run-bash.sh [PATH ...]
```

- `PATH` (optional, repeatable): test file or directory. Default: `tests/bash`.

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
