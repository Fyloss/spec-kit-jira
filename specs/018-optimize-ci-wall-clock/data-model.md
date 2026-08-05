# Data Model — Cut CI Wall-Clock to a 20-Minute Merge Decision

**Feature**: 018-optimize-ci-wall-clock
**Date**: 2026-08-05

This feature manipulates no runtime data. Its entities are the objects the test
pipeline schedules, budgets, and measures. They are modelled here because three
of them carry invariants that a reviewer must be able to check mechanically
(SC-005, SC-006, SC-008), and one carries a state machine that FR-004 makes
load-bearing.

---

## 1. Conformance Scenario

The unit of corpus work. One JSON file under `tests/conformance/scenarios/`.

| Field | Meaning |
| --- | --- |
| `name` | Informational label |
| `mock` | Mock-Jira configuration (projects, faults, seeded issues) |
| `fixture` | Repository tree copied into the scenario's workdir |
| `argv` / `runs[]` | One invocation, or an explicit sequence of them |
| `env` | Scenario-declared environment (the caller's is scrubbed) |

**Derived attributes this feature adds** (measurement, not schema — no scenario
file changes):

| Attribute | Source | Used by |
| --- | --- | --- |
| `port_leg_cost[bash\|powershell]` | wall-clock of each `run-scenario.sh` invocation | W3, SC-009 |
| `spawn_count` | process creations per leg | the §2.1 cost model |
| `http_calls` | lines in `calls.log` | correlates cost with write volume |

**Invariants**:
- **Completeness**: the executed scenario set on every host equals the full
  corpus. `|executed| == |scenarios/*.json|` on ubuntu, macOS and Windows
  (SC-005, FR-001).
- **Independence**: a scenario's temp workdir, mock instance, and — for the
  PowerShell leg — mock port are created by that scenario and identified by an
  identifier it recorded (FR-008). No scenario may observe another's state.
- **Determinism**: two runs of the same scenario at the same commit produce
  byte-identical `stdout`, `exit`, `calls.log`, and `workdir/` trees (FR-007).

**Relationships**: a Scenario produces two **Captures** (one per port); the pair
is compared to yield one **Verdict**.

---

## 2. Capture and Verdict

| Entity | Fields | Notes |
| --- | --- | --- |
| **Capture** | `stdout`, `stderr`, `exit`, `calls.log`, `workdir/` | Per scenario per port. `stdout.N`/`exit.N` per run for multi-run scenarios. |
| **Verdict** | `scenario`, `pass\|fail`, `divergence_report?` | A failure carries the first differing byte, both sides in hex, and both sizes. |

**Invariants**:
- The **verdict set** — the mapping from scenario to pass/fail — is what this
  feature must preserve exactly (SC-010). Two scenarios fail on `windows-latest`
  today; after the speed-up those same two, and only those two, must fail.
- A divergence report must survive the annotation budget: GitHub keeps ten
  annotations per check run, so all reports fold into **one** `::error::`
  (FR-006). This is an existing property to preserve, not to invent.

---

## 3. Concurrency Policy

The degree of in-step parallelism, per host. Today a function of the host alone.

| Host class | Current degree | Source |
| --- | --- | --- |
| Linux / macOS | `nproc` / `sysctl -n hw.ncpu` | `core_count()` |
| MSYS (git-bash on Windows) | **hard-coded 2** | `core_count()`'s `MINGW*\|MSYS*\|CYGWIN*` branch |
| Fallback | 4 | none of the above resolved |

**State machine** — FR-004 makes the transition, not the value, the governed thing:

```
    capped(2)  ──probe run at degree N completes, runner survives──▶  raised(N)
        ▲                                                                │
        └──────────── probe run at degree N loses the runner ────────────┘
                       (or reports fewer verdicts than scenarios)
```

**Invariants**:
- A degree above 2 on MSYS is valid only with a recorded probe run at that
  degree that (a) completed and (b) reported a verdict for every scenario.
- "Finished faster" is not evidence. Runner survival plus a complete verdict set
  is (FR-005).

---

## 4. Budget

A declared wall-clock ceiling, enforced by the pipeline rather than documented.

| Budget | Ceiling | Enforced by | Criterion |
| --- | --- | --- | --- |
| `unit` per host | 18 min | job `timeout-minutes` | SC-001, SC-002 |
| `coverage-bash` | ≤ 18 min, with ≥ 20% headroom over measured | step `timeout-minutes` | SC-004 |
| merge decision | 20 min | the max over all check runs | SC-003 |

**Invariants**:
- **Headroom, not tightness**: a budget set at or below the measured duration is
  the defect FR-013 names. `measured ≤ 0.8 × ceiling`.
- **Slow is red**: exceeding a budget fails the job. It never routes to the
  traceability fallback, which exists only for an *unmeasurable* kcov run
  (FR-013).
- **Amortised cost is published beside the wall-clock** so the next corpus growth
  can be sized before it turns a gate red (SC-009).

---

## 5. Blocking Inventory Entry

Nine job **definitions** across three workflows, expanding to eleven **check
runs**. This distinction matters: branch protection matches check-run names.

| Workflow | Definition | Check-run name(s) |
| --- | --- | --- |
| ci.yml | `unit` | `Unit suites (ubuntu-latest)`, `Unit suites (macos-latest)`, `Unit suites (windows-latest)` |
| ci.yml | `lint` | `Lint (shellcheck, PSScriptAnalyzer)` |
| ci.yml | `static-checks` | `Static checks (manifest, messages, registry writes)` |
| gates.yml | `changes` | `Detect Bash-relevant changes` |
| gates.yml | `coverage-bash` | `Bash coverage >= 80% (kcov primary, traceability fallback)` |
| gates.yml | `coverage-pwsh` | `PowerShell coverage >= 80% (Pester)` |
| gates.yml | `module-parity` | `Twin ports mirror module-for-module` |
| gates.yml | `version-string` | `Version literal single-sourced (SC-006, FR-021/022)` |
| boundary.yml | `engine-sink-boundary` | `engine/ carries zero Jira knowledge` |

**Invariants**:
- Both the definition set and the rendered check-run name set are frozen,
  byte-identical, including the parenthesised suffixes (SC-006, FR-016).
- No workflow outside this table may acquire an unscoped `pull_request` trigger
  or a `push` on the default branch. `live.yml` (Constitution XII's three
  triggers) and `windows-conformance.yml` (`push: [ci/windows-probe]`) are the
  two named exemptions; the nightly stays non-blocking by its triggers (FR-012).

---

## 6. Coverage Collector

| Entity | Fields | Notes |
| --- | --- | --- |
| **kcov shard** | scenario slice, own output directory | Runs its slice of the corpus under its own kcov instance |
| **merged report** | cobertura XML, per-line hits | The union of the shards' hits over one denominator |
| **exercise phase** | dispatcher paths, library entry points | Runs *inside* kcov; the sanctioned place to raise the numerator |
| **traced evidence** (leaving the gate) | distinct `file:line` frames from the bats suite | Moves to the nightly as evidence (FR-012) |

**Invariants**:
- **Denominator is kcov's alone**: which lines are statements is decided by kcov
  and never trimmed to flatter the percentage (FR-014).
- **Numerator grows only by exercising code**: a line counts as covered because
  something ran it, not because a report was filtered.
- **Merge is order-independent**: sharding must not change the report. The union
  of hits over a fixed denominator is commutative — the property that makes
  sharding safe here.

---

## 7. Probe Measurement

One line appended to the Windows probe's existing single `::notice::`. The
project's established channel for a fact only Windows can supply, because raw
job logs answer 403 to a non-admin token while annotations do not.

| Field | Example shape |
| --- | --- |
| question id | `W1` / `W2` / `W3` |
| measurement | a duration, a count, or `survived`/`lost` |
| context | the degree of concurrency, the Defender-exclusion state |

**Invariant**: the notice stays a single annotation. Per-scenario annotations
were tried and lost the report — the ten-annotation cap consumed by per-scenario
errors dropped the one carrying the bytes.
