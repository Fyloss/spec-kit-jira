---
description: "Task list for 022 — A Story Carries Its Task List as a Checklist, Instead of a Sub-Task Each"
---

# Tasks: A Story Carries Its Task List as a Checklist, Instead of a Sub-Task Each

**Input**: Design documents from `/specs/022-story-task-checklist/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/task-mirror-config.md](./contracts/task-mirror-config.md),
[contracts/checklist-rendering.md](./contracts/checklist-rendering.md), [quickstart.md](./quickstart.md)

**Tests**: REQUIRED, not optional. Constitution Principle XIII mandates TDD with ≥80% coverage, and the
project's bug-fix policy requires a test that fails before the change is applied. Every implementation
task below is preceded by the test that must fail first.

**Organization**: Grouped by user story. Two things are genuinely shared and therefore foundational
rather than duplicated per story: the `task_mirror` setting itself (every story reads it) and the split
of feature 012's single task-tier gate into three independent conditions.

**Ordering note — the blocker is lifted**: the ADF node shape is **decided**, and no task waits on a live
instance. [research.md](./research.md) §1 records the measurement: `taskList`/`taskItem` (candidate A) are
undocumented — the ADF node reference 404s, every primary source that tried them over the REST API got
`HTTP 400 INVALID_INPUT`, and official support is an unresolved suggestion (JRACLOUD-85414, *Gathering
Interest*). Candidate B — `bulletList` with a leading ☑/☐ glyph — ships. It uses a node the sink already
emits, and it carries no identity attribute, so this feature's stated main risk (research §2) does not
arise. T001 is therefore an **optional pre-release verification**, not a gate: it can run whenever an
instance exists, and nothing depends on its result.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: `[US1]`..`[US5]`, mapping to the user stories in spec.md
- Exact file paths are given in every task

## Path Conventions

Two native ports, mirrored trees (see plan.md → Project Structure):

- Bash: `scripts/bash/{lib,commands,sink/jira}/` — tests in `tests/bash/{lib,commands,sink}/`
- PowerShell: `scripts/powershell/{lib,commands,sink/jira}/` — tests in
  `tests/powershell/{lib,commands,sink}/`
- Cross-port byte equivalence: `tests/conformance/scenarios/us022-*.json` with fixtures under
  `tests/conformance/fixtures/`
- Live-only assertions: `tests/live/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Build the fixtures every later phase asserts against. The ADF shape is already decided
(research.md §1) — nothing in this phase blocks.

- [ ] T001 [P] *(optional, pre-release)* Write the live zero-churn probe in `tests/live/test_live_checklist_probe.bats`: against a real Jira project, PUT a story description carrying the shipped candidate-B checklist nodes, GET the same issue, and assert the returned `description` is byte-identical after `json_canonical` — the one assertion a mock cannot make, because a mock echoes what it was sent. Run it whenever an instance exists; **no task depends on its result**
- [ ] T002 [P] *(optional, pre-release)* Record T001's result in `specs/022-story-task-checklist/research.md` §2, confirming or refuting that the comparison-only normalisation is a no-op in practice as §1's decision predicts
- [ ] T003 [P] Capture the pre-change baseline in `tests/conformance/scenarios/us022-baseline-no-mode.json`: a full reconcile of an existing fixture with no `task_mirror` recorded, so FR-002's byte-for-byte promise is measured rather than asserted
- [ ] T004 [P] Create the conformance fixture `tests/conformance/fixtures/repo-with-checklist-mode/` — 5 stories, 100 attributed tasks across 3 phases, mixed complete/incomplete, plus one story with zero tasks and two unattributed tasks
- [ ] T005 [P] Create the conformance fixture `tests/conformance/fixtures/repo-with-no-subtask-type/` — a project reporting no sub-task issue type and declaring no `task` role (US5)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The `task_mirror` setting as a hand-editable primitive, and the gate split that lets the task
tier exist without a sub-task type. Every user story depends on both.

**⚠️ CRITICAL**: No user story phase begins until this phase completes.

### Tests (write first, observe failing)

- [X] T006 [P] Add `tests/bash/lib/test_config_task_mirror.bats` asserting the four refusals of contracts/task-mirror-config.md §2 — non-mapping, undeclared project key, invalid value, each with `EXIT_CONFIG` and zero writes and the exact message text
- [X] T007 [P] Add the Pester mirror `tests/powershell/lib/Config.TaskMirror.Tests.ps1` with the same four refusals and identical message text
- [X] T008 [P] Extend `tests/bash/lib/test_config_refusal.bats` with a regression asserting `task_strategy` is still refused as retired after this feature ships (FR-006)
- [X] T009 [P] Extend `tests/powershell/lib/Config.RetiredKeys.Tests.ps1` with the same `task_strategy` regression
- [X] T010 Add to `tests/bash/lib/test_config_task_mirror.bats` the full six-row resolution table of contracts/task-mirror-config.md §7 for `config_task_mirror_for`, including both absent rows
- [X] T011 Add the same six-row resolution table to `tests/powershell/lib/Config.TaskMirror.Tests.ps1`
- [X] T012 [P] Add `tests/bash/commands/test_reconcile_task_mirror_gate.bats` asserting the three split conditions of research.md §6 — `tasks.md` is read in both modes, durable identifiers are assigned in `subtask` mode only, sub-task writes are planned in `subtask` mode only
- [X] T013 [P] Add the Pester mirror `tests/powershell/commands/Reconcile.TaskMirrorGate.Tests.ps1`
- [X] T013a Add to `tests/bash/commands/test_reconcile_task_mirror_gate.bats`: a `tasks.md` absent beside the specification is a silent no-op in **both** modes — no refusal, no warning, no write, and the story's managed region carries no `Tasks` section. The gate split makes the read unconditional on mode, so this path is new and no longer inherited from feature 012 (spec Edge Cases)
- [X] T013b Add the same absent-`tasks.md` assertion to `tests/powershell/commands/Reconcile.TaskMirrorGate.Tests.ps1`

### Implementation

- [X] T014 [P] Add `task_mirror` to the known top-level keys and implement its three validation rules in `scripts/bash/lib/config.sh` (`_cfg_schema_errors`, alongside the existing `field_defaults` rules), leaving the retired-key list untouched
- [X] T015 [P] Mirror the same key and validation rules in `scripts/powershell/lib/Config.psm1`, leaving its retired-key list untouched
- [X] T016 Implement `config_task_mirror_for <project_key> <merged-cfg-json>` in `scripts/bash/lib/config.sh`, returning `subtask`, `checklist` or the empty string, mirroring `config_field_defaults_for`'s placement and return discipline (depends on T014)
- [X] T017 Implement the PowerShell mirror in `scripts/powershell/lib/Config.psm1` with byte-identical output (depends on T015)
- [X] T018 Split the single task-tier gate into three independent conditions in `scripts/bash/commands/reconcile.sh` — read `tasks.md`, assign durable identifiers, plan sub-task writes — per research.md §6's table
- [X] T019 Mirror the gate split in `scripts/powershell/commands/Reconcile.psm1`
- [X] T020 Carry the resolved `task_mirror` value into the plan context in `scripts/bash/commands/reconcile.sh`, beside the existing resolved facts
- [X] T021 Mirror the plan-context addition in `scripts/powershell/commands/Reconcile.psm1`
- [X] T022 [P] Add an assertion to `tests/bash/lib/test_run_state.bats` that editing `task_mirror` in `config.yml` invalidates the run-state short-circuit, so a future refactor of the hashed input set cannot silently break FR-003
- [X] T023 [P] Add the same assertion to `tests/powershell/lib/RunState.Tests.ps1`

**Checkpoint**: a hand-written `task_mirror` in `config.yml` validates, resolves, and gates the tier. User
story phases may now begin.

---

## Phase 3: User Story 1 — A team mirrors a hundred-task feature without creating a hundred tickets (Priority: P1) 🎯 MVP

**Goal**: In checklist mode, each story's ticket carries one checklist section holding exactly its own
tasks, and no issue is created at the task tier.

**Independent Test**: Configure checklist mode by hand against `repo-with-checklist-mode`, reconcile, and
observe zero issues created beyond the specification and story tiers, each story's ticket carrying its own
tasks in `tasks.md` order grouped by phase, and a story with no tasks carrying no section at all.

### Tests for User Story 1 (write first, observe failing)

- [X] T024 [P] [US1] Add `tests/bash/sink/test_adf_checklist.bats` asserting the structure of contracts/checklist-rendering.md §2 — one `Tasks` heading, one group per phase in first-appearance order, entries in document order, the no-phase group leading with no phase paragraph
- [X] T025 [P] [US1] Add the Pester mirror `tests/powershell/sink/Adf.Checklist.Tests.ps1` with byte-identical expected nodes
- [X] T026 [US1] Add to `tests/bash/sink/test_adf_checklist.bats`: a story with zero attributed tasks renders no section at all — no heading, no empty list (FR-021)
- [X] T026a [US1] Add to `tests/bash/sink/test_adf_checklist.bats`: two stories holding tasks whose text is identical each render their own entry under their own story, never shared and never deduplicated across stories (spec Edge Cases, contract §3)
- [X] T027 [US1] Add to `tests/bash/sink/test_adf_checklist.bats`: an entry carries none of `task_ref`, `local_id`, `files`, `depends_on`, `parallel` or the phase text (FR-017, contract §3)
- [X] T028 [US1] Add the T026 and T027 assertions to `tests/powershell/sink/Adf.Checklist.Tests.ps1`
- [X] T029 [US1] Add to `tests/bash/sink/test_adf_checklist.bats`: an entry's text renders the Markdown subset exactly as a sub-task description body does for the same line (FR-023)
- [X] T030 [US1] Add the same Markdown-subset assertion to `tests/powershell/sink/Adf.Checklist.Tests.ps1`
- [X] T030a [US1] Add the T026a identical-text assertion to `tests/powershell/sink/Adf.Checklist.Tests.ps1`
- [X] T031 [P] [US1] Add `tests/bash/sink/test_plan_apply_checklist.bats` asserting that in checklist mode `plan_writes_tasks` plans zero actions and the story's planned description carries the section (FR-007)
- [X] T032 [P] [US1] Add the Pester mirror `tests/powershell/sink/PlanApply.Checklist.Tests.ps1`
- [X] T033 [P] [US1] Add to `tests/bash/commands/test_reconcile_dry_run.bats`: a dry run prints each planned checklist per story with every entry's text and completion state, and writes nothing (FR-037)
- [X] T033a [P] [US1] Add the Pester mirror of T033's per-entry dry-run display to `tests/powershell/commands/Reconcile.DryRun.Tests.ps1` (FR-037)
- [X] T034 [P] [US1] Add to `tests/bash/commands/test_reconcile.bats`: every unattributed task is named individually in the run summary by task identifier with its reason (FR-022)
- [X] T034a [US1] Add to `tests/bash/commands/test_reconcile.bats`: a create-then-update sequence asserts all four counts — `checklists.created` on the first reconcile, `checklists.updated` and `entries.completed` after a task's text and box change, `checklists.unchanged` on a third unchanged run (FR-036, data-model.md §4). Only `unchanged` and `entries.completed` were pinned before
- [X] T034b [P] [US1] Add the T034 and T034a assertions to `tests/powershell/commands/Reconcile.Tests.ps1`
- [X] T035 [US1] Add to `tests/bash/sink/test_plan_apply_checklist.bats`: a rendered description exceeding the sink's ceiling withholds that one story's `description` field, names the story with its remedy, and leaves every other field and every other story writing normally (FR-041)
- [X] T035a [US1] Add to `tests/bash/sink/test_plan_apply_checklist.bats`: a story description carrying human prose above the boundary marker keeps it byte-for-byte when a `Tasks` section is appended below it, and a description carrying two boundary markers omits the `description` field entirely while every other field of that story still writes (FR-020)
- [X] T035b [US1] Add the same two assertions to `tests/powershell/sink/PlanApply.Checklist.Tests.ps1` (depends on T035a)
- [X] T035c [US1] Add the T035 size-ceiling assertion to `tests/powershell/sink/PlanApply.Checklist.Tests.ps1`, so FR-041 is pinned on both ports rather than on bash alone

### Implementation for User Story 1

- [X] T036 [US1] Implement `_adf_checklist_nodes` in `scripts/bash/sink/jira/adf.sh` as candidate B (research §1): the existing `bulletList` renderer, each item's first span being `"☑ "` or `"☐ "`. No node carries an identity attribute — there is nothing for Jira to regenerate and nothing for the comparison to strip
- [X] T037 [US1] Mirror `_adf_checklist_nodes` in `scripts/powershell/sink/jira/Adf.psm1` with byte-identical output (depends on T036)
- [X] T037a [US1] Confirm `.github/workflows/boundary.yml` (Gate #2, `patterns[]`) already covers this feature's nodes: candidate B emits `bulletList` and `listItem`, both listed since 016, so no token is added — record that in the workflow comment beside the 016 entries so the next feature does not re-derive it (FR-024, Constitution VIII)
- [X] T038 [US1] Append the checklist section last in `_adf_content_nodes` and add the fourth positional mode parameter to `adf_render_managed_description` in `scripts/bash/sink/jira/adf.sh`, defaulting to off so every existing call site stays byte-identical (contract §1)
- [X] T039 [US1] Mirror the append and the new parameter in `scripts/powershell/sink/jira/Adf.psm1`
- [X] T040 [US1] Gate `plan_writes_tasks` on the mode and pass the mode through to the renderer in `scripts/bash/sink/jira/plan_apply.sh`
- [X] T041 [US1] Mirror the gating and pass-through in `scripts/powershell/sink/jira/PlanApply.psm1`
- [X] T042 [US1] Implement the FR-041 size-ceiling withholding in `scripts/bash/sink/jira/plan_apply.sh`, reusing `_plan_apply_managed_field`'s existing whole-field drop rather than adding a second way to fail a field (contract §7)
- [X] T043 [US1] Mirror the size-ceiling withholding in `scripts/powershell/sink/jira/PlanApply.psm1`
- [X] T044 [US1] Add the four checklist counts (`checklists.created|updated|unchanged`, `entries.completed`) to the run summary in `scripts/bash/commands/reconcile.sh`, distinct from the specification, story and sub-task tallies (FR-036, data-model.md §4)
- [X] T045 [US1] Mirror the four counts in `scripts/powershell/commands/Reconcile.psm1`
- [X] T046 [US1] Add the per-entry dry-run display to `scripts/bash/commands/reconcile.sh` (FR-037)
- [X] T047 [US1] Mirror the per-entry dry-run display in `scripts/powershell/commands/Reconcile.psm1`

**Checkpoint**: US1 is complete and demonstrable on its own — a hundred tasks, six issues.

---

## Phase 4: User Story 2 — Checking a task off ticks it in Jira (Priority: P1)

**Goal**: An entry's completion state follows `tasks.md` in both directions, a re-run over unchanged
inputs writes nothing, and a human's edit is reported by name before it is overwritten.

**Independent Test**: Reconcile with every box unchecked, check three, reconcile again, and observe
exactly those three entries complete with every other byte of the ticket unchanged.

### Tests for User Story 2 (write first, observe failing)

- [X] T048 [P] [US2] Add to `tests/bash/sink/test_adf_checklist.bats`: `done: true` renders an entry complete and `done: false` renders it incomplete (FR-025)
- [X] T049 [P] [US2] Add the same completion assertions to `tests/powershell/sink/Adf.Checklist.Tests.ps1`
- [X] T050 [US2] Add to `tests/bash/sink/test_adf_checklist.bats`: a task reverting from checked to unchecked renders incomplete again, unlike a sub-task's status (FR-026)
- [X] T051 [US2] Add the reversion assertion to `tests/powershell/sink/Adf.Checklist.Tests.ps1`
- [X] T051a [US2] Add to `tests/bash/sink/test_adf_checklist.bats`: a story mirrored for the first time with every one of its tasks already checked renders the section with every entry complete in one write — a finished story does not arrive in Jira as outstanding work (spec Edge Cases)
- [X] T051b [US2] Add the T051a all-complete assertion to `tests/powershell/sink/Adf.Checklist.Tests.ps1`
- [X] T052 [P] [US2] Add to `tests/bash/commands/test_reconcile_idempotent.bats`: a second reconcile over unchanged inputs in checklist mode issues zero writes of every kind and reports `checklists.unchanged` equal to the story count (FR-030)
- [X] T053 [P] [US2] Add the same zero-write assertion to `tests/powershell/commands/Reconcile.Idempotent.Tests.ps1`
- [X] T054 [US2] Add to `tests/bash/commands/test_reconcile_idempotent.bats`: a `tasks.md` regenerated with every `T0xx` reference renumbered, text and order unchanged, produces zero writes (FR-017)
- [X] T055 [US2] Add the same renumber assertion to `tests/powershell/commands/Reconcile.Idempotent.Tests.ps1`
- [X] T056 [P] [US2] Add to `tests/bash/sink/test_plan_apply_checklist.bats` the full four-row drift decision table of contracts/checklist-rendering.md §6, including the "no record means no warning" row and the "already matches `tasks.md`, not drift" row
- [X] T057 [P] [US2] Add the same four-row drift table to `tests/powershell/sink/PlanApply.Checklist.Tests.ps1`
- [X] T058 [P] [US2] Add to `tests/bash/commands/test_reconcile.bats`: completing every entry of a story's checklist changes no issue's status — not the story's, not the specification's (FR-029)
- [X] T059 [US2] Add to `tests/bash/commands/test_reconcile.bats`: a person's edit in Jira produces the FR-027 warning naming the story **before** the rewrite, and leaves every box in `tasks.md` untouched (FR-028)
- [X] T059a [P] [US2] Add the T058 and T059 assertions to `tests/powershell/commands/Reconcile.Tests.ps1`, so FR-028 and FR-029 are pinned on both ports

### Implementation for User Story 2

- [X] T060 [US2] Implement the comparison-only node-identity normalisation in `scripts/bash/sink/jira/plan_apply.sh` as a **defensive no-op** — candidate B carries no identity attribute, so it strips nothing today — following `_summary_normalise`'s placement and its "for COMPARISON only — never applied to a value recorded or sent" discipline, and wire it into `plan_managed_description_status` (contract §5). It costs one function and is what makes a future return to candidate A a one-file change
- [X] T061 [US2] Mirror the normalisation and its wiring in `scripts/powershell/sink/jira/PlanApply.psm1`
- [X] T062 [US2] Add the `checklist` digest field to the identity stamp in `scripts/bash/sink/jira/identity.sh` and `scripts/bash/sink/jira/plan_apply.sh`, computed with `git hash-object --no-filters` over the canonical normalised checklist nodes (data-model.md §3)
- [X] T063 [US2] Mirror the `checklist` digest in `scripts/powershell/sink/jira/Identity.psm1` and `scripts/powershell/sink/jira/PlanApply.psm1`
- [X] T064 [US2] Implement the four-row drift decision and its warning in `scripts/bash/sink/jira/plan_apply.sh`, warning **then writing** — the deliberate divergence from the summary contract, which FR-026 requires and contract §6 records
- [X] T065 [US2] Mirror the drift decision and warning text in `scripts/powershell/sink/jira/PlanApply.psm1`
- [X] T066 [US2] Add the `entries.completed` tally to the run summary in `scripts/bash/commands/reconcile.sh` and confirm no code path transitions an issue in checklist mode (FR-029)
- [X] T067 [US2] Mirror the tally and the same confirmation in `scripts/powershell/commands/Reconcile.psm1`

**Checkpoint**: US1 + US2 together are the whole of the feature's user-facing value.

---

## Phase 5: User Story 3 — The choice is offered once, and stays editable afterwards (Priority: P2)

**Goal**: The ceremony offers the closed question, records the answer in a managed region, never re-asks
it, and reports the mode as its own effect.

**Independent Test**: Run the configuration command against a fixture project, answer with
`--task-mirror`, observe the region; re-run and observe nothing re-asked and the file byte-for-byte
identical; edit by hand and observe the next reconcile follow it.

### Tests for User Story 3 (write first, observe failing)

- [X] T068 [P] [US3] Add to `tests/bash/lib/test_cli.bats` the two `--task-mirror` usage errors of contracts/task-mirror-config.md §4 — missing value and malformed shape — with exact message text, plus repeatability and last-wins
- [X] T069 [P] [US3] Add the same `--task-mirror` parsing assertions to `tests/powershell/lib/Cli.Tests.ps1`
- [X] T070 [P] [US3] Add `tests/bash/commands/test_config_task_mirror.bats` asserting the five region outcomes of contract §3 — `inert`, `created`, `written`, `unchanged`, `refused` — including that `inert` leaves the file completely untouched
- [X] T071 [P] [US3] Add the Pester mirror `tests/powershell/commands/Config.TaskMirror.Tests.ps1` with the same five outcomes
- [X] T072 [US3] Add to `tests/bash/commands/test_config_task_mirror.bats`: the question is reported when nothing is recorded, is **not** re-asked when a value is recorded, and a re-run rewrites `config.yml` byte-for-byte (FR-008, FR-009)
- [X] T073 [US3] Add the same question/no-re-ask/byte-identical assertions to `tests/powershell/commands/Config.TaskMirror.Tests.ps1`
- [X] T074 [US3] Add to `tests/bash/commands/test_config_task_mirror.bats`: a hand-written entry inside the region that the ceremony did not ask about this run is re-emitted unchanged (FR-010)
- [X] T075 [P] [US3] Add to `tests/bash/commands/test_config_three_effects.bats` the per-project effect line of contract §6 in its three forms — recorded, unchanged, not recorded (FR-013)
- [X] T076 [US3] Add to `tests/bash/commands/test_config_task_mirror.bats` the FR-012 line: `subtask` recorded with no resolvable sub-task type is reported at config time with its remedy
- [X] T077 [US3] Add the T074, T075 and T076 assertions to `tests/powershell/commands/Config.TaskMirror.Tests.ps1`

### Implementation for User Story 3

- [X] T078 [P] [US3] Parse `--task-mirror KEY=<subtask|checklist>` in `scripts/bash/lib/cli.sh` beside `--issue-type` and `--field-default`, accepted by the config command only (contract §4)
- [X] T079 [P] [US3] Mirror the `--task-mirror` parsing in `scripts/powershell/lib/Cli.psm1`
- [X] T080 [US3] Implement `_config_task_mirror_block` and `_config_task_mirror_write` in `scripts/bash/commands/config.sh`, mirroring `_config_field_defaults_block`/`_config_field_defaults_write` and their four outcomes, with the region comment text of contract §3
- [X] T081 [US3] Mirror both functions in `scripts/powershell/commands/Config.psm1`
- [X] T082 [US3] Emit the closed question, the FR-012 line and the per-project effect line in `scripts/bash/commands/config.sh`, in the shape `_config_field_default_notes` already uses (contract §5, §6)
- [X] T083 [US3] Mirror the three report lines in `scripts/powershell/commands/Config.psm1` with identical text
- [X] T084 [US3] Wire the recorded answer through the ceremony's persistence path in `scripts/bash/commands/config.sh` so the region is spliced in the same run that answers it
- [X] T085 [US3] Mirror the persistence wiring in `scripts/powershell/commands/Config.psm1`

**Checkpoint**: the setting is now discoverable, not just hand-editable.

---

## Phase 6: User Story 4 — A team already mirroring sub-tasks is not disturbed, and switching destroys nothing (Priority: P2)

**Goal**: A project with no recorded mode is byte-for-byte unchanged; a switch writes to no sub-task and
reports what it abandoned with an exact query; a switch back re-binds rather than duplicates.

**Independent Test**: Reconcile in sub-task mode, switch to checklist, reconcile again, and observe the
issue count did not fall, no sub-task was written to, and the report names the stories with a
copy-pasteable `issue in (…)` query.

### Tests for User Story 4 (write first, observe failing)

- [X] T086 [P] [US4] Add to `tests/bash/commands/test_reconcile.bats`: a project with no recorded mode produces output byte-for-byte identical to `us022-baseline-no-mode.json` on every surface, the ceremony's question set included (FR-002, SC-008)
- [X] T087 [P] [US4] Add the same baseline-equality assertion to `tests/powershell/commands/Reconcile.Tests.ps1`
- [X] T088 [P] [US4] Add `tests/bash/commands/test_reconcile_mode_switch.bats`: switching to checklist deletes, closes, transitions and updates **no** sub-task — zero write actions of any kind against a task-tier issue (FR-033)
- [X] T089 [P] [US4] Add the Pester mirror `tests/powershell/commands/Reconcile.ModeSwitch.Tests.ps1`
- [X] T090 [US4] Add to `tests/bash/commands/test_reconcile_mode_switch.bats`: the switch report names the stories, the count of abandoned sub-tasks, and an `issue in (KEY-1, KEY-2, …)` query holding exactly the keys recorded in `tasks.md` (FR-034)
- [X] T091 [US4] Add the same switch-report assertion to `tests/powershell/commands/Reconcile.ModeSwitch.Tests.ps1`
- [X] T092 [US4] Add to `tests/bash/commands/test_reconcile_mode_switch.bats`: switching back removes the `Tasks` section from each story's managed region with every byte above the boundary intact, and re-binds sub-tasks by their preserved durable identifiers rather than duplicating (FR-035)
- [X] T093 [US4] Add the switch-back assertion to `tests/powershell/commands/Reconcile.ModeSwitch.Tests.ps1`
- [X] T093a [US4] Add to `tests/bash/commands/test_reconcile_mode_switch.bats`: the **checklist → subtask** switch is reported once too, naming the stories affected and the count of sub-tasks re-bound. FR-034 says "a switch in either direction" but its three named fields are written for the outbound direction only — the count of abandoned sub-tasks is zero here, because they are re-bound rather than orphaned, so this direction reports the re-bound count and no query
- [X] T093b [US4] Add the same reverse-direction report assertion to `tests/powershell/commands/Reconcile.ModeSwitch.Tests.ps1`
- [X] T093c [US4] Add to `tests/bash/commands/test_reconcile_mode_switch.bats`: a partially migrated project — some stories switched, some not — is never reported as fully migrated; the report names what was and was not migrated (FR-034, final clause, previously uncovered)
- [X] T094 [US4] Add to `tests/bash/commands/test_reconcile.bats`: checklist mode with a `task` role also declared reports the role once as recorded and not consumed, and creates no sub-task (FR-007, spec Edge Cases)
- [X] T094a [US4] Add the T094 declared-but-unused-role assertion to `tests/powershell/commands/Reconcile.Tests.ps1` (shares the file with T087)

### Implementation for User Story 4

- [X] T095 [US4] Implement switch detection in `scripts/bash/commands/reconcile.sh` from the task markers still recorded in `tasks.md` — no extra Jira read (research §6)
- [X] T096 [US4] Mirror switch detection in `scripts/powershell/commands/Reconcile.psm1`
- [X] T097 [US4] Emit the FR-034 report line with its `issue in (…)` query in `scripts/bash/commands/reconcile.sh`, built from the keys the markers carry
- [X] T098 [US4] Mirror the report line and query construction in `scripts/powershell/commands/Reconcile.psm1`
- [X] T098a [US4] Emit the reverse-direction (checklist → subtask) switch line and the partial-migration wording in `scripts/bash/commands/reconcile.sh`, beside T097's outbound line (depends on T093a, T093c)
- [X] T098b [US4] Mirror the reverse-direction and partial-migration lines in `scripts/powershell/commands/Reconcile.psm1` with identical text
- [X] T099 [US4] Emit the declared-but-unused `task` role line in `scripts/bash/commands/reconcile.sh`, replacing feature 012's status line in this mode rather than adding a second (data-model.md §4)
- [X] T100 [US4] Mirror the unused-role line in `scripts/powershell/commands/Reconcile.psm1`

**Checkpoint**: switching is safe in both directions and says what it did.

---

## Phase 7: User Story 5 — A project that offers no sub-task type can still mirror its task list (Priority: P3)

**Goal**: Checklist mode requires no `task` role and no sub-task issue type.

**Independent Test**: Point the bridge at `repo-with-no-subtask-type` in checklist mode, reconcile, and
observe the full task list mirrored with no refusal and no mention of a missing type.

### Tests for User Story 5 (write first, observe failing)

- [X] T101 [P] [US5] Add `tests/bash/commands/test_reconcile_no_subtask_type.bats` asserting that `repo-with-no-subtask-type` in checklist mode mirrors its full task list with no refusal, no warning about a missing type, and no `task` role declared (FR-005, SC-007)
- [X] T102 [P] [US5] Add the Pester mirror `tests/powershell/commands/Reconcile.NoSubtaskType.Tests.ps1`
- [X] T103 [US5] Add to `tests/bash/commands/test_reconcile_no_subtask_type.bats`: the same project in `subtask` mode still produces feature 012's existing behaviour unchanged, so the two modes are not conflated
- [X] T103a [US5] Add the T103 subtask-mode-unchanged assertion to `tests/powershell/commands/Reconcile.NoSubtaskType.Tests.ps1`

### Implementation for User Story 5

- [X] T104 [US5] Verify against T101 that Phase 2's gate split already delivers this story; if any residual dependency on `task_type_id` remains on the checklist path, remove it in `scripts/bash/commands/reconcile.sh` and `scripts/bash/sink/jira/plan_apply.sh`
- [X] T105 [US5] Apply the same verification and any residual removal in `scripts/powershell/commands/Reconcile.psm1` and `scripts/powershell/sink/jira/PlanApply.psm1`

**Checkpoint**: all five user stories are independently demonstrable.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Cross-port equivalence, the documentation FR-042 requires, and the gates that decide whether
this ships.

- [X] T106 [P] Add the conformance scenario `tests/conformance/scenarios/us022-checklist-two-phases.json` — a story with tasks across two phases, mixed complete and incomplete (contract §8 case 1)
- [X] T107 [P] Add the conformance scenario `tests/conformance/scenarios/us022-checklist-unchanged-rerun.json` — zero writes on an unchanged re-run (case 2)
- [X] T107a [P] Add the conformance scenario `tests/conformance/scenarios/us022-checklist-entry-completed.json` — reconcile, check one box in `tasks.md`, reconcile again, asserting the entry transitions to complete and `entries.completed` is 1. FR-040 names "the completion of an entry" as a corpus case; case 1's mixed states are static and do not exercise the transition
- [X] T107b [P] Add the conformance scenario `tests/conformance/scenarios/us022-checklist-crlf.json` — a `tasks.md` with CRLF line endings produces a mirrored result identical to the same file with LF endings (spec Edge Cases, Constitution VI)
- [X] T108 [P] Add the conformance scenario `tests/conformance/scenarios/us022-switch-to-checklist.json` — the switch, its report and its query (case 3)
- [X] T109 [P] Add the conformance scenario `tests/conformance/scenarios/us022-switch-to-subtask.json` — the switch back, re-binding by preserved identifier (case 4)
- [X] T110 [P] Add the conformance scenario `tests/conformance/scenarios/us022-config-question.json` — the ceremony's question, its answer, and its byte-for-byte re-run (case 5)
- [X] T110a [P] Add to `tests/bash/sink/test_plan_apply_privacy.bats`: a checklist entry carrying a BLOCK-tier value aborts the apply before the first write, and an allowlisted Confluence link in an entry passes silently — the checklist rides the story `description` channel `apply_writes` already sweeps, and this pins that it keeps doing so (FR-038, Constitution IX)
- [X] T110b [P] Add to `tests/bash/commands/test_hooks.bats`: a checklist refusal or drift warning raised inside the `after_tasks` hook is reported as one warning while the host command still exits 0 (FR-039, Constitution III)
- [X] T111 [P] Update `docs/04-config-ceremony.md` with the `task_mirror` question, its region and its effect line (FR-042)
- [X] T112 [P] Update `docs/05-reconcile-flow.md` with the two modes, the checklist's position in the managed region, and the detail trade FR-019 makes explicit
- [X] T113 [P] Update `docs/07-configuration-and-secrets.md` to list `task_mirror` in the committable team-config layer
- [X] T114 [P] Update the README managed block so a reader learns the mode exists without opening the docs (FR-042)
- [X] T114a [P] Add to `tests/bash/commands/test_config_scaffold.bats`: a repository scaffolded from `templates/config.yml.template` validates with zero schema errors, and `config_task_mirror_for` returns the empty string for every declared project — the template documents the setting without recording a choice (contract §3 `inert`, FR-002, FR-011)
- [X] T115 Add the `task_mirror` explanatory comment block to `templates/config.yml.template` with the key and both example values **commented out**, so a new repository learns the setting exists while recording nothing — a live key here would introduce the region for a team that has chosen nothing and break FR-002's byte-for-byte promise (Constitution XVI) (depends on T114a)
- [X] T116 Run `bash tests/conformance/ci-conformance.sh` and confirm exit 0 with zero `conformance divergence` lines
- [X] T117 Run `tests/run-bash.sh` and the Pester suite to green, and confirm statement coverage stays at or above 80%
- [X] T118 Run `shellcheck -x -P scripts/bash` over `scripts/bash` and `actionlint` over the workflows, both clean
- [ ] T119 Push to `ci/windows-probe` and read the resulting annotations; diff them against `main`'s current annotations before treating any red as a regression, and retry a `windows-latest` flake at most once
- [X] T120 Walk `specs/022-story-task-checklist/quickstart.md` end to end, including §6's live zero-churn double run against a real instance, and record the result

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies. T001/T002 are optional pre-release verifications and gate nothing.
- **Foundational (Phase 2)**: depends on the Phase 1 fixtures (T003–T005). **Blocks every user story.**
- **User Story 1 (Phase 3)**: depends on Phase 2. This is the MVP.
- **User Story 2 (Phase 4)**: depends on Phase 2; shares the rendering US1 builds, so it runs
  after US1 rather than beside it.
- **User Story 3 (Phase 5)**: depends on Phase 2 only. Genuinely independent of US1/US2 — it can be built
  in parallel with them by a second developer.
- **User Story 4 (Phase 6)**: depends on Phase 2 and US1 (a switch has to have something to switch to).
- **User Story 5 (Phase 7)**: depends on Phase 2 and US1; mostly verification.
- **Polish (Phase 8)**: depends on every story that is shipping.

### The one hard sequencing rule — retired

There was one: `T001 → T002 → {T036, T060}`, because the node shape was undecided. research.md §1 decided
it from Atlassian's published sources, so **no task waits on a live Jira instance**. The remaining
sequencing is ordinary: fixtures before the phases that assert against them, tests before their
implementation, and the bash port before the PowerShell port that must match it byte for byte.

### Within each user story

Tests are written and observed failing before the implementation they cover. Bash and PowerShell
implementations of the same function are sequential, not parallel — the second port mirrors the first and
must match it byte for byte.

### Parallel opportunities

Parallelism is bounded by **files**, not by task count: tasks that share a file run in listed order, and
only the first of each file carries `[P]`.

- Phase 1: T003, T004, T005 together; T001/T002 whenever an instance exists, in parallel with anything.
- Phase 2: six independent files — T006 (then T010), T007 (then T011), T008, T009, T012 (then T013a),
  T013 (then T013b); then the port pair T014/T015 together, followed by T016/T017 together (each shares
  its port's `config.sh` with T014/T015); T022/T023 together.
- Phase 3: eight independent files — T024 (then T026, T026a, T027, T029), T025 (then T028, T030, T030a),
  T031 (then T035, T035a), T032 (then T035b, T035c), T033, T033a, T034 (then T034a), T034b.
- Phase 4: eight independent files — T048 (then T050, T051a), T049 (then T051, T051b),
  T052 (then T054), T053 (then T055), T056, T057, T058 (then T059), T059a.
- Phase 5: five independent files — T068, T069, T070 (then T072, T074, T076),
  T071 (then T073, T077), T075; then T078/T079 together.
- Phase 6: four independent files — T086 (then T094), T087 (then T094a),
  T088 (then T090, T092, T093a, T093c), T089 (then T091, T093, T093b).
- Phase 7: T101 (then T103), T102 (then T103a).
- Phase 8: T106–T110 with T107a, T107b, T110a, T110b, and T111–T114 with T114a — all together;
  T115 after T114a; T116–T120 are gates and run in order.

---

## Parallel Example: User Story 1

```bash
# Launch the twelve US1 test tasks together — different files, no shared state:
Task: "T024 adf checklist structure in tests/bash/sink/test_adf_checklist.bats"
Task: "T025 Pester mirror in tests/powershell/sink/Adf.Checklist.Tests.ps1"
Task: "T031 plan_apply plans zero task actions in tests/bash/sink/test_plan_apply_checklist.bats"
Task: "T032 Pester mirror in tests/powershell/sink/PlanApply.Checklist.Tests.ps1"
Task: "T033 dry-run per-entry display in tests/bash/commands/test_reconcile_dry_run.bats"
Task: "T034 unattributed tasks named in tests/bash/commands/test_reconcile.bats"
```

---

## Implementation Strategy

### MVP first (Setup + Foundational + User Story 1)

1. Phase 1 — the fixtures T003, T004, T005 (T001/T002 are optional and gate nothing).
2. Phase 2 — the setting and the gate split.
3. Phase 3 — the rendering.
4. **STOP and validate**: a hundred tasks, six issues, on a real project. That alone is the feature's
   stated value, and it is demonstrable without the ceremony question, the drift record, or the switch
   report.

### Incremental delivery

1. MVP above → checklists appear.
2. + US2 → they advance, they do not churn, and a human's edit is reported. **This is the smallest
   honestly shippable release**: US1 without US2 would ship a checklist that never ticks, which spec §US2
   calls worse than no checklist.
3. + US3 → the setting becomes discoverable rather than hand-written.
4. + US4 → switching is safe and legible.
5. + US5 → the tier reaches projects that never had it.

### Parallel team strategy

After Phase 2, one developer takes US1 → US2 → US4 (the rendering spine) while a second takes US3 (the
ceremony) — the two touch disjoint files, `sink/jira/` versus `commands/config.sh` + `lib/cli.sh`. US5 is a
half-day verification for whoever finishes first.

---

## Notes

- Every implementation task has a bash and a PowerShell half. They are numbered separately because they
  are separate files and separate reviews, and the conformance corpus is what proves they agree.
- Conformance success is silent: exit 0 with no `conformance divergence` line is the pass; the temp paths
  it prints are harness noise.
- `bats` needs `-r` or it silently runs nothing, and the runner must never be piped. Prefer
  `tests/run-bash.sh --since main` for the inner loop.
- `main` is currently red on `windows-latest` for reasons unrelated to this feature. T119 exists because
  of that, not in spite of it.
- Two requirements are satisfied by writing no code and are covered by regression tests only: FR-006
  (`task_strategy` stays retired — T008/T009) and FR-038/FR-039 (the privacy guard already sweeps the
  story `description` channel the checklist rides on, and the hook non-blocking rule is untouched —
  T110a/T110b pin both). FR-020 is the same shape: the two-marker splice is upstream and untouched, and
  T035a/T035b pin that it stays so once a checklist is appended below the boundary.

---

## Phase 9: Convergence

**Note**: T001–T005 and T119 are still open in their own phases and are deliberately not restated here —
they are already traceable and already unchecked. This phase carries only the gaps that no existing task
covers.

- [X] T121 Add to `tests/bash/commands/test_reconcile_idempotent.bats` the checklist-mode renumber case: reconcile, regenerate `tasks.md` with every `T0xx` identifier renumbered and the task text, order and checked state unchanged, reconcile again, and assert zero writes of every kind and `checklists.unchanged` equal to the story count — T054 named this file and landed nothing in it, so the outcome FR-017 exists to guarantee is pinned only at the node level by `tests/bash/sink/test_adf_checklist.bats` per FR-017 (missing)
- [X] T122 Add the same renumber-produces-zero-writes assertion to `tests/powershell/commands/Reconcile.Idempotent.Tests.ps1`, which T055 named and which carries no checklist assertion today, per FR-017 (missing)
- [X] T123 Add to `tests/bash/commands/test_reconcile_task_mirror_gate.bats` the CRLF-versus-LF equality the conformance corpus cannot express: reconcile in checklist mode over a `tasks.md` with CRLF line endings, reconcile the same content with LF endings, and assert the planned story description is byte-identical — `us022-checklist-crlf.json` proves only that both ports agree on the CRLF input, not that CRLF and LF converge, per spec Edge Cases and Constitution VI (partial)
- [X] T124 Add the same CRLF-versus-LF equality assertion to `tests/powershell/commands/Reconcile.TaskMirrorGate.Tests.ps1` per spec Edge Cases and Constitution VI (partial)
