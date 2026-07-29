---

description: "Task list for feature 004 — Reconcile Resolves Its Own Routing and Plan Context From Config"
---

# Tasks: Reconcile Resolves Its Own Routing and Plan Context From Config

**Input**: Design documents from `/specs/004-reconcile-config-resolution/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: **MANDATORY, not optional.** Constitution XIII requires strict Red-Green-Refactor and states that *"no implementation task may be planned without its test task preceding it in `tasks.md`"*. The repository's bug-fix policy additionally requires a regression test that fails before the fix. Every implementation task below is therefore preceded by its test task, and every test task must be **observed failing** before its implementation begins.

**Ports**: Constitution VI makes a Bash-only fix a violation. Every behaviour lands in **both** ports — `scripts/bash/` and `scripts/powershell/` — and the conformance suite proves they agree.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Every task names its exact file path

## Path Conventions

- Bash port: `scripts/bash/`, tests in `tests/bash/`
- PowerShell port: `scripts/powershell/`, tests in `tests/powershell/`
- Cross-port golden scenarios: `tests/conformance/scenarios/`, fixtures in `tests/conformance/fixtures/` and `tests/conformance/mock-jira/fixtures/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Close the one open research item and build the fixtures every story tests against

- [X] T001 Close the R8 verification item — confirm against current Atlassian documentation (or one `GET /rest/api/3/issue/createmeta/{key}/issuetypes/{typeId}` call against a real team-managed project) that `fields.project` is required for creation in both project styles; record the outcome and its source in `specs/004-reconcile-config-resolution/research.md`
- [X] T002 [P] Create the bound-repository fixture at `tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira/config.yml` (one company-managed project, one `routing[]` rule with `folder_prefix`, a `routing_default`, and a `priority_map`) and `.../config.local.yml` (a `resolved_ids` entry with `issue_types`, `priorities` and `style`)
- [X] T003 [P] Give each of the three research-R4 branches its own createmeta fixture, without perturbing either existing one: leave `tests/conformance/mock-jira/fixtures/createmeta-fields-company.json` unchanged as branch 3 (`priority` present, no `allowedValues` — the site-wide-catalogue fallback), leave `.../createmeta-fields-team.json` unchanged as branch 1 (no `priority` field at all), and add `.../createmeta-fields-company-allowed.json` as branch 2 (`priority` present with an `allowedValues` array). Keeping the two existing fixtures byte-identical is what stops `test_discovery_company.bats` and the `us2-company-managed-discovery` capture from churning.
- [X] T003a [P] Make the new branch-2 fixture reachable from the mock without touching style detection: add an optional `createmetaFields` key to the mock config format, consulted only by the `createmeta/{key}/issuetypes/{typeId}` route in `tests/conformance/mock-jira/mock-server.ps1:159` (which today derives the fixture name from `Get-MetaStyle`, a function that knows only `company` and `team`), and add `tests/conformance/mock-jira/configs/priority-allowed.json` setting it to `company-allowed`. `Get-Style`, `Get-MetaStyle`, the `project-$style` route and every existing config stay untouched.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The shared creation-fields builder of research R3. Both P1 stories write into it, so it must exist first.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T004 [P] Write the failing test for the shared base builder in `tests/bash/sink/test_ticket.bats` — assert `jira_create_fields_base` returns exactly `{project:{key},issuetype:{id},summary}` and that `_ticket_create_body` is built from it; observe FAIL
- [X] T005 [P] Write the mirrored failing test in `tests/powershell/sink/Ticket.Tests.ps1` for `New-JiraCreateFieldsBase`; observe FAIL
- [X] T006 Implement `jira_create_fields_base <project> <summary> <issue-type-id>` in `scripts/bash/sink/jira/ticket.sh` and rewire `_ticket_create_body` to wrap it, leaving its output byte-identical
- [X] T007 [P] Implement `New-JiraCreateFieldsBase` in `scripts/powershell/sink/jira/Ticket.psm1` and rewire the existing create-body builder the same way
- [X] T008 Source `ticket.sh` from `scripts/bash/sink/jira/plan_apply.sh` and import `Ticket.psm1` from `scripts/powershell/sink/jira/PlanApply.psm1`, verifying the `_JIRA_SINK_*` re-entry sentinels prevent double-sourcing and that no cycle is introduced

**Checkpoint**: One builder owns the mandatory attribute set. Both P1 stories can now proceed.

---

## Phase 3: User Story 1 - A bound repository mirrors to the right project without any environment setup (Priority: P1) 🎯 MVP

**Goal**: The mirror resolves its target project from `config.yml` alone, and that project reaches the creation payload.

**Independent Test**: With no extension environment variables set, run the mirror on a spec folder in the fixture repository and confirm every planned creation names the configured project — and that `PROJ` appears nowhere.

### Tests for User Story 1 ⚠️

> Write these FIRST and observe them FAIL before any implementation task in this phase.

- [X] T009 [P] [US1] Write failing routing-resolution tests in `tests/bash/commands/test_reconcile_routing.bats` — folder-prefix rule match, `routing_default` fallback, no-rule-no-default refusal, placeholder-key refusal, explicit environment override wins, and epic strategy taken from the resolved project
- [X] T010 [P] [US1] Write the failing payload test in `tests/bash/sink/test_plan_apply_project.bats` — every `POST …/issue` body carries a non-empty `fields.project.key` equal to the document's `routing.project_key`, and assembly returns non-zero when it is empty
- [X] T011 [P] [US1] Write the mirrored routing tests in `tests/powershell/commands/Reconcile.Routing.Tests.ps1`; observe FAIL
- [X] T012 [P] [US1] Write the mirrored payload tests in `tests/powershell/sink/PlanApply.Project.Tests.ps1`; observe FAIL

### Implementation for User Story 1

- [X] T013 [US1] Add `_reconcile_resolve_routing` to `scripts/bash/commands/reconcile.sh` — call `config_load`, derive the spec folder basename, call `routing_resolve`, and return the resolved key; delete the `PROJ` fallback at the `project_key` assignment
- [X] T014 [US1] Refuse an absent, syntactically invalid, or placeholder key in `scripts/bash/commands/reconcile.sh` using the existing `config_key_is_placeholder`, returning through `_reconcile_fault` so zero writes occur
- [X] T014a [US1] Call `config_load` lazily in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` — only when a value is not supplied by an explicit override — and map a missing `config.yml` to the existing not-configured notice (exit 0, zero writes) while leaving a present-but-invalid one on `config_load`'s `EXIT_CONFIG` path
- [X] T014b [US1] Migrate the existing reconcile suites off the placeholder key: replace `SPEC_KIT_JIRA_PROJECT_KEY='PROJ'` with a real key in `tests/bash/commands/test_reconcile.bats:18`, `tests/powershell/commands/Reconcile.Tests.ps1:11` and the inline `pwsh` invocations at `test_reconcile.bats:77` and `:93`, and add one case per port asserting that an override equal to the placeholder is now refused with zero writes (FR-005)
- [X] T015 [US1] Resolve the run's epic strategy from the resolved project's `epic_strategy` in `scripts/bash/commands/reconcile.sh`, replacing the built-in `per_repo` default
- [X] T016 [US1] Build the creation payload from `jira_create_fields_base` in `scripts/bash/sink/jira/plan_apply.sh`, taking the project from `$doc.routing.project_key` (research R2) so no plan-context field is added
- [X] T017 [US1] Add the assembly guard to `plan_writes` in `scripts/bash/sink/jira/plan_apply.sh` — return non-zero before emitting any creation whose project or issue type is empty
- [X] T018 [P] [US1] Implement routing resolution, placeholder refusal and epic strategy in `scripts/powershell/commands/Reconcile.psm1`
- [X] T019 [P] [US1] Implement the payload project and the assembly guard in `scripts/powershell/sink/jira/PlanApply.psm1`
- [X] T020 [US1] Add the golden scenario `tests/conformance/scenarios/us8-reconcile-company-managed.json` using the T002 fixture, and confirm both ports produce byte-identical stdout, exit code, call log and tree
- [X] T021 [US1] Run quickstart Steps 1 and 2 in `specs/004-reconcile-config-resolution/quickstart.md` and confirm `fields_present` now includes `project` and the resolved key is the fixture's, never `PROJ`

**Checkpoint**: The mirror reaches the right project and says so in the payload. The reported symptom's first half is gone.

---

## Phase 4: User Story 2 - Created work items carry the issue type and priority the binding already discovered (Priority: P1)

**Goal**: The creation context builds itself from the persisted binding for the resolved project — no manual injection.

**Independent Test**: With no plan-context environment variable set, run the mirror in prediction mode against the bound fixture and confirm each creation declares the binding's issue type and the two-step-resolved priority.

### Tests for User Story 2 ⚠️

- [X] T022 [P] [US2] Write failing creation-context tests in `tests/bash/commands/test_reconcile_plan_context.bats` — issue type from `resolved_ids.<KEY>.issue_types.Story`, priority through `priority_map` then `resolved_ids.priorities`, estimation on create only, machine layer beating the committed layer, explicit plan-context override winning, and the project-not-bound refusal
- [X] T023 [P] [US2] Write the mirrored tests in `tests/powershell/commands/Reconcile.PlanContext.Tests.ps1`; observe FAIL

### Implementation for User Story 2

- [X] T024 [US2] Extend `_reconcile_plan_context` in `scripts/bash/commands/reconcile.sh` to build `story_type_id`, `priority_ids` and `estimation_field_id` from the resolved project's `resolved_ids` entry when no explicit override is set
- [X] T025 [US2] Implement the two-step priority resolution in `scripts/bash/commands/reconcile.sh` — `priority_map[<level>]` to a logical name, then `resolved_ids.<KEY>.priorities[<name>]` to an identifier, omitting the level when either step yields nothing
- [X] T026 [US2] Apply the machine-layer-wins precedence and the per-value environment override in `scripts/bash/commands/reconcile.sh`, keeping `base_url` always applied last as today
- [X] T027 [US2] Refuse creations when the resolved project has no `resolved_ids` entry, in `scripts/bash/commands/reconcile.sh`, returning through `_reconcile_fault` with zero writes
- [X] T028 [P] [US2] Implement the creation-context build, the two-step priority resolution and the precedence rules in `scripts/powershell/commands/Reconcile.psm1`
- [X] T029 [P] [US2] Implement the project-not-bound refusal in `scripts/powershell/commands/Reconcile.psm1`
- [X] T030 [US2] Run quickstart Step 3 in `specs/004-reconcile-config-resolution/quickstart.md` and confirm the estimation appears on `POST` bodies and never on `PUT` bodies

**Checkpoint**: A single mirror run now succeeds end to end against a bound repository. The reported defect is fixed.

---

## Phase 5: User Story 3 - A misconfiguration is reported in the operator's language (Priority: P2)

**Goal**: Each incomplete-configuration state produces its own named cause and one remedy, without ever failing the host lifecycle command.

**Independent Test**: Drive each of the four *fault* causes in [contracts/resolution-contract.md](./contracts/resolution-contract.md) in turn and confirm a distinct message, zero writes, exit 4 on direct invocation and exit 0 under a hook. The fifth catalogued cause, `not-configured`, is a notice rather than a fault: it exits 0 in every context and its existing behaviour must be asserted unchanged.

### Tests for User Story 3 ⚠️

- [X] T031 [P] [US3] Write failing diagnostics tests in `tests/bash/commands/test_reconcile_diagnostics.bats` — one case per cause (`routing-unresolved`, `placeholder-binding`, `unknown-project`, `project-not-bound`), each asserting a distinct message, an empty `mock_calls` log (zero requests of any kind, not merely zero writes — FR-019 requires resolution to complete before the first network call), exit 4 direct and exit 0 with exactly one warning under `SPEC_KIT_JIRA_HOOK_CONTEXT`
- [X] T032 [P] [US3] Write the mirrored tests in `tests/powershell/commands/Reconcile.Diagnostics.Tests.ps1`, carrying the same empty-call-log assertion per cause; observe FAIL

### Implementation for User Story 3

- [X] T033 [US3] Emit the `routing-unresolved` and `placeholder-binding` messages from `scripts/bash/commands/reconcile.sh`, each naming the cause and the remedy exactly as the contract specifies
- [X] T034 [US3] Detect and report `unknown-project` — a `routing[]` rule naming a key absent from `projects[]` — in `scripts/bash/commands/reconcile.sh`, naming both the rule and the unknown key
- [X] T035 [US3] Emit the `project-not-bound` message from `scripts/bash/commands/reconcile.sh`, kept distinct from the existing "not configured at all" notice, which retains its exit-0 behaviour
- [X] T036 [P] [US3] Implement all four messages with identical wording in `scripts/powershell/commands/Reconcile.psm1`
- [X] T037 [US3] Add the leak assertion to `tests/bash/commands/test_reconcile_diagnostics.bats` and `tests/powershell/commands/Reconcile.Diagnostics.Tests.ps1` — no diagnostic contains a site host or credential shape, at any verbosity
- [X] T038 [US3] Run quickstart Step 4 in `specs/004-reconcile-config-resolution/quickstart.md` and confirm the leak grep prints nothing

**Checkpoint**: Every misconfiguration is self-service. No lifecycle command can be failed by the mirror.

---

## Phase 6: User Story 4 - A team-managed project mirrors as correctly as a company-managed one (Priority: P2)

**Goal**: Payload contents follow what the resolved project reports it accepts, never a rule keyed on its style; the binding records priorities per project.

**Independent Test**: Plan creations against a company-managed and a team-managed project from one repository; confirm both declare the project, each declares only its own identifiers, and the team-managed one declares no priority.

### Tests for User Story 4 ⚠️

- [X] T039 [P] [US4] Write failing per-project priority tests in `tests/bash/sink/test_discovery_priorities.bats` — all three branches of research R4: priority field absent yields `{}`, present with `allowedValues` yields only those, present without `allowedValues` yields the site-wide catalogue
- [X] T040 [P] [US4] Write the mirrored tests in `tests/powershell/sink/Discovery.Priorities.Tests.ps1`; observe FAIL
- [X] T041 [P] [US4] Write failing dual-style tests in `tests/bash/commands/test_reconcile_styles.bats` — both styles declare a project, no payload carries the other project's issue type, and the team-managed payload declares no priority while the run still succeeds
- [X] T042 [P] [US4] Write the mirrored tests in `tests/powershell/commands/Reconcile.Styles.Tests.ps1`; observe FAIL

### Implementation for User Story 4

- [X] T043 [US4] Derive `priorities` from the resolved project's create metadata in `scripts/bash/sink/jira/discovery.sh`, implementing all three branches of research R4 and keeping the existing `GET /priority` call as the identifier catalogue so the API call sequence is unchanged
- [X] T044 [P] [US4] Implement the same three-branch derivation in `scripts/powershell/sink/jira/Discovery.psm1`
- [X] T044a [US4] Confirm the branch-3 path is a true no-op for existing callers: `tests/bash/sink/test_discovery_company.bats:83-87` (`.priorities | length` and `.priorities[0].logical_name`), its mirror `tests/powershell/sink/Discovery.Company.Tests.ps1`, and the `tests/conformance/scenarios/us2-company-managed-discovery.json` capture must all pass unchanged, since T003 left the company fixture without `allowedValues`. Any diff here means the derivation regressed a site whose create metadata omits `allowedValues`.
- [X] T045 [US4] Create the dual-style fixture at `tests/conformance/fixtures/repo-with-two-styles/.specify/jira/` — one company-managed and one team-managed project, each with its own `resolved_ids` entry and distinct identifiers
- [X] T046 [US4] Add the golden scenario `tests/conformance/scenarios/us8-reconcile-team-managed.json` and confirm byte-identical output across both ports
- [X] T047 [US4] Add the mechanical style-branch check as `tests/bash/ci/test_no_style_branch.bats` and `tests/powershell/ci/NoStyleBranch.Tests.ps1`, following the existing `test_no_registry_write.bats` convention — grep `scripts/bash/sink/jira/plan_apply.sh` and `scripts/powershell/sink/jira/PlanApply.psm1` for `company_managed` and `team_managed` and fail on any match. This is the FR-028 and Principle VII guarantee, enforced in source rather than by review.
- [X] T048 [US4] Run quickstart Step 5 in `specs/004-reconcile-config-resolution/quickstart.md` and confirm the team-managed action set declares no priority

**Checkpoint**: All four stories independently functional. The fix is style-independent by construction.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T049 Run the full port-parity diff of quickstart Step 6 across both new scenarios in `tests/conformance/scenarios/` and confirm every diff is empty
- [X] T050 [P] Run `bats tests/bash/commands tests/bash/sink tests/bash/engine` and `pwsh -c "Invoke-Pester tests/powershell"` and confirm both suites are green
- [ ] T051 [P] Confirm the kcov statement coverage gate stays at or above 80% and that the fail-closed and payload-assembly paths in `scripts/bash/commands/reconcile.sh` and `scripts/bash/sink/jira/plan_apply.sh` are near 100% — **not runnable in this environment**: `tests/coverage/bash-coverage.sh` itself refuses on macOS (`kcov cannot drive a non-Apple bash on macOS`) and requires the Linux CI job. Substitute evidence gathered locally: every new branch in both files is exercised by a dedicated failing-then-passing test (T009–T047), and the full mocked suites are green (597 bats + 505 Pester, 0 failures). Confirm the actual kcov percentage on the next Linux CI run.
- [X] T052 [P] Run `shellcheck` over the changed Bash modules and `PSScriptAnalyzer` over the changed PowerShell modules per `.shellcheckrc` and `PSScriptAnalyzerSettings.psd1`; both must pass clean
- [X] T053 [P] Add the CHANGELOG entry in `CHANGELOG.md` describing the four fixed defects, naming the removed `PROJ` fallback as the only behaviour change
- [X] T054 [P] Update `README.md` to state that a bound repository needs no environment variables for the mirror, and that the extension variables remain supported as explicit overrides
- [X] T055 Verify the two acceptance properties that span all stories — zero writes on every unresolved run, and a prediction run byte-identical to a real run — against `tests/conformance/scenarios/us6-dry-run.json` and the two new scenarios
- [X] T056 Run the complete quickstart in `specs/004-reconcile-config-resolution/quickstart.md` and tick every box in its acceptance summary

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies. T001 is research-only and never blocks code.
- **Foundational (Phase 2)**: Depends on Setup. **Blocks US1 and US2** — both write through the shared builder.
- **US1 (Phase 3)**: Depends on Foundational.
- **US2 (Phase 4)**: Depends on Foundational. Consumes the project key US1 resolves, so US1 first is the natural order.
- **US3 (Phase 5)**: Depends on US1 and US2 — it reports on failures of the resolution paths those stories introduce.
- **US4 (Phase 6)**: Depends on Foundational only. Independent of US3; can run parallel to it.
- **Polish (Phase 7)**: Depends on every story being complete.

### User Story Dependencies

- **US1 (P1)**: The MVP. Independently testable once Foundational lands.
- **US2 (P1)**: Independently testable, but only delivers a *working* mirror alongside US1 — the spec is explicit that fixing any subset of the defects still leaves the mirror broken.
- **US3 (P2)**: Needs US1 and US2 present to have failures to report.
- **US4 (P2)**: Fully independent of US3.

### Within Each User Story

- Test tasks are written and observed FAILING before any implementation task in the same phase — non-negotiable under Constitution XIII.
- Bash and PowerShell implementations of the same behaviour may proceed in parallel; neither is complete until the conformance scenario passes on both.
- The conformance scenario closes each story.

### Parallel Opportunities

- T002, T003 and T003a (Setup) are independent files; T003a's mock route only becomes exercisable once T003's fixture exists, so land them together.
- T004 and T005 (Foundational tests) are different ports.
- T009 through T012 (US1 tests) are four different files.
- T018 and T019 (PowerShell implementation) touch different modules than the Bash tasks preceding them.
- US3 and US4 can be developed simultaneously by two people once US1 and US2 are merged.
- T050 through T054 (Polish) are independent.

---

## Parallel Example: User Story 1

```bash
# Write all four failing test suites together, then observe them fail:
Task: "Routing resolution tests in tests/bash/commands/test_reconcile_routing.bats"
Task: "Payload project tests in tests/bash/sink/test_plan_apply_project.bats"
Task: "Routing tests in tests/powershell/commands/Reconcile.Routing.Tests.ps1"
Task: "Payload tests in tests/powershell/sink/PlanApply.Project.Tests.ps1"

# Then the two ports' implementations in parallel:
Task: "Routing resolution in scripts/powershell/commands/Reconcile.psm1"
Task: "Payload project and guard in scripts/powershell/sink/jira/PlanApply.psm1"
```

---

## Implementation Strategy

### MVP scope

The honest MVP is **Phase 1 + Phase 2 + US1 + US2**, not US1 alone. US1 alone makes the payload name the right project but still omit the issue type, so Jira still rejects every creation — the user visible outcome would be unchanged. The spec states this directly: fixing any subset of the defects still leaves the mirror broken.

US1 alone remains a valid, independently testable *increment* — it is simply not a shippable one.

### Incremental delivery

1. Setup + Foundational → the shared builder exists
2. US1 → the right project is resolved and declared → testable, not yet shippable
3. US2 → **first genuinely working mirror; this is the release the reporter is waiting for**
4. US3 → misconfigurations become self-service
5. US4 → the fix is proven style-independent and the latent priority defect is closed

### Suggested sequencing for one developer

Phases 1 → 2 → 3 → 4, then ship. Phases 5 and 6 follow as a second release; they can be swapped without consequence.

---

## Notes

- `[P]` marks different files with no incomplete dependency between them.
- Every test task must be observed FAILING before its implementation task starts — this is what the repository's bug-fix policy and Constitution XIII require, and the defect is fully reproducible without Jira, so there is no excuse for skipping it.
- Neither port is "done" alone: a behaviour present in one and absent in the other is a failing gate under Principle VI.
- No task adds a configuration key, schema field or CLI flag. If one appears to require it, stop — that is a signal the design drifted from research R2 or R4.
- Commit after each task or logical group.

---

## Phase 8: Convergence

- [ ] T057 Read `config.yml` whenever the creation context is not supplied by an explicit override — extend the config-read condition at `scripts/bash/commands/reconcile.sh:262` and `scripts/powershell/commands/Reconcile.psm1:309` to also require `SPEC_KIT_JIRA_PLAN_CONTEXT` to be unset, so a run that overrides only the project key still resolves `priority_map`; write the failing case first in `tests/bash/commands/test_reconcile_plan_context.bats` and `tests/powershell/commands/Reconcile.PlanContext.Tests.ps1` per FR-008 (partial)
- [ ] T058 Add a real (non-`--dry-run`) conformance scenario over the config-resolution path in `tests/conformance/scenarios/` and assert its captured `calls.log` request body is byte-identical to the `us8-reconcile-company-managed` prediction, per SC-006 (missing)
- [ ] T059 Close the open T051 gate: obtain the kcov statement percentage for `scripts/bash/commands/reconcile.sh` and `scripts/bash/sink/jira/plan_apply.sh` from a Linux CI run and record it in `specs/004-reconcile-config-resolution/tasks.md`, per Constitution XIII (missing)
- [ ] T060 Tick the acceptance-summary boxes in `specs/004-reconcile-config-resolution/quickstart.md`, recording the evidence behind each, per tasks: T056 (partial)
- [ ] T061 Exercise the branch-2 mock route — add a scenario or test consuming `tests/conformance/mock-jira/configs/priority-allowed.json` so the `createmetaFields` key at `tests/conformance/mock-jira/mock-server.ps1:61` is covered, per tasks: T003a (partial)
- [ ] T062 Add the no-environment-variables statement to `README.md`, or point its Install section at the paragraph now in `INSTALL.md:59-64`, per tasks: T054 (partial)
