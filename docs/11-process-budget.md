# 11. The process budget — one rule, stated whole

This document is the authoritative statement of the Bash port's process
budget. `specs/024-reconcile-local-performance/contracts/spawn-budget.md` is
the historical record of how the budget was derived and measured — its
figures are not repeated here for their own sake, they are repeated because a
rule stated without the evidence that motivated it invites a future reader to
simplify it back into the trap it closed.

## The measured evidence

Feature 024 cut a real reconcile run from **154 942 ms to 17 117 ms** on the
maintainer's machine, and from **20 243 to 13 057 `jq` invocations** on the
61-item reference specification, by removing per-item process spawning from
the reconcile path. Two engineers on differently-managed laptops disagree
about seconds and agree exactly about spawn counts — spawn count is a
property of the code; wall-clock is a property of the code *times* the
host's per-spawn cost (measured: 2.445 ms per `jq` spawn on unmanaged macOS
against 9–18 ms implied by a corporate-managed machine, the signature of an
endpoint-security agent inspecting every `exec`). That is why every assertion
in this document is a count, never a duration.

## The rule, stated whole

Batching and argument routing are **one inseparable rule**. Stating either
half alone reintroduces the defect the other half exists to prevent — this
has happened twice: PR #31 fixed it at five call sites, and feature 024's own
consolidation work reintroduced it at three more.

### Half one — no per-item process

**No loop on the reconcile path may spawn an external process (`jq`, `sed`,
`awk`, `curl`, …) once per item.** A loop over stories, tasks, or
configuration lines that shells out per iteration must be replaced by a
bounded number of calls for the whole set — batched, not iterated. This holds
per phase (`gate`, `plan`, `apply`, `parse`, …). Feature 025 specified the
whole-run corollary — doubling the item count must leave the total process
count unchanged — but measured (T004b,
`specs/025-spawn-budget-guardrails/research.md` R5) that it does **not hold
today**, on two independent, non-constant sources: `plan_writes`' per-story
UPDATE-branch payload construction (accepted debt, 024 T030) and
`tasks_parse_document`'s per-task line parsing (~6 spawns per task, found by
this feature's own measurement, not previously documented). The whole-run
assertion that would enforce this is therefore **specified but not built** —
see "Where the assertions live" below and
`specs/025-spawn-budget-guardrails/research.md` R5/D7 for the full
measurement and what would unblock it.

**The whole-run corollary is `≤`, not `=`, at the zero-item floor.** Per
phase this is exact — a phase given zero items does exactly the fixed amount
of work it always does. Over a whole run it is not: `prefetch.sh:46` returns
early on zero keys, so a zero-item run issues no bulkfetch and therefore
creates strictly *fewer* processes than a populated one. An equality
assertion at the whole-run zero floor would be false against correct code.

### Half two — the batched value must not travel through argv

**In the same breath**: the single bounded call that half one produces must
not pass its (now much larger) payload to a program as a single command-line
argument, when that payload can grow with input. It must travel through a
temp file — `json_build`'s established path — instead.

**The binding limit is the tightest cap across the supported hosts — never the
cap of the host you are standing on.** The three do not agree, and they span a
factor of four:

| host | per-argument cap | mechanism |
|---|---|---|
| **Windows** | **≈32 767 bytes** | `CreateProcess` bounds the whole command line |
| Linux | **128 KiB** (131 072) | `MAX_ARG_STRLEN` |
| macOS | none | — |

Windows is the binding one. Measured on a real Windows 11 host: 32 700 bytes
exec fine, 33 000 come back `E2BIG`. Note what `CreateProcess` counts — the
whole command line, so the *value* plus the filter, the other arguments and the
program name. A payload capped at exactly 32 767 still overflows once anything
joins it on the line; that is a real defect this document's own rule missed
(`plan_apply.sh`, whose description ceiling was set to that very number).

Linux's `MAX_ARG_STRLEN` is **not** `ARG_MAX`, the total argument-list size,
which is far larger — a value comfortably inside `ARG_MAX` still fails if one
*single* element exceeds `MAX_ARG_STRLEN`. Confusing the two is why the defect
reads as "the arguments aren't that big" during review: the total looks fine;
the one oversized element does not stand out unless you are looking for it.

Linux's limit is **inclusive**: 131 072 bytes exactly already fails. It bounds
the search for the argument's terminating NUL by `MAX_ARG_STRLEN`, so a string
that fills the limit leaves no room for it. The largest single argument that
can be delivered is 131 071 bytes — measured on the Ubuntu CI runner, where
131 072 and 131 073 both come back as "Argument list too long".

**Why the spread is the whole problem.** macOS enforces no cap at all, so the
identical run succeeds on the maintainer's own machine — which is why this was
caught late, by CI, three times. Then the same reasoning was applied one level
up: the guard built to catch it was calibrated to *Linux*, and Windows' cap is
four times tighter, so a payload of roughly 33–131 KB is fatal on
`windows-latest` and invisible to every other host **and to the guard itself**.
That blind spot hid fourteen call sites of this exact defect until 2026-08-22.
A payload is safe only when it clears the smallest cap of any host the project
supports.

One consequence bites anyone writing a check for this defect: a value at or
above the limit **cannot be handed to a process on Linux at all**. A check
that receives the oversized value as an argument in order to measure it can
therefore only ever pass on macOS — it reproduces the very blindness it was
written to remove. Measure a boundary value in-process instead; see
`tests/bash/helpers/argv_size_measure.sh`, which is sourced rather than
executed for exactly this reason.

## Why the two halves cannot be separated

```text
per-item loop  --consolidated into one call-->  single large value
                                                      |
                                    passed through argv|  routed through a temp file
                                                      v                 v
                                          E2BIG on Linux only      correct everywhere
                                          (invisible on macOS)
```

Applying half one without half two converts a slow run into a *crashed* run —
on Linux only, invisibly to whoever is reviewing the change on macOS. Do not
present these as a rule plus an optional follow-up; they are one rule.

## Reintroduction history

- **PR #31** fixed the batching-without-routing defect at five call sites.
- **Feature 024**'s own consolidation work — the very effort that cut spawn
  counts by two thirds — reintroduced it at three more sites, because
  batching a loop into one `jq` call was the visible win and routing the
  now-large payload through a temp file was the easy-to-forget second step.

A rule stated without this history reads as obvious in hindsight and
therefore skippable in a hurry. It has been paid for twice; recording why is
what keeps it from being paid for a third time.

## The PowerShell port's position

The PowerShell port does its JSON work in-process (feature 024 research R7)
and creates no external process per item by construction. Its protection
against this defect class is **structural, not tested** — the Bash port's
whole-run assertion (feature 025) has no PowerShell equivalent, because the
same assertion there would pass vacuously and prove nothing. Do not present a
green PowerShell run as evidence of coverage it does not have; state the
structural argument instead.

## Where the assertions live

- Per-phase (feature 024): four individually-named functions, each carrying
  its own spawn-count assertion.
- Whole-run (feature 025): **specified but not built.**
  `tests/bash/commands/test_reconcile_run_budget.bats` does not exist. The
  measurement that would land it (T004b) found the premise it needs — equal
  requests, zero writes — holds, but the budget it would assert does not (see
  above). Building it against known-non-constant code would ship either
  permanently red or with a hardcoded tolerance FR-012 forbids. See
  `specs/025-spawn-budget-guardrails/research.md` R5/D7.
- Argument size (feature 025): `tests/bash/sink/test_argv_size.bats` measures
  every argument any call site produces during a whole run against
  `HELPER_ARGV_SIZE_LIMIT` in `tests/bash/helpers/argv_size.bash` — **the
  tightest cap across supported hosts, on every host, regardless of that
  host's own limit**. `_LINUX` and `_WINDOWS` are kept as separate named
  constants, each pinned by its own boundary cases, so the verdict cannot
  quietly drift back to whichever host happens to run the suite. It was
  calibrated to Linux until 2026-08-22, and that is precisely how it stayed
  green through fourteen instances of the defect it was built to catch.
  Consequence, by design: the guard fails for payloads macOS and Linux
  deliver without complaint. That is what makes it cover the class.

## The gaps this document used to list — closed 2026-08-22

This section named two reconcile-path call sites that routed an input-growing
payload through a single `argv` element, measured but deliberately not fixed
(SC-007 forbade a production change under `scripts/` from feature 025). They
were `engine/parse.sh` (`--argjson st`, the whole stories array) and
`engine/interchange.sh` (`--argjson parse`, the whole parse result), at 66–72 KB
on a 100-story fixture.

**Both are fixed, and they were two of fourteen.** The estimate that there were
two is the part worth keeping in mind: it came from reading the sites this
document's authors already knew about, and the real number was found only by
sweeping the whole port for a payload that can grow with input reaching argv.
The others were in `commands/reconcile.sh` (eight), `commands/seed.sh` (two),
and `sink/jira/plan_apply.sh` (one) — the last of these capped at exactly
32 767 bytes and overflowing anyway, for the reason given above.

The arithmetic this section used to close on was also host-blind. It said ≈183
stories crosses 131 072 bytes; on Windows the crossing is at ≈50, and the
61-item reference specification is already past it. That is why four conformance
scenarios failed on `windows-latest` alone and nowhere else.

Closed by `fix/windows-remaining-divergences`, proven on the real Windows runner
across all 231 conformance scenarios. If you are adding a call site, the guard —
not this list — is what protects you; the list is here as a record of how a
hand-kept one fails.

See `specs/024-reconcile-local-performance/contracts/spawn-budget.md` for the
full derivation and measurement method, and
`specs/025-spawn-budget-guardrails/contracts/` for how the whole-run and
argument-size assertions are specified.
