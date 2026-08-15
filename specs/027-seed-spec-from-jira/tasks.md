---

description: "Task list for 027 — Seed a Specification From Existing Jira Issues"
---

# Tasks: Seed a Specification From Existing Jira Issues

**Input**: Design documents from `/specs/027-seed-spec-from-jira/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: **MANDATORY, not optional.** Constitution Principle XIII states that "no
implementation task may be planned without its test task preceding it in
`tasks.md`", and its enforcement test rejects at review any implementation task
that is not so preceded. Every implementation task below is therefore preceded by
the failing test that must be observed to fail first.

**Organization**: Tasks are grouped by user story. Priority order comes from
spec.md after the second clarification session moved US2 to P2: **P1 = US5, US1,
US3, US6** (the slice with no irreversible write), **P2 = US7, US4, US2**.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to
- Exact file paths in every description

## Path conventions

Twin native ports, per plan.md:

- Bash: `scripts/bash/{commands,engine,lib,sink/jira}/`
- PowerShell: `scripts/powershell/{commands,engine,lib,sink/jira}/`
- Tests: `tests/bash/`, `tests/powershell/`, `tests/conformance/scenarios/`

**The two ports are the largest source of `[P]`** in this feature: a Bash module
and its PowerShell twin are different files with no dependency between them.

## Traceability

Tasks cite **contract test IDs**, not FR numbers — the convention this repository
already follows. The mapping lives in the contracts:

| Prefix | Contract | Covers |
| --- | --- | --- |
| `D1…D10` | [designator-grammar.md](./contracts/designator-grammar.md) §8 | FR-002…FR-008, FR-053…FR-055 |
| `P-1…P-9` | [pin-marker.md](./contracts/pin-marker.md) §8 | FR-016…FR-019, FR-056…FR-058, FR-063 |
| `C-1…C-18` | [seed-cli-contract.md](./contracts/seed-cli-contract.md) §8 | FR-001, FR-032…FR-051, FR-061…FR-064 |
| `S-1…S-9` | [seed-record.md](./contracts/seed-record.md) §6 | FR-040, FR-041, FR-049, FR-050, FR-060 |

---

## Phase 1: Setup (shared infrastructure)

**Purpose**: fixtures and dispatch wiring that every later phase needs.

- [ ] T001 [P] Extend the conformance mock double to serve `POST /rest/api/3/issue/bulkfetch` with the field union of research R5 (`summary,description,status,issuetype,project,parent` + the `spec-kit-jira` property) in `tests/conformance/mock-jira/`
- [ ] T002 [P] Add a bats fixture builder for a seeded repo — `config.yml` with a `hierarchy` block and project routing, plus `personal.yml` — in `tests/bash/helpers/`
- [ ] T003 [P] Add the Pester twin fixture builder in `tests/powershell/helpers/`
- [ ] T004 [P] Add a non-default hierarchy fixture (SAFe-shaped roles, renamed types) for FR-014 in `tests/bash/helpers/` and `tests/powershell/helpers/`
- [ ] T005 [P] Write the failing dispatch test asserting `seed` is a recognised command word in `tests/bash/test_dispatch.bats` and `tests/powershell/commands/Dispatch.Tests.ps1`
- [ ] T006 Register `seed` in the command word list in `scripts/bash/lib/cli.sh` and `scripts/powershell/lib/Cli.psm1`, and in the dispatchers `scripts/bash/spec-kit-jira.sh` and `scripts/powershell/spec-kit-jira.ps1` (turns T005 green)

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: the five module pairs, the command surface, and the credential
guard that **every** user story depends on. This is plan.md phases 0–4 plus the
gate skeleton, plus the Principle IV obligation the cross-artifact analysis
found uncovered (T064, T065).

**⚠️ CRITICAL**: no user story work can begin until this phase is complete.

### Designator parsing — sink (research R2, contract `designator-grammar.md`)

- [ ] T007 [P] Write failing D1/D2 tests — key grammar and the three URL shapes — in `tests/bash/sink/test_designator.bats`
- [ ] T008 [P] Write the failing Pester twin in `tests/powershell/sink/Designator.Tests.ps1`
- [ ] T009 [P] Implement §2 grammar and §3 reduction in `scripts/bash/sink/jira/designator.sh`
- [ ] T010 [P] Implement the twin in `scripts/powershell/sink/jira/Designator.psm1`
- [ ] T011 [P] Write failing D3/D4 tests — `selectedIssue` wins over a key-shaped path segment; percent-decode before the grammar check — in `tests/bash/sink/test_designator.bats` and `tests/powershell/sink/Designator.Tests.ps1`
- [ ] T012 Implement rule-2-before-rule-3 precedence and percent-decoding in `scripts/bash/sink/jira/designator.sh` and `scripts/powershell/sink/jira/Designator.psm1`
- [ ] T013 [P] Write failing D5/D6 tests — host mismatch refuses with **zero requests issued**; a base URL with a path prefix still matches — in `tests/bash/sink/test_designator.bats` and `tests/powershell/sink/Designator.Tests.ps1`
- [ ] T014 Implement §4 host comparison (scheme, host case-insensitive minus trailing dot, port after scheme default) in `scripts/bash/sink/jira/designator.sh` and `scripts/powershell/sink/jira/Designator.psm1`
- [ ] T015 [P] Write failing D7/D9 tests — de-duplication on reduced keys across key and URL forms; position preserved under a shuffled response order — in `tests/bash/sink/test_designator.bats` and `tests/powershell/sink/Designator.Tests.ps1`
- [ ] T016 Implement §6 ordering and de-duplication (keep the earlier occurrence's position) in `scripts/bash/sink/jira/designator.sh` and `scripts/powershell/sink/jira/Designator.psm1`
- [ ] T017 [P] Write the failing D10 test — a designator with a trailing CR reduces identically on all three OSes — in `tests/bash/sink/test_designator.bats` and `tests/powershell/sink/Designator.Tests.ps1`
- [ ] T018 Implement the CR-by-CR trim in `scripts/bash/sink/jira/designator.sh`, with **no `$'\r\n'` inside any glob pattern** (research R11), and the twin in `scripts/powershell/sink/jira/Designator.psm1`

### CLI flags (research R6, contract `seed-cli-contract.md` §2)

- [ ] T019 [P] Write the failing test asserting `--parent` and `--story` accumulate into `\x1f`-joined streams and that a free-text parent containing spaces survives intact, in `tests/bash/lib/test_cli_designators.bats`
- [ ] T020 [P] Write the failing Pester twin in `tests/powershell/lib/Cli.Designators.Tests.ps1`
- [ ] T021 [P] Implement `--parent`, `--story`, and `--confirm` in `scripts/bash/lib/cli.sh`, emitting `parent_seen`, `parent`, `stories`, `confirm` in the shared fixed key order
- [ ] T022 [P] Implement the twin in `scripts/powershell/lib/Cli.psm1`
- [ ] T023 [P] Write the failing D8 test — a blank `--parent` refuses with `REF-DESIGNATOR` while an absent `--parent` takes the ordinary parent behaviour — in `tests/bash/lib/test_cli_designators.bats` and `tests/powershell/lib/Cli.Designators.Tests.ps1`
- [ ] T024 Implement the `parent_seen`-versus-`parent` distinction in `scripts/bash/lib/cli.sh` and `scripts/powershell/lib/Cli.psm1`

### The adoption read — sink (research R4/R5, contract `seed-cli-contract.md` §6)

- [ ] T025 [P] Write the failing C-14 test — 100 designators produce 1 `bulkfetch`, 101 produce 2, neither spawns a process per issue — in `tests/bash/sink/test_adoption.bats`
- [ ] T026 [P] Write the failing Pester twin in `tests/powershell/sink/Adoption.Tests.ps1`
- [ ] T027 [P] Implement the chunked fail-**closed** bulk read with the research R5 field union in `scripts/bash/sink/jira/adoption.sh` (do **not** modify `prefetch.sh` — see research R4)
- [ ] T028 [P] Implement the twin in `scripts/powershell/sink/jira/Adoption.psm1`
- [ ] T029 [P] Write the failing C-15 test — the request body reaches `jira_request` through a temp file, never through argv — in `tests/bash/sink/test_adoption.bats` and `tests/powershell/sink/Adoption.Tests.ps1`
- [ ] T030 Implement the temp-file body path in `scripts/bash/sink/jira/adoption.sh` and `scripts/powershell/sink/jira/Adoption.psm1`
- [ ] T031 [P] Write failing tests for the seven state-dependent refusal classes — `REF-UNRESOLVED`, `REF-ROLE`, `REF-ROUTING`, `REF-MULTIPROJECT`, `REF-TERMINAL`, `REF-CLAIMED`, `REF-THIN` — asserting zero writes and a named remediation each, **and** the FR-037 assertion that `REF-UNRESOLVED`'s message never claims to know whether the key is deleted or merely invisible, since `bulkfetch` reports both as absence and a message that guesses sends the operator down the wrong path — in `tests/bash/sink/test_adoption.bats` and `tests/powershell/sink/Adoption.Tests.ps1`
- [ ] T032 Implement refusal evaluation in `scripts/bash/sink/jira/adoption.sh` and `scripts/powershell/sink/jira/Adoption.psm1`, with `REF-UNRESOLVED` never claiming to distinguish deleted from forbidden
- [ ] T033 [P] Write the failing C-4 test — three mistyped designators are reported **together**, not one per run — in `tests/bash/sink/test_adoption.bats` and `tests/powershell/sink/Adoption.Tests.ps1`
- [ ] T034 Implement aggregate refusal reporting in `scripts/bash/sink/jira/adoption.sh` and `scripts/powershell/sink/jira/Adoption.psm1`
- [ ] T035 [P] Write the failing test asserting the current parents' summary and status are folded into the **same** `bulkfetch` call as a second id list, in `tests/bash/sink/test_adoption.bats` and `tests/powershell/sink/Adoption.Tests.ps1`
- [ ] T036 Implement the second id list in `scripts/bash/sink/jira/adoption.sh` and `scripts/powershell/sink/jira/Adoption.psm1`

### The pinning marker — engine (research R3, contract `pin-marker.md`)

- [ ] T037 [P] Write the failing P-1 test — `pin=` parses as `none` in the story, spec, and task parsers, and each of their bodies parses as `none` in the pin parser — in `tests/bash/engine/test_pin_marker.bats`
- [ ] T038 [P] Write the failing Pester twin in `tests/powershell/engine/PinMarker.Tests.ps1`
- [ ] T039 [P] Implement `pin_marker_format` and `pin_marker_parse_line` in `scripts/bash/engine/pin_marker.sh`, reusing `marker_splice.sh`
- [ ] T040 [P] Implement the twin in `scripts/powershell/engine/PinMarker.psm1`, reusing `MarkerSplice.psm1`
- [ ] T041 Add the reciprocal `pin=` fall-through guard to `scripts/bash/engine/{story_marker.sh,spec_marker.sh,task_marker.sh}` and `scripts/powershell/engine/{StoryMarker,SpecMarker,TaskMarker}.psm1` (closes P-1 in both directions)
- [ ] T042 [P] Write the failing P-2 test — placement at the `###`, `##`, `####` heading anchors and the H1 fallback — in `tests/bash/engine/test_pin_marker.bats` and `tests/powershell/engine/PinMarker.Tests.ps1`
- [ ] T043 Implement placement via the existing `_smk_scan_anchors` scan in `scripts/bash/engine/pin_marker.sh` and `scripts/powershell/engine/PinMarker.psm1`
- [ ] T044 [P] Write failing P-3/P-4 tests — each of the four §5 properties fails independently, naming the offending key and line; all four violations at once are reported together — in `tests/bash/engine/test_pin_marker.bats` and `tests/powershell/engine/PinMarker.Tests.ps1`
- [ ] T045 Implement `pin_marker_validate` over the four properties in `scripts/bash/engine/pin_marker.sh` and `scripts/powershell/engine/PinMarker.psm1`
- [ ] T046 [P] Write the failing P-9 test — validating 100 markers spawns no process per marker — in `tests/bash/engine/test_pin_marker.bats` and `tests/powershell/engine/PinMarker.Tests.ps1`
- [ ] T047 Implement the single-pass marker collection in `scripts/bash/engine/pin_marker.sh` and `scripts/powershell/engine/PinMarker.psm1`

### The seed record — lib (research R8, contract `seed-record.md`)

- [ ] T048 [P] Write failing S-1/S-8 tests — the record is written with `bindings: []` and the ordered designator set, byte-identical between ports — in `tests/bash/lib/test_seed_state.bats`
- [ ] T049 [P] Write the failing Pester twin in `tests/powershell/lib/SeedState.Tests.ps1`
- [ ] T050 [P] Implement schema 1, `seed_state_path`, compose, read, and delete in `scripts/bash/lib/seed_state.sh`, canonicalising through `lib/output.sh`
- [ ] T051 [P] Implement the twin in `scripts/powershell/lib/SeedState.psm1`
- [ ] T052 [P] Write the failing S-9 test — the record is gitignored and never appears in `git status` — in `tests/bash/lib/test_seed_state.bats` and `tests/powershell/lib/SeedState.Tests.ps1`
- [ ] T053 Confirm or extend the `.specify/jira/state/` gitignore coverage in the scaffolding written by `scripts/bash/commands/config.sh` and `scripts/powershell/commands/Config.psm1`

### Slug derivation (research R9, FR-059/FR-060)

- [ ] T054 [P] Write the failing test covering all five FR-059 shapes, including the free-text-parent-with-no-stories case falling through to the ordinary naming, in `tests/bash/commands/test_feature_designators.bats` and its Pester twin
- [ ] T055 Implement the number-source selection in `scripts/bash/commands/feature.sh` step (5) and `scripts/powershell/commands/Feature.psm1` — **`engine/naming.sh` and `Naming.psm1` gain zero lines**

### The seed command and the confirmation gate (research R1/R7)

- [ ] T056 [P] Write the failing C-7 test — the gate without `--confirm` performs zero mutations, emits `confirmation_required`, and exits 0 — in `tests/bash/commands/test_seed.bats`
- [ ] T057 [P] Write the failing Pester twin in `tests/powershell/commands/Seed.Tests.ps1`
- [ ] T058 [P] Implement the command skeleton and the `confirmation_required` payload — reusing `feature.sh`'s existing shape — in `scripts/bash/commands/seed.sh`
- [ ] T059 [P] Implement the twin in `scripts/powershell/commands/Seed.psm1`

### Reachability — the `mention` lesson (plan.md phase 8)

- [ ] T060 [P] Write the failing packaging test asserting `extension.yml` declares `speckit.jira.seed` under `provides.commands` and binds it to **no** hook event, in `tests/bash/packaging/test_manifest.bats`
- [ ] T061 Declare `speckit.jira.seed` in `extension.yml` under `provides.commands`
- [ ] T062 [P] Write `commands/speckit.jira.seed.md` — the agent-facing definition, carrying FR-015 as normative drafting text, the FR-056 marker format, and the FR-054 ordering obligation (research R12)
- [ ] T063 [P] Extend `commands/speckit.jira.feature.md` with the designator flags and the **mandatory follow-up invocation** of `speckit.jira.seed` (research R1's conveyance mitigation)
- [ ] T064 [P] Write the failing FR-047 test — at maximum verbosity, across moment 1 and moment 2 and **every refusal path**, the token appears in no stdout, stderr, or trace output, and no new value reaches argv where `ps` could read it — in `tests/bash/sink/test_designator.bats`, `tests/bash/commands/test_seed.bats` and their PowerShell twins
- [ ] T065 Audit and fix credential exposure across `scripts/bash/sink/jira/{designator.sh,adoption.sh}`, `scripts/bash/commands/seed.sh`, `scripts/bash/lib/seed_state.sh` and their PowerShell twins

**Checkpoint**: every module pair exists and is unit-green. No user story behaviour yet.

---

## Phase 3: User Story 5 — The ordinary run is untouched (Priority: P1)

**Goal**: prove that every existing consumer is unaffected before any new behaviour is layered on.

**Independent Test**: run the existing feature-naming conformance scenarios unmodified and assert byte-identical stdout, identical exit codes, and an identical recorded request sequence.

**Why first**: this is the regression pin that protects everyone already using the extension. plan.md requires it green before any other work is called done.

- [ ] T066 [P] [US5] Write the C-1 pinning test — an invocation with neither new flag is byte-identical in stdout, exit code, and request sequence to the current release — in `tests/bash/commands/test_feature.bats` and its Pester twin
- [ ] T067 [P] [US5] Write the C-6 test — an unreachable Jira **without** designators still emits `{active:false}` plus exactly one warning and exits 0 — in `tests/bash/commands/test_feature.bats` and `tests/powershell/commands/Feature.Tests.ps1`
- [ ] T068 [US5] Verify the existing feature conformance scenarios pass unmodified via `bash tests/conformance/ci-conformance.sh`
- [ ] T069 [P] [US5] Add the conformance scenario `tests/conformance/scenarios/us027-no-designators-untouched.json`

**Checkpoint**: the existing ceremony is provably unchanged.

---

## Phase 4: User Story 1 — Story-role issues only, no parent named (Priority: P1) 🎯 MVP

**Goal**: seed `spec.md` from named story-role issues, pin them deterministically, and bind them — with no parent write of any kind.

**Independent Test**: against a mocked double holding three story-role issues with distinct descriptions, invoke naming all three; assert `spec.md` carries exactly three pinning markers in designator order, assert three bindings with `origin: human`, assert zero issues created.

- [ ] T070 [P] [US1] Write the failing test — three designators supplied as a bare key, a browse URL, and a board URL resolve to three keys in **one** `bulkfetch` — in `tests/bash/commands/test_feature_designators.bats` and its Pester twin
- [ ] T071 [P] [US1] Wire moment 1 in `scripts/bash/commands/feature.sh`: parse → host check → de-duplicate → `REF-EXISTS` → resolve → refuse → slug → record → emit seed material, in the contract §3 order
- [ ] T072 [P] [US1] Implement the twin in `scripts/powershell/commands/Feature.psm1`
- [ ] T073 [P] [US1] Write the failing C-5 test — with designators supplied and Jira unreachable, the run exits `EXIT_FAILCLOSED` (2) and **never** takes `_feat_fallback`'s `{active:false}` + warning path — in `tests/bash/commands/test_feature_designators.bats` and `tests/powershell/commands/Feature.Designators.Tests.ps1`
- [ ] T074 [US1] Conditionalise `_feat_fallback` on the absence of designators in `scripts/bash/commands/feature.sh` and `scripts/powershell/commands/Feature.psm1`, leaving the designator-free path byte-identical (guarded by T066)
- [ ] T075 [P] [US1] Write the failing test asserting the seed material payload travels by **file**, not through argv, and that multi-line output goes through `lib/output.sh`, in `tests/bash/commands/test_feature_designators.bats` and `tests/powershell/commands/Feature.Designators.Tests.ps1`
- [ ] T076 [US1] Implement seed material emission in `scripts/bash/commands/feature.sh` and `scripts/powershell/commands/Feature.psm1`
- [ ] T077 [P] [US1] Write the failing FR-065 tests with one fixture per tier — a known coordinate in a seeded description BLOCKs with the dedicated block exit code and zero bytes written; a generic email WARNs without blocking; an allowlisted Confluence link passes silently — in `tests/bash/commands/test_seed_privacy.bats` and `tests/powershell/commands/Seed.Privacy.Tests.ps1`
- [ ] T078 [US1] Wire `privacy_guard_scan` over the seed material **before** it is handed to the agent in `scripts/bash/commands/feature.sh`, and over `spec.md` before the first mutation in `scripts/bash/commands/seed.sh`, plus their PowerShell twins, reusing `scripts/bash/sink/jira/privacy_guard.sh` and `privacy_allowlist_load`
- [ ] T079 [P] [US1] Write the failing test asserting `REF-DECOMP` fires on each of the four `pin-marker.md` §5 properties and names the offending key and line, in `tests/bash/commands/test_seed.bats` and its Pester twin
- [ ] T080 [US1] Wire `pin_marker_validate` into `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T081 [P] [US1] Write the failing test asserting binding writes the identity marker with `origin: human` and `role: story`, stamped and recorded **immediately per ticket, never batched**, in `tests/bash/commands/test_seed.bats` and `tests/powershell/commands/Seed.Tests.ps1`
- [ ] T082 [US1] Implement binding in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`, reusing `sink/jira/identity.sh`
- [ ] T083 [P] [US1] Write the failing P-7/P-8 tests — the pinning marker is replaced in place preserving every other byte and the line ending; an interrupted consumption leaves exactly the completed replacements — in `tests/bash/commands/test_seed.bats` and `tests/powershell/commands/Seed.Tests.ps1`
- [ ] T084 [US1] Implement pin consumption via `marker_splice` in `scripts/bash/engine/pin_marker.sh` and `scripts/powershell/engine/PinMarker.psm1`, writing the on-disk identifier **before** the Jira write
- [ ] T085 [P] [US1] Write the failing C-16 test — `--dry-run` predicts the identical action set and writes **no** seed record — in `tests/bash/commands/test_seed.bats` and `tests/powershell/commands/Seed.Tests.ps1`
- [ ] T086 [US1] Implement the dry-run path in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T087 [P] [US1] Write the failing C-13 test — a second identical run against a bound specification produces 0 writes of every kind and 0 changed local bytes — in `tests/bash/commands/test_seed.bats` and `tests/powershell/commands/Seed.Tests.ps1`
- [ ] T088 [US1] Verify idempotency end to end by running `tests/bash/commands/test_seed.bats` and `tests/powershell/commands/Seed.Tests.ps1` twice against the same state, asserting the second run reports zero writes
- [ ] T089 [P] [US1] Add conformance scenarios `us027-three-url-forms.json` and `us027-bind-stories.json` in `tests/conformance/scenarios/`

**Checkpoint**: the MVP. Stories are adopted, pinned, and bound with zero creates and zero parent writes.

---

## Phase 5: User Story 3 — A parent that already exists (Priority: P1)

**Goal**: adopt an operator-named existing parent and create the unpinned user stories beneath it.

**Independent Test**: with one parent-role issue and two story-role issues in the double, invoke naming all three; assert the parent is read and never created, its marker records `origin: human` and `role: parent`, and the created stories land under it.

- [ ] T090 [P] [US3] Write the failing test — an existing parent is adopted, never created, and its marker records `origin: human` with `role: parent` — in `tests/bash/commands/test_seed.bats` and its Pester twin
- [ ] T091 [US3] Implement parent adoption in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T092 [P] [US3] Write the failing test asserting `REF-ROLE` when the named parent's type does not match `hierarchy.specification`, naming the key, the type found, and the declared type, in `tests/bash/commands/test_feature_designators.bats` and `tests/powershell/commands/Feature.Designators.Tests.ps1`
- [ ] T093 [US3] Wire role validation into `scripts/bash/commands/feature.sh` and `scripts/powershell/commands/Feature.psm1`
- [ ] T094 [P] [US3] Write the failing SC-002 test — user stories with no pinning marker become new issues under the adopted parent, the story-role count is exactly `drafted − pinned`, **and a created parent is counted separately**: never part of that arithmetic, reported on its own line of the run summary, and zero whenever the parent was adopted or none was designated — in `tests/bash/commands/test_seed.bats` and `tests/powershell/commands/Seed.Tests.ps1`
- [ ] T095 [US3] Implement create-under-parent in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T096 [P] [US3] Write the failing FR-014 test exercising the non-default hierarchy fixture from T004 (SAFe-shaped roles, renamed types), in `tests/bash/commands/test_seed.bats` and `tests/powershell/commands/Seed.Tests.ps1`
- [ ] T097 [US3] Verify role resolution reads only the effective `hierarchy` configuration — no literal type name in `scripts/bash/sink/jira/{designator.sh,adoption.sh}`, `scripts/bash/commands/seed.sh`, or their PowerShell twins
- [ ] T098 [P] [US3] Add the conformance scenario `us027-adopt-existing-parent.json` in `tests/conformance/scenarios/`

**Checkpoint**: the full P1 adoption slice works under an operator-named parent.

---

## Phase 6: User Story 6 — The human's content survives (Priority: P1)

**Goal**: prove field class by field class what a bound issue undergoes, and that the one-way read holds.

**Independent Test**: capture every field of each named issue before the ceremony, run the ceremony and a full reconcile, and diff — only the enumerated writable classes may differ.

- [ ] T099 [P] [US6] Write the failing quickstart Scenario 2 test — after seeding, editing every named issue's description and summary in Jira, then running `plan`, `tasks`, and a full `reconcile`, `spec.md` is **byte-identical** — in `tests/bash/commands/test_seed_oneway.bats` and its Pester twin
- [ ] T100 [US6] Verify the one-way read in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1` — no code path may use a read to rewrite a local artifact
- [ ] T101 [P] [US6] Write the failing FR-030 test — the managed boundary marker and its panel are appended **below** a human's existing description at the first reconcile after binding, placing every pre-existing byte above it — in `tests/bash/commands/test_seed_oneway.bats` and `tests/powershell/commands/Seed.OneWay.Tests.ps1`
- [ ] T102 [US6] Implement or verify boundary introduction on a human-origin adopted ticket in the existing `engine/managed_section.sh` path and its `ManagedSection.psm1` twin
- [ ] T103 [P] [US6] Write the failing field-inventory test — comments, attachments, assignee, reporter, sprint, estimate, priority, issue links, and hand-applied labels are all unchanged; only the enumerated classes differ — in `tests/bash/commands/test_seed_oneway.bats` and `tests/powershell/commands/Seed.OneWay.Tests.ps1`
- [ ] T104 [US6] Verify field preservation in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1` against the FR-030 inventory
- [ ] T105 [P] [US6] Write the failing test asserting a human edit to the preserved region **after** binding still survives the next reconcile, in `tests/bash/commands/test_seed_oneway.bats` and `tests/powershell/commands/Seed.OneWay.Tests.ps1`
- [ ] T106 [P] [US6] Add the conformance scenario `us027-human-content-preserved.json` in `tests/conformance/scenarios/`

**Checkpoint**: P1 complete. This is the shippable slice — no irreversible write exists anywhere in it.

---

## Phase 7: User Story 7 — Provenance, decline, and resume (Priority: P2)

**Goal**: make the gate legible, and make declining a recoverable state rather than a dead end.

**Independent Test**: invoke the gate and assert the provenance report and write plan precede the first mutation; decline and assert the seeded-not-bound state; edit `spec.md`; resume and assert the plan reflects the current file with a delta.

- [ ] T107 [P] [US7] Write the failing test — the provenance report maps each drafted user story to its source (key or `new`) and each named issue to the section it seeded, emitted before the first mutation — in `tests/bash/commands/test_seed_gate.bats` and its Pester twin
- [ ] T108 [US7] Implement provenance rendering in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`, through `lib/output.sh`
- [ ] T109 [P] [US7] Write the failing C-8 test — declining leaves the seed record present, the pinning markers present, and **zero** identity markers on either side — in `tests/bash/commands/test_seed_gate.bats` and `tests/powershell/commands/Seed.Gate.Tests.ps1`
- [ ] T110 [US7] Implement the decline path in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T111 [P] [US7] Write failing C-9/C-10/S-2/S-3/S-4 tests — resume with the same set returns to the gate with `spec.md` byte-identical and no `REF-EXISTS`; a different set refuses `REF-RESEED`; the recorded slug is read, not re-derived, proven by editing the description between decline and resume; a key and its URL compare equal; reordered `--story` flags refuse — in `tests/bash/commands/test_seed_gate.bats` and `tests/powershell/commands/Seed.Gate.Tests.ps1`
- [ ] T112 [US7] Implement the resume path in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T113 [P] [US7] Write the failing C-11 test — a resume re-evaluates **every** refusal class against the re-read state, so a story closed, moved, or claimed between decline and resume refuses normally — in `tests/bash/commands/test_seed_gate.bats` and `tests/powershell/commands/Seed.Gate.Tests.ps1`
- [ ] T114 [US7] Implement full re-evaluation on resume in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`, never requesting comment bodies
- [ ] T115 [P] [US7] Write the failing P-5/P-6 tests — a prose rewrite, an added scenario, a renamed heading, and a new unpinned user story all pass; a deleted, duplicated, or moved pinned marker refuses with `REF-DRAFT-EDIT` on resume and `REF-DECOMP` on a first run — in `tests/bash/commands/test_seed_gate.bats` and `tests/powershell/commands/Seed.Gate.Tests.ps1`
- [ ] T116 [US7] Implement `REF-DRAFT-EDIT` as a class distinct from `REF-DECOMP`, with its own remediation, in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T117 [P] [US7] Write the failing C-12 test — the plan is recomputed from the current `spec.md` and the delta against the previously displayed plan names added and vanished lines — in `tests/bash/commands/test_seed_gate.bats` and `tests/powershell/commands/Seed.Gate.Tests.ps1`
- [ ] T118 [US7] Implement plan recomputation and the `plan_digest` delta in `scripts/bash/commands/seed.sh`, `scripts/powershell/commands/Seed.psm1`, and `lib/seed_state.sh` / `SeedState.psm1`
- [ ] T119 [P] [US7] Add conformance scenarios `us027-decline-resume.json` and `us027-draft-edit-refused.json` in `tests/conformance/scenarios/`

**Checkpoint**: the gate is legible and the decline is recoverable.

---

## Phase 8: User Story 4 — A parent alone (Priority: P2)

**Goal**: seed from a parent's content only, with no pinning constraint at all.

**Independent Test**: with a single parent-role issue carrying a substantial description, invoke naming only it; assert the drafted specification traces to that description, that no user story is pinned, and that the following reconcile creates one issue per drafted user story under it.

- [ ] T120 [P] [US4] Write the failing test — a parent-only invocation imposes no pinning constraint, so the drafting agent chooses the story count freely and `pin_marker_validate` passes over zero markers — in `tests/bash/commands/test_seed.bats` and its Pester twin
- [ ] T121 [US4] Implement the parent-only path in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T122 [P] [US4] Write the failing test — every drafted user story is created beneath the named parent, and the parent itself is never duplicated — in `tests/bash/commands/test_seed.bats` and `tests/powershell/commands/Seed.Tests.ps1`
- [ ] T123 [US4] Verify parent-only creation in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T124 [P] [US4] Add the conformance scenario `us027-parent-only.json` in `tests/conformance/scenarios/`

---

## Phase 9: User Story 2 — A parent that does not exist yet (Priority: P2)

**Goal**: create a parent from a free-text title and re-parent named stories onto it.

**Independent Test**: with two unparented story-role issues and no parent in the double, invoke naming a free-text parent and the two stories; assert exactly one parent-role issue is created with **no lookup issued**, both stories are re-parented onto it, and a second identical invocation creates nothing.

**⚠️ This phase contains the only two irreversible writes in the feature.** It is deliberately last: the P1 slice must be green and dogfooded first.

- [ ] T125 [P] [US2] Write the failing test — a free-text parent designator creates exactly one issue and **no lookup of any kind is issued** to check whether such a parent exists — in `tests/bash/commands/test_seed_parent.bats` and its Pester twin
- [ ] T126 [US2] Implement parent creation in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`, with the type resolved from `hierarchy.specification`
- [ ] T127 [P] [US2] Write the failing test — the created parent's summary is the operator's free text and its description body is the drafted overview — in `tests/bash/commands/test_seed_parent.bats` and `tests/powershell/commands/Seed.Parent.Tests.ps1`
- [ ] T128 [US2] Implement content derivation in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T129 [P] [US2] Write the failing FR-052 test — a human rename of the created parent survives every later reconcile, the free text is never re-applied, and the divergence is reported rather than reverted — in `tests/bash/commands/test_seed_parent.bats` and `tests/powershell/commands/Seed.Parent.Tests.ps1`
- [ ] T130 [US2] Verify creation-seed-only semantics against the existing summary record in `scripts/bash/sink/jira/identity.sh` and `scripts/powershell/sink/jira/Identity.psm1`
- [ ] T131 [P] [US2] Write the failing C-17 test — the re-parenting line renders **visually distinct** from every adopt and create line, naming the current parent by key, summary, and status, and stating the child-loss count even when it is one — in `tests/bash/commands/test_seed_parent.bats` and `tests/powershell/commands/Seed.Parent.Tests.ps1`
- [ ] T132 [US2] Implement the re-parenting disclosure in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T133 [P] [US2] Write the failing test — re-parenting fires **only** onto an operator-designated parent and never in a run where the specification role was left undesignated — in `tests/bash/commands/test_seed_parent.bats` and `tests/powershell/commands/Seed.Parent.Tests.ps1`
- [ ] T134 [US2] Implement the operator-designated scoping of placement and re-parenting in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T135 [P] [US2] Write the failing C-18 test — with no parent designator, each named story still under an existing parent produces a scatter note in the provenance report **and** the run summary, with a remediation, at exit 0 and zero writes — in `tests/bash/commands/test_seed_parent.bats` and `tests/powershell/commands/Seed.Parent.Tests.ps1`
- [ ] T136 [US2] Implement the FR-061 disclosure in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T137 [P] [US2] Write the failing test asserting a partially completed run reports exactly which bindings completed and which did not, and that the next invocation resumes from them (research R14), in `tests/bash/commands/test_seed_parent.bats` and `tests/powershell/commands/Seed.Parent.Tests.ps1`
- [ ] T138 [US2] Implement partial-run reporting and resumption in `scripts/bash/commands/seed.sh` and `scripts/powershell/commands/Seed.psm1`
- [ ] T139 [P] [US2] Add conformance scenarios `us027-create-parent.json`, `us027-reparent-disclosure.json`, and `us027-scatter-note.json` in `tests/conformance/scenarios/`

**Checkpoint**: all seven user stories independently functional.

---

## Phase 10: Polish & cross-cutting concerns

- [ ] T140 [P] Add budget assertions using 024's `PATH`-interposed counting stand-ins — 1 `bulkfetch` at 100 designators, 2 at 101, no per-issue spawn, body via temp file — in runs **separate** from any timing run, in `tests/bash/ci/` and `tests/powershell/ci/`
- [ ] T141 [P] Verify statement coverage stays at or above 80% on both ports via the coverage jobs in `.github/workflows/`, with the critical paths (fail-closed, idempotency, privacy guard, credential resolution) near total
- [ ] T142 [P] Run `find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +` and `actionlint`, both clean
- [ ] T143 [P] Verify the boundary greps in `.github/workflows/boundary.yml` still pass — no engine script under `scripts/bash/engine/` or `scripts/powershell/engine/` contains an issue-key pattern, a host, or a type name, and none sources a sink file
- [ ] T144 [P] Update `docs/06-feature-naming.md` with the designator flags and the two-moment flow
- [ ] T145 [P] Update `docs/08-safety-model.md` with the pinning marker and the seeded-not-bound state machine
- [ ] T146 [P] Update `README.md` and `INSTALL.md` with the seeding ceremony, and record in the operator-facing text that a decision living in a comment thread will not reach `spec.md` (FR-020's documented consequence)
- [ ] T147 [P] Move brownfield seeding from envisioned to shipped in `docs/VISION.md`, and update §6's note that `mention` is unreachable
- [ ] T148 Add the CHANGELOG entry and bump the version in `extension.yml` only — the literal appears nowhere else in the tree
- [ ] T149 Extend the double-run assertion in `tests/live/test_live_zero_churn.bats` to the write kinds this feature adds — the identity stamp on an adopted issue, the parent-link write, and the parent create — asserting the second run issues zero writes of every kind against a real instance (Bash only: there is no PowerShell live twin, and the asymmetry belongs in the CHANGELOG entry)
- [ ] T150 [P] Write the C-2 uniform-property test — each of the fourteen refusal classes performs zero writes, names the offending designator or marker, carries a copy-pasteable remediation, and exits `EXIT_CONFIG` (4) — in `tests/bash/commands/test_seed_refusals.bats` and `tests/powershell/commands/Seed.Refusals.Tests.ps1`
- [ ] T151 Add one conformance scenario per refusal class — `us027-refuse-{designator,host,unresolved,routing,role,claimed,terminal,multiproject,duplicate,thin,decomp,draft-edit,reseed,exists}.json` — in `tests/conformance/scenarios/`, closing FR-039's per-class obligation and SC-006's "14 of 14"
- [ ] T152 [P] Generalise the C-3 assertion — every refusal at `contracts/seed-cli-contract.md` §3 steps 1-4 issues **zero** requests, not only the host mismatch — in `tests/bash/commands/test_seed_refusals.bats` and `tests/powershell/commands/Seed.Refusals.Tests.ps1`
- [ ] T153 Run the full suites: `tests/run-bash.sh`, the Pester suite, and `bash tests/conformance/ci-conformance.sh` (exit 0 with zero divergence lines — success is silent)
- [ ] T154 Push to `ci/windows-probe` and triage the result **against the known-red baseline** before attributing any failure to this feature; one retry maximum
- [ ] T155 Verify the three-OS matrix defined in `.github/workflows/` is green on ubuntu, macos, and windows
- [ ] T156 Dogfood against a real Jira instance on a **company-managed** and a **team-managed** project, exercising all three URL shapes of `contracts/designator-grammar.md` §3 and an invisible-issue case; record the outcome in the CHANGELOG entry of T148
- [ ] T157 Confirm an agent can actually reach `/speckit.jira.seed` end to end — the `mention` lesson, and the difference between "built" and "usable"

---

## Dependencies & execution order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup. **Blocks every user story.**
- **US5 (Phase 3)**: depends on Phase 2. Depends on nothing else and should be green before any other story is called done.
- **US1 (Phase 4)**: depends on Phase 2. The MVP.
- **US3 (Phase 5)**: depends on Phase 4 — it adds the parent to US1's mechanism.
- **US6 (Phase 6)**: depends on Phase 4 (needs a bound ticket to preserve content on).
- **US7 (Phase 7)**: depends on Phase 4 (needs a plan to decline).
- **US4 (Phase 8)**: depends on Phase 5 (reuses parent adoption).
- **US2 (Phase 9)**: depends on Phase 5. Deliberately last — the irreversible writes.
- **Polish (Phase 10)**: depends on every story intended for the release.

### Within each phase

- Every implementation task is preceded by its failing test task (Constitution XIII).
- The failing test MUST be observed to fail before its implementation begins.
- Bash and PowerShell twins may proceed in parallel; the conformance scenario for a behaviour comes after both.

### Parallel opportunities

- **The two ports are the dominant axis**: any Bash task and its PowerShell twin are different files with no dependency (T007/T008, T009/T010, T027/T028, T039/T040, T050/T051, T058/T059 …).
- All Setup tasks except T006 are `[P]`.
- Within Foundational, the five module pairs are independent of one another: designator (T007–T018), CLI flags (T019–T024), adoption (T025–T036), pin marker (T037–T047), and seed record (T048–T053) can be developed by five people at once. The credential audit (T064–T065) comes last in the phase, because it asserts a property of every module the phase produced.
- Once Phase 4 is complete, US3, US6, and US7 are independent of each other.
- Every documentation task in Phase 10 is `[P]`.

### Parallel example — Foundational

```bash
# Five module pairs, ten files, no dependency between them:
Task: "T007 failing D1/D2 tests in tests/bash/sink/test_designator.bats"
Task: "T008 failing Pester twin in tests/powershell/sink/Designator.Tests.ps1"
Task: "T019 failing CLI flag test in tests/bash/lib/test_cli_designators.bats"
Task: "T025 failing C-14 test in tests/bash/sink/test_adoption.bats"
Task: "T037 failing P-1 test in tests/bash/engine/test_pin_marker.bats"
Task: "T048 failing S-1/S-8 test in tests/bash/lib/test_seed_state.bats"
```

---

## Implementation strategy

### MVP — Phases 1 through 4

Setup, Foundational, US5, US1. This delivers seeding, deterministic pinning, and
binding of named story-role issues, with **zero creates and zero parent writes**.
Stop here and validate: run quickstart Scenario 1 and Scenario 2 against a real
instance.

### The shippable P1 slice — Phases 1 through 6

Add US3 (adopt an existing parent, create the rest beneath it) and US6 (prove the
human's content survives). **This is the release candidate the spec's priority
change was designed to produce**: nothing in it is irreversible, so it can be
dogfooded on a real board without risk to a team's backlog.

### Incremental delivery afterwards

1. **Phase 7 (US7)** — makes declining recoverable. Ship before US2: an operator
   who cannot decline safely should not be offered irreversible writes.
2. **Phase 8 (US4)** — parent alone. Small, reuses Phase 5.
3. **Phase 9 (US2)** — parent creation and re-parenting. Last, and dogfooded on a
   throwaway project before a real one.

### Parallel team strategy

With several developers, Phase 2 splits cleanly five ways along the module pairs;
after Phase 4, US3, US6, and US7 can proceed concurrently. The one sequencing
rule that must not be relaxed: **US2 does not start until the P1 slice is green
and dogfooded.**

---

## Notes

- `[P]` = different files, no dependency on an incomplete task.
- Verify every test fails before implementing it — Red, then Green, then Refactor.
- Commit after each task or logical group.
- **Conformance success is silent**: exit 0 with zero `conformance divergence` lines. There is no pass banner, and the temp paths in the output are harness noise.
- `tests/run-bash.sh --since <ref>` gives a ≤ 60 s inner loop; the full suite is ~190 s. `bats -r tests/bash` works but is serial and ~15 minutes — and without `-r` it silently runs nothing.
- Two decisions remain formally open in spec.md and are settled provisionally by the plan: **OD-4** (research R13 — the adopted/created distinction stays in the identity marker's `origin` field) and **OD-5** (research R14 — a partial run resumes and never rolls back, which Principle I and FR-040 jointly force). T137/T138 implement R14. Neither changes a requirement.
- **Ten tasks were added by the 2026-08-15 cross-artifact analysis**, which found five CRITICAL gaps. They share a shape worth remembering: every one was a **cross-cutting obligation belonging to no user story**, and story-driven task generation had walked straight past all five.
  - **T064, T065** — FR-047, credentials never in argv, logs, or traces. Principle IV names this test in as many words.
  - **T073, T074** — the C-5 fail-closed departure of FR-038. Its negative twin (C-6, without designators) already had a test; the positive case had none.
  - **T077, T078** — FR-065, the privacy guard over seeded content. The requirement itself did not exist before the analysis; it was asserted only in the plan's Constitution Check.
  - **T149** — Principle II's live double-run assertion, which must be extended in the same change that adds a write kind. Bash only — there is no PowerShell live twin, and that asymmetry belongs in the CHANGELOG.
  - **T150, T151, T152** — FR-039's per-class conformance obligation and SC-006's "14 of 14", plus the general form of C-3. They sit in Phase 10 because the corpus cannot be complete until the last refusal class lands in Phase 9; each class keeps its own unit test in its own phase.
- Task IDs were renumbered when those ten were inserted. Unlike FR numbers — cited from the contracts and the plan — task IDs are referenced only inside this file, and a list meant to be executed in order must have an execution order that matches its ID order.
