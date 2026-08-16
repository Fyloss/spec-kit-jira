---

description: "Task list for 028 — A Scenario Written the Template's Way Reaches the Ticket Intact"
---

# Tasks: A Scenario Written the Template's Way Reaches the Ticket Intact

**Input**: Design documents from `/specs/028-fix-gherkin-clause-parsing/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/clause-recognition.md, quickstart.md

**Tests**: **REQUIRED, not optional.** Constitution XIII mandates TDD, and the project's bug-fix policy
requires a test that reproduces the defect and fails *before* the fix. Every phase below writes its tests
first.

**Organization**: Tasks are grouped by user story. Note honestly that User Stories 1, 2 and 3 are three
assertion surfaces over **one** production change — §2 of the contract. US1 carries that change; US2 and
US3 add no production code and exist to prove properties US1's own tests do not cover. This is stated
rather than disguised with invented implementation tasks (Constitution XV).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel — different files, no dependency on an incomplete task
- **[Story]**: US1..US5, mapping to spec.md's user stories

## Path Conventions

Two native ports at the repository root: `scripts/bash/engine/`, `scripts/powershell/engine/`. Tests in
`tests/bash/`, `tests/powershell/`, `tests/conformance/`. Paths below are exact.

---

## Phase 1: Setup (Baseline Capture)

**Purpose**: Establish, by measurement, both the failing state and the "must not change" state. Nothing is
initialised — this is an existing repository and the feature adds no dependency.

- [X] T001 Reproduce both failures per `specs/028-fix-gherkin-clause-parsing/quickstart.md` §1 and record both outputs: the bash port returns one scenario whose `given`, `when` and `then` each hold the whole line; the PowerShell port returns `[]`. Both must be observed before any source edit.
- [X] T002 [P] Confirm the guards that must pass **unmodified** are green on the untouched tree: the four Gherkin cases in `tests/bash/engine/test_parse_title_desc.bats`, their mirrors in `tests/powershell/engine/Parse.TitleDesc.Tests.ps1`, and both `parse_acceptance_criteria` assertions in `tests/bash/engine/test_parse_spawn_budget.bats`.

**Checkpoint**: The defect is measured on both ports and the regression baseline is green.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The one genuinely shared piece — the emphasis-wrapper token — hoisted so that every recogniser
in §2 of the contract, and the join pre-pass in §3, use a single definition rather than a copy each.

**⚠️ CRITICAL**: US1 and US4 both edit the recognisers; doing this first prevents four divergent copies of
the same token.

- [X] T003 [P] Hoist the emphasis-wrapper token `(\*\*|__|\*|_)?` to a single file-scope constant in `scripts/bash/engine/parse.sh`, replacing the function-local `kw_wrap`, and reference it from every existing recogniser. Behaviour must be byte-identical — this is a refactor, not a fix.
- [X] T004 [P] Mirror T003 in `scripts/powershell/engine/Parse.psm1`: hoist `$kwWrap` out of `Get-JiraParsedAcceptance` to module scope. Import it **without** `-Force` if a cross-module reference is introduced, per the sink-module scope hazard.

**Checkpoint**: One wrapper definition per port, all existing tests still green.

---

## Phase 3: User Story 1 — A scenario written the template's way reaches the ticket as three distinct clauses (Priority: P1) 🎯 MVP

**Goal**: The reporter's own line yields three clauses whose texts are disjoint, on both ports.

**Independent Test**: Feed `1. **Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.` to each port's acceptance parser and assert three disjoint clauses, none beginning with a keyword.

### Tests for User Story 1 ⚠️

> Write these FIRST and confirm they FAIL for the reasons T001 recorded.

- [X] T005 [US1] Add failing bats cases to `tests/bash/engine/test_parse_title_desc.bats` for contract §4 rows 1, 2, 5, 6 and 9, plus rule T3 (a triple-detected line matching neither pattern emits nothing), asserting clause **disjointness** (contract §6 invariant 1) and not merely non-emptiness. For FR-011, also assert that concatenating the three clause texts reproduces the source line minus its keywords, wrappers and clause delimiters — so a truncation at either end fails the test rather than passing it as "disjoint".
- [X] T006 [P] [US1] Add the mirror failing cases to `tests/powershell/engine/Parse.TitleDesc.Tests.ps1`, asserting the same nine-row values from `specs/028-fix-gherkin-clause-parsing/contracts/clause-recognition.md` §4.
- [X] T007 [US1] Confirm T005 and T006 fail **for the right reason** — bash: all three buckets hold the unsplit line; PowerShell: empty array — and not because a test is malformed. Record in `specs/028-fix-gherkin-clause-parsing/quickstart.md` §1's terms.

### Implementation for User Story 1

- [X] T008 [US1] In `parse_acceptance_criteria` (`scripts/bash/engine/parse.sh`), make the wrapper optional on **both** sides of `Given`, `When` and `Then` in the triple detector and in pattern T1, using the T003 constant. Group indices shift to 3, 6, 9 — see contract §2.
- [X] T009 [US1] In the same function in `scripts/bash/engine/parse.sh`, delete the glob-strip fallback (`${t#*Given }`, `${t%%When *}` and friends) and replace it with pattern T2, failing closed at T3. A glob strip that does not match returns its input unchanged, which is the whole cause of the threefold repetition — no branch may survive that can emit an unsplit line. Depends on T008.
- [X] T010 [P] [US1] Mirror T008 and T009 in `Get-JiraParsedAcceptance` (`scripts/powershell/engine/Parse.psm1`), including the deliberate switch of the delimiter-free fallback from lazy `(.*?)` to greedy `(.+)` so both ports split identically — research §R3.
- [X] T011 [US1] Verify T005 and T006 now pass and that the four pre-existing Gherkin cases in each port pass **unmodified**. If a pre-existing expected value has to change to make them green, the design is wrong (contract §6 invariant 4 — which permits adding inputs to a fixture, as T017 does, but never changing an existing assertion's value).

**Checkpoint**: The reported defect is gone on both ports. This is the MVP.

---

## Phase 4: User Story 2 — The emphasis around a keyword never reaches the reader (Priority: P1)

**Goal**: No rendered clause repeats its own keyword, for **every** accepted scenario form — not only the
single-line one US1 exercises.

**Independent Test**: For every form in contract §4 and §5, assert no clause body matches `^ kw (Given|When|Then|And|But) kw \s`.

**No production code is expected here.** The per-line and And/But recognisers already accept a wrapper on
both sides; US1's change completes the set. T014 exists only in case a case falls through.

### Tests for User Story 2 ⚠️

- [X] T012 [US2] Add bats cases to `tests/bash/engine/test_parse_title_desc.bats` asserting contract §6 invariant 2 (no clause body opens with a keyword) across every accepted form, plus an emphasised `**And**`/`**But**` continuation joining the correct bucket, plus a clause body containing the words "when"/"then" surviving unsplit (FR-007), plus a one-sided wrapper (`**Given` and `Given**`), plus a **mixed form** on one line (`**Given** x, When y, **Then** z`) yielding one scenario with all three clauses correct — contract §5 row 2, which is the spec's "a scenario mixing forms" edge case and appears in no §4 row.
- [X] T013 [P] [US2] Add the mirror cases to `tests/powershell/engine/Parse.TitleDesc.Tests.ps1`.

### Implementation for User Story 2

- [X] T014 [US2] Only if a T012/T013 case fails: extend the §2 classification in `scripts/bash/engine/parse.sh` and `scripts/powershell/engine/Parse.psm1`. **Do not touch the renderer** — `_adf_gherkin_panel` in `scripts/bash/sink/jira/adf.sh` and its PowerShell twin are correct, and their plain `"Given "` prefix is what FR-009 relies on (research §R4). **No case failed — US1's fix already satisfies every T012/T013 assertion; no production code added, per the phase's own prediction.**

**Checkpoint**: The stutter is impossible on every form, not just the reported one.

---

## Phase 5: User Story 3 — Both ports produce the same panel from the same specification (Priority: P1)

**Goal**: Close the Constitution VI divergence, and close the corpus gap that let it ship.

**Independent Test**: `bash tests/conformance/ci-conformance.sh` exits 0 with the new fixture present.

**Why this phase is not optional polish**: every acceptance-criteria line in every existing conformance
fixture uses the one-clause-per-line form `- **Given** …`. Not one uses the spec-kit template's own default
single-line triple. FR-015 requires the corpus to carry it (research §R6).

### Tests for User Story 3 ⚠️

- [X] T015 [US3] Create the conformance fixture `tests/conformance/fixtures/repo-with-template-form-ac/` with a `specs/001-template-form/spec.md` whose acceptance scenarios use the emphasised single-line triple, plus whatever config file the harness requires — model it on an existing fixture such as `tests/conformance/fixtures/repo-with-core/`.
- [X] T016 [US3] Add `tests/conformance/scenarios/us028-template-form-ac.json` binding that fixture to **two identical `reconcile` invocations** — a `"runs"` array of two entries carrying the same `argv`, the shape `tests/conformance/scenarios/us021-state-config-changed.json` already uses. Run 1 creates the story from the emphasised single-line form; run 2, over an unchanged fixture, is what pins FR-017/SC-007 and US3 AC2 across the port boundary. Follow `tests/conformance/scenarios/sc008-deleted-managed-region-restored.json` for the surrounding fields. **Verified manually against both ports before the corpus run: run 1's rendered panel shows disjoint "Given "/"When "/"Then " clauses (no stutter); run 2 short-circuits with `created:0, updated:0` on both ports.**
- [X] T017 [US3] Extend the existing cross-port parity test in `tests/bash/engine/test_parse_title_desc.bats` ("the PowerShell port parses identically") so its fixture specification uses the emphasised single-line form as well as the per-line form.
- [X] T017a [US3] Add a bats case asserting FR-017: a story created from the emphasised single-line form, reconciled a second time against an unchanged specification, reports **zero created and zero updated**. Implemented as `tests/bash/sink/test_us028_template_form_idempotent.bats`, driving `cmd_reconcile` twice through the mock harness against the T015 fixture (a dedicated file rather than an addition to `test_preserve_boundary.bats`: that file exercises `plan_writes`/`plan_writes_tasks` directly with a hand-built ctx, whereas FR-017 here is proven at the CLI's own run-state short-circuit — the same layer the conformance scenario exercises). The conformance corpus proves the two ports agree on the re-run; this asserts the re-run wrote nothing.

### Verification for User Story 3

- [X] T018 [US3] Run `bash tests/conformance/ci-conformance.sh`: success is **silent** — exit 0 and zero lines containing "conformance divergence"; temp-path noise is the harness. Confirm the scenario's **second** run is present in the compared output — a one-run scenario passes while proving nothing about FR-017. Do **not** run it concurrently with `tests/run-bash.sh`, which invents a spurious divergence in an unrelated scenario. **Ran standalone (no concurrent suite): exit 0, output was harness temp-path noise only, no "conformance divergence" line.**

**Checkpoint**: The two ports are pinned byte-for-byte on the template's own output.

---

## Phase 6: User Story 4 — A scenario wrapped across several lines is read whole (Priority: P2, in scope by extension)

**Goal**: A wrapped scenario — worth an empty panel on both ports today — is read as one scenario.

**Independent Test**: A three-line wrapped scenario with indented continuations yields three clauses reproducing its whole text.

**Separable**: this phase may be struck entirely without affecting US1, US2, US3 or US5.

### Tests for User Story 4 ⚠️

- [X] T019 [US4] Add failing bats cases to `tests/bash/engine/test_parse_title_desc.bats` for contract §3: a three-line scenario wrapped **inside a clause** followed by a second scenario; the existing per-line form passing through unchanged (§3's identity invariant); an **unindented** prose line immediately after a scenario **not** being joined; and — pinning FR-022 rather than fixing it — a scenario wrapped at a clause boundary, asserted to emit **nothing**, with the real shape taken from `specs/019-fix-duplicate-acceptance-criteria/spec.md:93-95`. **Only the "read whole" case actually failed pre-fix — the other three already held (fail-closed-by-default and no pre-pass yet), confirmed by direct run before implementing.**
- [X] T020 [P] [US4] Add the mirror failing cases to `tests/powershell/engine/Parse.TitleDesc.Tests.ps1`.

### Implementation for User Story 4

- [X] T021 [US4] Implement the continuation-join pre-pass in `parse_acceptance_criteria` (`scripts/bash/engine/parse.sh`) per contract §3's five conditions. Pure bash string operations — the pre-pass MUST add **no external command** (FR-021, research §R7). Note what the rule is not: the per-line loop already runs `$(_parse_trim …)` and `$(markdown_tokenize_inline …)` on every clause, and `tests/bash/helpers/spawn_count.bash` counts external processes through PATH shims, not subshells. A forked subshell is free; a `sed`, `awk`, `tr` or `jq` call is not. T027 is the measurement that decides it.
- [X] T022 [P] [US4] Mirror T021 in `Get-JiraParsedAcceptance` (`scripts/powershell/engine/Parse.psm1`), with identical continuation conditions.
- [X] T023 [US4] Add a wrapped scenario to the fixture specification at `tests/conformance/fixtures/repo-with-template-form-ac/specs/001-template-form/spec.md` and re-run `bash tests/conformance/ci-conformance.sh`. Depends on T015. **Re-ran standalone: exit 0, temp-path noise only. Manually confirmed on both ports via run-scenario.sh: run 1 creates parent+2 stories with a disjoint wrapped panel, run 2 short-circuits with 0 created/0 updated.**

**Checkpoint**: Both the single-line and the wrapped template forms reach the ticket intact.

---

## Phase 7: User Story 5 — Text that is not a scenario is still not turned into one (Priority: P2)

**Goal**: The boundary condition on every loosening above. A panel full of sentences that are not criteria
is no better than the stuttered one being fixed.

**Independent Test**: A specification containing prose that uses "given"/"when"/"then" mid-sentence produces only the intended scenarios.

### Tests for User Story 5 ⚠️

- [X] T024 [US5] Add bats cases to `tests/bash/engine/test_parse_title_desc.bats`: prose containing "given"/"when"/"then" mid-sentence yields no clause (FR-012); an absent or empty acceptance-scenario section yields `[]` with no warning (FR-014); a scenario that never reaches a Then is not emitted (FR-013).
- [X] T025 [P] [US5] Add the mirror cases to `tests/powershell/engine/Parse.TitleDesc.Tests.ps1`.

### Verification for User Story 5

- [X] T026 [US5] Re-run T024 and T025 **with the US4 join pre-pass in place**, feeding a story section that mixes scenarios with the "Why this priority" and "Independent Test" prose paragraphs a real spec.md carries — the acceptance parser is handed the whole story section, not just its scenarios subsection. Confirm no prose is joined into a clause. **All 37 bash / 36 PowerShell assertions pass; no production code required — the join pre-pass's leading-whitespace condition (§3 condition 2) already excludes these column-0 prose lines.**

**Checkpoint**: Recognition is looser where it must be and no looser anywhere else.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: The constitutional obligations that belong to no single story and are the ones most often
dropped from a story-driven task list.

- [X] T027 Confirm both `parse_acceptance_criteria` assertions in `tests/bash/engine/test_parse_spawn_budget.bats` pass **unmodified** (`bats -r tests/bash/engine/test_parse_spawn_budget.bats`). If the count moved, a command substitution has entered a per-line position (FR-021).
- [X] T028 Confirm `--dry-run` predicts the corrected panel and writes nothing (FR-019), via a **sibling** scenario `tests/conformance/scenarios/us028-template-form-ac-dry-run.json` reusing T015's fixture with `--dry-run` in the argv. Do **not** add the flag to `us028-template-form-ac.json` itself: that scenario's two real runs are FR-017's only cross-port proof (T016), and a dry run leaves nothing for a second run to settle. **Verified directly on bash via run-scenario.sh: `dry_run:true`, predicted `counts.created:3`, and `calls.log` shows only the one read (search) call — zero writes.**
- [X] T029 [P] Add the defect-fix entry to `CHANGELOG.md` (Constitution XII), naming both symptoms and the cross-port divergence.
- [X] T029a [P] Prove the two structural requirements that no story owns, by reading the feature's own diff. **FR-018**: the diff introduces no command, flag, configuration key, or output surface — it touches only `scripts/bash/engine/parse.sh`, `scripts/powershell/engine/Parse.psm1`, tests, fixtures, `CHANGELOG.md` and this spec folder; any other path is a finding. **FR-020**: `scripts/bash/sink/jira/adf.sh` and `scripts/powershell/sink/jira/Adf.psm1` are absent from the diff, and the `engine-sink-boundary` job in `.github/workflows/boundary.yml` is green — its two gates (no engine script sources or imports `sink/`; no engine script carries an Atlassian identifier) are what Constitution VIII is enforced by, and this feature must not be the first to trip them. **Confirmed: `git status --porcelain` shows only the expected paths (plus pre-existing unrelated `.specify/feature.json`/`specs/020-.../` changes not made by this feature); both boundary gates run locally against the tree exit 0 violations.**
- [X] T030 [P] Run `find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +` — must be clean. Scope it to `scripts/bash`; a whole-tree scan is ~1900 lines of unrelated host-script noise. **Clean, 0 findings.**
- [X] T031 [P] Run `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts/powershell -Recurse"` — must be clean. **Run with the repo's actual `PSScriptAnalyzerSettings.psd1` (the real CI invocation, `.github/workflows/ci.yml`) — found and fixed one real finding: `Join-JiraParseAcContinuations` (T022) violated `PSUseSingularNouns`, renamed to `Join-JiraParseAcContinuation`. 0 findings after the rename; Pester re-verified green (36/36).**
- [X] T032 Run the full suites: `tests/run-bash.sh` (~190s locally) and `pwsh -NoProfile -Command "Invoke-Pester tests/powershell -Output Detailed"`. Never pipe the bash runner, and never run it concurrently with the conformance corpus. **bash: 249 files / 2297 tests, 0 failed. Pester: 1768/1768 passed.** First run of the bash suite surfaced two pre-existing CI guards this feature's new scenarios/fixture tripped — not a regression in the fix itself, fixed as part of this task: the recorded conformance-scenario count (`test_conformance_no_cross_os_shard.bats`, 188→190) and the new fixture directory being un-staged (`test_fixtures_are_tracked.bats`, fixed with `git add -f`, never by relaxing the guard). Second run: clean.
- [ ] T033 Prove the Windows port on the real runner: push to `ci/windows-probe` (~11 min) and read the result from check-run **annotations**, not job logs. The probe's baseline on `main` is itself red — compare against that baseline, not against green. One retry maximum, then hand the result back. **NOT RUN — requires pushing to a remote branch; held for explicit operator go-ahead.**
- [X] T034 Walk the "Done when" list in `specs/028-fix-gherkin-clause-parsing/quickstart.md` end to end and tick every box. **All boxes ticked except the Windows probe (T033, held for operator go-ahead).**

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: no dependencies. T001 must precede every source edit — it is the failing-state evidence Constitution XIII and the bug-fix policy require.
- **Phase 2 (Foundational)**: depends on Phase 1. Blocks US1 and US4 (both edit the recognisers).
- **Phase 3 (US1)**: depends on Phase 2. **Blocks US2 and US3** — they assert properties of US1's change.
- **Phase 4 (US2)**: depends on US1.
- **Phase 5 (US3)**: depends on US1. T023 (US4) extends T015's fixture, so T015 precedes T023. T017a depends on T015's fixture only, not on T016, and may run beside it.
- **Phase 6 (US4)**: depends on Phase 2; independent of US2 and US3 except for T023's fixture dependency on T015.
- **Phase 7 (US5)**: T024/T025 depend on US1; T026 additionally depends on US4.
- **Phase 8 (Polish)**: depends on every story that is being shipped.

### User Story Dependencies

Unlike the template's default, these stories are **not** mutually independent, and pretending otherwise
would produce a task list that cannot be executed:

- **US1 (P1)** — carries the single production change. Independently testable and shippable alone.
- **US2 (P1)** — verification over US1's change. Not independently implementable; independently *testable*.
- **US3 (P1)** — cross-port and corpus proof of US1's change. Same relationship.
- **US4 (P2)** — genuinely independent production change (the join pre-pass). Strikeable.
- **US5 (P2)** — boundary condition over US1 and US4. Must not ship after them.

### Within Each Story

Tests are written and confirmed failing before implementation, in both ports, without exception.

### Parallel Opportunities

- T003 ‖ T004 — one file per port
- T005 ‖ T006, T012 ‖ T013, T019 ‖ T020, T024 ‖ T025 — bats file and Pester file are distinct
- T009 ‖ T010 — bash source and PowerShell source are distinct, though the design must match exactly
- T021 ‖ T022 — same
- T029 ‖ T029a ‖ T030 ‖ T031 — CHANGELOG, the diff review, shellcheck and PSScriptAnalyzer touch nothing in common

Tasks touching `tests/bash/engine/test_parse_title_desc.bats` (T005, T012, T017, T019, T024) are **not**
parallel with one another: same file.

---

## Parallel Example: User Story 1

```bash
# Failing tests, one per port, in parallel:
Task: "T005 — bats cases for contract §4 rows 1,2,5,6,9 and rule T3 in tests/bash/engine/test_parse_title_desc.bats"
Task: "T006 — mirror Pester cases in tests/powershell/engine/Parse.TitleDesc.Tests.ps1"

# Then the two ports' implementations, in parallel:
Task: "T009 — pattern T2 + fail-closed T3 in scripts/bash/engine/parse.sh"
Task: "T010 — mirror, greedy fallback, in scripts/powershell/engine/Parse.psm1"
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1 — measure both failures and the green baseline
2. Phase 2 — hoist the wrapper token
3. Phase 3 — failing tests, then the symmetric wrapper and the fail-closed fallback, both ports
4. **STOP and VALIDATE**: the reporter's line yields three disjoint unstuttered clauses on both ports

That alone closes both reported symptoms. It is a defensible ship on its own, though US3's conformance
fixture is what stops the same class of divergence recurring.

### Incremental Delivery

1. MVP (US1) → both reported symptoms gone
2. + US2 → the stutter is impossible on every form
3. + US3 → the ports are pinned byte-for-byte and the corpus gap is closed
4. + US4 → wrapped scenarios read whole *(strikeable — the one piece of scope beyond the report)*
5. + US5 → the boundary condition holds; **must not lag behind US4**
6. + Phase 8 → CHANGELOG, linters, spawn budget, dry-run, Windows

### Solo Strategy

The realistic order is strictly sequential: Phase 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8, taking the per-port `[P]`
pairs together. There is no useful team fan-out here — the whole feature is one function per port.

---

## Notes

- Verify every test fails before implementing it away. For the Windows-only surface, the conformance corpus on the probe **is** the failing test.
- `bats` needs `-r` or it silently runs nothing.
- Never run `tests/run-bash.sh` and the conformance corpus concurrently — shared fixtures invent a divergence in an unrelated scenario.
- No repair, migration, or detection of already-corrupted stories: the reporter is the extension's only user and declined it (spec.md, Clarified scope).
- The renderer stays untouched throughout. If a fix seems to need `sink/jira/adf.sh`, re-read research §R4 first.
