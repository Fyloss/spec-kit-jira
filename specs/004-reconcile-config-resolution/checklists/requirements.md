# Specification Quality Checklist: Reconcile Resolves Its Own Routing and Plan Context From Config

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-07-28
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

- **Revision 2 (2026-07-28)** — the first draft failed *"requirements are testable and unambiguous"* on
  review. It required the mirror to resolve the correct project but never required that project to
  appear in the outgoing creation payload; its scenarios only said writes "target the project", which
  no test could have distinguished from the actual defect. Since the mirror's creation payload declares
  no project at all, the first draft would have been implemented in full and the reported failure would
  have persisted. Closed by FR-022 to FR-025, US1 scenario 6, SC-009, SC-010, two edge cases, and the
  first entry in Assumptions. Re-validated: all items pass.
- **Revision 3 (2026-07-28)** — scope review raised whether the mandatory payload attributes hold for
  both project styles. They do for the project itself, which is unconditional; they do not for what
  surrounds it. Added US4, FR-026 to FR-031, four edge cases, SC-011 to SC-013, and three Assumptions
  entries. Revision 3 also records a fourth latent defect found while checking this: priorities are
  discovered site-wide and then stored per project, which is wrong for any project scoping priorities
  privately. Re-validated: all items pass.
- Validation otherwise passed on the first iteration; no other spec revisions were required.
- Script/file names from the bug report (`reconcile.sh`, `config.yml`, `config.local.yml`,
  `SPEC_KIT_JIRA_*`) appear only inside the verbatim **Input** quotation. Every requirement,
  scenario and success criterion is phrased in the product's own vocabulary — "committed team
  config", "machine-owned local binding", "creation context", "supported script ports".
- Two product terms are intentionally retained as domain language rather than implementation
  detail: "issue type" and "priority" are Jira-facing concepts this extension exists to mirror,
  and they are named in the constitution's own principles.
- One scope decision was made rather than raised as a clarification: existing environment
  variables are kept as explicit overrides (FR-013) instead of being removed. The reasoning is
  recorded as the first entry in **Assumptions** — reverse it there if the intent was removal.
- All 16 constitution principles are addressed in the Constitution Check table, including the
  ones this feature leaves unaffected.
- Scope now covers four defects, not the two reported. The third — the creation payload carrying no
  project — is the one that most directly explains the reported symptom, and none of the first three
  can be omitted without leaving the mirror non-functional. The fourth (site-wide priority discovery)
  is latent: it does not block the reported failure, but it would produce wrong payloads for projects
  that scope priorities privately.
- One factual claim in this spec could not be verified against live vendor documentation in the
  authoring session (no network access): that the declared project is mandatory for item creation in
  both project styles. It is stated as unconditional in FR-026 on strong prior grounds. The spec is
  nonetheless robust if that ever proved wrong, because FR-028 derives payload contents from what the
  project itself reports it accepts. Confirm against current vendor documentation during planning.
