# Specification Quality Checklist: Each Tier Advances Along Its Own Declared Workflow

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-10
**Updated**: 2026-08-13 (revision against 021, 022, 024)
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

### Validation record (iteration 1 — revision against 021, 022, 024, 2026-08-13)

The specification was re-validated against three features that shipped on `main` after it was drafted.
Four items failed and were corrected.

1. **Scope is clearly bounded** — the original spec assumed the mirror runs on every lifecycle event. It
   does not: 021's run-state short-circuit skips a run whose hashed local inputs are unchanged, and neither
   the implementation plan nor the lifecycle event is among what it hashes. The plan event and the analyze
   event — the two most likely to carry a declared step — would therefore never reach the write path this
   feature builds. User Story 3 and FR-013…FR-016 were added, the boundary against 021's deliberate trade
   (no healing of tracker-side change with no local change) is stated in Out of Scope, and the decision to
   own this rather than spin it out is argued in the Assumptions.

2. **Requirements are testable and unambiguous** — the original spec described the read half of the
   machinery as working. Re-checked against the shipped dispatch rather than accepted from the draft: the
   lifecycle event reaches the bridge only through a value nothing in the manifest or the agent-facing
   procedure ever sets, so on the real path the declared step is always empty and drift evaluation is never
   reached at all. Every scenario that exercises it does so through a test-only override. "The reported gap"
   gained a third half, User Story 2 and FR-010…FR-012 were added, and SC-003 states the before figure (0 of
   6 events resolve a step today) so the requirement fails against the pre-change code.

3. **All functional requirements have clear acceptance criteria** — the original spec's SC-011 asked for
   "at most one additional question per ticket due a move", which is exactly the one-request-per-ticket
   shape 021 removed and which 021's own SC-003 forbids; the resolution work it implied would likewise have
   restored the per-item process spawn 024 removed against a measured baseline. User Story 9 and FR-026…
   FR-031 replace it with a round-trip bound, a spawn bound, a configuration-parse bound, and a timing
   attribution requirement, each with a counting criterion (SC-012…SC-015) asserted by the stand-ins 024
   established. The mechanism is deliberately left open — an Assumption records that whether the tracker can
   answer for several tickets at once is a research question for planning, and names the bounded fallback if
   it cannot.

4. **Requirements are testable and unambiguous** — FR-015/FR-016 of the original spec spoke of the task tier
   being "enabled" or "disabled". Since 022 the tier has two modes, sub-task and checklist, and in checklist
   mode there is no task ticket to move at all. FR-022 now names the mode, FR-023 protects the sub-tasks a
   mode switch abandons, and the inert-mapping outcome is a once-per-run notice rather than a warning per
   entry (Assumptions, Principle XVI). US4 AC3/AC4 were rewritten in the same vocabulary.

### Deliberate departures from the generic template

- **Four success criteria count mechanism, not outcome.** SC-012 counts requests, SC-013 external
  processes, SC-014 per-phase request attribution, SC-015 configuration-source parses. Retained
  deliberately: this feature's cost is the thing two shipped features were built to control, the counts are
  what make "the run does not get slower" falsifiable on a CI runner an order of magnitude slower than a
  developer laptop, and shipped specs 021 (SC-003, SC-004) and 024 (SC-007, SC-008) set the precedent.
  SC-001…SC-011 and SC-016…SC-017 carry the user-facing claim on their own.

- **Two requirements fix defects of other features.** FR-010 (the event never reaches the mirror) and FR-014
  (the implementation plan is read on every run but is not part of what a completed run attests to) are
  reported against 003/021 rather than against this feature. They are in scope because FR-001's promise is
  unreachable and unverifiable without them; the Assumptions argue the case in the open rather than
  absorbing them silently, and Out of Scope states exactly how far the run-skip change goes.

- **Ten user stories, five of them P1.** The count reflects that this feature is the first able to write to
  a team's board: four of the P1 stories exist to stop it doing harm in a workflow the mirror does not know,
  and one exists to make it run at all. None of them is independently shippable value on its own — User
  Story 1 is — but each is independently testable, which is what the template asks for.
