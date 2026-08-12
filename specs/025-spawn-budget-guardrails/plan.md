# Implementation Plan: The Process Budget Outlives the Feature That Measured It

**Branch**: `feat/spawn-budget-durable-guardrails` | **Date**: 2026-08-12 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/025-spawn-budget-guardrails/spec.md`

## Summary

Feature 024 cut a real reconcile run from 154 942 ms to 17 117 ms by removing per-item process
spawning, and built the instruments to prove it. This feature keeps that property from decaying:
it moves the budget out of the merged feature's folder into `docs/11-process-budget.md` with a
pointer from the automatically-loaded `AGENTS.md`, lifts clause **C1.2** (the count must not grow
with the number of stories, tasks and configuration lines) from the four individually-named
functions that assert it today to the **whole run**, and makes the oversized-argument defect
detectable on the machine where the work happens instead of only on Linux CI.

C1.1's absolute bound — a total under *(small constant × phases)* — remains deliberately
unasserted. FR-012 forbids writing an expected total into these tests, precisely so that unrelated
work removing a `jq` call cannot turn the suite red; a hardcoded C1.1 is that forbidden shape. What
this feature closes is the *scope* gap (named functions → whole run), not the *bound* gap.

The design turns on one research finding (R1): the obvious whole-run assertion is impossible as
first conceived, because the Bash port's mock replaces `curl` with a script that itself runs `jq`
52 times, so any whole-run count measures the test double as well as the port. The assertion is
therefore built on a scenario that holds the request count **constant** while the item count
doubles — which keeps both `curl` and the mock's internal work flat, and needs no change to
shared conformance infrastructure.

## Technical Context

**Language/Version**: Bash 3.2+ (macOS system bash) and PowerShell 7+ — the two existing ports.
No new language.

**Primary Dependencies**: `bats` and `jq` for the Bash suite; Pester for PowerShell. The
`tests/conformance/mock-jira` double. No new dependency.

**Storage**: N/A — this feature adds documentation and test assertions; it introduces no state.

**Testing**: `tests/run-bash.sh` (full Bash suite), `bash tests/conformance/ci-conformance.sh`
(cross-port byte equivalence), `shellcheck`, `actionlint`.

**Target Platform**: macOS, Linux, Windows — every assertion added here must return the same
verdict on all three (FR-013).

**Project Type**: CLI bridge with twin native ports, plus contributor-facing documentation.

**Performance Goals**: none of its own. This feature *protects* feature 024's goals (FR-023
<20 s total, FR-024 no phase >5 s); it does not pursue new ones and performs no optimisation pass.

**Constraints**: assertions expressed as counts and non-growth, never elapsed time (FR-007);
the differential shape must be preserved rather than replaced by hardcoded totals (FR-012); no
production behaviour may change (SC-007).

**Scale/Scope**: one new `docs/` page, one `AGENTS.md` section, one header line on feature 024's
contract, and two test surfaces (a whole-run budget test, an argument-size shim plus its test).

## Constitution Check

*GATE: passed before Phase 0; re-evaluated after Phase 1 design — see "Post-Design Re-Evaluation".*

The specification carries the full sixteen-principle table. At plan level only the principles the
*design* newly engages are re-argued; the rest are unchanged from the spec's assessment.

| # | Principle | Design-level proof |
| --- | --- | --- |
| VI | macOS / Linux / Windows Portability | **Strengthened by this design, not merely respected.** R3 found the existing E2BIG test is a no-op on macOS — it detects `exec` failing, which only Linux does. D4 replaces symptom-detection with cause-detection (argument length), so the defect becomes visible on every host. This is the principle's measurement-over-emulation rule applied in the only direction available: rather than emulating Linux on macOS, the assertion measures the quantity that *causes* the Linux failure, which is platform-neutral. |
| XIII | TDD With a Minimum 80% Coverage | US2 and US3 are failing-test-first by construction. Each is specified by the defect it must catch, so the sequence is: write the assertion, introduce the defect deliberately, observe red, remove it, observe green. The plan's task ordering makes that explicit rather than leaving it to the implementer. |
| XIV | KISS | Three deliberate simplifications, each recorded in research: reuse the existing shim mechanism rather than build a second one (D4); reuse the existing in-process reconcile driver (D3); and choose the constant-request scenario specifically because it needs **no** change to the mock (D1). The rejected alternative — teaching the mock to bypass the counter — was simpler to describe and worse to own. |
| XV | YAGNI | Scope stops at the guardrail. `plan_writes`' deferred per-story payload work (024 T030) is left alone even though this feature's own assertion is what would catch it; optimising it is a separate feature. Amending the constitution with a performance principle is likewise excluded and left to an explicit amendment. |
| XVI | Human Readable | FR-004 requires the durable document to carry the reasoning and the measured evidence, including the fact that the paired defect was reintroduced after being fixed. A rule stated without its history invites a future reader to "simplify" it back into the trap. |

**Gate verdict: PASS.** No violation to justify; the Complexity Tracking table below is empty by
design.

## Project Structure

### Documentation (this feature)

```text
specs/025-spawn-budget-guardrails/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 output — R1-R4 and decisions D1-D6
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output — how to verify each story
├── contracts/
│   ├── whole-run-budget.md   # measurement protocol for the whole-run assertion
│   └── argument-size.md      # the oversized-argument rule and its detection
├── checklists/
│   └── requirements.md  # spec quality checklist (16/16)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
docs/
└── 11-process-budget.md          # NEW (US1) — the durable, authoritative rule

AGENTS.md                          # MODIFIED (US1) — short section + pointer,
                                   #   mirroring "Windows portability — non-negotiable"

specs/024-reconcile-local-performance/
└── contracts/spawn-budget.md      # MODIFIED (US1/FR-005) — header line ceding
                                   #   authority; measurements left intact

tests/bash/
├── helpers/
│   ├── spawn_count.bash           # UNCHANGED — reused as-is
│   ├── spec_fixture.bash          # NEW (Phase 2) — parameterised spec/tasks generator
│   └── argv_size.bash             # NEW (US3) — argument-length shim
├── ci/
│   ├── test_process_budget_doc.bats     # NEW (US1) — discoverability guard
│   ├── test_spec_fixture_helper.bats    # NEW (Phase 2) — fixture self-test
│   └── test_argv_size_helper.bats       # NEW (US3) — shim self-test
├── commands/
│   └── test_reconcile_run_budget.bats   # NEW (US2) — whole-run assertion
└── sink/
    └── test_argv_size.bats        # NEW (US3) — oversized-argument detection
```

Helper self-tests go in `tests/bash/ci/`, where the four existing ones already live
(`test_spawn_count_helper.bats`, `test_mtime_helper.bats`, `test_calls_log_helper.bats`,
`test_secret_store_stub_helper.bats`). Beyond convention, `tests/run-bash.sh:125` treats any change
under `tests/bash/helpers/*` as an undeterminable affected set and fails `--since` open to a FULL
run — a `.bats` file there would force a full-suite run on every edit to itself.

**Structure Decision**: no new source tree. The two ports are untouched — this feature adds one
contributor-facing document, one instruction-file section, and test-side assertions only. That is
what makes SC-007 (byte-identical conformance output) achievable by construction rather than by
verification: no file under `scripts/` is modified.

## Phase 1 Design Notes

**The whole-run assertion (US2)** generates a specification of *N* already-bound stories, runs
`cmd_reconcile … --force` under the counting shim, then repeats at 2*N*. It asserts three things,
in this order, because the order is what makes a failure diagnosable:

1. the two runs issued the **same number of requests** (the premise — D2);
2. the total process count is **unchanged** between them (the budget — C1.2);
3. a zero-item specification reaches a defined floor (C1.4).

Asserting the premise first means a future change that makes requests grow reports itself as
"the scenario no longer holds requests constant" instead of as a spurious budget breach.

**The argument-size assertion (US3)** installs a shim ahead of `jq` that measures each element of
`$@` and records any element exceeding 128 KiB. The whole-run scenario runs under it, so every
call site the run reaches is covered — not only the one path
`test_reconcile_large_spec.bats` exercises today. The threshold is Linux's `MAX_ARG_STRLEN`
regardless of the host, which is the point: a macOS developer gets the Linux verdict.

**The durable document (US1)** is written from feature 024's contract plus the two things that
contract does not carry: the measured real-machine before/after, and the reintroduction history
that makes the batching rule and the argument-routing rule inseparable.

## Post-Design Re-Evaluation

Re-checked after the design above was fixed. **Still PASS**, with two observations worth recording
rather than hiding:

1. **The design's central choice was forced by measurement, not preference.** D1 exists because
   the mock's `curl` replacement runs `jq` 52 times per request — discovered by reading
   `curl-shim.sh`, not by reasoning about it. Had the plan been written from the obvious design,
   the assertion would have grown with request count and been "fixed" by loosening it into
   uselessness. This is the same failure mode Principle VI's measurement rule exists to prevent,
   in a non-platform setting.

2. **One honest limit.** The whole-run assertion covers the Bash port only. The PowerShell port
   creates no external process per item by construction (024 research R7), so the same assertion
   there would pass vacuously and prove nothing — the spec's fifth edge case forbids reporting
   that as evidence. The PowerShell port's protection against this defect class remains
   structural (it does its JSON work in-process) rather than tested, and the durable document
   must say so plainly instead of implying symmetric coverage.

## Complexity Tracking

> No Constitution Check violations. Table intentionally empty.
