# Contract: Request Counting

**Feature**: 024 | **Satisfies**: FR-036, FR-037; **unblocks** SC-005, SC-014, FR-023, FR-024

> **Provenance.** The defect this contract governs was found by measurement during planning, not by the
> original specification. FR-036 and FR-037 were added to the spec by amendment once it was measured; this
> contract is written against them, not against FR-007, which covers the report's shape and says nothing
> about counts.

## §1 The defect, measured

The reference scenario (`us021-prefetch-count-61`) issues **123 requests** — `wc -l` on the harness's
`calls.log` — and the timing report attributes **0 requests to every phase**.

**Root cause**: `scripts/bash/sink/jira/client.sh:153` increments `JIRA_REQUEST_COUNT` in the shell running
`jira_request`. That function is invoked through `$( … )` at **15 of its 28 call sites**, so the increment lands
in a command-substitution subshell and is discarded when it exits. The parent's counter never moves.

**Consequence for this feature**: the request's premise — "`requests: 0ms`, so the time is entirely local CPU"
— reads that zero as evidence. It is not evidence; it is the defect. On the mock the conclusion happens to hold
(research R3 measures 52.7 s in `parse` with a mock tracker), but on the live instance that produced the
3-to-6-minute profile, real HTTPS time is being attributed to whichever phase issued the requests, which is why
the request reports `plan` and `apply` at ~80 s each.

## §2 Required behaviour

**C2.1** — The count is scoped to the **reconcile process**, not to the shell that happens to issue a request.

**C2.2** — Every request increments it exactly once, retries included.

**C2.3** — A phase's reported count equals the number of requests issued between its begin and end marks.

**C2.4** — Counting is observability only. A failure to count must never change a request, a payload, an
ordering, or an outcome — the same fail-open discipline as the clock (see `clock-reading.md` §2).

**C2.5** — Both ports report the same count for the same scenario. The value is conformance-diffed, so a
cross-port divergence is a test failure, not a documented quirk.

## §3 What must not change

**C3.1** — No request, payload, header, or ordering may change (FR-028). Feature 021's bulk-fetch batching,
connection reuse, and once-per-run credential resolution are untouched.

**C3.2** — Report shape is unchanged: same column, same width, same phase order (FR-007). Only the **values**
become correct.

**C3.3** — No credential material may become observable through the counter or its plumbing.

## §4 The one accepted expectation change

Fixing the counter changes the `requests` column from `0` to real numbers, which changes the expected stderr of
**`tests/conformance/scenarios/us021-timing-on.json`**.

Blast radius, measured: three scenarios enable timing (`us021-timing-on`, `us021-timing-off`,
`us021-state-unchanged`); only `us021-timing-on` asserts counts.

Spec FR-032 carves this out explicitly, and nowhere else in this feature: **the expectation was encoding a
bug**, so correcting it is demanded by FR-036 rather than accommodating a behaviour change. The corrected
expectation is derived from `calls.log`, not from the new implementation's output — the test must not be
rewritten to agree with whatever the code now prints. A **second** changed expectation is scope creep and
stops the work.

## §5 Verification

| # | Assertion |
| --- | --- |
| V1 | Reference scenario: summed per-phase request counts equal `wc -l calls.log` (123) |
| V2 | Phase attribution is correct — read phases carry the reads, write phases the writes |
| V3 | A retried request increments the counter for each attempt |
| V4 | Both ports report identical counts for the reference scenario |
| V5 | With counting forced to fail, the run's outcome, exit code, and written files are unchanged |
| V6 | `calls.log` itself is byte-identical to the pre-change run — the fix observes, it does not alter traffic |
