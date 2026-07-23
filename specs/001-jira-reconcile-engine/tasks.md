---
description: "Task list for Jira Reconcile Engine (Twin Bash / PowerShell Ports)"
---

# Tasks: Jira Reconcile Engine (Twin Bash / PowerShell Ports)

**Input**: Design documents from `/specs/001-jira-reconcile-engine/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (sink-interface.md, cli-contract.md, config.schema.json, config.local.schema.json, neutral-interchange.schema.json, run-summary.schema.json, jira-cloud-endpoints.md), quickstart.md

**Tests**: TESTS ARE REQUIRED for this feature. Constitution XIII mandates TDD with ≥80% statement coverage (kcov for Bash, Pester CodeCoverage for PowerShell) as a blocking merge gate, and NFR-6 mandates a shared mocked Jira double plus a shared conformance corpus. Every implementation task is preceded by its test task; every test MUST be written and MUST FAIL before its implementation.

**Twin-port convention**: Every module is mirrored **module-for-module** — one `*.psm1` per `*.sh` (NFR-1, NFR-2). Bash and PowerShell files are distinct paths, so a single task that touches both ports is still `[P]`-eligible against tasks touching other modules. The conformance corpus (`tests/conformance/`) asserts byte-identical observable behaviour across ports; a divergence is a failing test, not a documented quirk.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (US1–US12)
- Every task lists exact file paths

## Path Conventions

- **Bash port**: `.specify/extensions/jira/scripts/bash/` → `spec-kit-jira.sh`, `lib/`, `engine/`, `sink/jira/`, `commands/`, `hooks/`
- **PowerShell port**: `.specify/extensions/jira/scripts/powershell/` → `spec-kit-jira.ps1`, `lib/`, `engine/`, `sink/jira/`, `commands/`, `hooks/`
- **Extension metadata**: `.specify/extensions/jira/` → `extension.yml` (holds the version), `CHANGELOG.md`, `templates/`
- **Agent command file**: `commands/speckit.jira.config.md` (outside `.specify/`)
- **Team config (consuming repo)**: `.specify/jira/config.yml`, `.specify/jira/config.local.yml`, `.specify/jira/.env`
- **Tests**: `tests/bash/`, `tests/powershell/`, `tests/conformance/{run-scenario.sh,scenarios/,fixtures/,mock-jira/}`, `tests/live/`
- **CI**: `.github/workflows/`

**Boundary rule (Constitution VIII, grep-enforced)**: `engine/` scripts carry ZERO Jira identifiers and NEVER source/import `sink/`. All Jira knowledge lives in `sink/jira/`. `.specify/scripts/` and `.specify/templates/` (Spec Kit core) are NEVER written (FR-055, SC-009).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the twin-port skeleton, version single-source, test tree, lint config, and CI shell.

- [X] T001 Create the twin-port directory skeleton: `.specify/extensions/jira/scripts/bash/{lib,engine,sink/jira,commands,hooks}/` and `.specify/extensions/jira/scripts/powershell/{lib,engine,sink/jira,commands,hooks}/` and `.specify/extensions/jira/templates/`
- [X] T002 [P] Create the extension metadata `.specify/extensions/jira/extension.yml` (id, catalog name, and the `version` field — the SINGLE source of truth for the version, the only place the version literal appears in the tree, FR-021/022) and `.specify/extensions/jira/CHANGELOG.md` (SemVer, initial entry)
- [X] T003 [P] Create the test tree: `tests/bash/{lib,engine,sink,commands}/`, `tests/powershell/{lib,engine,sink,commands}/`, `tests/conformance/{scenarios,fixtures,mock-jira}/`, `tests/live/`
- [X] T004 [P] Add Bash lint/format config at repo root: `.shellcheckrc` and shfmt settings in `.editorconfig`
- [X] T005 [P] Add PowerShell lint config `PSScriptAnalyzerSettings.psd1` at repo root
- [X] T006 [P] Update `.gitignore`: remove the stale `.specify/jira/VERSION.local` line (FR-022 forbids any hand-maintained version marker). Note: `.specify/jira/config.local.yml` and `.specify/jira/.env` are already gitignored — verify they remain present (do not re-add duplicates)
- [X] T007 [P] Create the self-documenting `.specify/extensions/jira/templates/config.yml.template` (business-language keys + comments, Constitution XVI) and `.specify/extensions/jira/templates/readme-block.template`

**Checkpoint**: Skeleton, version source, and test tree exist — foundational work can begin.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Port infrastructure (`lib/`), the engine↔sink interface plumbing, credential-safe transport, the mocked Jira double, the conformance harness, and the CI enforcement gates. **No user story can begin until this phase is complete.**

**⚠️ CRITICAL**: Every user story depends on the mocked double, the conformance harness, `lib/`, and the sink transport.

### Test infrastructure

- [X] T008 [P] Build the mocked Jira double (company-managed + team-managed discovery responses, and 401 / 404 / 429-exhausted / network fault injection) in `tests/conformance/mock-jira/`
- [X] T009 Implement the conformance harness `tests/conformance/run-scenario.sh` (signature `run-scenario <scenario.json> <bash|powershell> [outdir]`) that runs a port against a scenario and captures stdout, exit code, written files, and Jira API call sequence for byte-identical comparison (NFR-1)

### Port infrastructure — `lib/` (no domain knowledge)

- [X] T010 [P] Prereq-check tests (bash ≥ 4 with macOS 3.2 named explicitly, curl/jq/git present; pwsh 7+) asserting exit code 5 in `tests/bash/lib/test_prereq.bats` and `tests/powershell/lib/Prereq.Tests.ps1`
- [X] T011 Implement prerequisite checks (exit 5 before any Jira interaction, NFR-4) in `.specify/extensions/jira/scripts/bash/lib/prereq.sh` and `.specify/extensions/jira/scripts/powershell/lib/Prereq.psm1`
- [X] T012 [P] Canonical-serializer parity tests (stable key ordering, UTF-8, explicit line-ending control, `jq` ↔ `ConvertTo-Json` byte-parity incl. `@uri` `%20`→`+` rule, research §11) in `tests/bash/lib/test_serialize.bats`, `tests/powershell/lib/Serialize.Tests.ps1`, and a conformance scenario
- [X] T013 Implement the canonical serializer (shared by config/output/interchange) in `.specify/extensions/jira/scripts/bash/lib/output.sh` and `.specify/extensions/jira/scripts/powershell/lib/Output.psm1`
- [X] T014 [P] CLI arg-parsing and exit-code-table tests (`--dry-run`/`--json`/`--on-drift`/`--verbose`/`--help`; codes 0/1/2/3/4/5/9 per contracts/cli-contract.md) in `tests/bash/lib/test_cli.bats` and `tests/powershell/lib/Cli.Tests.ps1`
- [X] T015 Implement CLI arg parsing + the shared exit-code table in `.specify/extensions/jira/scripts/bash/lib/cli.sh` and `.specify/extensions/jira/scripts/powershell/lib/Cli.psm1`
- [X] T016 [P] Run-summary rendering tests (prose default + `--json` validated against `contracts/run-summary.schema.json`, WARNING channel) in `tests/bash/lib/test_output.bats` and `tests/powershell/lib/Output.Tests.ps1`
- [X] T017 Implement run-summary rendering (prose + `--json`, WARNING channel) in `.specify/extensions/jira/scripts/bash/lib/output.sh` and `.specify/extensions/jira/scripts/powershell/lib/Output.psm1`
- [X] T018 [P] Credential-resolution tests — **eliminatory NFR-3**: env → OS secret manager → gitignored `.env`; assert the resolved token NEVER appears in argv, logs, errors, or under `set -x` / `-Verbose` (SC-007) in `tests/bash/lib/test_credentials.bats` and `tests/powershell/lib/Credentials.Tests.ps1`
- [X] T019 Implement credential resolution in `.specify/extensions/jira/scripts/bash/lib/credentials.sh` (Authorization header via `curl --config` on stdin, never `-H` argv) and `.specify/extensions/jira/scripts/powershell/lib/Credentials.psm1` (token stays in-process)

### Engine↔sink interface plumbing

- [X] T020 [P] Neutral-interchange schema-validation tests (valid + invalid docs against `contracts/neutral-interchange.schema.json`; validation failure ⇒ zero writes + error) in `tests/bash/engine/test_interchange.bats` and `tests/powershell/engine/Interchange.Tests.ps1`
- [X] T021 Implement the neutral-document schema validator (validate before any write, Constitution VIII) in `.specify/extensions/jira/scripts/bash/engine/interchange.sh` and `.specify/extensions/jira/scripts/powershell/engine/Interchange.psm1`
- [X] T022 [P] Sink REST-transport tests (retry/backoff honouring `Retry-After` on 429, exit-code mapping 2/3, credential-safe header) against the mocked double in `tests/bash/sink/test_client.bats` and `tests/powershell/sink/Client.Tests.ps1`
- [X] T023 Implement the REST v3 transport (retry/backoff, exit-code mapping, credential-safe header from T019) in `.specify/extensions/jira/scripts/bash/sink/jira/client.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/Client.psm1`
- [X] T024 Implement the entry-point dispatcher (routes `config`/`reconcile`/`mention`, runs prereq checks first) in `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` and `.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1`

### CI enforcement gates

- [X] T025 [P] CI: three-OS matrix (ubuntu / macos / windows) running bats + Pester unit suites and the conformance corpus in `.github/workflows/ci.yml`
- [X] T026 [P] CI: engine/sink boundary greps — #1 no `engine/` script sources/imports `sink/`; #2 no `engine/` script contains any Atlassian identifier (issue-key regex, `atlassian.net`, `createmeta`, ADF node names, field ids); grep builds the vendor token from split literals — in `.github/workflows/boundary.yml`
- [X] T027 [P] CI: coverage gate (kcov Bash ≥ 80% PRIMARY with traceability FALLBACK, Pester CodeCoverage ≥ 80%), module-parity check (same leaf set modulo `.sh`↔`.psm1`), and version-string grep (SC-006: no version string outside `.specify/extensions/jira/`; and within that folder the version literal appears only in the `version` field of `extension.yml`, never duplicated elsewhere, per FR-021/022) in `.github/workflows/gates.yml`

**Checkpoint**: Infrastructure ready — user story implementation can begin.

---

## Phase 3: User Story 4 - Committable team config, secrets separated, version single-sourced (Priority: P1)

**Goal**: A credential-free `config.yml` at the repo root, gitignored local overrides, credential-shaped values rejected by schema, and exactly one version source — the storage layer every other story reads and writes.

**Independent Test**: Reinstall the extension and assert `config.yml` + hooks survive; grep the consuming repo for any version string outside `.specify/extensions/jira/` and assert none; attempt a credential-shaped value in either YAML layer and assert schema rejection.

**Why first among P1**: US1's config command, US2's discovery persistence, US5's README markers, and every run summary read the version source and the config storage defined here.

### Tests for User Story 4 ⚠️

- [X] T028 [P] [US4] Config-schema tests: credential-shaped values rejected in both layers (FR-023, exit 4); `config.yml`/`config.local.yml` split; no version marker outside the extension (SC-006) in `tests/bash/lib/test_config.bats` and `tests/powershell/lib/Config.Tests.ps1`
- [X] T029 [P] [US4] Reinstall/upgrade preservation conformance scenario (config.yml + config.local.yml survive intact, FR-020) in `tests/conformance/scenarios/us4-reinstall-preserves-config.json`

### Implementation for User Story 4

- [X] T030 [US4] Implement config load/merge (`config.yml` + `config.local.yml`) and schema validation against `contracts/config.schema.json` / `contracts/config.local.schema.json` in `.specify/extensions/jira/scripts/bash/lib/config.sh` and `.specify/extensions/jira/scripts/powershell/lib/Config.psm1`
- [X] T031 [US4] Implement credential-shape rejection (ATATT prefix, real `*.atlassian.net`, email/token shapes) in both YAML layers with exit code 4 in `.specify/extensions/jira/scripts/bash/lib/config.sh` and `.specify/extensions/jira/scripts/powershell/lib/Config.psm1`
- [X] T032 [US4] Implement the single-source version reader (reads the `version` field of `.specify/extensions/jira/extension.yml`; asserts absence of `.specify/jira/VERSION` and any other hand-maintained version marker) consumed by config command, README markers, run summary, and upgrade check in `.specify/extensions/jira/scripts/bash/lib/config.sh` and `.specify/extensions/jira/scripts/powershell/lib/Config.psm1`

**Checkpoint**: Config storage, credential rejection, and version single-sourcing work independently.

---

## Phase 4: User Story 2 - Workflow-adaptable mapping, company-managed AND team-managed (Priority: P1)

**Goal**: Style-detected-first metadata discovery down the correct per-style path, an operator-confirmed estimation-field heuristic (no literal field name), four-category status classification, and config-time refusal of impossible mappings.

**Independent Test**: Run discovery against a company-managed fixture and a team-managed fixture; assert each follows its own path and produces a valid mapping. Configure a level above Epic on a team-managed project and assert config-time refusal (exit 4) naming the limitation.

### Tests for User Story 2 ⚠️

- [X] T033 [P] [US2] Style-detection + company-managed discovery (scheme-based endpoints, research §1/§2) against the mocked double in `tests/bash/sink/test_discovery_company.bats`, `tests/powershell/sink/Discovery.Company.Tests.ps1`, and `tests/conformance/scenarios/us2-company-managed-discovery.json`
- [X] T034 [P] [US2] Team-managed discovery (project-scoped, research §3): estimation-field heuristic ranking + operator confirmation (never the global Story Points field, no literal name), hierarchy limited to Epic/Sub-task in `tests/bash/sink/test_discovery_team.bats`, `tests/powershell/sink/Discovery.Team.Tests.ps1`, and `tests/conformance/scenarios/us2-team-managed-discovery.json`
- [X] T035 [P] [US2] Status classification into `mapped`/`post-scope`/`halted`/`unknown` (statusCategory-seeded + operator, research §4) and many-to-one phase→status mapping; assert no built-in "ideal" status/phase default table is shipped and the operator's configured workflow is authoritative (FR-012) in `tests/bash/sink/test_status_classification.bats` and `tests/powershell/sink/StatusClassification.Tests.ps1`
- [X] T036 [P] [US2] Config-time refusal of a team-managed level-above-Epic (FR-007, exit 4 naming limitation + style) in `tests/bash/commands/test_config_refusal.bats` and `tests/powershell/commands/Config.Refusal.Tests.ps1`

### Implementation for User Story 2

- [X] T037 [US2] Implement `discover_binding` — style detected first, per-style discovery of issue types / statuses+categories / priorities / fields / flagged field (research §1/§2/§3/§15) in `.specify/extensions/jira/scripts/bash/sink/jira/discovery.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/Discovery.psm1`
- [X] T038 [US2] Implement the estimation-field discovery heuristic (rank candidates by documented signals, propose but never assume the conventional name) in `.specify/extensions/jira/scripts/bash/sink/jira/discovery.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/Discovery.psm1`
- [X] T039 [US2] Implement status classification + many-to-one phase→status persistence into config in `.specify/extensions/jira/scripts/bash/lib/config.sh` and `.specify/extensions/jira/scripts/powershell/lib/Config.psm1`
- [X] T040 [US2] Implement mapping validation (refuse team-managed level-above-Epic at config time, exit 4) and persist `epic_strategy` / `task_strategy` / `link_type` by logical name in `.specify/extensions/jira/scripts/bash/commands/config.sh` and `.specify/extensions/jira/scripts/powershell/commands/Config.psm1`

**Checkpoint**: Discovery + mapping work for both project styles, verified against both fixtures.

---

## Phase 5: User Story 1 - Deterministic, model-independent configuration (Priority: P1) 🎯 MVP

**Goal**: `/speckit.jira.config` runs a fully deterministic, byte-identical-on-re-run ceremony — every step is an API read, a config read, or a closed enumerated question — orchestrating discovery, hook registration, and README-block management, reporting the three effects separately.

**Independent Test**: Run the config command twice against an unchanged project on both ports and diff the produced `config.yml`; byte-identical proves determinism. Inspect the command file to confirm every step is API-read / config-read / closed enumerated question. Assert one run performs all three effects and reports each separately.

**Depends on**: US4 (config storage), US2 (discovery). The hooks and README effects wire in the modules from US9 (T083) and US5 (T065) when those land.

### Tests for User Story 1 ⚠️

- [X] T041 [P] [US1] Byte-identical re-run (FR-003, SC-004) + both-ports-identical `config.yml` in `tests/conformance/scenarios/us1-config-idempotent.json`
- [X] T042 [P] [US1] Every step is API-read / config-read / closed enumerated question with machine-readable key/value or JSON output (FR-001, FR-002) in `tests/bash/commands/test_config_determinism.bats` and `tests/powershell/commands/Config.Determinism.Tests.ps1`
- [X] T043 [P] [US1] Run summary reports the three effects (discovery / hooks / README) separately (FR-054) in `tests/bash/commands/test_config_three_effects.bats` and `tests/powershell/commands/Config.ThreeEffects.Tests.ps1`. **Scope note**: at this phase only the discovery effect is wired, so this task asserts the summary *structure* (all three effects reported as distinct sections). The assertion that the hooks and README effects actually *perform their writes* is completed when T065 (README wiring, Phase 8) and T085 (hook wiring, Phase 12) land — extend this scenario there rather than duplicating it.

### Implementation for User Story 1

- [X] T044 [US1] Implement the config-command orchestration (discovery → persist config with deterministic canonical serialisation → three-effect summary) in `.specify/extensions/jira/scripts/bash/commands/config.sh` and `.specify/extensions/jira/scripts/powershell/commands/Config.psm1`
- [X] T045 [US1] Author the agent command file with the exact, ordered, model-independent algorithm (closed enumerated questions only, no inferred keys/fields) in `commands/speckit.jira.config.md`
- [X] T046 [US1] Implement three-effect run-summary reporting (discovery / hooks / README reported separately) in `.specify/extensions/jira/scripts/bash/commands/config.sh` and `.specify/extensions/jira/scripts/powershell/commands/Config.psm1`

**Checkpoint 🎯 MVP**: The config command produces a byte-identical, deterministic `config.yml` on both ports — the feature's entry point is usable. The discovery effect and the three-effect summary *structure* are validated here; US1's full Independent Test ("one run performs all three effects") is only satisfiable once the README effect (T065, Phase 8) and the hook effect (T085, Phase 12) are wired — the three-effect assertion is completed at Phase 12, not here.

---

## Phase 6: User Story 11 - Privacy guard BLOCK tier (Priority: P1)

**Goal**: Before every write, block on any exact match of a known coordinate, the `ATATT` token prefix, or a real non-documentation Atlassian host — zero writes, dedicated exit code 9 — active with no gap so the first live dogfooding from a public repo can never leak.

**Independent Test**: Feed fixtures with a known coordinate, the ATATT prefix, and a real Atlassian host; assert each blocks with exit 9 and zero writes. Assert the BLOCK tier is present in the P1 increment, not deferred.

**Why here**: Every write path (US3 `apply_writes` onward) must route through this guard; it ships in the first increment (FR-052, Constitution IV).

### Tests for User Story 11 ⚠️

- [X] T047 [P] [US11] BLOCK-tier tests: known site/project coordinate, ATATT prefix, real `*.atlassian.net` host → exit 9 + zero writes (FR-052) in `tests/bash/sink/test_privacy_block.bats`, `tests/powershell/sink/PrivacyGuard.Block.Tests.ps1`, and `tests/conformance/scenarios/us11-block-tier.json`

### Implementation for User Story 11

- [X] T048 [US11] Implement the privacy guard BLOCK tier (exact-match detection, dedicated exit 9, precision over recall) in `.specify/extensions/jira/scripts/bash/sink/jira/privacy_guard.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/PrivacyGuard.psm1`
- [X] T049 [US11] Wire the BLOCK guard as the mandatory pre-write gate in the apply path (every write, no gap) in `.specify/extensions/jira/scripts/bash/sink/jira/plan_apply.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/PlanApply.psm1`

**Checkpoint**: No write can occur without passing the BLOCK guard.

---

## Phase 7: User Story 3 - Rich, reliable ticket content (Priority: P1)

**Goal**: Deterministic title ladder, never-empty structured description (no `## Summary` dependency), Gherkin panel, distinct Design section, priority-by-logical-name, estimation on create only — rendered to ADF in the sink and written idempotently.

**Independent Test**: Feed a corpus with and without `## Summary`; assert every created Story has a non-empty ladder title, a non-empty structured description, and Gherkin criteria whenever present. Update a ticket and assert the estimation field is not re-sent.

### Tests for User Story 3 ⚠️

- [ ] T050 [P] [US3] Title-ladder + never-empty description incl. no-`## Summary` specs (FR-013, FR-014, SC-002) in `tests/bash/engine/test_parse_title_desc.bats` and `tests/powershell/engine/Parse.TitleDesc.Tests.ps1`
- [ ] T051 [P] [US3] Gherkin → panel and Figma/UX → distinct Design section (FR-015, FR-016) in `tests/bash/sink/test_adf.bats` and `tests/powershell/sink/Adf.Tests.ps1`
- [ ] T052 [P] [US3] Priority P1/P2/P3 → project priority by logical name; estimation written on create only, never re-sent on update (FR-017, FR-018) in `tests/bash/sink/test_plan_apply_content.bats` and `tests/powershell/sink/PlanApply.Content.Tests.ps1`
- [ ] T053 [P] [US3] Action-set parity: neutral doc built + schema-validated before write, both ports emit an identical create/update action set in `tests/conformance/scenarios/us3-ticket-content.json`

### Implementation for User Story 3

- [ ] T054 [US3] Implement the engine parser (title ladder, description synthesis, Gherkin, Design, priority, estimation, user_stories, tasks — zero Jira identifiers) in `.specify/extensions/jira/scripts/bash/engine/parse.sh` and `.specify/extensions/jira/scripts/powershell/engine/Parse.psm1`
- [ ] T055 [US3] Implement neutral-doc assembly + validation (build from parse output, validate via T021) in `.specify/extensions/jira/scripts/bash/engine/interchange.sh` and `.specify/extensions/jira/scripts/powershell/engine/Interchange.psm1`
- [ ] T056 [US3] Implement neutral-blocks → ADF rendering (panels for Gherkin, heading+section for Design) in `.specify/extensions/jira/scripts/bash/sink/jira/adf.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/Adf.psm1`
- [ ] T057 [US3] Implement the ticket identity marker (entity property read/write, origin, per-project scope, research §5) in `.specify/extensions/jira/scripts/bash/sink/jira/identity.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/Identity.psm1`
- [ ] T058 [US3] Implement `plan_writes` + `apply_writes` (resolve logical→id, ordered create/update/transition/comment/link/label action set, estimation create-only) in `.specify/extensions/jira/scripts/bash/sink/jira/plan_apply.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/PlanApply.psm1`
- [ ] T059 [US3] Implement the `reconcile` command wiring engine → sink → summary (BLOCK guard from US11) in `.specify/extensions/jira/scripts/bash/commands/reconcile.sh` and `.specify/extensions/jira/scripts/powershell/commands/Reconcile.psm1`

**Checkpoint**: Reconcile creates and updates rich, non-empty tickets from a spec corpus.

---

## Phase 8: User Story 5 - Version-marked managed block in the consuming README (Priority: P1)

**Goal**: A version-marked, byte-exact managed README block edited by splice — every byte outside preserved verbatim (CRLF-safe), absent block appended once, malformed markers refused with a located error, idempotent on unchanged input.

**Independent Test**: Run the README update with the block present / absent / malformed / CRLF; diff every byte outside the block and assert it is unchanged; assert a malformed marker pair produces zero writes and a located error.

### Tests for User Story 5 ⚠️

- [ ] T060 [P] [US5] Replace only between markers; preserve every byte outside (CRLF-safe); adopt host dominant line-ending; new README uses LF; byte-identical block across ports (FR-025, SC-005) in `tests/bash/engine/test_readme_splice.bats`, `tests/powershell/engine/ReadmeSplice.Tests.ps1`, and `tests/conformance/scenarios/us5-readme-block.json`
- [ ] T061 [P] [US5] Absent block appended once at documented position; absent README created with only the block; malformed markers (start-without-end/nested/duplicated) → zero writes + located error exit 4 (FR-026, FR-027) in `tests/bash/engine/test_readme_edgecases.bats` and `tests/powershell/engine/ReadmeEdgecases.Tests.ps1`
- [ ] T062 [P] [US5] Idempotent (unchanged version + content → zero rewrite, zero-change report); hand-edited block regenerated + summary states replaced (FR-028, FR-029) in `tests/bash/engine/test_readme_idempotent.bats` and `tests/powershell/engine/ReadmeIdempotent.Tests.ps1`

### Implementation for User Story 5

- [ ] T063 [US5] Implement the README byte-splice + dominant line-ending detection + malformed-marker refusal (engine owns the byte manipulation) in `.specify/extensions/jira/scripts/bash/engine/managed_section.sh` and `.specify/extensions/jira/scripts/powershell/engine/ManagedSection.psm1`
- [ ] T064 [US5] Implement the version-marked README-block writer (markers from the single version source, FR-024) in `.specify/extensions/jira/scripts/bash/hooks/readme_block.sh` and `.specify/extensions/jira/scripts/powershell/hooks/ReadmeBlock.psm1`
- [ ] T065 [US5] Wire the README-block writer as the config command's third reported effect in `.specify/extensions/jira/scripts/bash/commands/config.sh` and `.specify/extensions/jira/scripts/powershell/commands/Config.psm1`

**Checkpoint**: All P1 stories complete — deterministic config, dual-style discovery, BLOCK guard, rich tickets, managed README block.

---

## Phase 9: User Story 6 - Idempotency, drift, and Jira-side lifecycle safety (Priority: P2)

**Goal**: Zero writes on an unchanged corpus; named drift never silent overwrite; fail-closed reads with monotonic exit codes; status-category-aware drift; post-scope regression aborts by default; Flagged withholds transitions; human links untouched; `--dry-run` twin predicts exactly.

**Independent Test**: Run against an unchanged corpus and assert zero writes of every kind. Inject each fault and assert zero writes for the affected spec + the documented exit code. Advance a ticket in each status category and assert category-appropriate drift behaviour.

### Tests for User Story 6 ⚠️

- [ ] T066 [P] [US6] Unchanged corpus → zero writes of every kind (create/update/transition/comment/link/label) (FR-030, SC-001) in `tests/conformance/scenarios/us6-zero-churn.json`
- [ ] T067 [P] [US6] Fault injection (401/network/404/429-exhausted) → zero writes for the affected spec + monotonic exit codes 2/3 (FR-032) in `tests/bash/sink/test_fail_closed.bats`, `tests/powershell/sink/FailClosed.Tests.ps1`, and `tests/conformance/scenarios/us6-fail-closed.json`
- [ ] T068 [P] [US6] Status-category drift: post-scope never backward; unknown → named + suggest classify; halted → stop all writes + two remediations; mapped advanced Jira-side → named warning, never silent overwrite (FR-031, FR-034) in `tests/bash/engine/test_drift.bats` and `tests/powershell/engine/Drift.Tests.ps1`
- [ ] T069 [P] [US6] Post-scope regression aborts transition unless `--on-drift=proceed` (FR-035); Flagged withholds transitions, flag surfaced, never set/removed (FR-036); human links never modified, blockers info-note (FR-037) in `tests/bash/sink/test_lifecycle_safety.bats` and `tests/powershell/sink/LifecycleSafety.Tests.ps1`
- [ ] T070 [P] [US6] `--dry-run` report equals the real run's action set (FR-033) in `tests/conformance/scenarios/us6-dry-run.json`

### Implementation for User Story 6

- [ ] T071 [US6] Implement status-category-aware drift classification (pure functions, no Jira calls) in `.specify/extensions/jira/scripts/bash/engine/drift.sh` and `.specify/extensions/jira/scripts/powershell/engine/Drift.psm1`
- [ ] T072 [US6] Implement the managed-section idempotency diff + zero-churn decision (pure functions) in `.specify/extensions/jira/scripts/bash/engine/idempotency.sh` and `.specify/extensions/jira/scripts/powershell/engine/Idempotency.psm1`
- [ ] T073 [US6] Implement `--on-drift` handling, Flagged-transition withholding, human-link preservation, and the `--dry-run` twin in `.specify/extensions/jira/scripts/bash/sink/jira/plan_apply.sh`, `.specify/extensions/jira/scripts/powershell/sink/jira/PlanApply.psm1`, and the reconcile command

**Checkpoint**: Reconcile is idempotent, drift-aware, fail-closed, and dry-run-predictable.

---

## Phase 10: User Story 7 - Human-written content is never overwritten (Priority: P2)

**Goal**: On human-origin tickets, write only inside a delimited managed panel; preserve every human line verbatim above it permanently (even after later edits); compute the description idempotency diff on the managed section alone; bridge-created tickets have no delimiters.

**Independent Test**: On a human-origin ticket, write description with human text above the panel, run reconcile repeatedly, assert human text byte-preserved and the idempotency diff computed only on the managed section. On a bridge-created ticket, assert the whole description is the managed section with no delimiters.

### Tests for User Story 7 ⚠️

- [ ] T074 [P] [US7] Human-origin: write only inside the panel, preserve human lines verbatim incl. after later edit; diff on managed section only; bridge-created whole-description no delimiters; discriminator is recorded origin (FR-038, FR-039, FR-040) in `tests/bash/engine/test_managed_panel.bats`, `tests/powershell/engine/ManagedPanel.Tests.ps1`, and `tests/conformance/scenarios/us7-human-content.json`

### Implementation for User Story 7

- [ ] T075 [US7] Implement origin-discriminated managed-panel splice for Jira descriptions (preserve human lines above the panel; whole-description for bridge-created) in `.specify/extensions/jira/scripts/bash/engine/managed_section.sh` and `.specify/extensions/jira/scripts/powershell/engine/ManagedSection.psm1`, wired into ADF render + plan_apply

**Checkpoint**: Human-authored description content is provably never overwritten.

---

## Phase 11: User Story 8 - Multi-project / multi-team on one repository (Priority: P2)

**Goal**: Route each spec to its Jira project by folder prefix / spec label / configured default; each reconciles exclusively with its own style, discovery, and mapping; the config command re-binds incrementally without touching existing mappings; identities are per-project scoped.

**Independent Test**: Configure one spec routed to a company-managed project and another to a team-managed project; assert each reconciles with its own discovery results. Re-run the config command adding a new project and assert only that project's mapping is bound.

### Tests for User Story 8 ⚠️

- [ ] T076 [P] [US8] Routing by folder-prefix / spec-label / configured default; mixed company+team-managed each with its own discovery + mapping (FR-041, FR-042) in `tests/bash/engine/test_routing.bats`, `tests/powershell/engine/Routing.Tests.ps1`, and `tests/conformance/scenarios/us8-mixed-routing.json`
- [ ] T077 [P] [US8] Config incrementally re-runnable — adding a project binds only that one, existing mappings untouched (FR-043); per-project identity scope, no collision (FR-044) in `tests/bash/commands/test_config_incremental.bats` and `tests/powershell/commands/Config.Incremental.Tests.ps1`

### Implementation for User Story 8

- [ ] T078 [US8] Implement routing resolution (engine, from config `routing[]` / `routing_default` rules) in `.specify/extensions/jira/scripts/bash/engine/interchange.sh` and `.specify/extensions/jira/scripts/powershell/engine/Interchange.psm1`
- [ ] T079 [US8] Implement multi-project iteration + incremental re-bind in `.specify/extensions/jira/scripts/bash/commands/config.sh` and `.specify/extensions/jira/scripts/powershell/commands/Config.psm1`

**Checkpoint**: One repository reconciles many specs to distinct projects of mixed styles without collision.

---

## Phase 12: User Story 9 - Self-healing automatic mirror (Priority: P2)

**Goal**: `after_*` lifecycle hooks trigger a non-blocking reconcile (≤1 WARNING, host exit never affected); hook registration is idempotent and resilient; missing hooks are repaired in one command; an explicitly disabled hook stays disabled forever; hook health is reported every run.

**Independent Test**: Fire each lifecycle hook with a forced bridge failure and assert the host exit code is unaffected with ≤1 WARNING. Upgrade/reinstall and assert missing hooks are detected and repaired while a disabled hook stays disabled.

### Tests for User Story 9 ⚠️

- [ ] T080 [P] [US9] Idempotent `after_*` registration in `.specify/extensions.yml` (specify/clarify/plan/tasks/implement/analyze); re-run produces no duplicates (FR-045, FR-047) in `tests/bash/hooks/test_register_hooks.bats`, `tests/powershell/hooks/RegisterHooks.Tests.ps1`, and `tests/conformance/scenarios/us9-hook-registration.json`
- [ ] T081 [P] [US9] Bridge failure in a hook → ≤1 WARNING, host exit unaffected (FR-046); disabled hook stays disabled across upgrade/reinstall/repair (FR-048, SC-008) in `tests/bash/hooks/test_hook_resilience.bats` and `tests/powershell/hooks/HookResilience.Tests.ps1`
- [ ] T082 [P] [US9] Hook health checked + reported in every run summary; `--repair-hooks` one-command repair (FR-047) in `tests/bash/commands/test_hook_health.bats` and `tests/powershell/commands/HookHealth.Tests.ps1`

### Implementation for User Story 9

- [ ] T083 [US9] Implement idempotent `after_*` hook registration (set-not-append, respect `enabled: false`) in `.specify/extensions/jira/scripts/bash/hooks/register_hooks.sh` and `.specify/extensions/jira/scripts/powershell/hooks/RegisterHooks.psm1`
- [ ] T084 [US9] Implement hook-context exit downgrade to a single WARNING + hook-health reporting + `--repair-hooks` flag in `.specify/extensions/jira/scripts/bash/commands/reconcile.sh`, `.specify/extensions/jira/scripts/powershell/commands/Reconcile.psm1`, and the CLI layer
- [ ] T085 [US9] Wire hook registration as the config command's second reported effect (FR-054) in `.specify/extensions/jira/scripts/bash/commands/config.sh` and `.specify/extensions/jira/scripts/powershell/commands/Config.psm1`

**Checkpoint**: All P2 stories complete — trustworthy, self-healing automatic mirroring.

---

## Phase 13: User Story 10 - Editing an existing mentioned ticket (Priority: P3)

**Goal**: Mentioning an issue key reads that ticket, stamps it with the spec's identity, updates only that ticket thereafter, and logs every mutation; a read-only fetch returns content + linked Confluence (title/url only) + parent context + siblings; a ticket already claimed by another spec produces zero writes and an actionable refusal.

**Independent Test**: Mention an unclaimed key and assert the bridge fetches content/AC/priority/labels/status/flag/links + Confluence title+url + parent + siblings, then stamps identity and updates only that ticket. Mention a ticket claimed by another spec and assert zero writes + actionable refusal.

### Tests for User Story 10 ⚠️

- [ ] T086 [P] [US10] Read-only fetch (content/AC/priority/labels/status/flag/links, Confluence title+url only, parent context, sibling one-liners) (FR-050); claimed-by-other → zero writes + actionable refusal offering reopen or new-linked (FR-051) in `tests/bash/commands/test_mention.bats`, `tests/powershell/commands/Mention.Tests.ps1`, and `tests/conformance/scenarios/us10-mention.json`

### Implementation for User Story 10

- [ ] T087 [US10] Implement `fetch_mentioned` (read-only; Confluence page content NOT fetched) in `.specify/extensions/jira/scripts/bash/sink/jira/discovery.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/Discovery.psm1`
- [ ] T088 [US10] Implement the `mention` command (stamp identity, update only that ticket, log every mutation, refuse on claimed-by-other) in `.specify/extensions/jira/scripts/bash/commands/mention.sh` and `.specify/extensions/jira/scripts/powershell/commands/Mention.psm1`

**Checkpoint**: Mentioned-ticket read/edit flow works with identity safety.

---

## Phase 14: User Story 12 - Privacy guard WARN tier and allowlist without false positives (Priority: P3)

**Goal**: On top of the BLOCK tier, warn (not block) on generic shapes (emails, UUIDs); allowlisted Confluence links / domains (`.extensionignore` gitignore syntax or `config.privacy.allowlist`) produce neither block nor warning; `.extensionignore` paths are excluded from both parsing and scanning.

**Independent Test**: A generic email warns; an allowlisted Confluence link passes silently; a BLOCK-tier false positive on allowlisted content is a failing test; `.extensionignore` paths are excluded from parsing and scanning.

### Tests for User Story 12 ⚠️

- [ ] T089 [P] [US12] Generic shapes warn but don't block; allowlisted Confluence/domain → neither block nor warning; `.extensionignore` paths excluded from parse + scan; allowlisted content never BLOCK-false-positives (FR-053) in `tests/bash/sink/test_privacy_warn.bats`, `tests/powershell/sink/PrivacyGuard.Warn.Tests.ps1`, and `tests/conformance/scenarios/us12-warn-allowlist.json`

### Implementation for User Story 12

- [ ] T090 [US12] Implement the WARN tier + allowlist (`.extensionignore` + `config.privacy.allowlist`) + parse/scan exclusion in `.specify/extensions/jira/scripts/bash/sink/jira/privacy_guard.sh` and `.specify/extensions/jira/scripts/powershell/sink/jira/PrivacyGuard.psm1`

**Checkpoint**: All twelve user stories complete.

---

## Phase 15: Polish & Cross-Cutting Concerns

**Purpose**: Live verification, governance, docs, and final gate confirmation across all stories.

- [ ] T091 [P] Implement the opt-in live zero-churn suite (real instance, non-blocking on fork PRs) verifying SC-001 and SC-008 in `tests/live/`
- [ ] T092 [P] Add dedicated SC-007 tests: the resolved token never appears in argv, logs, errors, or traces at maximum verbosity on either port in `tests/bash/lib/test_token_leak.bats` and `tests/powershell/lib/TokenLeak.Tests.ps1`
- [ ] T093 [P] Add the SC-009 test: `git diff` over `.specify/scripts/` and `.specify/templates/` is empty after a full install + config run in `tests/conformance/scenarios/sc009-core-untouched.json`
- [ ] T094 [P] Finalize `.specify/extensions/jira/CHANGELOG.md` (SemVer) and the README managed-block template body; verify the catalog id (Constitution XII) in `.specify/extensions/jira/extension.yml`
- [ ] T095 Run the quickstart.md end-to-end validation (every scenario mapped to its SC-00x) per `specs/001-jira-reconcile-engine/quickstart.md`
- [ ] T096 [P] Write install/prerequisite docs (bash ≥ 4 with macOS 3.2 named, pwsh 7+, curl/jq/git; NFR-4) in the README managed block and `.specify/extensions/jira/` docs
- [ ] T097 Confirm the final gates green: coverage ≥ 80% both ports (kcov + Pester), critical paths near 100%, module-parity check, engine/sink greps, and version-string grep (SC-006)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup. **BLOCKS all user stories** (mocked double, conformance harness, `lib/`, sink transport, CI gates).
- **User Stories (Phases 3–14)**: All depend on Foundational. Real inter-story dependencies below.
- **Polish (Phase 15)**: Depends on all targeted user stories.

### User Story Dependencies (real, not just priority)

- **US4 (P1, Phase 3)**: Config storage + version source. Depends only on Foundational. Prerequisite for US1, US2, US5, US8.
- **US2 (P1, Phase 4)**: Discovery + mapping. Depends on Foundational + US4 (persists into config). Prerequisite for US1, US3, US8.
- **US1 (P1, Phase 5) 🎯 MVP**: Config command orchestration. Depends on US4 + US2. Its hooks/README effects integrate US9 (T083) and US5 (T064).
- **US11 (P1, Phase 6)**: BLOCK guard. Depends on Foundational. Prerequisite for every write path (US3 onward).
- **US3 (P1, Phase 7)**: Ticket content + reconcile writes. Depends on US2 (discovery) + US11 (guard) + Foundational (interchange/transport).
- **US5 (P1, Phase 8)**: README block. Depends on US4 (version source); feeds US1's third effect.
- **US6 (P2, Phase 9)**: Idempotency/drift/lifecycle. Depends on US3 (writes exist to make idempotent).
- **US7 (P2, Phase 10)**: Human-content panel. Depends on US3 (description rendering) + US6 (idempotency diff).
- **US8 (P2, Phase 11)**: Multi-project routing. Depends on US2 + US3 + US1 (config iteration).
- **US9 (P2, Phase 12)**: Self-healing hooks. Depends on US1 (config command) + a runnable reconcile (US3).
- **US10 (P3, Phase 13)**: Mentioned-ticket edit. Depends on US3 (identity + write) + US2 (fetch).
- **US12 (P3, Phase 14)**: WARN tier + allowlist. Depends on US11 (BLOCK tier module).

### Within Each User Story

- Tests MUST be written and MUST FAIL before implementation (Constitution XIII).
- Engine (neutral) modules before sink (Jira) modules; sink before commands.
- Both ports mirror module-for-module; the conformance scenario is the parity proof.
- Story complete and independently testable before the next.

### Parallel Opportunities

- All Setup tasks marked [P] run in parallel.
- All Foundational test tasks (T010, T012, T014, T016, T018, T020, T022) run in parallel; the three CI-gate tasks (T025, T026, T027) run in parallel.
- Within a story, all `[P]` test tasks run in parallel before implementation.
- After the P1 chain (US4 → US2 → US1 / US11 → US3 → US5) completes, the P2 stories US6/US7 (content-side) and US9 (hooks-side) can be staffed in parallel; US8 needs US2+US3.
- Bash and PowerShell are distinct files: a module's two ports can be split across two developers within one task.

---

## Parallel Example: User Story 3

```bash
# Launch all US3 tests together (they must FAIL first):
Task: "Title-ladder + never-empty description tests in tests/bash/engine/test_parse_title_desc.bats + tests/powershell/engine/Parse.TitleDesc.Tests.ps1"   # T050
Task: "Gherkin panel + Design section tests in tests/bash/sink/test_adf.bats + tests/powershell/sink/Adf.Tests.ps1"                                        # T051
Task: "Priority + estimation-create-only tests in tests/bash/sink/test_plan_apply_content.bats + tests/powershell/sink/PlanApply.Content.Tests.ps1"        # T052
Task: "Action-set parity scenario in tests/conformance/scenarios/us3-ticket-content.json"                                                                  # T053

# Then engine before sink before command:
Task: "engine/parse.sh + engine/Parse.psm1"          # T054  (neutral, no Jira identifiers)
Task: "engine/interchange.sh + engine/Interchange.psm1"  # T055
Task: "sink/jira/adf.sh + sink/jira/Adf.psm1"        # T056
Task: "sink/jira/identity.sh + sink/jira/Identity.psm1"  # T057
```

---

## Implementation Strategy

### MVP First (through User Story 1)

1. Phase 1: Setup.
2. Phase 2: Foundational (CRITICAL — blocks all stories).
3. Phase 3: US4 (config storage + version source).
4. Phase 4: US2 (dual-style discovery + mapping).
5. Phase 5: US1 (deterministic config command). **STOP and VALIDATE**: run `/speckit.jira.config` twice on both ports, diff `config.yml` — byte-identical proves the MVP.

### Incremental Delivery (first shippable increment = all P1)

1. MVP (US4 → US2 → US1) → deterministic configuration works.
2. Add US11 (BLOCK guard) → every write is guarded before any live run.
3. Add US3 (rich tickets) → reconcile creates/updates real tickets.
4. Add US5 (README block) → the extension documents itself. **First public-safe increment: all six P1 stories, BLOCK guard active on the first live dogfood.**
5. Add P2 (US6 → US7 → US8 → US9) → idempotent, human-safe, multi-project, self-healing.
6. Add P3 (US10, US12) → mentioned-ticket editing and the WARN tier/allowlist hardening.

### Parallel Team Strategy

Once Foundational is done and the P1 chain (US4 → US2 → US1) lands:

1. Developer A: US11 + US3 (write path + guard).
2. Developer B: US5 (README block) + US9 (hooks).
3. Developer C: US6 + US7 (idempotency + human-content safety) once US3 writes exist.
4. Each story integrates through the conformance corpus, which fails on any cross-port divergence.

---

## Notes

- [P] = different files, no dependencies on incomplete tasks.
- Every implementation task is preceded by its test task; verify the test FAILS before implementing (Constitution XIII).
- The conformance corpus (`tests/conformance/`) is the twin-port equivalence proof — a divergence is a failing test, not a documented quirk (NFR-1).
- `engine/` carries zero Jira identifiers and never sources/imports `sink/` (Constitution VIII, CI grep-enforced by T026).
- Never write under `.specify/scripts/` or `.specify/templates/` (Spec Kit core; FR-055, SC-009).
- The token never touches argv, logs, errors, or traces (NFR-3, eliminatory; SC-007).
- Commit after each task or logical group; stop at any checkpoint to validate a story independently.
