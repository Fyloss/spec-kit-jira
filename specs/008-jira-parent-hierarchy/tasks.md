---

description: "Task list for feature implementation"
---

# Tasks: A Specification Mirrors as a Jira Hierarchy

**Input**: Design documents from `/specs/008-jira-parent-hierarchy/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: REQUIRED, not optional. Constitution XIII mandates strict Red-Green-Refactor and states that no implementation task may be planned without its test task preceding it. The repository's bug-fix policy additionally requires a test reproducing each defect *before* its fix, and this feature repairs four. Every implementation task below is preceded by the test task that must be observed failing first.

**Ports**: Constitution VI requires both implementations to change together. A task naming two files changes both in one commit; splitting them across commits breaks the portability gate.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (US1–US5)
- Exact file paths are given in every task

## Path Conventions

Script-native extension, no build step. `scripts/bash/` and `scripts/powershell/` hold the two ports; `tests/bash/`, `tests/powershell/`, `tests/conformance/`, `tests/live/` hold the four suites.

---

## Phase 1: Setup — Make the Four Defects Observable

**Purpose**: None of this feature is testable against the current mock. It serves create metadata from one fixture regardless of which issue type is asked for, and it has no notion of a parent reference, so neither per-type required fields nor the parent link nor the hierarchy derivation can be exercised. Phase 1 ends with all four defects reproduced and red.

- [X] T001 Route `GET /rest/api/3/issue/createmeta/{key}/issuetypes/{typeId}` to a per-issue-type fixture instead of the single per-style fixture, so two different types return two different field sets, in `tests/conformance/mock-jira/mock-server.ps1`
- [X] T002 Store `fields.parent` on each created issue and return it from `GET /rest/api/3/issue/{key}`, so a parent link is assertable, in `tests/conformance/mock-jira/mock-server.ps1` (depends on T001)
- [X] T003 [P] Expose per-issue-type createmeta seeding and parent-link assertion to both drivers in `tests/conformance/mock-jira/lib.sh` and `tests/conformance/mock-jira/Mock.psm1`
- [X] T004 [P] Add the non-default issue-type fixtures `tests/conformance/mock-jira/fixtures/createmeta-issuetypes-french.json` (`Épopée` 1, `Récit` 0, `Tâche` 0, `Sous-tâche` -1) and `createmeta-issuetypes-safe.json` (`Epic` 2, `Feature` 1, `Story` 0, `Sub-task` -1)
- [X] T004a [P] Add `tests/conformance/mock-jira/fixtures/createmeta-issuetypes-nonlatin.json` (`エピック` 1, `ストーリー` 0, `Задача (QA)` 0, `サブタスク` -1) — CJK, Cyrillic and parenthesised punctuation in one fixture, so the suite proves the mechanism is script-agnostic rather than English-plus-French. Spec FR-003b and US1 acceptance scenario 7; the three name shapes are the ones feature 007 found truncating on read
- [X] T005 [P] Add the two refusal fixtures `tests/conformance/mock-jira/fixtures/createmeta-issuetypes-flat.json` (one non-sub-task level only) and `createmeta-issuetypes-ambiguous.json` (two non-sub-task types sharing the level above the child level)
- [X] T006 [P] Add `tests/conformance/mock-jira/fixtures/createmeta-fields-parent-mandatory.json` declaring a required custom field on the parent type, per spec FR-023 and quickstart Step 6
- [X] T007 [P] Add the conformance fixtures `tests/conformance/fixtures/repo-with-french-project/`, `repo-with-nonlatin-project/`, `repo-with-safe-project/` and `repo-with-mandatory-field/`, each a multi-story `spec.md` plus `.specify/jira/config.yml` and `config.local.yml` routing to a bound project. Their bindings are written in the **new list shape** of [data-model.md](./data-model.md) §3 from the outset, with every `logical_name` quoted (depends on T004a)
- [X] T008 [P] Add `tests/conformance/fixtures/repo-with-stale-binding/` — a `config.local.yml` whose `resolved_ids.<KEY>.issue_types` is the old name-to-id **map**, reproducing the state of every existing installation (spec FR-003a)
- [X] T009 Write the failing regression test for defect 1 — a three-story specification issues exactly three `POST /rest/api/3/issue` calls, no parent and no `fields.parent` on any child — in `tests/bash/commands/test_reconcile_hierarchy.bats` and `tests/powershell/commands/Reconcile.Hierarchy.Tests.ps1` (depends on T001–T007; quickstart Step 1)
- [X] T010 Write the failing regression test for defect 2 — `.issue_types.Story` finds no key on the French binding, so the child type reaches the plan context empty and every creation is refused — in `tests/bash/sink/test_hierarchy.bats` and `tests/powershell/sink/Hierarchy.Tests.ps1` (depends on T004, T007; quickstart Step 2)
- [X] T011 Write the failing regression test for defect 3 — `config_resolved_ids_for` discards `hierarchy_level` and `subtask`, so the persisted binding cannot answer a hierarchy question — in `tests/bash/lib/test_config_binding_shape.bats` and `tests/powershell/lib/Config.BindingShape.Tests.ps1` (quickstart Step 3)
- [X] T012 Write the failing regression test for defect 4 — discovery calls `createmeta/{key}/issuetypes/{firstType}` once, so no second issue type's field schema is ever fetched — in `tests/bash/sink/test_discovery_createmeta.bats` and `tests/powershell/sink/Discovery.CreateMeta.Tests.ps1` (depends on T001)

**Checkpoint**: all four defects are reproduced by automated tests on both ports. Do not proceed until each is red for the documented reason.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The persisted binding must carry the hierarchy before anything can resolve by it, and discovery must fetch metadata for both written types before required fields exist to check. Research R5 identifies this as the blocker underneath every other repair. This phase also carries the cost the reshaping imposes on state that already exists: every committed fixture binding is in the old shape, and the refusal implemented here is what makes that shape fatal, so the migration lands in the same phase as the refusal rather than after it.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T013 Write failing tests asserting the binding keeps `{logical_name, id, hierarchy_level, subtask}` per issue type as a **list**, not a name-to-id map, per [data-model.md](./data-model.md) §3, in `tests/bash/lib/test_config_binding_shape.bats` and `tests/powershell/lib/Config.BindingShape.Tests.ps1` (depends on T011)
- [X] T014 Reshape `config_resolved_ids_for` to preserve `hierarchy_level` and `subtask`, in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1` (depends on T013)
- [X] T014a Migrate **every existing fixture binding** from the name-to-id map to the list shape of [data-model.md](./data-model.md) §3, adding `hierarchy_level`, `subtask`, `child_type`, `parent_type` and `required_fields`, in `tests/conformance/fixtures/{repo-with-mirrored-spec,repo-with-reconcile-binding,repo-with-two-styles,repo-with-unicode-binding,repo-with-reconcile-legacy}/.specify/jira/config.local.yml` and in every inline binding under `tests/bash/` and `tests/powershell/`. **`repo-with-stale-binding` (T008) is deliberately excluded and stays in the old shape** — it is the subject of T015/T016. This task MUST land before T016: the moment the `binding-shape-stale` refusal exists, every un-migrated fixture exits 4 with zero writes and the fifteen reconcile-exercising conformance scenarios go red with no task to green them (depends on T014)
- [X] T014b Decide and record, per fixture, the parent-level type for the three bindings that declare base-level types only — `repo-with-two-styles` (`COMP`, `TEAM`), `repo-with-reconcile-legacy` (`TEST`) and `repo-with-unicode-binding` (`JET`). Each either gains a level-1 non-sub-task type or is converted to an intentional `no-parent-level` refusal fixture; migrating them without deciding produces a correct refusal against an incorrect fixture. Write the decision into each file's header comment beside the existing provenance notes (depends on T014a)
- [X] T014c Write failing tests asserting every `logical_name` in the new binding shape round-trips byte for byte — Latin diacritics, CJK, Cyrillic, and `Done (QA)` / `high/low` punctuation — and that a name the reader cannot unescape refuses with feature 007's located, redacted message rather than truncating the document (spec FR-003b), in `tests/bash/lib/test_config_binding_shape.bats` and `tests/powershell/lib/Config.BindingShape.Tests.ps1`. **007's fix does not carry for free**: it hardened mapping *keys*, and T014 moves the logical name into a *value* inside a list of objects. Cover `child_type.logical_name`, `parent_type.logical_name` and `required_fields[].logical_name` too (depends on T014, T004a)
- [X] T014d Extend the unconditional write-quoting and the fail-closed read to the new list shape so T014c passes, in `scripts/bash/commands/config.sh`, `scripts/powershell/commands/Config.psm1`, `scripts/bash/lib/config.sh` and `scripts/powershell/lib/Config.psm1` (depends on T014c)
- [X] T015 Write failing tests for the stale-binding refusal of spec FR-003a — a binding whose `issue_types` is a map exits 4 with a message saying the binding **predates parent support**, **not** the "project has not been bound yet" text, and the refusal happens **before the first `GET`** — in `tests/bash/commands/test_reconcile_stale_binding.bats` and `tests/powershell/commands/Reconcile.StaleBinding.Tests.ps1` (depends on T008)
- [X] T016 Implement the `binding-shape-stale` detection and its message from [contracts/hierarchy-resolution.md](./contracts/hierarchy-resolution.md) §6, placed before any type resolution so no empty issue type can reach `plan_writes`, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T015)
- [X] T017 Write failing tests asserting discovery fetches create metadata for **each** written issue type rather than `.issueTypes[0].id`, and records `required_fields` keyed by issue-type id with each field's Jira `name`, in `tests/bash/sink/test_discovery_createmeta.bats` and `tests/powershell/sink/Discovery.CreateMeta.Tests.ps1` (depends on T012)
- [X] T018 Implement the per-type createmeta fetch and the `required_fields` capture in `discover_binding`, in `scripts/bash/sink/jira/discovery.sh` and `scripts/powershell/sink/jira/Discovery.psm1` (depends on T017)
- [X] T019 Write failing tests asserting the child type's create metadata reports whether a `parent` field is offered, per research R4 — read, never assumed from project style — in `tests/bash/sink/test_discovery_createmeta.bats` and `tests/powershell/sink/Discovery.CreateMeta.Tests.ps1` (depends on T017)
- [X] T020 Persist parent-link availability per issue type in the binding, in `scripts/bash/sink/jira/discovery.sh`, `scripts/powershell/sink/jira/Discovery.psm1`, `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1` (depends on T019, T014)

**Checkpoint**: the binding carries the project's hierarchy and both written types' field schemas; an old binding refuses legibly; every logical name survives whatever script it is written in. No Jira write behaviour has changed yet. Quickstart Steps 3 and 3b pass — **and the pre-existing suite is still green**, which is the assertion T014a exists to protect. Run the full conformance suite here, not only the new scenarios.

---

## Phase 3: User Story 4 — Configuration Carries No Key Without a Consumer (Priority: P2)

**Goal**: `epic_strategy`, `task_strategy` and `link_type` are gone from every layer, a configuration still declaring one is refused by name, and the stray `projects[].issue_types` map is deleted.

**Scheduled first despite being P2.** It deletes a field from the neutral document that US2 then adds fields to, and it rewrites the `config.yml` of roughly twenty conformance fixtures that every later phase's tests read. Landing it after US1 or US2 means editing the same validator and the same fixtures twice. See Dependencies below.

**Independent Test**: Remove the three keys from a configuration and reconcile — behaviour is unchanged. Put one back and the run refuses with exit 4 naming the key. Under a hook the same case emits one WARNING and returns 0 (quickstart Step 11).

### Tests for User Story 4 ⚠️

> Write these first and observe them fail.

- [X] T021 [P] [US4] Write failing tests asserting a team configuration declaring **none** of the three retired keys validates cleanly, in `tests/bash/lib/test_config_retired_keys.bats` and `tests/powershell/lib/Config.RetiredKeys.Tests.ps1`
- [X] T022 [US4] *(same file pair as T021 — no [P])* Write failing tests asserting a configuration declaring a retired key is refused with exit 4, one error per occurrence naming the key, the project index and the file, per [contracts/hierarchy-resolution.md](./contracts/hierarchy-resolution.md) §9 — and pinning research R10's finding that the top-level unknown-key check does **not** reach inside `projects[]`, in `tests/bash/lib/test_config_retired_keys.bats` and `tests/powershell/lib/Config.RetiredKeys.Tests.ps1`
- [X] T023 [P] [US4] Write failing tests asserting the same refusal under `SPEC_KIT_JIRA_HOOK_CONTEXT` emits exactly one WARNING on stderr and returns 0, leaving the host command's outcome untouched (spec FR-032), in `tests/bash/commands/test_reconcile_hierarchy.bats` and `tests/powershell/commands/Reconcile.Hierarchy.Tests.ps1`
- [X] T024 [P] [US4] Write failing tests asserting the neutral interchange document carries no `epic.strategy` and its schema does not require one, in `tests/bash/engine/test_interchange.bats` and `tests/powershell/engine/Interchange.Tests.ps1`
- [X] T025 [P] [US4] Write the failing conformance scenario `tests/conformance/scenarios/us4-retired-key-refusal.json` — exit 4 on a direct invocation, one WARNING and exit 0 under a hook, byte-identical on both ports

### Implementation for User Story 4

- [X] T026 [US4] Remove the `epic.strategy` validation rule and the `epic_strategy` context field from `interchange_validate` and `interchange_build`, in `scripts/bash/engine/interchange.sh` and `scripts/powershell/engine/Interchange.psm1` (depends on T024)
- [X] T027 [US4] Remove `_reconcile_epic_strategy` / `Get-JiraReconcileEpicStrategy`, its resolution, and its injection into the plan context, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` — **and the fourth surface the spec's enumeration does not name: the `SPEC_KIT_JIRA_EPIC_STRATEGY` environment override** at `reconcile.sh:366` and `Reconcile.psm1:430`, with the `override_epic` branch that consumes it. It is neither a template key, a ceremony question, a validation rule nor a fixture, so removing only the enumerated surfaces leaves a live env var feeding a field that no longer exists (depends on T026)
- [X] T028 [US4] Remove the three keys from `config_project_mapping` / `New-JiraProjectMapping` and from the mapping's link-type requirement, in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1`
- [X] T029 [US4] Replace the three validation rules with the retirement rule — one named error per occurrence — in `scripts/bash/lib/config.sh` and `scripts/powershell/lib/Config.psm1` (depends on T022)
- [X] T030 [US4] Remove the three keys and their explanatory comments from `templates/config.yml.template` and from the configuration ceremony's questions in `commands/speckit.jira.config.md` (depends on T028)
- [X] T031 [US4] Delete the three keys from every conformance fixture `config.yml` under `tests/conformance/fixtures/`, and delete the stray `projects[].issue_types` map from `repo-with-reconcile-binding` per spec FR-030a and research R11 — deleted, not retired, and not reserved as a slot for the future committable switch (depends on T029)
- [X] T032 [US4] Update every unit and conformance test that declares the three keys in an inline configuration, across `tests/bash/`, `tests/powershell/` and `tests/conformance/scenarios/` — **and every suite that exports `SPEC_KIT_JIRA_EPIC_STRATEGY`**, which an inline-configuration search does not find. `tests/conformance/fixtures/repo-with-reconcile-legacy/.specify/jira/config.local.yml` documents in its own header that the pre-existing reconcile suite depends on that override; start there and follow the callers (depends on T031, T027)
- [X] T032a [US4] Assert mechanically that the three retired keys are gone — `grep -rn "epic_strategy\|task_strategy\|link_type\|SPEC_KIT_JIRA_EPIC_STRATEGY" scripts/ templates/ commands/ README.md INSTALL.md` returns nothing outside the retirement rule — as a test in `tests/bash/lib/test_config_retired_keys.bats` and `tests/powershell/lib/Config.RetiredKeys.Tests.ps1`. This is the second half of spec SC-008 and today exists only as a manual grep in quickstart Step 11; T048 automates the equivalent assertion for Atlassian literals and this mirrors its form (depends on T030, T031, T032)

**Checkpoint**: the committable configuration format is settled for rollout. A stale key refuses by name; the three keys are provably absent from code, templates, commands and documentation (T032a, spec SC-008); nothing else changed behaviour.

---

## Phase 4: User Story 1 — Issue Types Resolve on a Jira That Is Not the Atlassian Default (Priority: P1) 🎯 MVP

**Goal**: Both levels resolve from the project's own metadata. A French project and a SAFe project mirror their stories with no code change; a project that cannot answer refuses before any write.

**Independent Test**: Reconcile against the French fixture and the SAFe fixture; each creation carries the type identifier that fixture declares, with no code or configuration difference between the runs (quickstart Step 4).

### Tests for User Story 1 ⚠️

> **T033–T037 are one file, not five.** All five write `tests/bash/sink/test_hierarchy.bats` and `tests/powershell/sink/Hierarchy.Tests.ps1`. They are independent in content and may be split across authors, but they land as one edit per file — none carries [P].

- [X] T033 [US1] Write failing tests for child-level derivation — the lowest level occupied by a non-sub-task type, expressed as a minimum over the discovered set so no level number is compiled in — in `tests/bash/sink/test_hierarchy.bats` and `tests/powershell/sink/Hierarchy.Tests.ps1` (depends on T010)
- [X] T034 [US1] Write failing tests for parent-level derivation over every row of [contracts/hierarchy-resolution.md](./contracts/hierarchy-resolution.md) §3 — default Scrum, the company-managed fixture, SAFe, the Latin-diacritic fixture and the non-Latin-script fixture — in the same two files (depends on T004a)
- [X] T035 [US1] Write failing tests for the `no-parent-level` refusal — zero writes, exit 4, the project and its non-sub-task types named, and **no fallback** to the child level or a sub-task type — in the same two files (depends on T005)
- [X] T036 [US1] Write failing tests for the `parent-level-ambiguous` refusal — zero writes, exit 4, **every** candidate named, and no candidate selected — in the same two files (depends on T005)
- [X] T037 [US1] Write failing tests for the `child-type-unresolved` refusal when the binding records no child type (spec FR-001a), in the same two files
- [X] T038 [P] [US1] Write failing tests for the ceremony's child-type question — derived and recorded `source: derived` when the child level holds one candidate, asked and recorded `source: operator` when it holds several, mirroring `style` / `style_source` per research R2 — in `tests/bash/commands/test_config_child_type.bats` and `tests/powershell/commands/Config.ChildType.Tests.ps1`
- [X] T039 [P] [US1] Write the failing conformance scenarios `tests/conformance/scenarios/us1-hierarchy-french.json` and `us1-hierarchy-safe.json` — the same specification, the same code, two different projects' type identifiers (depends on T007)
- [X] T040 [P] [US1] Write the failing conformance scenarios `tests/conformance/scenarios/us1-hierarchy-no-parent-level.json` and `us1-hierarchy-ambiguous.json` — exit 4, zero writes, the candidates named (depends on T005)
- [X] T041 [P] [US1] Write the failing conformance scenario `tests/conformance/scenarios/us1-binding-shape-stale.json` — the pre-feature binding refused legibly (depends on T008, T016)

### Implementation for User Story 1

- [X] T042 [US1] Implement child-level and parent-level derivation from the persisted `issue_types` list in the new `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T033, T034)
- [X] T043 [US1] Implement the `no-parent-level`, `parent-level-ambiguous` and `child-type-unresolved` refusals with the catalogued messages, in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T042, T035, T036, T037)
- [X] T044 [US1] Add the child-type closed question to the configuration ceremony and persist `child_type` with its `source`, in `scripts/bash/commands/config.sh`, `scripts/powershell/commands/Config.psm1` and `commands/speckit.jira.config.md` (depends on T038, T014)
- [X] T045 [US1] Persist the derived `parent_type` in the binding at configuration time, refusing at that point when the derivation is ambiguous, in `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1` (depends on T042, T043)
- [X] T046 [US1] Replace the literal `.issue_types.Story` lookup with `.child_type.id`, and add `parent_type_id` and `parent_supports_link` to the plan context, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T042, T044, T045)
- [X] T047 [US1] Route every refusal through `_reconcile_fault` so a direct invocation returns the code and a hook emits one WARNING, per research R9, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T043, T046)
- [X] T048 [US1] Confirm the Phase 1 regression test T010 now passes, and assert no Atlassian default type name appears in `scripts/` outside test fixtures, per quickstart Step 4 (depends on T046)

**Checkpoint**: a French project and a SAFe project both mirror their stories correctly, and a project that cannot answer the hierarchy question refuses cleanly. Stories are still flat.

---

## Phase 5: User Story 2 — A Specification Mirrors as a Stable Hierarchy (Priority: P1)

**Goal**: One parent per specification, every story its child, the specification readable on the parent, and a second run that writes nothing.

**Independent Test**: Reconcile a three-story specification into an empty project — one parent, three children, each naming the parent. Reconcile again unchanged — zero writes of every kind, four issues still (quickstart Steps 7 and 8).

### Tests for User Story 2 ⚠️

- [X] T049 [P] [US2] Write failing tests for the parent-marker grammar of [contracts/parent-marker.md](./contracts/parent-marker.md) — the three valid forms, the ignored forms, the malformed form, and two `spec=` lines as `duplicate` — in `tests/bash/engine/test_spec_marker.bats` and `tests/powershell/engine/SpecMarker.Tests.ps1`
- [X] T050 [US2] *(same file pair as T049 — no [P])* Write the failing **non-collision** test the contract makes normative — a specification with an H1, **no** `## User Story` headings and a `spec=` marker present must still be assigned its own `story=` marker; and `story_marker_parse_line` must return `kind: "none"` for a `spec=` body — in `tests/bash/engine/test_spec_marker.bats` and `tests/powershell/engine/SpecMarker.Tests.ps1`
- [X] T051 [US2] *(same file pair as T049 — no [P])* Write failing tests for the parent marker's byte-preserving splice — insert after the H1, insert as line 1 when there is no H1, the two state transitions, every other byte preserved, the dominant line ending adopted, and the file not opened for writing when nothing changes — in `tests/bash/engine/test_spec_marker.bats` and `tests/powershell/engine/SpecMarker.Tests.ps1`
- [X] T052 [P] [US2] Write failing tests asserting the `spec=` line is excluded from `parse_title`, `parse_description_blocks`, `parse_acceptance_criteria`, `parse_design`, `parse_priority` and `parse_estimation`, in `tests/bash/engine/test_parse_marker.bats` and `tests/powershell/engine/Parse.Marker.Tests.ps1`
- [X] T053 [P] [US2] Write failing tests asserting the identity marker gains `role` — `parent` or `story` — that a marker with no `role` is never treated as a parent, and that `identity_claimed_by_other` still compares `repo` and `spec_slug` alone (research R6), in `tests/bash/sink/test_identity.bats` and `tests/powershell/sink/Identity.Tests.ps1`
- [X] T054 [P] [US2] Write failing tests for the parent recognition decision table of [contracts/hierarchy-resolution.md](./contracts/hierarchy-resolution.md) §7 — every row, including that each non-`new`/non-`bound` outcome plans **zero** stories (spec FR-012) — in `tests/bash/sink/test_recognition_parent.bats` and `tests/powershell/sink/Recognition.Parent.Tests.ps1`
- [X] T055 [US2] *(same file pair as T054 — no [P])* Write failing tests asserting an inconclusive parent read (401, exhausted 429, network drop) propagates its exit code with zero stdout and is **never** downgraded to "no parent exists", in `tests/bash/sink/test_recognition_parent.bats` and `tests/powershell/sink/Recognition.Parent.Tests.ps1`
- [X] T056 [US2] *(same file pair as T054 — no [P])* Write failing tests asserting a recorded parent returning 404 is re-created, its record replaced, and the event reported in the run summary (spec FR-018), in `tests/bash/sink/test_recognition_parent.bats` and `tests/powershell/sink/Recognition.Parent.Tests.ps1`
- [X] T057 [P] [US2] Write failing tests for the `plan_writes` return shape of [data-model.md](./data-model.md) §6 — `{parent, stories}`, the parent performed first, its response key injected into every child's `fields.parent`, and `parent: null` on a recognised unchanged parent — plus the cardinality invariant of spec FR-004: `plan_writes` returns **at most one** parent for a specification and no configuration path can make it return more or fewer, asserted as a property of the return shape rather than of one fixture — in `tests/bash/sink/test_plan_apply_parent.bats` and `tests/powershell/sink/PlanApply.Parent.Tests.ps1`
- [X] T058 [P] [US2] Write failing tests asserting the parent's payload passes the privacy guard before any write, and that a blocked parent means zero writes for the whole specification (research R8, spec FR-036), in `tests/bash/sink/test_privacy_block.bats` and `tests/powershell/sink/PrivacyBlock.Tests.ps1`
- [X] T059 [P] [US2] Write failing tests asserting the parent's description carries the overview prose, a named Success Criteria section and a named Out of Scope section as prose — and **no** list of user stories (spec FR-011) and no markdown, front-matter or marker text — in `tests/bash/engine/test_parse_epic.bats`, `tests/powershell/engine/Parse.Epic.Tests.ps1`, `tests/bash/sink/test_adf.bats` and `tests/powershell/sink/Adf.Tests.ps1`
- [X] T060 [US2] *(same file pair as T057 — no [P])* Write failing tests asserting an unchanged parent is not written to, and that a human-edited parent description is compared on its managed section alone, in `tests/bash/sink/test_plan_apply_parent.bats` and `tests/powershell/sink/PlanApply.Parent.Tests.ps1`
- [X] T061 [P] [US2] Write the failing conformance scenario `tests/conformance/scenarios/us2-parent-first-run.json` — the exact call sequence of quickstart Step 7, the parent created before any child, and the resulting `spec.md` bytes
- [X] T062 [P] [US2] Write the failing conformance scenario `tests/conformance/scenarios/us2-parent-second-run.json` — zero POST, PUT and DELETE, `created: 0`, `updated: 0`, `spec.md` byte-identical
- [X] T063 [P] [US2] Write the failing conformance scenario `tests/conformance/scenarios/us2-parent-interrupted.json` — a `spec=<id> creating` marker refuses the whole specification and creates **no** story either

### Implementation for User Story 2

- [X] T064 [US2] Lift the shared byte-offset, line-ending, atomic-write and line-replacement primitives out of `scripts/bash/engine/story_marker.sh` and `scripts/powershell/engine/StoryMarker.psm1` so a second marker key can reuse them without duplicating a splice routine (depends on T051)
- [X] T065 [US2] Implement the parent marker — grammar, placement after the H1, the three states, assign / mark-creating / record-ticket — in the new `scripts/bash/engine/spec_marker.sh` and `scripts/powershell/engine/SpecMarker.psm1` (depends on T064, T049, T050)
- [X] T066 [US2] Extend `parse_spec` to strip the `spec=` line from every extraction and to emit `epic.local_id` and `epic.marker`, in `scripts/bash/engine/parse.sh` and `scripts/powershell/engine/Parse.psm1` (depends on T065, T052)
- [X] T067 [US2] Extend `parse_spec` to extract the success criteria and out-of-scope sections into `epic.description.blocks` as neutral content, per [data-model.md](./data-model.md) §7, in `scripts/bash/engine/parse.sh` and `scripts/powershell/engine/Parse.psm1` (depends on T059)
- [X] T068 [US2] Carry `epic.local_id` and `epic.marker` through `interchange_build` and validate them, in `scripts/bash/engine/interchange.sh` and `scripts/powershell/engine/Interchange.psm1` (depends on T066, T026)
- [X] T069 [US2] Add `role` to the marker built by `identity_marker`, in `scripts/bash/sink/jira/identity.sh` and `scripts/powershell/sink/jira/Identity.psm1` (depends on T053)
- [X] T070 [US2] Implement parent recognition — one read by the recorded key, the decision table, and the fail-closed propagation — in `scripts/bash/sink/jira/recognition.sh` and `scripts/powershell/sink/jira/Recognition.psm1` (depends on T054, T055, T056, T069)
- [X] T071 [US2] Render the parent's description through the existing ADF path, including the named Success Criteria and Out of Scope sections, in `scripts/bash/sink/jira/adf.sh` and `scripts/powershell/sink/jira/Adf.psm1` (depends on T067)
- [X] T072 [US2] Change `plan_writes` to return `{parent, stories}` and to emit the parent's creation or update, per research R7, in `scripts/bash/sink/jira/plan_apply.sh` and `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T057, T071)
- [X] T073 [US2] Perform the parent first in `apply_writes_with_recognition`, read its key from the response, and inject that key as `fields.parent` into every story action before writing it (depends on T072)
- [X] T074 [US2] Stamp the parent's identity marker and record its key in `spec.md` immediately after its creation — never batched — and mark it `creating` in the same splice that marks the stories, in `scripts/bash/sink/jira/plan_apply.sh` and `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T073, T065)
- [X] T075 [US2] Add the parent's payload to the pre-write privacy scan so a blocked parent yields zero writes for the specification, in `scripts/bash/sink/jira/plan_apply.sh` and `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T058, T072)
- [X] T076 [US2] Implement the parent's zero-churn comparison — `idempotency_field_status` on `{summary, description}`, and the managed-section comparison on a human-edited parent — in `scripts/bash/sink/jira/plan_apply.sh` and `scripts/powershell/sink/jira/PlanApply.psm1` (depends on T060, T072)
- [X] T077 [US2] Sequence derive → gate → recognise parent → recognise stories → plan → create parent → create children in `cmd_reconcile`, assigning the parent identifier in the same pass that assigns story identifiers, per [contracts/parent-marker.md](./contracts/parent-marker.md) "Ordering within one run", in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T070, T074, T046)
- [X] T078 [US2] Stop the run before planning any story when the parent is blocked, emitting the catalogued diagnostic (spec FR-012), in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T077)
- [X] T079 [US2] Report the parent in the run summary — created, reused, re-created, or skipped — in `scripts/bash/commands/reconcile.sh`, `scripts/powershell/commands/Reconcile.psm1`, `scripts/bash/lib/output.sh` and `scripts/powershell/lib/Output.psm1` (depends on T077)
- [X] T080 [US2] Confirm the Phase 1 regression test T009 now passes — one parent, three children, every child naming the parent — by running `tests/bash/commands/test_reconcile_hierarchy.bats` and `tests/powershell/commands/Reconcile.Hierarchy.Tests.ps1`, and record the before/after call sequences in the task notes (depends on T077)
- [X] T080a [US2] Rebaseline **every pre-existing conformance scenario that exercises reconcile** against the new hierarchy: each gains one parent `POST /rest/api/3/issue`, one parent `PUT …/properties/spec-kit-jira` carrying `role: parent`, a `fields.parent` on every child creation, and one `spec=<id> ticket=<KEY>` line after the H1 of the fixture's `spec.md`. The scenarios are `us8-reconcile-{company-managed,team-managed,real,priority-allowed-discovery}`, `us8-mixed-routing`, `us2-zero-churn-unchanged`, `us6-{dry-run,zero-churn,fail-closed}`, `us1-recognition-{second-run,reorder}`, `us1-unicode-binding`, `us3-{ticket-content,feature-create,feature-attach}` and `us7-human-content` — enumerate them in the task notes and tick each, because a missed scenario surfaces as a byte-diff on the three-OS matrix rather than as a local failure. Only the new scenarios T061–T063 were planned for; these are the ones the feature changes without naming them (depends on T077, T078, T079)

**Checkpoint**: the feature works. A specification mirrors as a hierarchy, and re-running it changes nothing. The whole conformance suite — old scenarios and new — is green on both ports.

---

## Phase 6: User Story 3 — A Missing Mandatory Field Refuses the Run (Priority: P2)

**Goal**: A required field the bridge cannot supply stops the run before Jira is touched, naming the type and every field concerned.

**Independent Test**: Reconcile against the mandatory-field fixture — zero write calls, the documented exit code, the issue type and field named (quickstart Step 6).

### Tests for User Story 3 ⚠️

> **T081–T084 share one file pair too** — `tests/bash/sink/test_hierarchy.bats` and `tests/powershell/sink/Hierarchy.Tests.ps1`, the same pair T033–T037 wrote. Independent in content, one edit per file, no [P].

- [X] T081 [US3] Write failing tests for the satisfaction table of [contracts/hierarchy-resolution.md](./contracts/hierarchy-resolution.md) §5 — which required fields the bridge supplies and which it cannot — in `tests/bash/sink/test_hierarchy.bats` and `tests/powershell/sink/Hierarchy.Tests.ps1` (depends on T018)
- [X] T082 [US3] Write failing tests asserting the gate reports **every** unsatisfiable field of **every** written type in one refusal, not the first it finds, and names fields by their Jira `name` rather than a `customfield_NNNNN` id — including a field whose name is non-ASCII, which must survive into the message intact (spec FR-003b) — in the same two files (depends on T006)
- [X] T083 [US3] Write failing tests asserting the refusal issues zero writes, is reported as a named mandatory-field refusal rather than a transport or rejected-request error (spec FR-024), and fires for the child type as well as the parent, in the same two files
- [X] T084 [US3] Write failing tests asserting the `parent-link-unavailable` refusal when the child type's create metadata offers no `parent` field, in the same two files (depends on T019)
- [X] T085 [P] [US3] Write the failing conformance scenario `tests/conformance/scenarios/us3-mandatory-field-refusal.json` — the dry-run report and the real run naming the same types and fields in the same order, both predicting no writes (depends on T007)

### Implementation for User Story 3

- [X] T086 [US3] Implement the mandatory-field gate over both written types, collecting every unsatisfiable field before reporting, in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T081, T082, T083)
- [X] T087 [US3] Implement the `parent-link-unavailable` refusal from the child type's own metadata rather than from project style, per research R4, in `scripts/bash/sink/jira/hierarchy.sh` and `scripts/powershell/sink/jira/Hierarchy.psm1` (depends on T084)
- [X] T088 [US3] Run the gate after derivation and before recognition, so it precedes the first read as well as the first write, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T086, T077)

**Checkpoint**: a project with mandatory extras refuses cleanly instead of leaving an orphan parent behind.

---

## Phase 7: User Story 5 — The Implementation Plan Is Readable on the Parent (Priority: P3)

**Goal**: The parent also carries the implementation plan, under its own named section, replaced in place on later runs.

**Independent Test**: Reconcile a feature folder holding a plan; the parent carries a named plan section as prose. Change one sentence, reconcile, and the section is replaced rather than duplicated.

### Tests for User Story 5 ⚠️

- [X] T089 [P] [US5] Write failing tests asserting `plan.md`'s summary prose is ingested into neutral content blocks and that a folder with no plan produces no section and no warning (spec FR-028), in `tests/bash/engine/test_parse_plan.bats` and `tests/powershell/engine/Parse.Plan.Tests.ps1`
- [X] T090 [P] [US5] Write failing tests asserting the plan section is replaced in place and appears exactly once after a second run, and that an unchanged plan issues no write to the parent, in `tests/bash/sink/test_plan_apply_parent.bats` and `tests/powershell/sink/PlanApply.Parent.Tests.ps1`
- [X] T091 [P] [US5] Write the failing conformance scenario `tests/conformance/scenarios/us5-plan-on-parent.json` — the plan rendered as prose, then changed, then unchanged

### Implementation for User Story 5

- [X] T092 [US5] Read `plan.md` from the feature folder and extract its summary prose into neutral content blocks, in `scripts/bash/engine/parse.sh` and `scripts/powershell/engine/Parse.psm1` (depends on T089)
- [X] T093 [US5] Render the plan under its own named section in the parent's description, positioned after Out of Scope, in `scripts/bash/sink/jira/adf.sh` and `scripts/powershell/sink/jira/Adf.psm1` (depends on T092, T071)
- [X] T094 [US5] Pass the feature folder's plan into the neutral document alongside the specification, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T092)

**Checkpoint**: all five user stories are independently functional.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T095 [P] Write failing tests asserting `--dry-run` predicts the parent creation or reuse, every parent reference, and every refusal — including the mandatory-field refusal — exactly as the real run performs them (spec FR-025, FR-033), in `tests/bash/commands/test_reconcile_hierarchy.bats` and `tests/powershell/commands/Reconcile.Hierarchy.Tests.ps1`
- [X] T096 Implement any dry-run gap T095 exposes, keeping the report identical to the action set, in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` (depends on T095)
- [X] T096a Extend the **existing** dry-run conformance scenario `tests/conformance/scenarios/us6-dry-run.json` so the predicted action set names the parent creation or reuse, the identifier the run assigned, and every child's parent reference — and extend `us6-fail-closed.json` with the mandatory-field refusal, which must be predicted rather than discovered mid-write. Quickstart Step 10 already validates FR-033 and SC-007 by running this scenario, but no task created or updated it: T095/T096 add bats and Pester coverage only, so dry-run parity has no conformance-level proof and no cross-port proof. Distinct from T080a, which rebaselines the same two files for the *real* run's call sequence — land T080a first and add the prediction assertions on top (depends on T096, T080a)
- [X] T097 [P] Write failing tests asserting every new diagnostic matches the catalogued wording in [contracts/parent-marker.md](./contracts/parent-marker.md) and [contracts/hierarchy-resolution.md](./contracts/hierarchy-resolution.md), and contains no site host, token or account id, including at maximum verbosity, in `tests/bash/sink/test_hierarchy.bats` and `tests/powershell/sink/Hierarchy.Tests.ps1`
- [X] T098 [P] Extend the Constitution II zero-write assertion list to cover the parent and the parent link, in `tests/live/test_live_zero_churn.bats`
- [X] T099 Extend the live suite to build a real hierarchy, re-run it unchanged for zero writes, add one story, and confirm the parent is untouched, per quickstart Step 12, in `tests/live/test_live_zero_churn.bats` (depends on T098)
- [X] T100 [P] Document the parent artifact, the parent marker, the hierarchy derivation and its two refusals, the mandatory-field gate and the retired keys in `commands/speckit.jira.reconcile.md`, `commands/speckit.jira.config.md`, `README.md` and `INSTALL.md`
- [X] T101 Add the CHANGELOG entry and version bump in `CHANGELOG.md` and `extension.yml`, stating plainly that mirrors created before this release carry no parent and will be re-mirrored from a clean state, and that three configuration keys are now refused
- [X] T102 Confirm the two blocking quality gates Constitution XII names: **lint complete and passing** on both ports, and the coverage gate — at least 80% statement coverage overall and near-100% on parent recognition, the derivation refusals, the mandatory-field gate and every fail-closed path — via the repository's lint entry point, `tests/coverage/bash-coverage.sh` and `Invoke-Pester -CI`. Lint is a merge gate in its own right, not a by-product of the coverage run
- [X] T103 Run the full conformance suite on all three operating systems and confirm byte-identical stdout, exit codes, Jira call sequences and resulting `spec.md` bytes, via `tests/conformance/run-scenario.sh` in the CI matrix under `.github/workflows/`
- [X] T104 Execute all thirteen steps of `specs/008-jira-parent-hierarchy/quickstart.md` end to end, including the live dogfood run against the consuming project, and record the outcome as the Constitution XII dogfood evidence

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: no dependencies — start immediately
- **Phase 2 (Foundational)**: depends on Phase 1 — **blocks every user story**
- **Phase 3 (US4)**: depends on Phase 2
- **Phase 4 (US1)**: depends on Phase 3
- **Phase 5 (US2)**: depends on Phase 4
- **Phase 6 (US3)**: depends on Phase 5 for its sequencing task (T088) only; its gate logic (T081–T087) depends on Phase 2
- **Phase 7 (US5)**: depends on Phase 5
- **Phase 8 (Polish)**: depends on every story that is being shipped

### Why the phase order is not the priority order

Two deliberate deviations, each with a dependency reason rather than a value judgement:

1. **US4 (P2) runs before US1 and US2 (both P1).** It deletes `epic.strategy` from `interchange_validate` and `interchange_build`, which US2 then extends with `epic.local_id` and `epic.marker`; and it rewrites the `config.yml` of roughly twenty conformance fixtures that every later phase reads. Running it after US1 or US2 means editing the same two functions and the same twenty fixtures twice. It is also the rollout-window item, so landing it early leaves the most time to notice a problem with it.
2. **US1 (P1) runs before US2 (P1).** US2 cannot create a parent until US1 can name the type to create it at. The spec anticipates this: US1 delivers value alone — a French project that today refuses every creation will mirror its stories correctly, flat.

US1's acceptance scenario 2 mentions the parent's level. Its *derivation* is proven in Phase 4; the parent's *existence* is proven in Phase 5. Both halves of that scenario are covered, in the phase that owns each.

### Within Each User Story

- Tests are written and observed failing before the implementation they cover
- Engine changes before sink changes before command-layer sequencing
- Both ports change in the same commit (Constitution VI)
- Story complete before moving to the next phase

### Parallel Opportunities

- T003–T008 (fixtures and mock drivers) are independent files and run in parallel; T004a is one of them, and T007 waits on it only for the type names it reuses
- Within Phase 2, T013/T015 and T017/T019 are two independent test-then-implement chains
- **[P] means a distinct file, and several test tasks deliberately do not carry it.** T033–T037 and T081–T084 share `test_hierarchy.bats`; T049–T051 share `test_spec_marker.bats`; T054–T056 share `test_recognition_parent.bats`; T057/T060 share `test_plan_apply_parent.bats`; T021/T022 share `test_config_retired_keys.bats`. Each group is independent in *content* and can be divided among authors, but lands as one edit per file. Only tasks writing a file no other task in the same phase touches carry [P]
- T081–T087 (the mandatory-field gate) depend only on Phase 2, so US3's gate can be built in parallel with US2 by a second developer; only its sequencing task T088 waits for US2
- T100 (documentation) is independent of the code tasks once the behaviour is settled

### Sequential by necessity

- T013 → T014 → T045/T046: nothing resolves by hierarchy until the binding carries it
- **T014 → T014a → T016**: the fixtures must already be in the new shape when the stale-binding refusal starts firing. Reversing these two turns fifteen conformance scenarios red for a reason no task addresses
- T014a → T014b: migrate first, then settle the fixtures that have no parent level to migrate *to*
- T014c → T014d: the round-trip failures are observed before the quoting is widened
- T064 → T065 → T066: the shared primitives are lifted before the second marker uses them
- T072 → T073 → T074: the plan shape, then the ordering, then the recording
- T077 is the integration point — it depends on the parent marker, parent recognition, the new plan shape and the type resolution all being in place
- **T077/T078/T079 → T080a → T096a**: the existing scenarios can only be rebaselined once the sequence they must record is the final one, and the dry-run predictions can only be asserted against a real-run baseline that already exists
- T030/T031/T032 → T032a: the retired-key grep is only meaningful once every deletion has landed

---

## Parallel Example: Phase 1

```bash
# Fixtures and drivers are independent files:
Task: "Expose per-type createmeta seeding in tests/conformance/mock-jira/lib.sh and Mock.psm1"
Task: "Add createmeta-issuetypes-french.json and createmeta-issuetypes-safe.json"
Task: "Add createmeta-issuetypes-nonlatin.json (CJK, Cyrillic, parenthesised punctuation)"
Task: "Add createmeta-issuetypes-flat.json and createmeta-issuetypes-ambiguous.json"
Task: "Add createmeta-fields-parent-mandatory.json"
Task: "Add the three repo fixtures under tests/conformance/fixtures/"
Task: "Add repo-with-stale-binding fixture"
```

## Parallel Example: User Story 2 Tests

```bash
# Each writes to a distinct test file:
Task: "Parent-marker grammar tests in tests/bash/engine/test_spec_marker.bats"
Task: "Identity role tests in tests/bash/sink/test_identity.bats"
Task: "Parent recognition decision table in tests/bash/sink/test_recognition_parent.bats"
Task: "plan_writes shape tests in tests/bash/sink/test_plan_apply_parent.bats"
Task: "Privacy guard tests in tests/bash/sink/test_privacy_block.bats"
Task: "Parent description content tests in tests/bash/engine/test_parse_epic.bats"
```

---

## Implementation Strategy

### MVP scope

The demonstrable MVP is **Phases 1–5**: Setup, Foundational, US4, US1 and US2. That is the whole of "a specification mirrors as a Jira hierarchy, on any Jira, and re-running changes nothing" — the feature's stated purpose and both of its P1 stories.

Phase 4 alone (through US1) is a shippable increment for a consumer blocked today by the literal type lookup: their stories mirror correctly, flat. It is not the feature, but it is a real fix and a safe stopping point.

### Incremental delivery

1. Phases 1–2 → the binding carries the hierarchy; old bindings refuse legibly
2. Phase 3 (US4) → the committable format is settled before rollout
3. Phase 4 (US1) → **stop and validate**: non-default Jiras mirror their stories
4. Phase 5 (US2) → **stop and validate**: the hierarchy exists and is idempotent — MVP complete
5. Phase 6 (US3) → enterprise projects with mandatory fields refuse cleanly
6. Phase 7 (US5) → the plan reaches the parent
7. Phase 8 → dry-run parity, live gate, documentation, release

### Parallel team strategy

After Phase 2, one developer can take US4 then US1 then US2 on the critical path while a second builds US3's gate (T081–T087), which depends only on Phase 2. US5 needs US2 and is best left to whoever finishes first.

---

## Notes

- **Do not skip the RED phase.** Four defects are being repaired and the repository's bug-fix policy requires each to be reproduced by a failing test before its fix. T009–T012 are those four tests.
- **T050 is load-bearing and easy to pass for the wrong reason.** If the parent marker is ever seen by the story-marker scan, a specification with no `## User Story` headings silently loses its only story. Assert the parser's return value, not just the end state.
- **T031 deletes rather than retires** the stray `projects[].issue_types` map: it was never shipped in the template, so no consumer has it, and it maps names to identifiers where the future switch will declare a name (research R11).
- **The committable Story-versus-Task switch is not in this task set.** It is scheduled for the release before rollout to a second team; see the spec's Out of Scope.
- **T014a and T080a are the two quiet ways this feature breaks the build.** Neither adds behaviour; both keep the existing suite honest while the behaviour underneath it changes. T014a fails at the Phase 2 checkpoint if skipped, T080a on the three-OS matrix — which is the expensive place to find it. Run the *full* conformance suite at both checkpoints, not only the scenarios the phase added.
- **No language is a supported language.** An issue-type or field name is opaque text: the bridge carries the bytes Jira supplied and never parses, translates, normalises, case-folds or pattern-matches them. French appears here as a fixture, and T004a's CJK/Cyrillic fixture sits beside it so the suite cannot be read as covering two languages. If a task ever needs a list of languages, the design has gone wrong — see spec FR-003b.
- [P] tasks touch different files and have no dependency on an incomplete task — see Parallel Opportunities for the groups that deliberately do not carry it
- Commit after each task or logical group; both ports in the same commit
