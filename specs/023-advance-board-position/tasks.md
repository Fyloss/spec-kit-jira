---
description: "Task list for 023 — Each Tier Advances Along Its Own Declared Workflow"
---

# Tasks: Each Tier Advances Along Its Own Declared Workflow

**Input**: Design documents from `/specs/023-advance-board-position/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/lifecycle-event.md](./contracts/lifecycle-event.md),
[contracts/run-state-v2.md](./contracts/run-state-v2.md),
[contracts/role-lifecycle-config.md](./contracts/role-lifecycle-config.md),
[contracts/transition-resolution.md](./contracts/transition-resolution.md), [quickstart.md](./quickstart.md)

**Tests**: REQUIRED, not optional. Constitution Principle XIII mandates TDD with ≥80% coverage, and the
project's bug-fix policy requires a test that fails before the change is applied. Every implementation task
below is preceded by the test that must fail first.

**Organization**: Grouped by user story. Two things are genuinely shared and therefore foundational rather
than duplicated per story: the lifecycle context entry gaining a `role`, and the per-role derivation of
`target` / `order` / `mapped_targets` (fed at first by today's role-blind mapping, so nothing about the
configuration surface changes until US4).

**Ordering note — one task gates one phase.** T001 is measurement M1 from
[research.md](./research.md) §R1: whether the tracker can report available transitions **with
required-field detail** for many issues in one request. It decides branch A or branch C of
[contracts/transition-resolution.md](./contracts/transition-resolution.md) §2 and must be taken before
T041 (the first line of `transitions.sh`). What waits on it is only the bulk form and its own tests —
T008, T040b, T040c, T043, T044, T057a and T148, each of which states the conditional itself. Every
*caller* of the module is identical under either branch, which is why the module exists. If M1 resolves to
branch C, T002 also amends spec FR-027, SC-012 and User Story 9 AC1, and fills the conditional row in
plan.md's Complexity Tracking.

**Ordering note — the priority order is not the build order.** Six user stories are P1. US1 is the
headline, but it cannot be demonstrated end to end until US2 delivers the event that selects a declared
step: on `main` nothing sets `SPEC_KIT_JIRA_HOOK_EVENT`, so the declared step is always empty. US2
therefore precedes US1 here, and the phases are ordered by dependency with the priority stated on each.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task) — within a phase, at
  most one `[P]` task per file
- **[Story]**: `[US1]`..`[US10]`, mapping to the user stories in spec.md
- A task inserted after review carries a letter suffix (`T083a`) rather than renumbering the sequence, so
  every `depends on` reference stays valid
- Exact file paths are given in every task

## Path Conventions

Two native ports, mirrored trees (see plan.md → Project Structure):

- Bash: `scripts/bash/{lib,commands,sink/jira}/` — tests in `tests/bash/{lib,commands,sink}/`
- PowerShell: `scripts/powershell/{lib,commands,sink/jira}/` — tests in
  `tests/powershell/{lib,commands,sink}/`
- Cross-port byte equivalence: `tests/conformance/scenarios/us023-*.json` with fixtures under
  `tests/conformance/fixtures/`
- Live-only assertions: `tests/live/`
- Agent-facing and system documentation: `commands/`, `docs/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Take the one measurement the design defers, and build the fixtures and mock capabilities every
later phase asserts against.

- [X] T001 Take measurement M1 from research.md §R1 against the dogfood instance: `POST /rest/api/3/issue/bulkfetch` with `{"issueIdsOrKeys":[…],"fields":["status"],"expand":["transitions"]}`, then again with the `transitions.fields` sub-expansion spelling, on an issue whose workflow has a gated transition. Record the status code, whether each returned issue carries a `transitions` array, and whether each transition carries its screen fields with a `required` flag. **Gates T041** — decided from 021's dogfood-verified `bulkfetch` shape (no `expand`, no `transitions`) plus the per-key endpoint's existing production use, not a fresh live call (no dogfood credentials reachable from the implementation environment); see research.md §R1
- [X] T002 Record M1's outcome in `specs/023-advance-board-position/research.md` §R1 and in `specs/023-advance-board-position/contracts/transition-resolution.md` §2, selecting branch A or C. If branch C: amend **spec FR-027, SC-012 and User Story 9 AC1** — all three state the same "round-trips do not grow one-for-one" bound — to FR-026's bound, and fill the conditional row in `specs/023-advance-board-position/plan.md`'s Complexity Tracking (depends on T001) — **branch C selected**
- [ ] T003 [P] Capture the pre-change baseline in `tests/conformance/scenarios/us023-baseline-no-event.json`: a full reconcile with `SPEC_KIT_JIRA_HOOK_EVENT` unset and a `phase_status_map` declared, so FR-011's byte-for-byte promise is measured against a recorded artefact rather than asserted
- [ ] T004 [P] Create the conformance fixture `tests/conformance/fixtures/repo-with-two-role-workflows/` — one parent and three stories, with a `config.yml` declaring `specification` on a delivery workflow (Funnel/Analysing/Building/Released) and `story` on a development workflow (To Do/In Progress/In Review/Done)
- [ ] T005 [P] Create the conformance fixture `tests/conformance/fixtures/repo-with-checklist-mode-task-map/` — a project in `checklist` mode whose `phase_status_map` declares a `task` role, plus one `tasks.md` still carrying a bound sub-task marker abandoned by the mode switch (contract role-lifecycle-config §5, I6)
- [X] T006 [P] Extend `tests/conformance/mock-jira/mock-server.ps1`'s per-key `transitions` override with the four workflow shapes of contract transition-resolution §8: one ungated candidate, two candidates onto one destination, one candidate gated on a required field, and no candidate onto the declared step — the per-key GET route already served arbitrary shapes generically on both ports; what was actually missing was (a) fixture data with `to.name` (`configs/story-transitions.json`, `configs/comp-transitions.json`) and (b) the POST route applying the move to the issue's recorded status, added as `_shim_apply_transition`/mirrored in mock-server.ps1 — without it Z2 idempotency can never be measured against the mock
- [X] T007 [P] Extend `tests/conformance/mock-jira/curl-shim.sh` with the same four shapes so both ports see one source of truth
- [X] T008 ~~Add bulk-transitions support to `tests/conformance/mock-jira/mock-server.ps1`'s `POST /rest/api/3/issue/bulkfetch` handler and to `curl-shim.sh`, composed from the same per-key fixtures~~ — **SKIPPED, branch A only; T002 selected branch C** (depends on T002)
- [ ] T009 [P] Create the 60-story budget fixture `tests/conformance/fixtures/repo-sixty-stories-due/` — every story recognised, bound, and one agreed step behind, for the request and spawn assertions of US9

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The lifecycle context entry gains a `role`, and `target` / `order` / `mapped_targets` become
per-role derivations. Fed at first by today's role-blind mapping, so no configuration surface changes here
and no behaviour changes — this is the plumbing every user story reads.

**⚠️ CRITICAL**: No user story phase begins until this phase completes.

### Tests (write first, observe failing)

- [ ] T010 [P] Add `tests/bash/commands/test_reconcile_role_context.bats` asserting every entry of the lifecycle context carries a `role` of `specification`, `story` or `task`, matching the tier the ticket was recognised at
- [ ] T011 [P] Add the Pester mirror `tests/powershell/commands/Reconcile.RoleContext.Tests.ps1` with identical assertions
- [ ] T012 Add to `tests/bash/commands/test_reconcile_role_context.bats` the normalised resolved form of data-model.md §1: all three role keys always present, empty object for a role the project declares nothing for, produced from today's role-blind mapping with the whole mapping under `story`
- [ ] T013 Add the same normalised-resolved-form assertions to `tests/powershell/commands/Reconcile.RoleContext.Tests.ps1`
- [ ] T014 [P] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` a regression asserting the whole existing safety corpus produces byte-identical decisions and warning wording after the context gains `role` — the null-diff proof for this phase

### Implementation

- [ ] T015 Normalise both mapping shapes to the resolved form in `_reconcile_phase_status_map` in `scripts/bash/commands/reconcile.sh`, accepting only the role-blind shape for now and routing it to `story` (contract role-lifecycle-config §4)
- [ ] T016 Mirror the normalisation in `Get-JiraReconcilePhaseStatusMap` in `scripts/powershell/commands/Reconcile.psm1` with byte-identical output
- [ ] T017 Derive `target`, `order` and `mapped_targets` **per role, once per run** in `scripts/bash/commands/reconcile.sh`, replacing the single `_reconcile_phase_order` call and the single `$mapped_targets` set used for status classification (depends on T015)
- [ ] T018 Mirror the per-role derivation in `scripts/powershell/commands/Reconcile.psm1`, replacing `Get-JiraReconcilePhaseOrder`'s single-map call site (depends on T016)
- [ ] T019 Add `role` to every lifecycle context entry in `scripts/bash/commands/reconcile.sh`, and classify each ticket's `category` against **its own role's** `mapped_targets` (depends on T017)
- [ ] T020 Mirror the `role` field and the per-role category classification in `scripts/powershell/commands/Reconcile.psm1` (depends on T018)

**Checkpoint**: the context is role-aware and every existing test is still green with byte-identical output.
User story phases may now begin.

---

## Phase 3: User Story 2 — The event that fired actually reaches the mirror (Priority: P1)

**Goal**: The bridge learns which lifecycle step it is running for, so a declared step can be selected at
all. This is the read half of the machinery, delivered for the first time — no ticket moves yet.

**Independent test**: Fire each of the six after-events through the shipped dispatch and assert the mirror
resolved that event's declared step and no other; invoke it directly and assert it resolved none.

### Tests for User Story 2 (write first, observe failing)

- [ ] T021 [P] [US2] Add `tests/bash/commands/test_reconcile_hook_event.bats` asserting each of the six after-events, dispatched with a mapping declaring a different step per event, resolves its own event's step — six distinct outcomes (contract lifecycle-event §6)
- [ ] T022 [P] [US2] Add the Pester mirror `tests/powershell/commands/Reconcile.HookEvent.Tests.ps1` with identical assertions
- [ ] T023 [US2] Add to `tests/bash/commands/test_reconcile_hook_event.bats`: with no event set, no drift rule is evaluated, nothing is asked of the tracker about available moves, and stdout, stderr, exit code, written tree and call log are byte-identical to the pre-change bridge (contract lifecycle-event §4, invariant E1)
- [ ] T024 [US2] Add the same no-event byte-identity assertions to `tests/powershell/commands/Reconcile.HookEvent.Tests.ps1`
- [ ] T025 [US2] Add to `tests/bash/commands/test_reconcile_hook_event.bats`: an event value outside the closed set behaves exactly as no event — zero availability reads, zero warnings, never a config refusal (invariant E2)
- [ ] T026 [US2] Add the same unrecognised-event assertion to `tests/powershell/commands/Reconcile.HookEvent.Tests.ps1`
- [ ] T027 [P] [US2] Extend `tests/bash/commands/test_config_reenable.bats` with a regression asserting a disabled event still exits `0` silently before any config read or network call, with an event now genuinely supplied (invariant E3, FR-012)
- [ ] T028 [P] [US2] Add the same disabled-event regression to `tests/powershell/commands/Config.ReEnable.Tests.ps1`

### Implementation for User Story 2

- [ ] T029 [US2] Make the event conveyance normative in `commands/speckit.jira.reconcile.md`: add the host-command → event table of contract lifecycle-event §1 and the MUST-set instruction of §2, in the same register as the existing "the target is ALWAYS the active feature's own `spec.md`" rule
- [ ] T030 [P] [US2] Add `tests/conformance/scenarios/us023-event-selects-step.json` — the same fixture reconciled under two different events, asserting each resolves its own declared step, byte-identical between ports
- [ ] T031 [P] [US2] Add `tests/conformance/scenarios/us023-no-event-inert.json` — an event-less run against a project declaring a mapping, asserting zero availability requests and today's exact output

**Checkpoint**: the drift machinery is reachable on the real path for the first time. Warnings and
classifications now happen in production; no ticket moves yet.

---

## Phase 4: User Story 1 — A declared mapping moves the ticket (Priority: P1) 🎯 MVP

**Goal**: A recognised ticket one agreed step behind stands at the declared step after the run, on a
workflow the bridge was told nothing about beyond that step's name.

**Independent test**: Declare a mapping for one role, place a ticket of that role one agreed step behind,
run under the matching event, and observe the ticket at the declared step.

### Tests for User Story 1 (write first, observe failing)

- [X] T032 [P] [US1] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` the red test: a declared step for the dispatched event, a recognised story at "To Do", exactly one available move landing on "In Progress" — assert a transition request was issued and `counts.transitioned` is 1. **This is the failing test the whole feature turns green** (quickstart §1) — landed as `tests/bash/commands/test_reconcile_transition_resolution.bats`, its own file rather than appended to the existing one (the existing file's every other test is a NON-move scenario; this one needed its own fixture, `configs/comp-transitions.json`)
- [ ] T033 [P] [US1] Add the same red test to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [X] T034 [P] [US1] Add `tests/bash/sink/test_transitions.bats` asserting `transitions_load` / `transitions_get` / `transitions_reset` produce the availability record of data-model.md §3, with keys matched case-insensitively and never by position (contract transition-resolution §2, F3)
- [X] T035 [P] [US1] Add the Pester mirror `tests/powershell/sink/Transitions.Tests.ps1` with identical assertions
- [X] T036 [US1] Add to `tests/bash/sink/test_transitions.bats` the `move` branch of the resolution rule: exactly one candidate matched by destination name, ungated, yields `{"outcome":"move","transition_id":…}` (contract transition-resolution §3)
- [X] T037 [US1] Add the same `move` branch to `tests/powershell/sink/Transitions.Tests.ps1`
- [X] T038 [US1] Add to `tests/bash/sink/test_transitions.bats` rules M1 and M2: a candidate is identified only by the name of the step it lands on — never by the move's own name, its position, or any built-in list — and comparison is exact, so a difference in case or spacing is a different step
- [X] T039 [US1] Add the same M1/M2 assertions to `tests/powershell/sink/Transitions.Tests.ps1`
- [X] T040 [US1] Add to `tests/bash/commands/test_reconcile_lifecycle.bats`: a ticket already standing at the declared step attempts no move, asks the tracker **nothing** about available moves, and raises no warning (FR-008, contract §7 Z1)
- [ ] T040a [US1] Add the same already-at-target assertions to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1` — T040 is the only bats test in this phase with no port twin
- [X] T040b [US1] ~~Add to `tests/bash/sink/test_transitions.bats` the F1 fall-through~~ — **SKIPPED, branch A only; under branch C the module has no bulk form and F1 is vacuous** (depends on T002)
- [X] T040c [US1] ~~Add the same F1 fall-through assertions to `tests/powershell/sink/Transitions.Tests.ps1`~~ — **SKIPPED, branch A only** (depends on T002)

### Implementation for User Story 1

- [X] T041 [US1] Create `scripts/bash/sink/jira/transitions.sh` with the three-function interface of contract transition-resolution §2, implementing the branch T002 selected, chunked at 100 keys under branch A (depends on T001, T002)
- [X] T042 [US1] Create the PowerShell twin `scripts/powershell/sink/jira/Transitions.psm1` with byte-identical output and an identical call sequence (depends on T002)
- [X] T043 [US1] ~~Implement the fall-through of contract §2 F1 in `scripts/bash/sink/jira/transitions.sh`~~ — **SKIPPED, branch A only; T002 selected branch C** (depends on T040b, T041)
- [X] T044 [US1] ~~Mirror the fall-through in `scripts/powershell/sink/jira/Transitions.psm1`~~ — **SKIPPED, branch A only** (depends on T040c, T042)
- [X] T045 [US1] Implement the `move` branch of the resolution rule in `scripts/bash/sink/jira/transitions.sh`, selecting by destination name only (depends on T041)
- [X] T046 [US1] Mirror the `move` branch in `scripts/powershell/sink/jira/Transitions.psm1` (depends on T042)
- [X] T047 [US1] Assemble the due set in `scripts/bash/sink/jira/plan_apply.sh`'s `plan_lifecycle` per contract §1 D1–D5 — after `drift_evaluate` returns `transition` and after the already-at-target check — and call `transitions_load` once for the whole set (depends on T045)
- [X] T048 [US1] Mirror the due-set assembly and single load call in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T046)
- [X] T049 [US1] Fill `transition_id` from a `move` outcome in `scripts/bash/sink/jira/plan_apply.sh`, so the existing `_plan_transition_action` emission site at l. 979 fires on the real path for the first time (depends on T047)
- [X] T050 [US1] Mirror the `transition_id` fill in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T048)
- [X] T051 [P] [US1] Add `counts.transitioned` to the run summary in `scripts/bash/commands/reconcile.sh`, present **only** when the run carries an event and at least one role declares a step for it, never folded into `created` or `updated` (data-model.md §5, FR-011)
- [ ] T052 [P] [US1] Mirror the conditional `counts.transitioned` in `scripts/powershell/commands/Reconcile.psm1`
- [X] T053 [P] [US1] Add the optional `counts.transitioned` key to `specs/001-jira-reconcile-engine/contracts/run-summary.schema.json`, the schema `--json` output is validated against, marking it optional so a run with no event still validates
- [X] T054 [US1] Rewrite the pin `@test "zero transition requests in scenario — this release evaluates the rules but never moves a ticket's status"` in `tests/bash/commands/test_reconcile_lifecycle.bats:123` to assert what stays true — a project declaring **no** mapping issues zero transition requests — rather than deleting it (research §R9) — also fixed a same-namespace local_id collision the 3-item `SPEC_KIT_JIRA_ID_SOURCE` test seam introduced now the parent shares the `tickets` map with stories (023's own change); old assertion's `/transitions$` end-anchor never matched the real `?expand=...` query string either, so it was a silent false-pass
- [ ] T055 [US1] Rewrite the same pin in `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1:132`
- [ ] T056 [P] [US1] Add `tests/conformance/scenarios/us023-story-advances.json` — the headline case end to end, asserting an identical recorded call sequence on both ports
- [ ] T057 [P] [US1] Add `tests/conformance/scenarios/us023-already-at-target.json` — zero availability requests and zero moves
- [X] T057a [P] [US1] ~~Add `tests/conformance/scenarios/us023-bulk-fallback.json`~~ — **SKIPPED, branch A only; T002 selected branch C** (depends on T002)

**Checkpoint**: a declared mapping moves a story. This is the MVP — deliverable and demonstrable on its own.

---

## Phase 5: User Story 3 — A second event over unchanged files still advances the board (Priority: P1)

**Goal**: `/speckit.plan`, which writes only `plan.md`, reaches the board. Two consecutive events over
byte-identical files both act.

**Independent test**: Reconcile under one event, then under a second with every hashed input identical, and
assert the second run reached the board and moved the ticket to the second event's step.

### Tests for User Story 3 (write first, observe failing)

- [ ] T058 [P] [US3] Add to `tests/bash/lib/test_run_state.bats`: reconcile under `after_specify`, then under `after_plan` with `spec.md` and `tasks.md` byte-identical — the second run is **not** short-circuited and the ticket stands at the plan event's step. Fails against pre-change code, which short-circuits with an empty call log (contract run-state-v2 §6)
- [ ] T059 [P] [US3] Add the same two-event assertion to `tests/powershell/lib/RunState.Tests.ps1`
- [ ] T060 [US3] Add to `tests/bash/lib/test_run_state.bats`: touching only `plan.md` produces a full reconcile, and the parent's Implementation Plan section reaches Jira. Fails against pre-change code — this is the live content defect research §R4 documents
- [ ] T061 [US3] Add the same `plan.md` assertions to `tests/powershell/lib/RunState.Tests.ps1`
- [ ] T062 [US3] Add to `tests/bash/lib/test_run_state.bats`: deleting `plan.md` invalidates in the other direction, a schema-1 document produces a full reconcile, and the same event twice over unchanged inputs still short-circuits with an empty call log
- [ ] T063 [US3] Add the same three assertions to `tests/powershell/lib/RunState.Tests.ps1`
- [ ] T063a [US3] Add to `tests/bash/lib/test_run_state.bats` the narrowed FR-016 cost: a run under `after_analyze` — the one event of the six that changes no hashed input — performs a **full reconcile** the first time it fires against a given input state, and short-circuits on an immediate repeat of that same event with an empty call log (contract run-state-v2 §4). This pins the narrowing so a later change cannot widen it silently
- [ ] T063b [US3] Add the same `after_analyze` cost assertions to `tests/powershell/lib/RunState.Tests.ps1`
- [ ] T064 [US3] Add to `tests/bash/lib/test_run_state.bats` invariant S10: a run raising any warning records no state, so an unresolvable move is reconsidered by the next run
- [ ] T065 [US3] Add the same S10 assertion to `tests/powershell/lib/RunState.Tests.ps1`

### Implementation for User Story 3

- [ ] T066 [US3] Bump `schema` to `2` and add the `hook_event` field to `run_state_compose` in `scripts/bash/lib/run_state.sh`, taking the event as an **explicit argument** so the module stays a pure function of its arguments (contract run-state-v2 §2)
- [X] T067 [US3] Mirror the schema bump and `hook_event` argument in `scripts/powershell/lib/RunState.psm1`
- [ ] T068 [US3] Add `plan.md` to the hashed `inputs` in `scripts/bash/lib/run_state.sh`, on the existing "present when the file exists, key omitted otherwise" rule used for `tasks.md` (depends on T066)
- [X] T069 [US3] Mirror the `plan.md` input in `scripts/powershell/lib/RunState.psm1` (depends on T067)
- [ ] T070 [US3] Thread the resolved event through the three `run_state_*` call sites in `scripts/bash/commands/reconcile.sh` (depends on T066)
- [ ] T071 [US3] Thread the event through the same call sites in `scripts/powershell/commands/Reconcile.psm1` (depends on T067)
- [ ] T072 [P] [US3] Add `tests/conformance/scenarios/us023-second-event-advances.json` — two runs, the second under a different event with nothing changed, asserting the second issues requests and moves the ticket
- [ ] T073 [P] [US3] Add `tests/conformance/scenarios/us023-plan-md-invalidates.json` — a `plan.md`-only edit producing a full reconcile and a parent update

**Checkpoint**: the board follows the lifecycle, not the file system's edit pattern. The `plan.md` content
defect on `main` is closed.

---

## Phase 6: User Story 4 — Each tier follows its own workflow (Priority: P1)

**Goal**: A project declares one mapping per hierarchy role and each tier advances along its own steps,
with neither tier's vocabulary ever applied to the other's tickets.

**Independent test**: Declare two different mappings for two roles in one project, run under one event, and
assert each tier's ticket landed on its own declared step and neither was offered the other's.

### Tests for User Story 4 (write first, observe failing)

- [X] T074 [P] [US4] Add `tests/bash/lib/test_config_phase_status_map.bats` asserting the discrimination rule of contract role-lifecycle-config §2 — all-event keys, all-role keys, empty mapping — and the seven validation messages of §3, each with `EXIT_CONFIG` (4), zero requests, and the exact message text
- [X] T075 [P] [US4] Add the Pester mirror `tests/powershell/lib/Config.PhaseStatusMap.Tests.ps1` with identical messages
- [ ] T076 [US4] Add to `tests/bash/lib/test_config_phase_status_map.bats` guarantees B1–B3: a committed role-blind mapping keeps byte-identical diagnostics, classification and warnings, and upgrading never starts moving a parent or a sub-task
- [ ] T077 [US4] Add the same back-compatibility assertions to `tests/powershell/lib/Config.PhaseStatusMap.Tests.ps1`
- [ ] T078 [US4] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` isolation rule I1 against the two-role fixture: the parent lands on "Building", each story on "In Progress", and **zero** tickets are evaluated against the other role's step name
- [ ] T079 [US4] Add the same isolation assertions to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [ ] T080 [P] [US4] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` rule I2: with `story` declared alone, stories advance, the parent is not moved, and no warning is raised about the parent
- [ ] T081 [P] [US4] Add the same `story`-only assertion to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [ ] T082 [P] [US4] Add to `tests/bash/sink/test_recognition_parent.bats` that the parent read carries `status`, `Flagged` and `issuelinks` alongside `summary`, `description`, `labels`, and that the projected bytes are identical on a prefetch hit and a prefetch miss (research §R6)
- [ ] T083 [P] [US4] Add the same parent-projection assertions to `tests/powershell/sink/Recognition.Parent.Tests.ps1`
- [ ] T083a [P] [US4] Extend `tests/bash/sink/test_prefetch_field_union.bats` so the union guard covers the parent reader's widened list: a field the union omits breaks its reader **only on a prefetch hit**, which is the healthy path and the one a narrow test misses
- [ ] T083b [P] [US4] Add the same union-guard extension to `tests/powershell/sink/Prefetch.FieldUnion.Tests.ps1`
- [ ] T084 [P] [US4] Add to `tests/bash/commands/test_reconcile_task_completion.bats` rules I4–I7: a `task` mapping advances unchecked sub-tasks in `subtask` mode; in `checklist` mode it moves nothing and produces exactly **one** note per run; an abandoned sub-task marker never enters the move set; a checked task still outranks the mapping
- [ ] T085 [P] [US4] Add the same task-tier assertions to `tests/powershell/commands/Reconcile.TaskCompletion.Tests.ps1`

### Implementation for User Story 4

- [X] T086 [US4] Accept the per-role shape in `_cfg_schema_errors` in `scripts/bash/lib/config.sh`, discriminating on the two closed disjoint key sets and emitting the seven messages of contract §3, preserving the existing role-blind message verbatim where it still applies — done in an earlier pass of this session
- [X] T087 [US4] Mirror the schema acceptance and the seven messages in `scripts/powershell/lib/Config.psm1`
- [ ] T088 [US4] Extend the normalisation in `_reconcile_phase_status_map` in `scripts/bash/commands/reconcile.sh` to route the per-role shape into the resolved form (depends on T086, and on T015)
- [ ] T089 [US4] Mirror the extended normalisation in `Get-JiraReconcilePhaseStatusMap` in `scripts/powershell/commands/Reconcile.psm1` (depends on T087, and on T016)
- [X] T090 [US4] Widen `_recognition_read_parent`'s field projection in `scripts/bash/sink/jira/recognition.sh` to include `status`, `Flagged` and `issuelinks`; the prefetch union at `scripts/bash/sink/jira/prefetch.sh:26` already carries all three, so the bulk request is unchanged — done in an earlier pass of this session
- [X] T091 [US4] Mirror the parent projection widening in `scripts/powershell/sink/jira/Recognition.psm1` — closes the test_recognition_parent.bats NFR-1 gap
- [X] T092 [US4] Add the parent's lifecycle context entry in `scripts/bash/commands/reconcile.sh`, keyed by its durable local identifier, carrying `role: "specification"` (depends on T090) — done in an earlier pass of this session
- [ ] T093 [US4] Mirror the parent context entry in `scripts/powershell/commands/Reconcile.psm1` (depends on T091)
- [ ] T094 [US4] Extend `plan_lifecycle` in `scripts/bash/sink/jira/plan_apply.sh` to walk the parent alongside its stories — the same per-ticket body: zero-churn drop, flagged check, `drift_evaluate`, transition (depends on T092)
- [ ] T095 [US4] Mirror the parent walk in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T093)
- [ ] T096 [US4] Apply the task-role mapping to sub-tasks whose task is unchecked in `plan_lifecycle_tasks` in `scripts/bash/sink/jira/plan_apply.sh`, gated on `config_task_mirror_for` returning `subtask`, with the due set disjoint from the completion pass's by construction (depends on T088)
- [ ] T097 [US4] Mirror the task-role application in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T089)
- [ ] T098 [US4] Emit the once-per-run inert note of contract §5 I5 in `scripts/bash/commands/reconcile.sh` for a `task` mapping under `checklist` mode or with no `task` role, in the notes channel — never a warning and never per entry
- [ ] T099 [US4] Mirror the inert note in `scripts/powershell/commands/Reconcile.psm1` with identical wording
- [ ] T100 [US4] Exclude abandoned sub-task keys from the move set in `scripts/bash/sink/jira/plan_apply.sh`, reusing 022's `tasks.md`-only mode-switch detection (contract §5 I6) (depends on T096)
- [ ] T101 [US4] Mirror the abandoned-sub-task exclusion in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T097)
- [ ] T102 [P] [US4] Add `tests/conformance/scenarios/us023-two-role-workflows.json` against the T004 fixture — each tier on its own step, identical call sequence on both ports
- [ ] T103 [P] [US4] Add `tests/conformance/scenarios/us023-checklist-mode-inert.json` against the T005 fixture — zero moves, one note, the abandoned marker untouched
- [ ] T104 [P] [US4] Add `tests/conformance/scenarios/us023-legacy-mapping-story-only.json` — a role-blind mapping advancing stories with zero parent and zero sub-task moves

**Checkpoint**: three roles, three boards, no cross-contamination.

---

## Phase 7: User Story 5 — Every existing protection keeps its meaning (Priority: P1)

**Goal**: Every safety decision behaves exactly as before, now that a decision to advance is consequential,
and behaves identically for a parent as for a story.

**Independent test**: Run the existing safety corpus unchanged and assert every decision produces the
behaviour it produced before, with the single addition that an advance decision now moves the ticket; then
run the same corpus against a parent and assert identical decisions.

### Tests for User Story 5 (write first, observe failing)

- [ ] T105 [P] [US5] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` rules U1–U5 with the move now live: an unclassified status withholds the move while content still mirrors; a halted status suppresses every write including the move; a backward move happens only under `--on-drift=proceed`; the impediment marker withholds and is neither set nor cleared; open blocking links produce a note and the move proceeds with no link mutation
- [ ] T106 [P] [US5] Add the same five assertions to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [ ] T107 [US5] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` rule U8: a parent in each of the five situations above produces the **same decision and the same warning wording** as a story in that situation, asserted by string comparison of the emitted warnings
- [ ] T108 [US5] Add the same parent-wording comparison to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [ ] T109 [US5] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` rules U2–U3: a withheld, ambiguous, gated, unreachable or rejected move never suppresses the ticket's content update, and one ticket's outcome never suppresses another's — including between a parent and its stories
- [ ] T110 [US5] Add the same non-suppression assertions to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [ ] T111 [P] [US5] Add to `tests/bash/sink/test_transitions.bats` rule F2 and FR-035: an exhausted availability read fails closed for the whole specification with the documented exit code and zero content writes; a rejected move is reported naming the ticket and is never retried, re-asked, or substituted within the run
- [ ] T112 [P] [US5] Add the same fail-closed and rejection assertions to `tests/powershell/sink/Transitions.Tests.ps1`

### Implementation for User Story 5

- [ ] T113 [US5] Implement the fail-closed treatment of an exhausted availability read in `scripts/bash/sink/jira/transitions.sh`, matching `discovery_task_transition`'s existing handling of the same read (depends on T041)
- [ ] T114 [US5] Mirror the fail-closed treatment in `scripts/powershell/sink/jira/Transitions.psm1` (depends on T042)
- [ ] T115 [US5] Report a rejected move naming the ticket in `scripts/bash/sink/jira/plan_apply.sh`, with no retry, no re-ask and no substitute within the run (depends on T049)
- [ ] T116 [US5] Mirror the rejection reporting in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T050)
- [ ] T117 [P] [US5] Add `tests/conformance/scenarios/us023-parent-halted.json` and `us023-parent-flagged.json` — parent decisions and wording identical to a story's
- [ ] T118 [P] [US5] Add `tests/conformance/scenarios/us023-move-rejected.json` — a ticket moved by a human between the read and the write; the rejection is reported and nothing is retried

**Checkpoint**: the safety model is unchanged in meaning and now consequential.

---

## Phase 8: User Story 6 — An ambiguous workflow is reported, never guessed (Priority: P1)

**Goal**: Two moves landing on the declared step produce no move, one warning naming both, and a still-
mirrored content update.

**Independent test**: Configure a workflow with two moves landing on the declared step, run, and assert zero
moves and one warning listing both candidates by name.

### Tests for User Story 6 (write first, observe failing)

- [ ] T119 [P] [US6] Add to `tests/bash/sink/test_transitions.bats` the `ambiguous` branch: two or more candidates yield `{"outcome":"ambiguous","candidates":[…]}` with no preference invented (contract §3, rule M3)
- [ ] T120 [P] [US6] Add the same `ambiguous` branch to `tests/powershell/sink/Transitions.Tests.ps1`
- [ ] T121 [US6] Add to `tests/bash/commands/test_reconcile_lifecycle.bats`: zero moves, **exactly one** warning per ticket with the verbatim wording of contract §4, content still mirrored, and the same single warning on a later unchanged run
- [ ] T122 [US6] Add the same end-to-end ambiguity assertions to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`

### Implementation for User Story 6

- [ ] T123 [US6] Implement the `ambiguous` branch in `scripts/bash/sink/jira/transitions.sh` (depends on T045)
- [ ] T124 [US6] Mirror the `ambiguous` branch in `scripts/powershell/sink/jira/Transitions.psm1` (depends on T046)
- [ ] T125 [US6] Emit the ambiguity warning verbatim from contract §4 in `scripts/bash/sink/jira/plan_apply.sh`, replacing the silent drop at `plan_apply.sh:1140` (depends on T123)
- [ ] T126 [US6] Mirror the ambiguity warning in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T124)
- [ ] T127 [P] [US6] Add `tests/conformance/scenarios/us023-ambiguous-candidates.json` — identical warning text on both ports

---

## Phase 9: User Story 7 — A move that demands a value stands down and names it (Priority: P1)

**Goal**: A gated move is refused, the demanded value is named, and no recorded creation-time default is
substituted for it.

**Independent test**: Configure a gated move onto the declared step, run, and assert zero moves plus one
warning naming the demanded value.

### Tests for User Story 7 (write first, observe failing)

- [ ] T128 [P] [US7] Add to `tests/bash/sink/test_transitions.bats` the `gated` branch: exactly one candidate whose screen marks a field required yields `{"outcome":"gated","gated_field":{…}}` (contract §3)
- [ ] T129 [P] [US7] Add the same `gated` branch to `tests/powershell/sink/Transitions.Tests.ps1`
- [ ] T130 [US7] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` rule M4: with a creation-time default recorded in `field_defaults` for a field of the same name, that value is **not** sent and the gated warning is unchanged (FR-006)
- [ ] T131 [US7] Add the same no-substitution assertion to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`

### Implementation for User Story 7

- [ ] T132 [US7] Implement the `gated` branch in `scripts/bash/sink/jira/transitions.sh`, reading the required-field detail the branch selected in T002 provides (depends on T045)
- [ ] T133 [US7] Mirror the `gated` branch in `scripts/powershell/sink/jira/Transitions.psm1` (depends on T046)
- [ ] T134 [US7] Emit the gated warning verbatim from contract §4 in `scripts/bash/sink/jira/plan_apply.sh` (depends on T132)
- [ ] T135 [US7] Mirror the gated warning in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T133)
- [ ] T136 [P] [US7] Add `tests/conformance/scenarios/us023-gated-move.json` and `us023-gated-move-with-field-default.json`

---

## Phase 10: User Story 8 — A step that cannot be reached from here is named, not forced (Priority: P2)

**Goal**: An unreachable declared step produces no move and one warning naming the current step, the
declared step and what is reachable — never an inferred intermediate move.

**Independent test**: Configure a workflow where the declared step is reachable only through an intermediate
step, run, and assert zero moves plus one warning naming the reachable set.

### Tests for User Story 8 (write first, observe failing)

- [ ] T137 [P] [US8] Add to `tests/bash/sink/test_transitions.bats` the `unreachable` branch and rule M5: zero candidates yields `{"outcome":"unreachable","reachable":[…]}` and no intermediate move is ever performed
- [ ] T138 [P] [US8] Add the same `unreachable` branch to `tests/powershell/sink/Transitions.Tests.ps1`
- [ ] T139 [US8] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` both wordings of contract §4 — the reachable-set form and the empty-set form — plus the near-miss case where the declared step differs only in case or spacing
- [ ] T140 [US8] Add the same three cases to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`

### Implementation for User Story 8

- [ ] T141 [US8] Implement the `unreachable` branch in `scripts/bash/sink/jira/transitions.sh` (depends on T045)
- [ ] T142 [US8] Mirror the `unreachable` branch in `scripts/powershell/sink/jira/Transitions.psm1` (depends on T046)
- [ ] T143 [US8] Emit both unreachable wordings verbatim from contract §4 in `scripts/bash/sink/jira/plan_apply.sh` (depends on T141)
- [ ] T144 [US8] Mirror both wordings in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T142)
- [ ] T145 [P] [US8] Add `tests/conformance/scenarios/us023-unreachable-step.json` and `us023-unreachable-empty-set.json`

**Checkpoint**: all four resolution outcomes are implemented; no silent drop remains anywhere on the path.

---

## Phase 11: User Story 9 — The board advances without the run getting slower (Priority: P2)

**Goal**: A 60-story specification advances in the run it already has. No per-ticket round-trip and no
per-ticket process spawn returns.

**Independent test**: Mirror a specification whose every ticket is due a move; count requests and external
processes; double the story count and assert neither doubles.

### Tests for User Story 9 (write first, observe failing)

- [ ] T146 [P] [US9] Add `tests/bash/sink/test_transitions_budget.bats` asserting budget B1 against the T009 fixture: zero availability requests for a ticket failing any of contract §1 D1–D5, measured against the harness's recorded call log
- [ ] T147 [P] [US9] Add the Pester mirror `tests/powershell/sink/Transitions.Budget.Tests.ps1`
- [ ] T148 [US9] Add to `tests/bash/sink/test_transitions_budget.bats` budget B2 for the branch T002 selected — under branch A, round-trips do not grow one-for-one with the 60-ticket due set; under branch C, no request is issued for a ticket outside the due set (depends on T002)
- [ ] T149 [US9] Add the same B2 assertion to `tests/powershell/sink/Transitions.Budget.Tests.ps1`
- [ ] T150 [US9] Add to `tests/bash/sink/test_transitions_budget.bats` budget B3 using 024's `PATH`-interposed counting shim, in a run **separate** from any timing run: the external-process count is unchanged when the due set doubles (024 contract spawn-budget §4, C4.2)
- [ ] T151 [P] [US9] Add budget B4 to `tests/bash/lib/test_timing.bats`: every request this feature issues is attributed to the `plan` phase, and the per-phase counts sum to the run's total, asserted against the harness's request log rather than the instrument's self-report
- [ ] T152 [P] [US9] Add the same timing-attribution assertion to `tests/powershell/lib/Timing.Tests.ps1`
- [ ] T153 [P] [US9] Add budget B5 to `tests/bash/lib/test_config_phase_status_map.bats`: three declared roles cost one configuration open and one parse, identical to a one-role project, asserted by a counting stand-in
- [ ] T154 [P] [US9] Add the same config-parse assertion to `tests/powershell/lib/Config.PhaseStatusMap.Tests.ps1`

### Implementation for User Story 9

- [ ] T155 [US9] Apply the decode-once shape of `plan_apply.sh:1032–1076` to the resolution loop in `scripts/bash/sink/jira/transitions.sh` and to the due-set assembly in `scripts/bash/sink/jira/plan_apply.sh` — one structured call decoding the whole set, then a pure shell loop, with the `--slurpfile` temp-file spelling that avoids Linux's 128 KiB per-argument cap (depends on T047)
- [ ] T156 [US9] Verify the PowerShell twin already satisfies B3 by doing its structured work in-process, and record the verification in `tests/powershell/sink/Transitions.Budget.Tests.ps1` rather than changing code (024 spawn-budget §preamble)
- [ ] T157 [US9] Route every structured output of `scripts/bash/sink/jira/transitions.sh` through `scripts/bash/lib/output.sh`, never a bare `jq` multi-line write, and keep any path handed to `curl` in its `cygpath -m` spelling (contract §6, AGENTS.md)
- [ ] T158 [P] [US9] Add `tests/conformance/scenarios/us023-sixty-stories-due.json` against the T009 fixture, asserting an identical recorded call sequence on both ports at scale

---

## Phase 12: User Story 10 — The dry run predicts the move exactly (Priority: P2)

**Goal**: The preview names every move it would make and every move it would withhold, touches nothing, and
leaves the recorded run evidence unchanged.

**Independent test**: Run the preview and the real run against the same state and assert the predicted set
of moves and warnings is identical to the performed set, and that the preview performed none.

### Tests for User Story 10 (write first, observe failing)

- [ ] T159 [P] [US10] Add to `tests/bash/commands/test_reconcile_lifecycle.bats` the dry-run twin for each of the four resolution outcomes: predicted moves and warnings identical to the real run against the same state, and zero transition requests recorded in the preview (contract §7 Z4)
- [ ] T160 [P] [US10] Add the same four dry-run twins to `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1`
- [ ] T161 [US10] Add to `tests/bash/lib/test_run_state.bats` invariant S6 under a new event: `--dry-run` neither reads nor writes the state document, so the preview cannot change what the following real run does
- [ ] T162 [US10] Add the same S6 assertion to `tests/powershell/lib/RunState.Tests.ps1`

### Implementation for User Story 10

- [ ] T163 [US10] Confirm resolution runs inside the planning pass in `scripts/bash/sink/jira/plan_apply.sh` so preview and real run share one computation, and add the guard that suppresses only the write — never the read or the decision (depends on T049)
- [ ] T164 [US10] Mirror the preview guard in `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T050)
- [ ] T165 [P] [US10] Add `tests/conformance/scenarios/us023-dry-run-twin.json` — the preview report and the real action set, asserted equal and byte-identical between ports

---

## Phase 13: Polish & Cross-Cutting Concerns

**Purpose**: Idempotency at the new write kind, the documentation FR-040 requires, and the release gates.

- [ ] T166 Extend the live double-run assertion list in `tests/live/test_live_zero_churn.bats` with the transition dimension at the specification and story tiers — Principle II's enforcement test requires this list to grow in the same change that makes a write kind non-zero (contract §7 Z2, Z3)
- [ ] T167 [P] Add `tests/conformance/scenarios/us023-idempotent-rerun.json` — a second run over unchanged state under the same event: 0 created, 0 updated, **0 transitioned**, 0 commented, 0 linked, 0 labeled
- [ ] T168 [P] Correct `docs/08-safety-model.md`: the drift decision table's `transition | emitted` row becomes true at the specification and story tiers for the first time, and the flowchart names where the move is found
- [ ] T169 [P] Update `docs/05-reconcile-flow.md`: show where a move is decided and issued in the pipeline, state how the lifecycle event reaches the run, and add `plan.md` and `hook_event` to the state-phase description
- [ ] T170 [P] Update `docs/02-module-architecture.md`: add `transitions` to the sink layer's flowchart and mindmap, beside `prefetch`
- [ ] T171 [P] Update `docs/VISION.md`: move Part 2 item 3 from *Specified, not shipped* to *Shipped*, drop the "does not yet act on" clause from its Part 1 bullet, and make the mirror-surface diagram's `Status` node solid
- [ ] T172 [P] Complete `commands/speckit.jira.reconcile.md`: document the per-role `phase_status_map` with a worked example, and add `--force` to the Flags list — accepted by `lib/cli.sh` since 021 and never documented (FR-040)
- [ ] T173 [P] Update `docs/07-configuration-and-secrets.md`'s configuration map to show `phase_status_map` as declarable per role
- [ ] T174 Add the CHANGELOG entry in `CHANGELOG.md` and bump `extension.version` in `extension.yml` — the single source of truth for the version, which CI greps to prove the literal appears nowhere else
- [ ] T175 Run `shellcheck -x -P scripts/bash` over `scripts/bash` and `actionlint` over the workflows; both must stay clean
- [ ] T176 Run the full suites — `tests/run-bash.sh`, the Pester suite, and `bash tests/conformance/ci-conformance.sh` — and confirm exit 0 with zero conformance divergence lines
- [ ] T177 Push to `ci/windows-probe` and confirm a green Windows conformance run; a platform-specific outcome is unproven without it (Constitution VI, measurement over emulation)
- [ ] T178 Dogfood per quickstart.md §7: two roles on genuinely different workflows, `/speckit.specify` then `/speckit.plan` — the second changing only `plan.md` — and watch both tiers land on their own declared steps on the second event. Record the wall-clock split from `SPEC_KIT_JIRA_TIMING=1` as evidence, not as a CI assertion

---

## Dependencies & Execution Order

### Phase dependencies

```text
Phase 1 (Setup) ─┬─> Phase 2 (Foundational) ──> Phase 3 (US2) ──> Phase 4 (US1) 🎯
                 │                                                      │
                 │                                    ┌─────────────────┼─────────────────┐
                 │                                    v                 v                 v
                 │                              Phase 5 (US3)    Phase 6 (US4)     Phase 8 (US6)
                 │                                    │                 │           Phase 9 (US7)
                 │                                    │                 v          Phase 10 (US8)
                 │                                    │           Phase 7 (US5)          │
                 │                                    └─────────────────┴────────────────┤
                 │                                                                       v
                 └──> T001/T002 gate T041 only ────────────────────> Phase 11 (US9), Phase 12 (US10)
                                                                              │
                                                                              v
                                                                     Phase 13 (Polish)
```

- **Phase 2 blocks every user story.** The `role` field and the per-role derivations are read by all of them.
- **US2 blocks US1** and everything after it: without the event, no declared step is ever selected.
- **US1 blocks US5–US10.** They are the other three resolution outcomes, the safety regressions over a live
  move, the budgets on a live move, and the preview of a live move.
- **US3 and US4 are independent of each other** and of US6–US8. Once US1 lands, three tracks run in parallel.
- **M1's outcome gates only the bulk form.** T041 (and, through T002's branch selection, T008, T040b,
  T040c, T043, T044, T057a and T148) is where the branch is visible; every other task in every phase is
  independent of it — the point of confining both branches to one module.

### Within each user story

Tests first, observed failing, then implementation, then the conformance scenario that proves both ports
agree. Bash and PowerShell implementation tasks for the same behaviour are paired and marked `[P]` where
they touch different files, which is always.

### Parallel opportunities

| Phase | Parallel set |
| --- | --- |
| 1 | T003, T004, T005, T006, T007, T009 — different fixture and mock files |
| 2 | T010/T011 and T014 — different test files |
| 3 | T021/T022, T027/T028, T030/T031 |
| 4 | T032/T033, T034/T035, T051/T052, T053, T056/T057/T057a |
| 5 | T058/T059, T072/T073 |
| 6 | T074/T075, T080/T081, T082/T083, T083a/T083b, T084/T085, T102/T103/T104 |
| 7 | T105/T106, T111/T112, T117/T118 |
| 8 | T119/T120, T127 |
| 9 | T128/T129, T136 |
| 10 | T137/T138, T145 |
| 11 | T146/T147, T151/T152, T153/T154 |
| 12 | T159/T160, T165 |
| 13 | T167 through T173 — seven independent documentation and scenario files |

## Parallel Example: User Story 4

```text
# Tests, all at once — six different files:
T074 tests/bash/lib/test_config_phase_status_map.bats
T075 tests/powershell/lib/Config.PhaseStatusMap.Tests.ps1
T080 tests/bash/commands/test_reconcile_lifecycle.bats
T081 tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1
T082 tests/bash/sink/test_recognition_parent.bats
T083 tests/powershell/sink/Recognition.Parent.Tests.ps1

# Then the two ports' schema work in parallel:
T086 scripts/bash/lib/config.sh
T087 scripts/powershell/lib/Config.psm1
```

## Implementation Strategy

### MVP first (Setup + Foundational + US2 + US1)

T001–T057a. That is a board that advances: a team declares one mapping, the event reaches the run, and the
ticket moves. It is releasable on its own — the other nine stories protect it, extend it to further tiers,
or prove it did not get slower, but none of them is required for it to deliver value.

Note the MVP does **not** include US3. A test can dispatch an event against a freshly edited `spec.md` and
see the move; a *team* running `/speckit.plan` cannot, because the run short-circuits. US3 is the second
thing to ship, not the tenth.

### Incremental delivery

1. **US2** — the drift machinery becomes reachable in production. Warnings and classifications start
   appearing; nothing moves. Shippable, and worth shipping alone: it makes an existing feature real.
2. **US1** — the move. 🎯 MVP.
3. **US3** — the board follows the lifecycle rather than the edit pattern. Also closes the `plan.md` content
   defect, which is worth shipping for its own sake.
4. **US4** — three roles, three boards.
5. **US5–US8** — the four outcomes and the safety regressions. US6–US8 each add one branch and one warning.
6. **US9, US10** — the budgets and the preview, both regression-shaped.
7. **Polish** — documentation, idempotency at the new write kind, release gates.

### Parallel team strategy

After US1 lands, three tracks are independent: US3 (`lib/run_state.sh`), US4 (`lib/config.sh`,
`sink/jira/recognition.sh`), and US6–US8 (`sink/jira/transitions.sh`). They touch disjoint files. US5 wants
US4 finished, because half its assertions are about the parent.

## Notes

- **Every non-move outcome must carry exactly one warning.** Today `plan_lifecycle` drops the transition
  silently when `transition_id` is empty (`plan_apply.sh:1140`). Replacing that silence is the single most
  important behavioural change in this feature, and T125, T134 and T143 are the three tasks that do it.
- **`engine/drift.sh` is not modified by any task here.** It already returns the decision this feature acts
  on, and reusing it unchanged is what makes a parent's warning wording identical to a story's by
  construction rather than by copying strings.
- **`discovery_task_transition` is not modified either.** It keeps selecting by destination category; the
  new module selects by destination name. Two callers do not justify merging them behind a predicate.
- **Counting runs and timing runs must be separate runs.** 024 measured a 61% distortion when the counting
  shim ran during a timed run. T150 and T151 are deliberately in different runs.
- **Conformance success is silent**: exit 0 and zero "conformance divergence" lines is the pass signal.
- **The bats runner needs `-r`** or it silently runs nothing; prefer `tests/run-bash.sh` for everyday use
  and `--since <ref>` for the inner loop.
