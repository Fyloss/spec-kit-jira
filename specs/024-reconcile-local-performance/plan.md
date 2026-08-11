# Implementation Plan: The Time Reconcile Spends Is Its Own, and the Instrument That Says So Works Everywhere

**Branch**: `worktree-fix+optimize-code` | **Date**: 2026-08-10 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/024-reconcile-local-performance/spec.md`

## Summary

Reconcile's local processing is dominated by process creation, and the instrument that would prove it has two
defects of its own. This plan fixes the instrument first — the locale crash, then the request counter — because
neither the baseline nor any success criterion can be read until both are sound. It then cuts the spawn count
phase by phase.

**The maintainer's consuming-repo profile is authoritative and drives the work order.** A secondary
measurement taken here against the conformance fixture and a mock tracker serves one purpose: it removes
network time by construction, which isolates the mechanism. The two agree, and [research.md](./research.md) R3
shows why they report different seconds for the same work:

- **What is invariant across both environments** is what the run *does*: it re-reads the same configuration
  file in more than one phase, and it spawns a process per item in several loops. Both are machine-independent
  properties of the code.
- **What varies is what each of those costs.** Measured directly on the maintainer's machine: a bare spawn is
  **1.1 ms**, the same spawn with a here-string attached is **6.1 ms**, and one full read-and-parse of
  `config.local.yml` is **~33 s**. The security-agent multiplier is real, but it applies to **file
  operations**, not to `exec` — see research R3a, which corrects R3.

So every phase in the maintainer's profile is in scope at the priority he measured. The isolation run **adds**
one: with network removed, `parse` alone burns 52.7 s of pure CPU, which the consuming-repo profile
under-weights at 20 s. Nothing is traded away.

**Consequence for the success criteria — a correction to an earlier version of this plan.** This plan first
designated spawn count as *the* invariant and stated every step's exit condition as a spawn-count reduction.
Measurement retired that: cutting spawns 38% moved wall time 4.5%, while removing a single duplicated config
read moved one phase by 91%. Spawn count remains real, useful and machine-independent, and FR-016/FR-017
stand — but it is **no longer the primary lever**. Each step below states its exit condition in the terms its
own evidence supports:

- **Redundant reads eliminated** — the first-order cost; counted, machine-independent.
- **Spawn count reduced** — the second-order cost; counted, still required by FR-016/FR-017.
- **Wall clock** — recorded as evidence on both machines, asserted in no suite (A-3).

## Technical Context

**Language/Version**: Bash 3.2+ (macOS/Linux port, with a bash-5 fast path), PowerShell 7+ (Windows port)

**Primary Dependencies**: `curl`, `jq`, `git` — runtime dependency set is frozen (FR-035); this feature removes
`jq` invocations, adds none

**Storage**: Filesystem only — `.specify/jira/config.yml`, `config.local.yml`, and the run-state document

**Testing**: `bats` (`tests/run-bash.sh`, ~190 s), Pester, and the cross-port conformance corpus
(`tests/conformance/ci-conformance.sh`, 140 scenarios); `shellcheck` and `actionlint` gates

**Target Platform**: macOS, Linux, Windows — all three CI-gated; Windows divergences diagnosed on the real
runner only. **Corporate-managed macOS with endpoint security is a first-class target**, not an edge case: it
is where the motivating profile was taken and where the spawn cost is 4–7× higher.

**Project Type**: CLI tool — two native ports proven equivalent by a shared conformance corpus

**Performance Goals**: Local processing under 20 s on the reference specification, no single phase over 5 s
(FR-023, FR-024). Primary, machine-independent target: **spawn count bounded by phases + requests** (FR-016,
FR-017), from ~20 243 today.

**Constraints**: Byte-identical observable behaviour — stdout, stderr, exit code, written files, and the
recorded Jira call sequence (FR-021, FR-032); no concurrency (FR-022); no new dependency (FR-035)

**Scale/Scope**: Reference specification is 1 epic + 60 stories
(`tests/conformance/fixtures/repo-with-widget-spec-61`); must degrade gracefully well beyond it (FR-026)

## Constitution Check

*GATE: passed before Phase 0 research; re-checked after Phase 1 design — result unchanged.*

The specification's own Constitution Check covers all sixteen principles at the requirements level. This gate
records only what the **design** adds or puts at risk.

| # | Principle | Design-level gate | Status |
| --- | --- | --- | --- |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | The instrument fails **open** (FR-003) while writes stay fail-closed. The fail-open guard lives entirely inside `lib/timing.sh` and returns success; no write path acquires a fail-open branch. | **PASS** — bounded exception, argued in spec |
| VI | Portability | Consolidation removes `jq` calls rather than adding direct ones, satisfying the Windows-CRLF discipline a fortiori; the one remaining batched serialisation still routes through `lib/output.sh` (FR-020). PowerShell needs no equivalent change (R7). | **PASS** |
| VIII | Neutral Engine / Jira Sink | Parse work is engine-side and stays engine-side; the request counter is sink-side and stays sink-side. No module crosses the boundary. | **PASS** |
| XIII | TDD With ≥80% Coverage | Every step is failing-test-first, and the decisive tests are deterministic **counting** tests, not wall-clock assertions — which R3 makes not merely convenient but correct, since wall-clock is a property of the host's spawn cost. | **PASS** |
| XIV | KISS | The chosen clock read is *fewer* operations than today's (R1); the parse fix *removes* helpers. Net complexity is negative. | **PASS** |
| XV | YAGNI | Nothing is built that a requirement does not demand. The PowerShell work resolves to a recorded profile, not code (R7). | **PASS** |

**One deliberate exception, tracked in Complexity Tracking**: fixing the request counter (R2) changes one
existing conformance expectation. Spec FR-032 carves out that single case — the expectation was encoding the
FR-036 defect — and treats any second changed expectation as a scope-creep signal that stops the work.

## Project Structure

### Documentation (this feature)

```text
specs/024-reconcile-local-performance/
├── plan.md              # This file
├── research.md          # Phase 0 — the two profiles reconciled, and the decisions
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1 — how to reproduce every measurement
├── contracts/
│   ├── clock-reading.md     # Locale-independent clock contract
│   ├── request-counting.md  # Request counter contract (the R2 defect)
│   └── spawn-budget.md      # Per-phase external-process budget
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/bash/
├── lib/
│   ├── timing.sh            # STEP 1: locale-independent clock + fail-open guard
│   ├── config.sh            # STEP 6: YAML parser forks per line (~6 ms/line unmanaged)
│   └── output.sh            # unchanged; remains the only structured-output route
├── sink/jira/
│   ├── client.sh            # STEP 2: request counter escapes the subshell
│   ├── plan_apply.sh        # STEP 5: per-item spawn removal (gate + plan + apply)
│   └── recognition.sh       # STEP 5: measured first — 5.4 s on the rig, <1 s under EDR
├── engine/
│   ├── parse.sh             # STEP 4: two per-line jq loops
│   ├── story_marker.sh      # marker recognition consumed natively by parse
│   └── spec_marker.sh       # idem
└── commands/reconcile.sh    # phase boundaries only; not expected to change

scripts/powershell/
├── lib/Timing.psm1          # verified sound (R7) — profiled, not changed
└── engine/Parse.psm1        # verified fork-free (R7) — profiled, not changed

tests/
├── bash/lib/test_timing.bats        # locale matrix + fail-open regression tests
├── bash/helpers/spawn_count.bash    # NEW: PATH-interposed counting stand-in
└── conformance/scenarios/
    └── us021-timing-on.json         # the one expectation this feature edits
```

**Structure Decision**: No new module on either port. This feature is subtractive — it removes helper
invocations, corrects two defects, and adds exactly one test helper. Module-for-module cross-port equivalence
(FR-033) is preserved by construction: nothing is added on the Bash side that PowerShell would need to mirror.

## Work sequence

The order follows the user's instruction: **the locale fix is first because it unblocks the "after-fix"
baseline that every later step is measured against.** That same rationale forced Step 2 into the same position.

### Step 1 — The clock reads correctly on any locale *(FR-001…FR-005, FR-008)*

Failing test first: assert a **correct duration** under `fr_FR.UTF-8` against a known elapsed time. Per FR-005
this must not be an error-absence assertion — the defect is silent for ~90% of clock readings (R1), so an
error-absence test passes against the broken code most of the time.

Then: replace the dot-split in `lib/timing.sh:112-114` with the strip-all-non-digits read (R1 option C), and
wrap every clock tier in a digit-shape guard that degrades instead of erroring under `set -e`.

**Exit**: report correct under `C`, `fr_FR.UTF-8`, `de_DE.UTF-8`; byte-identical across all three under the
injected clock.

### Step 2 — The request counter tells the truth *(FR-036, FR-037; unblocks SC-005, SC-014, FR-023)*

> **Found by measurement during planning, then given a requirement.** Measured: the reference run issues
> **123 requests** and the report attributes **0 to every phase** (R2). `jira_request` increments inside a
> `$( … )` subshell at 15 of its 28 call sites. SC-005 and FR-023 are written about "phases **excluding
> request time**", unmeasurable while the counter reads zero — the same argument that puts the locale fix
> first. **This is also what prevents the consuming-repo profile from being decomposed into CPU and network
> after the fact**: the information was never recorded, on either machine. The specification was amended to
> carry FR-036 and FR-037 rather than leaving this work without a requirement, which is what Principle XV
> demands.

Failing test first: a run against the mock reports per-phase counts matching `calls.log`.

**Cost**: changes the `requests` column from `0` to real numbers, changing the expected stderr of
`us021-timing-on.json`. Justification in Complexity Tracking; blast radius measured — three scenarios enable
timing, one asserts counts.

**Exit**: per-phase request counts match `calls.log`, on both ports.

### Step 3 — Re-baseline on both machines *(FR-027)*

With a trustworthy instrument, record the reference profile **on the maintainer's consuming repo** and on the
isolation rig. This is the first point at which the consuming-repo profile can be split into CPU and network,
which is the measurement Steps 4-6 are judged against. Counting and timing are **separate runs** — the shim
distorts wall time by 61% (R4).

Recorded starting points:

| | consuming repo (authoritative) | isolation rig (pure CPU) |
| --- | --- | --- |
| total | 3–6 min | 91 515 ms |
| config / gate | 84 s / 79 s | 514 ms / 465 ms |
| parse | 20 s | **52 698 ms** |
| plan / apply | 83 s / 82 s | 16 286 ms / 16 164 ms |
| spawns | ~20 000 | **20 243** |
| cost per spawn | ~~9–18 ms (implied)~~ → **1.1 ms (measured 2026-08-11)** | **2.445 ms (measured)** |
| cost per `config.local.yml` read | **~33 s (measured 2026-08-11)** | sub-second |

### Step 4 — Parse stops forking per line *(FR-016…FR-019)*

Two patterns (R5): `_parse_strip_marker_lines` runs two `jq` pipelines **per line** — over the whole document
*and* again per story section; `_parse_lines_to_json` runs one `jq` **per line**, each re-parsing the
accumulator (O(n) spawns, O(n²) data).

Marker recognition becomes a native `[[ =~ ]]` match; array accumulation becomes a bash array serialised by a
single batched call. Failing test first: the spawn-count assertion (count does not grow when stories double),
with the corpus diff as the behavioural guard.

**Exit**: spawn count for this phase no longer grows with item count; `parse` under 5 s on the isolation rig;
corpus byte-identical.

### Step 5 — Gate, plan, apply *(FR-016…FR-019)*

The three phases the maintainer measured at 79 s, 83 s, and 82 s. Same treatment against
`sink/jira/plan_apply.sh`, one phase at a time with a re-measure between: FR-021 requires the recorded call
sequence to stay byte-identical, and a corpus divergence is far cheaper to bisect after one phase's change than
after three.

**Exit per phase**: spawn count flat in item count; corpus byte-identical.

`recognition` joins this step, measured before it is touched. It costs 5 377 ms on the isolation rig — over
FR-024's 5-second ceiling, and the only phase left over it once the four above are cut. It is also the one
phase whose two profiles disagree in *direction*: under 1 s on the maintainer's machine, where every other
phase is 4–7× worse. A phase that is cheaper under EDR is not spawn-bound, so the counter says what the
mechanism is before any consolidation is justified by it (spec A-2). If the count is already flat, that is
the answer to FR-024 for this phase and it is reported, not tuned.

### Step 6 — Configuration read once, and parsed without forking *(FR-009…FR-015)*

The maintainer's heaviest single phase at 84 s. Two mechanisms were proposed; **measurement has since ranked
them, and the ranking is the reverse of what this step first assumed**:

- **Parse without forking per line** — assumed here to be the dominant mechanism (~6 ms/line on unmanaged
  hardware, "proportionally more under EDR"). **Implemented (T038) and it did not move the phase**: the
  per-line `jq` calls are gone — an 82-line config that cost ~160 spawns now costs 2 — and `config` still
  costs ~34 s on the maintainer's machine. Worth keeping, correctly scoped, not the cause.
- **Read once per run** (FR-009, FR-010, and now FR-038) — the actual dominant mechanism. One
  `config.local.yml` read-and-parse is directly measured at **~33 s** on that machine, and the run performs
  **two**: `config_load` for `overrides`, `_reconcile_local_binding_for` for `resolved_ids`. `config` (~34 s)
  and `gate` (~33 s) are each one such read. Together they are 58% of the post-fix runtime.

**Exit**: `config.local.yml` opened and parsed **once** per run, asserted by a counting stand-in (FR-040); the
file-read count flat in configuration line count and item count; spawn count likewise.

### Step 7 — PowerShell: profile and record *(US5, FR-033)*

Resolves to a recorded profile, not code (R7). `Timing.psm1` reads `[datetime]::UtcNow.Ticks / 10000` — Int64
arithmetic, no textual decimal, so the locale defect cannot occur, confirming spec A-7 by measurement.
`Parse.psm1` uses in-process `ConvertTo-Json`/`ConvertFrom-Json` at 26 sites and spawns no external process —
and a port that does not spawn is immune to EDR spawn cost entirely. One open item is verified here: whether
the port shares the Step 2 counter defect.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Step 2 edits an existing conformance expectation (`us021-timing-on.json`) — the one expectation this feature changes | SC-005 and FR-023 are defined as "phases excluding request time". With the counter stuck at 0 (measured: 123 actual vs 0 reported) that quantity does not exist, so the headline criterion cannot be evaluated on a live tracker — the environment that matters. The expectation being edited was encoding the bug, and FR-032 now carves out this one case explicitly. | Deferring the counter to its own spec leaves this feature's primary success criterion unverifiable for the whole duration of the work, and leaves the consuming-repo profile permanently undecomposable into CPU and network. |

## Open items for the user — not silently decided

1. **FR-025's 20% variance bound.** On the isolation rig it already measures 5.3%. The 79% you measured is
   consistent with EDR inspection cost varying under system load (R3) rather than with local scheduling — which
   means cutting ~20 000 spawns to a few hundred removes almost all of the exposure, but the residual is not
   fully under this feature's control. Recommendation: keep the bound and measure it after the cuts land,
   rather than treating it as a design constraint now.
2. ~~**Step 2 is an addition to the specification's scope.**~~ **Resolved 2026-08-10** — the spec was amended
   to carry FR-036 and FR-037 (and SC-014), so the request counter is now ordinary in-scope work rather than
   an unrequirement-ed addition, and FR-032 carves out the one expectation it changes.
3. ~~**Worth confirming when you next profile**: the per-spawn cost on the consuming-repo machine.~~
   **Resolved 2026-08-11 — and it falsified R3's estimate.** Measured on that machine: a bare spawn is
   **1.1 ms**, not 9–18 ms; the ×5.5 penalty appears only once a here-string is attached, and one
   `config.local.yml` read-and-parse costs **~33 s**. The multiplier applies to file operations, not `exec`
   (R3a). The practical consequence is the opposite of what this item anticipated: a spawn reduction will
   feel *less* dramatic there than an unmanaged benchmark predicts, and a redundant-read reduction will feel
   far more.
