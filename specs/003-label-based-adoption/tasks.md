# Tasks: Label-Based Adoption of Pre-Existing Jira Tickets

**Input**: Design documents from `/specs/003-label-based-adoption/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: INCLUDED and MANDATORY. Constitution Principle XIII requires TDD with
≥80% statement coverage, and plan.md states every test task is ordered before its
implementation task. Every `[P]`-marked test task below must be written and
observed **failing** before the implementation task that satisfies it.

**Organization**: Tasks are grouped by user story so each story is independently
implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story the task belongs to (US1…US6)
- Every task carries an exact file path

## Path Conventions

Twin-port CLI extension, no new top-level directory (plan.md §Project Structure):

- Bash port: `scripts/bash/{engine,sink/jira,lib,commands}/`
- PowerShell port: `scripts/powershell/{engine,sink/jira,lib,commands}/`
- Bash tests: `tests/bash/{engine,sink,lib,commands,hooks,conformance}/*.bats`
- PowerShell tests: `tests/powershell/{engine,sink,lib,commands,hooks,conformance}/*.Tests.ps1`
- Shared conformance corpus: `tests/conformance/{scenarios,fixtures,mock-jira}/`
- Opt-in live suite: `tests/live/*.bats`

## ⚠️ Two constraints that invalidate work if violated

1. **Boundary grep scans comments.** `.github/workflows/boundary.yml` greps
   `scripts/*/engine/` for `[A-Z]{2,}-[0-9]+`, `atlassian`, `createmeta`,
   `customfield_[0-9]+` and fails on a match **inside comments too**.
   `engine/adoption.sh` and `engine/Adoption.psm1` may not carry a single
   example issue key, not even illustratively. Precedent: `engine/naming.sh`
   uses the pattern `[A-Z]*-*`. (research §8)
2. **The bridge-created wire value is `bridge-created` (hyphen)**, not the
   `bridge_created` the spec prose uses. The spec names the *concept*; the
   literal is pinned by research §4 and is what tests assert. Renaming would
   invalidate markers already stamped on live tickets.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: The two fixture repositories every later phase reads

- [X] T001 [P] Create conformance fixture `tests/conformance/fixtures/repo-with-adoption/` — three spec folders under `specs/` (one feature-level plus user stories in `spec.md`), and `.specify/jira/config.yml` carrying `adoption: {enabled: true, label_prefix: "speckit-adopt:"}` plus a `routing_default` project, mirroring the shape of `tests/conformance/fixtures/repo-with-spec/`
- [X] T002 [P] Create conformance fixture `tests/conformance/fixtures/repo-with-adoption-multi/` — five spec folders routed across two Jira projects (for `--spec` scoping, `wrong-project`, and the short-number collision), with two folders deliberately sharing the same leading numbering component

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Config key acceptance, command surface, module scaffolding, and the
JQL-aware mock server — nothing in any user story can run until these land

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. In
particular, without T005/T006 every adoption fixture is rejected as an unknown
top-level config key, and without T025–T028 no conformance scenario can express a
candidate corpus.

### Config key acceptance

- [X] T003 [P] Add a failing case to `tests/bash/lib/test_config.bats` asserting that a team `config.yml` carrying an `adoption:` section loads without an unknown-key error
- [X] T004 [P] Add the twin failing case to `tests/powershell/lib/Config.Tests.ps1`
- [X] T005 Add `"adoption"` to the team top-level key allowlist in `_CFG_TEAM_ERRORS_JQ` in `scripts/bash/lib/config.sh` (alongside `version_compat`, `projects`, `routing`, `routing_default`, `privacy`, `teams`)
- [X] T006 Add the twin allowlist entry in `scripts/powershell/lib/Config.psm1`

### Command surface

- [X] T007 [P] Add failing cases to `tests/bash/lib/test_cli.bats` for `cli_parse` accepting the `adopt` command and the boolean `--yes` flag, and rejecting `--on-drift` for `adopt` (per adopt-cli-contract §Flags)
- [X] T008 [P] Add the twin failing cases to `tests/powershell/lib/Cli.Tests.ps1`
- [X] T009 Implement `adopt` in the command list and `--yes` parsing in `scripts/bash/lib/cli.sh`, rejecting `--on-drift` for `adopt` with a usage error
- [X] T010 Implement the twin in `scripts/powershell/lib/Cli.psm1`, byte-identical key=value state lines
- [X] T011 [P] Add failing cases to `tests/bash/commands/test_dispatch.bats` asserting the usage block lists `adopt` and that the dispatcher routes `adopt` to its command module
- [X] T012 [P] Add the twin failing cases to `tests/powershell/commands/Dispatch.Tests.ps1`
- [X] T013 [P] Assert in `tests/bash/hooks/test_register_hooks.bats` that `adopt` never appears in the hook registration table and that `register_hooks` is unchanged by this feature — adoption requires operator confirmation and is never fired by a hook (FR-029)
- [X] T014 [P] Add the twin assertion to `tests/powershell/hooks/RegisterHooks.Tests.ps1`
- [X] T015 Update both usage strings (`usage: spec-kit-jira <config|reconcile|mention|feature|adopt>` at line 31 and the "a command is required" message at line 70) in `scripts/bash/spec-kit-jira.sh`
- [X] T016 Update the twin `$UsageLines` and the "a command is required" message in `scripts/powershell/spec-kit-jira.ps1`

### Module scaffolding

> These six tasks create behaviourless stubs so the dispatcher route and the
> module loaders resolve; they add no logic and are therefore not preceded by a
> test task. Every behaviour that lands in them afterwards is test-first.

- [X] T017 [P] Create `scripts/bash/engine/adoption.sh` — header documenting the boundary-grep constraint (no issue-key-shaped literal, **not even in a comment**, following the `engine/naming.sh` precedent), `set -u`-safe function stubs, no Jira mechanics
- [X] T018 [P] Create the twin `scripts/powershell/engine/Adoption.psm1` with the same header constraint and `Export-ModuleMember` surface
- [X] T019 [P] Create `scripts/bash/sink/jira/adoption.sh` — sink-side stub sourcing `client.sh` and `identity.sh`, where every issue-key-shaped literal is allowed to live
- [X] T020 [P] Create the twin `scripts/powershell/sink/jira/Adoption.psm1`
- [X] T021 [P] Create `scripts/bash/commands/adopt.sh` defining `cmd_adopt` (skeleton returning the not-yet-implemented usage code) so the dispatcher route in T015 resolves
- [X] T022 [P] Create the twin `scripts/powershell/commands/Adopt.psm1` exporting `Invoke-JiraAdopt`, returning only its numeric exit code per the dispatcher contract

### Mock server (JQL-aware discovery)

- [X] T023 [P] Add failing cases to `tests/powershell/conformance/Mock.Tests.ps1` for `GET /rest/api/3/search/jql` returning scenario-driven issues filtered by the JQL's `project` and `labels IN (…)` terms, and for multi-page results carrying `nextPageToken`
- [X] T024 [P] Add the twin failing cases to `tests/bash/conformance/test_mock_double.bats`
- [X] T025 Replace the fixed `search-siblings` response for `^/rest/api/3/(search|search/jql)$` with a JQL-aware handler driven by a per-scenario issues map in `tests/conformance/mock-jira/mock-server.ps1`, serving `issues[].key`, `fields.labels`, `fields.parent.key`, `fields.project.key` only
- [X] T026 Implement `nextPageToken` cursor pagination (page size honouring `maxResults`, token omitted on the last page) in the same handler in `tests/conformance/mock-jira/mock-server.ps1`
- [X] T027 Thread the new `mock.issues` scenario field (and per-issue identity markers consumed by the existing `Get-IdentityMarker` path) through `tests/conformance/run-scenario.sh` and `tests/conformance/mock-jira/lib.sh`
- [X] T028 Thread the same `mock.issues` field through `tests/conformance/mock-jira/Mock.psm1` so both port drivers seed identical corpora

**Checkpoint**: `spec-kit-jira adopt --help` works on both ports, adoption config
sections parse, and the mock can serve a labelled candidate corpus. User story
work can begin.

---

## Phase 3: User Story 1 - Adopt a hierarchy discovered by label (Priority: P1) 🎯 MVP

**Goal**: An operator enables adoption, labels existing tickets so each label
names a spec, runs `adopt`, sees a plan produced with zero writes, confirms, and
gets exactly one identity stamp (`origin: human`) per adopted ticket — no create,
delete, transition, comment, link, relabel, description, or summary write.

**Independent Test**: Against the mock double holding an Epic and two Stories
carrying spec-naming labels, and three spec folders on disk: run `adopt`, assert
the printed plan lists three bindings *before* any write, confirm, assert exactly
three `PUT /issue/*/properties/spec-kit-jira` calls and zero writes of every
other kind (quickstart Scenario 1).

### Tests for User Story 1 ⚠️ write first, observe failing

- [X] T029 [P] [US1] Label grammar tests in `tests/bash/engine/test_adoption_labels.bats` — the three forms of research §3 (`<prefix><folder>`, `<prefix><folder>:us<N>`, `<prefix><NNN>`), case-sensitive exact matching, prefix-alone and unknown-folder labels never derived, short form emitted only when the numbering component is unique in scope
- [X] T030 [P] [US1] Twin label grammar tests in `tests/powershell/engine/Adoption.Labels.Tests.ps1`
- [X] T031 [P] [US1] Target derivation tests in `tests/bash/engine/test_adoption_targets.bats` — one `feature` target per folder plus one `story` target per user story parsed from `spec.md`, `project_key` resolved through the existing `routing_resolve`, and the total ordering of data-model §2 (folder asc → feature before story → ordinal asc)
- [X] T032 [P] [US1] Twin target derivation tests in `tests/powershell/engine/Adoption.Targets.Tests.ps1`
- [X] T033 [P] [US1] Config tests in `tests/bash/lib/test_config.bats` — empty, whitespace-bearing, and >255-character-with-longest-suffix prefixes each produce a located configuration error with exit 4 before any search; `enabled` absent ⇒ disabled; **and `templates/config.yml.template` ships a self-documented `adoption:` section carrying `enabled` and `label_prefix` with explanatory comments** (FR-002, Principle XVI)
- [X] T034 [P] [US1] Twin config tests in `tests/powershell/lib/Config.Tests.ps1`
- [X] T035 [P] [US1] Discovery tests in `tests/bash/sink/test_adoption_search.bats` — JQL shape `project = "<KEY>" AND labels IN (…)`, one query per distinct routed project over the union of that project's labels, `fields=labels,parent,project`, `maxResults=100`, and pagination looping to token exhaustion so a multi-page corpus yields every candidate
- [X] T036 [P] [US1] Twin discovery tests in `tests/powershell/sink/Adoption.Search.Tests.ps1`
- [X] T037 [P] [US1] Claim-read tests in `tests/bash/sink/test_adoption_identity.bats` — one identity read per candidate, a 404 means "unclaimed" and is not a failure, marker fields `origin`/`spec_slug` surfaced onto the candidate JSON of data-model §4
- [X] T038 [P] [US1] Twin claim-read tests in `tests/powershell/sink/Adoption.Identity.Tests.ps1`
- [X] T039 [P] [US1] Command phase tests in `tests/bash/commands/test_adopt.bats` — `adoption.enabled` false/absent ⇒ exit 4 naming the config key with **zero reads against candidate tickets**; the plan is printed before any write; confirmation `y` applies; decline ⇒ exit 0 with zero writes and an "adoption cancelled" summary; non-TTY without `--yes` ⇒ dry-run-identical output naming `--yes` as the way to proceed
- [X] T040 [P] [US1] Twin command phase tests in `tests/powershell/commands/Adopt.Tests.ps1`
- [X] T041 [P] [US1] Stamp tests in `tests/bash/sink/test_adoption_stamp.bats` — the action set contains only `PUT /rest/api/3/issue/{key}/properties/spec-kit-jira`, the body is built by the existing `identity_marker` with `"origin":"human"`, and the set is executed through `apply_writes` (so the BLOCK guard and the abort ladder are inherited, research §7)
- [X] T042 [P] [US1] Twin stamp tests in `tests/powershell/sink/Adoption.Stamp.Tests.ps1`
- [X] T043 [P] [US1] Privacy-guard tests in `tests/bash/sink/test_adoption_privacy.bats` — a BLOCK-tier known coordinate in the tracked tree makes `adopt --yes` exit 9 with **zero property PUTs**; adoption claims no exemption because its action set goes through `apply_writes` (FR-028, FR-030, Principle IX)
- [X] T044 [P] [US1] Twin privacy-guard tests in `tests/powershell/sink/Adoption.PrivacyGuard.Tests.ps1`
- [X] T045 [P] [US1] Conformance scenario `tests/conformance/scenarios/us1-adopt-hierarchy.json` — three labelled candidates, `--yes --json`, asserting exactly three property PUTs and no other write kind
- [X] T046 [P] [US1] Conformance scenario `tests/conformance/scenarios/us1-adopt-disabled.json` — `adoption.enabled: false` on a fully labelled backlog ⇒ exit 4, zero candidate reads, zero writes (SC-009)
- [X] T047 [P] [US1] Conformance scenario `tests/conformance/scenarios/us1-adopt-decline.json` — operator declines ⇒ exit 0, zero writes, summary reports cancellation
- [X] T048 [P] [US1] Conformance scenario `tests/conformance/scenarios/us1-adopt-unnamed-label.json` — a ticket carrying the bare prefix and a ticket whose label names a folder absent from disk are never adopted and never guessed at (FR-003)
- [X] T049 [P] [US1] Conformance scenario `tests/conformance/scenarios/us1-adopt-privacy-block.json` — a BLOCK-tier match ⇒ exit 9 with zero writes in the call log (FR-028)
- [X] T050 [P] [US1] Conformance scenario `tests/conformance/scenarios/us1-adopt-team-managed.json` — the same labelled corpus served by a team-managed project binds and stamps identically to the company-managed case, proving adoption carries no project-style branch (NFR-5, Principle VII)
- [X] T051 [P] [US1] Conformance scenario `tests/conformance/scenarios/us1-adopt-invalid-prefix.json` — a whitespace-bearing `adoption.label_prefix` ⇒ located configuration error, exit 4, nothing searched and nothing written (FR-002, SC-005)
- [X] T052 [P] [US1] Conformance runner `tests/bash/conformance/test_us1_adopt.bats` driving the seven scenarios above through `tests/conformance/run-scenario.sh` on both ports and diffing the captures (NFR-1, SC-008)

### Implementation for User Story 1

- [X] T053 [US1] Add the self-documented `adoption:` section (`enabled: false`, `label_prefix: "speckit-adopt:"`, with business-language comments explaining opt-in and the three label forms) to `templates/config.yml.template` per data-model §1 and FR-002
- [X] T054 [US1] Implement `adoption_validate_prefix` and `adoption_labels_for` in `scripts/bash/engine/adoption.sh` — the three label forms, short-form uniqueness over the folders in scope, case-sensitive exact values, no issue-key literal anywhere in the file
- [X] T055 [US1] Implement the twin `Test-JiraAdoptionPrefix` / `Get-JiraAdoptionLabels` in `scripts/powershell/engine/Adoption.psm1`
- [X] T056 [US1] Implement `adoption_targets` in `scripts/bash/engine/adoption.sh` — folders in scope → feature and story targets, `routing_resolve` for `project_key`, the total ordering of data-model §2, emitted as canonical JSON
- [X] T057 [US1] Implement the twin `Get-JiraAdoptionTargets` in `scripts/powershell/engine/Adoption.psm1`
- [X] T058 [US1] Add the `adoption` schema rules (`enabled` boolean defaulting to false, `label_prefix` string validation) with located errors to `scripts/bash/lib/config.sh` per `contracts/adoption-config.schema.json`
- [X] T059 [US1] Implement the twin schema rules in `scripts/powershell/lib/Config.psm1`
- [X] T060 [US1] Implement `adopt_search_candidates` in `scripts/bash/sink/jira/adoption.sh` — build the JQL from derived label values only, one request per routed project, `nextPageToken` pagination to exhaustion, returning candidates ordered by key ascending
- [X] T061 [US1] Implement the twin `Get-JiraAdoptionCandidates` in `scripts/powershell/sink/jira/Adoption.psm1`
- [X] T062 [US1] Implement `adopt_read_candidate_identity` in `scripts/bash/sink/jira/adoption.sh` — one `identity_read` per candidate and per pinned key, 404 ⇒ `identity: null`, any other transport failure propagating its mapped code
- [X] T063 [US1] Implement the twin in `scripts/powershell/sink/jira/Adoption.psm1`
- [X] T064 [US1] Implement the happy-path branch of `adoption_classify` in `scripts/bash/engine/adoption.sh` — exactly one unclaimed candidate in the routed project ⇒ binding with `reason: "label-match"`, `status: "adopt"`, candidates consumed as opaque JSON
- [X] T065 [US1] Implement the twin classification branch in `scripts/powershell/engine/Adoption.psm1`
- [X] T066 [US1] Implement phase 1 of `cmd_adopt` in `scripts/bash/commands/adopt.sh` — enablement gate before any read, prefix validation, target derivation, discovery, claim reads, classification, and the prose plan printer of adopt-cli-contract §Output
- [X] T067 [US1] Implement the twin phase 1 in `scripts/powershell/commands/Adopt.psm1`, byte-identical plan output
- [X] T068 [US1] Implement the confirmation gate in `scripts/bash/commands/adopt.sh` — read one line from the terminal, `--yes` pre-confirms, decline exits 0 with zero writes, non-TTY without `--yes` collapses onto the dry-run path naming `--yes` (FR-006, research §6)
- [X] T069 [US1] Implement the twin confirmation gate in `scripts/powershell/commands/Adopt.psm1`
- [X] T070 [US1] Implement phase 2 of `cmd_adopt` in `scripts/bash/commands/adopt.sh` — build the ordered property-PUT action set for bindings with status `adopt` and hand it to the existing `apply_writes`; emit no other write kind
- [X] T071 [US1] Implement the twin phase 2 in `scripts/powershell/commands/Adopt.psm1`

**Checkpoint**: US1 is fully functional — a labelled backlog is adoptable end to
end with zero writes before confirmation, and the privacy guard is proven to
apply. This is the MVP.

---

## Phase 4: User Story 2 - Adoption is fail-closed on ambiguity (Priority: P1)

**Goal**: Every ambiguity refuses **that binding** with zero writes, naming the
spec folder, every issue key involved, and a copy-pasteable remediation.
Unambiguous bindings in the same run still apply; the run exits 4. Unreliable
reads abort the whole run before any write.

**Independent Test**: One fixture per refusal class plus one valid binding: the
valid binding applies, each refused binding leaves zero writes, each message
names the spec and the keys, and the run exits 4 (quickstart Scenario 2). The
`wrong-project` class is the one exception — it is only reachable through an
explicit binding and is therefore fixtured with US4.

### Tests for User Story 2 ⚠️ write first, observe failing

- [X] T072 [P] [US2] Candidate-count refusals in `tests/bash/engine/test_adoption_classify.bats` — `no-candidate` (message names the exact label searched for) and `several-candidates` (message names **every** candidate, never a truncated pair)
- [X] T073 [P] [US2] Twin candidate-count refusals in `tests/powershell/engine/Adoption.Classify.Tests.ps1`
- [X] T074 [P] [US2] Claim refusals in `tests/bash/engine/test_adoption_claims.bats` — `already-claimed` (marker names another spec) and `spec-owns-bridge-ticket` (marker names this spec with origin literal `bridge-created`, hyphen — research §4)
- [X] T075 [P] [US2] Twin claim refusals in `tests/powershell/engine/Adoption.Claims.Tests.ps1`
- [X] T076 [P] [US2] Hierarchy and scope refusals in `tests/bash/engine/test_adoption_hierarchy.bats` — `unbound-parent`, `wrong-parent`, `wrong-project`, `ambiguous-short-number`, each asserting the message names the folder(s) and every key or project key involved
- [X] T077 [P] [US2] Twin hierarchy and scope refusals in `tests/powershell/engine/Adoption.Hierarchy.Tests.ps1`
- [X] T078 [P] [US2] No-heuristic guarantee in `tests/bash/engine/test_adoption_no_heuristic.bats` — two candidates whose titles match the spec's title exactly still refuse; permuting candidate order, recency, and issue type changes nothing (FR-012)
- [X] T079 [P] [US2] Twin no-heuristic guarantee in `tests/powershell/engine/Adoption.NoHeuristic.Tests.ps1`
- [X] T080 [P] [US2] Exit-code precedence in `tests/bash/commands/test_adopt_exit_codes.bats` — a mixed run applies valid bindings and exits 4; when classes co-occur the highest applicable code wins (FR-013); a decline still exits 4 if any refusal occurred
- [X] T081 [P] [US2] Twin exit-code precedence in `tests/powershell/commands/Adopt.ExitCodes.Tests.ps1`
- [X] T082 [P] [US2] Fail-closed discovery in `tests/bash/sink/test_adoption_fail_closed.bats` — 401/403 ⇒ 3, and 404 / network error / exhausted 429 retries ⇒ 2, each aborting the **whole run before any write** with zero property PUTs
- [X] T083 [P] [US2] Twin fail-closed discovery in `tests/powershell/sink/Adoption.FailClosed.Tests.ps1`
- [X] T084 [P] [US2] Conformance scenario `tests/conformance/scenarios/us2-adopt-no-candidate.json`
- [X] T085 [P] [US2] Conformance scenario `tests/conformance/scenarios/us2-adopt-several-candidates.json` — served across **multiple mock pages** so the message proves pagination reached every candidate (NFR-6)
- [X] T086 [P] [US2] Conformance scenario `tests/conformance/scenarios/us2-adopt-already-claimed.json`
- [X] T087 [P] [US2] Conformance scenario `tests/conformance/scenarios/us2-adopt-spec-owns-bridge-ticket.json` — candidate carries this spec's marker with origin `bridge-created`
- [X] T088 [P] [US2] Conformance scenario `tests/conformance/scenarios/us2-adopt-unbound-parent.json` — a story-labelled candidate whose feature-level ticket is neither already bound nor bound in the run
- [X] T089 [P] [US2] Conformance scenario `tests/conformance/scenarios/us2-adopt-wrong-parent.json` — candidate's Jira parent is not the spec's bound feature-level ticket
- [X] T090 [P] [US2] Conformance scenario `tests/conformance/scenarios/us2-adopt-ambiguous-short-number.json` — two in-scope folders share the numbering component a short-form label names, using the `repo-with-adoption-multi` fixture
- [X] T091 [P] [US2] Conformance scenario `tests/conformance/scenarios/us2-adopt-mixed-refusals.json` — valid bindings apply alongside refusals, run exits 4 (US2 AS-4)
- [X] T092 [P] [US2] Fault-injection conformance scenarios `tests/conformance/scenarios/us2-adopt-fault-{401,404,network,429}.json` reusing the existing per-key fault map, asserting exit 3/2/2/2 and zero property PUTs in every call log
- [X] T093 [P] [US2] Conformance runner `tests/bash/conformance/test_us2_adopt_refusals.bats` driving every scenario above on both ports and diffing the captures

### Implementation for User Story 2

- [X] T094 [US2] Implement `no-candidate` and `several-candidates` classification plus their message and remediation builders in `scripts/bash/engine/adoption.sh` (remediation is the literal `--bind` command line that resolves the case)
- [X] T095 [US2] Implement the twin classification and builders in `scripts/powershell/engine/Adoption.psm1`
- [X] T096 [US2] Implement `already-claimed` and `spec-owns-bridge-ticket` classification in `scripts/bash/engine/adoption.sh`, pinning the origin literal `bridge-created`
- [X] T097 [US2] Implement the twin claim classification in `scripts/powershell/engine/Adoption.psm1`
- [X] T098 [US2] Implement `wrong-project`, `unbound-parent`, `wrong-parent`, and `ambiguous-short-number` classification in `scripts/bash/engine/adoption.sh`, evaluating story targets after their spec's feature target so in-run binding is visible
- [X] T099 [US2] Implement the twin hierarchy classification in `scripts/powershell/engine/Adoption.psm1`
- [X] T100 [US2] Implement refusal accumulation and highest-code-wins exit mapping in `scripts/bash/commands/adopt.sh` — per-binding refusals never stop unambiguous bindings, whole-run aborts leave zero writes overall
- [X] T101 [US2] Implement the twin accumulation and exit mapping in `scripts/powershell/commands/Adopt.psm1`
- [X] T102 [US2] Propagate fail-closed transport results out of discovery in `scripts/bash/sink/jira/adoption.sh` so an unreliable read aborts before the action set is built (FR-008)
- [X] T103 [US2] Implement the twin propagation in `scripts/powershell/sink/jira/Adoption.psm1`

**Checkpoint**: US1 and US2 both work independently — adoption binds what is
unambiguous and refuses everything else with zero writes.

---

## Phase 5: User Story 3 - Adopt without destroying human content (Priority: P1)

**Goal**: Every adopted ticket carries origin `human` permanently, so the first
reconcile after adoption *adds* the managed panel below existing prose with every
pre-existing byte intact, the reconcile after that writes nothing, and re-running
adoption on an adopted corpus writes nothing.

**Independent Test**: Capture each adopted ticket's description, run `adopt` then
`reconcile` twice; assert every pre-existing byte is unchanged outside the managed
panel, the panel was added below it, the second reconcile writes nothing, and a
re-run of `adopt` writes nothing (quickstart Scenario 3).

> Most of this story is **proof, not new code**: stamping origin `human` selects
> the managed-panel splice and managed-section-only churn diff that `adf.sh` and
> `plan_apply.sh` have implemented since 001 US7. Only FR-018's reporting is new.

### Tests for User Story 3 ⚠️ write first, observe failing

- [X] T104 [P] [US3] Byte-preservation tests in `tests/bash/sink/test_adoption_preserve.bats` — after an adoption stamp, `plan_managed_description_status` diffs the managed panel alone, the human prose never enters a write payload, **and a later reconcile leaves the marker's `origin: human` untouched so the human-origin behaviour is permanent** (FR-016)
- [X] T105 [P] [US3] Twin byte-preservation and origin-permanence cases added to `tests/powershell/sink/PlanApply.HumanContent.Tests.ps1`
- [X] T106 [P] [US3] Re-run idempotency in `tests/bash/commands/test_adopt_rerun.bats` — `adopt` over an already-adopted corpus produces zero writes of every kind and exits 0 (FR-019, SC-004)
- [X] T107 [P] [US3] Twin re-run idempotency in `tests/powershell/commands/Adopt.Rerun.Tests.ps1`
- [X] T108 [P] [US3] Extend `tests/bash/sink/test_lifecycle_safety.bats` with an adopted ticket: it is never hard-deleted, the most permitted is detaching the identity (FR-017)
- [X] T109 [P] [US3] Extend `tests/powershell/sink/LifecycleSafety.Tests.ps1` with the twin case
- [X] T110 [P] [US3] Adoption-reporting tests in `tests/bash/commands/test_reconcile.bats` — the first reconcile after adoption reports, per adopted ticket, that it was adopted and what was added, and adds nothing outside the managed panel (FR-018)
- [X] T111 [P] [US3] Twin adoption-reporting cases in `tests/powershell/commands/Reconcile.Tests.ps1`
- [X] T112 [P] [US3] Conformance scenario `tests/conformance/scenarios/us3-adopt-preserve.json` — adopt, reconcile, reconcile; asserts byte-identical human prose outside the managed panel, zero creations/deletions/transitions on adopted tickets, and a zero-write second reconcile (SC-002, SC-006)
- [X] T113 [P] [US3] Conformance scenario `tests/conformance/scenarios/us3-adopt-rerun-zero-write.json` — adoption re-run on an adopted corpus, zero writes, exit 0
- [X] T114 [P] [US3] Conformance runner `tests/bash/conformance/test_us3_adopt_preserve.bats` driving both scenarios on both ports

### Implementation for User Story 3

- [X] T115 [US3] Report adopted tickets and what was added to each in the first post-adoption reconcile summary in `scripts/bash/commands/reconcile.sh` (FR-018)
- [X] T116 [US3] Implement the twin reporting in `scripts/powershell/commands/Reconcile.psm1`
- [X] T117 [US3] Confirm and, where a gap is found, close it so the human-origin hard-deletion exclusion covers adopted tickets in `scripts/bash/sink/jira/plan_apply.sh` (FR-017)
- [X] T118 [US3] Apply the twin confirmation/fix in `scripts/powershell/sink/jira/PlanApply.psm1`

**Checkpoint**: The Product Owner's promise is proven end to end — all three P1
stories are complete and the feature is releasable once the live gate (T183)
passes.

---

## Phase 6: User Story 4 - Explicit binding override (Priority: P2)

**Goal**: `--bind <folder>[:us<N>]=<KEY>` pins a target to a specific issue key,
replacing label discovery for it and validated exactly like a discovered
candidate — same project check, same claim check, same hierarchy checks, same
refusals, same exit codes.

**Independent Test**: On a corpus where one spec has two candidates and another
has none, pin both; assert both bind with reason `explicit-binding`, and that a
pin to a claimed or wrong-project ticket is refused exactly as a discovered
candidate would be (quickstart Scenario 4).

### Tests for User Story 4 ⚠️ write first, observe failing

- [X] T119 [P] [US4] `--bind` parsing cases in `tests/bash/lib/test_cli.bats` — repeatable, structurally validated (non-empty on both sides of `=`), malformed value ⇒ usage error exit 1; **no issue-key shape check in the parser** (research §9)
- [X] T120 [P] [US4] Twin `--bind` parsing cases in `tests/powershell/lib/Cli.Tests.ps1`
- [X] T121 [P] [US4] Pin resolution tests in `tests/bash/engine/test_adoption_pins.bats` — a pin replaces discovery for its target, `reason: "explicit-binding"`, `overrode_key` set when a discovered candidate is overridden, and a pin naming a folder absent from disk stops the run as a usage error with zero writes (FR-021, FR-022)
- [X] T122 [P] [US4] Twin pin resolution tests in `tests/powershell/engine/Adoption.Pins.Tests.ps1`
- [X] T123 [P] [US4] Issue-key shape tests in `tests/bash/sink/test_adoption_key_shape.bats` — the key shape is validated in the sink, a malformed key is a usage error, and identity is read for pinned keys exactly as for discovered candidates
- [X] T124 [P] [US4] Twin issue-key shape tests in `tests/powershell/sink/Adoption.KeyShape.Tests.ps1`
- [X] T125 [P] [US4] Conformance scenario `tests/conformance/scenarios/us4-adopt-explicit-binding.json` — two pins bind, summary records `explicit-binding`, no label is added to the unlabelled ticket
- [X] T126 [P] [US4] Conformance scenario `tests/conformance/scenarios/us4-adopt-pin-refusals.json` — pins to a claimed ticket and to a ticket outside the routed project (the `wrong-project` class US2 defers here) refuse with the same messages and exit 4
- [X] T127 [P] [US4] Conformance scenario `tests/conformance/scenarios/us4-adopt-unknown-folder.json` — a pin naming a folder absent from disk ⇒ exit 1, zero writes
- [X] T128 [P] [US4] Conformance scenario `tests/conformance/scenarios/us4-adopt-pin-overrides.json` — the plan states both the pinned key and the discovered key it overrode (FR-022, US4 AS-5)
- [X] T129 [P] [US4] Conformance runner `tests/bash/conformance/test_us4_adopt_bind.bats` driving all four scenarios on both ports

### Implementation for User Story 4

- [X] T130 [US4] Implement repeatable `--bind` structural parsing in `scripts/bash/lib/cli.sh`
- [X] T131 [US4] Implement the twin parsing in `scripts/powershell/lib/Cli.psm1`
- [X] T132 [US4] Implement pin resolution in `scripts/bash/engine/adoption.sh` — unknown-folder usage error, pin replaces the target's discovery, `overrode_key` recorded, pins routed through the identical validation path as discovered candidates
- [X] T133 [US4] Implement the twin pin resolution in `scripts/powershell/engine/Adoption.psm1`
- [X] T134 [US4] Implement issue-key shape validation in `scripts/bash/sink/jira/adoption.sh` (the only layer permitted to carry a key-shaped literal)
- [X] T135 [US4] Implement the twin shape validation in `scripts/powershell/sink/jira/Adoption.psm1`
- [X] T136 [US4] Wire pins through `cmd_adopt` in `scripts/bash/commands/adopt.sh` — pinned identity reads, plan lines showing both keys on an override
- [X] T137 [US4] Wire pins through the twin in `scripts/powershell/commands/Adopt.psm1`

**Checkpoint**: Every US2 refusal now has a working, copy-pasteable remedy.

---

## Phase 7: User Story 5 - Adoption dry-run and audit trail (Priority: P2)

**Goal**: `adopt --dry-run` reports exactly the action set the real run performs
with zero writes, and every run emits a structured summary listing applied
bindings with their reason and refused bindings with their remediation — prose by
default, `--json` on opt-in, byte-identical across ports.

**Independent Test**: Run `--dry-run --json` and `--yes --json` against the same
state; assert identical action sets, zero dry-run writes, and both summaries
validating against the run-summary schema plus the adoption-plan deltas
(quickstart Scenario 5).

### Tests for User Story 5 ⚠️ write first, observe failing

- [X] T138 [P] [US5] Dry-run equivalence in `tests/bash/commands/test_adopt_dry_run.bats` — the dry-run's reported action set equals the real run's for the same state, and the dry-run call log holds zero writes (FR-023, SC-003)
- [X] T139 [P] [US5] Twin dry-run equivalence in `tests/powershell/commands/Adopt.DryRun.Tests.ps1`
- [X] T140 [P] [US5] Summary tests in `tests/bash/commands/test_adopt_summary.bats` — `--json` conforms to `run-summary.schema.json` plus `contracts/adoption-plan.schema.json` (`command: "adopt"`, an `adoption` block), default output is prose, and counts of adopted/skipped/refused are present (FR-024, NFR-4)
- [X] T141 [P] [US5] Twin summary tests in `tests/powershell/commands/Adopt.Summary.Tests.ps1`
- [X] T142 [P] [US5] Extend `tests/bash/lib/test_token_leak.bats` — no adopt output at any verbosity, including `--verbose`, contains the token or the site host (FR-025, NFR-3)
- [X] T143 [P] [US5] Extend `tests/powershell/lib/TokenLeak.Tests.ps1` with the twin adopt cases
- [X] T144 [P] [US5] Conformance scenario `tests/conformance/scenarios/us5-adopt-dry-run.json` — dry-run action set captured for diffing against the real run
- [X] T145 [P] [US5] Conformance scenario `tests/conformance/scenarios/us5-adopt-json-summary.json` — schema-validated summary with applied reasons and refusal remediations
- [X] T146 [P] [US5] Conformance runner `tests/bash/conformance/test_us5_adopt_audit.bats` driving both scenarios on both ports and asserting byte-identical summaries (SC-008)

### Implementation for User Story 5

- [X] T147 [US5] Implement the `--dry-run` path in `scripts/bash/commands/adopt.sh` — print the plan and the action set, never prompt, perform zero writes
- [X] T148 [US5] Implement the twin dry-run path in `scripts/powershell/commands/Adopt.psm1`
- [X] T149 [US5] Emit the `adoption` summary block through the existing canonical serializer in `scripts/bash/commands/adopt.sh`, conforming to `contracts/adoption-plan.schema.json`
- [X] T150 [US5] Implement the twin summary emission in `scripts/powershell/commands/Adopt.psm1`, byte-identical for identical inputs
- [X] T151 [US5] Implement the prose summary with adopted/skipped/refused counts and per-refusal remediation lines in `scripts/bash/commands/adopt.sh`
- [X] T152 [US5] Implement the twin prose summary in `scripts/powershell/commands/Adopt.psm1`

**Checkpoint**: Adoption is auditable and scriptable; the dry-run twin is exact.

---

## Phase 8: User Story 6 - Partial and resumable adoption (Priority: P3)

**Goal**: `--spec <folder>` restricts a run to a subset of spec folders, with the
rest reported out of scope and zero reads against their tickets; an interrupted
adoption completes on re-run with exactly one stamp per ticket.

**Independent Test**: Adopt a two-spec subset of a five-spec repository and assert
the other three are untouched and reported out of scope; interrupt a run after the
first stamp, re-run, and assert the stamped ticket is skipped and every ticket
carries exactly one stamp (quickstart Scenario 6).

### Tests for User Story 6 ⚠️ write first, observe failing

- [X] T153 [P] [US6] `--spec` parsing cases in `tests/bash/lib/test_cli.bats` — repeatable, non-empty, structurally validated
- [X] T154 [P] [US6] Twin `--spec` parsing cases in `tests/powershell/lib/Cli.Tests.ps1`
- [X] T155 [P] [US6] Scope tests in `tests/bash/commands/test_adopt_scope.bats` — only scoped folders are discovered, the rest appear in `out_of_scope` sorted ascending with **zero reads or writes against their tickets**, and a scope naming a folder absent from disk stops the run as a usage error exit 1 with zero writes
- [X] T156 [P] [US6] Twin scope tests in `tests/powershell/commands/Adopt.Scope.Tests.ps1`
- [X] T157 [P] [US6] Scope-before-derivation tests in `tests/bash/engine/test_adoption_targets.bats` — the short-number uniqueness test is evaluated over the folders **in scope**, not the whole repository (data-model §6)
- [X] T158 [P] [US6] Twin scope-before-derivation tests in `tests/powershell/engine/Adoption.Targets.Tests.ps1`
- [X] T159 [P] [US6] Resumability tests in `tests/bash/commands/test_adopt_resume.bats` — a candidate carrying **this** spec's marker with origin `human` gets status `already-adopted`, is skipped and counted as skipped (not an error), and an interrupted-plus-completing pair of runs totals exactly one stamp per ticket (FR-027, SC-007)
- [X] T160 [P] [US6] Twin resumability tests in `tests/powershell/commands/Adopt.Resume.Tests.ps1`
- [X] T161 [P] [US6] Conformance scenario `tests/conformance/scenarios/us6-adopt-scope.json` — two of five folders scoped, three reported out of scope with zero reads against their tickets
- [X] T162 [P] [US6] Conformance scenario `tests/conformance/scenarios/us6-adopt-resume.json` — one ticket pre-stamped in the mock corpus, re-run skips it and stamps only the rest
- [X] T163 [P] [US6] Conformance scenario `tests/conformance/scenarios/us6-adopt-unknown-scope.json` — `--spec` naming a folder absent from disk ⇒ exit 1, zero writes
- [X] T164 [P] [US6] Conformance runner `tests/bash/conformance/test_us6_adopt_scope.bats` driving all three scenarios on both ports

### Implementation for User Story 6

- [X] T165 [US6] Implement repeatable `--spec` structural parsing in `scripts/bash/lib/cli.sh`
- [X] T166 [US6] Implement the twin parsing in `scripts/powershell/lib/Cli.psm1`
- [X] T167 [US6] Apply scope **before** label derivation and emit the sorted `out_of_scope` list in `scripts/bash/engine/adoption.sh`, raising the unknown-folder usage error
- [X] T168 [US6] Implement the twin scope application in `scripts/powershell/engine/Adoption.psm1`
- [X] T169 [US6] Implement the `already-adopted` status branch in `scripts/bash/engine/adoption.sh` — this spec's marker with origin `human` ⇒ skipped, no action emitted
- [X] T170 [US6] Implement the twin `already-adopted` branch in `scripts/powershell/engine/Adoption.psm1`
- [X] T171 [US6] Report out-of-scope folders and skipped counts in the plan and summary in `scripts/bash/commands/adopt.sh`
- [X] T172 [US6] Implement the twin reporting in `scripts/powershell/commands/Adopt.psm1`

**Checkpoint**: All six user stories are independently functional.

---

## Phase 9: Polish & Cross-Cutting Concerns

> The live suite (T183) is opt-in — it runs on push to the default branch, on a
> schedule, and on a maintainer-applied label. It is never a blocking gate on
> pull requests from forks (Principle XII), but Principle II makes it a
> **release** gate: mocks alone do not prove idempotency.

- [X] T173 [P] Add `# kcov-excl-start` / `# kcov-excl-stop` markers around every multi-line `jq` program literal in `scripts/bash/engine/adoption.sh` and `scripts/bash/sink/jira/adoption.sh`, matching the `engine/interchange.sh` convention (research §12)
- [X] T174 [P] Run `shellcheck` clean over `scripts/bash/engine/adoption.sh`, `scripts/bash/sink/jira/adoption.sh`, and `scripts/bash/commands/adopt.sh`
- [X] T175 [P] Run `PSScriptAnalyzer` clean over `scripts/powershell/engine/Adoption.psm1`, `scripts/powershell/sink/jira/Adoption.psm1`, and `scripts/powershell/commands/Adopt.psm1`
- [X] T176 Verify the boundary gate: `grep -rnE '[A-Z]{2,}-[0-9]+|atlassian|createmeta|customfield_[0-9]+' scripts/bash/engine scripts/powershell/engine` returns **no match**, comments included (Principle VIII, research §8)
- [ ] T177 Verify statement coverage ≥80% on both ports for the new modules (kcov on Linux via `tests/coverage/bash-coverage.sh`, Pester CodeCoverage everywhere), with the ambiguity-refusal, zero-write, human-preservation, confirmation-gate, and privacy-guard paths close to 100% (Principle XIII)
  - **Status**: PowerShell half DONE — Pester CodeCoverage over the three new
    modules reports **94.29%** (1073/1138 commands) against the 80% gate, with the
    refusal, zero-write, preservation, confirmation and privacy paths exercised.
    Bash half NOT RUN HERE: `tests/coverage/bash-coverage.sh` refuses on macOS by
    design (kcov cannot drive a non-Apple bash, and Apple's /bin/bash is 3.2, which
    this port disqualifies), so it must be read from the CI "Bash coverage" job on
    ubuntu-latest.

- [X] T178 [P] Document the `adopt` command, the `adoption:` config keys, and the three label forms in `README.md`
- [X] T179 [P] Add the feature entry to `CHANGELOG.md`
- [X] T180 Bump the single-sourced `extension.version` in `extension.yml` by a MINOR increment (new command, new config keys — Principle XII)
- [X] T181 Verify FR-031 traceability: every new config key (`adoption.enabled`, `adoption.label_prefix`) and every new flag (`--bind`, `--spec`, `--yes`) is exercised by at least one named automated test; no unused key, flag, or schema field ships; and confirm no runtime dependency beyond each port's declared prerequisites was introduced (NFR-2)
- [X] T182 Run the full cross-port parity diff for every adoption scenario per quickstart §Cross-port parity (`tests/conformance/run-scenario.sh … bash` vs `… powershell`, then `diff -r`) and confirm byte-identical plans, summaries, call logs, and exit codes (NFR-1, SC-008)
- [X] T183 Extend `tests/live/test_live_zero_churn.bats` with an adoption case — against a real instance: label a throwaway ticket, run `adopt --yes` twice, and assert the second run performs zero writes of every kind (create, update, transition, comment, link, label, identity stamp). Principle II requires live verification and states that mocks are NOT sufficient; this is the automated counterpart to the manual dogfood record (FR-019, SC-004)
- [ ] T184 Execute the full `quickstart.md` validation (Scenarios 1–6) on the three-OS matrix and record the results
  - **Status**: NOT RUN — needs the three-OS matrix. Every quickstart scenario is
    encoded as an automated conformance scenario and passes on macOS on BOTH ports
    (Scenarios 1–6 map to us1-adopt-*, us2-adopt-*, us3-adopt-*, us4-adopt-*,
    us5-adopt-*, us6-adopt-*); Linux and Windows must be read from the CI matrix.

- [ ] T185 Perform the dogfood run against a real Jira instance on a throwaway project per quickstart §Dogfood, recording that hand-written descriptions survived byte-for-byte and the second reconcile wrote nothing (Principle XII — a release without this record is invalid)
  - **Status**: NOT RUN — needs real credentials and a throwaway Jira project, which
    this environment has none of. The automated counterpart (T183) is written and
    skips cleanly without them; run it with SPEC_KIT_JIRA_LIVE=1 and
    SPEC_KIT_JIRA_ADOPT_TICKET set. Principle XII makes this record mandatory
    BEFORE release.


---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately
- **Foundational (Phase 2)**: depends on Setup — **BLOCKS every user story**
- **US1 (Phase 3)**: depends on Foundational. No dependency on other stories
- **US2 (Phase 4)**: depends on Foundational; shares `engine/adoption.sh` and `commands/adopt.sh` with US1, so it lands cleanest after US1's classification skeleton exists
- **US3 (Phase 5)**: depends on US1 (needs a stamp to exist before preservation can be proven)
- **US4 (Phase 6)**: depends on US1 and US2 (a pin is validated through the same classification path); it also supplies the `wrong-project` conformance scenario US2 defers
- **US5 (Phase 7)**: depends on US1 (the action set is the prediction)
- **US6 (Phase 8)**: depends on US1; the `already-adopted` skip complements US3's zero-write re-run
- **Polish (Phase 9)**: depends on every story that ships. T183 additionally requires real credentials and is a release gate, not a PR gate

### Within Each User Story

- Every test task is written and observed **failing** before its implementation task (Principle XIII)
- Engine (pure) before sink (Jira-aware) before command (orchestration)
- Bash and PowerShell twins for one concern are written back to back so parity never drifts by more than one task
- Conformance scenarios are authored with the story's tests but pass only once the story's implementation lands

### Parallel Opportunities

- **Setup**: T001–T002 parallel
- **Foundational**: the five test pairs (T003/T004, T007/T008, T011/T012, T013/T014, T023/T024) are parallel; the six module scaffolds T017–T022 are all parallel (distinct new files)
- **US1**: all 24 test tasks T029–T052 are parallel (distinct files); implementation pairs are sequential per file
- **US2**: all 22 test tasks T072–T093 are parallel — the ten conformance scenarios T084–T092 especially
- **US3–US6**: every test task in each story is parallel within its story
- **Polish**: T173–T175 and T178–T179 are parallel
- **Team split**: after Phase 2, one developer can take US1+US3 (the write path and its preservation proof) while another takes US2 (classification) — they meet in `engine/adoption.sh`, so coordinate on that file

---

## Parallel Example: User Story 1

```bash
# All US1 engine and sink tests, both ports, at once:
Task: "Label grammar tests in tests/bash/engine/test_adoption_labels.bats"
Task: "Twin label grammar tests in tests/powershell/engine/Adoption.Labels.Tests.ps1"
Task: "Target derivation tests in tests/bash/engine/test_adoption_targets.bats"
Task: "Twin target derivation tests in tests/powershell/engine/Adoption.Targets.Tests.ps1"
Task: "Discovery tests in tests/bash/sink/test_adoption_search.bats"
Task: "Twin discovery tests in tests/powershell/sink/Adoption.Search.Tests.ps1"
Task: "Privacy-guard tests in tests/bash/sink/test_adoption_privacy.bats"
Task: "Twin privacy-guard tests in tests/powershell/sink/Adoption.PrivacyGuard.Tests.ps1"

# All seven US1 conformance scenarios at once:
Task: "Conformance scenario tests/conformance/scenarios/us1-adopt-hierarchy.json"
Task: "Conformance scenario tests/conformance/scenarios/us1-adopt-disabled.json"
Task: "Conformance scenario tests/conformance/scenarios/us1-adopt-decline.json"
Task: "Conformance scenario tests/conformance/scenarios/us1-adopt-unnamed-label.json"
Task: "Conformance scenario tests/conformance/scenarios/us1-adopt-privacy-block.json"
Task: "Conformance scenario tests/conformance/scenarios/us1-adopt-team-managed.json"
Task: "Conformance scenario tests/conformance/scenarios/us1-adopt-invalid-prefix.json"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (**CRITICAL** — blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: run quickstart Scenario 1 on both ports — plan before
   any write, exactly one property PUT per adopted ticket, zero other writes
5. This is a demonstrable adoption of a labelled backlog

### Incremental Delivery

1. Setup + Foundational → the command exists and the mock can serve candidates
2. + US1 → a labelled backlog is adoptable (**MVP**)
3. + US2 → ambiguity refuses instead of guessing — **the minimum safe release**
4. + US3 → the byte-preservation promise is proven end to end
5. + T183 (live idempotency) → **releasable**
6. + US4 → every refusal has a working remedy
7. + US5 → auditable and scriptable
8. + US6 → partial and resumable

> **Release gate**: US1, US2, and US3 are all P1 and must ship together, and
> T183 must be green. Adopting without US2 would let the bridge guess a binding
> onto a human's ticket; shipping without US3's proof would break the promise
> that makes adoption acceptable to a Product Owner; shipping without T183 would
> claim idempotency on mock evidence alone, which Principle II forbids.

### Parallel Team Strategy

1. The whole team completes Setup + Foundational
2. Then: Developer A takes US1 → US3; Developer B takes US2; Developer C takes
   the mock-server and conformance corpus work feeding all stories
3. US4, US5, US6 fan out once US1 and US2 are green

---

## Notes

- `[P]` = different files, no dependency on an incomplete task
- Every engine change must survive the boundary grep **including comments** — see
  the constraint block at the top of this file
- The origin literal on the wire is `human` for adopted tickets and
  `bridge-created` (hyphen) for bridge-created ones — never `bridge_created`
- Commit after each task or logical twin pair; stop at any checkpoint to validate
  a story independently
- Avoid: any fallback selection strategy in any code path (FR-012 forbids it
  existing at all, not merely being unreachable)

---

## Phase 10: Convergence

> Appended by `/speckit-converge`. Both suites are green on macOS (Bash 851
> tests, PowerShell 632/632); the boundary grep, shellcheck, and
> PSScriptAnalyzer are at or above the repository baseline. The two findings
> below are reporting gaps against spec prose that the implementation otherwise
> satisfies. T177, T184, and T185 remain open above and are NOT duplicated here —
> they need Linux CI, the three-OS matrix, and live credentials respectively.

- [ ] T186 [P] Add failing cases to `tests/bash/engine/test_adoption_classify.bats` asserting that a **story-level** `no-candidate` refusal names the ordinary reconcile as a supported outcome (the child is created as a bridge-created ticket under the adopted parent) alongside the existing label/`--bind` remediation, while a **feature-level** `no-candidate` keeps its current remediation unchanged per FR-014 (partial)
- [ ] T187 [P] Add the twin failing cases to `tests/powershell/engine/Adoption.Classify.Tests.ps1` per FR-014 (partial)
- [ ] T188 Extend the `no-candidate` remediation builder in `scripts/bash/engine/adoption.sh` so a story-level target states the ordinary-reconcile outcome, leaving the exit code at 4 per FR-013 and carrying no issue-key-shaped literal (boundary grep), per FR-014 (partial)
- [ ] T189 Implement the twin remediation in `scripts/powershell/engine/Adoption.psm1`, byte-identical for identical inputs, per FR-014 (partial)
- [ ] T190 [P] Add failing cases to `tests/bash/commands/test_adopt.bats` for a run with zero targets in scope — exit 0, zero reads, zero writes, and a plan/summary that states nothing was found — per spec Edge Cases (partial)
- [ ] T191 [P] Add the twin failing cases to `tests/powershell/commands/Adopt.Tests.ps1` per spec Edge Cases (partial)
- [ ] T192 Print a "nothing was found" statement from `_adopt_print_plan` in `scripts/bash/commands/adopt.sh` when the plan carries no binding, no refusal, and no out-of-scope folder, per spec Edge Cases and Constitution XVI (partial)
- [ ] T193 Implement the twin statement in `scripts/powershell/commands/Adopt.psm1`, byte-identical across ports per NFR-1/SC-008, per spec Edge Cases and Constitution XVI (partial)
