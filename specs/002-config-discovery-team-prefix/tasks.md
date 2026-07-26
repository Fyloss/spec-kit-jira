# Tasks: Reliable Automatic Jira Discovery & Team-Based Feature Prefix

**Input**: Design documents from `/specs/002-config-discovery-team-prefix/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: REQUIRED — Constitution XIII (TDD ≥ 80%) mandates that every implementation task is preceded by its failing-first test task. Regression tests for the two reported defects MUST fail on the current code before the fix is applied.

**Organization**: Tasks are grouped by user story. Twin-port rule (FR-020): every behaviour ships in both the Bash and PowerShell ports with byte-identical persisted output and identical exit codes; a story is complete only when both ports and their conformance scenarios pass.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)

## Path Conventions

Single-project twin-port layout (unchanged from 001):

- Bash port: `scripts/bash/{engine,sink/jira,lib,commands,hooks}/`
- PowerShell port: `scripts/powershell/{engine,sink/jira,lib,commands,hooks}/`
- Tests: `tests/bash/<layer>/test_<topic>.bats`, `tests/powershell/<layer>/<Topic>.Tests.ps1`, `tests/conformance/scenarios/<name>.json` (run by `tests/conformance/run-scenario.sh`)

---

## Phase 1: Setup (Shared Fixtures)

**Purpose**: Recorded payloads and fixture repositories every story's tests replay

- [X] T001 [P] Add ambiguous-style discovery payload fixtures in tests/conformance/fixtures/: a `GET /project/{key}` payload with neither `style` nor `simplified`, and one with contradictory signals (`style: "classic"` + `simplified: true`) — used by US1 regression and conformance tests
- [X] T002 [P] Add `repo-with-teams` conformance fixture in tests/conformance/fixtures/repo-with-teams/: committed `config.yml` declaring teams `ijt` (project IJT, prefix `ijt-`, pattern `ijt-<ID>/<FEATURE_NAME>`) and `wex` (project WEX, prefix `wex-`, pattern `wex-<ID>/<FEATURE_NAME>`), plus a sample `personal.yml` selecting `ijt` — used by US3 tests and scenarios

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Mock Jira server endpoints that US2 and US3 conformance scenarios replay — no story's conformance suite can run without them

**⚠️ CRITICAL**: Complete before starting any user story's conformance tasks

- [X] T003 Extend the mock Jira server in tests/conformance/mock-jira/ with paginated `GET /rest/api/3/project/search` (honouring `startAt`/`maxResults`, `isLast`/`total`, per-page `values[].{key,name,style,simplified}`), including an empty-result variant (contracts/jira-endpoints-delta.md)
- [X] T004 Extend the mock Jira server in tests/conformance/mock-jira/ with `GET /rest/api/3/issue/{key}?fields=project` (mentioned-ticket validation) and `POST /rest/api/3/issue` (create, returning a new key), both recorded in the mock's call log so scenarios can assert call sequences and zero-call cases

**Checkpoint**: Fixtures and mock endpoints ready — user story phases can begin

---

## Phase 3: User Story 1 — Accurate automatic project style detection (Priority: P1) 🎯 MVP

**Goal**: Style comes exclusively from the API payload or an explicit operator answer; ambiguity asks (interactive) or fails closed with exit 4 (unattended); the binding records `style` + `style_source` provenance (FR-001/FR-002/FR-003)

**Independent Test**: Run the ceremony against a team-managed payload → `style: team_managed`, `style_source: api` persisted; against an ambiguous payload unattended → exit 4, zero writes; with `--style KEY=team_managed` → persisted with `style_source: operator`. Byte-identical binding across ports and re-runs.

### Tests for User Story 1 (write FIRST — must FAIL on current code) ⚠️

- [X] T005 [P] [US1] Failing regression bats suite in tests/bash/sink/test_discovery_ambiguous.bats: `_disc_style` on a payload with no `style`/`simplified` yields empty (never `company_managed`); contradictory signals (`classic`+`simplified:true`) yield empty; unambiguous signals still map correctly — MUST fail against current scripts/bash/sink/jira/discovery.sh
- [X] T006 [P] [US1] Failing Pester twin in tests/powershell/sink/Discovery.Ambiguous.Tests.ps1 asserting the same three-valued mapping against scripts/powershell/sink/jira/Discovery.psm1
- [X] T007 [P] [US1] Bats suite in tests/bash/commands/test_config_style.bats: `--style KEY=VALUE` repeatable flag (bad value ⇒ usage exit 1); resolution order api → operator → fail closed; ambiguous without `--style` ⇒ exit 4, zero writes, stderr names project key + missing/contradictory signal + the two valid values; committed `config.yml` `style` conflicting with an unambiguous API signal ⇒ treated as ambiguous; summary carries per-project `style`/`style_source` (FR-003)
- [X] T008 [P] [US1] Pester twin in tests/powershell/commands/Config.Style.Tests.ps1 covering the same resolution matrix
- [X] T009 [P] [US1] Conformance scenario tests/conformance/scenarios/us1-style-ambiguous-refusal.json: unattended run against the ambiguous fixture ⇒ exit 4, zero writes, stderr names project and missing signal, byte-identical stderr/exit across ports
- [X] T010 [P] [US1] Conformance scenario tests/conformance/scenarios/us1-style-operator-answer.json: `config --style PROJ1=team_managed --json` against the ambiguous fixture ⇒ persisted `style_source: "operator"`, summary audits it, `config.local.yml` byte-identical across ports
- [X] T011 [US1] Extend tests/conformance/scenarios/us2-team-managed-discovery.json and us2-company-managed-discovery.json to also assert the persisted `style` + `style_source: "api"` in `config.local.yml` and the summary audit

### Implementation for User Story 1

- [X] T012 [US1] Make `_disc_style` three-valued in scripts/bash/sink/jira/discovery.sh: explicit non-contradictory signal ⇒ mapped style; absent or contradictory ⇒ empty result surfaced as `style: null` in the binding; remove the `company_managed` default (research §2)
- [X] T013 [US1] Twin the three-valued mapping in scripts/powershell/sink/jira/Discovery.psm1 (makes T005/T006 pass)
- [X] T014 [US1] Update scripts/bash/lib/config.sh: `projects[].style` becomes optional in the committed-config schema (operator declaration when present); extend the config.local known-key list with `style` and `style_source` under `resolved_ids.<KEY>` so the canonical serialiser round-trips them byte-identically
- [X] T015 [US1] Twin the schema changes in scripts/powershell/lib/Config.psm1
- [X] T016 [US1] Implement style resolution in scripts/bash/commands/config.sh: repeatable `--style KEY=VALUE` flag (enum-validated, exit 1 otherwise); per-project order api-signal → `--style`/committed declaration (provenance `operator`) → fail closed exit 4 with zero writes; committed-vs-API conflict re-enters the ambiguous branch; persist `style`/`style_source`; per-project audit in the run summary (contracts/config-cli-contract.md)
- [X] T017 [US1] Twin the style resolution in scripts/powershell/commands/Config.psm1 (makes T007–T011 pass)
- [X] T018 [P] [US1] Update templates/config.yml.template: remove the pre-filled `style: company_managed` line, replace with a comment documenting the optional operator declaration

**Checkpoint**: US1 fully functional — ambiguity never silently defaults; provenance auditable; both ports byte-identical

---

## Phase 4: User Story 2 — Jira-first discovery with a transparent branch-based fallback (Priority: P2)

**Goal**: In a connected run the project key comes only from argument → committed config (placeholder `PROJ` = unset) → closed question over `discovery_list_projects`; git state is never a source. Undefined connection parameters trigger a loud, provisional, write-free degraded mode (FR-004…FR-009)

**Independent Test**: Run the ceremony without connection parameters → explicit warning, `provisional: true` proposals, re-run guidance, `config.local.yml` untouched; re-run with parameters → authoritative discovery, mismatches surfaced, branch names play no role; `config NOPE` → transport fail-closed exit, no substitution.

### Tests for User Story 2 (write FIRST — must FAIL before implementation) ⚠️

- [X] T019 [P] [US2] Bats suite in tests/bash/sink/test_discovery_list_projects.bats: `discovery_list_projects` paginates `GET /project/search`, extracts `key`/`name`/style per the §1 mapping into a canonical array, and fails closed with the "no visible project" error on zero results
- [X] T020 [P] [US2] Pester twin in tests/powershell/sink/Discovery.ListProjects.Tests.ps1 for `Get-JiraDiscoveryProjectList`
- [X] T021 [P] [US2] Bats suite in tests/bash/commands/test_config_key_sources.bats: positional `PROJECT_KEY` validated by the first discovery read; unknown key ⇒ transport fail-closed exit with no substitution (FR-006); configured key equal to the literal `PROJ` placeholder treated as unset (FR-005); unattended with no usable key ⇒ exit 4 whose error describes the closed-question path
- [X] T022 [P] [US2] Pester twin in tests/powershell/commands/Config.KeySources.Tests.ps1
- [X] T023 [P] [US2] Bats suite in tests/bash/commands/test_config_degraded.bats: degraded mode triggers only when `SPEC_KIT_JIRA_BASE_URL` is unset or the token resolves through none of the three rungs, tested before any Jira call; degraded run ⇒ exit 0, one warning naming the missing variables, distinct `<prefix>-<number>/…` branch prefixes proposed with `provisional: true`, `rerun_guidance` present, `config.local.yml` byte-identical to before; defined-but-wrong credentials ⇒ auth/network exit codes, never degraded (research §4)
- [X] T024 [P] [US2] Pester twin in tests/powershell/commands/Config.Degraded.Tests.ps1
- [X] T025 [P] [US2] Docs regression test in tests/bash/commands/test_agent_doc_config.bats: grep-assert commands/speckit.jira.config.md contains the normative FR-007 wording — key/style **never** inferred from git state in a connected run, branch-derived output provisional-only, exactly the two new closed questions — MUST fail against the current command definition
- [X] T026 [P] [US2] Conformance scenario tests/conformance/scenarios/us2-list-projects.json: connected run with no key ⇒ paginated project/search call sequence recorded, closed-question error/output lists the accessible projects, byte-identical across ports
- [X] T027 [P] [US2] Conformance scenario tests/conformance/scenarios/us2-placeholder-key-refusal.json: `config.yml` holding `PROJ`, arbitrary branch prefix checked out ⇒ exit 4 unattended, summary contains no branch-derived value (quickstart scenario 3)
- [X] T028 [P] [US2] Conformance scenario tests/conformance/scenarios/us2-degraded-mode.json: no base URL in env ⇒ exit 0, provisional proposals, re-run guidance, zero writes, zero mock-Jira calls; both ports byte-identical
- [ ] T029 [US2] Implement `discovery_list_projects` in scripts/bash/sink/jira/discovery.sh: paginated `GET /rest/api/3/project/search` through the existing transport, canonical array output reusing the three-valued style mapping, zero-results fail-closed error
- [ ] T030 [US2] Twin `Get-JiraDiscoveryProjectList` in scripts/powershell/sink/jira/Discovery.psm1 (makes T019/T020 pass)
- [ ] T031 [US2] Add the placeholder-key rule in scripts/bash/lib/config.sh: a configured key equal to the template's literal `PROJ` constant is treated as unset (constant lives beside the template consumer)
- [ ] T032 [US2] Twin the placeholder rule in scripts/powershell/lib/Config.psm1
- [ ] T033 [US2] Implement key sourcing and degraded mode in scripts/bash/commands/config.sh: optional positional `PROJECT_KEY` (validated, fail-closed, no substitution); source order argument → config → closed question, exit 4 unattended; degraded-mode trigger test before any Jira call; degraded branch scan via `git for-each-ref refs/heads --format='%(refname:short)'` producing provisional proposals, one warning, copy-pasteable re-run command, zero writes to config.local.yml; mismatch surfacing on the next connected run (FR-009)
- [ ] T034 [US2] Twin key sourcing and degraded mode in scripts/powershell/commands/Config.psm1 (makes T021–T028 pass)
- [ ] T035 [US2] Rewrite commands/speckit.jira.config.md per contracts/config-cli-contract.md: normative MUST/NEVER wording forbidding git-state inference in connected runs, degraded-mode announcement/provisional semantics, the two closed questions (style two-value; key over the discovered list), agent asks then re-invokes with `--style`/the chosen key (makes T025 pass)

**Checkpoint**: US1 + US2 independently functional — connected runs never touch git state; degraded runs are loud, provisional, and write-free

---

## Phase 5: User Story 3 — Team naming conventions with a personal team selection (Priority: P3)

**Goal**: Committed `teams:` catalogue + gitignored `.specify/jira/personal.yml` selection; new twin-ported `feature` command resolves the ticket first (validate or create), emits `branch_name` per team pattern and flat `short_name` with deduped prefix; registered as non-blocking `before_specify` hook; no selection ⇒ byte-for-byte today's behaviour (FR-010…FR-019)

**Independent Test**: With the `repo-with-teams` fixture and `team: ijt` selected: `feature IJT-42 "invoice export"` → `ijt-42/invoice-export` + `ijt-invoice-export`, ticket attached; no ticket → created in IJT; `WEX-7` → `confirmation_required`; no personal file → `{active:false}`, zero Jira calls, behaviour identical to today.

### Tests for User Story 3 (write FIRST — must FAIL before implementation) ⚠️

- [ ] T036 [P] [US3] Bats suite in tests/bash/lib/test_teams_catalogue.bats: `teams:` validation — unique `id` (`^[a-z][a-z0-9]*$`) and `folder_prefix` (`^[a-z0-9][a-z0-9-]*-$`); `branch_pattern` contains `<ID>` and `<FEATURE_NAME>` exactly once each, other chars restricted to `[a-z0-9/_-]`, unknown placeholders refused; credential-shaped values refused without echoing; absent section changes nothing (contracts/teams-catalogue.schema.json)
- [ ] T037 [P] [US3] Pester twin in tests/powershell/lib/TeamsCatalogue.Tests.ps1
- [ ] T038 [P] [US3] Bats suite in tests/bash/lib/test_personal_config.bats: `.specify/jira/personal.yml` loader — absent file ⇒ inactive; unknown `team` ⇒ located error naming the file and listing valid catalogue ids (exit 4); `override` passes catalogue-entry validation; credential-shaped values refused without echoing (contracts/personal-config.schema.json)
- [ ] T039 [P] [US3] Pester twin in tests/powershell/lib/PersonalConfig.Tests.ps1
- [ ] T040 [P] [US3] Bats suite in tests/bash/engine/test_naming.bats: pattern expansion with `<ID>`/`<FEATURE_NAME>`; ticket number = key stripped of `^[A-Z][A-Z0-9_]+-`; `short_name` = `folder_prefix` + short name with prefix never duplicated (`ijt-ijt-…` impossible); `/` in pattern yields git hierarchy only, folder component stays flat; plus the engine-boundary assertion that scripts/bash/engine/naming.sh contains no issue-key-shaped text (Constitution VIII)
- [ ] T041 [P] [US3] Pester twin in tests/powershell/engine/Naming.Tests.ps1
- [ ] T042 [P] [US3] Bats suite in tests/bash/sink/test_ticket.bats: `ticket_validate` reads `GET /issue/{key}?fields=project` (fail-closed codes for a mentioned key); `ticket_create` POSTs with `fields.project.key` = team project, `fields.issuetype.id` = the binding's resolved story-type id (never a literal type name), PASS-1 privacy guard runs before the POST (BLOCK ⇒ exit 9, zero writes), created ticket identity-stamped
- [ ] T043 [P] [US3] Pester twin in tests/powershell/sink/Ticket.Tests.ps1
- [ ] T044 [P] [US3] Bats suite in tests/bash/commands/test_feature.bats covering contracts/feature-cli-contract.md: no team selected ⇒ `{active:false}` exit 0 zero side effects; invalid personal file ⇒ exit 4 located error; mentioned ticket of another catalogue team without `--use-team` ⇒ `confirmation_required` exit 0 zero writes; `--use-team` accepts only catalogue ids, personal file untouched; non-catalogue-project ticket ⇒ proceed/stop confirmation; no key ⇒ guarded create; Jira unreachable or create refused ⇒ `{active:false}` + exactly one warning, exit 0 (FR-016); `--dry-run` predicts would-attach/would-create with zero writes; `override_used` reported
- [ ] T045 [P] [US3] Pester twin in tests/powershell/commands/Feature.Tests.ps1
- [ ] T046 [P] [US3] Extend tests/bash/hooks/test_register_hooks.bats: `before_specify` → `speckit.jira.feature` registered `enabled: true, optional: true`, merged set-not-append; operator-disabled entry never re-added or re-enabled; the six existing `after_*` registrations unchanged
- [ ] T047 [P] [US3] Pester twin in tests/powershell/hooks/RegisterHooks.Tests.ps1 for the `before_specify` registration
- [ ] T048 [P] [US3] Bats suite in tests/bash/commands/test_config_gitignore.bats: the config ceremony's gitignore effect appends `.specify/jira/personal.yml` coverage idempotently, reports `created|written|unchanged|skipped`, and a second run reports `unchanged` with a byte-identical `.gitignore` (FR-019)
- [ ] T049 [P] [US3] Pester twin in tests/powershell/commands/Config.Gitignore.Tests.ps1
- [ ] T050 [P] [US3] Conformance scenarios tests/conformance/scenarios/us3-feature-attach.json (mentioned `IJT-42` ⇒ attached, `ijt-42/invoice-export`, `ijt-invoice-export`) and us3-feature-create.json (no ticket ⇒ mock records `POST /issue`, created number feeds `<ID>`), both on the repo-with-teams fixture, byte-identical across ports
- [ ] T051 [P] [US3] Conformance scenarios tests/conformance/scenarios/us3-feature-no-team.json (`{active:false}`, empty mock call log), us3-feature-cross-team.json (`WEX-7` ⇒ `confirmation_required` naming `wex`; re-invoke `--use-team wex` ⇒ `wex-7/…`, personal.yml unchanged), and us3-feature-fallback.json (unreachable Jira ⇒ `{active:false}` + one warning, exit 0)
- [ ] T052 [P] [US3] Conformance scenario tests/conformance/scenarios/us3-gitignore-effect.json: first config run `created|written`, second run all effects `unchanged`, `git check-ignore .specify/jira/personal.yml` exits 0 (quickstart scenario 7)

### Implementation for User Story 3

- [ ] T053 [US3] Implement the `teams:` catalogue schema and load-time validation in scripts/bash/lib/config.sh (uniqueness, prefix/pattern grammar, credential-shape refusal, optional section)
- [ ] T054 [US3] Twin the catalogue validation in scripts/powershell/lib/Config.psm1 (makes T036/T037 pass)
- [ ] T055 [US3] Implement the personal-file loader in scripts/bash/lib/config.sh: read `.specify/jira/personal.yml`, validate `team` against the catalogue with the located-error listing, validate `override` as a catalogue entry, never write the file
- [ ] T056 [US3] Twin the personal-file loader in scripts/powershell/lib/Config.psm1 (makes T038/T039 pass)
- [ ] T057 [P] [US3] Create pure naming engine scripts/bash/engine/naming.sh: pattern expansion, project-key stripping of an opaque ticket key, folder-prefix dedup, flat-folder guarantee — no Jira knowledge, no issue-key-shaped literals
- [ ] T058 [P] [US3] Create twin scripts/powershell/engine/Naming.psm1 (makes T040/T041 pass)
- [ ] T059 [P] [US3] Create sink scripts/bash/sink/jira/ticket.sh: `ticket_validate` (read via existing transport) and `ticket_create` (guarded write: PASS-1 guard, resolved story-type id, identity stamp) per contracts/jira-endpoints-delta.md
- [ ] T060 [P] [US3] Create twin scripts/powershell/sink/jira/Ticket.psm1 (makes T042/T043 pass)
- [ ] T061 [US3] Create scripts/bash/commands/feature.sh implementing `cmd_feature` per contracts/feature-cli-contract.md: load catalogue + personal file; effective-team resolution with `confirmation_required` / proceed-stop outputs; ticket-before-naming; non-blocking fallback; canonical JSON output (`team`, `ticket{key,number,action}`, `branch_name`, `short_name`, `override_used`, `warnings`); `--json`, `--dry-run`, `--use-team` (depends on T053–T060)
- [ ] T062 [US3] Create twin scripts/powershell/commands/Feature.psm1 implementing `Invoke-JiraFeature` (makes T044/T045 pass)
- [ ] T063 [US3] Register the `feature` subcommand in the dispatcher scripts/bash/lib/cli.sh
- [ ] T064 [US3] Twin the dispatch entry in scripts/powershell/lib/Cli.psm1
- [ ] T065 [US3] Add the gitignore effect to scripts/bash/commands/config.sh: verify/append `.specify/jira/personal.yml` coverage idempotently alongside the existing `config.local.yml`/`.env` lines, report `created|written|unchanged|skipped` as its own effect, covered by `--dry-run`
- [ ] T066 [US3] Twin the gitignore effect in scripts/powershell/commands/Config.psm1 (makes T048/T049 pass)
- [ ] T067 [US3] Register `before_specify` → `speckit.jira.feature` (`enabled: true`, `optional: true`) in scripts/bash/hooks/register_hooks.sh using the existing set-not-append merge with disabled-stays-disabled
- [ ] T068 [US3] Twin the registration in scripts/powershell/hooks/RegisterHooks.psm1 (makes T046/T047 pass)
- [ ] T069 [P] [US3] Create templates/personal.yml.template (commented `team:` + optional `override:` example) and document the `teams:` catalogue with commented examples in templates/config.yml.template
- [ ] T070 [P] [US3] Create agent command definition commands/speckit.jira.feature.md: ordered ceremony — run the deterministic command, ask only its closed questions (`confirmation_required` ⇒ `--use-team` or stop), `{active:false}` ⇒ proceed exactly as today, otherwise drive `create-new-feature.sh --short-name "<short_name>"`, create/switch to `branch_name`, report `override_used` and the ticket action
- [ ] T071 [US3] Declare `speckit.jira.feature` in extension.yml's provided commands so installation mirrors the new command file

### Remediation additions (speckit-analyze A1/A3 — depend on T053/T054)

- [ ] T077 [P] [US2] Failing bats suite tests/bash/commands/test_config_team_mismatch.bats: connected run with a `teams:` catalogue whose team project is not in project/search ⇒ exactly one warning naming the team id and project key, counts.warnings incremented, exit 0, binding written; all teams accessible ⇒ zero warnings; no project/search call when no catalogue is declared (FR-009)
- [ ] T078 [P] [US2] Pester twin tests/powershell/commands/Config.TeamMismatch.Tests.ps1
- [ ] T079 [US2] Implement connected-run mismatch surfacing in scripts/bash/commands/config.sh (after key binding, before the summary; reuses discovery_list_projects) per contracts/config-cli-contract.md
- [ ] T080 [US2] Twin the mismatch surfacing in scripts/powershell/commands/Config.psm1 (makes T077/T078 pass)
- [ ] T081 [P] [US3] Failing bats suite tests/bash/engine/test_routing_team.bats: a folder `003-ijt-invoice-export` with catalogue teams ijt/wex routes to IJT with no explicit rule; an explicit routing rule still wins; no catalogue ⇒ behaviour unchanged (US3 scenario 6, data-model §4)
- [ ] T082 [P] [US3] Pester twin tests/powershell/engine/Routing.Team.Tests.ps1
- [ ] T083 [US3] Add the implicit team→project fallback to the routing resolution (catalogue passed as opaque data — the engine keeps zero Jira knowledge)
- [ ] T084 [US3] Twin the fallback in the PowerShell routing module (makes T081/T082 pass)

**Checkpoint**: All three user stories independently functional — no-selection path byte-for-byte identical to today

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T072 [P] Add the CHANGELOG.md entry and MINOR SemVer bump in extension.yml (Constitution XII)
- [ ] T073 [P] Lint gates clean: `shellcheck scripts/bash/**/*.sh` and PSScriptAnalyzer over scripts/powershell/ with zero new findings
- [ ] T074 Run the full conformance suite (`tests/conformance/run-scenario.sh` over every scenario, new and existing) asserting byte-identical stdout, exit codes, call sequences, and written files across both ports — including SC-004 byte-identical re-run of an unchanged project
- [ ] T075 Verify statement coverage ≥ 80% on both ports (kcov for bats, Pester CodeCoverage) and close any gap with targeted unit tests
- [ ] T076 Walk through specs/002-config-discovery-team-prefix/quickstart.md scenarios 1–7 end-to-end against the mock server and record the results

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies
- **Foundational (Phase 2)**: Independent of Phase 1; blocks every conformance-scenario task (T009–T011, T026–T028, T050–T052)
- **US1 (Phase 3)**: Unit tests (T005–T008) can start immediately; conformance tasks need T001/T003
- **US2 (Phase 4)**: Needs T003 (project/search mock); shares scripts/bash/commands/config.sh with US1 — start T033/T034 after T016/T017 when running stories sequentially
- **US3 (Phase 5)**: Needs T002/T004; gitignore-effect tasks (T065/T066) touch the same config.sh/Config.psm1 files as US1/US2 tasks — sequence within each file
- **Polish (Phase 6)**: After all desired stories

### Within Each User Story

- Test tasks MUST be written and observed FAILING before their implementation tasks (Constitution XIII); T005/T006 and T025 are regression tests that must fail against the current code
- Bash and PowerShell twins of the same behaviour are separate files and can proceed in parallel, but a task is only "done" when both ports pass the shared conformance scenario
- Within US3: lib validation (T053–T056) before the feature command (T061/T062); engine (T057/T058) and sink (T059/T060) are mutually parallel; dispatcher (T063/T064) after the command exists

### Cross-file conflict warning

`scripts/bash/commands/config.sh` / `scripts/powershell/commands/Config.psm1` are modified by US1 (T016/T017), US2 (T033/T034), and US3 (T065/T066) — never run these concurrently; priority order is the safe sequence.

---

## Parallel Example: User Story 1

```bash
# All US1 test tasks in parallel (different files):
Task: T005 tests/bash/sink/test_discovery_ambiguous.bats
Task: T006 tests/powershell/sink/Discovery.Ambiguous.Tests.ps1
Task: T007 tests/bash/commands/test_config_style.bats
Task: T008 tests/powershell/commands/Config.Style.Tests.ps1
Task: T009 tests/conformance/scenarios/us1-style-ambiguous-refusal.json
Task: T010 tests/conformance/scenarios/us1-style-operator-answer.json

# Then the twin sink fixes in parallel:
Task: T012 scripts/bash/sink/jira/discovery.sh
Task: T013 scripts/powershell/sink/jira/Discovery.psm1
```

## Parallel Example: User Story 3

```bash
# Engine and sink pairs are independent of each other:
Task: T057 scripts/bash/engine/naming.sh
Task: T058 scripts/powershell/engine/Naming.psm1
Task: T059 scripts/bash/sink/jira/ticket.sh
Task: T060 scripts/powershell/sink/jira/Ticket.psm1
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 (T001) + Phase 2 (T003) as needed by US1 scenarios
2. Phase 3 complete: failing regressions T005/T006 first, then the twin fixes
3. **STOP and VALIDATE**: us1/us2 conformance scenarios byte-identical across ports — the reported style defect is fixed and shippable

### Incremental Delivery

1. US1 → the silent-default defect is gone (MVP)
2. US2 → git state eliminated as a key source; degraded mode loud and write-free
3. US3 → team conventions and ticket-first naming, opt-in, zero change for non-selecting developers
4. Polish → gates, coverage, CHANGELOG, release prep

Each story leaves both ports green and every persisted byte identical, so any prefix of the phases is releasable.

---

## Notes

- Total: **84 tasks** (Setup 2 · Foundational 2 · US1 14 · US2 21 · US3 40 · Polish 5) — T077–T084 added by the speckit-analyze remediation (FR-009 mismatch surfacing, implicit team route)
- [P] = different files, no incomplete-task dependency
- Exit codes are reused, never extended: 1 usage · 2 fail-closed read · 3 auth · 4 config refusal · 9 privacy BLOCK (research §8)
- Commit after each task or twin pair; keep the failing-test commit separate from the fix commit for the two regression suites (T005/T006, T025)
