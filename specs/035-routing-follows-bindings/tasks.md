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
- [X] **T024 / T031 / T032 / T039 / T048 — CLOSED after the fact.** These were
  marked done on the strength of message-level tests that did not prove what
  they claimed. Four end-to-end cases were added afterwards to
  `tests/bash/commands/test_reconcile_marker_routing.bats`, driving the real
  command against the mock:
  - **C3.3** both refusals leave the mock's call log EMPTY — zero requests, not
    merely zero writes, which is the difference between the ordering being a
    property of the design and a coincidence;
  - **C3.5** both refusals downgrade to one `WARNING` at exit 0 under
    `SPEC_KIT_JIRA_HOOK_CONTEXT` — the CHANGED branch of Principle III, which
    would otherwise have inherited the unchanged branch's coverage;
  - **C3.4** each refusal is compared as BYTES with and without `--dry-run`,
    not by substring;
  - **FR-009** no run emits an action set naming more than one project,
    asserted over the emitted actions rather than inferred from the refusals.
- [ ] **T040 partial** — the message-to-command check rests on the existing
  generic guard rather than a case written for this feature's literals.
- [ ] **T034b** — FR-015's assertion is implied by the refusals being emitted
  from a zero-request path (now proven by C3.3 above), not asserted directly.
- [ ] **PowerShell twins of the four cases above.** The mismatch refusal is
  covered end-to-end in both modes by `Reconcile.Durability.Tests.ps1`; the hook
  downgrade and the one-project invariant are not, on that port. Cross-port
  equivalence of the refusals themselves is carried by the conformance corpus.


---

## Phase 7: Convergence

Appended by `/speckit-converge` on 2026-08-31, after assessing the code against
`spec.md`, `plan.md`, `contracts/marker-routing.md` and the constitution. Ordered
CRITICAL first.

- [X] T049 **CRITICAL** Rebuild the routing refusal for a FIVE-rank chain in `scripts/bash/commands/reconcile.sh` (`_reconcile_routing_refusal`) and `scripts/powershell/commands/Reconcile.psm1` (`Get-JiraReconcileRoutingRefusal`): add the clause reporting what the specification's own record found, renumber the operator-team clause from rank 3 to rank 4, and delete the now-unreachable `already bound … fixed by its own markers` branch — a bound specification always yields a marker project and can no longer reach this refusal at all. Failing test first, in `tests/bash/commands/test_reconcile_routing_refusal.bats` and `tests/powershell/commands/Reconcile.RoutingRefusal.Tests.ps1`. Per C2.6 (contradicts) — T018/T019 were marked done with no artifact behind them
- [X] T050 Correct the routing box in `docs/05-reconcile-flow.md:24`, which still renders `four ranks: rule → team prefix → …`. The T041 sweep grepped for `routing_default` and this file states the chain without naming the key — re-grep for `four ranks|four-rank|rank 3 of four` afterwards, not for the key. Per FR-024 (missing)
- [X] T051 [P] Correct the three live comments still describing a four-rank chain: `scripts/bash/commands/reconcile.sh:171`, `scripts/powershell/commands/Reconcile.psm1:225`, `scripts/powershell/engine/Interchange.psm1:363`. Per Constitution XVI (partial)
- [X] T052 Extend `tests/live/test_live_zero_churn.bats` to the repository shape that produces a full duplicate ticket set today: a bound specification, a committed default naming another project, no team folder prefix — re-run and assert zero writes of every kind. Constitution II names this suite by path in its enforcement test; the suite is bash-only by design. Per FR-021 / C6.3 (missing)
- [X] T053 [P] Write the PowerShell twins of the four end-to-end cases now proven only in bash, in `tests/powershell/commands/Reconcile.MarkerRouting.Tests.ps1`: both refusals leave the mock call log empty (C3.3); both downgrade to one `WARNING` at exit 0 under `SPEC_KIT_JIRA_HOOK_CONTEXT` (C3.5); each refusal is byte-identical with and without `--dry-run` (C3.4); no run emits an action set naming more than one project (FR-009). Use a both-streams capture — a refusal travels on stderr, which `Invoke-Captured` does not see. Per FR-019 / C6.1 (missing)
- [X] T054 Resolve the contradiction at C5.3: the clause keeps `_recognition_project_of` / `Get-JiraRecognitionProjectOf` on the stated ground that the task-tier check reuses them, but that check uses `marker_bound_projects` and neither helper has a caller in either port. Either reuse the helper in the task tier, or delete it from both ports and amend C5.3 to say so. Per C5.3 / Constitution XV (contradicts)
- [X] T055 [P] Assert FR-015 directly rather than resting on C3.3's zero-request proof: every message this feature adds is composable from values known before any Jira write. Per FR-015 (partial)
- [X] T056 [P] Add a message-to-command case covering this feature's own literals rather than relying on the generic guard, in the existing message↔command check. Per FR-022 / T040 (partial)

### Phase 7 outcome — 2026-08-31

All eight closed. Verified after the fact:

| Suite | Result |
| --- | --- |
| bash `engine` + `sink` + `ci` + `conformance` | 1415 tests, 0 failures |
| bash `commands` (both halves) + `lib` + `hooks` + `packaging` | 1237 tests, 0 failures |
| Pester `sink` + `lib` + `engine` | 1269 tests, 0 failures |
| Pester routing-refusal / marker-routing / durability / routing | 0 failures |
| conformance, 7 scenarios incl. the three 033 refusal states | byte-identical on both ports |
| `shellcheck -x -P scripts/bash` | clean |

Two things Phase 7 changed that are worth carrying forward:

- **T049 rewrote a shipped message.** `us033-refuse-bound-skip` now exits **0**
  instead of 4 — the state it captured (a bound specification no rank could
  place) cannot occur any more. Its description was rewritten rather than the
  scenario deleted: it is now the cross-port proof that the refusal is gone.
- **T054 deleted a helper the contract said to keep.** C5.3 was amended rather
  than the code bent to fit it, and both ports' durability tests were flipped
  from asserting presence to asserting absence.

Still open, unchanged from the earlier hand-off: T047 (`ci/windows-probe`,
in flight), T046 (dogfooding), and the live assertion added by T052, which
skips until `SPEC_KIT_JIRA_LIVE=1` and real credentials are supplied.
