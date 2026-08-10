---

description: "Task list for 023 — Each Tier Advances Along Its Own Declared Workflow"
---

# Tasks: Each Tier Advances Along Its Own Declared Workflow

**Input**: Design documents from `/specs/023-advance-board-position/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: **REQUIRED, not optional.** Constitution Principle XIII makes this project strictly
Red-Green-Refactor: *"No implementation task may be planned without its test task preceding it in
`tasks.md`."* Every test task below is written first, **observed to FAIL**, and validated by the operator
before the implementation task that turns it green.

**Organization**: grouped by user story so each is independently implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable — a different file, no dependency on an incomplete task
- **[Story]**: US1…US7, mapping to the user stories in [spec.md](spec.md)
- Every task names an exact path

## Path Conventions

Twin native ports. Every behaviour lands in both:

- **Bash** — `scripts/bash/{lib,engine,sink/jira,commands}/`, tested by `bats` under `tests/bash/`
- **PowerShell** — `scripts/powershell/{lib,sink/jira,commands}/`, tested by `Pester` under `tests/powershell/`
- **Shared** — `tests/conformance/{scenarios,fixtures,mock-jira}/` proves the two byte-equivalent

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: the fixtures and doubles every later phase measures against. Nothing here changes product code.

- [ ] T001 [P] Capture the pre-change baseline in `tests/conformance/scenarios/us023-baseline-no-mapping.json`: a full reconcile of a fixture that declares **no** `phase_status_map`, recording the exact request sequence. FR-017 and SC-003 promise this sequence is unchanged by the feature; a baseline captured *before* the change makes that measurable instead of asserted
- [ ] T002 [P] Create the conformance fixture `tests/conformance/fixtures/repo-with-role-workflows/` — one spec with a specification-tier parent, 3 stories and a `tasks.md`, plus a `config.yml` declaring shape B with **different** steps per role (`specification: after_plan → "Building"`, `story: after_plan → "In Progress"`), per [contracts/role-lifecycle-config.md](contracts/role-lifecycle-config.md) §2
- [ ] T003 [P] Create the conformance fixture `tests/conformance/fixtures/repo-with-legacy-mapping/` — a parent, stories and sub-tasks, with a `config.yml` declaring the **role-blind** shape A exactly as it ships today. This is the FR-013 upgrade regression's fixture
- [ ] T004 Extend the Bash double `tests/conformance/mock-jira/curl-shim.sh` to serve `GET /issue/{key}/transitions?expand=transitions.fields` **per role**: the offered moves depend on the issue's type and current status, so one fixture can express an Epic on a delivery workflow and a Story on a development workflow. Include the three unresolvable shapes — two moves onto one step, one move whose screen carries a required field, and no move onto the declared step
- [ ] T005 Extend the PowerShell double `tests/conformance/mock-jira/mock-server.ps1` identically. Both doubles MUST answer the same request with the same body for the same fixture, or every conformance scenario below measures the doubles rather than the ports
- [ ] T006 [P] Document the per-role workflow fixture keys the doubles now read, alongside the existing mock configuration documentation in `tests/conformance/mock-jira/`, so the next scenario author does not reverse-engineer T004 and T005

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the configuration shape and the availability reader. Every user story needs both.

**⚠️ CRITICAL**: no user story work begins until this phase is complete and its tests are green.

### Tests (write first, observe failing)

- [ ] T007 [P] Write failing normalisation tests in `tests/bash/lib/test_config_role_workflows.bats`: shape A normalises to `{story:{…}}` **and nothing else**; shape B normalises per role; a role that declared nothing is **absent**, never an empty object; `phase_status_map: {}` is shape-neutral. Per [contracts/role-lifecycle-config.md](contracts/role-lifecycle-config.md) §2/§3/§5 and [data-model.md](data-model.md) §1
- [ ] T008 [P] Write failing validation tests in the same file for each row of contract §4 — unknown role name, role value not an object, step name not a string, shape A value not a string, and the two shapes mixed. Each message names the project index and the offending key, in the style of the existing validator at `scripts/bash/lib/config.sh:753`
- [ ] T009 [P] Write the failing test, in the same file, that an event key the host does not emit is **inert, not an error** (contract §4) — rejecting it would break a config the moment the host renames an event
- [ ] T010 [P] Write the Pester twins of T007–T009 in `tests/powershell/lib/Config.RoleWorkflows.Tests.ps1`. Import the module under test **without** `-Force`: a forced import from a sink module clobbers the caller's scope and the failure does not reproduce in a single file
- [ ] T011 [P] Write failing tests for the new availability reader in `tests/bash/sink/test_discovery_lifecycle_transitions.bats`, one per row of [contracts/lifecycle-transition.md](contracts/lifecycle-transition.md) §5: one ungated candidate → `transition_id` set; one gated candidate → `transition_id` null and `withheld_field` naming it; two or more → both listed, `transition_id` null; none → `transition_id` null and `reachable` naming the offered destinations. Add the §4 test that a step name differing only in letter case or surrounding space is **not** a match
- [ ] T012 [P] Write the Pester twin in `tests/powershell/sink/Discovery.LifecycleTransitions.Tests.ps1`
- [ ] T013 Run T007–T012 and **observe every one fail**, then have the operator validate the failures. This is the Red gate Principle XIII requires; an implementation task started before it is a review rejection

### Implementation

- [ ] T014 Implement shape detection, normalisation and validation in `scripts/bash/lib/config.sh`, extending the existing `phase_status_map` validation at `:753`. Discrimination is structural — never positional, never by a marker key (contract §3)
- [ ] T015 Implement the twin in `scripts/powershell/lib/Config.psm1`, extending the validation at `:872`. The two ports MUST emit byte-identical messages
- [ ] T016 Implement `discovery_lifecycle_transition` in `scripts/bash/sink/jira/discovery.sh` as a **sibling** of `discovery_task_transition` (`:472`), selecting candidates on the destination's `name` rather than its `statusCategory`, and returning `{candidates, transition_id, withheld_field, reachable}` per [data-model.md](data-model.md) §3. **Leave `discovery_task_transition` untouched** — feature 012's contract is shipped and tested
- [ ] T017 Implement the twin in `scripts/powershell/sink/jira/Discovery.psm1`
- [ ] T018 Run `tests/run-bash.sh --since HEAD~1` and the Pester suite; confirm T007–T012 are green and nothing else regressed

**Checkpoint**: the configuration accepts three workflows and the reader can find a move by name. No ticket moves yet.

---

## Phase 3: User Story 1 — A declared mapping moves the ticket (Priority: P1) 🎯 MVP

**Goal**: a team declaring a mapping sees its board advance. The whole point of the feature.

**Independent Test**: declare a mapping for one role, place a ticket one agreed step behind, run under the matching lifecycle event, and observe the ticket standing at the declared step.

### Tests for User Story 1 (write first, observe failing)

- [ ] T019 [US1] Rewrite the pinning test at `tests/bash/commands/test_reconcile_lifecycle.bats:123`. Its current name — *"zero transition requests in every scenario — this release evaluates the rules but never moves a ticket's status"* — becomes false with this feature. Replace it with the narrower assertion that **a project declaring no mapping issues zero transition requests**, preserving its intent, and correct the file header comment (`:1-5`) which still cites "research R9" and "no ticket's status is ever moved". Per research R1: rewritten in the change that makes it false, never deleted quietly
- [ ] T020 [P] [US1] Write the failing move test in `tests/bash/commands/test_reconcile_lifecycle_move.bats`: shape-A mapping, a recognised story at "To Do", `after_plan → "In Progress"`, one ungated move available. Assert exactly one `GET …/transitions?expand=transitions.fields`, exactly one `POST …/transitions`, and `transitioned: 1` in the summary
- [ ] T021 [P] [US1] Write the failing zero-churn test in the same file: re-run unchanged and assert **zero** transitions **and zero availability reads** — a ticket already at its declared step is never even asked about (FR-008, contract §9)
- [ ] T022 [P] [US1] Write the failing inert-cost test in the same file: no lifecycle event, and separately no declared mapping, each issuing **zero** availability reads (FR-022, contract §1)
- [ ] T023 [P] [US1] Write the failing fail-closed test in `tests/bash/commands/test_reconcile_lifecycle_faults.bats`: the availability read returns 401, then 403, then 5xx. Each asserts **no move and no content write** for the affected specification, the documented non-zero exit, and nothing on stdout from the reader (FR-020, contract §3)
- [ ] T024 [P] [US1] Write the failing refusal test in the same file: the move POST is rejected because the ticket moved meanwhile. Assert the refusal is reported naming the ticket, and — from the **call log**, the only place it is provable — that there was no retry, no second availability read, and no other candidate attempted (FR-021, contract §6)
- [ ] T025 [P] [US1] Write the failing top-level count test in `tests/bash/commands/test_reconcile_summary_counts.bats`: `transitioned` appears in the top-level counts, is derived from the emitted actions, and is distinct from the existing nested `tasks.transitioned` (research R7, [data-model.md](data-model.md) §5). This covers the **machine-readable** half of FR-024 only; T107 covers the prose half
- [ ] T026 [P] [US1] Write the Pester twins of T020–T025 in `tests/powershell/commands/Reconcile.LifecycleMove.Tests.ps1` and `Reconcile.LifecycleFaults.Tests.ps1`
- [ ] T027 [P] [US1] Add the conformance scenario `tests/conformance/scenarios/us023-story-advance.json` over the fixture from T002, asserting a byte-identical `--json` summary **and an identical request sequence** across both ports. Its expected prose output carries the `Transitioned:` line of T108 from the start — adding it later would be an unrelated diff of the scenario
- [ ] T105 [P] [US1] Extend `tests/bash/hooks/test_hook_resilience.bats:90` — *"every bridge fault leaves the host exit code untouched under optional:false"* — with the fault this feature adds: the availability read failing (401 / 403 / 5xx) under `SPEC_KIT_JIRA_HOOK_CONTEXT=1` still leaves the host at exit 0 with one WARNING. That test **enumerates** its three faults rather than sweeping them, so a new fault kind stays invisible to it until it is named. Add the same assertion for each of the five new warnings of [data-model.md](data-model.md) §6: a withheld, ambiguous, gated, unreachable or refused move is a WARNING inside a hook and never a non-zero host exit (FR-025, Principle III's enforcement test)
- [ ] T106 [P] [US1] Write the Pester twin of T105 in `tests/powershell/hooks/HookResilience.Tests.ps1`, and extend the in-file port-parity check at `tests/bash/hooks/test_hook_resilience.bats:162` (*"the PowerShell port downgrades a hook-context failure identically"*) to cover the availability-read fault, so both ports are proven to downgrade the new faults the same way
- [ ] T107 [P] [US1] Write the failing prose-summary test in `tests/bash/commands/test_reconcile_summary_counts.bats`: the default (non-`--json`) report carries `Transitioned: <n>` on its own line, positioned between the `Created: …` and `Recognised: …` lines, and is **absent entirely** from a command whose summary carries no `transitioned` count. FR-024 requires the count in both reports and T025 covers only the machine-readable half
- [ ] T028 [US1] Run T019–T027 and T105–T107 and **observe them fail**; operator validates the Red gate

### Implementation for User Story 1

- [ ] T029 [US1] In `scripts/bash/sink/jira/plan_apply.sh`, have `plan_lifecycle` consume the resolved `move` from the ticket entry and emit the transition through the **existing** `_plan_transition_action` (`:973`) — the guard at `:1081` finally becomes satisfiable. `plan_lifecycle_tasks` is not touched
- [ ] T030 [US1] In `scripts/bash/commands/reconcile.sh`, resolve the declared step for the run's lifecycle event and issue the availability read **lazily**, gated on **every** condition of [contracts/lifecycle-transition.md](contracts/lifecycle-transition.md) §1 in the order §1 states them — including the impediment-marker check and the sub-task completion-precedence check, which the request-cost reasoning in research R8 does not enumerate — during the planning pass and **before any action is applied**. That ordering is what makes T023's fail-closed assertion true (research R8)
- [ ] T031 [US1] In `scripts/bash/commands/reconcile.sh` (summary assembly, `~:1875`), add the top-level `transitioned` count, derived by counting the emitted transition actions so it can never disagree with the action list. Leave the nested `tasks.transitioned` (`:1848`) alone
- [ ] T032 [US1] Implement the refusal path: a rejected move is reported and **not** retried, re-read, or substituted (contract §6)
- [ ] T033 [US1] Implement the twins of T029–T032 in `scripts/powershell/sink/jira/PlanApply.psm1` and `scripts/powershell/commands/Reconcile.psm1`
- [ ] T034 [US1] Assemble the new warning strings through the port's output helper (`scripts/bash/lib/output.sh`), never a direct `jq` call — the Windows `jq` build emits CRLF on multi-line output, and these warnings are multi-line prose (research R10, `docs/10-windows-portability.md`)
- [ ] T108 [US1] Implement the `Transitioned:` prose line in `summary_render_prose` (`scripts/bash/lib/output.sh:225`) and its PowerShell twin, guarded by `has("transitioned")` on the counts object so no other command's summary changes by a byte ([data-model.md](data-model.md) §5, FR-024). This is prose assembled through the output helper — precisely the surface `docs/10-windows-portability.md` warns about — and both ports must emit it byte-identically
- [ ] T035 [US1] Run `tests/run-bash.sh`, the Pester suite and `bash tests/conformance/ci-conformance.sh`; confirm green

**Checkpoint**: a board advances. US1 is shippable on its own.

---

## Phase 4: User Story 2 — Each tier follows its own workflow (Priority: P1)

**Goal**: an Epic on a delivery workflow and a Story on a development workflow each advance along their own steps.

**Independent Test**: declare two different mappings in one project, run one event, and assert each tier landed on its own declared step.

### Tests for User Story 2 (write first, observe failing)

- [ ] T036 [P] [US2] Write the failing two-workflow test in `tests/bash/commands/test_reconcile_lifecycle_roles.bats` over the T002 fixture: the parent stands at "Building", every story at "In Progress", and **no ticket was evaluated against the other role's step name** (FR-010, FR-011)
- [ ] T037 [P] [US2] Write the failing undeclared-role test in the same file: with only the story role declared, stories advance, the parent is not moved, and **no warning is raised about the parent** — an undeclared role is silent, not withheld (FR-012)
- [ ] T038 [P] [US2] Write the failing upgrade regression in `tests/bash/commands/test_reconcile_lifecycle_legacy.bats` over the T003 fixture: a role-blind shape A moves stories and moves **0 parents and 0 sub-tasks**. Assert on the **call log**, not the summary — the summary would look identical if a parent had been moved (FR-013, SC-004)
- [ ] T039 [P] [US2] Write the failing task-role-inert test in `tests/bash/commands/test_reconcile_lifecycle_task_role.bats`: a `task` workflow declared while sub-task mirroring is **off** creates and moves nothing, emits exactly one note that the declaration has no effect, and leaves the exit code unchanged (FR-015, contract §7)
- [ ] T040 [P] [US2] Write the failing precedence test in the same file: with the tier **on**, a **checked** task's sub-task is moved by the completion pass with its existing wording and the declared mapping does not also act on it; an **unchecked** task's sub-task follows the declared mapping (FR-016, contract §7)
- [ ] T041 [P] [US2] Write the Pester twins in `tests/powershell/commands/Reconcile.LifecycleRoles.Tests.ps1`
- [ ] T042 [P] [US2] Add the conformance scenarios `tests/conformance/scenarios/us023-two-workflows.json` and `us023-legacy-shape.json`
- [ ] T043 [US2] Run T036–T042 and **observe them fail**; operator validates

### Implementation for User Story 2

- [ ] T044 [US2] In `scripts/bash/sink/jira/plan_apply.sh`, give `plan_lifecycle` an **explicit ordered ticket list** carrying each entry's `local_id` and `role`, instead of deriving the list from `doc.stories`. That derivation is what made the parent unreachable; every safety rule inside the loop is unchanged (research R5, [data-model.md](data-model.md) §2)
- [ ] T045 [US2] In `scripts/bash/commands/reconcile.sh`, include the specification-tier parent's `bound` entry in that list — it already carries the same `key`, `current`, `status`, `flagged` and `origin` fields a story's entry has
- [ ] T046 [US2] In `scripts/bash/commands/reconcile.sh`, resolve `target`, `category` and `order` **per role**, calling the existing `config_classify_statuses` (`lib/config.sh:639`) and `config_phase_status_targets` (`:659`) once per role with that role's mapping. Their signatures do not change, and `engine/drift.sh` is not touched (research R4)
- [ ] T047 [US2] Implement the task-role gate: the declared mapping is offered only to sub-tasks with **no completion outcome** in this run; `plan_lifecycle_tasks` stays exactly as it is (FR-016, contract §7)
- [ ] T048 [US2] Implement the "declaration has no effect" note for a `task` mapping while the tier is disabled (FR-015)
- [ ] T049 [US2] Implement the twins of T044–T048 in `scripts/powershell/sink/jira/PlanApply.psm1` and `scripts/powershell/commands/Reconcile.psm1`
- [ ] T050 [US2] Run the full suites and the conformance corpus; confirm green

**Checkpoint**: three roles, three workflows, and an existing configuration still means exactly the story role.

---

## Phase 5: User Story 3 — Every existing protection keeps its meaning (Priority: P1)

**Goal**: the safety rules behave exactly as before — now that they finally have consequences.

**Independent Test**: run the existing safety corpus unchanged and assert identical decisions and identical warning wording, then repeat it against a parent.

### Tests for User Story 3 (write first, observe failing)

- [ ] T051 [P] [US3] Write the wording-regression test in `tests/bash/commands/test_reconcile_lifecycle_wording.bats`: every existing drift, halt, flagged and blocker warning string is asserted **verbatim**. Any edit to an existing string is a regression, not an improvement (FR-018)
- [ ] T052 [P] [US3] Write the failing parent-parity test in `tests/bash/commands/test_reconcile_lifecycle_parent.bats`: a parent in each of the unclassified, halted, ahead-of-spec, flagged and blocked situations produces the **same decision and the same wording** as a story in that situation (FR-014)
- [ ] T053 [P] [US3] Write the failing halt test: a halted ticket has **every** write suppressed, including the move, and its content PUT does not happen (FR-018)
- [ ] T054 [P] [US3] Write the failing withhold test: a withheld move does **not** suppress the content update, on every unresolvable outcome (FR-019, contract §8)
- [ ] T055 [P] [US3] Write the failing backward-pull test: a backward move is refused by default and **performed** under `--on-drift=proceed` — the first time that flag has ever moved anything (FR-018)
- [ ] T056 [P] [US3] Write the failing independence test: one ticket's ambiguity, gate or refusal never suppresses another ticket's move, including between a parent and its own stories (FR-019, contract §8)
- [ ] T057 [P] [US3] Write the Pester twins in `tests/powershell/commands/Reconcile.LifecycleWording.Tests.ps1`
- [ ] T058 [US3] Run T051–T057 and **observe them fail**; operator validates

### Implementation for User Story 3

- [ ] T059 [US3] Reconcile any divergence T051–T056 expose in `scripts/bash/sink/jira/plan_apply.sh` — the expectation is that most pass once US1 and US2 land, and each that does not marks a place where the new write path changed a decision it should only have consumed
- [ ] T060 [US3] Implement the twin corrections in `scripts/powershell/sink/jira/PlanApply.psm1`
- [ ] T061 [US3] Run the full safety corpus on both ports; confirm zero wording drift

**Checkpoint**: the rules that protect a human's board still protect it, now that they can act.

---

## Phase 6: User Story 4 — An ambiguous workflow is reported, never guessed (Priority: P1)

**Goal**: two moves onto one step produce no move and one warning naming both.

**Independent Test**: configure two candidate moves, run, assert zero moves and one warning listing both.

### Tests for User Story 4 (write first, observe failing)

- [ ] T062 [P] [US4] Write the failing ambiguity test in `tests/bash/commands/test_reconcile_lifecycle_ambiguous.bats`: two offered moves land on the declared step. Assert zero moves, exactly one warning naming the ticket, its role, the step and **every** candidate, and that the content PUT still happened (FR-004, FR-019)
- [ ] T063 [P] [US4] Write the failing stability test in the same file: a later run over the unchanged workflow raises the **same single warning** and still performs no move
- [ ] T064 [P] [US4] Write the Pester twin in `tests/powershell/commands/Reconcile.LifecycleAmbiguous.Tests.ps1`
- [ ] T065 [P] [US4] Add the conformance scenario `tests/conformance/scenarios/us023-ambiguous-candidates.json`, pinning the warning byte-for-byte across both ports
- [ ] T066 [US4] Run T062–T065 and **observe them fail**; operator validates

### Implementation for User Story 4

- [ ] T067 [US4] Implement the ambiguity outcome in `scripts/bash/sink/jira/plan_apply.sh` with the wording of [data-model.md](data-model.md) §6. **No preference is invented by any rule** — not a naming convention, not an ordering, not a tie-break option (contract §5, FR-017 forbids the configuration key a tie-break would need)
- [ ] T068 [US4] Implement the twin in `scripts/powershell/sink/jira/PlanApply.psm1`

**Checkpoint**: an ambiguous workflow is a sentence a human can act on, not a coin flip with side effects.

---

## Phase 7: User Story 5 — A move that demands a value stands down and names it (Priority: P1)

**Goal**: a gated transition screen is refused, and the demanded field is named.

**Independent Test**: configure a gated move onto the declared step, run, assert zero moves and one warning naming the field.

### Tests for User Story 5 (write first, observe failing)

- [ ] T069 [P] [US5] Write the failing gated-move test in `tests/bash/commands/test_reconcile_lifecycle_gated.bats`: one candidate whose screen requires a field. Assert zero moves and one warning naming the ticket, its role, the step and the field (FR-005)
- [ ] T070 [P] [US5] Write the failing no-substitution test in the same file: with a **creation-time default recorded for a field of the same name**, assert that value is **not** sent and the outcome is still the warning of T069 (FR-006). This is the assertion that keeps wrong data out of an audited workflow field
- [ ] T071 [P] [US5] Write the Pester twin in `tests/powershell/commands/Reconcile.LifecycleGated.Tests.ps1`
- [ ] T072 [P] [US5] Add the conformance scenario `tests/conformance/scenarios/us023-gated-transition.json`
- [ ] T073 [US5] Run T069–T072 and **observe them fail**; operator validates

### Implementation for User Story 5

- [ ] T074 [US5] Implement the gated outcome in `scripts/bash/sink/jira/plan_apply.sh`, consuming the reader's `withheld_field`. The transition POST carries `{transition:{id}}` and **nothing else** — no field values accompany a move (contract §6, [data-model.md](data-model.md) §4)
- [ ] T075 [US5] Implement the twin in `scripts/powershell/sink/jira/PlanApply.psm1`

**Checkpoint**: an enterprise workflow that demands a value gets a question, never an invented answer.

---

## Phase 8: User Story 6 — A step that cannot be reached from here is named, not forced (Priority: P2)

**Goal**: a target reachable only through an intermediate step is refused, with the reachable set named.

**Independent Test**: configure a workflow where the declared step needs an intermediate hop, run, assert zero moves and one warning naming what *is* reachable.

### Tests for User Story 6 (write first, observe failing)

- [ ] T076 [P] [US6] Write the failing unreachable test in `tests/bash/commands/test_reconcile_lifecycle_unreachable.bats`: no offered move lands on the declared step. Assert zero moves, no intermediate move, and one warning naming the ticket, its role, the current step, the declared step and the reachable set (FR-007)
- [ ] T077 [P] [US6] Write the failing not-in-workflow test in the same file: the declared step names something this role's workflow does not contain at all, producing the same outcome and telling the reader the step was not found among the reachable ones
- [ ] T078 [P] [US6] Write the failing near-miss test in the same file: a declared step differing from a real one only by letter case or surrounding space is reported unreachable, **never** silently accepted (contract §4)
- [ ] T079 [P] [US6] Write the Pester twin in `tests/powershell/commands/Reconcile.LifecycleUnreachable.Tests.ps1`
- [ ] T080 [P] [US6] Add the conformance scenario `tests/conformance/scenarios/us023-unreachable-step.json`
- [ ] T081 [US6] Run T076–T080 and **observe them fail**; operator validates

### Implementation for User Story 6

- [ ] T082 [US6] Implement the unreachable outcome in `scripts/bash/sink/jira/plan_apply.sh`, reporting the `reachable` set the reader already returns — the useful message costs no extra request (research R9)
- [ ] T083 [US6] Implement the twin in `scripts/powershell/sink/jira/PlanApply.psm1`

**Checkpoint**: a multi-step workflow gets an explanation, not an inferred path with unseen side effects.

---

## Phase 9: User Story 7 — The dry run predicts the move exactly (Priority: P2)

**Goal**: the preview names every move it would make and every one it would withhold, and touches nothing.

**Independent Test**: run the preview and the real run against the same state and assert identical predicted and performed sets.

### Tests for User Story 7 (write first, observe failing)

- [ ] T084 [P] [US7] Write the failing preview test in `tests/bash/commands/test_reconcile_lifecycle_dryrun.bats`: for each state of US1 and US4–US6, assert the predicted moves and warnings are identical to the real run's — same tickets, same roles, same step pairs, same wording — and that the call log contains the availability reads but **zero** `POST …/transitions` (FR-023, contract §10)
- [ ] T085 [P] [US7] Write the Pester twin in `tests/powershell/commands/Reconcile.LifecycleDryRun.Tests.ps1`
- [ ] T086 [P] [US7] Add the conformance scenario `tests/conformance/scenarios/us023-dry-run-predicts.json`
- [ ] T087 [US7] Run T084–T086 and **observe them fail**; operator validates

### Implementation for User Story 7

- [ ] T088 [US7] Implement the preview path in `scripts/bash/commands/reconcile.sh`: the availability read **is** performed under `--dry-run` — it is a read, and the prediction is worthless without it — and no move is issued (contract §10)
- [ ] T089 [US7] Implement the twin in `scripts/powershell/commands/Reconcile.psm1`

**Checkpoint**: an operator can see what the feature would do to an unfamiliar board before letting it.

---

## Phase 10: Polish & Cross-Cutting Concerns

- [ ] T090 Extend the live double-run assertion in `tests/live/` to cover `transitioned`. Principle II names it among the write kinds a second run must leave at zero and requires the assertion list to be extended **in the same change** that makes a write kind reachable — this is an obligation, not an option (research R7)
- [ ] T091 [P] Correct `docs/08-safety-model.md`: the decision table at `:161` states `transition` → "emitted", which the code did not do. Make it accurate and add the five outcomes of [contracts/lifecycle-transition.md](contracts/lifecycle-transition.md) §5 (FR-027)
- [ ] T092 [P] Correct `docs/VISION.md`: Part 1 claims the bridge "advances the ticket on the board" and item 3 is marked *Shipped*. Both describe what did not exist. Restate them against what now ships, and restate item 3's remaining envisioned half — proposing the mapping at configuration time — as the follow-up it now is, with **three** mappings to propose rather than one (FR-027)
- [ ] T093 [P] Document the role-keyed shape in `docs/07-configuration-and-secrets.md` with a worked two-workflow example, stating plainly that the role-blind shape means the story role (FR-026, contract §8)
- [ ] T094 [P] Update `docs/05-reconcile-flow.md` so the reconcile flow shows the availability read and the move, gated on the conditions of contract §1
- [ ] T095 [P] Add the CHANGELOG entry under Unreleased, naming both halves: the board now advances, and the mapping is per hierarchy role (Principle XII)
- [ ] T096 Verify the 80% statement-coverage gate on both ports, and that the drift decision path — a named critical path — sits near total coverage (Principle XIII)
- [ ] T097 [P] Run `find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +` and `actionlint`; both must be clean. Scope the shellcheck run to `scripts/bash` — a whole-tree scan is roughly 1900 lines of host-script noise
- [ ] T098 Run the full `tests/run-bash.sh`, the full Pester suite, and `bash tests/conformance/ci-conformance.sh`. Conformance success is **silent**: exit 0 and zero lines containing `conformance divergence`; there is no pass banner
- [ ] T099 Push to `ci/windows-probe` and confirm a green run before claiming the platform behaviour. This feature assembles multi-line prose from tracker data, which is precisely where the Windows CRLF quirks bite. Principle VI: a model of Windows is not Windows, and results arrive as check-run annotations rather than job logs. **One retry maximum** on a `windows-latest` flake, then hand the result back
- [ ] T100 Walk `quickstart.md` end to end and confirm every one of its eight scenarios behaves as written
- [ ] T101 Dogfood against a real Jira instance on **two tiers** — declare two workflows, run the lifecycle, and watch the Epic and its stories each land on their own declared step. A single-tier dogfood does not exercise the change that motivated the feature (Principle XII)

---

## Phase 11: Convergence

- [ ] T102 Run `/speckit-analyze` over `spec.md`, `plan.md` and this file, and resolve any inconsistency it reports
- [ ] T103 Re-read the Constitution Check in [plan.md](plan.md) against the **shipped** code and confirm all sixteen verdicts still hold — particularly Principle VIII, whose proof is that the `scripts/bash/engine/` diff is empty
- [ ] T104 Confirm no functional requirement is unimplemented and no shipped behaviour is unrequired: every new configuration key, field and warning traces to an FR, and every FR traces to a test (Principle XV)

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 (Setup)**: no dependencies — start immediately
- **Phase 2 (Foundational)**: needs Phase 1's doubles — **blocks every user story**
- **Phase 3 (US1)**: needs Phase 2. Delivers the MVP alone
- **Phase 4 (US2)**: needs Phase 3 — it extends the write path US1 introduces to a second and third role
- **Phase 5 (US3)**: needs Phase 4 — parent parity cannot be asserted before the parent is evaluated
- **Phases 6–8 (US4, US5, US6)**: need Phase 3 only. **Mutually independent** — three different outcomes of the same reader, in three different test files
- **Phase 9 (US7)**: needs Phase 3; asserts more once 6–8 land
- **Phase 10 (Polish)**: needs every story that is being shipped
- **Phase 11 (Convergence)**: last

### The one hard sequencing rule

**Within every phase, the test tasks come first and are observed to fail.** Principle XIII makes an
implementation task planned ahead of its test a review rejection, and the operator validates each Red gate
(T013, T028, T043, T058, T066, T073, T081, T087).

### Parallel opportunities

- T001–T003 and T006 in parallel; T004 and T005 touch the two doubles and may run in parallel with each other
- All of T007–T012 in parallel — six different test files
- T105–T107 in parallel with T020–T027: three different test files again (`test_hook_resilience.bats`, its
  Pester twin, `test_reconcile_summary_counts.bats`). Their implementations do not collide either — T108
  lands in `lib/output.sh`, which no other task in this phase touches
- The two ports are always different files: every Bash/PowerShell twin pair is parallelizable
- **US4, US5 and US6 are the largest parallel win**: three developers, three outcomes, three test files, no shared implementation beyond the reader Phase 2 already delivered
- T091–T095 (documentation and CHANGELOG) all in parallel

---

## Parallel Example: Phase 2

```bash
# Six failing test files, written together:
Task: "Normalisation tests in tests/bash/lib/test_config_role_workflows.bats"          # T007
Task: "Validation tests in tests/bash/lib/test_config_role_workflows.bats"             # T008
Task: "Inert-unknown-event test in the same file"                                       # T009
Task: "Pester twins in tests/powershell/lib/Config.RoleWorkflows.Tests.ps1"            # T010
Task: "Reader outcomes in tests/bash/sink/test_discovery_lifecycle_transitions.bats"   # T011
Task: "Pester twin in tests/powershell/sink/Discovery.LifecycleTransitions.Tests.ps1"  # T012

# Then the two implementations, in parallel:
Task: "Shape detection and validation in scripts/bash/lib/config.sh"                    # T014
Task: "The twin in scripts/powershell/lib/Config.psm1"                                  # T015
```

---

## Implementation Strategy

### MVP first (Setup + Foundational + US1)

1. Phase 1 — fixtures and doubles
2. Phase 2 — configuration shape and the reader **(blocks everything)**
3. Phase 3 — US1
4. **STOP and VALIDATE**: a declared mapping moves a story; a re-run moves nothing and asks nothing; an
   unmapped project's request sequence matches T001's baseline byte for byte
5. This is shippable. A team's board advances, on the story tier, with every existing protection intact

### Incremental delivery

1. MVP → US2 (three roles) → US3 (parity and wording) → US4/US5/US6 (the three unresolvable workflows) → US7 (preview)
2. US4, US5 and US6 each turn a silent nothing into a sentence a human can act on. Shipping US1 without
   them means an enterprise workflow fails quietly, so treat them as part of the first real release even
   though US1 is technically shippable alone

### Parallel team strategy

1. Everyone on Phase 1 + Phase 2
2. One developer takes US1 through to green — it is the spine
3. Then: developer A on US2, developers B/C/D on US4/US5/US6 in parallel, and US3's wording regression run
   continuously by whoever is not blocked
4. US7 last, because it asserts against whatever the others produced

---

## Notes

- `[P]` = a different file with no incomplete dependency
- `bats -r` is load-bearing: without `-r` the suite silently runs nothing. Prefer `tests/run-bash.sh`, and
  `tests/run-bash.sh --since <ref>` for the inner loop
- Never pipe the test runner; grep output is rewritten before pipes and redirects, so verify assertions with
  `awk` rather than a grep pipeline
- Tests identify processes, files and ports by an identifier they recorded themselves — never by a name
  pattern or a machine-wide scan (Principle XIII's isolation rule)
- Commit after each task or logical group; stop at any checkpoint to validate a story independently
- **FR-016 remains the one decided-not-inherited interaction** (a task's completion outranks the declared
  mapping on its own sub-task). It is exercised by T040. If it is revisited, T040 and T047 are the only
  tasks that change
