# Implementation Plan: The Mirror Adds to a Ticket, and Never Overwrites What It Did Not Write

**Branch**: `worktree-fix+protect-ticket-override` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/018-preserve-ticket-content/spec.md`

## Summary

A bridge-created ticket's description is owned end to end by the mirror and replaced on every run;
`adf_render_managed_description` already renders a *delimited* managed panel above which a human's prose
survives, but it is gated on a non-bridge origin and the plan context deliberately withholds the `"bridge"`
value so that gate never opens. The core of this feature is therefore **removing a discriminator, not
adding a mechanism**: every recognised ticket — parent, story, sub-task — routes through the managed-panel
splice, and the churn comparison that already exists for human-origin tickets
(`plan_managed_description_status`) becomes the universal one.

Three things do have to be built. First, a **migration rule** for a description that carries no boundary
yet: the mirror's own previous output must become the managed region rather than be mistaken for a human's
prose and duplicated below a fresh panel — resolved by an exact suffix match against the freshly rendered
managed nodes, falling back to preserve-and-warn so no path can destroy text. Second, a **malformed-boundary
refusal**: two marker nodes in one description would silently swallow the text between them, so the split
must report a count and the description write must be skipped for that ticket. Third, a **last-written
summary record**, added to the identity entity property the mirror already stamps, which is the only thing
that can distinguish a human's rename from a specification's retitle; a divergence withholds the summary
field and warns, and `--on-drift=proceed` restores the specification's title.

Two findings from Phase 0 change the shape of the work beyond what the spec anticipated, and both are
written up in `research.md` with a recommended resolution: the privacy guard would **block the entire run**
the first time a human pastes a Jira link into a mirrored ticket (R4), and the plan section already sits
where FR-001 wants it, so User Story 1 is delivered almost entirely by User Story 2's mechanism (R2).

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port) and PowerShell 7+ (Windows port) — two native
implementations, no shared runtime, proven equivalent by the conformance corpus (Constitution VI).

**Primary Dependencies**: `jq` and `curl` at runtime, reached only through `scripts/bash/lib/output.sh`
(never called directly — the Windows `jq` build emits CRLF on multi-line output). No new dependency.

**Storage**: The repository tree (`spec.md` markers), the gitignored local binding, and — for the new
last-written summary — the Jira issue entity property `spec-kit-jira` the mirror already writes through
`sink/jira/identity.sh`. No new storage location.

**Testing**: `bats` for the Bash port (`tests/run-bash.sh`, ~190 s; `--since <ref>` for a change-scoped
loop), Pester for the PowerShell port, and `tests/conformance/ci-conformance.sh` for cross-port byte
equivalence against the mock Jira. Coverage by kcov (Bash, primary gate) and Pester CodeCoverage
(PowerShell), 80 % statement minimum.

**Target Platform**: macOS, Linux, Windows — the three-OS GitHub Actions matrix is a merge gate.

**Project Type**: A Spec Kit extension: a pair of CLI ports with a neutral engine and a Jira sink behind a
fixed interface.

**Performance Goals**: No new Jira round-trip on the read side — the existing recognition read already
returns `description` and the identity property. One additional entity-property `PUT` per ticket whose
summary is actually written, and none at all on a settled mirror (the write is bound to the summary write,
which zero-churn already drops).

**Constraints**: Zero-churn idempotency (Constitution II) is the sharpest constraint: the boundary, the
plan section and the summary record must each cost zero writes once settled. Byte-identical output across
both ports. No new configuration key, no new flag, no new command.

**Scale/Scope**: Two ports × (1 engine module, 3 sink modules, 1 command module) plus their contracts and
the conformance corpus. Touched: `engine/managed_section.sh` / `ManagedSection.psm1`,
`sink/jira/adf.sh` / `Adf.psm1`, `sink/jira/identity.sh` / `Identity.psm1`,
`sink/jira/recognition.sh` / `Recognition.psm1`, `sink/jira/plan_apply.sh` / `PlanApply.psm1`,
`sink/jira/privacy_guard.sh` / `PrivacyGuard.psm1`, `commands/reconcile.sh` / `Reconcile.psm1`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Pre-Phase-0 evaluation** — the spec's own Constitution Check covers all sixteen principles at the
specification level. At the design level, four gates need an explicit verdict and one needs a decision
recorded before design can proceed:

| Gate | Verdict |
|---|---|
| **II — Zero-churn** | PASS by design, and it is the gate the whole design is arranged around: the boundary is compared on the managed region alone (`plan_managed_description_status`, already written), and the identity `PUT` that records the summary is emitted only when the summary write itself is emitted. |
| **VI — Portability** | PASS. Every value manipulated here is JSON (ADF node arrays, the identity marker), so the `$'\r\n'`-in-a-glob hazard of `docs/10-windows-portability.md` is not reachable; the one text-shaped comparison (summary normalisation, R5) is specified as a whitespace rule with no CR in any pattern. |
| **VIII — Engine/sink separation** | PASS. `managed_section_panel_split` already takes the marker as a *parameter* and treats nodes as opaque JSON; the marker-count extension keeps that property. The migration suffix match is pure array comparison and stays in the engine; the marker text and the ADF node shape stay in `adf.sh`. |
| **IX — Privacy guard** | **DECISION REQUIRED — resolved in R4.** Round-tripping a human's prose through the guard turns one pasted Jira link into a whole-run refusal (exit 9). The recommended resolution narrows the scan to the content the mirror *composes*, which serves Principle IX's own precision rationale rather than conflicting with it. Recorded in Complexity Tracking as a deliberate, argued scope narrowing of a security control. |
| **X — Self-healing** | PASS with the spec's stated resolution: the mirror restores the region it authored, in full, and has never authored a human's text. FR-008 keeps the healing guarantee literal for the managed region. |

**Post-Phase-1 re-evaluation**: all five gates hold. R4's decision is the only one that narrows an existing
control, and it is argued, bounded to the preserved prefix, and covered by its own tests (a coordinate the
mirror composes still blocks; a coordinate present only in the preserved prefix does not). One spec
refinement is required by the research and is listed under Complexity Tracking rather than applied silently
to the spec.

## Project Structure

### Documentation (this feature)

```text
specs/018-preserve-ticket-content/
├── plan.md              # This file
├── spec.md              # The feature specification
├── research.md          # Phase 0 output — six decisions
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── managed-description.md   # The boundary: split, render, migrate, refuse
│   └── summary-record.md        # The last-written summary and its drift rule
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/bash/                              scripts/powershell/
├── engine/                                ├── engine/
│   └── managed_section.sh   (+count)      │   └── ManagedSection.psm1   (+count)
├── sink/jira/                             ├── sink/jira/
│   ├── adf.sh               (+origin)     │   ├── Adf.psm1              (+origin)
│   ├── identity.sh          (+summary)    │   ├── Identity.psm1         (+summary)
│   ├── recognition.sh       (+surface)    │   ├── Recognition.psm1      (+surface)
│   └── plan_apply.sh (+drift,+scope)      │   └── PlanApply.psm1 (+drift,+scope)
└── commands/                              └── commands/
    └── reconcile.sh         (+context)        └── Reconcile.psm1        (+context)

tests/                                        # existing files, extended
├── bash/engine/test_managed_panel.bats          # marker count
├── bash/sink/test_us7_plan_apply.bats           # the inverted bridge-origin test
├── bash/sink/test_adf.bats                      # bridge-origin managed render
├── bash/sink/test_privacy_block.bats            # the narrowed scan scope
├── bash/sink/test_identity.bats                 # the summary field
├── bash/sink/test_recognition.bats              # last_summary surfaced
└── powershell/{engine,sink}/…                   # the six matching Pester files

tests/                                        # new files
├── bash/engine/test_managed_migration.bats      # the suffix split
├── bash/sink/test_preserve_boundary.bats        # preservation, churn, refusals
├── bash/sink/test_plan_in_boundary.bats         # the plan section
├── bash/sink/test_summary_record.bats           # the drift decision table
├── bash/sink/test_boundary_migration.bats       # the three migration branches
├── bash/sink/test_suppressed_no_boundary.bats   # a hold grants nothing
├── powershell/{engine,sink}/…                   # the six matching Pester files
└── conformance/scenarios/us*-preserve-*.json    # cross-port byte equivalence

docs/
├── 05-reconcile-flow.md    # the ownership boundary in the pipeline diagram
└── 08-safety-model.md      # what the mirror owns, and what it never touches
```

**Structure Decision**: The existing one-module-per-concern layout is kept exactly; no file is added to
either port. Every change lands in a module that already owns the concern — the splice in the engine, the
ADF rendering and the identity marker in the sink, the plan context in the command. Note that the privacy
narrowing of R4 does **not** land in `privacy_guard.sh`: the guard's own rules are untouched, and what
changes is the *projection* of the payload handed to it, at the four pre-write scan sites inside
`plan_apply.sh`. Twelve new test files are the only new artifacts — six per port — and they exist because
the boundary's behaviours (migration, refusal, suppression) and the summary record are genuinely new rather
than extensions of an existing test's subject.

## Complexity Tracking

> Filled because the Constitution Check records one deliberate narrowing of an existing control and one
> required refinement of the specification.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| **Principle IX — the pre-write privacy scan no longer covers the preserved human prefix** (R4) | Extending the boundary to every bridge-created ticket means the mirror now echoes back text a human typed in Jira. The guard's BLOCK tier matches any `*.atlassian.net` host, so the first Jira link a human pastes into a mirrored description would refuse the entire run with exit 9 and zero writes — on every subsequent run, until a human deletes the link from Jira. The guard exists to stop the *repository* leaking coordinates into Jira; text read from a ticket and written back to that same ticket cannot leak anything that is not already there. | *Scan everything, as today* was rejected because it converts a routine human action into a permanent, whole-feature outage, which is exactly the "blocking control with false positives ends up disabled" failure Principle IX names in its own rationale. *Downgrade the host rule to WARN* was rejected because it weakens the guard for content the mirror really does compose. *Allowlist the site host* was rejected because it requires every consumer to configure their own site into an allowlist to use the feature at all, and it blinds the guard to that host everywhere else. The narrowing is per-region, explicit, and leaves every mirror-composed byte scanned exactly as before — it also closes the same latent defect that already exists for adopted tickets. |
| **Spec refinement required: FR-020's "without duplicating any content" cannot be guaranteed unconditionally** (R3) | The migration run must split a boundary-less description into "the mirror's previous output" and "a human's additions" with no record of what the mirror last wrote. An exact suffix match resolves the two common cases — untouched, and human-prefixed — but cannot resolve a description whose specification *also* changed in the same run. Both remaining outcomes are bad in one direction: discarding loses a human's text, preserving duplicates the mirror's. | *Discard the unmatched remainder* was rejected outright: Principle I forbids a silent regression and Principle III is fail-closed, so an irrecoverable loss can never be preferred to a visible duplication. *Record a description digest in the identity property* was rejected as redundant — from this release onward the boundary itself is the record, so the digest would exist solely for one migration run and then be dead weight (Principle XV). The resolution is to preserve, and to report one named warning naming the ticket so the operator sees the duplication and can trim it. FR-020 should be refined to guarantee no *loss* unconditionally and no *duplication* when the migration is unambiguous, with a named warning otherwise. Recommended for `/speckit-clarify` rather than edited into the spec here. |
