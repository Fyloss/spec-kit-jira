---
description: "Task list for 010 — The Operator Declares Which Issue Types Carry the Mirror"
---

# Tasks: The Operator Declares Which Issue Types Carry the Mirror

**Input**: Design documents in `/specs/010-jira-hierarchy-mapping/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/role-mapping.md](./contracts/role-mapping.md), [quickstart.md](./quickstart.md)

**Tests**: NOT optional here. Constitution XIII mandates TDD with ≥80% coverage, and the repository's bug-fix policy requires a failing test reproducing the defect before the fix. Every phase below leads with its tests.

**Organization**: Tasks are grouped by user story so each is independently implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: which user story the task serves (US1…US5)
- Every task names its file paths

## Path Conventions

Twin native ports, file-for-file. **Constitution VI requires both ports to change in the same commit**, so a task that touches behaviour names its bash file *and* its PowerShell twin, and is done only when both are done. That is why fewer tasks are marked `[P]` than the file count suggests.

- Bash port: `scripts/bash/…`, tests in `tests/bash/…`
- PowerShell port: `scripts/powershell/…`, tests in `tests/powershell/…`
- Cross-port corpus: `tests/conformance/…`

---

## Phase 1: Setup — Make the Consumer's Blockage Observable

**Purpose**: Nothing about this feature is testable against the current mock. No fixture has more than one type at a level *and* more than one at the level below, so the two-simultaneous-ambiguities case — the consumer's actual state — cannot be reproduced. Phase 1 ends with the blockage red on both ports.

- [X] T001 [P] Add `tests/conformance/mock-jira/fixtures/createmeta-issuetypes-consumer.json` reproducing the consumer instance: `Epic` and `Service Category` at level 1; `Tâche`, `Story`, `Defect`, `Improvement Action`, `Test`, `Test Set`, `Test Execution`, `Precondition`, `Release`, `Incident SNOW`, `Objective`, `Service`, `Problem SNOW` at level 0; `Sous-tâche` and `Sub Test Execution` at level -1 with `subtask: true`. Real names, non-ASCII included — this is the one fixture that proves SC-001 (research R11)
- [X] T002 [P] Add `tests/conformance/mock-jira/fixtures/createmeta-fields-consumer.json` giving the consumer types a field schema with no unsatisfiable mandatory field, so the mandatory gate is not what refuses during Phase 1–4 (mirrors `createmeta-fields-hier-ambiguous.json`)
- [X] T003 [P] Add `tests/conformance/mock-jira/configs/consumer-hierarchy.json` selecting the `consumer` issue-type style, following `ambiguous-hierarchy.json`
- [X] T004 Add `tests/conformance/fixtures/repo-with-consumer-hierarchy/` — a two-user-story `spec.md` plus `.specify/jira/config.yml` routing to the consumer project with **no** `hierarchy` declaration. This is the fixture that must refuse (depends on T001–T003)
- [X] T005 Add `tests/conformance/fixtures/repo-with-declared-hierarchy/` — the same instance with `hierarchy: {specification: Epic, story: Story}` declared, plus a `config.local.yml` in the current binding shape. This is the fixture that must configure and mirror (depends on T004)
- [X] T006 Write the failing test for the blockage — configuring `repo-with-consumer-hierarchy` exits `4` with `parent-level-ambiguous` naming `Epic, Service Category`, and never reaches the story tier — in `tests/bash/commands/test_config_role_mapping.bats` and `tests/powershell/commands/Config.RoleMapping.Tests.ps1` (depends on T004; quickstart Step 1)
- [X] T007 Write the failing test for the ordering trap — a project ambiguous at BOTH tiers reports both unresolved roles in one run — in `tests/bash/commands/test_config_role_mapping.bats` and `tests/powershell/commands/Config.RoleMapping.Tests.ps1`. Today `hierarchy_derive`'s refusal at `commands/config.sh:531` aborts before `_config_resolve_child_type` at `:533`, so only the specification tier is named (research R1; quickstart Step 2)
- [X] T008 Record the pre-change baseline for the standing regression guard: run `tests/run-bash.sh`, the Pester suite, and `bash tests/conformance/ci-conformance.sh`, and note the pass counts of all three in the PR description. The Pester count belongs in the baseline as much as the bash one — every checkpoint below claims both ports green, and Constitution VI makes the three-OS matrix a merge gate. Every later phase re-runs this; FR-004 makes "no `hierarchy` key ⇒ byte-identical behaviour" the invariant the whole feature rests on (quickstart Step 3)

**Checkpoint**: both defects reproduced on both ports. Do not proceed until T006 and T007 are red for the documented reason and the rest of the suite is green.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The role vocabulary, the two schema layers and the answer flag must exist before any resolver can read them. Nothing here changes behaviour for a repository with no declaration.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T009 Write failing tests for the closed role set and the committed `hierarchy` schema — a non-object `hierarchy`, an unknown role name, and an empty/non-string role value each refuse with exit `4` and the message of [contracts/role-mapping.md](./contracts/role-mapping.md) §6.1 — in `tests/bash/lib/test_config.bats` and `tests/powershell/lib/Config.Tests.ps1`
- [ ] T010 Declare the closed role set `specification, story, task` as a single constant per port (`JIRA_ROLE_NAMES`), following the `JIRA_HOOK_EVENT_NAMES` precedent so the set has exactly one source, in `scripts/bash/lib/config.sh` and `scripts/powershell/lib/Config.psm1` (depends on T009)
- [X] T011 Add `projects[].hierarchy` validation to `_CFG_TEAM_ERRORS_JQ` and its PowerShell twin — shape, unknown role, non-empty string value — in `scripts/bash/lib/config.sh` and `scripts/powershell/lib/Config.psm1`. Note the general unknown-*project*-key check still does not exist (008 FR-030a), which is precisely why the role check must live inside this mapping (depends on T010)
- [ ] T011a [P] Write failing tests for the local binding's `roles` schema — a non-object `resolved_ids.<KEY>.roles`, an unknown role name, and a `source` outside `declared|operator|derived` each refuse with exit `4` — in `tests/bash/lib/test_config.bats` and `tests/powershell/lib/Config.Tests.ps1`, mirroring the existing `style_source` cases (depends on T010)
- [X] T012 Add `resolved_ids.<KEY>.roles` validation to `_CFG_LOCAL_ERRORS_JQ` and its twin — shape, unknown role, `source` in `declared|operator|derived` — mirroring the existing `style_source` rule, in `scripts/bash/lib/config.sh` and `scripts/powershell/lib/Config.psm1` (depends on T010, T011a)
- [ ] T013 [P] Write the test asserting the **existing** credential scan already covers the new key — a token-shaped and a host-shaped value under `projects[].hierarchy.story` each refuse with exit `4` and the value is never echoed — in `tests/bash/lib/test_token_leak.bats` and `tests/powershell/lib/TokenLeak.Tests.ps1`. FR-003 rides on `_cfg_credential_errors`; this asserts it rather than assuming it (research R3)
- [ ] T014 [P] Write failing tests for `--issue-type KEY=role=name` parsing, last-occurrence-wins per `(KEY, role)`, a malformed value exiting `1` as a usage error, and `--child-type KEY=name` still parsing as the `story` alias, in `tests/bash/lib/test_cli.bats` and `tests/powershell/lib/Cli.Tests.ps1`
- [X] T015 Implement `--issue-type` and keep `--child-type` as its documented alias in `scripts/bash/lib/cli.sh` and `scripts/powershell/lib/Cli.psm1`, per [contracts/role-mapping.md](./contracts/role-mapping.md) §2.2 (depends on T014)
- [ ] T015a [P] Write failing tests for `role_candidates` / `Get-JiraRoleCandidates` — non-sub-task types for `specification` and `story`, sub-task types for `task`, both in discovered order, and an empty set when the project reports no sub-task type — in `tests/bash/sink/test_role_mapping.bats` and `tests/powershell/sink/Hierarchy.RoleMapping.Tests.ps1` (depends on T010)
- [X] T016 Implement `role_candidates` / `Get-JiraRoleCandidates` — the non-sub-task types for `specification` and `story`, the sub-task types for `task`, in discovered order — in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1`. `hierarchy_child_level` and `hierarchy_derive` are unchanged and become step 3 of the resolver (depends on T010, T015a)

**Checkpoint**: schema, flag and candidate set exist. T008's baseline still green — nothing above changes behaviour for a repository with no declaration.

---

## Phase 3: User Story 1 — A Project With Several Types Per Level Configures and Mirrors (Priority: P1) 🎯 MVP

**Goal**: An operator declares `hierarchy` in the committed config; the ambiguous project configures, and a reconcile mirrors the specification into the declared types.

**Independent Test**: Configure `repo-with-declared-hierarchy` — the ceremony exits `0` and the binding records both types. Reconcile its two-story `spec.md` and observe one parent of the declared specification type and two children of the declared story type.

### Tests for User Story 1 ⚠️

- [ ] T017 [P] [US1] Write failing tests for resolution steps 1 and 3 — a declared name resolves an ambiguous level with `source: declared`; an unambiguous level with nothing declared still derives with `source: derived`; the resolver evaluates every role before refusing — in `tests/bash/sink/test_role_mapping.bats` and `tests/powershell/sink/Hierarchy.RoleMapping.Tests.ps1` ([contracts/role-mapping.md](./contracts/role-mapping.md) §3, §3.2)
- [ ] T018 [P] [US1] Write failing tests for byte-equal matching — no trimming beyond YAML scalar rules, no case folding, no Unicode normalisation, no prefix match — plus the §6.3 unknown-type refusal naming every candidate and the §6.4 duplicate-name refusal naming the level, in `tests/bash/sink/test_role_mapping.bats` and `tests/powershell/sink/Hierarchy.RoleMapping.Tests.ps1` ([contracts/role-mapping.md](./contracts/role-mapping.md) §3.3)
- [ ] T019 [P] [US1] Write failing tests for persistence — `roles.<role>` carries `{logical_name, id, hierarchy_level, subtask, source}` with `hierarchy_level` as a **string**, and `roles.story` ≡ `child_type` / `roles.specification` ≡ `parent_type` (contract §5.1, §9.2) — in `tests/bash/lib/test_config_binding_shape.bats` and `tests/powershell/lib/Config.BindingShape.Tests.ps1`
- [ ] T020 [P] [US1] Write the failing test that a second ceremony run over unchanged inputs writes byte-identical YAML and emits no question, in `tests/bash/commands/test_config_determinism.bats` and `tests/powershell/commands/Config.Determinism.Tests.ps1` (contract §5.2)
- [ ] T021 [P] [US1] Write the failing test that reconcile mirrors into the declared types — one parent of the declared specification type, one child per user story of the declared story type, each naming the parent — in `tests/bash/commands/test_reconcile_hierarchy.bats` and `tests/powershell/commands/Reconcile.Hierarchy.Tests.ps1` (depends on T005)
- [ ] T022 [P] [US1] Write the failing zero-churn test — a second reconcile of the unchanged specification issues zero writes of every kind at every tier — in `tests/bash/commands/test_reconcile_zero_churn.bats` and `tests/powershell/commands/Reconcile.ZeroChurn.Tests.ps1` (FR-025)
- [ ] T022a [P] [US1] Write the failing dry-run prediction test — `reconcile --dry-run` against `repo-with-declared-hierarchy` names the resolved type of the parent and of every child, and the predicted action set is identical to the real run's over the same state — in `tests/bash/commands/test_reconcile_dry_run.bats` and `tests/powershell/commands/Reconcile.DryRun.Tests.ps1` (FR-026; this is Constitution XI's enforcement test, which nothing else in this feature performs)

### Implementation for User Story 1

- [X] T023 [US1] Implement `role_resolve` / `Resolve-JiraRoleMapping` with precedence steps 1 (declared) and 3 (derived), evaluating **all three roles in one pass** and accumulating unresolved roles rather than refusing on the first, in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T016, T017; contract §3, §3.2)
- [X] T024 [US1] Implement byte-equal candidate matching plus the §6.3 and §6.4 refusal messages, in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T023, T018)
- [X] T025 [US1] Replace the two separate calls — `hierarchy_derive` at `scripts/bash/commands/config.sh:527` and `_config_resolve_child_type` at `:533` — with one `role_resolve` call per project, in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1`. `_config_resolve_child_type` / `Resolve-JiraChildType` is deleted, not left orphaned (depends on T023)
- [X] T026 [US1] Persist `roles` under `resolved_ids.<KEY>` **and dual-write** `child_type` / `parent_type` from `roles.story` / `roles.specification`, in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1`. The dual-write is what keeps `_reconcile_plan_context`, `hierarchy_mandatory_gate` and the stale-binding codes untouched — see plan.md Complexity Tracking for its removal trigger (depends on T025, T019; contract §5.1)
- [ ] T026a [P] [US1] Write failing tests for the §7.1 per-role audit — `<role>: <logical_name> (<source>)` in prose and `{"roles":{…}}` under the discovery effect in `--json`, with one role resolved from each of the three sources — in `tests/bash/commands/test_config_three_effects.bats` and `tests/powershell/commands/Config.ThreeEffects.Tests.ps1` (depends on T026)
- [X] T027 [US1] Add the per-role provenance audit to the discovery effect of the run summary — `<role>: <logical_name> (<source>)` in prose, `{"roles":{…}}` in `--json` — in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1` (depends on T026, T026a; contract §7.1)
- [ ] T028 [US1] Add the conformance scenario `tests/conformance/scenarios/us1-role-declared.json` over `repo-with-declared-hierarchy`, asserting the ceremony exits `0` and the audit reports both roles as `declared` (depends on T027)

**Checkpoint**: the consumer instance configures and mirrors when the mapping is declared. T006 is green. T008's baseline still green.

---

## Phase 4: User Story 2 — The Ceremony Asks Instead of Failing (Priority: P1)

**Goal**: An operator who has declared nothing gets a closed enumerated question over the project's own candidates, answers it once with a flag, and the answer is persisted with its provenance.

**Independent Test**: Run the ceremony against `repo-with-consumer-hierarchy` with nothing declared — the refusal lists both specification-tier candidates and all thirteen story-tier candidates, and names the exact declaration and flag. Re-run with `--issue-type` answers and it completes.

**Why this is still P1**: US1's declaration surface is undiscoverable without this. An operator meeting `parent-level-ambiguous` today has no path forward from the message alone — that is exactly how the consumer got stuck.

### Tests for User Story 2 ⚠️

- [ ] T029 [P] [US2] Write failing tests for the §6.2 unresolved-role refusal — one block per unresolved role in the order `specification, story`, each naming the level, every candidate in discovered order, the `projects[].hierarchy.<role>` declaration and the `--issue-type` flag — plus the assertion that an **undeclared `task` role never appears in the block**: it is absent, not unresolved, and treating it otherwise would refuse every project that wants no task tier ([contracts/role-mapping.md](./contracts/role-mapping.md) §3.4) — in `tests/bash/sink/test_role_mapping.bats` and `tests/powershell/sink/Hierarchy.RoleMapping.Tests.ps1`
- [ ] T030 [P] [US2] Write failing tests for the structured `unresolved_roles` block in the `--json` summary, matching the shape in [contracts/role-mapping.md](./contracts/role-mapping.md) §6.2, in `tests/bash/commands/test_config_role_mapping.bats` and `tests/powershell/commands/Config.RoleMapping.Tests.ps1`
- [ ] T031 [P] [US2] Write failing tests for resolution step 2 — `--issue-type KEY=story=Story` resolves with `source: operator` and is persisted — plus the `--child-type` alias resolving the same way, in `tests/bash/commands/test_config_child_type.bats` and `tests/powershell/commands/Config.ChildType.Tests.ps1` (depends on T015)
- [ ] T032 [P] [US2] Write the test asserting **no interactive prompt exists** — the ceremony never reads stdin on any path, so `--json` and the hook path cannot hang — in `tests/bash/commands/test_config_role_mapping.bats` and `tests/powershell/commands/Config.RoleMapping.Tests.ps1` (research R7)

### Implementation for User Story 2

- [X] T033 [US2] Implement the §6.2 refusal prose, one block per unresolved role in role order, in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T023, T029)
- [X] T034 [US2] Emit the `unresolved_roles` block **through the port's output module**, never a bare `jq` — it is multi-line JSON and the Windows `jq` build emits CRLF on multi-line output — in `scripts/bash/commands/config.sh` (via `scripts/bash/lib/output.sh`) and `scripts/powershell/commands/Config.psm1` (depends on T033, T030; research R10)
- [X] T035 [US2] Wire resolution step 2 (`operator`) into `role_resolve`, between the committed declaration and derivation, in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T023, T031)
- [X] T036 [US2] Rewrite step 8 of the ceremony algorithm in `commands/speckit.jira.config.md` — the agent reads the `unresolved_roles` block, asks the human a closed question over those candidates only, and re-invokes with `--issue-type`. State normatively that the bridge never prompts and that no option outside the candidate list may be offered (depends on T034)
- [ ] T037 [P] [US2] Add the conformance scenarios `tests/conformance/scenarios/us1-role-unresolved-both.json` (both roles reported in one refusal, zero writes) and `us1-role-operator-answer.json` (`--issue-type` resolves and persists with provenance), and verify `us1-hierarchy-ambiguous.json` is **unchanged and still passing** — it is the guard proving the closed question did not become a prompt (depends on T035)

**Checkpoint**: T007 is green. The consumer is unblocked end to end — this plus Phase 3 is the true deliverable. T008's baseline still green.

---

## Phase 5: User Story 3 — The Whole Team Mirrors Into the Same Issue Types (Priority: P2)

**Goal**: The committed declaration outranks a private local answer, so two developers on one repository mirror into identical types.

**Independent Test**: Record a mapping in `config.yml`, delete `config.local.yml`, re-run configuration with no flags — the declared types resolve with no question asked. Then set a conflicting local answer and re-run: the declaration wins and the run names both types.

### Tests for User Story 3 ⚠️

- [ ] T038 [P] [US3] Write failing tests for precedence — a committed declaration beats a recorded local answer, the binding converges onto the declaration, and the run reports the §7.2 supersession note naming both types — in `tests/bash/commands/test_config_role_mapping.bats` and `tests/powershell/commands/Config.RoleMapping.Tests.ps1`
- [ ] T039 [P] [US3] Write the failing test that supersession is **one-time**: a third run over the converged state writes byte-identical YAML and emits no note, in `tests/bash/commands/test_config_determinism.bats` and `tests/powershell/commands/Config.Determinism.Tests.ps1` (Constitution II)
- [ ] T040 [P] [US3] Write failing tests for the §7.3 promotion note — any role resolving with `source: operator` prints the exact YAML to commit, as a note, never a warning, with the run still exiting `0` — in `tests/bash/commands/test_config_three_effects.bats` and `tests/powershell/commands/Config.ThreeEffects.Tests.ps1` (FR-011)

### Implementation for User Story 3

- [X] T041 [US3] Implement the supersession path — declaration outranks the recorded answer, binding converges, §7.2 note emitted once — in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1` (depends on T035, T038)
- [X] T042 [US3] Implement the §7.3 promotion note in the discovery effect, in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1` (depends on T027, T040)
- [ ] T043 [P] [US3] Add the conformance scenario `tests/conformance/scenarios/us1-role-supersession.json` asserting the declaration wins, the note names both types, and the run exits `0` (depends on T041)

**Checkpoint**: the divergence risk 008 recorded and dated to this release is closed.

---

## Phase 6: User Story 4 — A Mapping That No Longer Matches the Project Refuses Cleanly (Priority: P2)

**Goal**: An impossible or stale mapping is refused before any issue exists, naming the role, the types and the levels.

**Independent Test**: Mutate the fixture so the specification-role type sits at or below the story-role type's level; the run refuses, names both roles and both levels, and issues zero writes.

### Tests for User Story 4 ⚠️

- [ ] T044 [P] [US4] Write failing tests for the ordering refusal (§6.7) — including the two negative assertions that are easy to omit: a gap greater than one level is **accepted** (FR-012), and a lexical comparison ordering `"-1" > "0"` must fail the test — in `tests/bash/sink/test_role_mapping.bats` and `tests/powershell/sink/Hierarchy.RoleMapping.Tests.ps1` (contract §4, §4.1)
- [ ] T045 [P] [US4] Write failing tests for the sub-task refusals — §6.5 (a sub-task type for `specification` or `story`) and §6.6 (a non-sub-task type for `task`, with an empty candidate list rendered as the explicit words, never an empty string) — plus the assertion that a sub-task type reported at level `0` is caught by the `subtask` flag and **not** by its level, in `tests/bash/sink/test_role_mapping.bats` and `tests/powershell/sink/Hierarchy.RoleMapping.Tests.ps1` (contract §4.1)
- [ ] T046 [P] [US4] Write failing tests for check 5 and check 6 running at **configuration** time over the resolved roles — the existing parent-link refusal, and the mandatory-field gate over every type the mapping selects including one derivation would never have chosen — in `tests/bash/sink/test_hierarchy.bats` and `tests/powershell/sink/Hierarchy.Tests.ps1` (FR-017, FR-018)
- [X] T047 [P] [US4] Write failing tests for reconcile-time re-validation (§8) — checks 4, 5 and 6 against the persisted binding, `reconcile:` prefix, zero writes — and for the FR-004 cases that an **absent** `roles` key in an otherwise current binding is not an error, and that an absent `roles.task` inside a present `roles` block is likewise not an error (§3.4), in `tests/bash/commands/test_reconcile_hierarchy.bats` and `tests/powershell/commands/Reconcile.Hierarchy.Tests.ps1`
- [ ] T047a [P] [US4] Write failing tests that a dry run predicts **every** §6 refusal exactly — same exit code, same message bytes, zero writes — for the unknown-type, duplicate-name, sub-task-misuse and ordering cases, in `tests/bash/commands/test_reconcile_dry_run.bats` and `tests/powershell/commands/Reconcile.DryRun.Tests.ps1` (FR-026, second clause)
- [ ] T048 [P] [US4] Write the failing test that every §6 refusal is downgraded to one WARNING with exit `0` under hook context, in `tests/bash/commands/test_reconcile_lifecycle.bats` and `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1` (FR-020, Constitution III)

### Implementation for User Story 4

- [X] T049 [US4] Implement `role_validate` / `Test-JiraRoleMapping` — checks 1–4 of contract §4 with **numeric** level comparison after `tonumber` / `[int]`, and the §6.5/§6.6/§6.7 messages — in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T023, T044, T045)
- [X] T050 [US4] Extend `hierarchy_mandatory_gate` / `Get-JiraHierarchyMandatoryGate` to run over every type the mapping selects, and pull the parent-link check to configuration time, in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T049, T046)
- [X] T051 [US4] Call `role_validate` after resolution and before persistence in the ceremony, in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1` (depends on T049)
- [X] T052 [US4] Add §8 re-validation against the persisted binding in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1`, with the `reconcile:` prefix and **no** re-read of the project's metadata — an absent `roles` key stays non-fatal (depends on T049, T047)
- [X] T053 [P] [US4] Add the conformance scenario `tests/conformance/scenarios/us1-role-ordering-refusal.json` asserting inverted levels refuse with exit `4` and zero writes (depends on T051)
- [X] T053a [P] [US4] Add the conformance scenario `tests/conformance/scenarios/us1-role-declared-dry-run.json` capturing `reconcile --dry-run` over `repo-with-declared-hierarchy` — zero writes, a predicted resolved type per tier — so FR-026 is proven cross-port and not only in the bats suites (depends on T022a)

**Checkpoint**: every impossible mapping the contract enumerates is refused before an issue exists. All P1 and P2 stories complete.

---

## Phase 7: Polish, Documentation & Release

**Purpose**: The surfaces an operator actually reads, and the gates that prove the twin ports agree.

- [X] T054 [P] Document the `hierarchy` mapping in `templates/config.yml.template` in the same business vocabulary as `priority_map`, using the consumer's three-level shape as the worked example, with a comment stating the example is documentation and never a fallback (FR-005, Constitution VII)
- [X] T055 [P] Replace step 8 of `docs/04-config-ceremony.md` — the derivation-only description and its mermaid flow — with the declared → answered → derived precedence and the unresolved-role question
- [X] T056 [P] Document the committed/local split for the mapping in `docs/07-configuration-and-secrets.md` — names in `config.yml`, ids and provenance in `config.local.yml` (Constitution V)
- [X] T057 [P] Add the entry under `## [Unreleased]` in `CHANGELOG.md` describing the new key, the new flag, the `--child-type` alias, and the fact that a repository with no `hierarchy` key is unaffected
- [X] T058 Bump `extension.version` `0.8.0` → `0.9.0` in `extension.yml` — additive committed-format key, so minor — and confirm `config_assert_single_version_source` still passes (depends on T057)
- [X] T059 Run the full suites on both ports: `tests/run-bash.sh`, the Pester suite, and `bash tests/conformance/ci-conformance.sh`. All six new scenarios green, `us1-hierarchy-ambiguous.json` unchanged and green, T008's baseline counts met or exceeded (depends on T053, T053a)
- [X] T060 [P] Run `shellcheck $(git ls-files '*.sh')`, `actionlint`, and `Invoke-ScriptAnalyzer -Path scripts/powershell -Recurse -Settings PSScriptAnalyzerSettings.psd1` — all clean
- [ ] T061 Verify coverage ≥ 80% overall from `coverage.xml` with resolution precedence (`role_resolve` in `scripts/bash/sink/jira/hierarchy.sh`) and idempotency near 100%, per Constitution XIII (depends on T059)
- [ ] T062 Push to `ci/windows-probe` and confirm a green run (~11 min, results as annotations). Two things are under test and neither can be checked by reading: the `unresolved_roles` block must not acquire CRLF, and every message interpolating `Tâche` / `Sous-tâche` must be byte-identical across ports. **A Windows claim is unproven without this run, in either direction** (depends on T059; quickstart Step 11, `AGENTS.md`)
- [ ] T063 Dogfood against the real consumer instance per [quickstart.md](./quickstart.md) Step 12, driving `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` in the consumer repository — config exits `0` with a three-role audit, the dry run predicts every resolved type, the first reconcile builds the hierarchy, the second reports `created: 0, updated: 0`. This is **SC-001**, and Constitution II states mocks are explicitly not sufficient for the idempotency claim (depends on T062)

**Checkpoint**: releasable. SC-001 through SC-007 demonstrated.

---

## Phase 8: User Story 5 — A Team That Works in Sub-Tasks Can Mirror Its Task List (Priority: P3) — DEFERRED

**Goal**: A declared `task` role mirrors each task recorded against a user story as a sub-task of that story's issue.

**Independent Test**: Declare a `task` role against the consumer fixture, reconcile a specification whose stories carry tasks, observe one sub-task per task under the correct story, re-run and observe zero writes.

**⚠️ This phase is gated separately and is NOT required for the release above.** Nothing parses `tasks.md` in either port today — `grep -n "task" scripts/bash/engine/parse.sh` returns nothing — the neutral interchange document is shaped `{epic, stories[]}`, and durable identifiers, recognition and drift all enumerate two tiers. This is an engine feature roughly the size of 008 and would delay the consumer's unblock by its own length (research R9).

**What ships in Phases 2–7 regardless**: the `task` role's declaration, its §6.6 validation, its persistence, and the §7.4 status line. A role that silently did nothing would be worse than no role — a team would commit `hierarchy.task: Sous-tâche`, see no error, and conclude sub-tasks were being created.

- [X] T064 [P] [US5] Write the failing test that a declared `task` role validates, persists, reports §7.4, and creates **zero** sub-tasks — plus the §3.4 counterpart, that an **undeclared** `task` role produces no `roles.task`, no note and no refusal — in `tests/bash/commands/test_config_role_mapping.bats` and `tests/powershell/commands/Config.RoleMapping.Tests.ps1`. The zero-sub-tasks assertion is inverted only when T070 lands (depends on T005; contract §9.6, §9.7)
- [X] T065 [US5] Emit the §7.4 note — `task is recorded as "<NAME>" but is not mirrored yet — this release creates no sub-tasks` — whenever a `task` role resolves, in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1`. **This task belongs to the Phase 7 release**, not to the deferred work below (depends on T027, T064)

*Everything below this line is the deferred tier and is out of scope for the release above.*

- [ ] T066 [US5] Extend `engine/parse.sh` and `engine/Parse.psm1` to parse tasks recorded against a user story, emitting neutral task content — no Jira identifier crosses into the engine (Constitution VIII)
- [ ] T067 [US5] Extend the neutral interchange document and its schema to carry tasks under their story, in `scripts/bash/engine/interchange.sh` and `scripts/powershell/engine/Interchange.psm1` (depends on T066)
- [ ] T068 [US5] Add the third durable-identifier tier — marker assignment and byte-preserving splice for the task artifact — in `scripts/bash/engine/` and `scripts/powershell/engine/`, generalising `story_marker` rather than duplicating it (depends on T067)
- [ ] T069 [US5] Extend recognition, identity and drift to the sub-task tier, in `scripts/bash/sink/jira/{recognition,identity}.sh`, `scripts/bash/engine/drift.sh` and their PowerShell twins (depends on T068)
- [ ] T070 [US5] Create sub-tasks of the resolved `task` type under each story in `scripts/bash/sink/jira/plan_apply.sh` and `scripts/powershell/sink/jira/PlanApply.psm1`, and extend the plan context to carry the task type id (depends on T069)
- [ ] T071 [US5] Prove FR-024 both ways: no `task` role ⇒ output byte-identical to the two-tier mirror; a `task` role ⇒ one sub-task per task and zero writes on a second run, in `tests/bash/commands/test_reconcile_zero_churn.bats` and `tests/powershell/commands/Reconcile.ZeroChurn.Tests.ps1` (depends on T070)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately
- **Foundational (Phase 2)**: depends on Phase 1 — **blocks every user story**
- **US1 (Phase 3)**: depends on Phase 2
- **US2 (Phase 4)**: depends on Phase 2; shares `role_resolve` with US1, so it lands after Phase 3 in practice
- **US3 (Phase 5)**: depends on US2's `operator` source (T035) — precedence needs two sources to arbitrate between
- **US4 (Phase 6)**: depends on Phase 2 only; could be built in parallel with US1–US3 by a second developer
- **Polish (Phase 7)**: depends on US1–US4
- **US5 (Phase 8)**: T064/T065 belong to the Phase 7 release; T066–T071 are deferred and depend on nothing above

### Why the phase order is not strictly the priority order

US1 and US2 are both P1 and together form the actual unblock. US1 is sequenced first because it delivers the resolver `role_resolve` that US2 extends with one more precedence step — the reverse order would build the question before the thing it asks about. Shipping US1 alone is a defensible MVP but a poor one: the operator would have to already know the key exists.

### Within Each User Story

- Tests are written and **must fail** before the implementation tasks in the same phase
- The resolver (`sink/jira/hierarchy.sh`) before the ceremony (`commands/config.sh`)
- The ceremony before the reconcile-side re-validation
- Both ports in the same commit — a task is not done when only bash is done

### Parallel Opportunities

- T001–T003 are three independent fixture files
- T011a, T013, T014 and T015a touch four different test files and are independent of each other
- T022a and T047a are the only two tasks in `test_reconcile_dry_run.bats`, and land in different phases
- Within each story, all `[P]` test tasks can be written concurrently
- **US4 is the genuine cross-story parallel opportunity**: it depends only on Phase 2 and touches `role_validate`, which US1–US3 do not
- T054–T057 and T060 are independent documentation and lint tasks

### Sequential by necessity

- T023 → T024 → T025 → T026 → T027 all touch the resolver and then the ceremony's persistence, in that order
- T033 → T034 (the refusal prose before the block that carries it)
- T059 → T061 → T062 → T063 (suite, coverage, Windows, live) — each gate consumes the previous one's result

---

## Parallel Example: User Story 4

```bash
# All four US4 test tasks touch different files and can be written together:
Task: "T044 ordering refusal tests in tests/bash/sink/test_role_mapping.bats"
Task: "T046 config-time parent-link and mandatory-gate tests in tests/bash/sink/test_hierarchy.bats"
Task: "T047 reconcile re-validation tests in tests/bash/commands/test_reconcile_hierarchy.bats"
Task: "T048 hook-downgrade tests in tests/bash/commands/test_reconcile_lifecycle.bats"
```

T045 is deliberately excluded — it shares `test_role_mapping.bats` with T044.

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1 Setup → both defects red
2. Phase 2 Foundational → schema, flag, candidate set
3. Phase 3 US1 → **STOP AND VALIDATE**: `repo-with-declared-hierarchy` configures and mirrors

At this point the consumer can be unblocked by hand-editing `config.yml`. Usable, but they have to be told the key exists.

### The real deliverable (US1 + US2)

4. Phase 4 US2 → the failing run tells the operator what to write

This is what the spec's Assumptions call the unblock, and it is the smallest thing worth releasing.

### Incremental delivery

5. Phase 5 US3 → team-wide consistency (closes the risk 008 dated to this release)
6. Phase 6 US4 → every impossible mapping refuses cleanly
7. Phase 7 → docs, version, conformance, Windows probe, live dogfood
8. Phase 8 T066–T071 → the task tier, in a later release

### Parallel team strategy

Two developers after Phase 2: one takes US1 → US2 → US3 (the resolver and ceremony chain), the other takes US4 (`role_validate`, which the chain does not touch). They meet at Phase 7.

---

## Notes

- `[P]` = different files, no dependency on an incomplete task
- **Both ports in the same commit** — Constitution VI. This is why most implementation tasks name two files and are not `[P]`
- Every refusal task must assert **zero Jira writes** and the hook downgrade, not just the exit code
- Verify each test fails for the documented reason before implementing — a test that fails for the wrong reason proves nothing
- Re-run T008's baseline (`tests/run-bash.sh`, `ci-conformance.sh`) at every checkpoint: FR-004 is the invariant the whole feature rests on
- Commit per task or per logical group; stop at any checkpoint and validate the story independently

---

## Phase 9: Convergence

**Purpose**: The resolver, its validation, the ceremony wiring, the reconcile re-validation, the notes, the flag, the schema, the docs and the release metadata are all in place on both ports. What the codebase does not yet have is the test corpus Constitution XIII requires to come *first*, and the three release gates. Every task below closes a gap between an artifact's stated intent and the code as it stands.

- [X] T072 CRITICAL — Create `tests/bash/sink/test_role_mapping.bats` and `tests/powershell/sink/Hierarchy.RoleMapping.Tests.ps1`, covering `role_candidates` / `Get-JiraRoleCandidates`, `role_resolve` precedence steps 1–3, byte-equal matching (no trim, no case fold, no Unicode normalisation, no prefix match), and **one test per §6 refusal message** (§6.2 through §6.7) each asserting zero Jira writes and the exact prose. Neither file exists today, so `scripts/bash/sink/jira/hierarchy.sh:85-306` and its PowerShell twin ship with no unit test at all per Constitution XIII and quickstart Step 5 (missing)
- [ ] T073 CRITICAL — Push to `ci/windows-probe` and confirm a green run: the `unresolved_roles` block must not acquire CRLF, and every message interpolating `Tâche` / `Sous-tâche` must be byte-identical across ports per Constitution VI, FR-029 and `AGENTS.md` (missing)
- [ ] T074 CRITICAL — Verify coverage ≥ 80% overall from `coverage.xml`, with `role_resolve` in `scripts/bash/sink/jira/hierarchy.sh` and the idempotency path near 100%, per Constitution XIII (missing)
- [X] T075 [P] Add the committed `hierarchy` schema tests (non-object mapping, unknown role, empty/non-string value ⇒ exit `4` with the §6.1 message) and the local `roles` schema tests (non-object `resolved_ids.<KEY>.roles`, unknown role, `source` outside `declared|operator|derived`) to `tests/bash/lib/test_config.bats` and `tests/powershell/lib/Config.Tests.ps1`; the validation at `scripts/bash/lib/config.sh:657-664` and `:696` is untested per FR-001, FR-030 and FR-010 (missing)
- [X] T076 [P] Add the assertion that the existing credential scan covers the new key — a token-shaped and a host-shaped value under `projects[].hierarchy.story` each exit `4` with the value never echoed — to `tests/bash/lib/test_token_leak.bats` and `tests/powershell/lib/TokenLeak.Tests.ps1` per FR-003 and Constitution IV (missing)
- [X] T077 [P] Add `--issue-type KEY=role=name` tests — parsing, last-occurrence-wins per `(KEY, role)`, a malformed value exiting `1` as a usage error, and `--child-type KEY=name` still parsing as the `story` alias — to `tests/bash/lib/test_cli.bats` and `tests/powershell/lib/Cli.Tests.ps1` per contract §2.2 (missing)
- [X] T078 [P] Add the binding-shape assertions — `roles.<role>` carries `{logical_name, id, hierarchy_level, subtask, source}` with `hierarchy_level` as a **string**, and `roles.story` ≡ `child_type` / `roles.specification` ≡ `parent_type` on every fixture — to `tests/bash/lib/test_config_binding_shape.bats` and `tests/powershell/lib/Config.BindingShape.Tests.ps1` per contract §5.1 and §9.2 (partial)
- [X] T079 [P] Add the ceremony determinism tests — a second run over unchanged inputs writes byte-identical YAML and emits no question, and supersession is one-time so a third run over the converged state emits no note — to `tests/bash/commands/test_config_determinism.bats` and `tests/powershell/commands/Config.Determinism.Tests.ps1` per Constitution II and contract §5.2 (missing)
- [X] T080 [P] Add the reconcile tests over `tests/conformance/fixtures/repo-with-declared-hierarchy` — one parent of the declared specification type, one child per user story of the declared story type each naming the parent, and a second reconcile issuing zero writes of every kind — to `tests/bash/commands/test_reconcile_hierarchy.bats`, `tests/bash/commands/test_reconcile_zero_churn.bats` and their PowerShell twins; the fixture is currently referenced by no test per FR-022, FR-025 and SC-007 (missing)
- [X] T081 [P] Create `tests/bash/commands/test_reconcile_dry_run.bats` and `tests/powershell/commands/Reconcile.DryRun.Tests.ps1`, asserting that `reconcile --dry-run` names the resolved type of the parent and of every child with an action set identical to the real run's, and that it predicts **every** §6 refusal exactly — same exit code, same message bytes, zero writes — per FR-026 and Constitution XI (missing)
- [X] T082 [P] Add the supersession tests — a committed declaration beats a recorded local answer, the binding converges onto the declaration, and the §7.2 note names both types — to `tests/bash/commands/test_config_role_mapping.bats` and `tests/powershell/commands/Config.RoleMapping.Tests.ps1`; the path at `scripts/bash/commands/config.sh:623-631` has no test on either port per FR-007 and US3/AC2 (missing)
- [X] T083 [P] Add the §7.1 per-role audit tests (`<role>: <logical_name> (<source>)` in prose and `{"roles":{…}}` under the discovery effect in `--json`, with one role from each of the three sources) and the §7.3 promotion note tests (a note, never a warning, run still exits `0`) to `tests/bash/commands/test_config_three_effects.bats` and `tests/powershell/commands/Config.ThreeEffects.Tests.ps1` per FR-027 and FR-011 (missing)
- [X] T084 [P] Add the configuration-time gate tests — the existing parent-link refusal and the mandatory-field gate run over every type the mapping selects, including one derivation would never have chosen — to `tests/bash/sink/test_hierarchy.bats` and `tests/powershell/sink/Hierarchy.Tests.ps1`; the wiring at `scripts/bash/commands/config.sh:600-610` is untested per FR-017 and FR-018 (missing)
- [X] T085 [P] Add the hook-downgrade test — every §6 refusal becomes one WARNING with exit `0` under hook context — to `tests/bash/commands/test_reconcile_lifecycle.bats` and `tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1` per FR-020 and Constitution III (missing)
- [X] T086 Add the four missing conformance scenarios — `us1-role-declared.json`, `us1-role-unresolved-both.json` (both roles in one refusal, zero writes, over the unreferenced `repo-with-consumer-hierarchy` fixture), `us1-role-operator-answer.json` and `us1-role-supersession.json` — under `tests/conformance/scenarios/`, and confirm `us1-hierarchy-ambiguous.json` is unchanged and still passing; only two of the six scenarios the plan names exist per FR-029 and Constitution VI (partial)
- [ ] T087 Dogfood against the real consumer instance per [quickstart.md](./quickstart.md) Step 12 — config exits `0` with a three-role audit, the dry run predicts every resolved type, the first reconcile builds the hierarchy, the second reports `created: 0, updated: 0` per SC-001 and Constitution XII (missing)
- [X] T088 Declare the closed role set as a single `JIRA_ROLE_NAMES` constant in `scripts/bash/lib/config.sh`, following the `JIRA_HOOK_EVENT_NAMES` precedent, and source it from the two `_CFG_*_ERRORS_JQ` programs, `scripts/bash/sink/jira/hierarchy.sh` and both `for role_key in specification story task` loops in `scripts/bash/commands/config.sh`. The PowerShell port already has `$script:JiraRoleNames` (`Config.psm1:1146`); the bash port repeats the literal in five places, so the set does not have "exactly one source" per contract §1 (partial)
- [X] T089 [P] Add the assertion that no interactive prompt exists — the ceremony never reads stdin on any path, so `--json` and the hook path cannot hang — to `tests/bash/commands/test_config_role_mapping.bats` and `tests/powershell/commands/Config.RoleMapping.Tests.ps1` per FR-008 and research R7 (missing)
- [X] T090 Resolve whether `hierarchy_mandatory_gate` must cover the resolved `task` type: it reads only `.child_type.id` and `.parent_type.id` in `scripts/bash/sink/jira/hierarchy.sh:391` and its twin, while `scripts/bash/commands/config.sh:585-592` already fetches `required_fields` for the task type and nothing evaluates it. Either extend the gate or record in the contract why a tier that creates nothing is exempt, per FR-018 (partial)
