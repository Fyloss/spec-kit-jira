# Specification Quality Checklist: The Time Reconcile Spends Is Its Own, and the Instrument That Says So Works Everywhere

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-10
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`

### Validation record (iteration 1)

Three items initially failed and were corrected before this checklist was marked complete.

1. **No implementation details** — the first draft named the shell variable `EPOCHREALTIME`, the tool `jq`,
   and the file `scripts/bash/lib/timing.sh` inside the requirements. Named artefacts are now confined to the
   narrative "Why this is a defect" section, where they are quoting the reported defect. FR-001…FR-008 speak of
   "the clock reading" and "the timing instrument"; FR-019/FR-020 speak of "an external tool" and "the port's
   output module". This is the boundary this project's own shipped specs (021) hold.

2. **Requirements testable and unambiguous** — "the run gets fast" was originally stated only as a wall-clock
   budget, which is not deterministically assertable in CI on this project (CI runners are an order of
   magnitude slower than a developer laptop). Split into two kinds of requirement: counting requirements
   (FR-009, FR-016, FR-017) that a stand-in asserts deterministically, and measurement requirements (FR-023…
   FR-027) that are recorded as dogfood evidence. A-3 states the distinction so planning does not mistake a
   budget for a unit test.

3. **Success criteria technology-agnostic** — SC-007 and SC-008 count "configuration source opens" and
   "external processes", which are mechanism-level. Retained deliberately: this feature's user-visible outcome
   *is* process behaviour of a command-line tool, the counts are what make the wall-clock claim falsifiable
   rather than anecdotal, and shipped spec 021 sets the same precedent (SC-003, SC-004). SC-001…SC-006 and
   SC-009…SC-013 are outcome-level and carry the user-facing claim on their own.

### Validation record (iteration 2)

4. **Requirements testable and unambiguous** — the reported defect was re-checked against a live comma-locale
   shell rather than accepted from the report, and the check changed a requirement. The report describes a
   crash; the reproduction shows the crash is the minority case. The shell's arithmetic comma operator
   discards the seconds and evaluates only the fractional digits, which raises the reported base error when
   they begin with `0` and completes silently with a wrong duration otherwise. FR-005 and SC-003 were
   rewritten to assert duration correctness rather than error absence, an acceptance scenario was added to
   User Story 1, and A-4b records the measurement. Without this, a conforming test would have passed against
   the unfixed code roughly nine times in ten.

### Validation record (iteration 3 — post-planning amendment, 2026-08-10)

5. **All functional requirements have clear acceptance criteria** — `/speckit-analyze` found that planning had
   produced a whole implementation phase with no requirement behind it. Measurement during planning (research
   R2) uncovered a second instrument defect: the run issues 123 requests and the report attributes 0 to every
   phase, which makes "phases excluding request time" — what SC-005 and FR-023 are written about — a quantity
   that does not exist. The plan tracked it in Complexity Tracking and asked the question in its Open items,
   but Principle XV requires every shipped artefact to be demanded by a functional requirement of the current
   spec. FR-036, FR-037, and SC-014 were added, `contracts/request-counting.md` was retargeted off FR-007
   (which covers the report's shape and says nothing about counts), and FR-032 was given an explicit carve-out
   for the one conformance expectation that was encoding the defect.

6. **Requirements testable and unambiguous** — A-1 claimed the reference specification is one parent, ten
   stories, and fifty tasks. The conformance rig that actually carries the spawn-count baseline has the same
   item count and no tasks at all, so FR-016's "must not grow with the number of tasks" clause was
   unexercisable. A-1 now records both shapes and which figure each one carries, and the task dimension is
   assigned to a test-owned fixture so the conformance rig — and the baseline it carries — stays untouched.

### Deliberate departures from the generic template

- **Fail-open is asserted against a fail-closed constitution.** Principle III requires failing closed on
  writes; FR-003 requires the timing instrument to fail open. The Constitution Check names this asymmetry
  explicitly rather than eliding it — the instrument decides nothing, and a diagnostic that can abort the run
  it is diagnosing is the defect being fixed. This is a bounded exception to a principle, argued in the open,
  not a dilution of it.
- **One user story's scope is an output, not an input.** User Story 5 (PowerShell) is conditional on a
  measurement that does not yet exist (A-8). It is written as measure-then-decide rather than given a
  speculative scope, which is what Principle XV requires.
- **Two of the fourteen success criteria are counting assertions, one is a variance bound.** SC-009's 20%
  spread is a stability criterion, not a speed one; it is separately necessary because today's 79% spread
  makes any future regression undetectable against the baseline.
