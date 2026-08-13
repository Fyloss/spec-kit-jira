# Contract: The Whole-Run Process Budget

**Feature**: 025 | **Satisfies**: FR-006, FR-007, FR-008, FR-009, FR-010, FR-012, FR-013

Feature 024's `contracts/spawn-budget.md` clause **C1.2** — the count must not grow with the number
of stories, tasks or configuration lines — is asserted today only at four individually-named
functions, never over a run. This contract defines how that assertion is measured at whole-run
scope, and — as importantly — what would make it lie.

Clause **C1.1**, the absolute bound on a run's total, stays unasserted on purpose: W1.2 and FR-012
forbid writing an expected total into these tests, and a hardcoded C1.1 is that forbidden shape.
The gap this contract closes is one of scope, not of bound.

## §1 What is asserted

**W1.1** — For a specification of *N* items and one of 2*N* items, otherwise identical, the total
number of external processes each run creates is **equal**.

**W1.2** — Equality is asserted between two measured runs. No expected total is written into the
test. A floor that changes because unrelated work removed a `jq` call must not turn the suite red.

**W1.3** — A specification with **zero** items reaches a defined floor, asserted to be no greater
than the populated case's count. A bound proven only at one size is not a bound (024 C1.4).

**W1.3.1** — It is `≤`, not `=`, and that is not a weakening for convenience. 024's C1.4 is a
**per-phase** claim, which can hold exactly. Its whole-run analogue cannot: `prefetch.sh:46`
returns early on zero keys, so a zero-item run issues no bulkfetch and therefore creates strictly
fewer processes than a populated one. An equality assertion here would be false against correct
code.

**W1.4** — The assertion is a count comparison. **No duration appears in it.** The counting shim
itself distorts wall clock by roughly 61%, so a run made under it cannot be timed at all.

## §2 The premise, asserted before the budget

The comparison in W1.1 is only meaningful if the two runs differ in item count and in **nothing
else that creates processes**. The dominant confounder is the Jira request.

**W2.1** — Both runs MUST issue the **same number of requests**. The test asserts this **before**
comparing process counts.

**W2.2** — A violation of W2.1 MUST be reported as a broken premise — "the scenario no longer holds
the request count constant" — never as a budget breach. The two have different causes and different
fixes, and a test that confuses them sends the next reader to the wrong file.

**W2.3** — The scenario achieving W2.1: stories that are **already bound** (they carry recorded
ticket markers), content **unchanged** (so nothing is written), and `--force` (so the unchanged-state
short-circuit does not skip the run entirely). Prefetch chunks keys at 100 per bulk fetch, so 10 and
20 stories both cost exactly one.

## §3 Why `curl` cannot simply be excluded

The obvious alternative to §2 — count `jq`+`sed`+`awk`, ignore `curl` — **is invalid** and must not
be reintroduced by a later simplification.

`tests/conformance/mock-jira/lib.sh` installs `curl-shim.sh` as `curl` on `PATH`. That shim is a
Bash script that runs `jq` **52 times** over the course of serving requests. To a PATH-interposed
counter those calls are indistinguishable from the port's own. Excluding `curl` therefore removes
one process per request and leaves dozens.

**W3.1** — Any future change to this assertion MUST state how it prevents the mock's own process
usage from being attributed to the port. Holding the request count constant (§2) is how it is done
today.

## §4 Scope

**W4.1** — This contract governs the **Bash port**. The PowerShell port performs its JSON work
in-process and creates no external process per item (024 research R7); the same assertion there
passes without proving anything.

**W4.2** — A vacuous pass MUST NOT be presented as evidence of compliance. Where the PowerShell
port's protection is structural rather than tested, documentation MUST say so plainly rather than
implying symmetric coverage.

## §5 Failing test first (Constitution XIII)

**W5.1** — The assertion is accepted only after being observed **red**: a per-item fork is
introduced deliberately into a reconcile-path function **that carries no dedicated spawn test of its
own**, the suite is run and fails, the fork is removed, and the suite passes.

**W5.2** — Choosing a function that already has a dedicated spawn test would prove nothing — that
function is already protected. The point of this assertion is the code nobody thought to test.
