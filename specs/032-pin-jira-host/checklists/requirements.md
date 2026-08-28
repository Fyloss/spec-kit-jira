# Specification Quality Checklist: Pin the Jira Destination Host

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-28
**Last revalidated**: 2026-08-28, after Phase 0 research and `/speckit-analyze`
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

### Clarifications (resolved before planning)

- **FR-010 — accepting a changed destination.** The operator must name the new
  destination explicitly. The ceremony refuses to re-record otherwise, so
  following the refusal's printed instruction verbatim is not sufficient. This
  is what stops the control from degrading into a speed bump; asserted by SC-008
  and US1 scenario 6.
- **FR-011 — an environment-supplied destination.** Exempt. The environment is
  operator-typed and unreachable from a pull request — the ground on which the
  constitution already admits the credential retrieval command's name from there
  and nowhere else. The attacker-reachable source, the committed team config,
  remains compared.

### Amendments forced by Phase 0 research

The spec was revised mid-plan; these supersede its first draft.

- **FR-001** — the record's key is a new `bound_site`, **not** the existing
  `site_alias`, whose published contract states the opposite and which existing
  installations already populate with a human alias. This removes a migration
  class entirely: an upgraded installation is simply *absent*.
- **FR-012** — port comparison is default-port-normalised, not byte-exact, and
  the host fold is an explicitly enumerated ASCII mapping. The two ports' native
  folds were measured to disagree.
- **FR-016** (new) — the Constitution IV/V amendment is a **prerequisite**, not a
  consequence. Recording an origin in the local layer is forbidden by the
  constitution as written and refused by the credential-shape guard that
  enforces it.
- **FR-017** (new) — two pre-existing cross-port divergences in the reused origin
  primitive are repaired first, each proven red before its fix.

### Open item carried into implementation

**The Constitution IV/V conflict is declared, not resolved.** The spec does not
dilute either principle; it depends on an explicit amendment (tasks T001-T002)
landing first. If that amendment is not accepted, the feature does not proceed —
see plan.md Complexity Tracking for the rejected alternative and why it was
rejected.

### `/speckit-analyze` follow-ups, applied

Coverage gaps found and closed: FR-015 gained clause C4.12 and tasks T056a/T056b;
FR-013/SC-007, FR-006/C4.11, and SC-003 gained tasks T065a, T065b, T065c. FR
coverage is now 17/17 and SC coverage 8/8.

Checklist complete — the spec is consistent with plan, contracts, and tasks.
