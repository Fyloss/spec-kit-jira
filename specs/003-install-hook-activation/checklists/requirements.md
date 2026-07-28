# Specification Quality Checklist: Hooks Active From Installation

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

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.

### Validation record

Iteration 1 found and fixed:

- **Implementation leak** — several requirements named the concrete artifacts
  (`extension.yml`, `.specify/extensions.yml`, `spec-kit-jira` executable,
  `--repair-hooks`, `optional: false`). Rewritten in terms of *extension
  manifest*, *hook registry*, *bridge entry point*, *one-command repair* and
  *non-optional dispatch*, with the concrete names left to planning. The seven
  lifecycle event names are retained deliberately: they are the host workflow's
  vocabulary, not this extension's implementation.
- **Untestable success criterion** — an early SC phrased install-to-first-run
  as a duration. Replaced by SC-008, which counts manual steps (zero) instead
  of measuring wall-clock time.
- **Ambiguity on "non-optional"** — the user's phrasing could mean either
  "always dispatched" or "allowed to fail the host command". Resolved in the
  Overview and Assumptions as a dispatch property only, which keeps the
  constitution's non-blocking-hooks principle intact; FR-004 and FR-015 now
  state the two halves separately.

Iteration 2: all items pass. No open clarifications.

Iteration 3 — the **Input** line was recorded verbatim in French, which breaks
the English-only documentation rule. Replaced with an English translation of
the same description. The quoted error message is left verbatim, including its
misspelt command name, because that typo is evidence the spec reasons about
(User Story 5, FR-018) rather than prose to be corrected. No requirement,
scenario or success criterion changed. All items still pass.

Iteration 4 — a cross-artifact analysis, prompted by the consuming project's
question "will the configuration command overwrite our `.specify/extensions.yml`?",
produced three changes and one reversal of an earlier decision:

- **The registry becomes read-only to this extension** (FR-022, FR-023, SC-011,
  SC-012). The earlier design let the ceremony write when an entry was missing.
  That was rejected on evidence: this extension's YAML reader models a restricted
  subset of the language and discards comments, so every write it performs
  silently damages a file the operator is invited to edit and other extensions
  co-own (research.md R3). User Story 6, FR-021 to FR-025, FR-028 and FR-029 are
  rewritten around read-classify-report.
- **The missing Constitution Check section was added**, as Governance requires.
  The spec template was missing it too, so no spec in this repository could have
  complied; the template is fixed in the same change.
- **Two requirements were unachievable as written and are now stated as effects**:
  FR-007 and SC-005 claimed a disabled *entry* survives a reinstall, which the
  host's unconditional `enabled: true` makes impossible (research.md R5). They
  now guarantee that no bridge step *runs*, which is both true and testable.
  US5 scenario 3 replaced an unmeasurable "drowning the output" phrasing with a
  counted limit.
- **A new requirement covers an upgrade defect found during analysis** (FR-028):
  entries written by earlier versions carry no owning-extension field, so the
  host duplicates rather than replaces them, in exactly the repositories that
  reported the original defect.

All items still pass. The Content Quality item "no implementation details" is
re-checked: FR-022 names the hook registry as a concept, and the concrete path
appears only in plan.md, tasks.md and the contracts.

Iteration 5 — tracing the reported error message to its emitter showed it exists
**nowhere in this repository**: not in a script, not in a command document. The
assistant composed it after the procedure told it to run a bare `spec-kit-jira`
that a consuming repository does not have. Two consequences were specified:

- **A sixth degraded cause** (FR-017): the bridge entry point being absent or
  not executable. It is the only cause the bridge cannot report, because in that
  state it never starts.
- **FR-030** pins the message for that state as verbatim text in the documented
  procedures, with an instruction not to improvise. The message↔command CI check
  cannot police prose that is never committed, so the enforceable control is to
  fix the words in the document the assistant reads and check the document
  contains them. This closes the last of the four defects in the reported
  message; the other three are closed by US1, US4 and FR-017 respectively.

### Constitution alignment

- **III. Fail-Closed on Writes, Non-Blocking on Hooks** — FR-015 to FR-020 and
  SC-006 preserve non-blocking hook outcomes while dispatch becomes mandatory.
- **X. Self-Healing Automatic Mirror** — FR-005 to FR-007, FR-021, FR-025,
  FR-028, SC-004 and SC-005 keep idempotent registration, health reporting and
  the permanently-honoured disabled entry. Repair is offered as one command
  where one exists; the leftover-entry case has none, and that deviation is
  recorded in plan.md § Complexity Tracking.
- **II. Zero-Churn Idempotency** — FR-022, FR-023, SC-007 and SC-011 remove the
  second writer entirely rather than coordinating two of them.
- **VI. Portability** — FR-013 and SC-008 require identical behaviour on both
  ports.
