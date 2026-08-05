# Implementation Plan: Cut CI Wall-Clock to a 20-Minute Merge Decision

**Branch**: `018-optimize-ci-wall-clock` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

> Authored in the worktree `feat+optimize-windows-tests-4`; the work lands on
> `018-optimize-ci-wall-clock`.

**Input**: Feature specification from `/specs/018-optimize-ci-wall-clock/spec.md`

## Summary

A pull request waits **95 minutes** for its slowest blocking job, and one of the
nine blocking job definitions has been red on `main` since 2026-07-28 because it cannot
finish inside any budget. This plan brings the merge decision to 20 minutes
without removing a test, a scenario, or a gate.

Phase 0 measurement changed the diagnosis the request started from. The Windows
cost is **not** mock startup: a conformance scenario spawns ~610 processes on
POSIX and roughly **1000 on Windows** (the CRLF guard doubles them), of which
**93% are `jq` calls made by the Bash port itself** — production code this
feature may not touch. The PowerShell mock is 2 spawns out of a thousand.
In-step parallelism, the request's deliverable 1, has also already shipped: the
corpus has run under `xargs -P` since the 008 merge, throttled to 2 on Windows
because a wider fan-out once killed the runner.

So the plan is built around three things the request did not anticipate:

1. **Measure on the real runner first.** Four questions (per-spawn cost with and
   without Defender exclusions; survival at concurrency 3 and 4; the per-port
   time split; whether an MSYS-built `jq` emits LF here) are answerable only on
   `windows-latest`, and each one decides a design choice. They go first,
   through the existing probe.
2. **The Bash unit suite is the second critical path** (33–39 min of a 42–48 min
   `unit` job) and is treated as a first-class lever.
3. **One decision is escalated, not taken.** The largest remaining Windows lever
   is a few lines in `scripts/bash/lib/output.sh` that FR-020 freezes. Its value
   is measured (~1.9× on the dominant cost) and the choice is the user's.

**Approach**: measure → make the corpus and the bats suite cheaper and wider
within their existing job steps → re-architect the coverage gate onto kcov alone,
sharded and merged → prove determinism before the wider form gates → record every
budget mechanically.

## Technical Context

**Language/Version**: Bash ≥ 4 (test harness, runners, coverage driver) and
PowerShell 7+ (the twin port's suite); GitHub Actions workflow YAML.

**Primary Dependencies**: `bats` 1.13, `jq`, `curl`, `kcov` (development-time
only, Constitution XIII's named exception), Pester ≥ 5, GitHub Actions
runners (ubuntu-latest, ubuntu-22.04, macos-latest, windows-latest).

**Storage**: N/A — no runtime data. Measurement evidence lands in
`specs/018-optimize-ci-wall-clock/baseline.md`.

**Testing**: `bats` for the Bash side (with meta-tests under `tests/bash/ci`
that assert workflow and runner properties), Pester for the PowerShell side, the
84-scenario conformance corpus for cross-port equivalence, and the
`ci/windows-probe` workflow as the only Windows oracle.

**Target Platform**: the three-OS GitHub Actions matrix. All hosted runners are
4 vCPU; `windows-latest` additionally pays MSYS `fork` emulation, native PE
loading, and Defender's on-access scan for every process creation.

**Project Type**: test-infrastructure and CI configuration. No product code.

**Performance Goals**: `unit` ≤ 18 min per host (from 95m18s / 48m33s / 42m25s);
`coverage-bash` green with ≥ 20% headroom under a ≤ 18 min budget (from a
15m39s timeout kill); push to complete merge decision ≤ 20 min (from ≈ 95 min).

**Constraints**: `scripts/bash/**` and `scripts/powershell/**` frozen (FR-020);
the nine job definitions and eleven check-run names byte-identical (FR-016);
every host runs the complete corpus (FR-001); no new job names (FR-002);
Windows behaviour proven by measurement, never emulation (FR-018).

**Scale/Scope**: 84 conformance scenarios, 1427 `@test`s across 149 `.bats`
files, 1128 Pester assertions across 125 files, 3 workflows, 9 blocking job
definitions.

## Constitution Check

*GATE: passed before Phase 0 research; re-checked after Phase 1 design.*

| # | Principle | Verdict | Evidence |
| --- | --- | --- | --- |
| I | Filesystem is the source of truth | **PASS** — unaffected | No reconcile, drift, adoption or write path is touched (FR-020) |
| II | Zero-churn idempotency | **PASS** — unaffected | Live suite triggers unchanged; the mocked zero-churn scenarios keep running (FR-001/FR-010) |
| III | Fail-closed on writes | **PASS** — unaffected | No write or hook path changes. R5 applies the same instinct to the pipeline: a worker that reports nothing fails the step |
| IV | Credential security | **PASS** | No fixture or log gains a credential; C10 keeps the credential/transport machinery xtrace-suspended wherever tracing runs |
| V | Config / binding / secrets separation | **PASS** — unaffected | No configuration layering changes |
| VI | Three-OS portability | **PASS, strengthened** | FR-001 keeps the full corpus per host (R1); W1–W4 answer Windows questions on Windows (contracts/windows-probe.md); FR-022 extends the quirks catalog |
| VII | No hard-coded Jira workflow assumptions | **PASS** — unaffected | Non-default workflow fixtures stay in the corpus |
| VIII | Neutral engine / Jira sink | **PASS** — unaffected | The boundary greps stay blocking and unmodified |
| IX | Two-tier privacy guard | **PASS** — unaffected | Every privacy-tier test and fixture keeps running |
| X | Self-healing mirror | **PASS** — unaffected | Install-harness scenarios stay in the corpus every host executes |
| XI | Dry-run and auditability | **PASS** — unaffected | Dry-run behaviour and run summaries unchanged; their tests keep running |
| XII | Quality and catalog publication | **PASS, restored** | Same nine definitions blocking (B1); a permanently-red gate becomes a meaningful one (C1–C8) |
| XIII | TDD, ≥ 80% coverage | **PASS** | C1 holds the denominator, C2 the numerator's honesty; kcov — the tool this principle names — becomes the sole collector; the probe run is the failing-test-first step for Windows behaviour (Constitution VI); FR-008 holds identity-based isolation at the wider concurrency |
| XIV | KISS | **PASS** | Net removal: one collector instead of two, no new job topology, no new workflow for the corpus, no static sharding (D1) |
| XV | YAGNI | **PASS** | Only what the three budgets require. Job-topology restructuring, tiering, and reduced Windows verification stay out of scope |
| XVI | Human readable | **PASS** | R7 keeps the byte-level report legible; every budget is a number a reader can check against a run; measurements land in the catalog (P5) |

**One deviation is raised rather than taken** — see Complexity Tracking. It is
not a violation of the constitution; it is a conflict with this spec's own
FR-020, escalated because the spec's escape clause requires escalation.

## Project Structure

### Documentation (this feature)

```text
specs/018-optimize-ci-wall-clock/
├── plan.md              # This file
├── spec.md              # The specification
├── research.md          # Phase 0 — measurements, decisions D1–D8, open questions W1–W4
├── data-model.md        # Phase 1 — scenarios, budgets, the concurrency state machine, the inventory
├── quickstart.md        # Phase 1 — V1–V10 validation runs
├── baseline.md          # Evidence, written during implementation (FR-022, SC-013)
├── contracts/
│   ├── conformance-runner.md   # R1–R10
│   ├── coverage-runner.md      # C1–C10
│   ├── blocking-inventory.md   # B1–B5, the nine definitions and eleven check runs
│   └── windows-probe.md        # P1–P5, questions W1–W4
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source code (repository root)

Everything this feature touches, and nothing else:

```text
tests/
├── run-bash.sh                       # D5: oversubscription + LPT ordering
├── conformance/
│   ├── ci-conformance.sh             # D2/D4: concurrency policy, worker accounting, timings
│   ├── run-scenario.sh               # D4: harness spawn reduction (jq_lines, mktemp/cp churn)
│   └── mock-jira/curl-shim.sh        # D4: shim spawn reduction
├── coverage/bash-coverage.sh         # D6/D7: kcov sharding + merge, exercise-phase numerator
└── bash/ci/                          # meta-tests: inventory guard, runner bounds, workflow guards

.github/workflows/
├── ci.yml                            # budgets (timeout-minutes); Defender exclusions on Windows
├── gates.yml                         # coverage-bash re-architecture and its budget
├── bash-suite-stability.yml          # destination for the xtrace-traced evidence
└── windows-conformance.yml           # W1–W4 measurement lines on the existing notice

docs/10-windows-portability.md        # FR-022: whatever the probe establishes
```

**Structure Decision**: no new directories and no new files outside
`specs/018-optimize-ci-wall-clock/`, with one possible exception — if the
xtrace-traced suite is better served by a sibling workflow than by extending
`bash-suite-stability.yml`, that sibling is `schedule` + `workflow_dispatch`
only (B3/B4). `scripts/bash/**` and `scripts/powershell/**` do not appear in
this tree, which is FR-020 restated as a layout.

## Implementation phases

Ordered by dependency. Each phase states what must be true before the next
starts, so a blocked phase does not silently license the one after it.

### Phase A — Measure before designing (FR-003, FR-018)

Answer W1–W4 on the real `windows-latest` runner through the probe, and build
the per-file timing profile for the bats suite in CI. Record everything in
`baseline.md`. W4 exists so the Complexity Tracking decision is put to the user
with a measured number attached rather than an estimate.

**Exit condition**: W1–W4 answered with a run id and a commit; the bats profile
exists. **Nothing in Phase B is designed until this holds** — this is FR-003's
rule and Constitution VI's measurement-over-emulation rule applied to
performance rather than to correctness.

### Phase B — Cheap, verdict-neutral wins (FR-003, FR-009)

Independent of the Windows answers, so they proceed in parallel with Phase A's
round trips:

- **B1**: remove test-owned spawns — the shim's 27 `jq` per 8 HTTP calls, the
  harness's `jq_lines` + `sed` pairs, the `mktemp`/`cp` churn (D4, ~25% of
  measured spawns).
- **B2**: `tests/run-bash.sh` oversubscription and LPT ordering (D5), driven by
  Phase A's profile.
- **B3**: worker accounting and per-scenario timings in the corpus runner
  (R5/R6/R9) — the instrumentation every later claim is measured with.

Each lands with its failing test first (`tests/bash/ci/`), and each is
verdict-neutral by construction: same files, same scenarios, different order and
degree.

**Why this does not breach FR-003's measure-before-design rule.** FR-003 binds
the *Windows* per-scenario cost: its breakdown must be measured on a real
`windows-latest` runner before the change addressing it is designed, and that
is Phase C, which is gated on Phase A. Phase B's levers are host-independent,
test-owned, and already measured on POSIX (research §2.1's spawn census, §4.1's
suite shape) — removing a `jq` the test harness itself spawns is not a Windows
design decision, and it is verdict-neutral either way. Phase A's answers change
the *size* of Phase B's payoff on Windows, never its correctness, so the two
proceed in parallel.

### Phase C — The Windows levers (FR-004, FR-018)

Gated on Phase A. Defender exclusions in `ci.yml` (D3) and the concurrency cap
raise (D2), each proven by a probe run reporting survival **and** a complete
verdict count (P2), not merely a shorter duration.

**Exit condition**: a probe run at the chosen degree that survived and reported
84 verdicts, plus V2's determinism check at that degree on Windows.

### Phase D — The coverage gate (FR-011 – FR-014)

1. Measure the **kcov-alone percentage** on Linux (research §5.2's decision
   rule). This is the gate on the rest of the phase: ≥ 80% ships as designed;
   70–80% extends the exercise phase first; < 70% stops and reports.
2. Shard the exercise phase and merge (C3), asserting shard/serial equivalence
   (C4).
3. Move the xtrace collector to the nightly (C8, B4).
4. Set the budget with ≥ 20% headroom over the measured duration and make
   exceeding it fail loudly (C5/C6).

### Phase E — Freeze the guarantees and record the evidence

The inventory guard test (B5), the budgets as `timeout-minutes` (FR-017), the
Windows catalog entries (P5, FR-022), and the closure of 009's T032/T035/T036
against real measurements (FR-021, SC-013).

## Risks and how each is bounded

| Risk | Bound |
| --- | --- |
| **The 18-minute Windows target is not reachable with production code frozen.** Research §3 puts the realistic frozen-code case at ~33 min and the optimistic at ~16. | Phase A measures the levers independently, so the shortfall is a number rather than an opinion. If it persists, the Complexity Tracking decision below is the lever, and relaxing SC-001 is the alternative. Either way the user decides on evidence. |
| **Raising the concurrency cap kills the runner again.** | The cap only moves on a probe run that survived *and* reported every verdict (R4/P2). A lost runner reverts it; the cost is one 11-minute probe. |
| **kcov alone falls below 80%.** | Research §5.2's decision rule, evaluated *before* the workflow changes. The < 70% branch stops and reports rather than quietly lowering anything. |
| **Wider concurrency turns a deterministic scenario flaky.** | V2 runs the corpus twice at the new degree on POSIX and on Windows before the wider form gates. 009 hit exactly this class of defect at exactly this point; the check is the tripwire, and a difference blocks adoption rather than being retried. |
| **A gate silently stops blocking.** | B1–B5, asserted mechanically against the workflow files, on both the job ids and the rendered check-run names. |
| **Measuring against a red baseline.** | `windows-latest` is red for two genuine divergences this feature does not own. Every claim compares verdict *sets*, not green/red (FR-019, V7). |
| **Windows round trips eat the schedule.** | One retry maximum per inconclusive probe run, then report as it stands. Four runners and ~11 minutes per push. |

## Complexity Tracking

> One entry. It is not a constitution violation — it is a conflict with this
> spec's own FR-020, which the spec itself says to escalate rather than resolve
> silently.

| Violation | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| **Removing the second process per `jq` call on Windows.** The port's `jq` wrapper (`scripts/bash/lib/output.sh`) installs itself only when `jq` emits CRLF and pipes every call through `sed`. On Windows that doubles the port's process count — **~500 of a scenario's ~1000 process creations, ~1.9× on the single dominant cost**. Research §3 puts SC-001 out of reach without it in the realistic case. Two routes, both needing a decision: **(a)** put an LF-emitting (MSYS-built) `jq` on the Windows runner, so the wrapper's own condition reports false — *workflow-scoped, no production-code change, FR-020-safe*, but the corpus then exercises a `jq` a stock git-bash user does not have, in exactly the CRLF class quirks 1 and 7 came from; **(b)** make the guard spawn-free inside the port — *production code, frozen by FR-020*, and harder than it looks: `sed $'s/\r$//'` is a per-line transform over a whole stream, and quirk 1 forbids the obvious `$'\r\n'` glob on that host, so a pure-bash form needs a CR-by-CR walk that may cost more than the `sed` it replaces. | The frozen-code alternatives were costed, not assumed: concurrency (≤ 2×, unproven), Defender exclusions (1.3–2×, unproven), test-owned spawn removal (~1.25×, measured). Multiplied at their realistic values they reach ~33 minutes against a ~10.5-minute step budget. The genuinely simpler alternative is **to relax SC-001** to what frozen code can deliver — a spec decision, not a plan decision, which is why this sits here awaiting the user rather than being implemented. Precedent: 009 faced the identical tension and resolved it the other way (T028 touched `engine/story_marker.sh` because leaving a race on a blocking gate was worse than the scoping rule). |

**Status**: **awaiting the user's decision** between (a), (b), and relaxing
SC-001. Note that (a) needs no FR-020 exception at all — it is a fidelity
trade-off rather than a scoping one, and if chosen it should be recorded in
`docs/10-windows-portability.md` as a deliberate divergence between what CI
exercises and what a stock Windows host runs.

Phases A, B, D and E proceed regardless; only Phase C's ceiling depends on this.
If the answer is "none of the above", Phase E records the measured shortfall and
SC-001 is renegotiated against evidence rather than quietly missed.
