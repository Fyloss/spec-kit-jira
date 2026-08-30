---
description: "Task list for 033 — The routing fallback follows the developer's team"
---

# Tasks: The routing fallback follows the developer's team

**Input**: Design documents from `/specs/033-routing-follows-team/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/routing-resolution.md

**Tests**: REQUIRED. Constitution XIII mandates TDD, and FR-012 makes cross-port byte equivalence part of the requirement — so for anything with an operator-visible output the failing-test-first artifact is a **conformance scenario**, not a per-port unit test. Per-port suites cover what the corpus structurally cannot reach (a pure function's parameter contract, a schema rule, a process count).

**Organization**: grouped by user story. Phase 2 blocks every story; the three stories are otherwise independent of one another.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 / US2 / US3, mapping to spec.md
- Tasks cite contract clauses (C1.1 … C7.3) from `contracts/routing-resolution.md`

**Revision 2026-08-30** — `/speckit-analyze` found one CRITICAL and three HIGH gaps; this list is the corrected one. The corpus turned out to contain **no** scenario exercising routing resolution at all: `us8-mixed-routing.json` runs the `config` command against a multi-project fixture, and `us027-refuse-routing.json` runs `feature` about a REF-ROUTING refusal. Neither resolves a rank. The previous T053 discharged C7.2 by citing them.

---

## Phase 1: Setup — shared fixtures

- [X] T001 [P] Build the two-team conformance fixture repository under `tests/conformance/fixtures/us033-multi-team/`: `config.yml` declaring projects ALPHA and BETA, one `routing:` rule on `billing-`, and a `teams:` catalogue with `alpha`/`beta` entries, per quickstart.md §1
- [X] T002 [P] Build the three `personal.yml` fixture variants under `tests/conformance/fixtures/us033-multi-team/`: selecting `beta`, selecting `alpha`, and present-but-selecting-no-team (the absent-file case is recorded in the scenario rather than as a fixture)
- [X] T003 [P] Build the specification-folder fixtures under `tests/conformance/fixtures/us033-multi-team/specs/`: unbound, bound (`ticket=ALPHA-88`), in-flight (`creating`), bare-assigned, one matching the `billing-` rule, and one carrying the `alpha-` team folder prefix

---

## Phase 2: Foundational — the regression net (BLOCKS every story)

**Purpose**: pin the pre-change behaviour before touching resolution, so FR-009 is verified rather than asserted. C1.4 is the clause that makes the whole feature safe for existing repositories, and it can only be proven against a baseline captured first.

- [X] T004 Add conformance scenario `us033-legacy-shape` — a repository declaring `routing_default`, **no** `teams:`, and **no** `personal.yml` — and prove it GREEN against the unmodified tree before any task below runs. This is also rank 4's conformance witness (C1.4, C7.2, FR-009)
- [X] T005 Record the pre-change resolution of every existing routing scenario in the corpus as the comparison baseline for T068; no scenario may change its resolved key by the end of this feature

**Checkpoint**: the baseline is captured and green. Stories may begin.

---

## Phase 3: User Story 1 — the developer mirrors into their own project (Priority: P1) 🎯 MVP

**Goal**: a specification matching no committed rule and carrying no team folder prefix resolves to the project of the team the operator selected, and only when nothing is bound yet.

**Independent test**: the §1 fixture with `team: beta` and the unbound spec folder resolves to BETA; with `team: alpha` it resolves to ALPHA; with the bound spec folder it resolves to ALPHA whichever team is selected.

> Phase 4 (US2) may be executed before this phase — see Implementation strategy.

### Per-port tests first (these MUST fail before Phase 3 implementation)

- [X] T006 [P] [US1] Failing bats for the boundness predicate in `tests/bash/engine/test_story_marker_bound.bats` — the ticket-bearing form counts, `creating` / bare / absent do not (C3.3)
- [X] T007 [P] [US1] Failing Pester twin in `tests/powershell/engine/StoryMarker.Bound.Tests.ps1`
- [X] T008 [P] [US1] Failing bats for rank 3 in `tests/bash/engine/test_interchange_routing_rank3.bats` — team id supplied, nothing else matches, resolves to that team's `project` (C2.1)
- [X] T009 [P] [US1] Failing Pester twin in `tests/powershell/engine/Interchange.Routing.Tests.ps1`
- [X] T010 [P] [US1] Failing bats for rank precedence in `tests/bash/engine/test_interchange_routing_precedence.bats` — a committed rule and a committed team route each beat the personal selection (C2.5)
- [X] T011 [P] [US1] Failing Pester twin
- [X] T012 [P] [US1] Failing bats for C1.4 in `tests/bash/engine/test_interchange_routing_empty_team.bats` — an empty fourth input reproduces the three-input resolver byte for byte, across rule/team/default/refusal
- [X] T013 [P] [US1] Failing Pester twin
- [X] T014 [P] [US1] Failing spawn-count bats in `tests/bash/engine/test_interchange_routing_spawn_budget.bats`. Source the helper itself — `tests/bash/helpers/spawn_count.bash`, entry point `helper_spawn_count_setup <shim_dir> <count_file>`, under `contracts/spawn-budget.md §4 C4.1` — **not** `tests/bash/ci/test_spawn_count_helper.bats`, which is the guard *for* that helper. Follow the shape of the two existing budget tests, `tests/bash/engine/test_parse_spawn_budget.bats` and `tests/bash/sink/test_plan_apply_spawn_budget.bats`. Resolution against a 2-team catalogue and a 50-team catalogue MUST cost the identical number of external processes, and that number MUST be 1 (C1.3). **Bash only, deliberately**: the counting harness exists in no other port (`tests/powershell/helpers/` holds CallsLog, SecretStoreStub and SeedFixture, and nothing equivalent), so C7.1's byte-equivalence obligation does not reach it — a missing Pester twin here is the design, not an omission. *Analyze finding E4: `docs/11-process-budget.md` records this defect class being reintroduced three times; the guard is cheap and the original omission was not deliberate.*
- [X] T015 [P] [US1] Failing bats in `tests/bash/commands/test_reconcile_rank3_unknown_project.bats` — a catalogue team whose `project` is absent from `projects[]`, reached through rank 3, refuses with the **unknown-project** message of `reconcile.sh:759`, not with the routing refusal (spec Edge Cases §1). *Analyze finding E3.*
- [X] T016 [P] [US1] Failing Pester twin of T015

### Conformance scenarios first (C7.2 — one per rank, all currently absent from the corpus)

- [X] T017 [US1] Failing conformance scenario `us033-rule-route` — the `billing-` spec folder with `team: beta` selected resolves to ALPHA. **Rank 1's witness, and the byte-compared proof of C2.5.** *Analyze finding E1: no such scenario exists today.*
- [X] T018 [US1] Failing conformance scenario `us033-team-route` — the `alpha-` prefixed spec folder with `team: beta` selected resolves to ALPHA. **Rank 2's witness, and the second half of C2.5.** *Analyze finding E1.*
- [X] T019 [US1] Failing conformance scenario `us033-personal-route-beta` — the unbound spec, `team: beta`, resolves to BETA. Rank 3's witness
- [X] T020 [US1] Failing conformance scenario `us033-personal-route-alpha` — the **same** unbound spec, `team: alpha`, resolves to ALPHA. Without this, a resolver that always returned the first catalogue entry would pass every other task, and SC-001 would be half-proven. *Analyze finding E2.*
- [X] T021 [US1] Failing conformance scenario `us033-bound-ignores-personal` — the bound spec resolves to ALPHA under `team: beta` AND under `team: alpha`, proving C3.5 with two runs
- [X] T022 [US1] Failing conformance scenario `us033-rank3-unknown-project` — the byte-compared twin of T015/T016. *Analyze finding E3.*

### Implementation

- [X] T023 [US1] Implement the fork-free bound predicate in `scripts/bash/engine/story_marker.sh`, recognising only the `ticket=` form of line 80; no process per line, per story, or per marker (C3.4), and no `$'\r\n'` inside a glob (C7.3)
- [X] T024 [P] [US1] Twin in `scripts/powershell/engine/StoryMarker.psm1`
- [X] T025 [US1] Add the fourth parameter to `routing_resolve` in `scripts/bash/engine/interchange.sh` and fold the rank-3 lookup into the existing single `jq` program between the team route and the default (C1.1, C1.3, C2.1); the function opens no file (C1.2)
- [X] T026 [P] [US1] Twin `Resolve-JiraRouting` in `scripts/powershell/engine/Interchange.psm1`
- [X] T027 [US1] Expose the personal-load result from `config_resolve_connection` in `scripts/bash/lib/config.sh` through a module-scoped variable, on the `_CFG_PIN_STATUS` precedent — no second `config_personal_load` call (research R4)
- [X] T028 [P] [US1] Twin in `scripts/powershell/lib/Config.psm1`
- [X] T029 [US1] In `scripts/bash/commands/reconcile.sh`, move the raw specification read from line 891 to ahead of the routing block, evaluate boundness once from that text, and supply the fourth argument gated on it (C3.1, C3.2)
- [X] T030 [P] [US1] Twin in `scripts/powershell/commands/Reconcile.psm1` (read currently at line 1024, routing at 861)

### Pinning what already holds

- [X] T031 [P] [US1] Regression bats in `tests/bash/commands/test_reconcile_personal_malformed.bats` proving C4.3 — a present-but-malformed `personal.yml` refuses with exit 4 **before** routing resolves and with zero writes. This behaviour already exists (`config.sh:1836`); the test exists so a future refactor cannot silently remove it
- [X] T032 [P] [US1] Pester twin
- [X] T033 [P] [US1] Regression bats proving C4.4 — an absent `personal.yml`, and one selecting no team, both fall through silently with no warning and no diagnostic
- [X] T034 [P] [US1] Per-port unit case for C4.2 — an id that passes catalogue validation but matches no entry at resolution time yields rank 3 nothing and falls to rank 4. Unreachable through the supported path; no conformance scenario is warranted

**Checkpoint**: US1 is independently demonstrable and shippable.

---

## Phase 4: User Story 2 — a repository can decline to name a shared default (Priority: P2)

**Goal**: `routing_default` becomes optional in the committed schema without becoming permissive.

**Independent test**: a `config.yml` with no `routing_default` validates; one with a malformed `routing_default` still refuses with today's message.

- [X] T035 [P] [US2] Failing bats in `tests/bash/lib/test_config_routing_default_optional.bats` — a configuration omitting `routing_default` validates (C5.1)
- [X] T036 [P] [US2] Failing Pester twin in `tests/powershell/lib/Config.RoutingDefaultOptional.Tests.ps1`
- [X] T037 [P] [US2] Failing bats — `routing_default: lower` still refuses with the message it produces today, unchanged (C5.2)
- [X] T038 [P] [US2] Failing Pester twin
- [X] T039 [P] [US2] Failing bats — `routing_default` remains a legal top-level key and is not reported as unknown (C5.3)
- [X] T040 [US2] Drop the presence half of the rule at `scripts/bash/lib/config.sh:875`, keep the shape half, and leave the allowed-key list at line 877 untouched
- [X] T041 [P] [US2] Twin at `scripts/powershell/lib/Config.psm1:767`, leaving the allowed list at 772 untouched
- [X] T042 [US2] Conformance scenario `us033-no-routing-default` — a repository omitting the key loads and routes through the catalogue. Note this witnesses the *schema relaxation*, not a rank; rank 4's witness is T004

**Checkpoint**: US2 is independently shippable and touches nothing US1 or US3 own.

---

## Phase 5: User Story 3 — a refusal names which state produced it (Priority: P3)

**Goal**: when all four ranks yield nothing, the operator is told what each rank found rather than which single key is missing.

**Independent test**: construct a repository in each distinguishable refusal state and confirm each message names that state and no other.

- [X] T043 [P] [US3] Failing bats in `tests/bash/commands/test_reconcile_routing_refusal.bats` — the message reports all four rank findings, not only the last (C6.2)
- [X] T044 [P] [US3] Failing Pester twin
- [X] T045 [P] [US3] Failing bats for the three rank-3 states of C6.3 — no `personal.yml`; a file selecting no team; rank 3 not consulted because the specification is already bound — each named distinctly
- [X] T046 [P] [US3] Failing Pester twin
- [X] T047 [P] [US3] Failing bats proving C6.5 — the message does not prescribe declaring `routing_default` as the sole remedy
- [X] T048 [US3] Replace the refusal at `scripts/bash/commands/reconcile.sh:737` with the four-finding message (C6.1–C6.5)
- [X] T049 [P] [US3] Twin at `scripts/powershell/commands/Reconcile.psm1:863`
- [X] T050 [US3] Conformance scenarios `us033-refuse-no-selection`, `us033-refuse-no-team-key`, `us033-refuse-bound-skip` — one per C6.3 state, byte-compared across ports (C7.2)
- [X] T051 [US3] Verify the new message's command literals are covered by `tests/bash/ci/test_message_command_literals.bats` and its Pester twin, extending the check's input set if the message introduces a literal it does not yet see (C6.4)

**Checkpoint**: every refusal state is diagnosable and byte-identical across ports.

---

## Phase 6: Polish & cross-cutting concerns

### Documentation and surface

- [X] T052 [P] `templates/config.yml.template` — present `routing_default` as optional and state at the key that a developer's selected team takes precedence over it (FR-010)
- [X] T053 [P] `templates/personal.yml.template` — state at the `team:` key that it now governs routing as well as naming (FR-010)
- [X] T054 [P] `docs/07-configuration-and-secrets.md` — document the four-rank chain including rank 3's bound-marker precondition, and update the `routing + routing_default` node of the diagram at line 13 (FR-011)
- [X] T055 [P] `docs/06-feature-naming.md` — the document that describes `personal.yml`'s `team:` key. It mentions the key six times and routing zero times, so after this feature it states something that is no longer the whole truth: the key governs naming **and** routing rank 3 (FR-011)
- [X] T056 [P] Sweep `README.md`, `docs/04-config-ceremony.md` and `docs/05-reconcile-flow.md` for statements the four-rank chain contradicts. A document that states the old three-rank behaviour is a defect this feature introduces, not a pre-existing one
- [X] T057 [P] CHANGELOG entry and the version bump in `extension.yml` (`extension.version` is the single source of truth; the literal appears nowhere else but CHANGELOG.md)

### Constitutional obligations that belong to no user story

**Swept explicitly.** These are properties of the whole feature, so no story generates them.

- [X] T058 **The fail-closed departure (Principle III).** This feature adds a NEW refusal branch (C6.1). Test that in hook context it downgrades to a single actionable warning and returns success to the host command — the changed branch, not the unchanged one, in `tests/bash/hooks/` and its Pester twin
- [X] T059 **Principle IV.** Assert the routing refusal and the rank-3 path never emit any content of `personal.yml` beyond the selected team id — that file also holds the operator's email, and the new message is the first one to reason about its contents
- [X] T060 **Per-class conformance (C7.2).** Confirm the corpus contains one scenario per rank — rank 1 → T017, rank 2 → T018, rank 3 → T019/T020, rank 4 → T004 — plus one per C6.3 refusal state (T050), C1.4 (T004), C3.5 (T021), and the unknown-project path (T022). **Verify each named scenario exists and runs the `reconcile` command**; the previous revision of this task discharged the clause against two scenarios that run other commands entirely

> **Principle IX — not applicable.** This feature writes no content into any tracked file; the privacy guard gains no surface. Recorded here rather than dropped, because a silently omitted obligation is indistinguishable from a forgotten one.
>
> **Principle II live zero-churn — not applicable.** No new write kind reaches the sink interface, so `tests/live/test_live_zero_churn.bats` needs no extension. Same reasoning.

### Guards and gates

- [X] T061 Reconcile the corpus scenario count at `tests/bash/ci/test_conformance_no_cross_os_shard.bats:18` — currently pinned at 243; this feature adds **eleven** scenarios, so the literal becomes 254. The guard is legitimately red from T004 until this task
- [X] T062 `git add -f` every new fixture under `tests/conformance/fixtures/us033-multi-team/` and prove `tests/bash/ci/test_fixtures_are_tracked.bats` green. Run it from a clean tree — a local sink run reddens this guard for unrelated reasons
- [X] T063 Prove each new guard RED against the pre-change file retrieved from git before accepting it. A guard that was never seen to fail has not been shown to guard anything
- [X] T064 `shellcheck -x -P scripts/bash` over `scripts/bash`, `actionlint`, and PSScriptAnalyzer — all clean

### Verification

- [X] T065 `tests/run-bash.sh` full suite, 0 failures
- [X] T066 `bash tests/conformance/ci-conformance.sh` — exit 0 and **zero** lines containing `conformance divergence`. Success is silent; there is no pass banner, and the temp paths are harness noise. Never run this concurrently with the bash suite
- [X] T067 Full Pester run
- [X] T068 Compare every pre-existing routing scenario against the T005 baseline; any resolved key that changed is a FR-009 violation and blocks the feature
- [X] T069 Push `ci/windows-probe` and read the annotations (~11 min). C7.3's CRLF tolerance in the boundness scan is the clause most likely to diverge, and a Windows divergence is diagnosed by measurement on the runner, never by emulation. One retry maximum on a flake

---

## Dependencies

**Phase order**: Setup (T001–T003) → Foundational (T004–T005) → stories → Polish.

**Foundational blocks everything.** T004/T005 capture the pre-change behaviour; capturing it after a change proves nothing.

**Story independence**:

- **US2 (Phase 4) is fully independent** — two schema rules and their tests. It could ship alone, before or after US1.
- **US1 (Phase 3) is the MVP** and depends only on Foundational.
- **US3 (Phase 5) depends on US1**: the four-finding message can only report on four ranks once the third exists.

**Within US1**: T023/T024 (predicate), T025/T026 (resolver) and T027/T028 (exposing the personal load) are mutually independent and all precede T029/T030 (the wiring that consumes them). Every test task T006–T022 precedes its implementation.

**Cross-port pairs** are always parallel with each other and never with their own port's dependency chain.

## Parallel execution examples

**Setup**: T001, T002, T003 together — three disjoint fixture trees.

**US1 per-port tests**: T006–T016 together — eleven files, no shared state, all expected red.

**US1 conformance**: T017–T022 are written in parallel but share the corpus count guard, which stays red until T061.

**US1 implementation**: three independent chains, `(T023 → T024)`, `(T025 → T026)`, `(T027 → T028)`, converging on T029/T030.

**Polish documentation**: T052–T057 together — six disjoint files.

**Never parallel**: T065 and T066. The bash suite and the conformance corpus share fixtures, and running them together invents an `Only in …: state` divergence in an unrelated scenario.

## Implementation strategy

**MVP = Phase 1 + Phase 2 + Phase 3 (US1).** That alone closes the reported defect: a developer in a multi-team repository stops mirroring into another team's project. Everything after it is refinement.

**Recommended order**: Foundational → **US2** → US1 → US3. US2 is placed before US1 despite its lower priority because it is two rules and their tests, it is the only story that can regress an existing repository's *loading* (as opposed to its routing), and getting it green early means every subsequent conformance run exercises both the with-key and without-key shapes. The phase numbering follows story priority, not this order — see the note in the Phase 3 header.

**The task to scrutinise hardest is T029/T030** — moving the specification read ahead of routing. It is the only change in this feature that reorders an existing command, and its safety rests on a measured claim: nothing between the two points writes the specification. Verify that claim against the tree before making the move, not after.

**Do not mark a conformance task done without running it.** Four of this list's six conformance scenarios for US1 exist because the previous revision assumed coverage that measurement disproved.

---

## Phase 7: Convergence

Appended by `/speckit-converge` on 2026-08-30, after the implementation passed
its own gates. Every finding is a document that still describes the behaviour
this feature replaced — no code gap was found, and nothing unrequested was
built.

- [X] T070 Make `routing_default` optional in `specs/001-jira-reconcile-engine/contracts/config.schema.json` — remove it from the top-level `"required"` array at line 8 while keeping its `projectKey` shape at line 39, so the published contract stops stating the opposite of the shipped validator, per FR-003 / C5.1 / C5.3 (contradicts)
- [X] T071 Replace the `routing-unresolved` remedy in `specs/004-reconcile-config-resolution/contracts/resolution-contract.md:77` — it prescribes "Add `routing_default`", the single prescription C6.5 forbids; state instead that the refusal reports what each of the four ranks found, per FR-007 / C6.5 (contradicts)
- [X] T072 Complete `README.md:405-425` where `personal.yml`'s `team:` key is introduced: it now governs routing rank 3 as well as naming, and the routing half applies only while the specification is unbound. The statement there is incomplete rather than false, which is why the T056 contradiction sweep did not catch it, per FR-011 (partial)
- [X] T073 Name the affected population in the `CHANGELOG.md` 0.23.0 entry: a repository that already declares a `teams:` catalogue AND whose developers select teams will see an unbound specification that previously fell to `routing_default` route to the selecting developer's project instead; already-bound specifications do not move, per plan Constitution XII row (partial)
- [X] T074 Add a ninth row to the "eight distinguished causes" table in `commands/speckit.jira-mirror.reconcile.md:91` for a routing refusal — it exits 4 exactly as the credentials row does, and 033 makes the state reachable by design now that a repository may legitimately declare no `routing_default`, per C6.1 (partial)
