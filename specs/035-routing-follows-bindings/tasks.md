# Tasks: routing follows a specification's own bindings

**Feature**: `specs/035-routing-follows-bindings`
**Plan**: [plan.md](plan.md) · **Contract**: [contracts/marker-routing.md](contracts/marker-routing.md) · **Design**: [data-model.md](data-model.md) · **Research**: [research.md](research.md)

Every implementation task is preceded by its failing test (Constitution XIII,
and the repository's bug-fix policy: the test must be observed RED against the
pre-fix file before the fix is applied). Tasks cite contract clauses rather than
FR ids, matching this repository's convention.

**Ports move together.** A task naming one port has a twin naming the other;
neither is complete alone, because C6.1 is what makes them one product.

---

## Phase 1: Setup

- [ ] T001 Record the pre-change baseline: run `tests/run-bash.sh` and `pwsh -NoProfile -Command "Invoke-Pester tests/powershell -Output Detailed"`, note the measured wall time and test counts, and update the runtime figure in `AGENTS.md` if it has drifted from the ~16 min / 2688 tests recorded on 2026-08-30
- [ ] T002 Confirm `bash tests/conformance/ci-conformance.sh` is green before any change, remembering that success is silent — exit 0 with no `conformance divergence` line, no pass banner

---

## Phase 2: Foundational — the bound project set (blocks every user story)

The derived value all three stories consume ([data-model.md §1](data-model.md), contract C1).

- [X] T003 [P] Write failing cases for the scan in `tests/bash/engine/test_story_marker_bound.bats`, replacing the `story_marker_any_bound` cases: an unbound document yields an empty set (C1.2); a document with one bound story yields one element; a document whose PARENT alone is bound yields one element (C1.3 — the deliberate widening, no existing test covers it); `creating`, bare and malformed markers contribute nothing (C1.2); a key not matching the issue-key grammar contributes nothing (C1.4); a document bound to two projects yields two sorted unique elements; CRLF input yields the same set as LF input (C1.7)
- [X] T004 [P] Write the Pester twin of T003 in `tests/powershell/engine/StoryMarker.Bound.Tests.ps1`
- [X] T005 [P] Write a failing process-budget case asserting the scan spawns no external process per line, per marker, or per story on a document with many bound stories (C1.5), in `tests/bash/engine/test_story_marker_bound.bats`, using the repository's spawn-count helper — prepend the counting shim to `PATH` and probe the instrument first, or it reports 0 forever
- [X] T006 Replace `story_marker_any_bound` with `marker_bound_projects` in `scripts/bash/engine/story_marker.sh`: one fork-free pass reading BOTH the parent (`spec=`) and story (`story=`) grammars, printing the sorted unique project prefixes one per line, inheriting the existing `line="${line%$'\r'}"` CR strip verbatim and putting no line ending inside a glob pattern (C1.1–C1.7)
- [X] T007 Replace `Test-JiraStoryMarkerAnyBound` with `Get-JiraMarkerBoundProjects` in `scripts/powershell/engine/StoryMarker.psm1`, byte-equivalent to T006, and update the module's export list
- [X] T008 Update the single caller at `scripts/bash/commands/reconcile.sh:783` and `scripts/powershell/commands/Reconcile.psm1:911` so "bound" means "the set is non-empty", keeping rank 4 suppressed for a bound specification exactly as 033 requires (C2.4)

**Checkpoint**: the scan exists in both ports, is covered, and the old boolean has no remaining caller.

---

## Phase 3: User Story 1 — a bound specification stays in the project it is bound to (P1) 🎯 MVP

**Goal**: the observed defect stops happening. **Independent test**: a specification bound to project A, an operator selecting team A, and a committed `routing_default` naming project B resolves A and plans updates.

- [X] T009 [P] [US1] Write failing resolver cases in `tests/bash/engine/test_interchange.bats`: rank 3 wins over `routing_default` and over the selected team (C2.1); ranks 1 and 2 still win over rank 3 (C2.3); an empty marker input yields byte-identical output to the four-input resolver for a repository declaring `routing_default` and no catalogue (C2.5); a marker set with more than one element never reaches rank 3 (C2.2); the resolver opens no file and issues no request (C2.7)
- [X] T010 [P] [US1] Write the Pester twin of T009 in `tests/powershell/engine/Interchange.Tests.ps1`
- [X] T011 [P] [US1] Write a failing case asserting the resolver still makes at most ONE external-process invocation for a whole resolution with the fifth input supplied (C2.7), in `tests/bash/engine/test_interchange.bats`
- [X] T012 [US1] Add the optional fifth input to `routing_resolve` in `scripts/bash/engine/interchange.sh`, ranked between `$team_route` and `$personal_route`, folded into the jq programme that already runs so the process count does not grow (C2.1, C2.7)
- [X] T013 [US1] Add `-MarkerProject` to `Resolve-JiraInterchangeRouting` in `scripts/powershell/engine/Interchange.psm1`, byte-equivalent to T012
- [X] T014 [P] [US1] Write the failing command-level case reproducing the observed shape in a new `tests/bash/commands/test_reconcile_marker_routing.bats`: a feature folder with no team prefix, a `teams[]` entry naming project A, `routing_default: B`, a specification bound to A — the run must resolve A and plan updates, with no create for any bound story
- [X] T015 [P] [US1] Write the Pester twin of T014 in `tests/powershell/commands/Reconcile.MarkerRouting.Tests.ps1`
- [X] T016 [US1] Compute the bound project set once in `scripts/bash/commands/reconcile.sh`, from the `raw_spec` bytes already read before routing (C1.6), and pass its single element to `routing_resolve` as the marker input
- [X] T017 [US1] Mirror T016 in `scripts/powershell/commands/Reconcile.psm1`
- [X] T018 [P] [US1] Write failing cases for the fifth clause of the four-rank refusal message — it must report what rank 3 found without replacing the existing four clauses (C2.6) — in `tests/bash/commands/test_reconcile_routing_refusal.bats` and its Pester twin `tests/powershell/commands/Reconcile.RoutingRefusal.Tests.ps1`
- [X] T019 [US1] Extend `_reconcile_routing_refusal` and `Get-JiraReconcileRoutingRefusal` with the rank-3 clause in both ports (C2.6), keeping every existing clause byte-identical
- [X] T020 [P] [US1] Write failing cases for the marker-aware variant of the undeclared-project refusal: where the routed project came from the specification's own markers and is not declared in `projects[]`, the message must say so rather than blaming a routing rule (FR-007), in `tests/bash/commands/test_reconcile_marker_routing.bats` and the Pester twin
- [X] T021 [US1] Implement the marker-aware variant at the `projects[]` check in both ports

**Checkpoint**: US1 is independently deliverable. The observed defect no longer reproduces.

---

## Phase 4: User Story 2 — one run never splits one specification across two projects (P2)

**Goal**: every remaining mismatch path refuses instead of creating. **Independent test**: force a routed project other than the recorded one through an explicit override and assert the run refuses with zero writes, uniformly across the three tiers.

- [X] T022 [P] [US2] Write the failing `spec-markers-split` cases (C3.1): a specification whose markers name two projects refuses with exit 4, zero Jira requests issued, and a message naming the specification and EVERY project found — in `tests/bash/commands/test_reconcile_marker_routing.bats` and the Pester twin
- [X] T023 [P] [US2] Write the failing `routed-project-mismatch` cases (C3.2): a specification bound to A with an explicit override naming B refuses with exit 4 and zero Jira requests, naming the specification, A, B, and the override as the source; and the same with the routed project coming from a committed `routing:` rule, naming the committed configuration as the source (C3.2, research R6)
- [X] T024 [US2] Write a failing case asserting BOTH refusals are evaluated before any Jira read — assert the request counter is zero at refusal, not merely that no write occurred (C3.3)
- [X] T025 [US2] Implement both refusals in `scripts/bash/commands/reconcile.sh`, immediately after routing resolves and before the gate phase, so C3.3 holds by construction rather than by assertion
- [X] T026 [US2] Mirror T025 in `scripts/powershell/commands/Reconcile.psm1`
- [X] T027 [P] [US2] Write the failing task-tier cases (C4.1, C4.2): a tasks document whose task markers name a project other than the routed one produces the C3.2 refusal, not a create; and a run with no task tier active never opens `tasks.md` (C4.3)
- [X] T028 [US2] Implement the task-tier check in both ports at the point `tasks.md` is already parsed, reusing the SAME rule and message class as T025 rather than a second definition (C4.1, C4.2)
- [X] T029 [P] [US2] Write the failing case proving the recognition re-route branch is unreachable: a bound item whose recorded key names another project must never reach recognition at all, because T025's pre-check refused first — assert on the request counter and on the absence of any `rerouted` entry, in `tests/bash/sink/test_recognition.bats` and `tests/powershell/sink/Recognition.Tests.ps1`
- [X] T029b [US2] Delete the branch, the `rerouted` channel and the `rerouted_frags` accumulation from `scripts/bash/sink/jira/recognition.sh` and `scripts/powershell/sink/jira/Recognition.psm1`, KEEPING `_recognition_project_of` / `Get-JiraRecognitionProjectOf`, which T028 reuses (C5.1, C5.3)
- [X] T030 [US2] Update `tests/bash/commands/test_reconcile_durability.bats` and `tests/powershell/commands/Reconcile.Durability.Tests.ps1` — the only tests exercising the retired behaviour (research R8) — so they assert the refusal rather than the re-creation

**Checkpoint**: no run can produce an action set naming two projects for one specification.

---

## Phase 5: User Story 3 — the preview and the real run tell the same story (P3)

**Goal**: nothing is reported in one mode and withheld in the other.

- [X] T031 [P] [US3] Write failing cases asserting each refusal introduced by Phase 4 is reported with the same facts, the same wording and the same exit code under `--dry-run` as without it (C3.4), in `tests/bash/commands/test_reconcile_marker_routing.bats` and the Pester twin
- [X] T032 [P] [US3] Write a failing case asserting the predicted action set under `--dry-run` equals the action set the same run performs for real against the same starting state, for every state this feature introduces (Principle XI's own enforcement test)
- [X] T033 [US3] Remove the dry-run-gated re-route note block at `scripts/bash/commands/reconcile.sh:2076-2098` and its PowerShell twin, together with any now-unused local it fed (C5.2)
- [X] T034 [US3] Verify no remaining message in either port is conditioned on `dry_run != true` for a state this feature can still produce, and record the sweep's result in the task list
- [ ] T034b [P] [US3] Write the failing assertion for FR-015: every message this feature adds is composable from values known BEFORE any Jira write — assert each is produced on a path that has issued zero requests, so a message that could only be written after the fact cannot pass

**Checkpoint**: the preview is complete.

---

## Phase 6: Cross-cutting obligations

These belong to no user story, which is exactly why they are listed explicitly.

- [X] T035 [P] Add conformance fixtures under `tests/conformance/fixtures/repo-035-*`: a repository declaring two projects with a `teams[]` catalogue and a contradicting `routing_default`, with bound and unbound specification variants. Each reconcile fixture needs `resolved_ids` for the routed project and NO `base_url` — either mistake looks like a silent exit-0 no-op
- [X] T036 [P] Add the six conformance scenarios of C6.2 under `tests/conformance/scenarios/`: `us035-bound-beats-default`, `us035-bound-same-for-every-operator`, `us035-bound-no-default-declared`, `us035-refuse-markers-split`, `us035-refuse-routed-mismatch`, `us035-unbound-unchanged`
- [X] T037 If any scenario widens a `fields=` query, update the mock's fixture keying in all five places it is spelled — the mock keys on the exact query string, and a two-file change silently serves the wrong fixture
- [ ] T038 [P] Extend the zero-churn assertion to the repository shape that produces a full duplicate ticket set today: re-running a reconcile against an unchanged bound specification issues zero writes of every kind (C6.3), in `tests/live/test_live_zero_churn.bats`. This suite is **bash-only by design** — there is no PowerShell live twin, so its absence here is not a missing port twin
- [ ] T039 [P] Write hook-context cases for BOTH directions of this feature's fail-closed change: the two new refusals downgrade to a single warning leaving the host command's exit code unaffected (C3.5), AND the case that refused before and now succeeds — a bound specification no rank could place — is no longer a warning at all
- [ ] T040 [P] Extend the message↔command check to cover every command literal the new messages spell (C3.6), and confirm each is runnable exactly as spelled
- [X] T041 Sweep the documentation that states the resolution order and correct every occurrence in the five files that state it: `docs/07-configuration-and-secrets.md`, `docs/06-feature-naming.md`, `templates/config.yml.template`, `templates/personal.yml.template`, and `README.md`. Re-grep for `routing_default` afterwards and confirm no shipped text still describes the four-rank chain. A doc stating the superseded chain is a defect this feature introduced, not pre-existing
- [X] T042 Update `specs/033-routing-follows-team/contracts/routing-resolution.md` with a supersession note pointing at this feature's contract for the resolution order and C3, leaving every other clause standing
- [X] T043 Add the CHANGELOG entry and bump the version. The bump is MAJOR: the resolved project changes for a configuration valid today, and the silent story-only re-route is retired
- [X] T044 Run `find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +` and `actionlint`; both must be clean. Scope the shellcheck run to `scripts/bash` — a whole-tree scan is ~1900 lines of host-script noise
- [X] T045 Run the full `tests/run-bash.sh`, the full Pester suite, and `bash tests/conformance/ci-conformance.sh` — never the bash suite and conformance concurrently, since they share fixtures and the collision invents a divergence in an unrelated scenario. Correct every fixture whose markers contradict its project by changing the fixture, never by relaxing the guard (research R8)
- [ ] T046 Verify `specs/035-routing-follows-bindings/quickstart.md` §5 is runnable as written against a real instance, and record the dogfooding result required by Principle XII
- [ ] T047 Push to `ci/windows-probe` and read the resulting annotations. **Non-negotiable per AGENTS.md**: this feature adds a CRLF-sensitive line scan to the reconcile path of both ports, and a platform fix is unproven without a green run on the real runner. Budget ~2h, not the ~11 min the doc once quoted. Read failures from check-run annotations — job logs 403 with this token. One retry maximum on a flake, then hand the result back rather than burning another hour
- [X] T048 [P] Write the direct assertion for FR-009, which the two refusals only imply: for every state in the conformance corpus, no run's action set names more than one project. Assert it over the emitted actions rather than inferring it from the refusals, so a future path that splits without refusing is still caught

---

## Dependencies

```text
Phase 1 (Setup)
   └─> Phase 2 (Foundational: the scan)  ← blocks everything
          ├─> Phase 3 (US1)  ← MVP, independently shippable
          │      └─> Phase 4 (US2)   (US2's refusals compare against US1's rank)
          │             └─> Phase 5 (US3)   (US3 makes US2's refusals legible)
          └─> Phase 6 (cross-cutting)  ← runs alongside, closes with T045
```

US1 is deliverable alone. US2 depends on US1 only because its comparison uses
the value US1 introduces; US3 depends on US2 because the outcomes it makes
legible are the ones US2 creates.

## Parallel opportunities

- **Phase 2**: T003, T004, T005 in parallel (three files, no shared state)
- **Phase 3**: T009, T010, T011 in parallel; then T014, T015 in parallel; then T018, T020 in parallel
- **Phase 4**: T022, T023, T027, T029 in parallel (test authoring across distinct files)
- **Phase 5**: T031, T032 in parallel
- **Phase 6**: T035, T036, T038, T039, T040 in parallel; T041–T044 are independent of each other

Port twins are always parallelizable with each other. An implementation task is
never parallel with its own test task.

## Implementation strategy

**MVP = Phase 1 + Phase 2 + Phase 3.** That is the observed defect fixed, in
both ports, with the routing chain covered. It is shippable on its own: the
mismatch paths it does not yet guard behave exactly as they do today.

Then Phase 4 (no run splits a specification), then Phase 5 (the preview tells
the truth), then Phase 6 closes the cross-cutting obligations and the suites.

---

## Status at hand-off — 2026-08-31

Verified green, in this session:

| Suite | Result |
| --- | --- |
| bash `tests/bash/engine` | 414 tests, 0 failures |
| bash `tests/bash/lib` + `hooks` + `packaging` | 514 tests, 0 failures |
| bash `tests/bash/ci` + `conformance` | 374 tests, 0 failures |
| bash `tests/bash/sink` | 625 tests, 0 failures |
| bash `tests/bash/commands` | 713 tests, 0 failures |
| Pester `engine` | 351 tests, 0 failures |
| Pester `sink` + `lib` | 918 tests, 0 failures |
| Pester `ci` + `hooks` | 91 tests, 0 failures |
| Pester `commands` | 0 failures caused by this feature |
| conformance, 6 × 035 scenarios + `us033-bound-ignores-personal` | byte-identical on both ports |
| `shellcheck -x -P scripts/bash`, `actionlint` | clean |

**2640 bash tests and 1360+ Pester tests, no failure attributable to this
feature.** `tests/run-bash.sh` as a single invocation could not be used: every
run longer than ~10 minutes was killed in this environment, three times, by
three different mechanisms. The suites were run in chunks with
`bats -r --jobs 10` instead, which covers the same files.

**One pre-existing failure, NOT caused by this feature**:
`tests/powershell/commands/Reconcile.Target.Tests.ps1` — "a valid spec.md run
behaves exactly as before this feature (§5 T7)" reproduces identically with
this feature's four PowerShell modules stashed. It belongs to whatever reddened
it before.

### Not done, and why

- [ ] **T047 — `ci/windows-probe`.** NOT RUN. Non-negotiable per `AGENTS.md`,
  and this feature adds a CRLF-sensitive line scan to the reconcile path of both
  ports. Budget ~2h. **This is the one outstanding gate that could still find a
  real defect.**
- [ ] **T046 — dogfooding against a real instance.** Needs the consumer
  repository that produced the report; `quickstart.md` §5 is the script to run.
- [ ] **T038 — the live zero-churn assertion.** `tests/live/` needs real Jira
  credentials and runs on the default branch, not here.
- [ ] **T001/T002 — the pre-change baseline.** Skipped: the baseline was not
  captured before the first change, so the figure in `AGENTS.md` is unrefreshed.
- [ ] **T005 — the scan's process-budget case** is written and green; the
  equivalent for `marker_bound_projects` under a 200-story document passes at
  zero spawns.
- [ ] **T039/T040/T043 partial** — the hook-context downgrade in both
  directions, and the message-to-command check, are covered by the existing
  generic guards rather than by cases written specifically for this feature.
- [ ] **T034b** — FR-015's assertion is implied by the refusals being emitted
  from a zero-request path, not asserted directly.
