# Contract: Bash coverage runner (`tests/coverage/bash-coverage.sh`)

The Bash port's statement-coverage gate. Constitution XIII names kcov as the
primary collector; this contract makes kcov the **only** collector on the
blocking gate and moves the xtrace evidence to the nightly.

## CLI

```
tests/coverage/bash-coverage.sh [--threshold N] [--report-dir DIR]
                                [--mode full|conformance|bats]
```

| Variable | Meaning | Default |
| --- | --- | --- |
| `SPEC_KIT_JIRA_COVERAGE_TIMEOUT` | Wall-clock bound on the kcov phase | 600 |
| `SPEC_KIT_JIRA_COVERAGE_JOBS` | **NEW** — number of kcov shards over the corpus | host core count |

`--mode conformance` (kcov alone) becomes the shape the gate runs. `--mode full`
and `--mode bats` remain for local use and for the nightly.

## Guarantees

| # | Guarantee | Rationale |
| --- | --- | --- |
| C1 | The **denominator** is kcov's statement set, never trimmed, filtered, or narrowed to raise the percentage. | FR-014, Constitution XIII |
| C2 | The **numerator** grows only by executing code. Compensation for the retired collector lives in the exercise phase, which runs *inside* kcov. | FR-014, D7 |
| C3 | The corpus is exercised in **N shards**, each under its own kcov instance, merged into one report. The merge is order-independent: a union of hits over a fixed denominator. **NEW** | FR-011, D6 |
| C4 | Merging N shards yields the same percentage as one serial run of the same scenarios. **NEW** — this is the property that makes C3 safe and it is asserted, not assumed. | FR-011 |
| C5 | Exceeding the declared wall-clock budget **fails the job**. It never routes to the traceability fallback. | FR-013 |
| C6 | The traceability fallback activates **only** on the explicit "could not measure" path (rc=2: no kcov, unusable interpreter, empty report). | FR-013, 009 FR-016 |
| C7 | The gate publishes the percentage, the covered/total line counts, and the per-file table. | Constitution XVI |
| C8 | The xtrace-traced bats collector does not run on the blocking gate. It runs in the non-blocking nightly and publishes its distinct-frame count as coverage-gap evidence. | FR-011, FR-012 |
| C9 | Neither collector may redirect fd 2, and every phase reads stdin from `/dev/null`. | Pre-existing invariants guarded by `tests/bash/ci/test_coverage_runner_bounds.bats` |
| C10 | The credential/transport machinery stays xtrace-suspended wherever tracing runs. | Constitution IV, NFR-3 |

## Gate decision table

| kcov outcome | Job result |
| --- | --- |
| measured, ≥ threshold | pass |
| measured, < threshold | **fail**, naming the shortfall |
| exceeded the budget | **fail**, naming the budget |
| could not measure (rc=2) | traceability fallback decides |

## Non-goals

- **Not** a lowering of the 80% floor.
- **Not** a place to exclude files to make the number work. C1 is absolute.
