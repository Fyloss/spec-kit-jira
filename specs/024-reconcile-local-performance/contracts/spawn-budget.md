# Contract: Per-Phase External-Process Budget

**Feature**: 024 | **Satisfies**: FR-016, FR-017, FR-018, FR-019, FR-020, FR-021, FR-026

Governs how many external processes a reconcile may create, and how that is measured. Applies to the Bash port;
the PowerShell port does its JSON work in-process and spawns nothing per item (research R7), so it satisfies
this contract already and is verified rather than changed.

## §1 The budget

**C1.1** — Total external processes per run ≤ *(small constant × phases)* + *(one per Jira request)*.

**C1.2** — The count must not grow with the number of stories, tasks, or configuration lines (FR-016). Doubling
the item count must leave it unchanged.

**C1.3** — No loop on the reconcile path spawns a process per item, and none spawns one per **field** of an item
(FR-018).

**C1.4** — A zero-item specification reaches the same per-phase floor as the reference (spec US3 AC4). A bound
that holds only at the reference size is not a bound.

**C1.5** — Where a transformation genuinely needs an external tool, it is invoked a bounded number of times for
the whole set, and its batched output is byte-identical to the concatenation of today's per-item outputs
(FR-019).

## §2 Measured starting point

**20 243 `jq` invocations** for the 61-item reference specification — roughly **332 per mirrored item**, i.e.
proportional to input where C1.2 demands constant.

**Why this, and not wall-clock, is the contract's primary quantity.** Spawn count is a property of the code;
wall-clock is a property of the code *times the host's per-spawn cost*. Measured (research R3): **2.445 ms**
per `jq` spawn on unmanaged macOS, against **9–18 ms** implied by the consuming repo's 3–6 minutes — the
signature of an endpoint-security agent inspecting every `exec`, which is standard on corporate-managed
machines. Two engineers on differently-managed laptops will disagree about seconds and agree exactly about
spawns.

Two consequences:

- A conformance-suite assertion on spawn count is meaningful on any runner; one on duration is not.
- Every spawn removed is worth ~2.4 ms on unmanaged hardware and 9–18 ms on a managed one, so this contract
  delivers **4–7× more on the target environment** than a benchmark taken on unmanaged hardware predicts.

Dominant sources (research R5):

| Pattern | Cost |
| --- | --- |
| `_parse_strip_marker_lines` (`engine/parse.sh` l. 34-44) | Two `jq` pipelines — ≥4 processes — **per line**; run over the whole 545-line document *and* again per story section |
| `_parse_lines_to_json` (`engine/parse.sh` l. 66-73) | One `jq` **per line**, each re-parsing the accumulator: O(n) spawns, O(n²) data |
| `parse_story` (`engine/parse.sh` l. 373) | Six command-substitution pipelines + `jq` + `json_canonical`, per story, on top of the above |
| YAML parser (`lib/config.sh`) | Forks per configuration line — ~6 ms/line unmanaged, proportionally more under EDR; this is why `config` dominates on the maintainer's machine while measuring 0.5 s on the isolation rig |
| Per-item work (`sink/jira/plan_apply.sh`) | Drives the `gate`, `plan`, and `apply` phases |

## §3 Preserved disciplines

**C3.1** — The Bash port must not call `jq` directly for multi-line output; the Windows build emits CRLF. All
structured output goes through `scripts/bash/lib/output.sh` (FR-020). Removing `jq` calls satisfies this a
fortiori, but the remaining batched call still routes through the output module.

**C3.2** — Paths handed to `curl` keep their `cygpath -m` spelling (FR-020).

**C3.3** — The recorded Jira call sequence — requests, order, payloads — stays byte-identical (FR-021).

**C3.4** — No concurrency, anywhere (FR-022). Speed comes from doing less per item, never from doing several at
once. Feature 021 rejected concurrency on determinism grounds and that decision stands.

**C3.5** — Marker recognition moved in-process must produce **exactly** today's classification for every case,
including malformed and duplicate markers. The consolidation is a change of mechanism with a null observable
diff.

## §4 Measurement method

**C4.1** — A `PATH`-interposed counting stand-in: a shim earlier on `PATH` that records one line per invocation
then `exec`s the real tool. No new dependency; works identically for `jq`, `sed`, `awk`, and `curl`.

**C4.2** — **Counting runs and timing runs must be separate runs.** Measured: the shim costs a process per call
and inflated the reference run from 91 515 ms to 147 774 ms — a **61% distortion**. A test that asserts a
duration and a count in the same run is measuring the shim.

**C4.3** — The count assertion is the deterministic one and belongs in the suite. Wall-clock budgets are
recorded as dogfood evidence, not asserted in CI, where runners are an order of magnitude slower than a
developer laptop (spec A-3).

**C4.4** — Behavioural proof is the corpus diff, run after **each** phase's consolidation rather than once at
the end — a divergence is far cheaper to bisect after one phase's change than after four (research R6).

## §5 Verification

| # | Assertion |
| --- | --- |
| V1 | Reference specification: total spawns within C1.1's bound |
| V2 | Doubling stories and tasks leaves the spawn count unchanged (C1.2) |
| V3 | Zero-item specification reaches the same floor (C1.4) |
| V4 | Full conformance corpus byte-identical: stdout, stderr, exit, tree, `calls.log` |
| V5 | `parse` under 5 s on the reference specification (FR-024) |
| V6 | Local processing total under 20 s (FR-023) |
| V7 | Windows: line endings and encoding unchanged, verified on the real runner — never by emulation |
