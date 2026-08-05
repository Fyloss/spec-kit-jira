# Contract: Conformance corpus runner (`tests/conformance/ci-conformance.sh`)

Runs the whole corpus against both ports on the host it is invoked on, and diffs
the captures. This contract **extends** the script's existing behaviour; every
guarantee already held is restated so a reviewer can see what is new (marked
**NEW**) and what must not move.

## CLI and environment

```
bash tests/conformance/ci-conformance.sh
```

| Variable | Meaning | Default |
| --- | --- | --- |
| `SPEC_KIT_JIRA_SHARD_TOTAL` / `SPEC_KIT_JIRA_SHARD_INDEX` | Static round-robin slice, for the **probe's** 4-runner matrix only | 1 / 0 (no slicing) |
| `SPEC_KIT_JIRA_CONFORMANCE_JOBS` | **NEW** — explicit in-step concurrency, overriding the host default | unset (host default) |

The shard variables stay available and stay **unused by `ci.yml`**: they exist
for the probe, which spans runners deliberately and non-blockingly. Any use of
them from a blocking workflow is the forbidden cross-OS shape (FR-001/FR-002),
guarded by `tests/bash/ci/test_conformance_no_cross_os_shard.bats`.

## Guarantees

| # | Guarantee | Rationale |
| --- | --- | --- |
| R1 | Executes **every** scenario in `scenarios/*.json` on the host it runs on. | FR-001, SC-005 |
| R2 | Each scenario runs against **both** ports; stdout, exit code, call sequence and written tree are compared for byte-identical equality. | FR-001, Constitution VI |
| R3 | Scenarios are scheduled **dynamically** across workers (work-stealing), never partitioned statically inside the job. | D1 — a 4.4× cost spread across equal static shards was measured on probe run `30972259389` |
| R4 | The in-step concurrency is the host default unless `SPEC_KIT_JIRA_CONFORMANCE_JOBS` overrides it. On MSYS the default may exceed 2 **only** with a recorded probe run at that degree in which the runner survived and every scenario reported. **NEW** | FR-004, D2 |
| R5 | Exit code 0 **iff** every scenario reported a verdict **and** every verdict is a pass. A worker that produces no result is a failure, never an omission. **NEW** | FR-005 |
| R6 | The number of verdicts is printed and compared against the corpus size; a shortfall is a named error, not a silent pass. **NEW** | FR-005, SC-005 |
| R7 | Failures fold into exactly **one** `::error::` annotation carrying the byte-level report: first differing byte, both sides in hex, both sizes. Per-scenario annotations are forbidden. | FR-006 — GitHub keeps only ten annotations per check run |
| R8 | Two consecutive runs at the same commit and concurrency produce byte-identical captures per scenario and an identical verdict set. | FR-007, SC-007 |
| R9 | Per-scenario, per-port timings are emitted so amortised cost can be published beside wall-clock. **NEW** | SC-009, W3 |
| R10 | No scenario identifies state (temp dir, port, process) by name pattern or machine-wide scan. | FR-008, Constitution XIII |

## Non-goals

- **Not** a mechanism for running a subset on any blocking job. R1 is absolute.
- **Not** a place to add retries. A flaky scenario under wider concurrency is a
  determinism defect (R8) and must fail, not be re-rolled.
