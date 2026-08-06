---

description: "Task list for 018 — the mirror adds to a ticket, and never overwrites what it did not write"
---

# Tasks: The Mirror Adds to a Ticket, and Never Overwrites What It Did Not Write

**Input**: Design documents from `/specs/018-preserve-ticket-content/`

**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/managed-description.md`,
`contracts/summary-record.md`, `quickstart.md`

**Tests**: **REQUIRED, and first.** Constitution XIII is strict Red-Green-Refactor: every implementation
task below is preceded by the test task that must be observed failing. A task list with an implementation
task ahead of its test is a review rejection.

**Organization**: Grouped by user story. Note the one honest exception to story independence, stated in
Dependencies below: User Story 1 rides on User Story 2's mechanism (research R2), and User Story 4's split
is foundational rather than optional (research R3).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel — different files, no dependency on an incomplete task
- **[Story]**: US1 / US2 / US3 / US4, mapping to `spec.md`
- Every task names its exact file path

## Path Conventions

Two native ports, one module per concern, mirrored one-to-one:

- Bash: `scripts/bash/{engine,sink/jira,commands,lib}/…`, tests in `tests/bash/{engine,sink,commands}/…`
- PowerShell: `scripts/powershell/{engine,sink/jira,commands,lib}/…`, tests in
  `tests/powershell/{engine,sink,commands}/…`
- Cross-port equivalence: `tests/conformance/scenarios/*.json`, mock configs in
  `tests/conformance/mock-jira/configs/`

Every behaviour lands in **both** ports and must produce byte-identical output. That is why the tasks come
in pairs.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: A recorded baseline, and the mock seeds every later phase depends on

- [X] T001 Record the green baseline — run `tests/run-bash.sh`, the Pester suite, and `bash tests/conformance/ci-conformance.sh` on this branch and note the pass counts in the PR description, so that every red observed from T004 onward is attributable to this feature and not to pre-existing state. Note that `main` is already red on `windows-latest`; the baseline is the local three suites, not CI.
- [X] T002 [P] Add the seeded-prefix mock config in `tests/conformance/mock-jira/configs/preserve-human-prefix.json` — a pre-seeded parent and story whose stored `description` carries two human paragraphs above the delimiter node, plus their `spec-kit-jira` identity properties, using the mock's existing `issues` seeding block (`tests/conformance/mock-jira/mock-server.ps1:97`)
- [X] T003 [P] Add the pre-release mock config in `tests/conformance/mock-jira/configs/preserve-pre-release.json` — three pre-seeded tickets carrying **no** delimiter: one holding exactly the mirror's own output, one with a human paragraph prepended, one matching neither; each with an identity property carrying no `summary` field

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The ownership boundary itself — the split, the migration split, the origin-independent render,
and the privacy scope that stops the boundary bricking the mirror

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. Shipping User Story 2 without
T008–T011 duplicates content on every ticket of an existing estate (research R3).

### Engine — the marker count (research R6, contract §1/§3)

- [X] T004 [P] Failing test: `managed_section_panel_split` returns `marker_count` — `0` for no marker, `1` for a well-formed boundary, `2` for two marker-bearing nodes — in `tests/bash/engine/test_managed_panel.bats`
- [X] T005 [P] Failing test: the same three cases for the PowerShell split in `tests/powershell/engine/ManagedPanel.Tests.ps1`
- [X] T006 Add `marker_count` to the canonical return of `managed_section_panel_split`, retaining `had_marker` so no existing caller changes shape, in `scripts/bash/engine/managed_section.sh`
- [X] T007 Add `marker_count` to the PowerShell split with byte-identical canonical output in `scripts/powershell/engine/ManagedSection.psm1`

### Engine — the migration split (research R3, contract §3)

- [X] T008 [P] Failing test: `managed_section_suffix_split <managed-nodes>` returns `{prefix, matched}` — exact match with empty prefix, match with a human prefix, no match returning the whole array — in `tests/bash/engine/test_managed_migration.bats`
- [X] T009 [P] Failing test: the same three cases in `tests/powershell/engine/ManagedMigration.Tests.ps1`
- [X] T010 Implement `managed_section_suffix_split` as pure structural array comparison — no marker, no tracker vocabulary, canonical output — in `scripts/bash/engine/managed_section.sh` (depends on T006, same file)
- [X] T011 Implement the PowerShell equivalent in `scripts/powershell/engine/ManagedSection.psm1` (depends on T007, same file)

### Sink — the origin-independent render (research R1, data-model §3)

- [X] T012 [P] Failing test: `adf_render_managed_description` renders a delimited region for a `bridge-created` origin, and resolves all five rows of the contract §3 table (malformed / well-formed / clean migration / warned migration / creation), in `tests/bash/sink/test_adf.bats`
- [X] T013 [P] Failing test: the same five rows in `tests/powershell/sink/Adf.Tests.ps1`
- [X] T014 Remove the `bridge-created` early return and implement the contract §3 resolution — delegating to `managed_section_panel_split` and, on `marker_count == 0`, to `managed_section_suffix_split` — in `scripts/bash/sink/jira/adf.sh`
- [X] T015 Implement the same resolution in `scripts/powershell/sink/jira/Adf.psm1`

### Sink — the privacy scan scope (research R4, contract §5)

- [X] T016 [P] Failing test: a `*.atlassian.net` host present **only** in a preserved human prefix does not block the run, while the same host in a node the mirror composes still blocks with the existing exit code and zero writes, in `tests/bash/sink/test_privacy_block.bats`
- [X] T017 [P] Failing test: the same two cases in `tests/powershell/sink/PrivacyGuard.Block.Tests.ps1`
- [X] T018 Scan a projection of each payload that excludes the description's preserved prefix, at all four pre-write scan sites (`plan_apply.sh:877` in `apply_writes`, and `:982`, `:988`, `:994` in `apply_writes_with_recognition`), in `scripts/bash/sink/jira/plan_apply.sh`
- [X] T019 Apply the same projection at the matching four scan sites in `scripts/powershell/sink/jira/PlanApply.psm1`

**Checkpoint**: The boundary mechanism exists and is safe to write through. User stories can begin.

---

## Phase 3: User Story 2 - What a human writes on a mirrored ticket survives every reconcile (Priority: P1) 🎯 MVP

**Goal**: Every ticket the mirror manages — parent, story, sub-task — carries the boundary, and text outside
it is preserved byte-for-byte through every reconcile.

**Independent Test**: Mirror a specification with two user stories and a task tier against the Jira double,
seed each returned ticket's description with human prose above the boundary, edit the specification, re-run,
and assert every payload preserves its prose verbatim while the managed region reflects the edit.

### Tests for User Story 2 ⚠️

> Write these first, run them, and observe them fail before touching Phase 3 implementation.

- [X] T020 [P] [US2] Invert the assertion at `tests/bash/sink/test_us7_plan_apply.bats:47` — "a bridge-created update keeps the whole-description behaviour" becomes "a bridge-created update preserves the human prefix and renders a delimited managed region below it". This is the reproduction of the reported defect; it must be red before T024.
- [X] T021 [P] [US2] Invert the matching PowerShell assertion in `tests/powershell/sink/PlanApply.HumanContent.Tests.ps1`
- [X] T022 [P] [US2] Failing tests for the four remaining boundary behaviours — preservation across parent, story and sub-task (FR-007); an edit confined to the prefix produces zero writes (FR-009); a deleted managed region is restored in full (FR-008); a duplicated delimiter warns by ticket key and writes no description while other fields still reconcile (FR-012) — in a new `tests/bash/sink/test_preserve_boundary.bats`
- [X] T023 [P] [US2] The same four behaviours in a new `tests/powershell/sink/PreserveBoundary.Tests.ps1`
- [X] T068 [P] [US2] Failing test: a tracker rejection of an oversized description — the combined human prefix and managed region exceed the field limit — produces one warning naming the ticket key, writes no description for that ticket, writes every other field of that ticket normally, truncates nothing, and leaves the host exit code unaffected (FR-011, contract managed-description §2), in `tests/bash/sink/test_preserve_boundary.bats`
- [X] T069 [P] [US2] The same behaviour in `tests/powershell/sink/PreserveBoundary.Tests.ps1`
- [X] T070 [P] [US2] Failing tests for all three suppression causes — a halted status, an operator flag, and unresolved drift — asserting that the ticket acquires no boundary, no plan section, and no summary record on that run, and acquires all three on the first run that is allowed to write to it (FR-023, contract managed-description §4, summary-record §2), in a new `tests/bash/sink/test_suppressed_no_boundary.bats`. Clarified (spec.md, session 2026-08-05): only `halted` suppresses content; a flag or unresolved drift only ever withheld the transition (FR-035/FR-036, feature 015/016) and are unaffected by this feature — the tests prove both halves.
- [X] T071 [P] [US2] The same three causes and the same settle in a new `tests/powershell/sink/SuppressedNoBoundary.Tests.ps1`

### Implementation for User Story 2

- [X] T024 [US2] Stop excluding the `bridge` origin: build `ticket_origins` from every recognised ticket (currently `with_entries(select(.value.origin != "bridge"))` at line 348) and stop omitting `origin` from the lifecycle context (line 1176), in `scripts/bash/commands/reconcile.sh`
- [X] T025 [US2] Make the same two changes in `scripts/powershell/commands/Reconcile.psm1`
- [X] T026 [US2] Make the managed-panel path unconditional at **all four** origin gates — `:325` story update (`!= "bridge-created"`), `:446` parent render (`!= "bridge"`), `:466` parent churn (`elif … != "bridge"`), `:683` lifecycle churn (`!= "bridge-created"`) — so that `plan_managed_description_status` becomes the universal churn comparison on **every** tier including the parent; note the two spellings and unify them in this change (see T072). Wire the malformed-boundary warning and the tracker-rejection warning (FR-011, T068), each skipping only that ticket's description field while every other field still reconciles. In `scripts/bash/sink/jira/plan_apply.sh`
- [X] T027 [US2] Make the same four gates unconditional — `:380`, `:509`, `:537`, `:787` — and wire the same two warnings in `scripts/powershell/sink/jira/PlanApply.psm1`
- [X] T072 [US2] Unify the origin vocabulary the four gates test. `recognition.sh:176,367` emit `"bridge"`; `adf.sh:205` and `plan_apply.sh:219`'s own contract comment say `"bridge-created"`. Today the mismatch is unreachable because `reconcile.sh:348` excludes bridge tickets from the map — T024 removes exactly that exclusion. Settle on one spelling, correct the `:219` comment, and assert the chosen value in `tests/bash/sink/test_recognition.bats`. In `scripts/bash/sink/jira/plan_apply.sh` and `scripts/bash/sink/jira/adf.sh` (depends on T026, same file)
- [X] T073 [US2] Apply the identical unification in `scripts/powershell/sink/jira/PlanApply.psm1` and `Adf.psm1` (depends on T027)

### Cross-port proof for User Story 2

- [X] T028 [P] [US2] Add the conformance scenario `tests/conformance/scenarios/us2-preserve-human-prefix.json` — fixture `repo-with-mirrored-spec`, mock config `preserve-human-prefix`, two runs — asserting the prefix survives byte-for-byte and the second run writes nothing
- [X] T029 [US2] Run `bash tests/conformance/ci-conformance.sh` and confirm zero `conformance divergence` lines and exit 0 (success is silent — there is no pass banner)

**Checkpoint**: A human can annotate any mirrored ticket and keep the annotation. SC-001 and SC-004 hold.

---

## Phase 4: User Story 1 - The plan is added to the Epic's description, not substituted for it (Priority: P1)

**Goal**: `plan.md`'s content lands as an addition below whatever the parent's description already holds,
refreshed in place on every later run.

**Independent Test**: Mirror a specification, seed the parent description with human prose above the
boundary, produce a `plan.md`, run again, and assert the prose is preserved verbatim and the plan section
sits inside the managed region; then change the plan and re-run, asserting the section is replaced in place
and exactly one exists.

**Note**: research R2 established that the plan blocks already render last inside the parent's managed
nodes, so this story needs little production code of its own — but it is the story the operator asked for,
so its behaviours are pinned by their own tests and their own conformance scenarios.

### Tests for User Story 1 ⚠️

- [X] T030 [P] [US1] Failing tests for the six plan-section behaviours — plan section inside the managed region below a preserved prefix (FR-001); replaced in place with exactly one section after a plan change (FR-002); absent with no warning when there is no plan (FR-003); removed when a mirrored plan later yields nothing (FR-004); zero writes when unchanged (FR-005); `--dry-run` payload byte-identical to the real run's — in a new `tests/bash/sink/test_plan_in_boundary.bats`
- [X] T031 [P] [US1] The same six behaviours in a new `tests/powershell/sink/PlanInBoundary.Tests.ps1`

### Implementation for User Story 1

- [X] T032 [US1] Confirm against the now-red tests that the plan blocks appended to `.epic.description.blocks` (line 731) remain the last nodes of the parent's managed region, and correct the append point if T030 shows otherwise, in `scripts/bash/commands/reconcile.sh`. Confirmed correct as-is — T030 passed with no production change; research R2's premise holds.
- [X] T033 [US1] Apply the identical confirmation or correction in `scripts/powershell/commands/Reconcile.psm1`. Confirmed correct as-is (`Reconcile.psm1:871`, the same append shape) — no change needed.

### Cross-port proof for User Story 1

- [X] T034 [P] [US1] Add `tests/conformance/scenarios/us1-plan-added-not-replaced.json` — fixture `repo-with-plan-and-prefix` (new: `repo-with-plan` carries no ticket marker, so it cannot exercise SC-002's "pre-run description" against a pre-seeded human prefix; this fixture pairs a plan.md with the marker-bound spec.md `repo-with-preserve-prefix-spec` already uses), mock config `preserve-human-prefix` — asserting the pre-run description is a contiguous subsequence of the post-run description (SC-002). Verified byte-identical across ports via `run-scenario.sh`.
- [X] T035 [US1] "The plan changed, then deleted" (SC-003, FR-002, FR-004). Deviated from a `tests/conformance/scenarios/us1-plan-changed-then-deleted.json` E2E scenario: `run-scenario.sh`'s `runs[]` share one workdir/mock per scenario with no per-run file-mutation primitive, so a plan.md that changes content between runs cannot be expressed without extending the shared harness — the same constraint `us5-plan-on-parent.json` already documents for this identical concern ("the changed-plan case is proven byte-for-byte cross-port at the plan_apply unit level, T090"). Followed that precedent: added the cross-port byte-identity proof (plan A → B, then B → deleted) directly to `tests/bash/sink/test_plan_in_boundary.bats` instead.

**Checkpoint**: The operator's explicit request is delivered. SC-002 and SC-003 hold.

---

## Phase 5: User Story 3 - A human's rename is reported and kept, never silently undone (Priority: P2)

**Goal**: The mirror records the summary it last wrote, so a human's rename is named and preserved instead
of silently reverted; `--on-drift=proceed` restores the specification's title.

**Independent Test**: Mirror a specification, change the returned ticket's summary on the Jira double,
re-run, and assert no summary write is sent, one named warning identifies the ticket and the field, and a
run with the drift override sends exactly one summary write restoring the specification's title.

**Note**: fully independent of User Stories 1, 2 and 4 — it touches a different field and a different
record.

### Tests for User Story 3 ⚠️

- [X] T036 [P] [US3] Failing test: `identity_marker` carries a `summary` field when one is supplied and omits it entirely when not, and `identity_claimed_by_other` is unaffected by its presence, in `tests/bash/sink/test_identity.bats`
- [X] T037 [P] [US3] The same two assertions in `tests/powershell/sink/Identity.Tests.ps1`
- [X] T038 [P] [US3] Failing test: a bound entry surfaces `last_summary` from the identity marker, and omits it for a marker written by a previous release, in `tests/bash/sink/test_recognition.bats`
- [X] T039 [P] [US3] The same two assertions in `tests/powershell/sink/Recognition.Tests.ps1`
- [X] T040 [P] [US3] Failing tests for the whole contract §4 decision table plus the §3 normalisation rule and the task tier — no record means no warning (FR-018); record equal means a silent retitle (FR-017); record different means the field is omitted and one warning names ticket and field (FR-015); `--on-drift=proceed` restores and counts it (FR-016); a whitespace-only difference never warns; a settled ticket writes no entity property at all (FR-019) — in a new `tests/bash/sink/test_summary_record.bats`
- [X] T041 [P] [US3] The same six behaviours in a new `tests/powershell/sink/SummaryRecord.Tests.ps1`

### Implementation for User Story 3

- [X] T042 [P] [US3] Add the optional `summary` parameter to `identity_marker` and `identity_write`, omitted rather than empty, in `scripts/bash/sink/jira/identity.sh`
- [X] T043 [P] [US3] Add the same optional parameter in `scripts/powershell/sink/jira/Identity.psm1`
- [X] T044 [P] [US3] Surface `last_summary` on each bound entry from the already-read identity marker — no extra request — in `scripts/bash/sink/jira/recognition.sh`
- [X] T045 [P] [US3] Surface `last_summary` the same way in `scripts/powershell/sink/jira/Recognition.psm1`
- [X] T046 [US3] Add `ticket_summaries` and `ticket_last_summaries` to the plan context beside `ticket_descriptions`, both omitted when empty, in `scripts/bash/commands/reconcile.sh` (depends on T024, same function)
- [X] T047 [US3] Add the same two maps in `scripts/powershell/commands/Reconcile.psm1` (depends on T025)
- [X] T048 [US3] Add the shared `plan_summary_drift_status` helper and apply the contract §4 decision in all three tiers — omitting `summary` from the desired fields and emitting one warning per drifted ticket; give `_plan_writes_parent` and `plan_writes_tasks` a warnings channel so all three report through `plan_writes`' existing `warnings` key — and stamp the record after any write whose payload carried a summary, in `scripts/bash/sink/jira/plan_apply.sh` (depends on T026, same file)
- [X] T049 [US3] Apply the identical helper, decision, warnings channels and stamping in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T027)

### Cross-port proof for User Story 3

- [X] T050 [P] [US3] Add `tests/conformance/scenarios/us3-summary-rename-withheld.json` — a pre-seeded ticket whose stored summary differs from its recorded one — asserting no summary key in the payload and one named warning
- [X] T051 [US3] Add `tests/conformance/scenarios/us3-summary-rename-proceed.json` — the same state run with `--on-drift=proceed` — asserting exactly one summary write and an ordinary update count

**Checkpoint**: SC-005 holds. A Product Owner's rename survives, and the operator has the existing escape
hatch when they want the specification to win.

---

## Phase 6: User Story 4 - An existing installation gains the boundary without losing or duplicating a word (Priority: P3)

**Goal**: The one-time transition costs no human text, duplicates nothing where the migration is
unambiguous, warns by ticket key where it is not, and settles to zero on the next run.

**Independent Test**: Seed the Jira double with tickets in the pre-release shape — no boundary, a
mirror-written description, and a variant with human text appended — run the mirror once, and assert no
human text is lost, no content is duplicated on the unambiguous tickets, and a second run reports zero
writes.

**Note**: the split this story depends on is built in Phase 2 (T008–T011), because User Story 2 cannot ship
safely to an existing estate without it. What remains here is the reporting and the upgrade proof.

### Tests for User Story 4 ⚠️

- [X] T052 [P] [US4] Failing tests for the three migration branches and the settle — untouched pre-release description migrates with nothing above the boundary and no duplication; a human-prefixed one keeps the prefix exactly; an ambiguous one loses nothing and produces one warning naming the ticket key; the run after each reports zero writes (FR-020 for the loss guarantee on all three, FR-020a for the two unambiguous branches, FR-020b for the warned one, FR-021 for the settle) — in a new `tests/bash/sink/test_boundary_migration.bats`. New fixture `tests/conformance/fixtures/repo-with-pre-release-migration` and a `PRE-9` parent added to the pre-existing `preserve-pre-release` mock config to give the parent tier a stable binding.
- [X] T053 [P] [US4] The same four behaviours in a new `tests/powershell/sink/BoundaryMigration.Tests.ps1`
- [X] T052/T053 note: both files passed on first run against the existing implementation — the warning wiring (T054/T055) was already in place from `_adf_resolve_managed`/`_plan_apply_managed_field` (T014/T026) in Phase 2/3; no production code changed in this phase.

### Implementation for User Story 4

- [X] T054 [US4] Wire the ambiguous-migration warning — named by ticket key, non-blocking, reported through the existing `warnings` channel and counted through the existing `updated` vocabulary with no new key — in `scripts/bash/sink/jira/plan_apply.sh` (depends on T048, same file). Confirmed already wired (see T052 note); verified by T052's tests, no change needed.
- [X] T055 [US4] Wire the identical warning in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T049). Confirmed already wired; verified by T053's tests, no change needed.

### Cross-port proof for User Story 4

- [X] T056 [P] [US4] Add `tests/conformance/scenarios/us4-migration-clean.json` — mock config `preserve-pre-release`, two runs — asserting no duplication on the two unambiguous tickets and zero writes on the second run. Manually verified byte-identical across both ports before trusting it.
- [X] T057 [US4] Add `tests/conformance/scenarios/us4-migration-ambiguous.json` — asserting nothing is lost, one warning names the ticket, and the host exit code is unaffected. Manually verified byte-identical across both ports before trusting it.

**Checkpoint**: SC-006 holds. An existing team can upgrade without losing the annotations this feature
exists to protect.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T058 [P] Update `docs/05-reconcile-flow.md` — the ownership boundary in the pipeline, and the fact that the description write now replaces only the managed region
- [X] T059 [P] Update `docs/08-safety-model.md` — what the mirror owns, what it never touches, and the narrowed privacy-scan scope with research R4's argument
- [X] T060 [P] Add the `Unreleased` entry to `CHANGELOG.md` — the boundary, the plan-as-addition behaviour, the summary record, and the one-time transition an existing consumer will see as ordinary `updated` counts
- [X] T061 [P] Document the one-time transition for consumers in `INSTALL.md`, as feature 017's provenance-label back-fill is documented
- [X] T062 Run `shellcheck $(git ls-files '*.sh')` and `actionlint`; both must be clean. Ran shellcheck via the exact CI invocation (`find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +`) — clean. `actionlint` — clean.
- [X] T063 Run the full suites — `tests/run-bash.sh`, the Pester suite, and `bash tests/conformance/ci-conformance.sh` — and compare the pass counts against T001's baseline. Final state: bash 1556/1556 (0 failed), Pester 1238/1238 (0 failed), conformance 96/96 scenarios byte-identical across ports (0 divergence). All three suites grew monotonically across this phase's work with zero regressions.
- [X] T064 Confirm statement coverage stays at or above 80% on both ports; the description-resolution decision and the summary-drift decision are critical paths and target close to 100%. PowerShell (Pester `CodeCoverage`, run locally): **92.92%**, well above the gate. Bash (`tests/coverage/bash-coverage.sh`): kcov structurally cannot instrument a bash ≥ 4 target on macOS (`--mode full`/`--mode conformance` refuse to run here by design — see the script's own guard) — this side of the gate only runs meaningfully on the Linux "Bash coverage" CI job, which memory already records as red on `main` since 2026-07-28 for an unrelated timeout reason predating this feature; deferred to CI verification alongside T066, not fabricated locally.
- [X] T065 Walk `quickstart.md` end to end, including Scenario 4 (a Jira link in a human's prose must not block the run). Confirmed: the pointer test at `test_us7_plan_apply.bats:47` passes in its post-fix (inverted) form; the inner loop, Scenario 1-3 conformance scenarios, and cross-port equivalence are all covered by the clean full-suite/conformance runs above; Scenario 4 reconfirmed directly via `test_privacy_block.bats` (18/18, including the three dedicated R4 cases). Windows and Dogfooding sections deferred to T066/T067 (require explicit user confirmation before pushing/using real credentials).
- [X] T066 Push to `ci/windows-probe` and read the resulting check-run annotations; diff them against `main`'s, since `main` is already red on `windows-latest` and the baseline is not green. One retry maximum on a flake, then hand the result back. Pushed `a718729` (run 31046919016): 2/4 shards green, 2/4 red — but the only failures are `us1-field-defaults-idempotent`, `us2-field-defaults-question`, `us2-field-defaults-option-question` (byte-identical CRLF divergences at the same offsets as a prior, unrelated push to this same shared branch), all pre-existing feature 011/015 scenarios with no connection to this feature's scope. Every one of 018's own six scenarios (`us1-plan-added-not-replaced`, `us2-preserve-human-prefix`, `us3-summary-rename-withheld`, `us3-summary-rename-proceed`, `us4-migration-clean`, `us4-migration-ambiguous`) is absent from both failure lists — clean on every shard that ran it. Matches the documented `main`-is-already-red-on-`windows-latest` baseline; not a regression this feature introduced, so no retry was needed.
- [ ] T067 Dogfood against a real Jira instance: `/speckit.specify` → type two paragraphs into the Epic in Jira → `/speckit.plan` → `/speckit.tasks`, asserting the paragraphs survive, exactly one implementation-plan section exists, and nothing was renamed. Anonymise every field, option, and project name before any of it reaches a spec or a fixture.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup — **blocks every user story**
- **User Story 2 (Phase 3)**: depends on Phase 2
- **User Story 1 (Phase 4)**: depends on Phase 3 — see the exception below
- **User Story 3 (Phase 5)**: depends on Phase 2 only; can run in parallel with Phases 3 and 4
- **User Story 4 (Phase 6)**: depends on Phase 2 and Phase 3
- **Polish (Phase 7)**: depends on every story being complete

### Two honest exceptions to story independence

- **User Story 1 is not independent of User Story 2.** Research R2 found that the plan section already
  renders last inside the parent's managed nodes, so what US1 actually asks for — the plan landing as an
  *addition* — is delivered by US2's boundary. US1 keeps its P1 slot because it is the operator's explicit
  request and its behaviours need their own pins, but it cannot be built first.
- **User Story 4's split is foundational, not P3 work.** Research R3 found that shipping US2 without the
  suffix-match migration would treat every pre-release description as human prose and duplicate the
  mirror's own output on every ticket of an existing estate. T008–T011 therefore sit in Phase 2. What
  remains in Phase 6 is the reporting and the upgrade proof, which genuinely are P3.

### Within Each User Story

- Every test task precedes its implementation task, and must be observed failing (Constitution XIII)
- Engine before sink; sink before command; command before conformance
- Both ports before the conformance scenario that proves they agree

### Parallel Opportunities

- T002 and T003 (different mock configs)
- T004/T005, T008/T009, T012/T013, T016/T017 — each pair is one test per port, different files
- T020–T023 and T068–T071 — test files only, one per port per concern
- T030/T031, T036–T041, T052/T053 — same pattern
- T042–T045 — four different modules across two ports
- **Phase 5 (US3) can run entirely in parallel with Phases 3 and 4** if staffed, up to T046/T048, which
  touch files Phase 3 also edits
- T058–T061 — four different documents

### Sequential by necessity

Pairs that touch the same file cannot be parallelised: T006→T010 and T007→T011 (`managed_section`),
T026→T072→T048→T054 (`plan_apply.sh`), T027→T073→T049→T055 (`PlanApply.psm1`), T024→T046
(`reconcile.sh`), T025→T047 (`Reconcile.psm1`).

Note that T068–T073 are appended IDs placed inside Phase 3 rather than renumbered into sequence, so the
IDs in that phase do not read monotonically; the phase headings carry the ordering, not the numbers.

---

## Parallel Example: Phase 2 Foundational

```bash
# The four test pairs, all different files — write and run them together:
Task: "T004 marker_count tests in tests/bash/engine/test_managed_panel.bats"
Task: "T005 marker count tests in tests/powershell/engine/ManagedPanel.Tests.ps1"
Task: "T008 suffix-split tests in tests/bash/engine/test_managed_migration.bats"
Task: "T009 suffix-split tests in tests/powershell/engine/ManagedMigration.Tests.ps1"
Task: "T012 resolution tests in tests/bash/sink/test_adf.bats"
Task: "T013 resolution tests in tests/powershell/sink/Adf.Tests.ps1"
Task: "T016 privacy-scope tests in tests/bash/sink/test_privacy_block.bats"
Task: "T017 privacy-scope tests in tests/powershell/sink/PrivacyGuard.Block.Tests.ps1"

# Observe every one of them fail, then implement in pairs.
```

---

## Implementation Strategy

### MVP first (User Story 2 only)

1. Phase 1 Setup
2. Phase 2 Foundational — **critical, blocks everything**
3. Phase 3 User Story 2
4. **Stop and validate**: a human can annotate any mirrored ticket and the annotation survives a full
   lifecycle. This alone closes the reported defect's surviving half.
5. Demo against the Jira double

Note that the MVP here is **User Story 2, not User Story 1**, despite both being P1 — for the reason stated
under the exceptions above. US1 is one phase behind it and adds almost no code.

### Incremental delivery

1. Setup + Foundational → the boundary exists and is safe to write through
2. + US2 → human text survives (MVP)
3. + US1 → the plan is demonstrably an addition, with its own conformance proof
4. + US3 → a rename is kept and named
5. + US4 → an existing estate can upgrade
6. Polish → docs, CHANGELOG, three-OS gate, dogfood

### Parallel team strategy

- Everyone on Phase 2 first; it blocks all four stories
- Then: developer A takes US2 → US1 → US4 (they share `plan_apply.sh` and must serialise on it), while
  developer B takes US3 up to T046, where it meets A's files

---

## Notes

- Tests are not optional here. Constitution XIII makes Red-Green-Refactor a merge gate, and T020 — the
  inverted assertion that currently encodes the defect as correct behaviour — is the reproduction the whole
  feature is judged against.
- One spec-level decision from `plan.md`'s Complexity Tracking is settled in the spec as FR-020a/FR-020b
  (research R3) and one as FR-024/FR-024a (research R4). Both are load-bearing from **Phase 2 onward** —
  T010/T011 build the preserve-and-warn branch and T014/T015 assert contract §3 row 4 — not from Phase 6.
- Conformance success is silent: exit 0 and zero `conformance divergence` lines. Temporary-path noise is
  the harness, not a failure.
- Use `tests/run-bash.sh`, not bare `bats -r tests/bash` — the latter is serial and ~15 minutes. If you do
  use raw `bats`, the `-r` is load-bearing: without it bats silently runs nothing and reports success.
- Commit after each task or logical pair; stop at any checkpoint to validate a story on its own.

---

## Phase 8: Convergence

**Purpose**: Close the gap between the two contracts' "the scenarios that must exist" tables and the
scenarios the corpus actually carries. Every behaviour below is already implemented and unit-tested in both
ports; what is missing is the *shared* cross-port proof Constitution VI and FR-027 require. The bash suite
(1556/1556) and `ci-conformance.sh` (exit 0, zero divergence) are green as of this convergence pass.

- [X] T074 [P] Add a task-tier conformance scenario proving the boundary and the summary record on
      `role:"task"` sub-tasks — no 018 scenario seeds one today (`preserve-human-prefix.json` seeds a parent
      and a story, `preserve-pre-release.json` a parent and three stories, us3's inline mock a parent and a
      story), so the sub-task tier's prefix preservation and summary-drift decision are proven only by
      per-port unit tests. Compose it from the existing `tests/conformance/fixtures/repo-with-task-tier`
      fixture plus a mock config seeding a sub-task with a human prefix above the delimiter and a diverging
      recorded summary, in `tests/conformance/scenarios/` and
      `tests/conformance/mock-jira/configs/` per FR-006, FR-027, SC-008, contracts/managed-description.md §7
      row 1 and contracts/summary-record.md §5/§6 row 8. Added `<!-- speckit-jira -->` binding markers to the
      fixture's spec.md/tasks.md (previously unbound), `configs/preserve-task-tier.json`, and
      `scenarios/sc008-task-tier-boundary.json` — verified byte-identical across ports via `run-scenario.sh`
      (a fixed `SPEC_KIT_JIRA_ID_SOURCE` was required for T001's still-unbound task marker to be
      deterministic).
- [X] T075 [P] Add the oversized-description conformance scenario — the `ifFieldPresent` fault primitive was
      built into **both** harness halves for exactly this row (`tests/conformance/mock-jira/mock-server.ps1`
      and `tests/conformance/mock-jira/curl-shim.sh`, both annotated "018, T069, FR-011") but no config or
      scenario uses it; the refusal is proven only in `tests/bash/sink/test_preserve_boundary.bats` and
      `tests/powershell/sink/PreserveBoundary.Tests.ps1`. Assert one warning naming the ticket key, no
      description written, every other field of that ticket written, nothing truncated, and the host exit
      code unaffected, in `tests/conformance/scenarios/` per FR-011 and
      contracts/managed-description.md §2/§7 row 12. Added
      `configs/preserve-oversized-description.json` (a fault on `PRSV-2` reusing
      `preserve-human-prefix`'s seed) and `scenarios/sc008-oversized-description-refused.json` — confirmed
      two PUTs to PRSV-2 (rejected, then retried without `description`), the warning lands on stderr (not
      the JSON `warnings` channel), summary/labels/priority still write, and the run is byte-identical
      across ports.
- [X] T076 [P] Add the two-delimiter conformance scenario — seed a description carrying two marker-bearing
      nodes and assert the description write is skipped for that ticket, one warning names the ticket key,
      and every other field still reconciles, byte-identically across ports, in
      `tests/conformance/scenarios/` and `tests/conformance/mock-jira/configs/` per FR-012 and
      contracts/managed-description.md §3 row 1 / §7 row 9. Added `configs/preserve-two-delimiters.json`
      (PRSV-1 well-formed, PRSV-2 with two marker nodes) and `scenarios/sc008-two-delimiters-refused.json` —
      confirmed PRSV-2's `description` key is absent from the payload entirely, one JSON `warnings` entry
      names PRSV-2, summary/labels/priority still write on PRSV-2, PRSV-1 reconciles normally in the same
      run, and the run is byte-identical across ports.
- [X] T077 [P] Add the privacy-narrowing conformance proof, both halves — an `*.atlassian.net` link seeded
      **only** in a preserved human prefix must not block the run, and the same host composed into the
      managed region must still refuse with the existing exit code and zero writes. Neither half is in the
      corpus today: the sole `reconcile`-path evidence is `tests/bash/sink/test_privacy_block.bats` and its
      Pester twin, and `tests/conformance/scenarios/us11-block-tier.json` runs `config`, not `reconcile` —
      its own description records that it "runs as a benign config read". This is the cross-port safety
      proof for the feature's one deliberate narrowing of a security control, in
      `tests/conformance/scenarios/` per FR-024, FR-024a, contracts/managed-description.md §5/§7 rows 10–11
      and plan.md's Complexity Tracking (research R4). Added `scenarios/sc008-privacy-prefix-allowed.json`
      (reuses `repo-with-preserve-prefix-spec`, an atlassian.net link only in PRSV-2's prefix — exit 0,
      normal writes) and a new fixture `repo-with-privacy-narrowing-managed` + `configs/preserve-privacy-composed-blocked.json`
      + `scenarios/sc008-privacy-composed-blocked.json` (the atlassian.net host lives in the story text
      itself, so the mirror composes it into the managed region — exit 9, zero write calls, the existing
      BLOCK stderr message). Both confirmed byte-identical across ports.
- [X] T078 [P] Add the deleted-managed-region conformance scenario — seed a ticket whose delimiter is
      present with nothing below it and assert the managed region is restored in full while the human
      prefix above it is preserved byte-for-byte, in `tests/conformance/scenarios/` and
      `tests/conformance/mock-jira/configs/` per FR-008 and contracts/managed-description.md §7 row 5.
      Added `configs/preserve-deleted-managed-region.json` (PRSV-1/PRSV-2 with the delimiter as the last
      content node) and `scenarios/sc008-deleted-managed-region-restored.json` — confirmed the prefix node
      survives unchanged at index 0, the full managed region is rendered back below the delimiter, and the
      run is byte-identical across ports.
- [X] T079 [P] Add the summary-record edge conformance scenario covering the four uncovered rows of
      contracts/summary-record.md §6 — a specification retitle whose record matches the current summary
      updates silently with no warning (FR-017); a human rename to exactly the specification's title
      produces no write and no warning; a divergence that is whitespace-only never warns (§3
      normalisation); a settled ticket writes zero fields **and** zero entity properties (FR-019). All four
      are statically seedable in one mock config, in `tests/conformance/scenarios/` and
      `tests/conformance/mock-jira/configs/` per FR-017, FR-019 and contracts/summary-record.md §3/§6 rows
      2, 5, 6, 7. Added a new fixture `repo-with-summary-record-edges` (a parent + three stories, seeded via
      a priming run so each story's description is already exactly what the mirror renders — isolating
      `summary` as the only field under test) and `scenarios/sc008-summary-record-edges.json`, covering rows
      2 (record equals current, silent retitle), the exact-match row (current already equals the
      specification's title though the record is stale — never treated as drift, resent unchanged, no
      warning), and the whitespace-only row (§3 normalisation, silent retitle) — zero warnings, byte-identical
      across ports. Row 7 (a fully settled ticket writes zero fields **and** zero entity properties, FR-019)
      is not a new scenario: it is already proven, cross-port, by `us2-preserve-human-prefix.json`'s existing
      second run — its accumulated `calls.log` shows two `GET`s and **no** `PUT`s at all on that run,
      including the identity-property write, which is exactly FR-019's guarantee. Traced (not built new)
      because seeding a story whose desired `priority`/`labels` provably equal its current ones is
      orthogonal to this feature: `recognition.sh`'s `current` object (used for the zero-churn comparison)
      never carries `priority`, a pre-existing shape unrelated to 018, so a single-run "already exactly
      matching" fixture for THIS field cannot by itself prove zero HTTP writes — only a second, genuinely
      settled run can, which the existing scenario already supplies.
- [X] T080 Obtain the Bash port's statement-coverage figure, or record an explicit waiver. T064 measured
      PowerShell at 92.92% but left the Bash side — the plan's own stated *primary* coverage gate —
      unmeasured: kcov structurally cannot instrument a Bash ≥ 4 target on macOS, and the Linux
      "Bash coverage" CI job has been red on `main` since 2026-07-28 for an unrelated timeout, so the 80%
      floor is unverified on the primary port for this feature. Either read the figure from a CI run on
      this branch, or state in the PR description why the gate cannot report and what compensates for it,
      per Constitution XIII and plan.md's Technical Context "Testing". **Explicit waiver, no fresh figure
      obtained**: confirmed locally (`tests/coverage/bash-coverage.sh`'s own `require_kcov()`, lines
      443-463) that kcov cannot drive a non-Apple Bash on this macOS host — "Failed to exchange stderr for
      pipe" — and Apple's shipped `/bin/bash` is 3.2, below the project's Bash ≥ 4 floor, so no local kcov
      run is possible on this branch at all. Confirmed via `gh run view` / `gh api .../check-runs/.../
      annotations` on the latest `gates.yml` run on `main` (run 31006298069, check-run 92307053925) that
      the "Bash coverage >= 80%" job fails there too, independently of this branch, with "The action
      'Measure statement coverage with kcov' has timed out after 15 minutes" — matching the pre-existing
      memory record dated since 2026-07-28. A `--mode bats` local traceability-only run (the script's own
      suggested fallback for "measure only what runs anywhere") was attempted as compensating evidence but
      did not produce output before the process ended, so no partial local figure is available either.
      Compensating evidence instead: T064's PowerShell run (identical logic, both ports built and tested
      together against the shared conformance corpus per Constitution VI) measured 92.92%, and all 190s of
      `tests/run-bash.sh` plus the full conformance corpus (Phase 8, T074-T079) pass on this branch. The
      80% floor is asserted, not measured, for the Bash port on this branch — reviewers should treat CI's
      red gate on `main` itself as pre-existing infrastructure debt, not a regression introduced by 018.

**Note on the two documented deviations, left as-is**: contracts/managed-description.md §7's
"plan changed, then deleted" row is already resolved at the `plan_apply` unit level with a written
rationale (T035 — `run-scenario.sh`'s `runs[]` share one workdir and mock with no per-run file-mutation
primitive, following the precedent `us5-plan-on-parent.json` set for the identical concern), and §7's
"prefix edited, nothing else" row is covered in substance by `us2-preserve-human-prefix.json`'s second run,
which settles to zero writes with a human prefix present. Neither is re-opened here.
