# Feature Specification: The Process Budget Outlives the Feature That Measured It

**Feature Branch**: `feat/spawn-budget-durable-guardrails`

**Created**: 2026-08-12

**Status**: Draft

**Input**: User description: see "Context" below.

## Context

Feature 024 removed the per-item process spawning that made `reconcile` slow, and measured
the result on the machine that motivated the work: **154 942 ms → 17 117 ms (-89.0%)** on a
real run. It also built the right instruments — a spawn-counting test helper
(`tests/bash/helpers/spawn_count.bash`), a contract
(`specs/024-reconcile-local-performance/contracts/spawn-budget.md`, clauses C1.1–C1.5), and
differential non-growth tests over `parse.sh`, `config.sh`, `plan_apply.sh` and
`recognition.sh`.

None of that stops the regression from coming back, for three reasons this feature closes.

**The tests are attached to named functions, never to the reconcile path as a whole.** Every
existing spawn assertion targets one function that someone remembered to test
(`_apply_writes_decode_rows`, `config_yaml_to_json`, `parse_acceptance_criteria`,
`recognition_run`). A function added by a future feature is unmeasured and merges green
however many processes it forks per item. Clause C1.2 — the count must not grow with items —
is asserted only at those four named functions, never over a run. The whole-run figures behind
it (20 243 → 13 057) were measured by hand and written into a Markdown table; nothing
re-measures them. `plan_writes`' per-story payload construction is deliberately still
unoptimised (024 T030, deferred) and is exactly the shape that slips through today.

**The contract is feature-local, so it is invisible to the next feature.** Nothing will lead
an agent working on feature 026 to `specs/024-*/contracts/`. `AGENTS.md`, which every session
loads automatically, says nothing about process budgets — although it already demonstrates the
pattern that works, in its "Windows portability — non-negotiable" section summarising
`docs/10-windows-portability.md`.

**The remedy is a trap when stated on its own, and it has already been paid for twice.**
Batching per-item `jq` calls into one call concentrates many small values into a single large
one. If that value travels through `argv`, it crosses Linux's `MAX_ARG_STRLEN` (128 KiB **per
argument**, distinct from the far larger total `ARG_MAX`) and the run dies with `E2BIG`.
PR #31 fixed this at five call sites; feature 024's own consolidation work reintroduced it at
three more (`plan_apply.sh`, `recognition.sh`, `tasks_parse.sh`), caught only by Linux CI.
"Batch into one call" and "route a large payload through the temp-file path rather than
`argv`" are one rule. Writing the first without the second manufactures a Linux-only crash.

This feature builds the guardrail. It does not perform another optimisation pass.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The rule is stated once, durably, and carries its companion (Priority: P1)

A contributor — human or agent — about to write a loop on the reconcile path learns, from
context that loads without them going looking, that a per-item external process is forbidden,
and learns in the same breath that the batched replacement must not be passed through `argv`
when it can grow large.

**Why this priority**: it is the cheapest of the three and the only one that acts before the
code is written. It is also the one whose absence has a measured cost: the same defect class
was reintroduced three times after having been fixed five times, because the fix pattern was
folklore rather than written guidance. A rule nobody can find is enforced only by whoever
happens to remember it.

**Independent Test**: with only automatically-loaded context (`AGENTS.md` and what it points
at), a reader can state the process-budget rule and its large-payload companion, and reach the
authoritative text without opening any `specs/` folder.

**Acceptance Scenarios**:

1. **Given** a session that has loaded only `AGENTS.md`, **When** the reader looks for the
   rule governing how many external processes a loop may create, **Then** they find a named,
   non-negotiable summary and a pointer to the durable document holding the full rule.
2. **Given** the durable document, **When** a reader consults the batching remedy, **Then**
   the large-payload routing requirement is stated as part of the same rule, not as a separate
   or optional note, and names the per-argument limit that makes it necessary.
3. **Given** the merged feature 024, **When** its contract folder is consulted, **Then** the
   budget it defined is present in the durable location and the feature-local copy no longer
   claims to be the authority.

---

### User Story 2 - A newly-added per-item loop fails before it merges (Priority: P2)

> **Implementation status: blocked, not built.** Measured during implementation (research.md R5/D7):
> whole-run C1.2 does not hold against today's code on two independent, non-constant sources
> (`plan_writes`'s per-story payload construction, and `tasks_parse_document`'s per-task line
> parsing — the second not previously documented). Building this story's assertion as specified
> would either ship permanently red or require a production fix under `scripts/`, which this
> feature's own scope forbids (SC-007). Unblocking it is a maintainer decision.

A contributor adds a function to the reconcile path that forks one external process per story.
The suite turns red on the change that introduces it, naming the growth, rather than the defect
reaching a consumer's machine and being found by wall-clock complaint months later.

**Why this priority**: it is the only mechanism that catches code nobody thought to test, which
is precisely the code that regresses. It costs more than US1 and depends on nothing from it.

**Independent Test**: introduce a deliberate per-item fork into a reconcile-path function that
has no dedicated spawn test today, run the suite, and observe a failure that identifies the
growth; remove it and observe green.

**Acceptance Scenarios**:

1. **Given** a reconcile run over a specification, **When** the number of stories and tasks is
   doubled, **Then** the total number of external processes the run creates is unchanged.
2. **Given** a function on the reconcile path with no dedicated spawn test, **When** it is
   changed to fork once per item, **Then** the suite fails and the failure names the growth
   rather than reporting an unrelated symptom.
3. **Given** a specification with no items at all, **When** it is reconciled, **Then** the
   process count reaches a defined floor no greater than the populated case's, so a bound proven
   only at one size is not mistaken for a bound.
4. **Given** the assertion, **When** it runs on a slow or heavily loaded host, **Then** its
   verdict is identical to a fast host's, because nothing in it is expressed in elapsed time.

---

### User Story 3 - A batched payload that would die on Linux is caught wherever it is introduced (Priority: P3)

A contributor consolidates a per-item loop into a single call — doing exactly what US1's rule
asks — and routes the resulting large value through `argv`. The suite catches it, at whichever
call site it was introduced, instead of only on the one path that happens to have a test today.

**Why this priority**: it closes the trap US1 documents, mechanically. It is last because US1
already prevents most instances by stating the rule, and because the existing single-path test
plus Linux CI caught the last three occurrences — late, but they were caught.

**Independent Test**: route an oversized value through `argv` at a call site other than the one
`test_reconcile_large_spec.bats` exercises, and observe the suite fail.

**Acceptance Scenarios**:

1. **Given** a value large enough to exceed the per-argument limit, **When** it is passed
   through `argv` anywhere on the reconcile path, **Then** the suite fails rather than the
   defect surviving to a Linux-only CI run.
2. **Given** the same value routed through the temp-file path, **When** the run proceeds,
   **Then** it succeeds and its output is byte-identical to the small-input case's shape.
3. **Given** a host whose per-argument limit differs from Linux's, **When** the assertion runs,
   **Then** its verdict does not depend on the host's own limit being reached.

---

### Edge Cases

- A run that short-circuits (an unchanged specification) never reaches most phases; its floor
  is lower than a full run's, and asserting a full run's budget against it would be wrong.
- One-time, per-process setup costs (a module's load-time probe) are not per-item growth and
  must not be counted as such, or the floor moves for reasons unrelated to any loop.
- A process created to serve a Jira request is bounded by the request count, not by the item
  count; the two grow together in a creating run and must not be conflated.
- A future host may make an external tool unnecessary (an in-process equivalent), lowering the
  count; a budget expressed as an exact number would then fail for an improvement.
- The PowerShell port creates no external process per item by construction; an assertion written
  against process creation must not report a vacuous pass there as if it had proven something.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The process budget MUST be recorded in a document that lives outside any single
  feature's folder and is discoverable from the repository's automatically-loaded agent
  instructions.
- **FR-002**: The automatically-loaded agent instructions MUST carry a short, named summary of
  the budget and a pointer to the authoritative document, following the same shape the existing
  Windows-portability section uses.
- **FR-003**: The durable document MUST state the batching remedy and the large-payload routing
  requirement as a single inseparable rule, and MUST name the per-argument size limit that makes
  the second half necessary.
- **FR-004**: The durable document MUST record why the rule exists, including the measured
  before/after that motivated it and the fact that the paired defect was reintroduced after
  being fixed, so a future reader can weigh it rather than merely obey it.
- **FR-005**: Feature 024's contract MUST cease to present itself as the authority once the
  durable document exists, without its historical record being rewritten or deleted.
- **FR-006**: The suite MUST assert the total number of external processes a whole reconcile run
  creates, not only the counts of individually named functions.
- **FR-007**: The whole-run assertion MUST be expressed as non-growth under a doubled item count,
  or as a count, and MUST NOT be expressed in elapsed time.
- **FR-008**: The whole-run assertion MUST fail when a per-item fork is introduced into a
  reconcile-path function that carries no dedicated spawn test of its own.
- **FR-009**: The whole-run assertion MUST distinguish per-item growth from per-request growth
  and from one-time per-process setup, so that a run legitimately issuing more requests does not
  read as a budget breach.
- **FR-010**: The whole-run assertion MUST reach a defined floor on a zero-item specification, no
  greater than the populated case's count, so that a bound holding only at the reference size is
  not accepted as a bound.

> **FR-006–FR-010 status: deferred, by maintainer decision (2026-08-12), not met.** T004b measured
> that the property these five requirements assume (whole-run process count does not grow with
> item count) does not hold today, on two independent sources: `plan_writes`' per-story payload
> construction and `tasks_parse_document`'s per-task parsing (research.md R5/D7). Unblocking them
> needs a production fix to one or both, under `scripts/`, which this feature's own SC-007 forbids.
> The maintainer was offered the choice to charter that fix now or record the deferral, and chose
> to record the deferral only — the reconcile path is fast and working today, and a production
> change is out of scope for this guardrail feature. These five requirements remain unmet until a
> future feature charters and lands the fix; see US2's status note above and `research.md` R5.
- **FR-011**: The suite MUST fail when an oversized value is routed through `argv` at any call
  site on the reconcile path, not only at the single path covered today.
- **FR-012**: The existing differential test shape — double the input, assert the count is
  unchanged — MUST be preserved; assertions MUST NOT be converted to hardcoded expected totals
  that drift as unrelated work changes the floor.
- **FR-013**: Every assertion this feature adds MUST produce the same verdict regardless of host
  speed, load, or endpoint-security inspection overhead.

### Key Entities

- **Process budget**: the rule governing how many external processes a run may create, and how
  that number may and may not grow with input.
- **Durable document**: the repository-level home of the budget, outside `specs/`, reachable from
  the automatically-loaded instructions.
- **Whole-run assertion**: the check that measures a complete reconcile rather than one function.
- **Large-payload routing rule**: the companion requirement that a batched value must not travel
  through `argv`.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Unaffected. This feature adds a document and test assertions; it introduces no new state and reads no source of truth the ports do not already read. |
| II | Zero-Churn Idempotency | Unaffected — no production write path is touched. The assertions observe a run; they do not alter what it writes. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Unaffected. No change to any write path or hook dispatch. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Honoured: the whole-run assertion runs against the mock Jira double and records process counts only. No credential is read, and no counted artefact may embed one (024 T036b established this containment rule for the config cache; the same prohibition applies to anything this feature writes). |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected. |
| VI | macOS / Linux / Windows Portability | Directly engaged. FR-013 requires host-independent verdicts. FR-011 concerns a Linux-only failure mode, and per this principle's measurement-over-emulation rule the durable document must describe how it is reproduced on a real Linux host rather than inferred. The PowerShell port spawns nothing per item (024 research R7), so the edge case above forbids reporting a vacuous pass there as proof. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Honoured. The budget applies to both sides of the boundary and is stated without reference to Jira semantics; the assertion observes process creation, which is neutral. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected — no payload content is inspected or emitted. |
| X | Self-Healing Automatic Mirror | Unaffected. |
| XI | Universal Dry-Run and Auditability | Unaffected. |
| XII | Quality and Catalog Publication | Honoured — this feature exists to keep a shipped quality property from silently decaying; the durable document is contributor-facing and excluded from what installs into a consuming repository, consistent with `docs/` already being excluded by `.extensionignore`. |
| XIII | TDD With a Minimum 80% Coverage | Honoured. US2 and US3 are failing-test-first by construction: each is specified by the defect it must catch, so the assertion is written and observed failing against a deliberately introduced fork or oversized argument before the guardrail is accepted. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Honoured. The existing spawn-counting helper and mock scenario are reused; no new measurement machinery is introduced where the differential shape already in the suite suffices. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Honoured. Scope is bounded to the guardrail. Optimising `plan_writes` or any remaining hot path is explicitly excluded, as is amending the constitution — the latter requires its own explicit amendment, outside a feature. |
| XVI | Human Readable — Readable by a Human Above All | Honoured. FR-004 requires the document to record the reasoning and the measured evidence, not only the prohibition, so a future reader can judge whether the rule still applies. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A reader with only the automatically-loaded instructions can state both halves of
  the rule and reach the authoritative text without opening a `specs/` folder.
- **SC-002**: Doubling the number of stories and tasks in a reconciled specification leaves the
  total number of external processes the run creates unchanged.
- **SC-003**: A per-item fork deliberately introduced into a reconcile-path function that has no
  dedicated spawn test today causes a suite failure that names the growth.
- **SC-004**: An oversized value deliberately passed to an external program as a single
  command-line argument, at a call site other than the one covered today, causes a suite failure.
- **SC-005**: Every assertion added by this feature returns the same verdict on the maintainer's
  managed machine, an unmanaged development machine, and CI — differing only in how long it takes
  to run, never in what it concludes.
- **SC-006**: The process budget is stated in exactly one authoritative place; the feature-local
  contract points to it rather than duplicating it.
- **SC-007**: No production behaviour changes: the conformance corpus produces byte-identical
  output before and after this feature.

## Assumptions

- The audience for the durable document is contributors to this repository and the agents working
  in it, not operators of a consuming repository — so it belongs in `docs/`, which
  `.extensionignore` already excludes from installation.
- The existing spawn-counting helper and the reference mock scenario built by feature 024 are
  sound and are reused rather than replaced; this feature adds an assertion over a whole run, not
  a second measurement mechanism.
- "External process" continues to mean what feature 024's helper counts today; a change to that
  definition would be a change to the contract, not an implementation detail.
- The whole-run assertion runs against the mock Jira double, never a live instance, so its process
  count is deterministic and no credential is involved.
- Feature 024's contract file remains in place as the historical record of how the budget was
  derived and measured; only its claim to authority moves.
- Amending the constitution with a performance principle is deliberately out of scope and is
  expected to follow as a separate, explicit amendment.
