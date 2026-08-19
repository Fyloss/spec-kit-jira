# Specification Quality Checklist: Retire the .env credential file

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-18
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

All items pass. 37 functional requirements, 10 success criteria, 4 user stories.

### Clarifications resolved 2026-08-18

- **The retrieval command replaces the fixed-service-name probe** (FR-003).
  Two rungs only — environment variable, then retrieval command — matching the
  spec-kit-figma model. US1 AC4 is the regression test that the store is no
  longer searched on the extension's own initiative.
- **The base URL moves to the shared `config.yml`, not `personal.yml`**, since
  it is identical for every team. FR-012 through FR-015 and FR-021 carry it;
  the email alone lands in `personal.yml` (FR-016 through FR-019, FR-022).
- **No migration path** (Assumptions, Constitution XV). The requester is the
  only user today, so `.env` support is removed outright: no carry-over, no
  leftover-file warning, no deprecation window.

### A latent defect found while adding the team placeholder (2026-08-18)

Adding a commented `team` placeholder to the created `personal.yml` (FR-025,
FR-026) surfaced a blocker in the existing validation: `_CFG_PERSONAL_ERRORS_JQ`
evaluates `(.team // "") | test("^[a-z][a-z0-9]*$")`, so an **absent** `team`
key yields `"team is invalid"`. `team` is effectively mandatory the moment the
file exists — while an absent file is simply inactive.

Without FR-027, the config ceremony would therefore create a `personal.yml`
whose team placeholder is commented out, and every subsequent command in that
repository would fail with `config: personal (…): team is invalid`. The
ceremony's own output would break the repository. This affects every repository
whose catalogue declares no teams too, a shape the conformance corpus already
covers (`us3-feature-no-team`, `repo-with-teams-noselect`).

FR-027 makes `team` optional-when-absent; US3 AC3 and SC-006 are the tests.

### Two design tensions recorded rather than resolved

Both are decided; they are noted here so `/speckit-plan` does not rediscover
them as blockers.

1. **The credential-shape guard refuses the very shapes this feature stores.**
   `_cfg_credential_errors` refuses email-shaped *and* `*.atlassian.net`-shaped
   values at any key outside `privacy`, on every configuration surface —
   including `personal.yml`, which `config_personal_load` scans explicitly.
   FR-021 and FR-022 narrow it to exactly one new key per file, and US2 AC5 is
   the test that the narrowing did not become a hole.

2. **Constitution V is deliberately narrowed** (see its row in the Constitution
   Check). The committed layer today refuses a Jira host and keeps the site
   identity in `config.local.yml` as `site_alias`. This feature reverses that
   for one key, by the operator's explicit decision: the hostname is team-wide,
   is not a secret, and enters the repository's history irreversibly. FR-037
   requires the documentation to say so. `site_alias` itself is untouched —
   reconciling the two is out of scope.

Naming decisions (the retrieval-command variable, the two new YAML keys) are
left to `/speckit-plan`: the spec fixes behaviour and resolution order, not
identifiers. The exact comment wording of the created `personal.yml` is
likewise a plan-level concern; the spec fixes only what the file must explain
(FR-024 through FR-027).
