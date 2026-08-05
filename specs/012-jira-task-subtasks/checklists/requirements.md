# Specification Quality Checklist: Every Task Lands as a Sub-Task Under Its Own Story

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-02
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

- Both open questions were answered by the requester and are now firm requirements:
  - **Unattributed tasks** (setup, foundational, polish) are reported and not mirrored — FR-028.
    No bridge-owned issue is invented to host them. A destination remains available as a future
    opt-in, recorded in Out of Scope with a written trigger.
  - **Completion state** is mirrored forward — FR-029 to FR-033. A checked task drives its sub-task
    to a status the project *classifies* as done, resolved from the project's own classification
    rather than from any status name, so a French- or otherwise non-English-named workflow is
    covered without configuration (SC-010).
- Constitution Check covers all sixteen principles of constitution v1.2.0, each with a stated proof
  or a stated reason for being unaffected. Three rows changed once completion mirroring was added:
  II gains the transition write kind, VII gains the classification-based resolution, XIV records
  that the transition reuses the existing story-tier lifecycle rules rather than a second mechanism.
- Scope note carried forward for `/speckit-plan`: two shipped status lines announce that this tier
  is inert — feature 010's "task is recorded as … but is not mirrored yet" and feature 011's
  "recorded, not yet consumed" for a field default on the sub-task type. FR-012 makes replacing both
  part of this feature; shipping the mirror while still announcing its absence is a defect.

### Re-validation 2026-08-03 — feature 011 shipped since this spec was drafted

Feature 011 (recorded field defaults) shipped in v0.10.0 after this specification was written. Four
places assumed a world in which it did not exist; all four are now corrected and the checklist is
re-verified green against the updated text.

- **Out of Scope was wrong, not merely stale.** It deferred "supplying values for mandatory custom
  fields on the sub-task type" to "a separate feature", which has since shipped. Replaced by three
  bounded exclusions: no defaults surface of this feature's own, no default on a transition screen,
  no partial-mirror degradation.
- **A whole requirement group was missing.** FR-034 to FR-039 make the sub-task type a third scope
  entry of feature 011's mechanism: the ceremony asks about it only when a `task` role is declared
  (FR-035), the pre-write gate refuses cleanly when nothing is recorded (FR-036), the consolidated
  confirmation stays one question per run across all three tiers (FR-037), no default is sent on a
  transition (FR-038), and value provenance reuses the existing summary and preview (FR-039).
  Acceptance scenarios US1-7 and US1-8 cover FR-035 and FR-037; three edge cases cover FR-036,
  FR-038 and a default recorded under feature 011's opt-in before this tier existed.
- **Constitution rows V, VII, XIV and XV** now state the relationship instead of calling the
  configuration surface unaffected: no new key, one more issue type under `field_defaults`, and the
  hook still never edits the team config.
- **One judgement call, recorded in Assumptions rather than left open** — *superseded the same day,
  see the revision below*: an unsatisfiable required field on the sub-task type withdrew the whole
  specification's mirror, not just its task tier, with a written trigger in Out of Scope.

### Revision 2026-08-03 — the requester fired that written trigger immediately

Asked whether a mandatory field on the sub-task type would block, and told to handle it inside this
feature on feature 011's foundations. It would have blocked, in one case, and that case is now
closed. **FR-036 is inverted**: an unsatisfiable required field on the sub-task type no longer
refuses the specification. The two upper tiers mirror exactly as they would with no `task` role
declared, the task tier alone is withheld, and each field is named with its remedy.

- **User Story 6 (P1)** carries the behaviour end to end — the ceremony question, the recorded
  default applied on creation, the single consolidated confirmation, the withheld tier, the
  recovery, and the field whose shape can never be defaulted (feature 011, FR-010). The two
  scenarios previously appended to User Story 1 moved here, where they belong.
- **FR-037 to FR-039 are new**: the summary states a withheld tier as withheld, a withheld task
  receives no durable identifier in `tasks.md` (so FR-017 already makes it new again next run), and
  recording the default is the only action needed to finish the mirror. The previous FR-037 to
  FR-039 renumbered to FR-040 to FR-042; every cross-reference was updated with them.
- **Constitution row III rewritten.** Fail-closed is a property of a write, not of a run: the
  sub-task writes that cannot be formed are not issued, while the specification and story writes,
  which are correct and independently satisfiable, still happen. The task tier is a leaf, so
  withholding it leaves exactly the coherent two-tier mirror of the previous release — which is why
  the same argument does **not** extend to the two upper tiers, now stated in Out of Scope.
- **SC-013 and SC-014** measure it: declaring a `task` role never reduces what a team already gets,
  and recording the missing default moves the issue count by precisely the number of withheld tasks.
