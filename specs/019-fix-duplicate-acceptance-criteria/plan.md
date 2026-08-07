# Implementation Plan: A Ticket the Mirror Created Is the Mirror's to Replace

**Branch**: `fix/duplicate-acceptance-criteria` | **Date**: 2026-08-06 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/019-fix-duplicate-acceptance-criteria/spec.md`

## Summary

Re-running reconcile against an edited specification leaves two Acceptance Criteria sections on the ticket,
permanently. The cause is one branch: when a description carries no boundary marker, the mirror decides
whether the content is its own by asking whether it is byte-identical to what it would render *now* — a
question an edited specification always answers "no". So the mirror's own prose is reclassified as a human's
and re-rendered beneath itself.

The fix routes evidence the mirror already stores to the decision that ignores it: every ticket's identity
entity property records `origin` — `bridge` (the mirror created it) or `human` (adopted via `mention`). A
neutral engine function takes that as an opaque `self` / `other` / `unknown` parameter and owns the whole
decision. Exactly one row of the decision table changes; every other path stays byte-identical, which is
what keeps the regression surface small.

Repairing tickets already damaged is out of scope by the reporter's explicit decision — there is no
installed base.

## Technical Context

**Language/Version**: Bash 3.2+ (macOS system bash, MSYS bash on Windows) and PowerShell 7+ — two native
ports proven equivalent by a shared conformance corpus

**Primary Dependencies**: `jq` (bash port: only ever through `scripts/bash/lib/output.sh`), `curl`. None
added by this feature.

**Storage**: Jira entity property `spec-kit-jira` (the identity marker, holding `origin`); markers spliced
into `spec.md`. Nothing new is persisted.

**Testing**: `bats` via `tests/run-bash.sh`; Pester; cross-port byte equivalence via
`tests/conformance/ci-conformance.sh`; `shellcheck`, `actionlint`, PSScriptAnalyzer

**Target Platform**: macOS, Linux, Windows

**Project Type**: CLI extension for Spec Kit — neutral engine + Jira sink, two native ports

**Performance Goals**: No new network calls, no new discovery pass. The decision is local and reads context
already assembled. Suite runtime must not regress (`tests/run-bash.sh` ≈190s).

**Constraints**: Byte-identical output across both ports; no new dependency, flag, or configuration key; no
`$'\r\n'` inside a glob pattern; no direct `jq` in the bash port

**Scale/Scope**: ~7.1k lines across `engine/` + `sink/jira/`; six source files touched, three per port

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Initial evaluation (pre-Phase 0)**: PASS — no violation, no justification required.

**Post-design re-evaluation (post-Phase 1)**: PASS. The design strengthened three principles and weakened
none.

| # | Principle | Gate status after design |
| --- | --- | --- |
| I | Filesystem is the source of truth | **Strengthened.** The specification alone determines the region's content; today a superseded copy survives on the ticket, contradicting the file it mirrors. No new exception: the mirror writes to no ticket and no region it did not already write to. |
| II | Zero-churn idempotency | **PASS, and improved.** The decision is keyed on a server-side **entity property**, hidden from the editable UI — precisely what this principle demands, and why the provenance label and the summary were both rejected in research R2. Second-run-writes-nothing is asserted by contract §5.5. |
| III | Fail-closed on writes | **PASS.** Rule 1 (`malformed`) still omits the description key entirely rather than sending `null`; rule 5 (`unknown`) preserves and warns rather than guessing. Every warning stays non-blocking. |
| IV | Credential security | **Unaffected.** No credential read, written, or reported. |
| V | Config / binding / secrets separation | **PASS.** No configuration key, no flag, no new context key. Ownership is behaviour. |
| VI | macOS / Linux / Windows portability | **PASS with a named hazard.** The change is in the managed-section splice, this project's historical source of Windows divergence. The quickstart carries the two standing rules (no `$'\r\n'` in a glob; no direct `jq`), and the conformance corpus covers every row of the decision table. |
| VII | No hard-coded Jira workflow assumptions | **PASS.** No status, transition, screen, or field configuration is assumed. Contract §1 forbids depending on the stored document being byte-stable across a round trip. |
| VIII | Neutral engine / Jira sink | **Strengthened.** Research R4 moves the ownership rule *out* of the sink and into the engine, taking ownership as a third opaque parameter beside the markers it already takes. `self`/`other`/`unknown` carry no tracker vocabulary. |
| IX | Two-tier privacy guard | **Unaffected.** No new text is composed; this feature writes strictly less. Guard-then-write ordering untouched. |
| X | Self-healing automatic mirror | **PASS.** The mirror still restores its own region when damaged; `sc008-deleted-managed-region-restored.json` is retained unchanged as the guard. |
| XI | Universal dry-run and auditability | **PASS.** No new payload shape, so `--dry-run` predicts the new outcome through the existing path. No destructive operation added. |
| XII | Quality and catalog publication | **PASS.** CHANGELOG entry required; gated by the full suite, the conformance corpus and the linters on all three operating systems. |
| XIII | TDD with ≥80% coverage | **PASS.** The failing reproduction is quickstart §1 and is written first. The new engine function is unit-tested across all six decision rows. |
| XIV | KISS | **PASS.** One decision changes. No fingerprint, no cache, no new state, no new vocabulary. `managed_section_suffix_split` is retained unchanged rather than replaced. |
| XV | YAGNI | **PASS.** Repair, a repair command, a migration mode and the content-shape heuristic are all named out of scope in the spec and none is built. The `unknown` branch is built because FR-004 requires it, not because it is reachable today. |
| XVI | Human readable | **PASS.** A ticket states its acceptance criteria once. Warnings keep naming the ticket and what to do about it; no new warning vocabulary is introduced. |

## Project Structure

### Documentation (this feature)

```text
specs/019-fix-duplicate-acceptance-criteria/
├── plan.md                          # This file
├── spec.md                          # Feature specification
├── research.md                      # Phase 0 — R1..R7, all measured
├── data-model.md                    # Phase 1 — origin, ownership, split result, transitions
├── quickstart.md                    # Phase 1 — failing test first, then validation
├── contracts/
│   └── ownership-decision.md        # Phase 1 — signatures, decision table, caller obligations
├── checklists/
│   └── requirements.md              # Spec quality checklist (14/14)
└── tasks.md                         # Phase 2 output — NOT created by /speckit-plan
```

### Source Code (repository root)

```text
scripts/
├── bash/
│   ├── engine/
│   │   └── managed_section.sh       # + managed_section_ownership_split  (the decision)
│   ├── sink/jira/
│   │   ├── adf.sh                   # _adf_resolve_managed + both render entrypoints take origin
│   │   └── plan_apply.sh            # 3 update call sites pass ctx origin (story/parent/task)
│   └── commands/reconcile.sh        # unchanged — already populates every origin needed
└── powershell/
    ├── engine/
    │   └── ManagedSection.psm1      # + Split-JiraManagedSectionOwnership (+ export)
    └── sink/jira/
        ├── Adf.psm1                 # Resolve-JiraManagedAdfContent + both ConvertTo-* take -Origin
        └── PlanApply.psm1           # 3 call sites; origin lookup hoisted above each render

tests/
├── bash/
│   ├── engine/
│   │   ├── test_managed_ownership.bats      # NEW — all six decision rows
│   │   ├── test_managed_panel.bats          # unchanged — regression guard
│   │   └── test_managed_migration.bats      # unchanged — suffix split is not modified
│   └── sink/
│       ├── test_boundary_migration.bats     # MODIFIED — each case gains an origin
│       ├── test_preserve_boundary.bats      # unchanged — regression guard
│       └── test_adf.bats, test_adf_task.bats# unchanged — regression guards
├── powershell/                              # Pester twins of the above
└── conformance/scenarios/
    ├── us4-migration-ambiguous.json         # REWRITTEN — origin bridge ⇒ replaced, silent
    ├── us4-migration-ambiguous-human.json   # NEW — origin human ⇒ preserved, warned
    ├── us4-migration-clean.json             # unchanged
    └── sc008-deleted-managed-region-restored.json  # unchanged
```

**Structure Decision**: The existing two-port layout is kept exactly as it is. The feature adds one function
per port in the neutral engine and threads one optional parameter through the sink to three call sites per
port. No module is created, moved, or split — research R4 and R6 record why the seam falls where it does and
list every touched line.

## Complexity Tracking

> Fill ONLY if Constitution Check has violations that must be justified.

No violations. The Constitution Check passed both before Phase 0 and after Phase 1 design, and the design
reduced rather than increased complexity in two places worth naming:

- The ownership rule **leaves** the sink for the engine, removing a Constitution VIII grey area that
  predates this feature.
- `managed_section_suffix_split` is retained and unmodified rather than replaced, so the `other` path stays
  byte-identical and its existing tests remain valid regression guards.

One judgement call is recorded here rather than hidden, though it is not a violation: the `unknown` branch
(contract §1 rule 5) is not reachable through any shipping code path, because `identity_marker` requires an
origin and every caller supplies one. It is built because FR-004 requires it and because the alternative
default — treating an unreadable origin as `bridge` — is the single branch capable of deleting a human's
description. Research R3 records the cheaper-looking alternatives and why they were rejected.
