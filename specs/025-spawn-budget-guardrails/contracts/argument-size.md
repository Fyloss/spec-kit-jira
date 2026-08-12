# Contract: Batching and Argument Size Are One Rule

**Feature**: 025 | **Satisfies**: FR-003, FR-011, FR-013

This contract exists because the remedy for a process-budget violation, stated alone, produces a
Linux-only crash. It has been paid for twice: PR #31 fixed it at five call sites, and feature 024's
own consolidation work reintroduced it at three more.

## §1 The rule, stated whole

**A1.1** — A loop that creates one external process per item MUST be replaced by a bounded number
of calls for the whole set (024 C1.3, C1.5).

**A1.2** — **In the same breath**: the batched value produced by A1.1 MUST NOT be passed to a
program as a single command-line argument when it can grow with input. It MUST travel through a
temp file (`json_build`'s established path) instead.

**A1.3** — A1.1 and A1.2 are **one rule**. Applying A1.1 without A1.2 converts a slow run into a
crashed run, on Linux only, invisibly to a macOS developer. Documentation and review MUST NOT
present them as separable.

## §2 The limit

**A2.1** — The binding limit is Linux's `MAX_ARG_STRLEN`: **128 KiB per single argument**, 32 pages.

**A2.2** — It is **not** `ARG_MAX`, the total argument-list size, which is far larger. A value well
inside `ARG_MAX` still fails if one element exceeds `MAX_ARG_STRLEN`. Confusing the two is why the
defect reads as "the arguments aren't that big" during review.

**A2.3** — macOS enforces **no** per-argument cap. The identical run succeeds there. The failure is
therefore not reproducible on the maintainer's development machine by execution.

## §3 Detection — the cause, not the symptom

**A3.1** — Detection MUST measure the **length of each argument**, not whether `exec` failed.

**A3.2** — The threshold in A2.1 is applied on **every** host, including hosts with no such limit.
The verdict is a property of the code under test, which ships to Linux, not of the machine running
the check.

**A3.3** — Rationale, recorded because it is counter-intuitive: the existing
`tests/bash/commands/test_reconcile_large_spec.bats` detects the symptom, and says in its own header
that it "passes on macOS whether or not the defect is present." A symptom-detecting test gives the
maintainer's own machine **no signal at all**, which is why the defect reached CI three times.

**A3.4** — Detection covers **every call site a run reaches**, not one nominated path. It is
achieved by interposition during a whole run, in the same manner as the process counter.

## §4 What passing means

**A4.1** — A run whose largest single argument stays under the threshold passes.

**A4.2** — A value routed through a temp file does not appear in the argument vector at all, and so
cannot breach A2.1 regardless of size. That is the shape A1.2 requires.

**A4.3** — Output equivalence is unaffected: a batched call's result MUST remain byte-identical to
the concatenation of the per-item results it replaced (024 C1.5).

## §5 Failing test first (Constitution XIII)

**A5.1** — The assertion is accepted only after being observed **red**: an oversized value is routed
through a single argument at a call site **other than** the one `test_reconcile_large_spec.bats`
already exercises, the suite fails, the change is reverted, and the suite passes.

**A5.2** — The red observation MUST be made on the development host (macOS), not only on Linux CI.
Demonstrating that is the entire point of A3.1 — if the test can only go red on Linux, it has not
improved on what already exists.
