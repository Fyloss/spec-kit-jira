---

description: "Task list for feature implementation"
---

# Tasks: Reconcile Recognises the Tickets It Already Created

**Input**: Design documents from `/specs/005-fix-reconcile-idempotency/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: REQUIRED, not optional. Constitution XIII mandates strict Red-Green-Refactor and states that no implementation task may be planned without its test task preceding it. The repository's bug-fix policy additionally requires a test that reproduces the defect *before* the fix. Every implementation task below is preceded by the test task that must be observed failing first.

**Ports**: Constitution VI requires the Bash and PowerShell implementations to change together. A task that names two files changes both in one commit; splitting them across commits breaks the portability gate.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Exact file paths are given in every task

## Path Conventions

Script-native extension, no build step. `scripts/bash/` and `scripts/powershell/` hold the two ports; `tests/bash/`, `tests/powershell/`, `tests/conformance/`, `tests/live/` hold the four suites.

---

## Phase 1: Setup — Make the Defect Observable

**Purpose**: The mocked Jira double is write-only, stateless, and returns a fixed issue key for every creation, which is why duplicate creation is currently invisible to the test suite. Nothing about this feature is testable until the double can express "the ticket exists now". Phase 1 ends with the defect reproduced and red.

- [X] T001 Return a distinct, sequential issue key from each `POST /rest/api/3/issue` instead of the fixed `issue-created.json` key, in `tests/conformance/mock-jira/mock-server.ps1`
- [X] T002 Store each created issue's fields in per-process state and serve `GET /rest/api/3/issue/{key}`, returning `404` for an unknown key, in `tests/conformance/mock-jira/mock-server.ps1` (depends on T001)
- [X] T003 Serve the `?properties=spec-kit-jira` query parameter on the issue GET and accept `PUT /rest/api/3/issue/{key}/properties/{propertyKey}` into the same state, in `tests/conformance/mock-jira/mock-server.ps1` (depends on T002)
- [X] T004 Apply `PUT /rest/api/3/issue/{key}` to the stored fields so a later GET reflects the update, in `tests/conformance/mock-jira/mock-server.ps1` (depends on T002)
- [X] T005 [P] Expose state reset and per-issue seeding to both drivers in `tests/conformance/mock-jira/lib.sh` and `tests/conformance/mock-jira/Mock.psm1`
- [X] T006 [P] Add the conformance fixture `tests/conformance/fixtures/repo-with-mirrored-spec/` — a multi-story `spec.md` with no markers yet, plus `.specify/jira/config.yml` and `config.local.yml` routing to a bound project
- [X] T007 Write the failing regression test required by the bug-fix policy — reconcile the fixture twice and assert two `POST /rest/api/3/issue` calls and `created: 1` on the second run — in `tests/bash/commands/test_reconcile_idempotent.bats` and `tests/powershell/commands/Reconcile.Idempotent.Tests.ps1` (depends on T001–T006)

**Checkpoint**: the reported defect is reproduced by an automated test on both ports, matching quickstart Step 1. Do not proceed until it is red for the documented reason.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The durable identifier, its marker line, and its place in the identity marker. Every user story depends on all of it.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T008 Write failing tests for identifier generation — shape `^[0-9a-f]{16}$`, uniqueness across calls, and the `SPEC_KIT_JIRA_ID_SOURCE` seam yielding a fixed sequence — in `tests/bash/engine/test_story_marker.bats` and `tests/powershell/engine/StoryMarker.Tests.ps1`
- [X] T009 Implement identifier generation and the `SPEC_KIT_JIRA_ID_SOURCE` seam per research R4 in the new `scripts/bash/engine/story_marker.sh` and `scripts/powershell/engine/StoryMarker.psm1` (depends on T008)
- [X] T010 Write failing tests for the marker grammar — the three valid forms (`story=`, `story=`+`creating`, `story=`+`ticket=`), the three ignored forms, and the three malformed forms, including two marker lines in one story section, of [contracts/story-marker.md](./contracts/story-marker.md) — in `tests/bash/engine/test_story_marker.bats` and `tests/powershell/engine/StoryMarker.Tests.ps1`
- [X] T011 Implement marker formatting and recognition of the grammar in `scripts/bash/engine/story_marker.sh` and `scripts/powershell/engine/StoryMarker.psm1` (depends on T010)
- [X] T012 Write failing tests for the byte-preserving splice — insert after a story heading, insert after the H1 for the implicit story, replace in place, the two state transitions (`story=<id>` → `creating`, `creating` → `ticket=<KEY>`), preserve every other byte, adopt the file's dominant line ending, and **do not open the file for writing when nothing changes** — in `tests/bash/engine/test_story_marker.bats` and `tests/powershell/engine/StoryMarker.Tests.ps1`
- [X] T013 Implement the splice, reusing `managed_section_line_ending` and writing through a temporary file renamed over the original, in `scripts/bash/engine/story_marker.sh` and `scripts/powershell/engine/StoryMarker.psm1` (depends on T012)
- [X] T014 Write failing tests proving the marker line is excluded from `parse_title`, `parse_description_blocks`, `parse_acceptance_criteria`, `parse_design`, `parse_priority`, and `parse_estimation`, and that `stories[].local_id` carries the marker's identifier or is empty when absent, in `tests/bash/engine/test_parse_marker.bats` and `tests/powershell/engine/Parse.Marker.Tests.ps1`
- [X] T015 Implement marker-aware parsing in `scripts/bash/engine/parse.sh` and `scripts/powershell/engine/Parse.psm1` (depends on T014)
- [X] T016 [P] Write failing tests for the identity marker gaining `story` and staying byte-identical across ports, in `tests/bash/sink/test_identity.bats` and `tests/powershell/sink/Identity.Tests.ps1`
- [X] T017 Add `story` to the marker built by `identity_marker` in `scripts/bash/sink/jira/identity.sh` and `scripts/powershell/sink/jira/Identity.psm1` (depends on T016)
- [X] T018 Update every fixture, scenario, and assertion that pins a positional `local_id` (`s1`, `s2`, …) to the durable identifier under `SPEC_KIT_JIRA_ID_SOURCE`, across `tests/bash/`, `tests/powershell/`, and `tests/conformance/scenarios/` (depends on T015)

**Checkpoint**: identifiers can be generated, written into a specification without disturbing a byte around them, read back, and stamped into a marker. No Jira behaviour has changed yet.

---

## Phase 3: User Story 1 — A Second Run Creates No Duplicates (Priority: P1) 🎯 MVP

**Goal**: Reconcile recognises the tickets it created and updates them instead of duplicating them.

**Independent Test**: Reconcile a three-story specification, then reconcile it again unchanged; the project holds three tickets, not six, and the second run reports `created: 0` (quickstart Steps 2, 3, 5).

### Tests for User Story 1 ⚠️

> Write these first and observe them fail.

- [X] T019 [P] [US1] Write failing tests for the marker verification decision table — bound, `marker-mismatch`, `orphan` (stamped identifier matching no story of the specification), `claimed-by-other`, `duplicate-claim` on two stories, `duplicate-claim` on two keys, and a ticket with no marker never adopted — per [contracts/recognition-contract.md](./contracts/recognition-contract.md), in `tests/bash/sink/test_recognition.bats` and `tests/powershell/sink/Recognition.Tests.ps1`
- [X] T020 [P] [US1] Write failing tests for the recognition fault matrix — `401`→exit 3, exhausted `429`→exit 2, network drop→exit 2, `404`→ticket re-created with a notice — each asserting **zero** creation POSTs, in `tests/bash/sink/test_recognition.bats` and `tests/powershell/sink/Recognition.Tests.ps1`
- [X] T021 [P] [US1] Write failing tests for the run sequence — a ticket is never created for a story whose identifier is unrecorded, and an unwritable `spec.md` exits 4 with zero writes — in `tests/bash/commands/test_reconcile_idempotent.bats` and `tests/powershell/commands/Reconcile.Idempotent.Tests.ps1`
- [X] T022 [P] [US1] Write failing tests for the `key-unrecorded` fail-closed window of research R8 — a story carrying a plain `story=<id>` with no key is **created normally**, a story carrying `creating` is **blocked** with its siblings still reconciling and the exit code 0, and a run that fails the privacy guard after assignment leaves every story creatable by the next run — in `tests/bash/commands/test_reconcile_idempotent.bats` and `tests/powershell/commands/Reconcile.Idempotent.Tests.ps1`
- [X] T023 [P] [US1] Write the failing conformance scenario `tests/conformance/scenarios/us1-recognition-second-run.json` — two runs against the mock, asserting one creation, identical `spec.md` bytes on both ports, and the exact Jira call sequence
- [X] T024 [P] [US1] Write the failing conformance scenario `tests/conformance/scenarios/us1-recognition-reorder.json` — reorder and retitle stories between runs, asserting `created: 0` and that each ticket still holds the content of the story whose marker names it

### Implementation for User Story 1

- [X] T025 [US1] Implement the recognition read — one `GET /rest/api/3/issue/{key}?properties=spec-kit-jira&fields=…` per recorded key — in the new `scripts/bash/sink/jira/recognition.sh` and `scripts/powershell/sink/jira/Recognition.psm1` (depends on T019, T020)
- [X] T026 [US1] Implement marker verification and the `{bound, new, blocked}` result shape of [data-model.md](./data-model.md) in `scripts/bash/sink/jira/recognition.sh` and `scripts/powershell/sink/jira/Recognition.psm1` (depends on T025)
- [X] T027 [US1] Map every read failure to its documented exit code with zero writes, never downgrading an inconclusive read to "no ticket exists", in `scripts/bash/sink/jira/recognition.sh` and `scripts/powershell/sink/jira/Recognition.psm1` (depends on T025)
- [X] T028 [US1] Sequence assign → recognise → plan → record in `cmd_reconcile` in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1`, writing identifiers into `spec.md` before any Jira write per research R5 (depends on T013, T026)
- [X] T029 [US1] Populate the plan context's `tickets`, `ticket_origins`, and `ticket_descriptions` from the recognition result, keeping `SPEC_KIT_JIRA_PLAN_CONTEXT` as a wholesale override, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T028)
- [X] T030 [US1] Exclude blocked stories from the document handed to `plan_writes` and emit one warning each from the diagnostics catalogue, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T026)
- [X] T031 [US1] Mark every planned creation `creating` in `spec.md` after the privacy guard and before the first create, then stamp the identity marker on each created ticket and replace its `creating` with the recorded key, per created ticket rather than batched, in `scripts/bash/sink/jira/plan_apply.sh`, `scripts/powershell/sink/jira/PlanApply.psm1`, `scripts/bash/commands/reconcile.sh`, and `scripts/powershell/commands/Reconcile.psm1` (depends on T028)
- [X] T032 [US1] Confirm the Phase 1 regression test T007 now passes — two runs, one creation — and record the before/after call counts in the task notes

**Checkpoint**: the reported defect is fixed. Re-running any lifecycle command no longer duplicates tickets, on both ports.

---

## Phase 4: User Story 2 — An Unchanged Re-run Writes Nothing At All (Priority: P2)

**Goal**: Recognition is not enough — a re-run over an unchanged corpus must issue no write of any kind, and must leave `spec.md` byte-identical.

**Independent Test**: Reconcile twice with no change; the second run reports `created: 0, updated: 0`, the call log holds no POST or PUT, and `cmp` on `spec.md` succeeds (quickstart Steps 3, 4).

### Tests for User Story 2 ⚠️

- [X] T033 [P] [US2] Write failing tests asserting an unchanged re-run issues zero POST and zero PUT requests and reports `skipped` equal to the story count, in `tests/bash/commands/test_reconcile_zero_churn.bats` and `tests/powershell/commands/Reconcile.ZeroChurn.Tests.ps1`
- [X] T034 [P] [US2] Write failing tests asserting a change to one story out of several produces exactly one PUT, naming that story's ticket, in `tests/bash/commands/test_reconcile_zero_churn.bats` and `tests/powershell/commands/Reconcile.ZeroChurn.Tests.ps1`
- [X] T035 [P] [US2] Write failing tests asserting a human-origin ticket's churn is computed on the managed section alone and its prose above the panel is never rewritten, in `tests/bash/commands/test_reconcile_zero_churn.bats` and `tests/powershell/commands/Reconcile.ZeroChurn.Tests.ps1`
- [X] T036 [P] [US2] Write failing tests asserting `spec.md` is byte-identical after an unchanged re-run and that `--dry-run` writes neither Jira nor `spec.md`, in `tests/bash/commands/test_reconcile_zero_churn.bats` and `tests/powershell/commands/Reconcile.ZeroChurn.Tests.ps1`
- [X] T037 [P] [US2] Write the failing conformance scenario `tests/conformance/scenarios/us2-zero-churn-unchanged.json` — a second run with an empty write set and identical `spec.md` bytes on both ports

### Implementation for User Story 2

- [X] T038 [US2] Build the lifecycle context from the recognition result — `current` fields and `origin` per ticket — and pass it to `plan_lifecycle` on every run, keeping `SPEC_KIT_JIRA_LIFECYCLE` as an override, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T026)
- [X] T039 [US2] Count dropped no-op writes into `counts.skipped`, replacing the hard-coded `0`, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T038)
- [X] T040 [US2] Guard the `spec.md` write behind the dry-run flag so a dry run predicts identifiers without assigning them, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T028)

**Checkpoint**: an unchanged re-run is a no-op end to end — no Jira write, no file write, and a summary that says so.

---

## Phase 5: User Story 3 — Recognition Survives a Rename, a Fresh Clone, and a Colleague (Priority: P3)

**Goal**: Recognition depends on nothing machine-local.

**Independent Test**: Mirror a specification, commit it, reconcile from a clone that never ran the bridge, and assert `created: 0` (quickstart Step 6).

### Tests for User Story 3 ⚠️

- [X] T041 [P] [US3] Write failing tests asserting recognition succeeds with no local run history — no state file, empty cache directories — in `tests/bash/commands/test_reconcile_durability.bats` and `tests/powershell/commands/Reconcile.Durability.Tests.ps1`
- [X] T042 [P] [US3] Write failing tests asserting a renamed specification folder still recognises its tickets and creates none, in `tests/bash/commands/test_reconcile_durability.bats` and `tests/powershell/commands/Reconcile.Durability.Tests.ps1`
- [X] T043 [P] [US3] Write failing tests asserting recognition is scoped to the routed project, so two specifications mirrored into different projects never recognise each other's tickets, and that a story whose recorded ticket lives outside the routed project is mirrored into the routed project rather than blocked, in `tests/bash/sink/test_recognition.bats` and `tests/powershell/sink/Recognition.Tests.ps1`

### Implementation for User Story 3

- [X] T044 [US3] Treat a recorded ticket whose project differs from the routed project as `new` — create in the routed project, re-record the key, emit the `re-routed` notice from the diagnostics catalogue, and leave the former ticket untouched — in `scripts/bash/sink/jira/recognition.sh` and `scripts/powershell/sink/jira/Recognition.psm1` (depends on T043)
- [X] T045 [US3] Confirm no code path introduced by this feature reads or writes machine-local state, and record the audit in the task notes (depends on T041, T042)

**Checkpoint**: the fix works for every clone and every colleague, not only the machine that first mirrored.

---

## Phase 6: User Story 4 — Recognition Feeds the Safety Rules (Priority: P3)

**Goal**: Now that reconcile updates real tickets, the drift, Flagged, and blocker rules stop being inert — while no ticket's status is ever moved (research R9).

**Independent Test**: Advance a mirrored ticket in Jira, re-run, and assert a named drift warning identifying the ticket, no silent regression, and zero transition requests (quickstart Step 9).

### Tests for User Story 4 ⚠️

- [X] T046 [P] [US4] Seed per-issue `status`, `statusCategory`, the Flagged field, and `issuelinks` in the mock, in `tests/conformance/mock-jira/mock-server.ps1`, `tests/conformance/mock-jira/lib.sh`, and `tests/conformance/mock-jira/Mock.psm1`
- [X] T047 [P] [US4] Write failing tests asserting a ticket advanced beyond the event's phase raises a named drift warning and has its content write suppressed where the drift rule says so, in `tests/bash/commands/test_reconcile_lifecycle.bats` and `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [X] T048 [P] [US4] Write failing tests asserting a Flagged ticket has its transition withheld, the flag surfaced, and no flag write emitted, in `tests/bash/commands/test_reconcile_lifecycle.bats` and `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [X] T049 [P] [US4] Write failing tests asserting **zero** `POST /rest/api/3/issue/{key}/transitions` calls in every scenario, pinning research R9's scope boundary, in `tests/bash/commands/test_reconcile_lifecycle.bats` and `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [X] T050 [P] [US4] Write failing tests asserting that under `SPEC_KIT_JIRA_HOOK_CONTEXT` every recognition failure exits 0 with exactly one WARNING on stderr, in `tests/bash/commands/test_reconcile_lifecycle.bats` and `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`

### Implementation for User Story 4

- [X] T051 [US4] Derive the `target` status from the lifecycle event through the existing phase→status map and `config_phase_status_targets`, leaving `transition_id` unset, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T047, T049)
- [X] T052 [US4] Populate `status`, `category`, `flagged`, and `blockers` per ticket in the lifecycle context from the recognition read, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T051)
- [X] T053 [US4] Confirm the existing `SPEC_KIT_JIRA_HOOK_CONTEXT` downgrade covers every failure recognition can raise, extending it only if a gap is found, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T050)

**Checkpoint**: updates are safe — divergence is reported, never silently overwritten, and nothing transitions.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T054 Write failing tests for the run summary reporting `recognised`, `assigned`, and a populated `skipped`, in both JSON and prose form, in `tests/bash/lib/test_output.bats` and `tests/powershell/lib/Output.Tests.ps1`
- [X] T055 Implement the new summary counts and their prose rendering in `scripts/bash/commands/reconcile.sh`, `scripts/powershell/commands/Reconcile.psm1`, `scripts/bash/lib/output.sh`, and `scripts/powershell/lib/Output.psm1` (depends on T054)
- [X] T056 [P] Write failing tests asserting every diagnostic matches the catalogue wording and contains no site host, token, or account id, including at maximum verbosity, in `tests/bash/sink/test_recognition.bats` and `tests/powershell/sink/Recognition.Tests.ps1`
- [X] T057 [P] Document the marker line, recognition, and the new summary counts in `commands/speckit.jira.reconcile.md`, `README.md`, and `INSTALL.md`
- [X] T058 Add the CHANGELOG entry and version bump in `CHANGELOG.md` and `extension.yml`, stating plainly that tickets created before this release carry no marker and that their specifications will be mirrored afresh once — the one user-visible cost of the fix
- [X] T059 Extend the live double-run assertion to cover recognition, creation, and the unchanged re-run in `tests/live/test_live_zero_churn.bats`, per Constitution II which states mocks are not sufficient
- [ ] T060 Verify against a live instance that a `spec-kit-jira` entity property set through the REST API is not JQL-searchable without an app descriptor, per quickstart Step 11, and record the outcome in [research.md](./research.md) R2 whichever way it falls
- [ ] T061 Confirm the coverage gate — at least 80% statement coverage overall and near-100% on recognition, idempotency, and the fail-closed paths — via `tests/coverage/bash-coverage.sh` and `Invoke-Pester -CI`
- [ ] T062 Run the full conformance suite on all three operating systems and confirm byte-identical stdout, exit codes, Jira call sequences, and resulting `spec.md` bytes, via `tests/conformance/run-scenario.sh` and the CI matrix in `.github/workflows/`
- [ ] T063 Execute [quickstart.md](./quickstart.md) end to end, including the dogfood run against the consuming project that reported the defect, and confirm the backlog does not grow

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately. Its output is a red regression test.
- **Foundational (Phase 2)**: depends on Phase 1 — **blocks every user story**.
- **User Story 1 (Phase 3)**: depends on Phase 2. This is the MVP and the fix for the reported defect.
- **User Story 2 (Phase 4)**: depends on Phase 3 — it refines writes that only exist once recognition does.
- **User Story 3 (Phase 5)**: depends on Phase 3. Independent of US2 and US4.
- **User Story 4 (Phase 6)**: depends on Phase 3, and on T038 from Phase 4 for the lifecycle context it extends.
- **Polish (Phase 7)**: depends on all stories.

### User Story Dependencies

US1 is genuinely independent once Phase 2 lands. US2 and US4 both build on the lifecycle context, so US2's T038 precedes US4's T051–T052. US3 is independent of both and can be developed alongside either.

### Within Each User Story

Tests are written and observed failing before the implementation task that satisfies them — every pair above is ordered that way, and a reviewer should reject any reordering (Constitution XIII).

### Parallel Opportunities

- T005 and T006 in Setup.
- T016 in Foundational, alongside T010–T015 (different files).
- All six test tasks of US1 (T019–T024), all five of US2 (T033–T037), all three of US3 (T041–T043), and all five of US4 (T046–T050) — each set touches distinct files.
- T056 and T057 in Polish.
- US3 can be staffed alongside US2 or US4 by a second developer.

Implementation tasks within a story are mostly **not** parallel: T025–T031 and T038–T040 converge on `reconcile.sh` and `Reconcile.psm1`.

---

## Parallel Example: User Story 1

```bash
# Launch the six failing-test tasks together:
Task: "T019 recognition decision table in tests/bash/sink/test_recognition.bats"
Task: "T020 recognition fault matrix in tests/bash/sink/test_recognition.bats"
Task: "T021 run sequence in tests/bash/commands/test_reconcile_idempotent.bats"
Task: "T022 key-unrecorded window in tests/bash/commands/test_reconcile_idempotent.bats"
Task: "T023 conformance scenario us1-recognition-second-run.json"
Task: "T024 conformance scenario us1-recognition-reorder.json"

# Then implement sequentially — T025 through T031 share reconcile.sh.
```

---

## Implementation Strategy

### MVP First (Phases 1–3)

1. Phase 1 — reproduce the defect; stop when it is red for the documented reason.
2. Phase 2 — the identifier, its marker line, its place in the identity marker.
3. Phase 3 — recognition; T032 turns the Phase 1 test green.
4. **STOP and VALIDATE**: quickstart Steps 1–3 and 5. The reported bug is fixed here.

Shipping after Phase 3 is defensible: duplicates stop. A re-run would still rewrite unchanged tickets, which is noise rather than damage, and Phase 4 removes it.

### Incremental Delivery

Phase 3 (no duplicates) → Phase 4 (no churn) → Phase 5 (durability proven) → Phase 6 (safe updates) → Phase 7 (summary, docs, live gate). Each phase is independently testable and leaves the extension in a shippable state.

### Do Not Ship Without

T058's CHANGELOG note, T059's live double-run, and T063's dogfood run. Constitution II makes the live assertion mandatory rather than advisory, and T058 is the only warning users get that their first upgrade re-mirrors existing specifications.

---

## Notes

- `[P]` marks different files with no dependency on an incomplete task.
- Every task naming two paths changes both ports in one commit (Constitution VI).
- Verify each test fails before implementing; commit after each task or logical pair.
- Total: 63 tasks — Setup 7, Foundational 11, US1 14, US2 8, US3 5, US4 8, Polish 10.
