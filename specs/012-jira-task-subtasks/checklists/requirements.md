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
- Scope note carried forward for `/speckit-plan`: feature 010 emits a status line stating that the
  `task` role is recorded but not mirrored and that the release creates no sub-tasks. FR-012 makes
  replacing it part of this feature — shipping the mirror while still announcing its absence is a
  defect.
