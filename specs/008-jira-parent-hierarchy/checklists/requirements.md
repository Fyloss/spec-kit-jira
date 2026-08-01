# Specification Quality Checklist: A Specification Mirrors as a Jira Hierarchy

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-07-31
**Updated**: 2026-07-31 (post-planning sign-off)
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

All items pass. Three clarifications were answered on 2026-07-31 before planning, and two
conditions were attached to a planning finding on the same day. Both sessions are recorded
in the specification's Clarifications section.

### Pre-planning clarifications

- **Q1** — the parent's hierarchy level is derived, not declared, with two fail-closed
  refusals. FR-002, FR-004, FR-005, FR-006.
- **Q2** — the parent carries overview prose, success criteria and out-of-scope
  boundaries, and deliberately carries **no** list of user stories. FR-010, FR-011.
- **Q3** — a configuration declaring a retired key is refused, downgraded to one WARNING
  inside a lifecycle hook. FR-031, FR-032.

### Post-planning amendments

Planning found that hierarchy level identifies the child's *tier* but not its *type*: Jira's
base level holds several non-sub-task types in nearly every project, including this
repository's own company-managed fixture where `Story` and `Defect` both sit at level 0.
FR-001 was rewritten to match — two-step resolution through a recorded logical name — and
these requirements were added:

- **FR-001a** — a child-level type that cannot be resolved refuses, naming the project and the
  level and pointing at the configuration ceremony. Later merged with FR-007, which restated the
  same trigger and the same refusal; FR-007's number is retired rather than reused.
- **FR-003b** — every issue-type logical name round-trips byte for byte whatever its script.
  Feature 007 hardened mapping *keys*; the new binding shape moves the name into a *value*, so
  the quoting and fail-closed read must be extended rather than assumed to carry over.
- **FR-003a** — a binding written before this feature is detected explicitly and refused
  with its own message, never as "not bound yet" and never by falling through to an empty
  issue type. Every existing installation is in this state on its first run after the
  change, so it is tested rather than release-noted.
- **FR-030a** — the stray `projects[].issue_types` map is deleted, not reserved as a slot
  for the future committable switch: it maps names to identifiers while the switch declares
  a name, and it exists only in a test fixture, so no consumer's committed file changes.

The Out of Scope entry for the committable Story-versus-Task switch now carries a **dated
trigger** rather than an open-ended deferral: it must ship before rollout to a second team,
because the child type is a team preference answered per developer in a gitignored file, so
two developers can diverge and mix issue types in one Jira project. It is purely additive,
so the cost of deferring is backlog inconsistency, not breakage.

### Standing notes

Two items on "no implementation details" are deliberate. The specification names four
configuration keys and quotes issue-type names (`Story`, `Defect`, `Récit`, Capability /
Feature / Story). Neither is leakage: the keys are the committed, operator-facing surface
this feature changes, and the type names are the user-visible data that demonstrates both
the defect and the ambiguity that FR-001 resolves.

FR-031 records a verified correction: the configuration validator rejects unknown keys at
the **top level only** and applies no unknown-key check inside project entries, in either
implementation. Deleting the three validation rules would accept stale keys silently, so an
explicit retirement rule is real work, not a deletion.

The Constitution Check section lists all sixteen principles. Principle XVI records a
consequence rather than a conflict: this feature deletes the key the constitution uses as
its illustration of a business-language configuration key, which calls for a separate
patch-level amendment.

Planning complete: `plan.md`, `research.md` (eleven decisions), `data-model.md`,
`contracts/` and `quickstart.md` exist and the Constitution Check passes initial and
post-design. Ready for `/speckit-tasks`.
