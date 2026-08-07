---

description: "Task list for 019 — A Ticket the Mirror Created Is the Mirror's to Replace"
---

# Tasks: A Ticket the Mirror Created Is the Mirror's to Replace

**Input**: Design documents from `/specs/019-fix-duplicate-acceptance-criteria/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/ownership-decision.md](./contracts/ownership-decision.md),
[quickstart.md](./quickstart.md)

**Tests**: REQUIRED, not optional. Constitution Principle XIII mandates TDD with ≥80% coverage, and the
project's bug-fix policy requires a test that reproduces the defect and **fails** before the fix is applied.
Every implementation task below is preceded by the test that must fail first.

**Organization**: Grouped by user story. The neutral engine decision (Phase 2) is genuinely shared by all
four stories, so it is foundational rather than duplicated per story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: `[US1]`..`[US4]`, mapping to the user stories in spec.md
- Exact file paths are given in every task

## Path Conventions

Two native ports, mirrored trees (see plan.md → Project Structure):

- Bash: `scripts/bash/engine/`, `scripts/bash/sink/jira/` — tests in `tests/bash/{engine,sink}/`
- PowerShell: `scripts/powershell/engine/`, `scripts/powershell/sink/jira/` — tests in
  `tests/powershell/{engine,sink}/`
- Cross-port byte equivalence: `tests/conformance/scenarios/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Establish the baseline that "byte-identical everywhere else" is later measured against. No
project initialisation is needed — this is a change to a shipped codebase.

- [X] T001 Capture the pre-change baseline: run `tests/run-bash.sh` and `bash tests/conformance/ci-conformance.sh`, and record the resulting pass counts in the branch's working notes so Phase 7 can prove no other behaviour moved
- [X] T002 [P] Confirm the linters are clean at baseline: `shellcheck $(git ls-files '*.sh')` and `actionlint`
- [X] T003 [P] Record the defect reproduction output from `specs/019-fix-duplicate-acceptance-criteria/quickstart.md` §1 (expect `2` sections, `migrated-warned`, exit 1) — this is the "fails before the fix" evidence the bug-fix policy requires

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The neutral engine ownership decision. Every user story routes through it.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Tests first ⚠️

> Write these tests FIRST and confirm they FAIL — the function does not exist yet.

- [X] T004 [P] Create `tests/bash/engine/test_managed_ownership.bats` covering all six rows of `contracts/ownership-decision.md` §1: marker duplicated → `malformed`; marker once → prefix above marker, `ok`; marker absent + `self` → empty prefix, `ok`; marker absent + `other` → suffix-split behaviour; marker absent + `unknown` → whole content preserved, `migrated-warned`; and an unrecognised ownership string treated as `unknown`
- [X] T005 [P] Create the Pester twin `tests/powershell/engine/ManagedOwnership.Tests.ps1` asserting the same six rows and the same canonical JSON output

### Implementation

- [X] T006 [P] Implement `managed_section_ownership_split <marker> <managed-json> <ownership>` in `scripts/bash/engine/managed_section.sh`, reading the existing content-node array from stdin and emitting canonical `{prefix, status}` — no Jira vocabulary, no direct `jq` (route through `scripts/bash/lib/output.sh`), no `$'\r\n'` inside any glob pattern
- [X] T007 [P] Implement `Split-JiraManagedSectionOwnership` in `scripts/powershell/engine/ManagedSection.psm1` with parameters `-Marker -ManagedJson -Ownership -ExistingJson`, and add it to the `Export-ModuleMember -Function` list at the end of that file
- [X] T008 Run `bats -r tests/bash/engine/test_managed_ownership.bats` and the Pester twin: both must now pass, and `tests/bash/engine/test_managed_migration.bats` plus `tests/powershell/engine/ManagedMigration.Tests.ps1` must still pass **unmodified** — `managed_section_suffix_split` is retained untouched (research R4)

**Checkpoint**: The decision exists and is proven in isolation, on both ports. No caller uses it yet, so the shipped behaviour is unchanged.

---

## Phase 3: User Story 1 - An updated spec.md replaces what the mirror wrote on the parent and its stories (Priority: P1) 🎯 MVP

**Goal**: Editing an acceptance criterion in `spec.md` and re-running reconcile leaves exactly one Acceptance Criteria section on the parent and on every affected story.

**Independent Test**: A description carrying no boundary on a ticket whose recorded origin is `bridge`, an edited acceptance-criteria clause, one run → exactly one acceptance-criteria section carrying the edited clause.

### Tests for User Story 1 ⚠️

> Write these FIRST and confirm they FAIL.

- [X] T009 [P] [US1] Add the reported-defect cases to `tests/bash/sink/test_boundary_migration.bats`: origin `bridge` + no boundary + edited specification → one acceptance-criteria section, status `ok`, no warning; and the unchanged-specification-but-changed-rendering variant of spec.md §US1 scenario 2
- [X] T010 [P] [US1] Add the same cases to `tests/powershell/sink/BoundaryMigration.Tests.ps1`
- [X] T011 [P] [US1] Rewrite `tests/conformance/scenarios/us4-migration-ambiguous.json`: its fixture carries `"origin":"bridge"`, so its recorded expectation flips from "content duplicated, one warning" to "content replaced, no warning" (research R7 — this file encodes the defect as expected output and will not pass otherwise)

### Implementation for User Story 1

- [X] T012 [P] [US1] In `scripts/bash/sink/jira/adf.sh`, give `_adf_resolve_managed` an optional third `origin` argument, translate it (`bridge`→`self`, `human`→`other`, anything else including empty→`unknown`) and delegate the `marker_count` branch to `managed_section_ownership_split`; give `adf_render_managed_description` the same optional third argument and pass it through
- [X] T013 [P] [US1] In `scripts/powershell/sink/jira/Adf.psm1`, add the optional `-Origin` parameter to `Resolve-JiraManagedAdfContent` and `ConvertTo-JiraManagedAdfDocument`, applying the identical translation and delegating to `Split-JiraManagedSectionOwnership`
- [X] T014 [US1] In `scripts/bash/sink/jira/plan_apply.sh`, pass `ctx.ticket_origins[<sid>]` to `adf_render_managed_description` at the story update call site (≈line 365)
- [X] T015 [US1] In `scripts/bash/sink/jira/plan_apply.sh`, pass `ctx.parent_origin` at the parent update call site (≈line 520) — same file as T014, so this task is sequential after it
- [X] T016 [US1] In `scripts/powershell/sink/jira/PlanApply.psm1`, pass the origin at the story call site (≈line 424) and the parent call site (≈line 586), **hoisting `$ticketOrigins` (≈line 448) and `$parentOrigin` (≈line 609) above their respective render calls** — this ordering hazard exists only in the PowerShell port (research R6)
- [X] T017 [US1] Run `specs/019-fix-duplicate-acceptance-criteria/quickstart.md` §1: it must now report `1` section, status `ok`, exit 0 — the same script that failed in T003

**Checkpoint**: The reported defect is fixed for the parent and story tiers, on both ports.

---

## Phase 4: User Story 4 - Text a human wrote is never mistaken for the mirror's own output (Priority: P1)

**Goal**: Widening what the mirror recognises as its own must not make it delete anyone's writing. This is the boundary condition on Phase 3 and ships with it, never after.

**Independent Test**: Every Phase 3 scenario re-run against tickets whose recorded origin is `human`, plus tickets carrying human prose above the boundary — every human-authored character survives.

### Tests for User Story 4 ⚠️

- [X] T018 [P] [US4] Add origin-`human` cases to `tests/bash/sink/test_preserve_boundary.bats`: a ticket a human created with no boundary → the whole description preserved above a newly established boundary, one named warning; and a ticket with human prose above an existing boundary → prose preserved verbatim, only the region below replaced
- [X] T019 [P] [US4] Add the same cases to `tests/powershell/sink/PreserveBoundary.Tests.ps1`
- [X] T020 [P] [US4] Create `tests/conformance/scenarios/us4-migration-ambiguous-human.json` — the same fixture as the rewritten `us4-migration-ambiguous.json` but with `"origin":"human"`, asserting the content is preserved and one warning is reported (this is the coverage the rewrite of T011 would otherwise remove)
- [X] T021 [P] [US4] Add the undeterminable-origin case to `tests/bash/sink/test_boundary_migration.bats` and `tests/powershell/sink/BoundaryMigration.Tests.ps1`: an origin that is neither `bridge` nor `human` → whole content preserved, status `migrated-warned`, ticket named in the warning (FR-004)

### Implementation for User Story 4

- [X] T022 [US4] Confirm no source change is required: the `other` and `unknown` branches are the pre-feature behaviour, retained by `managed_section_ownership_split` (T006/T007). If any test from T018–T021 fails, the defect is in the translation table of T012/T013, not here — fix it there
- [X] T023 [US4] Prove contract §5.3 (the regression invariant): for every ownership other than `self`, output is byte-identical to the baseline captured in T001 — `tests/bash/sink/test_adf.bats`, `test_adf_task.bats`, `tests/bash/engine/test_managed_panel.bats` and their Pester twins must pass **unmodified**

**Checkpoint**: Both P1 stories are complete. The mirror replaces what it wrote and preserves what it did not.

---

## Phase 5: User Story 2 - An updated plan.md replaces what the mirror wrote on the parent (Priority: P2)

**Goal**: Regenerating `plan.md` leaves exactly one plan summary on the parent.

**Independent Test**: A parent with recorded origin `bridge` and no boundary, a changed plan summary, one run → the new summary once and no part of the previous one.

**Note**: `reconcile.sh:750` merges the parsed plan summary into `.epic.description.blocks` **before** rendering, so the parent call site fixed in T015/T016 already carries this story. These tasks prove it rather than build it — if they fail, the parent call site is incomplete.

### Tests for User Story 2 ⚠️

- [X] T024 [P] [US2] Add to `tests/bash/sink/test_plan_in_boundary.bats`: origin `bridge`, no boundary, changed plan summary → the parent's description carries the new summary exactly once and no part of the previous one; plus the "plan summary and specification both changed in one run" case settling in a single write
- [X] T025 [P] [US2] Add the same cases to `tests/powershell/sink/PlanInBoundary.Tests.ps1`
- [X] T026 [P] [US2] Add the no-`plan.md` and no-summary-section regression cases to both files, asserting the outcome is unchanged from today (no plan content, no warning)

### Implementation for User Story 2

- [X] T027 [US2] Run T024–T026 and confirm they pass with **no source change**. If they do not, correct the parent call site in `scripts/bash/sink/jira/plan_apply.sh` (T015) or `scripts/powershell/sink/jira/PlanApply.psm1` (T016) — never by adding a second plan-specific code path

**Checkpoint**: All three artefacts named by the reporter behave correctly on the parent and story tiers.

---

## Phase 6: User Story 3 - An edited task replaces that sub-task's content (Priority: P2)

**Goal**: Editing an existing task in `tasks.md` leaves exactly one copy of that text on the sub-task.

**Independent Test**: A sub-task with recorded origin `bridge` and no boundary, edited task text, one run → the sub-task's description carries the edited text once.

**Depends on**: Phase 2 **and** T012/T013. T030 calls `_adf_resolve_managed` with the third `origin`
argument that T012 introduces; T031 calls `Resolve-JiraManagedAdfContent -Origin` introduced by T013. These
are the same two files, not merely the same seam. Only the tests (T028/T029) are independent of Phase 3.

### Tests for User Story 3 ⚠️

- [X] T028 [P] [US3] Add to `tests/bash/sink/test_plan_writes_tasks.bats`: origin `bridge` + no boundary + edited task text → one copy of the text and one metadata bullet list; an unchanged task → not written to; a metadata-only change → one updated copy
- [X] T029 [P] [US3] Add the same cases to the Pester twin under `tests/powershell/sink/`

### Implementation for User Story 3

- [X] T030 [P] [US3] In `scripts/bash/sink/jira/adf.sh`, give `adf_render_managed_task_description` the same optional third `origin` argument and pass it to `_adf_resolve_managed`
- [X] T031 [P] [US3] In `scripts/powershell/sink/jira/Adf.psm1`, add `-Origin` to `ConvertTo-JiraManagedTaskAdfDocument` and pass it to `Resolve-JiraManagedAdfContent`
- [X] T032 [US3] In `scripts/bash/sink/jira/plan_apply.sh`, pass `ctx.ticket_origins[<tid>]` at the sub-task update call site (≈line 733)
- [X] T033 [US3] In `scripts/powershell/sink/jira/PlanApply.psm1`, pass the origin at the sub-task call site (≈line 730), hoisting `$taskOrigins` (≈line 846) above the render call
- [X] T034 [US3] Confirm `tests/conformance/scenarios/sc008-task-tier-boundary.json` still passes unmodified

**Checkpoint**: All four user stories are complete on both ports and all three tiers.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Note**: T043 and T044 were added after the first numbering pass. Run them alongside T035/T036, before
T041.

- [X] T035 Run the full bash suite `tests/run-bash.sh` and confirm the pass count equals the T001 baseline plus the tests added here — no other test changed status
- [X] T036 Run `bash tests/conformance/ci-conformance.sh` and confirm exit 0 with zero lines containing `conformance divergence` (success is silent — there is no pass banner, and the temp paths it prints are harness noise)
- [X] T037 [P] Run `shellcheck $(git ls-files '*.sh')` and `actionlint`; both must be clean
- [~] T038 [P] Confirm coverage stays at or above the Principle XIII floor of 80% for the touched modules. **Partial**: PowerShell side gated and green — Pester `-CodeCoverage` over `ManagedSection.psm1` + `Adf.psm1` against `tests/powershell/{engine,sink}` measures **95.16%** (590/620 commands, 30 missed across both files). Bash side ungated: `kcov` cannot run on macOS against this port's required bash ≥4 (documented in `tests/coverage/bash-coverage.sh` — Apple's `/bin/bash` is 3.2, and pointing `--bash-parser` at Homebrew bash aborts with "Failed to exchange stderr for pipe"), so no percentage is obtainable locally; only the Linux CI job produces the gated number. `--mode bats` (hit counts, no denominator) traced `managed_section.sh` 114, `sink/jira/adf.sh` 97, `sink/jira/plan_apply.sh` 680 statements — see T053
- [X] T039 [P] Add the CHANGELOG.md entry under the unreleased heading, describing the user-visible change: a ticket the mirror created is replaced rather than duplicated, and tickets already duplicated are not repaired
- [X] T040 [P] Update the engine module map in `docs/README.md` to list `managed_section_ownership_split` / `Split-JiraManagedSectionOwnership` alongside the existing splice functions. **Note** (T050): the actual engine module map lives in `docs/02-module-architecture.md` — `docs/README.md` carries no such map — done there instead
- [X] T041 Run the full `quickstart.md` validation end to end, including §3's regression guard — if any test other than the two named in research R7 needed editing, stop and investigate rather than editing it
- [ ] T042 Push to `ci/windows-probe` and read the resulting check-run annotations (~11 min). Diff them against `main`'s annotations before attributing any failure to this branch — `main` is **not** green on `windows-latest`. One retry maximum on a flake, then hand the result back
- [X] T043 [P] Assert FR-017 on the new payload: extend `tests/bash/commands/test_reconcile_dry_run.bats` and `tests/powershell/commands/Reconcile.DryRun.Tests.ps1` with an origin-`bridge`, no-boundary fixture — `--dry-run` predicts exactly the description payload and the (now empty) warning set the real run produces, and issues zero writes. `plan_apply.sh:243` records that the dry-run report *is* this plan object, so this asserts an existing guarantee over changed content rather than building a second path
- [X] T044 [P] Assert contract §5.5, FR-018 and SC-005 on all three tiers: extend `tests/bash/commands/test_reconcile_idempotent.bats` and `tests/powershell/commands/Reconcile.Idempotent.Tests.ps1` with an origin-`bridge`, no-boundary description — the first run replaces the region, the second reports 0 created / 0 updated and issues no `PUT`. The `self` branch is the only one that can regress this, because it re-renders the whole region on every run

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately
- **Foundational (Phase 2)**: depends on Phase 1 — **blocks every user story**
- **US1 (Phase 3)**: depends on Phase 2
- **US4 (Phase 4)**: depends on Phase 3 (it asserts the invariant Phase 3 could break) — both are P1 and ship together
- **US2 (Phase 5)**: depends on Phase 3 (the parent call site it proves is fixed there)
- **US3 (Phase 6)**: its tests (T028/T029) depend on Phase 2 only; its implementation (T030–T033) depends on
  T012/T013 — the same two sink files — and T032 additionally on T014/T015, the same `plan_apply.sh`
- **Polish (Phase 7)**: depends on every story being complete

### User Story Dependencies

- **US1 (P1)**: after Phase 2. No dependency on another story.
- **US4 (P1)**: after US1. It is the boundary condition on US1's change and must not be deferred — an irrecoverable loss of a human's text is a worse defect than the duplicate being removed.
- **US2 (P2)**: after US1. Proves the parent tier rather than building it.
- **US3 (P2)**: tests after Phase 2, implementation after T012–T015. It touches a different *call site*, but the same two sink files as US1, so the implementation serialises behind it.

### Within Each User Story

- Tests are written first and MUST fail before the implementation task that satisfies them
- Engine before sink; sink render entrypoints before call sites
- Both ports before the checkpoint — a story is not complete on one port

### Parallel Opportunities

- T002 and T003 (Setup)
- T004 and T005; then T006 and T007 (different files, different ports)
- T009, T010, T011 (three different test files)
- T012 and T013 (bash sink vs PowerShell sink)
- T018, T019, T020, T021 (four different test files)
- T024, T025, T026
- T028 and T029; T030 and T031
- T037, T038, T039, T040, T043, T044
- **US3's tests (T028/T029) can be written in parallel with Phases 3–5** once Phase 2 is done. Its
  implementation cannot — see "Not parallel" below

**Not parallel**: T014 and T015 edit the same file (`plan_apply.sh`) — sequential; T032 edits it again, after both. T030 edits `adf.sh` after T012, and T031 edits `Adf.psm1` after T013 — one writer per file.

---

## Parallel Example: Phase 2 (Foundational)

```bash
# Write both failing unit tests together:
Task: "Create tests/bash/engine/test_managed_ownership.bats covering all six decision rows"
Task: "Create tests/powershell/engine/ManagedOwnership.Tests.ps1 asserting the same six rows"

# Then implement both ports together:
Task: "Implement managed_section_ownership_split in scripts/bash/engine/managed_section.sh"
Task: "Implement Split-JiraManagedSectionOwnership in scripts/powershell/engine/ManagedSection.psm1"
```

## Parallel Example: User Story 1

```bash
# Three independent test files:
Task: "Add bridge-origin defect cases to tests/bash/sink/test_boundary_migration.bats"
Task: "Add the same cases to tests/powershell/sink/BoundaryMigration.Tests.ps1"
Task: "Rewrite tests/conformance/scenarios/us4-migration-ambiguous.json for origin bridge"

# Then both sink render entrypoints:
Task: "Thread origin through _adf_resolve_managed in scripts/bash/sink/jira/adf.sh"
Task: "Add -Origin to Resolve-JiraManagedAdfContent in scripts/powershell/sink/jira/Adf.psm1"
```

---

## Implementation Strategy

### MVP First (Phases 1–4)

1. Phase 1: Setup — capture the baseline and the failing reproduction
2. Phase 2: Foundational — the engine decision, proven in isolation on both ports
3. Phase 3: US1 — the reported defect, fixed on the parent and story tiers
4. Phase 4: US4 — prove no human text can be lost by the change
5. **STOP and VALIDATE**: quickstart §1 reports `1` / `ok`; the full suite matches the T001 baseline

US1 without US4 is not a deliverable MVP. US4 is the safety condition on US1's own change, and both are P1
for that reason.

### Incremental Delivery

1. Phases 1–2 → the decision exists, shipped behaviour unchanged
2. + Phase 3 → the reported defect is fixed (the reporter's `Hello World` / `Hello Universe` case)
3. + Phase 4 → proven safe for adopted tickets and human prose
4. + Phase 5 → `plan.md` proven on the parent (expected to need no source change)
5. + Phase 6 → `tasks.md` proven on the sub-task tier
6. + Phase 7 → linters, conformance, coverage, dry-run and idempotency assertions, CHANGELOG, Windows probe

### Parallel Team Strategy

With two developers, after Phase 2:

- Developer A: Phase 3 → Phase 4 → Phase 5 (the parent/story chain, one file collision to serialise)
- Developer B: T028/T029 (the task-tier tests) immediately, then T030–T034 once Developer A has landed
  T012–T015 — the task tier shares `adf.sh`, `Adf.psm1` and `plan_apply.sh` with US1

---

## Notes

- `[P]` = different files, no dependency on an incomplete task
- Every implementation task is preceded by a test that must fail first (Principle XIII and the project's bug-fix policy)
- **Two existing test artefacts are rewritten, not extended** — `us4-migration-ambiguous.json` and the boundary-migration tests. If any *other* existing test needs editing to pass, that is a signal the change reached further than the decision, not a licence to edit the test (contract §5.3)
- Repairing tickets already carrying a duplicate is **out of scope** by the reporter's decision. No task here attempts it, and no test asserts it happens
- `bats -r` is load-bearing — without `-r` it silently runs nothing
- Commit after each task or logical group

---

## Phase 8: Convergence

**Purpose**: Close the gap between the artefacts and the code as measured after Phase 7. The implementation
itself is correct and both suites are green (bash 1662/1662, conformance exit 0 with zero divergence lines,
`shellcheck`/`actionlint` clean, quickstart §1 reports `1` / `ok`). What remains is unproven behaviour, one
unresolved requirement conflict, and two records that no longer match what changed.

- [X] T045 Resolve the conflict between FR-005/FR-003/US4 AC1 and contract §1 rule 4 per FR-005 (contradicts): the `other` branch of `managed_section_ownership_split` and `Split-JiraManagedSectionOwnership` still delegates to the structural byte comparison `managed_section_suffix_split`, so the human-origin outcome depends on the stored content being byte-stable across a tracker round trip (forbidden by FR-005 without qualification) and strips the matched suffix rather than preserving "every character" (US4 AC1, FR-003). Either narrow rule 4 so the decision is origin-only, or record the retained 018 FR-020a migration behaviour as a named, justified exception in `contracts/ownership-decision.md` §1 and `research.md` — where FR-005 is currently not mentioned at all. **Resolved**: recorded as a named exception (`research.md` §R8, `contracts/ownership-decision.md` §1) — narrowing rule 4 was measured against `test_boundary_migration.bats`'s PRE-2 case and reintroduces the duplication FR-006/FR-007 forbid; nothing is discarded by either outcome of rule 4, so FR-003 holds in effect even though the mechanism is content-dependent
- [X] T046 Add a parent-tier row-3 regression case to `tests/bash/sink/test_boundary_migration.bats` and `tests/powershell/sink/BoundaryMigration.Tests.ps1` per US1/AC3 and FR-008 (missing): all three 019 cases assert `.stories[0]` only, and PRE-9 in the pre-release fixture carries the marker so it exercises rule 2. Assert `parent_current` + `parent_origin: "bridge"` + no boundary → the whole existing parent description replaced, exactly one acceptance-criteria section, no warning. The behaviour was probed by hand and is correct; only the guard is missing
- [X] T047 Add the User Story 2 cases to `tests/bash/sink/test_plan_in_boundary.bats` and `tests/powershell/sink/PlanInBoundary.Tests.ps1` per US2 AC1–AC3, FR-010 and SC-003 (missing): neither file contains an `origin`, a `bridge` or a `019` reference, so T024–T026 are marked complete with nothing behind them and T027's "confirm they pass with no source change" is unproven. Cover the changed plan summary on a bridge-origin parent with no boundary, the "plan summary and specification both changed in one run settles in a single write" case, and the no-`plan.md` / no-summary-section regressions. **Resolved** alongside T024–T026 above — six cases added (three bash, three Pester), all pass with no source change
- [ ] T048 Push to `ci/windows-probe` and read the resulting check-run annotations per FR-019 and Constitution VI (missing): this is T042, still unchecked. The change is in the managed-section splice — the project's named Windows-divergence site, and the hazard the plan's Constitution VI gate calls out. Diff the annotations against `main`'s before attributing any failure to this branch (`main` is not green on `windows-latest`); one retry maximum on a flake
- [X] T049 Add the "origin bridge, no boundary, unchanged specification" case to `tests/powershell/sink/BoundaryMigration.Tests.ps1` per US1/AC2 (partial): the bash twin has it at `test_boundary_migration.bats:112`, the Pester file has only T010's edited-spec case and T021, so this acceptance scenario is proven on one port only
- [X] T050 Document the ownership decision in `docs/02-module-architecture.md` per plan: docs module map, T040 (missing): `docs/README.md` — the file T040 names — carries no engine module map and no `managed_section` reference at all, and `git status docs/` is clean. The real map is the `managed_section` node at `docs/02-module-architecture.md:137`, which still describes the module as "marker-delimited byte splice" alone. Add the ownership decision at that map's granularity
- [X] T051 Bring `research.md` §R7 and `quickstart.md` §3 in line with what actually changed per contract §5.3 and T041 (partial): four existing artefacts were edited, not the two on record — `tests/bash/sink/test_adf.bats` and `tests/powershell/sink/Adf.Tests.ps1` (the row-3 case gains origin `human`, though R7 lists `test_adf.bats` as an *unchanged* regression guard), `tests/bash/ci/test_conformance_no_cross_os_shard.bats` (106 → 107 scenarios), and `tests/conformance/mock-jira/configs/preserve-pre-release.json`. Each carries an inline justification; the record does not
- [X] T052 Assert the accepted-loss case explicitly per spec Edge Cases and Assumptions (partial): `preserve-pre-release.json` flipped PRE-2 and PRE-3 from `origin:"bridge"` to `origin:"human"`, which keeps the pre-existing suffix-split expectations green but removes the only fixture in which a pre-018 bridge-origin ticket carries a human paragraph. The spec accepts that such a paragraph is lost when the region is restored — add a test that states that accepted trade-off rather than leaving it hidden behind a relabelled fixture
- [~] T053 Measure coverage for the touched modules against the Principle XIII 80% floor per Constitution XIII, T038 (missing): `scripts/bash/engine/managed_section.sh`, `scripts/powershell/engine/ManagedSection.psm1`, `scripts/bash/sink/jira/adf.sh` and `scripts/powershell/sink/jira/Adf.psm1` have not been measured. Note that `coverage-bash` has been red on `main` since 2026-07-28 on a kcov timeout — scope the traced phase rather than running the whole suite under kcov. **Partial, measured 2026-08-07**: PowerShell — `ManagedSection.psm1` + `Adf.psm1` together, 95.16% (590/620), well clear of the floor. Bash — `require_kcov` refuses on this host (macOS; the port's bash ≥4 prerequisite cannot be satisfied by Apple's `/bin/bash` 3.2, and kcov cannot drive a non-Apple bash on macOS at all), so the gated bash number can only be produced by the Linux `coverage-bash` CI job — which is independently red since 2026-07-28 regardless of this branch. `--mode bats` (traced, ungated) recorded hit counts of 114/97/680 statements for the three touched bash files, a positive but non-quantitative signal. The full bash-side gate remains open pending a CI run
