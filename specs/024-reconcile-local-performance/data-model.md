# Phase 1 Data Model: Reconcile Local Performance

**Feature**: 024-reconcile-local-performance | **Date**: 2026-08-10

Three entities, all **process-scoped and non-persistent**. Nothing here is written to disk, enters a payload,
or survives the run — which is why none of them appears in the run-state fingerprint or the conformance tree
diff.

---

## 1. Clock reading

One observation of the host wall clock, taken at a phase boundary.

| Field | Type | Notes |
| --- | --- | --- |
| `raw` | string | As the shell renders it. **Its decimal separator is a property of the host, not of the reading.** |
| `digits` | string | `raw` with every non-digit removed. The only form arithmetic ever sees. |
| `ms` | integer | Milliseconds since the epoch: `digits / 1000` on the microsecond-precision tier. |
| `valid` | boolean | `digits` matches `^[0-9]+$`. False ⇒ the instrument degrades; the run is untouched. |

**Invariants**

- **C1** — No code path may reference a decimal separator character. Locale independence is structural
  (FR-002); a solution that could be broken by an unfamiliar separator has already failed.
- **C2** — `digits` is derived before any arithmetic. The defect being fixed is arithmetic performed on a
  string that still contains a separator (research R1).
- **C3** — `valid == false` never propagates a non-zero status. Under `set -euo pipefail` a failing arithmetic
  expansion aborts the run, which is the crash this feature removes (FR-003).
- **C4** — Invariants C1-C3 hold for **every** clock tier, not only the microsecond one. FR-003 is written
  about any failure of the instrument.

**Lifecycle**: created at `timing_phase_begin` / `timing_phase_end`, consumed immediately into a phase record,
never stored.

---

## 2. Phase record

The elapsed time and request count of one named phase of one run.

| Field | Type | Notes |
| --- | --- | --- |
| `phase` | enum | One of the eight fixed names, in fixed order: `prereq`, `state`, `config`, `parse`, `gate`, `recognition`, `plan`, `apply`. |
| `start_ms` / `elapsed_ms` | integer | From clock readings. |
| `start_requests` / `requests` | integer | Delta of the run's request counter across the phase. |
| `reached` | boolean | Unreached phases are omitted from the report, never printed as zero. |

**Invariants**

- **P1** — The phase set is closed. This feature adds, removes, and renames nothing (spec A-9).
- **P2** — Report order is the canonical order above, never call order.
- **P3** — `requests` must equal the number of requests the phase actually issued (FR-036). **Violated
  today**: the reference run issues 123 requests and every phase reports 0 (research R2). This is the defect
  Step 2 fixes.
- **P4** — The record is stderr-only, and carries no credential material (FR-007).

**Relationship to the request counter**: `requests` is a *delta of a counter owned elsewhere* — in the sink's
client. P3 therefore cannot be satisfied inside the timing module alone; it depends on the counter entity
below. This coupling is the reason Steps 1 and 2 are adjacent in the plan.

---

## 3. Run request counter

A single monotonic count of tracker requests issued by the run.

| Field | Type | Notes |
| --- | --- | --- |
| `count` | integer | Incremented once per request, retries included. |
| `scope` | — | **The reconcile process**, not the shell that happens to issue the request. |

**Invariants**

- **R1** — The increment must be observable by the parent shell. **Violated today**: `jira_request` is invoked
  through `$( … )` at 15 of its 28 call sites, so the increment happens in a command-substitution subshell and
  is discarded on exit.
- **R2** — The counter is observability only. A failure to count must never change a request, a payload, an
  ordering, or an outcome — the same fail-open discipline as the clock (FR-037, mirroring FR-003).
- **R3** — Both ports expose the same count for the same scenario; the value is conformance-diffed, so a
  cross-port divergence is a test failure rather than a quirk.

**Known-good comparison**: `calls.log` from the conformance harness is the ground truth a test asserts against.

---

## 4. Phase spawn budget *(a constraint, not a stored value)*

The number of external processes one phase may create. It has no runtime representation — it exists as an
assertion in the suite — but it is the quantity FR-016 and FR-017 are written about, so it is modelled here.

| Property | Rule |
| --- | --- |
| Bound | A small constant per phase, plus one per Jira request (FR-017). |
| Independence | Must not grow with story count, task count, or configuration line count (FR-016). |
| Floor | A zero-item specification must reach the same per-phase floor as the reference (spec US3 AC4). |
| Measurement | A `PATH`-interposed counting stand-in; counting and timing runs are **separate**, since the shim distorts wall time by 61% (research R4). |
| Why counted, not timed | Spawn count is a property of the code; wall-clock is that count **times the host's per-spawn cost**, measured at 2.445 ms unmanaged against 9–18 ms implied on a corporate-managed host (research R3). Only the count is comparable across machines. |

**Measured today**: 20 243 `jq` invocations for 61 items — roughly 332 per item, i.e. proportional to input
where the requirement demands constant. At the managed host's per-spawn cost that is 3–6 minutes; at the
unmanaged host's, 91.5 s. Same code, same count, one multiplier.

---

## Entity relationships

```text
Run
 ├── Run request counter  (one per process; sink-owned)
 │        ▲ read as a delta by
 ├── Phase record × 8     (command-layer; stderr-only)
 │        ▲ built from
 └── Clock reading × 16   (two per phase; port infrastructure)

Phase spawn budget ──asserts against──> Run   (test-time only; no runtime entity)
```

**Boundary check (Principle VIII)**: clock readings are port infrastructure and carry no tracker knowledge;
phase records are command-layer; the request counter is sink-owned and read across the existing interface. No
entity crosses the engine/sink boundary, and none is added to either side.
