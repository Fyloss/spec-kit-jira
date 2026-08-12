---

description: "Task list for 025 — The Process Budget Outlives the Feature That Measured It"
---

# Tasks: The Process Budget Outlives the Feature That Measured It

**Input**: Design documents from `/specs/025-spawn-budget-guardrails/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: REQUIRED, not optional. Constitution XIII mandates TDD, and contracts
`whole-run-budget.md` §5 and `argument-size.md` §5 both require the assertion to be observed **red**
before it is accepted. For a regression guard written against already-correct code, "failing test
first" means: write the assertion, introduce the defect deliberately, observe red, revert, observe
green. Those are separate, explicit tasks below — skipping the red step leaves an assertion nobody
has ever seen fail, which is indistinguishable from an assertion that cannot fail.

**Organization**: grouped by user story. US1, US2 and US3 are fully independent — none consumes
another's output.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependencies)
- **[Story]**: US1, US2, US3
- Exact file paths included

## Path Conventions

Repository root. Two ports under `scripts/bash/` and `scripts/powershell/`; contributor
documentation under `docs/`; Bash tests under `tests/bash/`. **No file under `scripts/` is modified
by this feature** — that is what makes SC-007 true by construction.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: capture the baseline this feature must not disturb.

- [X] T001 Record the pre-change baseline by running `tests/run-bash.sh` and
  `bash tests/conformance/ci-conformance.sh`, and paste the two summary lines into the Verification
  Log at the bottom of `specs/025-spawn-budget-guardrails/tasks.md`. Conformance success is
  **silent** — expect exit 0 and zero `conformance divergence` lines, not a pass banner; the temp
  paths it prints are harness noise.
> The scenario-floor measurement that used to sit here as T002 is now **T004b**, in Phase 2. It
> could not be performed here: the scenario whose floor it claimed to record is created by T004,
> two phases later. There is no T002.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the one piece of test infrastructure both US2 and US3 need — a specification of *N*
stories whose binding state and task count are parameters — and the measurement that proves the
scenario built on it actually holds the request count constant.

**⚠️ CRITICAL**: T004 blocks US2 and US3. US1 does not depend on it and may start immediately.

- [X] T003 Add the self-test FIRST: `tests/bash/ci/test_spec_fixture_helper.bats`, asserting that a
  `bound` document parses to the expected story count with every story recognised, an `unbound` one
  to the same count with none recognised, and that the task count is `story-count ×
  tasks-per-story`. Observe it **red** against the absent helper before writing T004 — a fixture
  generator that silently emits unrecognised markers, or the wrong number of tasks, would make US2's
  whole scenario measure the wrong thing while still looking green. It goes in `tests/bash/ci/`
  where the four existing helper self-tests already live; a `.bats` file under
  `tests/bash/helpers/` would additionally force `--since` to fail open to a FULL run on every edit
  to itself (`tests/run-bash.sh:125`).
- [X] T004 Add `helper_make_spec <dir> <story-count> <bound|unbound> [tasks-per-story]` to a new
  `tests/bash/helpers/spec_fixture.bash`, writing `<dir>/spec.md` and — when `tasks-per-story` is
  non-zero — `<dir>/tasks.md`. Each story carries the Given/When/Then triple that makes its rendered
  payload realistic. Under `bound`, each story also carries its
  `<!-- speckit-jira story=… ticket=… -->` marker line so the run recognises it instead of creating
  it. Model the document shape on `_write_large_spec` in
  `tests/bash/commands/test_reconcile_large_spec.bats`, which is the proven generator this replaces.
  Turn T003 green.
- [X] T004b Measure the premise **before** T011 depends on it. Using `helper_make_spec` from T004
  and `tests/bash/helpers/spawn_count.bash`, drive `cmd_reconcile … --force` against the mock at 10
  stories × 3 tasks and at 20 stories × 6 tasks with `task_mirror: checklist`, and record in the
  Verification Log in `specs/025-spawn-budget-guardrails/tasks.md`: the Jira request count of each
  run, the total spawn count of each, and whether either run emitted a write. T011–T013 assume all
  three rather than establish them. **Both runs MUST issue the same number of requests and MUST
  emit zero writes.** If the request counts differ, the constant-request scenario does not hold and
  US2 has no assertion — stop and re-open research R1 rather than loosening T013. If a bound,
  unchanged, checklist-carrying story reads as drift and emits a write, fall back to
  `tasks-per-story 0`, and record in `spec.md` that the task loops stay uncovered together with the
  reason. Recording the two spawn counts here also makes any later drift attributable.

**Checkpoint**: the parameterised fixture exists, is trusted, and its request-count premise is
measured rather than assumed; US3 can begin. **US2 is blocked — see T004b's result and
research.md R5/D7.**

---

## Phase 3: User Story 1 - The rule is stated once, durably, and carries its companion (Priority: P1) 🎯 MVP

**Goal**: a contributor about to write a loop on the reconcile path finds the process-budget rule —
and its inseparable argument-routing companion — from context that loads automatically.

**Independent Test**: with only `AGENTS.md` and what it points at, a reader can state both halves of
the rule and reach the authoritative text without opening any `specs/` folder.

### Tests for User Story 1

> Written FIRST. T005 fails until T006 and T007 exist.

- [X] T005 [US1] Add `tests/bash/ci/test_process_budget_doc.bats` asserting that
  `docs/11-process-budget.md` exists, that `AGENTS.md` references it by path, and that the document
  names both halves of the rule (a per-item process prohibition **and** the argument-routing
  requirement) plus the `128` KiB figure. This guards discoverability and link rot mechanically; it
  deliberately does **not** claim to prove readability, which quickstart §1 verifies by inspection.

### Implementation for User Story 1

- [X] T006 [US1] Write `docs/11-process-budget.md` as the authoritative rule. It MUST carry: the
  budget itself (promoted from feature 024's `contracts/spawn-budget.md` clauses C1.1–C1.5); the
  measured evidence that motivated it (154 942 ms → 17 117 ms on the maintainer's machine, and
  20 243 → 13 057 spawns on the 61-item reference); the batching rule and the argument-routing rule
  stated as **one inseparable rule** with the 128 KiB `MAX_ARG_STRLEN` figure and its distinction
  from `ARG_MAX`; and the reintroduction history (fixed at five sites by PR #31, reintroduced at
  three more by feature 024's own consolidation work) — because a rule stated without its history
  invites a future reader to simplify it back into the trap (FR-003, FR-004). When promoting C1.4,
  keep it stated as the **per-phase** claim it is, and add the whole-run corollary from contract
  W1.3.1: over a whole run the zero-item floor is bounded above by the populated run's count, not
  equal to it, because prefetch issues nothing on zero keys (`prefetch.sh:46`).
- [X] T007 [US1] Add a "Process budget — non-negotiable" section to `AGENTS.md`, mirroring the shape
  of the existing "Windows portability — non-negotiable" section: a short summary of the two halves
  of the rule, then a pointer to `docs/11-process-budget.md` for the full text (FR-002).
- [X] T008 [US1] Record the PowerShell port's honest position in `docs/11-process-budget.md`: it
  creates no external process per item by construction (024 research R7), so the Bash port's
  assertion would pass there vacuously. State that its protection is **structural, not tested**,
  rather than implying symmetric coverage (contract W4.2).
- [X] T009 [US1] Add a header line to
  `specs/024-reconcile-local-performance/contracts/spawn-budget.md` naming
  `docs/11-process-budget.md` as the current authority and marking itself the historical record of
  how the budget was derived and measured. Change **nothing else in that file** — FR-005 requires
  its measurements to survive intact.
- [X] T010 [US1] Verify T009 was surgical by running
  `git diff main -- specs/024-reconcile-local-performance/contracts/spawn-budget.md` and confirming
  the diff is additive only, then record the line count in the Verification Log in
  `specs/025-spawn-budget-guardrails/tasks.md`.

**Checkpoint**: US1 is complete and independently shippable. The rule is discoverable and whole even
if US2 and US3 are never built.

---

## Phase 4: User Story 2 - A newly-added per-item loop fails before it merges (Priority: P2)

> **BLOCKED — not built this session.** T004b measured the premise this phase depends on and found
> whole-run C1.2 does not hold today, on two independent non-constant sources: `plan_writes`
> (accepted debt, 024 T030) and `tasks_parse_document` (newly found, undocumented until now). Both
> are production code under `scripts/`; fixing either is out of this feature's own scope (SC-007).
> A single-function subtraction was drafted and rejected — see research.md R5/D7 for the full
> measurement and the rejected alternatives. T011–T017 below are left unchecked and unbuilt,
> deliberately, rather than shipped against a premise known not to hold. Unblocking this phase is a
> maintainer decision: charter a fix to one or both functions first.

**Goal**: lift clause C1.2 from the four named functions that assert it today to the whole run.

**Independent Test**: introduce a deliberate per-item fork into a reconcile-path function that has no
dedicated spawn test today; the suite fails naming the growth; remove it; the suite passes.

### Tests for User Story 2

> **The premise is asserted before the budget.** Order matters — see contract `whole-run-budget.md` §2.

- [ ] T011 [US2] Add `tests/bash/commands/test_reconcile_run_budget.bats` driving a whole
  `cmd_reconcile … --force` run against the mock, using `helper_make_spec … bound` from T004 at
  10 stories × 3 tasks and at 20 stories × 6 tasks — doubling stories, tasks and
  acceptance-criteria scenarios together, which is what US2 AC1, SC-002 and 024's V2 all ask for.
  The run's config MUST set `task_mirror: checklist`: in that mode a story's tasks are rendered
  into its description in-process (`adf_checklist_digest`, `plan_apply.sh:390`) and cost no
  request, so doubling tasks adds per-item local work without disturbing the constant-request
  premise. Any other mode turns each task into an issue to create, requests grow with tasks, and
  T012 correctly reports a broken premise. Model the in-process driver on
  `tests/bash/commands/test_reconcile_large_spec.bats` (sources `reconcile.sh`, starts the mock,
  calls `cmd_reconcile` directly). `--force` is required so the unchanged-state short-circuit does
  not skip the run entirely.
- [ ] T012 [US2] In that file, assert the **premise first**: both runs issued the same number of Jira
  requests. On failure it MUST report "the scenario no longer holds the request count constant",
  never a budget breach — the two have different causes and different fixes (contract W2.2).
- [ ] T013 [US2] Then assert the budget: the total process count from
  `helper_spawn_count_total` is **equal** between the 10-story and 20-story runs, with no expected
  total written into the test (contract W1.1, W1.2; FR-012).
- [ ] T014 [US2] Add the zero-item floor case to the same file: a specification with no stories
  reaches a defined floor no greater than the populated case's count (contract W1.3; FR-010).

### Implementation for User Story 2

> No production code. The "implementation" of a regression guard is proving it can fail.

- [ ] T015 [US2] **Observe RED.** Temporarily add a per-item fork (e.g. `jq -n 'null' > /dev/null`)
  inside `plan_writes`' per-story loop in `scripts/bash/sink/jira/plan_apply.sh` — chosen because it
  has **no dedicated spawn test of its own** and is deliberately still unoptimised (024 T030), so it
  is exactly the code this assertion exists to catch (contract W5.1, W5.2). Run
  `bats tests/bash/commands/test_reconcile_run_budget.bats`, confirm it fails and that the failure
  names the growth, and record both counts in the Verification Log in
  `specs/025-spawn-budget-guardrails/tasks.md`.
- [ ] T016 [US2] Revert the T015 edit to `scripts/bash/sink/jira/plan_apply.sh` and confirm the test
  passes. Verify with `git diff main -- scripts/` that the file is byte-identical to `main` — the
  deliberate defect must leave no trace.
- [ ] T017 [US2] Confirm host independence: re-run
  `bats tests/bash/commands/test_reconcile_run_budget.bats` under artificial CPU load (a
  `yes > /dev/null` per core) and confirm the verdict is unchanged and only the duration differs
  (FR-013, SC-005). Record in the Verification Log in `specs/025-spawn-budget-guardrails/tasks.md`.

**Checkpoint**: a per-item loop added anywhere the run reaches now fails the suite, including in
functions nobody thought to test.

---

## Phase 5: User Story 3 - A batched payload that would die on Linux is caught wherever it is introduced (Priority: P3)

**Goal**: make the oversized-argument defect visible on the machine where the work happens. Today
`test_reconcile_large_spec.bats` says in its own header that it "passes on macOS whether or not the
defect is present" — the maintainer's own host gets no signal, which is why the defect reached CI
three times.

**Independent Test**: route an oversized value through a single argument at a call site other than
the one already covered, and observe the suite fail **on macOS**.

### Tests for User Story 3

- [X] T018 [P] [US3] Add `tests/bash/helpers/argv_size.bash` providing
  `helper_argv_size_setup <shim_dir> <report_file>`: a shim ahead of `jq` on `PATH` that measures the
  byte length of each element of `$@`, appends any element exceeding **131072** bytes (Linux
  `MAX_ARG_STRLEN`) to the report file, then `exec`s the real tool with stdout, stderr and exit code
  passing through untouched. Resolve the real tool **before** prepending the shim directory, exactly
  as `tests/bash/helpers/spawn_count.bash` does, so the shim never recurses into itself.
- [X] T018b [P] [US3] Add `tests/bash/ci/test_argv_size_helper.bats`, the shim's own self-test,
  alongside the existing `test_spawn_count_helper.bats`. Assert that an argument of 131073 bytes is
  recorded in the report file, that one of 131071 bytes is not, that the boundary value 131072 is
  not (the limit is 32 pages inclusive), and that the shimmed tool's stdout, stderr and exit code
  pass through untouched. Without this, T019's "the report file is empty" is satisfied equally by a
  correct run and by a shim that never fired — wrong PATH order, wrong report path, or a
  non-executable shim all produce an empty file. T021 is a *temporary* defect that gets reverted;
  after merge, nothing else keeps this instrument alive. An assertion whose only proof-of-life was
  reverted is the exact failure mode this feature exists to close.
  **Two clauses of this task were wrong and are superseded by T039**: the boundary value 131072 IS
  fatal and must be recorded ("the limit is 32 pages inclusive" was the right words attached to the
  wrong comparison, A2.4), and no boundary case can be asserted through `PATH` at all, because Linux
  refuses to deliver such an argument to any process (A2.5).
- [X] T019 [US3] Add `tests/bash/sink/test_argv_size.bats` running a whole reconcile over a large
  **unbound** specification (`helper_make_spec … unbound` at 100 stories, the size that assembles a
  ~140 KB plan) under T018's shim, asserting the report file is empty. The threshold is applied on
  every host regardless of the host's own limit — that is the point (contract A3.1, A3.2).
- [X] T020 [US3] Document in the header of `tests/bash/sink/test_argv_size.bats` why it measures
  argument length rather than `exec` failure, citing that the symptom-detecting test it complements
  cannot fail on macOS (contract A3.3).

### Implementation for User Story 3

- [X] T021 [US3] **Observe RED on macOS.** Temporarily revert one `json_build` call site — **deviation
  recorded**: `scripts/bash/engine/tasks_parse.sh:273` (its `tasks` array), not
  `scripts/bash/sink/jira/plan_apply.sh` as originally written. The only `plan_apply.sh` site large
  enough to cross 128 KiB at reachable scale is `plan_writes`' own `_plan` assembly — the exact one
  `test_reconcile_large_spec.bats` already exercises, so it fails "a site other than" in the same
  sentence. `tasks_parse.sh`'s call is independently documented as the same defect class (its own
  comment: "the same class of defect research/#31 first fixed, at different call sites") and is
  covered by the second `@test` in `tests/bash/sink/test_argv_size.bats`, added for this purpose.
  Reverted to pass its payload via `--argjson`. Ran `bats tests/bash/sink/test_argv_size.bats` **on
  the development host (macOS)**: confirmed it fails — the untouched first `@test` (the
  `plan_apply.sh` site) stayed green, the second (`tasks_parse.sh`) failed, correctly isolating the
  defect to the site actually touched (A5.1, A5.2). Offending argument's byte length recorded in the
  Verification Log.
- [X] T022 [US3] Revert the T021 edit to `scripts/bash/engine/tasks_parse.sh`, confirm the test
  passes, and verify with `git diff main -- scripts/` that the file is byte-identical to `main`.
- [X] T023 [US3] Confirm the two tests are complementary rather than redundant by running both
  `bats tests/bash/sink/test_argv_size.bats` and
  `bats tests/bash/commands/test_reconcile_large_spec.bats` green, and record in the Verification Log
  in `specs/025-spawn-budget-guardrails/tasks.md` that the pre-existing test remains the end-to-end
  proof on Linux while the new one is the portable cause-detector.

**Checkpoint**: the batching trap is now caught at every call site a run reaches, on every host.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T024 Run the full Bash suite via `tests/run-bash.sh` and confirm it is green, comparing the
  file and test counts against T001's baseline recorded in the Verification Log in
  `specs/025-spawn-budget-guardrails/tasks.md`.
- [X] T025 [P] Run `bash tests/conformance/ci-conformance.sh` and confirm exit 0 with zero
  `conformance divergence` lines — SC-007's byte-identical requirement.
- [X] T026 [P] Run `shellcheck` over the Bash port using the CI-scoped command
  (`find scripts/bash … -exec shellcheck -x -P scripts/bash`) and confirm it is clean. A whole-tree
  scan is ~1900 lines of unrelated host-script noise and is not the gate.
- [X] T027 Verify the feature stayed inside its own scope: `git diff --stat main -- scripts/` MUST be
  **empty**. A non-empty result means production code changed and SC-007 no longer holds by
  construction. Record the result in the Verification Log in
  `specs/025-spawn-budget-guardrails/tasks.md`.
- [X] T028 [P] Add a `### Changed` entry under `[Unreleased]` in `CHANGELOG.md` noting that the
  process budget is now enforced over a whole run and documented durably. Keep it brief and
  contributor-facing: precedent for internal tooling in this changelog is 0.9.0's `tests/run-bash.sh`
  and CI-caching entries.
- [X] T029 Walk `specs/025-spawn-budget-guardrails/quickstart.md` end to end and confirm every stated
  check behaves as written, correcting the quickstart where reality differs rather than the reverse.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: T004 blocks US2 and US3. **US1 is not blocked by it.**
- **US1 (Phase 3)**: independent of everything. Shippable alone — this is the MVP.
- **US2 (Phase 4)**: needs T004.
- **US3 (Phase 5)**: needs T004.
- **Polish (Phase 6)**: after whichever stories are taken.

### User Story Dependencies

- **US1 (P1)**: no dependencies on any other story. Pure documentation.
- **US2 (P2)**: depends on T004 only. Does not consume US1 or US3.
- **US3 (P3)**: depends on T004 only. Uses the same generator as US2 but in a different **mode** —
  `unbound` at 100 stories, where US2 uses `bound` with tasks — and that is what keeps the two
  independent: neither consumes the other's output, and neither's scenario constrains the other's.

### Within Each Story

- The assertion is written before the deliberate defect that proves it can fail.
- The RED observation (T015, T021) is a task in its own right, not a step inside another task — an
  assertion nobody has seen fail is indistinguishable from one that cannot fail.
- Every deliberate defect is reverted and verified byte-identical against `main` in the very next
  task.

### Parallel Opportunities

- **US1 can proceed in parallel with Phase 2 entirely** — it touches only `docs/`, `AGENTS.md` and
  024's contract file.
- Once T003/T004 land, US2 and US3 can proceed in parallel: they share no file.
- T018 and T018b are marked [P] — a new helper file and its own self-test, touched by nothing else.
- T025, T026 and T028 are mutually independent.

---

## Parallel Example: after Foundational completes

```bash
# Different files, no shared state — safe to run concurrently:
Task: "T011 whole-run budget test in tests/bash/commands/test_reconcile_run_budget.bats"
Task: "T018 argument-size shim in tests/bash/helpers/argv_size.bash"
```

**Never run the two RED-observation tasks (T015, T021) concurrently.** Both temporarily edit
`scripts/bash/sink/jira/plan_apply.sh`; running them together would leave two deliberate defects in
one file and make each test's verdict unattributable.

**Never run two full suites concurrently.** They share conformance fixtures, and a concurrent pair
produces spurious cross-test failures that cost more to diagnose than the parallelism saves.

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 (T001).
2. Phase 3 (T005–T010) — skipping Phase 2 entirely, which US1 does not need.
3. **STOP and VALIDATE**: quickstart §1. The rule is now discoverable and whole.

US1 alone delivers the thing that was paid for twice: the batching rule and its argument-routing
companion, written down together, where an agent will actually encounter them.

### Incremental Delivery

1. Setup → US1 → ship (the rule exists and is found).
2. Foundational → US2 → ship (a new per-item loop now fails the suite).
3. US3 → ship (the batching trap is caught on every host, not only Linux CI).

Each increment stands alone; none breaks a previous one.

---

## Verification Log

Append measured results here as tasks complete. Counting runs and timing runs are separate runs —
the counting shim distorts wall clock by ~61%, so **never read a duration from a counted run**.

| Task | What was measured | Result |
| --- | --- | --- |
| T001 | baseline suite + conformance | run-bash.sh: 200 files, 1899 tests, 1 pre-existing failure (test_fixtures_are_tracked.bats — repo-with-reconcile-binding/.specify/jira/state/{.gitignore,large.json} untracked; confirmed present on `main` via `git diff main`, unrelated to this feature). conformance: exit 0, zero divergence lines (silent success). |
| T004b | request counts, spawn counts and write counts at 10×3 vs 20×6 | requests: 1==1 (equal, premise holds); writes: 0==0 (zero, holds); spawns: 2381 vs 5091 (10x3) and 1826 vs 3276 (10x0 vs 20x0 tasks) — NOT equal on two independent, non-constant sources (`plan_writes`, `tasks_parse_document`). **US2 blocked** — see research.md R5/D7. |
| T010 | 024 contract diff is additive only | 4 insertions(+), 0 deletions(-) — header line only |
| T015 | RED: counts at 10 vs 20 stories with a deliberate fork | *(pending)* |
| T016 | `plan_apply.sh` byte-identical to `main` after revert | *(pending)* |
| T017 | verdict under CPU load | *(pending)* |
| T018b | shim self-test: 131071 / 131072 / 131073-byte boundary cases | 7/7 green: 131073B recorded, 131071B and the 131072B boundary not recorded (limit is 32 pages inclusive), stdout/stderr/exit code pass through untouched, unfired shim leaves report empty. **Two of those results were wrong — superseded by T039**: 131072B must be recorded, and the boundary cases were measured through `PATH`, which only macOS permits. |
| T039 | Linux's real boundary, on the Ubuntu runner | 131071B execs; 131072B and 131073B both fail `execve` with "Argument list too long" (exit 126). The limit is inclusive → threshold corrected from `> 131072` to `>= 131072` (A2.4), and a boundary case can only be measured in-process (A2.5). |
| T039 | RED on macOS before the fix | boundary assertion inverted to "131072B IS recorded" failed against the shipped `-gt` comparison with all 11 other assertions in the file green — defect isolated to the comparison alone. |
| T039 | guard after the fix | `bats tests/bash/ci/test_argv_size_helper.bats` 12/12, exit 0, no bats warnings. `bats -r tests/bash/ci` (the failing CI step) 162/162, exit 0. `bats tests/bash/sink/test_argv_size.bats` 2/2 green under the stricter threshold — no live call site sits on the boundary. `shellcheck -x` clean on both helper files. |
| T039 | `test_fixtures_are_tracked.bats` — the failure T001/T024/T038 all logged as pre-existing | not a repository defect: the port writes a self-ignoring `state/.gitignore` (`*`) plus one state file per local sink run inside the fixture tree, and the guard walks every file under `tests/conformance/fixtures` demanding it be tracked. Both artefacts trashed → guard green, `bats -r tests/bash/ci` 162/162. It returns after any local run of `tests/bash/sink/test_argv_size.bats`; CI never sees it (fresh checkout). |
| T024 | full suite post-change vs T001 baseline | run-bash.sh: 204 files, 1918 tests, 1 file failed — +4 files (the four this feature adds) and +19 tests against T001's 200/1899; same single pre-existing failure (`test_fixtures_are_tracked.bats`), unrelated to this feature |
| T021 | RED on macOS: offending argument length | 427485 bytes (tasks_parse.sh's `tasks` array, 700 tasks, --argjson reverted) — shim reported it, test 2 failed, test 1 (untouched call site) stayed green |
| T022 | `scripts/` byte-identical to `main` after revert (engine/tasks_parse.sh, not plan_apply.sh — see T021's site choice) | `git diff main -- scripts/` empty |
| T023 | both argument tests green, roles distinguished | test_argv_size.bats (2 cases) + test_reconcile_large_spec.bats all green after revert; the pre-existing test remains the Linux end-to-end proof, the new one is the portable cause-detector |
| T027 | `git diff --stat main -- scripts/` empty | empty output, confirmed — no production file touched by this feature |

---

## Notes

- **No production code changes.** Every task that touches `scripts/` is a deliberate, temporary
  defect immediately reverted and verified byte-identical against `main` (T016, T022, T027).
- The counting shim measures the mock as well as the port — the mock's `curl` replacement runs `jq`
  52 times. US2's scenario holds the request count constant precisely so that contribution stays
  flat; do not "simplify" it into excluding `curl`, which does not work (contract W3.1, research R1).
- The PowerShell port is deliberately not given an equivalent assertion: it would pass vacuously.
  T008 records that honestly instead of implying coverage that does not exist.

---

## Phase 7: Convergence

Appended by `/speckit-converge`. Every item below is a measured gap between what `spec.md`,
`plan.md` and `contracts/` call for and what the tree currently contains — not a change of scope.
The measurements cited were taken this session against the working tree.

- [X] T030 **CRITICAL** — Record the two measured live `argv` sites in `docs/11-process-budget.md`
  as known, open gaps, and charter their fix separately per Constitution VI (contradicts).
  A probe over the same 100-story unbound run `tests/bash/sink/test_argv_size.bats` drives found
  two reconcile-path sites passing an input-growing payload through a single `argv` element:
  `scripts/bash/engine/parse.sh:680` (`--argjson st`, the whole stories array) at **66 369** and
  **71 257** bytes across its two invocations, and `scripts/bash/engine/interchange.sh:154`
  (`--argjson parse`, the whole parse result) at **71 542** bytes — 54.6% of `MAX_ARG_STRLEN`.
  Both grow linearly with story count: ≈183 stories crosses 131 072 at this fixture's story size,
  and materially fewer with realistically-sized stories (the 61-item reference spec is already the
  same order). This is the exact defect class A1.2 forbids, live in the tree, on Linux only.
  **Fixing them is production work under `scripts/`, which SC-007 forbids this feature** — so the
  in-scope deliverable is the honest record plus a charter note, in the same shape research.md R5
  uses for US2. Do **not** edit `scripts/` under this task.
- [X] T031 Correct the "Where the assertions live" section of `docs/11-process-budget.md` per FR-001
  (contradicts). It currently states that `tests/bash/commands/test_reconcile_run_budget.bats`
  "drives a full `cmd_reconcile … --force` at two item counts and asserts the total is unchanged".
  That file does not exist — US2 is blocked (research.md R5/D7) and `quickstart.md` §2 says so.
  The one document the feature designates authoritative must not claim coverage the tree lacks;
  state the whole-run assertion as **specified but not built**, with the pointer to R5.
- [X] T032 Record the measured whole-run non-compliance in `docs/11-process-budget.md` per FR-004
  (contradicts). "Half one" currently reads "and, since feature 025, over a whole run: doubling the
  item count must leave the total process count unchanged" — T004b measured 2381 vs 5091 spawns at
  10×3 vs 20×6, so the property does not hold today. Name the two sources R5 isolated
  (`plan_writes`' UPDATE-branch payload construction, and `tasks_parse_document` at ~6 spawns/task).
  FR-004 exists so a future reader can weigh the rule; a rule presented as already enforced when it
  is not is the same trap in the other direction.
- [~] T033 **Deferred by maintainer decision (2026-08-12).** Add a max-argument-length
  **differential** to `tests/bash/sink/test_argv_size.bats` per FR-011 and FR-012 (partial). The
  test asserts an absolute threshold at one fixed size, so it is structurally blind to T030's
  finding: a payload that grows with input but stays under 128 KiB at 100 stories passes. Extend
  `tests/bash/helpers/argv_size.bash` to also record the **largest** argument seen (not only
  breaches), then assert the maximum does not grow between *N* and 2*N* — the same differential
  shape FR-012 already mandates for spawn counts, applied to the quantity A1.2 governs. Written
  against today's code this assertion is **red** (it is what would have caught T030). Maintainer
  explicitly declined to land a deliberately-red test into the suite. Not built this session — the
  two known gaps stay documented in `docs/11-process-budget.md` (T030) without a mechanical
  assertion behind them. Revisit if/when T030's charter decision is made.
- [X] T034 **Maintainer decision (2026-08-12): record the deferral, do not charter a production
  fix.** Reconciled FR-006–FR-010's MUST wording with the measured blocked status by adding a
  status note in `spec.md` directly under FR-010, naming the two non-constant sources and pointing
  to US2's status note and `research.md` R5/D7. No production fix chartered — the reconcile path is
  fast and working today; a `scripts/` change is out of this feature's scope.
- [X] T035 Widen `tests/bash/helpers/argv_size.bash` to the tool set it says it mirrors, per A3.4
  (partial). It shims `jq` alone; `tests/bash/helpers/spawn_count.bash:22` shims `jq sed awk curl`.
  Verified this session that there is **no live gap** — the port has no `awk -v`, no `curl --data`,
  and curl bodies travel through a stdin config referencing a temp file — so this is future-proofing,
  not a fix. It matters because an instrument scoped to one remembered tool is the precise shape
  this feature was written to eliminate at the function level. Widened `helper_argv_size_setup` to
  shim `jq sed awk curl` (same loop shape as `spawn_count.bash`); existing self-test and
  `test_argv_size.bats` both re-run green after the change.
- [X] T036 Observe `@test 1` of `tests/bash/sink/test_argv_size.bats` **red** at its own call site
  per A5.1 (partial). T021's red observation was relocated to `tasks_parse.sh`, so `@test 2` has
  proof-of-life and `@test 1` has none; its measured headroom is 71 542 of 131 072 bytes. Introduced
  a deliberate oversized `argv` route in `plan_writes`' `_plan` assembly (`plan_apply.sh:583`,
  reverted the `json_build` call to `jq -cn --argjson s "${stories}" …`). `@test 1` failed alone,
  `@test 2` (untouched `tasks_parse.sh` site) stayed green, correctly isolating the defect. Reverted;
  `git diff main -- scripts/` empty; both tests green again.
- [X] T037 Extend `tests/bash/ci/test_process_budget_doc.bats` to assert that every repository path
  `docs/11-process-budget.md` names actually exists, per FR-001 (partial). The test guards
  `AGENTS.md` → document today but not the document's outbound references, which is exactly the link
  rot that produced T031's finding. Excludes the one documented deliberate exception
  (`tests/bash/commands/test_reconcile_run_budget.bats`, US2 blocked). All 6 assertions green.
- [X] T038 Complete the Verification Log rows left open (partial). Re-measured after T033-T037's
  own edits (one added test in `test_process_budget_doc.bats`): `tests/run-bash.sh` → **204 files,
  1918 tests, 1 file failed** — +4 files and +19 tests against T001's 200/1899 baseline, same single
  pre-existing failure (`test_fixtures_are_tracked.bats`, unrelated to this feature). T018b and T024
  rows completed in the Verification Log.
- [X] T039 **Ubuntu CI red on `tests/bash/ci/test_argv_size_helper.bats`** — two defects, one root
  cause, both found by the runner rather than by the development host, which is the same platform
  blindness this contract is about (A2.3, A2.5).
  1. **The threshold was off by one, under-detecting.** `> 131072` waves through an argument of
     exactly 131072 bytes, which Linux already refuses: `MAX_ARG_STRLEN` bounds the search for the
     terminating NUL, so a string that fills the limit has no room for it. Recorded as A2.4 with the
     runner's measurement (131071 execs, 131072 and 131073 do not) and corrected to `>= 131072`.
     Observed **red on macOS** first — the boundary assertion inverted to "IS recorded" failed
     against the shipped comparison, with every other assertion in the file green, isolating the
     defect to the comparison alone.
  2. **The guard asserted its boundary cases through `PATH`**, i.e. by exec'ing the shim with the
     oversized value. On Linux the kernel kills that `execve` before any of our code runs (exit 126,
     "Argument list too long") — so those two assertions could only ever pass on macOS. Recorded as
     A2.5. The measurement now lives in `tests/bash/helpers/argv_size_measure.sh`, which the shim
     **sources** rather than execs, so the same file and the same comparison can be exercised
     in-process by the guard with no `execve` carrying the value.
  Proof-of-life for the interposition itself is kept, and strengthened, by a separate half of the
  guard that fires the shim through `PATH` at a lowered limit — proving PATH order, the exec bit and
  the report path with an argument every host can deliver — plus a new case covering all four shimmed
  tools (T035 widened the tool set; nothing asserted the other three fired) and one proving a shim
  with no report path fails loudly instead of silently empty. `helper_argv_size_setup` takes the
  limit as an optional third argument for that purpose only; assertions about the code under test
  leave it at `HELPER_ARGV_SIZE_LIMIT`. No `scripts/` file touched.
