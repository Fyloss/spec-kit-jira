# Specification Quality Checklist: The Process Budget Outlives the Feature That Measured It

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-12
**Feature**: [spec.md](../spec.md)

## Content Quality

- [X] No implementation details (languages, frameworks, APIs)
- [X] Focused on user value and business needs
- [X] Written for non-technical stakeholders
- [X] All mandatory sections completed

## Requirement Completeness

- [X] No [NEEDS CLARIFICATION] markers remain
- [X] Requirements are testable and unambiguous
- [X] Success criteria are measurable
- [X] Success criteria are technology-agnostic (no implementation details)
- [X] All acceptance scenarios are defined
- [X] Edge cases are identified
- [X] Scope is clearly bounded
- [X] Dependencies and assumptions identified

## Feature Readiness

- [X] All functional requirements have clear acceptance criteria
- [X] User scenarios cover primary flows
- [X] Feature meets measurable outcomes defined in Success Criteria
- [X] No implementation details leak into specification

## Notes

**On "no implementation details" and "technology-agnostic", for a feature whose product is the
repository's own guardrail.** These two items are written for product features, where naming a
framework in a requirement forecloses a design decision that should stay open. This feature's
deliverable *is* internal engineering guidance and internal test assertions, so its subject
matter is unavoidably technical — the same tension the repository has already accepted in
features 009 (test performance), 018 (CI wall clock) and 024 (local performance), each of which
states requirements in terms of processes, suites, and counts.

Both items are judged **passing** on the criterion that actually matters: no functional
requirement names the mechanism that will satisfy it. FR-001 requires the budget to live
"outside any single feature's folder", not `docs/11-process-budget.md`; FR-006 requires a
whole-run process assertion, not a named test file or helper. The concrete file paths appear
only in the Context (historical background) and Assumptions (recorded defaults) sections, which
is where the template intends them. SC-004 was reworded during validation to drop `argv` in
favour of "a single command-line argument", a domain concept rather than a code detail.

**Deliberate absence of clarification markers.** Three decisions that could have been raised as
questions were instead settled from measured evidence recorded in feature 024, and documented in
Assumptions rather than deferred:

1. *Count or seconds?* Settled as count — the same code measured 58 s on the isolation rig and
   17 s on the maintainer's machine, so a seconds threshold would fail on slow CI for reasons
   unrelated to the code (FR-007, FR-013, SC-005).
2. *Reuse or rebuild the measurement machinery?* Settled as reuse — feature 024's helper and
   reference scenario are sound, and Principle XIV forbids a second mechanism where one suffices.
3. *Where does the durable document live?* Settled as `docs/`, which `.extensionignore` already
   excludes from what installs into a consuming repository — the audience is contributors, not
   operators.

**One risk the plan phase must resolve, not a spec gap.** FR-009 requires the whole-run assertion
to separate per-item growth from per-request growth. In a creating run those two rise together
(one ticket per story), so the assertion needs either a scenario whose request count is held
constant while item count doubles, or a decomposition that attributes each process to its cause.
Feature 024 established that both are achievable — its phase-attribution work distinguished them
— but which to use is a design decision for `/speckit-plan`. The requirement is testable as
written; only its implementation is open.
