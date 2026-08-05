---

description: "Task list for 018 — Cut CI Wall-Clock to a 20-Minute Merge Decision"
---

# Tasks: Cut CI Wall-Clock to a 20-Minute Merge Decision

**Input**: Design documents from `/specs/018-optimize-ci-wall-clock/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: **REQUIRED, not optional.** Constitution XIII makes Red-Green-Refactor
non-negotiable and forbids planning an implementation task without its test task
before it. For this feature the "unit under test" is the pipeline itself, so the
tests are meta-tests under `tests/bash/ci/` asserting properties of the runners
and the workflow files — the pattern this repository already uses
(`test_workflow_bash_runner.bats`, `test_coverage_runner_bounds.bats`,
`test_conformance_no_cross_os_shard.bats`). For Windows-only behaviour,
Constitution VI says the conformance corpus **on the real runner** is that
failing test, because no other host can reproduce it.

**Organization**: grouped by user story. All four stories are P1 in spec.md;
they are ordered here by dependency, not by importance.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on incomplete work)
- **[Story]**: US1–US4 from spec.md
- Every task names its exact file path

## Path Conventions

Repository root. This feature touches `tests/`, `.github/workflows/`, `docs/`,
`AGENTS.md`, `specs/018-optimize-ci-wall-clock/` and — for T052's closure of
009's open tasks — `specs/009-optimize-test-performance/tasks.md`.

`scripts/bash/**` and `scripts/powershell/**` are frozen (FR-020). Exactly one
task can write there: **T025 option (b)**, and only if the user chose it at T015
and the FR-020 exception is recorded. Every other task that finds itself wanting
to touch those trees stops and returns to T015 — that is the only door.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: create the evidence document every later claim is recorded in, and
freeze the reference counts before anything moves.

- [X] T001 Create `specs/018-optimize-ci-wall-clock/baseline.md` with the measured starting point from research.md §1 (per-job and per-step durations from run `30947466217`, gates run `30947468905`), each figure carrying its run id and date
- [X] T002 [P] Record the frozen reference counts in `specs/018-optimize-ci-wall-clock/baseline.md`: 84 scenarios, 1427 `@test`s across 149 `.bats` files, 1128 Pester assertions across 125 files, 9 job definitions / 11 check runs — with the exact commands that produced each, so SC-008 is re-checkable
- [X] T003 [P] Record the pre-existing `windows-latest` verdict set in `specs/018-optimize-ci-wall-clock/baseline.md`: `us2-field-defaults-option-question` and `us2-field-defaults-question` failing, everything else passing (FR-019's comparison baseline)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: instrumentation, guards, and the measurements that decide the
design. FR-003 forbids designing the Windows change before measuring it, so this
phase genuinely blocks — it is not a warm-up.

**⚠️ CRITICAL**: no user story work begins until T004–T017 are complete.

### Instrumentation and guards (test first)

- [X] T004 [P] Write failing meta-test for worker accounting in `tests/bash/ci/test_conformance_worker_accounting.bats`: the corpus runner prints a verdict count, and a run in which a worker produces no result exits non-zero rather than passing (contracts/conformance-runner.md R5/R6)
- [X] T005 Implement verdict counting and worker accounting in `tests/conformance/ci-conformance.sh` so T004 passes (R5/R6, FR-005)
- [X] T006 [P] Write failing meta-test for per-scenario timings in `tests/bash/ci/test_conformance_timings.bats`: each scenario reports a per-port duration and the run prints an amortised per-scenario cost (R9, SC-009)
- [X] T007 Implement per-scenario, per-port timing capture in `tests/conformance/ci-conformance.sh` and `tests/conformance/run-scenario.sh` so T006 passes (R9)
- [X] T008 [P] Write failing meta-test for the blocking inventory in `tests/bash/ci/test_blocking_inventory.bats`: the nine job definitions and eleven rendered check-run names match contracts/blocking-inventory.md byte for byte, and no workflow outside that table carries an unscoped `pull_request` trigger or a `push` on the default branch, with `live.yml` and `windows-conformance.yml` asserted as the two named exemptions and a third occurrence failing the test (B1–B5, SC-006)
- [X] T009 Make `tests/bash/ci/test_blocking_inventory.bats` green against the current `.github/workflows/*.yml` — no workflow change expected; a failure here means the contract table is wrong, not the workflows
- [X] T009a [P] Write failing meta-test in `tests/bash/ci/test_no_machine_wide_state.bats`: no file under `tests/` identifies a process, port, or directory by a machine-wide scan — `pgrep -f`, `pidof`, `lsof -i`, a fixed literal port, a shared fixed `/tmp` path — every such identifier must come from something the caller itself recorded (FR-008, Constitution XIII's test-isolation rule)
- [X] T009b Make `tests/bash/ci/test_no_machine_wide_state.bats` green against the current tree; any occurrence that cannot be removed is allowlisted **in the test, by name, with the recorded identifier it uses instead**, and recorded in `specs/018-optimize-ci-wall-clock/baseline.md` — this is the check FR-008 requires to precede *any* concurrency increase (FR-008)

### Measurement (plan Phase A)

- [X] T010 Add the W1–W4 measurement lines to the single `::notice::` in `.github/workflows/windows-conformance.yml` (contracts/windows-probe.md P1–P4): per-spawn cost with Defender exclusions off and on (W1), corpus survival plus verdict count at concurrency 3 and 4 (W2), per-port per-scenario split (W3), and whether an MSYS-built `jq` emits LF on this runner with the corpus cost under it (W4)
- [X] T011 Run the Windows probe (`git push --force origin HEAD:ci/windows-probe`) and record W1–W4 in `specs/018-optimize-ci-wall-clock/baseline.md` with the run id and commit — one retry maximum on an inconclusive run, then report as it stands (contracts/windows-probe.md, budget discipline) — **W1/W2/W3 measured (run `31028591939`); W4 reported unmeasured after a 37-min unexplained step produced no data — not pursued further per budget discipline, see baseline.md**
- [ ] T012 [P] Build the per-file timing profile for the bats suite from a CI run and record it in `specs/018-optimize-ci-wall-clock/baseline.md` — **not** from a local wall clock (this project's runners are 6–8× slower, and the authoring host was at load average 167; research §4.2)
- [ ] T013 [P] Measure the **kcov-alone** statement coverage percentage on Linux (`tests/coverage/bash-coverage.sh --mode conformance --threshold 80`) and record it in `specs/018-optimize-ci-wall-clock/baseline.md`. **Venue and bound are part of the task**: it runs on an `ubuntu-latest` runner (a `workflow_dispatch` on `gates.yml`, or a Linux container) — never the authoring macOS host, where `require_kcov` refuses because kcov can only drive the SIP-signed Bash 3.2 this port rejects (research §5.2) — and with `SPEC_KIT_JIRA_COVERAGE_TIMEOUT` raised well above its 600 s default, because the pre-shard exercise phase is serial and already overruns that bound (009's evidence: scenario 46 of 51 when it expired). A run that hits the bound is **not a measurement**: re-run it with a higher bound, never record it as "unmeasurable" — that is the FR-013 distinction this feature exists to protect
- [ ] T014 Apply research §5.2's decision rule to T013's number and record the branch taken in `specs/018-optimize-ci-wall-clock/baseline.md`: ≥ 80% ships as designed; 70–80% requires T033's numerator work first; **< 70% stops Phase 5 and is reported to the user as a spec question**

### The escalated decision

- [X] T015 Put plan.md's Complexity Tracking decision to the user with W1 and W4's measured numbers attached — option (a) an LF-emitting `jq` on the Windows runner (workflow-scoped, FR-020-safe, fidelity trade-off), option (b) a spawn-free guard inside `scripts/bash/lib/output.sh` (production code, frozen by FR-020, and unproven), or relaxing SC-001 to what frozen code delivers. Record the answer in `specs/018-optimize-ci-wall-clock/baseline.md` — **decided: option (a), scoped to `ci.yml` only, probe stays on native `jq`** — see baseline.md
- [ ] T016 If the user chooses option (a), record it in `docs/10-windows-portability.md` as a deliberate, named divergence between what CI exercises and what a stock Windows host runs — not as an invisible optimisation
- [ ] T017 Record in `specs/018-optimize-ci-wall-clock/baseline.md` the arithmetic that T011's numbers produce for the Windows corpus step, so US1's target is chased against measured factors rather than research.md's estimates

**Checkpoint**: every design input is measured and written down. Phase 3 can begin.

---

## Phase 3: User Story 1 — The Windows verdict in minutes, not 95 (Priority: P1) 🎯 MVP

**Goal**: the `unit` job on `windows-latest` reports within 18 minutes, still
executing all 84 scenarios against both ports.

**Independent Test**: run the corpus on a real `windows-latest` runner through
the probe, before and after. The step completes within budget, reports a verdict
for all 84 scenarios, and the verdict set is unchanged.

### Tests for User Story 1 ⚠️

> Written FIRST and observed to FAIL. For the Windows-specific behaviour the
> probe run itself is the failing test (Constitution VI).

- [ ] T018 [P] [US1] Write failing meta-test for the concurrency policy in `tests/bash/ci/test_conformance_concurrency.bats`: `SPEC_KIT_JIRA_CONFORMANCE_JOBS` overrides the host default, the MSYS default is the recorded proven degree, and scheduling stays dynamic rather than a static partition (R3/R4) — **partially done**: the override half landed in Phase 2 (pulled forward, see baseline.md's "Dependency gap resolved" note) because T010's W2 measurement needed it; this task's remaining scope is the "MSYS default is the recorded proven degree" assertion, addable once T026 supplies the number
- [ ] T019 [P] [US1] Write failing test for the reduced-spawn curl shim in `tests/bash/ci/test_mock_shim_contract.bats` (extend the existing file): identical responses, identical call-log order, and a bounded process count per request (R10, FR-003)
- [ ] T020 [P] [US1] Write failing test for harness spawn reduction in `tests/bash/conformance/test_run_scenario.bats` (extend): `jq_lines` and the workdir snapshot produce identical captures with fewer process creations (FR-003)
- [ ] T020a [P] [US1] Write failing meta-test for the Windows Defender exclusions in `tests/bash/ci/test_workflow_windows_defender.bats`: the `windows-latest` leg of `.github/workflows/ci.yml` declares exclusions for the workspace, the temp directory, git-bash and `jq.exe`; the step is guarded so a non-zero exit degrades to a slower correct run rather than failing the job; and no other matrix leg carries it (D3, FR-003)
- [ ] T020b [P] [US1] Write failing meta-test for the `unit` job budget in `tests/bash/ci/test_workflow_job_budgets.bats`: the `unit` job in `.github/workflows/ci.yml` declares `timeout-minutes`, its value is ≤ 18, and it is declared on the job rather than on a single step so a hung leg cannot outlive the budget (FR-015, FR-017, SC-001, SC-002)

### Implementation for User Story 1

- [ ] T021 [US1] Implement the concurrency policy in `tests/conformance/ci-conformance.sh` — `SPEC_KIT_JIRA_CONFORMANCE_JOBS`, the host default, and the MSYS branch reading the proven degree — so T018 passes (R4, D2)
- [ ] T022 [P] [US1] Reduce test-owned spawns in `tests/conformance/mock-jira/curl-shim.sh` (measured: 27 `jq` per 8 HTTP calls) so T019 passes (D4)
- [ ] T023 [P] [US1] Reduce test-owned spawns in `tests/conformance/run-scenario.sh` — the `jq_lines`+`sed` pair per scalar read, the `mktemp`/`cp` churn, the per-file snapshot loop — so T020 passes (D4)
- [ ] T024 [US1] Add Windows Defender exclusions for the workspace, the temp directory, git-bash and `jq.exe` to the `windows-latest` leg of `.github/workflows/ci.yml`, guarded so a failure to set them degrades to a slower correct run rather than a failed job, so T020a passes (D3)
- [ ] T025 [US1] Apply the user's T015 decision to the Windows leg (option (a): install the LF-emitting `jq` in `.github/workflows/ci.yml` and the probe; option (b): the guard change, only with an explicit FR-020 exception recorded; neither: skip and proceed to T026)
- [ ] T026 [US1] Run the probe at the candidate concurrency degrees and record survival, wall-clock and **verdict count** for each in `specs/018-optimize-ci-wall-clock/baseline.md` — "it finished faster" is not evidence a wider fan-out is safe (FR-004, P2)
- [ ] T028 [US1] Run the corpus **twice at the candidate degree** on `windows-latest` via `.github/workflows/windows-conformance.yml`, driving the degree with `SPEC_KIT_JIRA_CONFORMANCE_JOBS` so the gating default has not moved yet, and confirm byte-identical captures and an identical verdict set; record both runs in `specs/018-optimize-ci-wall-clock/baseline.md`. A difference here blocks adoption of that degree — it is not a flake to re-roll (FR-007, SC-007, quickstart V2)
- [ ] T027 [US1] **Runs after T026 and T028** — FR-007 requires determinism proven *before* the parallel form gates. Raise the MSYS default in `tests/conformance/ci-conformance.sh` to the degree T026 proved survivable and T028 proved deterministic, citing both run ids in the code comment beside it (R4)
- [ ] T029 [US1] Set `timeout-minutes` on the `unit` job in `.github/workflows/ci.yml` to the budget SC-001 requires so T020b passes, and record the measured Windows wall-clock and amortised per-scenario cost in `specs/018-optimize-ci-wall-clock/baseline.md` (FR-017, SC-009)

**Checkpoint**: `windows-latest` reports within budget, all 84 scenarios, verdict set unchanged.

---

## Phase 4: User Story 2 — A complete merge decision within 20 minutes (Priority: P1)

**Goal**: all eleven check runs report within 20 minutes of a push on a pull
request touching Bash code; no `unit` leg exceeds 18 minutes.

**Independent Test**: push a Bash-touching commit and measure the interval from
push to the last check run's conclusion.

### Tests for User Story 2 ⚠️

- [ ] T030 [P] [US2] Write failing meta-test for the runner's scheduling in `tests/bash/ci/test_run_bash_runner.bats` (extend the existing file): the worker count may exceed the core count, files are ordered longest-first from the committed profile, an absent or stale profile falls back to the current order rather than failing, and the executed file set is unchanged in every case (D5, FR-010)

### Implementation for User Story 2

- [ ] T031 [US2] Implement worker oversubscription and longest-processing-time-first ordering in `tests/run-bash.sh`, reading the profile committed by T032, so T030 passes (D5, FR-009)
- [ ] T031a [US2] Run `tests/run-bash.sh` twice on CI at the oversubscribed worker count and confirm an identical pass/fail set and an identical executed-file set across both runs, recording both in `specs/018-optimize-ci-wall-clock/baseline.md` — the bats suite's determinism check at the new degree, the counterpart of T050 for the corpus (FR-007, FR-008, Constitution XIII's parallel-execution clause)
- [ ] T032 [US2] **Runs before T031** — it produces the file T031 reads, so it is not parallel with it. Commit the per-file timing profile produced by T012 to `tests/bash-suite-timings.txt` (or the path T031 reads), documenting that it is a scheduling hint only — never a filter, and never a source of verdicts
- [ ] T033 [US2] Refresh the timing profile from the nightly in `.github/workflows/bash-suite-stability.yml`, so the ordering does not rot as the suite grows — **not parallel**: T042 edits the same workflow file (the 51→84 and 986→1427 growth is exactly what invalidated the previous budgets)
- [ ] T034 [US2] Measure the `unit` job on `ubuntu-latest` and `macos-latest` after T031 and record both in `specs/018-optimize-ci-wall-clock/baseline.md` (SC-002)
- [ ] T035 [US2] Measure push-to-complete-merge-decision on a pull request touching Bash code and record it, with per-job durations, in `specs/018-optimize-ci-wall-clock/baseline.md` (SC-003, quickstart V9)
- [ ] T036 [US2] Record total runner-minutes for that run against baseline run `30947466217` in `specs/018-optimize-ci-wall-clock/baseline.md` (SC-012)

**Checkpoint**: the merge decision arrives inside 20 minutes, every gate still reporting.

---

## Phase 5: User Story 3 — A coverage gate that is green and means something (Priority: P1)

**Goal**: `coverage-bash` completes inside a budget with ≥ 20% headroom,
publishes a real percentage, and fails only on a genuine drop or a red suite.

**Independent Test**: run the gate on a Bash-touching pull request; confirm it
publishes a percentage, and that a budget overrun fails while an unmeasurable
run reaches the fallback.

**⚠️ Gated on T014**: if the kcov-alone measurement came in below 70%, this
phase stops and the gap is reported as a spec question rather than closed
quietly.

### Tests for User Story 3 ⚠️

- [ ] T037 [P] [US3] Write failing test for shard/serial equivalence in `tests/bash/ci/test_coverage_shard_merge.bats`: the merged N-shard percentage equals the serial percentage over the same scenarios, the merge is order-independent, and **the total statement count — the denominator — is identical across the sharded and serial forms and at least the figure T013 recorded**, so a percentage can never be raised by losing statements (C3/C4, C1, FR-014)
- [ ] T038a [P] [US3] Rewrite `tests/bash/ci/test_coverage_bats_measurement.bats` for the single-collector gate, red before T040/T042 and green after: the four assertions that encode the merge — "a line counts as covered when either exercise ran it", "the merged percentage is what the gate decides on", "an empty trace leaves the kcov measurement untouched", "the bats phase is wall-clock bounded like the kcov phase" — must assert those properties of the **nightly evidence run** rather than of `gates.yml`, while "no workflow drives bats under kcov — that pair never terminates" stays asserted against **every** workflow. Also re-verify `tests/bash/ci/test_workflow_kcov_runner.bats` still finds the kcov-installing jobs once the phase is sharded (C8, FR-011, FR-012)
- [ ] T038 [P] [US3] Write failing test for the two failure modes **and the declared budget** in `tests/bash/ci/test_coverage_runner_bounds.bats` (extend the existing file): a budget overrun fails the job and never reaches the traceability fallback, the explicit rc=2 "could not measure" path does, and the `coverage-bash` step in `.github/workflows/gates.yml` declares a `timeout-minutes` of at most 18 (C5/C6, FR-013, SC-004)

### Implementation for User Story 3

- [ ] T039 [US3] Implement kcov sharding over the corpus and the merge of the shards' output directories in `tests/coverage/bash-coverage.sh`, honouring `SPEC_KIT_JIRA_COVERAGE_JOBS`, so T037 passes (C3, D6)
- [ ] T040 [US3] Switch the `coverage-bash` step in `.github/workflows/gates.yml` to `--mode conformance` (kcov alone) and confirm the rc=2 and overrun paths behave per T038 (C5/C6/C8, FR-011)
- [ ] T041 [US3] If T014 landed in the 70–80% band, extend `exercise_libraries`/`exercise_dispatcher` in `tests/coverage/bash-coverage.sh` — which run *inside* kcov — until the floor is met, without touching the denominator (C1/C2, D7, FR-014)
- [ ] T042 [US3] Move the xtrace-traced bats collector to `.github/workflows/bash-suite-stability.yml` as coverage-gap evidence, publishing its distinct-frame count, with `schedule` + `workflow_dispatch` triggers only (C8, B4, FR-012, SC-011)
- [ ] T043 [US3] Set `timeout-minutes` on the `coverage-bash` step in `.github/workflows/gates.yml` to a budget leaving ≥ 20% headroom over the measured duration, and record both numbers in `specs/018-optimize-ci-wall-clock/baseline.md` (FR-013, SC-004)
- [ ] T044 [US3] Confirm in `tests/coverage/bash-coverage.sh` that the credential/transport machinery stays xtrace-suspended wherever tracing still runs, and that no phase redirects fd 2 or reads the runner's stdin, with `tests/bash/ci/test_coverage_runner_bounds.bats` still green (C9/C10, Constitution IV)

**Checkpoint**: `coverage-bash` is green, bounded, and honest; the coverage-gap evidence still exists, non-blocking.

---

## Phase 6: User Story 4 — Every guarantee survives the speed-up (Priority: P1)

**Goal**: the inventory, the per-OS corpus completeness, and the verdict set are
provably unchanged.

**Independent Test**: compare the blocking-job inventory, the per-OS scenario
count, and the per-scenario verdict set before and after. All three identical.

- [ ] T045 [P] [US4] Confirm the `windows-latest` verdict set still holds exactly the two failures recorded in T003 — no new failure, none hidden — and record the comparison in `specs/018-optimize-ci-wall-clock/baseline.md` (FR-019, SC-010)
- [ ] T046 [P] [US4] Inject a one-line cross-port divergence into a scratch copy of a port module, run one scenario against both ports, confirm the diff fails and the report names the first differing byte in hex with both sizes, then discard the scratch copy — recording the result in `specs/018-optimize-ci-wall-clock/baseline.md` (SC-010, R7, quickstart V7)
- [ ] T046a [P] [US4] Repeat T046's injection so that **many** scenarios fail at once (a divergence in a module every scenario touches), and confirm the run still emits exactly **one** `::error::` annotation carrying the whole byte-level report — FR-006's annotation-budget clause, untested by the single-scenario case, and the shape that once dropped the report that carried the bytes (FR-006, R7, data-model §2)
- [ ] T047 [P] [US4] Confirm `tests/bash/ci/test_blocking_inventory.bats` is still green after every workflow change, and record the nine definitions / eleven check-run names as unchanged (SC-006, B1)
- [ ] T048 [P] [US4] Confirm the per-OS scenario count equals the corpus count on all three hosts, read from the verdict counts T005 added to `tests/conformance/ci-conformance.sh`, and record the three numbers in `specs/018-optimize-ci-wall-clock/baseline.md` (SC-005, FR-001)
- [ ] T049 [P] [US4] Confirm the executed inventory has not shrunk — ≥ 84 scenarios, ≥ 1427 `@test`s across ≥ 149 files, ≥ 1128 Pester assertions across ≥ 125 files — by re-running T002's recorded commands and writing the result beside its frozen reference in `specs/018-optimize-ci-wall-clock/baseline.md` (SC-008, FR-010)
- [ ] T050 [US4] Run `bash tests/conformance/ci-conformance.sh` twice on a POSIX host at the final concurrency, confirm byte-identical captures and an identical verdict set, and record both runs in `specs/018-optimize-ci-wall-clock/baseline.md` (FR-007, SC-007, quickstart V2)

**Checkpoint**: all four stories complete; every guarantee re-proven rather than assumed.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T051 [P] Add every quirk the probe established to `docs/10-windows-portability.md` in the catalog's rule-then-measurement form, including the per-spawn cost of this runner and the concurrency ceiling with its evidence (FR-022, P5)
- [ ] T052 [P] Close feature 009's open tasks against this feature's measurements: mark T032 (coverage floor and denominator), T035 (Windows scope verification) and T036 (CI measurement) resolved in `specs/009-optimize-test-performance/tasks.md`, each citing the section of `specs/018-optimize-ci-wall-clock/baseline.md` that closes it (FR-021, SC-013)
- [ ] T053 [P] Update `AGENTS.md`'s "Running the suites" section with the new suite runtimes and any new runner flag, so the next agent inherits the measurement instead of the stale figure
- [ ] T054 Run the full quickstart V1–V10 and record each result in `specs/018-optimize-ci-wall-clock/baseline.md`
- [ ] T055 Final Constitution re-check: confirm `git diff --name-only main -- scripts/` is **empty** (FR-020), or that the single exception is the one the user approved in T015 and is recorded as such
- [ ] T056 Record the feature's outcome against every success criterion SC-001 – SC-013 in `specs/018-optimize-ci-wall-clock/baseline.md`, including any criterion that was **not** met and why — a missed budget is reported, never quietly dropped

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: blocks everything. T010–T014 are measurements that
  decide the design; FR-003 forbids designing around them.
- **US1 (Phase 3)**: needs Phase 2. T025 needs T015's answer; T027 needs T026's
  probe evidence.
- **US2 (Phase 4)**: needs T012's profile. Otherwise **independent of US1** —
  the bats suite and the Windows corpus share no file.
- **US3 (Phase 5)**: needs T013/T014. Independent of US1 and US2.
- **US4 (Phase 6)**: verification; needs US1–US3.
- **Polish (Phase 7)**: needs everything.

### Within each story

- The test task precedes its implementation task, always (Constitution XIII).
- T009a/T009b precede **every** concurrency raise (T021/T027 for the corpus,
  T031 for the bats suite): FR-008 requires the isolation check before the
  increase, not after it. T031a confirms it at the new degree afterwards.
- For Windows behaviour the probe run **is** the test (Constitution VI): T026
  before T027, T011 before T021.
- **T026 and T028 both precede T027**: FR-007 forbids the wider form gating
  before determinism at that degree is proven, so the candidate degree is driven
  by `SPEC_KIT_JIRA_CONFORMANCE_JOBS` until it is.
- **T032 precedes T031** — it commits the profile T031 reads.
- **T038a precedes T040 and T042** — the existing measurement guard encodes the
  two-collector gate and must be rewritten red before the collector moves.
- A measurement task precedes the budget it sets: T034 before T029's equivalent
  for the POSIX legs, T043 after the coverage duration is known.

### Parallel opportunities

- T002, T003 together.
- T004, T006, T008, T009a (four different new test files) together; T012, T013
  together once the probe is running.
- **US1, US2 and US3 can run in parallel** once Phase 2 completes — they touch
  disjoint files (`ci-conformance.sh` + `curl-shim.sh` + `run-scenario.sh` /
  `run-bash.sh` / `bash-coverage.sh`) and disjoint workflow jobs. **One
  exception**: T033 (US2) and T042 (US3) both edit
  `.github/workflows/bash-suite-stability.yml` and must be serialised.
- T045–T049 together, and T046a alongside T046.
- T051, T052, T053 together.

---

## Parallel Example: Phase 2 foundations

```bash
# Three independent meta-test files, written together:
Task: "Failing meta-test for worker accounting in tests/bash/ci/test_conformance_worker_accounting.bats"
Task: "Failing meta-test for per-scenario timings in tests/bash/ci/test_conformance_timings.bats"
Task: "Failing meta-test for the blocking inventory in tests/bash/ci/test_blocking_inventory.bats"

# Two independent measurements, once the probe is in flight:
Task: "Build the bats per-file timing profile from a CI run"
Task: "Measure the kcov-alone coverage percentage on Linux"
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1 Setup.
2. Phase 2 Foundational — **the measurements are the work here**, not overhead.
3. Phase 3 US1.
4. **STOP and VALIDATE**: `windows-latest` inside 18 minutes, 84 verdicts,
   verdict set unchanged.

This is a defensible stopping point on its own: it removes 77 of the 95 minutes
and leaves every gate in place.

### Incremental delivery

1. Setup + Foundational → every design input measured.
2. US1 → the Windows leg stops being the critical path.
3. US2 → the POSIX legs follow; the 20-minute target becomes reachable.
4. US3 → the coverage gate stops being permanently red.
5. US4 + Polish → the guarantees are re-proven and the evidence is recorded.

### Notes

- `[P]` = different files, no dependency on incomplete work.
- **One retry maximum** on an inconclusive `windows-latest` run: it costs ~11
  minutes and four runners, and re-rolling a flake proves nothing.
- **`main` is red on `windows-latest`** for two genuine divergences this feature
  does not own. Always diff a branch's verdict set against `main`'s before
  concluding the branch broke something.
- Conformance success is **silent** — no pass banner. Exit 0 with zero
  "conformance divergence" lines is the pass.
- Never size a budget from a local wall clock; these runners are 6–8× slower.
- Any task that would write to `scripts/bash/**` or `scripts/powershell/**` stops
  and returns to T015. That is the only door.
