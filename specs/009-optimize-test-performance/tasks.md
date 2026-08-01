---
description: "Task list for 009-optimize-test-performance"
---

# Tasks: Optimize Automated Test Performance (macOS / Linux)

**Input**: Design documents from `/specs/009-optimize-test-performance/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: REQUIRED and tests-first. Constitution XIII mandates strict
Red-Green-Refactor: every implementation task is preceded by a test task that is
written, run, and observed to FAIL before the implementation turns it green.
Every fixed bug ships with a regression test written before the fix (FR-015).

**Organization**: The three user stories are P1 facets of one optimization
(local speed / CI cost / quality preserved). They share one foundation — the
`curl` shim (Phase 2) — which blocks all three.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: US1 (fast local feedback), US2 (cheaper CI), US3 (quality preserved)
- Every task names exact file paths.

## Path Conventions

Script-native repo. All work is confined to `tests/`, `.github/workflows/`, and
docs. Production code under `scripts/bash/**` and `scripts/powershell/**` is NOT
touched (guarantees coverage/behavior parity by construction — see plan.md).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Capture the baseline the success criteria are measured against, and
confirm the invariants the plan relies on.

- [ ] T001 Capture and record the current-tree baselines in `specs/009-optimize-test-performance/baseline.md`, each on the current tree (pre-shim, real pwsh mock): (a) **serial** wall-clock of `bats -r tests/bash`, and (b) **parallel** wall-clock of `bats -r tests/bash --jobs "$(getconf _NPROCESSORS_ONLN)"` — the mode SC-001 is judged against; CI runner-minutes + wall-clock of the latest `main` CI run; and the current Bash `@test` count (`grep -rhc '^@test' tests/bash --include='*.bats' | paste -sd+ - | bc`). SC-001 is measured like-for-like: the optimized `run-bash.sh` (parallel) vs baseline (b) (parallel), so the improvement reflects the shim, not concurrency alone. These anchor SC-001/SC-004/SC-005/SC-007. **Counts re-captured 2026-08-02 on `21068d6`: 955 `@test`s / 115 files / 35 mock-dependent / 51 scenarios.** The *timings* remain outstanding — see the two blockers below.
  - **(a)/(b) are still unmeasurable on this machine**: without PowerShell every mock-dependent file fails instantly, and `bats --jobs` without GNU `parallel` runs 0 tests. SC-001 therefore has no usable denominator yet. Resolve by measuring on a Linux/CI host, or by re-defining SC-001's baseline — do not compare against a 0-test run.
  - **CI runner-minutes / wall-clock**: capture from a real green run on `21068d6`, not from the `20–35 min` figure quoted in a gates.yml comment.
- [x] T002 [P] Record the exact set of blocking CI gates today (jobs in `.github/workflows/ci.yml`, `.github/workflows/gates.yml` and `.github/workflows/boundary.yml`) into `specs/009-optimize-test-performance/baseline.md` under "Gate inventory (must be identical after)" — the SC-006/FR-010 checklist. **Re-captured 2026-08-02 on `21068d6`: 9 blocking jobs / 3 workflows**, including 008's new `lint` job and the conformance corpus now running as a *step* of the three-OS `unit` job. `windows-conformance.yml` and `live.yml` are explicitly recorded as NON-gates.
- [x] T003 [P] Confirm the single-HTTP-chokepoint invariant still holds: `grep -rn 'curl ' scripts/bash | grep -v '#'` returns only `sink/jira/client.sh`; note the result in `baseline.md`. If a second call site exists, STOP — the shim design assumes one. **Re-verified post-008: holds** (single site, now `client.sh:139`).

**Checkpoint**: Baselines recorded; the numbers SC-001/004/005/007 will be judged against exist on disk.

---

## Phase 2: Foundational (Blocking Prerequisites) — the `curl` shim

**Purpose**: Replace the per-test PowerShell mock backend with a scripted `curl`
shim reached through the unchanged `mock_start`/`mock_stop`/`mock_calls` contract.
This is the one mechanism US1, US2, and US3 all depend on.

**⚠️ CRITICAL**: No user-story phase may begin until this phase is complete and all **35** existing mock-driving Bash test files are green on the shim backend.

**Shim state model (research.md Decision 6, resolving OQ-1)**: the shim is NOT a stateless router. `lib.sh` exposes `mock_issue_field`, which reads a field back out of an issue an earlier POST created — 9 call sites in `tests/bash/sink/test_hierarchy.bats` and `tests/bash/commands/test_reconcile_hierarchy.bats`. The shim therefore keeps an **issue store** in the recorded `MOCK_TMPDIR` (see `contracts/curl-shim.md` § Session state).

### Tests (write first, observe FAIL)

- [ ] T004 Write the shim contract test in `tests/bash/ci/test_mock_shim_contract.bats` per `contracts/curl-shim.md` and `contracts/mock-driver.md`: via `mock_start`, assert `GET project/COMP`→company fixture and `TEAM`→team fixture; `faults.json` gives 401 (AUTH), 404 (MISSING), 429+`Retry-After` (RATE), network failure (NET); `POST /issue`→201; every request appears once and in order in `mock_calls`; and the `Authorization` header NEVER appears in `${MOCK_CALLLOG}`. **Plus the 008 surface (invariants 6–7)**: after a `POST /issue` carrying a `parent`, `mock_issue_field <key> .fields.parent.key` returns that parent; and two concurrent `mock_start` instances never see each other's issues. Run it, observe it FAIL (no shim yet).

### Implementation (turn it green)

- [ ] T005 Implement the scripted `curl` replacement in `tests/conformance/mock-jira/curl-shim.sh` satisfying `contracts/curl-shim.md`: parse the `--config -` stdin (`url`, `request`, `data=@file`), honor `--output`/`--dump-header`/`--write-out '%{http_code}'`, route path→fixture using the existing `configs/*.json` + `fixtures/*.json`, emit faults (401/403/404/429+`Retry-After`/network=non-zero exit), append `METHOD target` to `${MOCK_CALLLOG}`, and NEVER read or log the `Authorization` header.
- [ ] T005b Implement the shim's **issue store** per `contracts/curl-shim.md` § Session state (Decision 6): a JSON file under the recorded `MOCK_TMPDIR`, seeded from `fixtures/*.json` at `mock_start`, updated by `POST`/`PUT /rest/api/3/issue` (recording created keys and their `fields`, incl. `parent`), and read by `GET /rest/api/3/issue/{key}`. Confirm `mock_write_config` needs no shim-side work (0 bats call sites) rather than assuming it. Makes T004's invariants 6–7 pass.
- [ ] T006 Edit `tests/conformance/mock-jira/lib.sh` so `mock_start` selects the backend by port: install the `curl` shim on `PATH` for the Bash port (setting `MOCK_BASE_URL` sentinel, `MOCK_CALLLOG`, `MOCK_TMPDIR`; no process) and keep spawning `mock-server.ps1` for the PowerShell port; `mock_stop` removes exactly the recorded `MOCK_TMPDIR` (and the recorded pwsh PID when present). Public function names/outputs unchanged (contract preserved). Make T004 pass.
- [ ] T007 Run the full existing mock-driving suite on the shim backend and fix any shim/lib gaps until green: `bats tests/bash/sink` and the mock-using files under `tests/bash/commands` and `tests/bash/conformance` (all **35** `mock_start` files). In particular `tests/bash/sink/test_client.bats` (retry/backoff/status-mapping) and the "token never under `set -x`" test MUST pass unchanged, and 008's `tests/bash/sink/test_hierarchy.bats` + `tests/bash/commands/test_reconcile_hierarchy.bats` MUST pass on whichever OQ-1 option was chosen.
- [ ] T008 Edit `tests/conformance/run-scenario.sh` so the Bash port uses the shim and the PowerShell port uses the real pwsh server (Decision 2); guard the `mock.pid` write so it only runs for the real-server backend, and update `tests/bash/conformance/test_run_scenario.bats` to assert mock lifecycle by the backend actually in use (no name-pattern scan; recorded identity only, Constitution XIII).
- [ ] T009 Verify cross-port conformance still passes end-to-end after the backend split: run `tests/conformance/run-scenario.sh` for a Bash(shim) vs PowerShell(real) pair on 2–3 representative scenarios (e.g. `us3-feature-create.json`, `us8-reconcile-company-managed.json`, `us6-fail-closed.json`) and `diff` stdout/exit/calls.log/workdir — must be byte-identical (this is the shim↔pwsh-mock cross-check). This is a **smoke check, not the gate**: FR-006/SC-010 require all **51** scenarios against both ports, which `tests/conformance/ci-conformance.sh` runs in CI on all three OSes (T009b).
- [ ] T009b Run the FULL corpus locally through the 008 entry point — `bash tests/conformance/ci-conformance.sh` — and confirm all 51 scenarios stay byte-identical across ports on the shim backend. Note that this script already shards via `SPEC_KIT_JIRA_SHARD_TOTAL` / `SPEC_KIT_JIRA_SHARD_INDEX`; record whether that sharding is reusable to cut the three-OS conformance cost (input to T015/T017).

**Checkpoint**: The Bash suite drives the mock with zero PowerShell processes; all 35 mock files green; conformance parity intact.

---

## Phase 3: User Story 1 - Fast local feedback (Priority: P1) 🎯 MVP

**Goal**: A developer/agent runs the whole Bash suite fast with only `bats`+`jq`,
every test executes, and the result is never a false green.

**Independent Test**: On a machine with only `bats`+`jq` (no PowerShell, no GNU
`parallel`), `tests/run-bash.sh` completes in ≤ half the T001 baseline, executes
every test (0 skipped for missing tooling), and exits with a correct verdict.

### Tests (write first, observe FAIL) ⚠️

- [ ] T010 [US1] Write the runner regression test in `tests/bash/ci/test_run_bash_runner.bats` per `contracts/test-runner.md`: with GNU `parallel` forced off `PATH`, the runner executes the FULL suite and the reported executed-test count equals the expected total (never 0) — the regression for the silent-zero-tests defect (FR-003/FR-015); a deliberately failing test makes the runner exit non-zero; the summary reports a count > 0. Run it, observe it FAIL (no runner yet).

### Implementation

- [ ] T011 [US1] Implement `tests/run-bash.sh` per `contracts/test-runner.md`: discover test files (default `tests/bash`, optional path args), shard across cores with `xargs -P "$(getconf _NPROCESSORS_ONLN)"` (one `bats` per file), serial fallback if concurrency is unavailable, aggregate exit codes, print a summary with file/test counts, and exit non-zero with a named message on any failure or if executed-file count is 0. No dependency on GNU `parallel`. Make T010 pass.
- [ ] T010b [US1] Write the change-scoped mode's tests in `tests/bash/ci/test_run_bash_runner.bats` per `contracts/test-runner.md` § Change-scoped mode, BEFORE implementing it: `--since` with an undeterminable diff runs the FULL suite (S2, fail-open); an empty selection runs everything, never zero (S3); the output names the selected files and flags the run as partial (S4). Run them, observe FAIL.
- [ ] T011b [US1] Implement `--since <ref>` in `tests/run-bash.sh` (FR-017): map the diff to affected test files, fail open to the full suite on any doubt, print the selection and a "PARTIAL RUN" banner. Local only — never referenced from a workflow. Makes T010b pass.
- [ ] T012 [US1] Confirm the fast path end-to-end: run `tests/run-bash.sh` on this machine and verify **≤ 5 min** wall-clock (SC-001) with 0 tests skipped for missing tooling (SC-002); then run `tests/run-bash.sh --since HEAD~1` on a single-module diff and verify **≤ 60 s** (SC-001b). Record both timings in `specs/009-optimize-test-performance/baseline.md`.
- [ ] T013 [P] [US1] Update the "running the tests" documentation (`README.md` and/or `INSTALL.md`) to state the fast local path (`tests/run-bash.sh`, only `bats`+`jq` required, no PowerShell/GNU `parallel` for the Bash suite) per FR-014 / Constitution XVI.

**Checkpoint**: The Bash suite is fast and trustworthy locally with only `bats`+`jq`.

---

## Phase 4: User Story 2 - Cheaper, faster CI (Priority: P1)

**Goal**: CI consumes markedly fewer runner-minutes and finishes sooner, with
every blocking gate and verdict identical.

**Independent Test**: On a representative PR, CI runner-minutes drop ≥40% (SC-004)
and wall-clock ≥30% (SC-005) vs. the T001/T002 baseline, while the blocking gate
set is byte-for-byte the same (SC-006).

### Tests / guards (adjust first where a guard asserts an invocation)

- [ ] T014 [US2] Update the CI-guard tests that assert workflow invocations so they match the new commands BEFORE editing the workflows, then observe them fail against the current workflow: adjust `tests/bash/ci/test_workflow_kcov_runner.bats` and any assertion in `tests/bash/ci/` that pins `bats --jobs`/toolchain-install lines, to expect `tests/run-bash.sh` and the cached/targeted-install shape. Keep every gate-existence assertion (SC-006) — and add one for 008's `lint` job, which the pre-008 inventory did not know about.

### Implementation

- [ ] T015 [US2] Edit `.github/workflows/ci.yml`: replace `bats -r tests/bash --jobs …` (line 63) with `tests/run-bash.sh`; drop the GNU `parallel` install (Linux line 36 + macOS line 43) and stop requiring PowerShell for the Bash run; install `specify-cli` only in the job(s) that run the install-harness scenarios; keep the three-OS matrix and all three jobs (`unit`, `lint`, `static-checks`). Leave the `unit` job's conformance step (line 85, `bash tests/conformance/ci-conformance.sh`) running on all three OSes unless T017 establishes a cheaper shape that preserves the verdict. Make T014 pass.
- [ ] T016 [US2] Add dependency caching to `.github/workflows/ci.yml` and `.github/workflows/gates.yml` via `actions/cache`: cache the Pester module (keyed on OS + pinned Pester version) and the `uv`-installed `specify-cli` (keyed on OS + pinned spec-kit ref); on a cache miss, install exactly as today (correct, slower). A cache hit must never change a gate verdict.
- [ ] T017 [US2] Edit `.github/workflows/gates.yml` so the Bash coverage job inherits the shim speedup (no pwsh under kcov) while keeping the 80% threshold, the `kcov-excl` regions, the kcov→traceability fallback, and the `changes` fail-open path filter unchanged; confirm the PowerShell coverage job and its 80% threshold are untouched.
- [ ] T017b [US2] Enforce the coverage budget (FR-016/SC-004): set `coverage-bash`'s `timeout-minutes` to **15** and verify the job finishes inside it with headroom. Ensure a timeout FAILS the job rather than being absorbed by the traceability fallback — the fallback exists for kcov runs that could not *measure*, not for ones that were merely *slow*. Record the measured duration in `baseline.md`.
- [ ] T017c [US2] Shard the conformance corpus **within each OS** (FR-018, Decision 7): parallelise the `unit` job's conformance step across N shards on the SAME host using the existing `SPEC_KIT_JIRA_SHARD_TOTAL` / `SPEC_KIT_JIRA_SHARD_INDEX` support in `tests/conformance/ci-conformance.sh`. **Every OS must still run all 51 scenarios.** Do NOT distribute scenarios across the three OSes — that shape is forbidden (it would leave Windows proving only a third of the corpus). Record the before/after duration of the conformance step per OS in `baseline.md`.
- [ ] T017d [US2] Add the mechanical guard for SC-011/FR-018/FR-019 to `tests/bash/ci/`: assert that on every OS in the matrix the number of conformance scenarios executed equals the full corpus count (51), and that `windows-latest` still runs both the Pester suite and the complete corpus as blocking work. This is the test that makes a future shard-across-OS regression impossible to land quietly.
- [ ] T018 [P] [US2] Review `.github/workflows/boundary.yml` for the same avoidable reinstalls; apply caching/targeted-install only where it cannot change a verdict (fail-open on uncertainty, FR-009). If nothing applies, note it in `baseline.md`. FR-009 scope note: this feature satisfies "avoid re-executing work a diff cannot change" via toolchain caching (T016) and the _existing_ `changes` path filter (preserved in T017) — it introduces NO new gate-skipping or affectedness-based conditional execution (test-tiering that changes what gates a PR is Out of Scope, spec.md). Record this scoping decision in `baseline.md`.

**Checkpoint**: CI is cheaper and faster with the identical gate set.

---

## Phase 5: User Story 3 - Quality guarantees fully preserved (Priority: P1)

**Goal**: Prove the faster suite still proves everything the slow one did — no
test removed, coverage floor and denominator unchanged, parity still enforced,
green under parallelism.

**Independent Test**: Coverage ≥80% both ports on an unchanged-or-larger
denominator; an injected cross-port divergence still fails conformance; the suite
is green across 20 parallel runs; executed-assertion count ≥ the T001 baseline.

### Verification tasks

- [ ] T019 [US3] Verify the coverage floor and denominator are unchanged: run `tests/coverage/bash-coverage.sh --mode full --threshold 80` (Linux/kcov), confirm PASS and that the measured line count (denominator) is ≥ the pre-change value; if the shim needs any adjustment under `SPEC_KIT_JIRA_COVERAGE_INPROCESS`, make the minimal edit in `tests/conformance/mock-jira/lib.sh`/`curl-shim.sh` only (never widen `kcov-excl` or shrink the denominator). Record the % and line count in `baseline.md` (SC-008/FR-005).
- [ ] T020 [P] [US3] Verify parity detection is unimpaired (SC-010): temporarily inject a one-line divergence into a Bash-port output path in a scratch copy, run a conformance scenario against both ports, confirm the `diff` FAILS, then revert. Document the check in `quickstart.md` V6 (already drafted) as executed.
- [ ] T021 [P] [US3] Verify no new flakiness (SC-009/FR-007), at two cadences: run `tests/run-bash.sh` **5 times consecutively locally** — all 5 green — and add a **scheduled CI job that runs it 20 times** and reports. (A 20× local gate costs ~7 hours, which would defeat the purpose of this feature; the strong evidence moves to CI where it costs no developer time.) Confirm no test locates a process/file/port by name pattern or machine-wide scan (`grep -rn 'pgrep\|pkill\|lsof\|:[0-9]\{4,\}' tests/bash` reviewed; shim/runner use recorded identity only).
- [ ] T022 [P] [US3] Verify zero tests were removed (SC-007/FR-004): compare the current `@test` count and file list to the T001 baseline; the executed-assertion count must be **≥ 955 across ≥ 115 `.bats` files** (the post-008 baseline — NOT the superseded pre-008 figure of 775/95). Record in `baseline.md`.
- [ ] T023 [US3] Verify the PowerShell port is not regressed (FR-013): run the Pester suite (`Invoke-Pester tests/powershell`, 96 `.Tests.ps1` files) and confirm green + coverage ≥80% unchanged. **CI-owned**: pwsh is not installed on the primary dev machine (see T001 note), so the `unit` and `coverage-pwsh` jobs are the system of record for this task — cite the run URL rather than a local result.
- [ ] T023b [US3] Verify the Windows guarantee explicitly (FR-019/FR-020/SC-011): on the `windows-latest` leg of the `unit` job, confirm the Pester suite ran in full AND all 51 conformance scenarios executed on that host — not a shard of them. Confirm both are still blocking. Record the per-OS scenario counts in `baseline.md`; any host reporting fewer than 51 is a FAIL, not a speed-up.

**Checkpoint**: Every constitution gate proven intact at its prior strength.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation, changelog, and measured confirmation of the goals.

- [ ] T024 Run the full `quickstart.md` validation (V1–V7) and record pass/fail for each scenario in `baseline.md`.
- [ ] T025 [P] Measure the achieved CI figures against the **absolute budgets**: `coverage-bash` ≤ 15 min (SC-004), push → complete merge decision ≤ 20 min (SC-005), and total runner-minutes below a green run of `21068d6` (SC-005b). Record all three in `baseline.md`. A budget miss is a failure of this feature, not a rounding note.
- [ ] T026 [P] Add a `CHANGELOG.md` entry (Constitution XII / SemVer) describing the test-performance optimization: `curl` shim backend, dependency-free runner, CI caching; note the removed PowerShell/GNU-`parallel` requirement for the Bash suite.
- [ ] T027 Final Constitution re-check: confirm no production code under `scripts/**` changed (`git diff --name-only main -- scripts/` is empty), all gates green three-OS, and every FR/SC in `spec.md` is satisfied; note any deviation for review.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup — **BLOCKS US1, US2, US3**.
- **US1 (Phase 3)**: Depends on Foundational. The MVP increment.
- **US2 (Phase 4)**: Depends on Foundational; US2's `ci.yml` edit (T015) calls `tests/run-bash.sh`, so it also depends on **US1 T011**.
- **US3 (Phase 5)**: Depends on Foundational (verifies the shim); T019 needs the coverage path from Phase 2; independent of US1/US2 otherwise.
- **Polish (Phase 6)**: Depends on all desired stories complete.

### Critical path

T001 → (T004→T005→T005b→T006→T007→T008→T009→T009b) → T010→T011 → T015 → T024→T027.

**OQ-1 is resolved** (research.md Decision 6 — the shim carries an issue store),
so the critical path is no longer decision-blocked.

### Independent of the critical path (start any time after Foundational)

- **T017b** (kcov budget) and **T017c** (in-OS conformance sharding) are the two
  tasks that actually address the 30-minute CI timeout. T017c is the larger lever:
  008 multiplied the conformance cost ~3.9× by promoting the corpus to all three
  OSes and growing it to 51 scenarios.
- **T010b/T011b** (change-scoped local mode) are the two that address the
  multi-hour implementation loop. They touch no CI gate.
- **T017d** and **T023b** are the Windows guard rails; land T017d *before* T017c
  so the shard-across-OS mistake cannot pass unnoticed.

### Within each story

- Test task precedes its implementation task (TDD, Constitution XIII).
- Foundational tasks T004–T009 are strictly sequential (same files: `lib.sh`, `curl-shim.sh`, `run-scenario.sh`).

### Parallel Opportunities

- Setup: T002, T003 in parallel (different concerns); T001 first (others reference it).
- US1: T013 (docs) ∥ T012 (timing) after T011.
- US2: T018 ∥ the T016/T017 workflow edits (different files); T014→T015 sequential (guard then workflow).
- US3: T020, T021, T022, T023 all [P] — independent verifications.
- Polish: T025, T026 [P].

---

## Parallel Example: User Story 3

```bash
# Independent verification tasks after Foundational + US1/US2:
Task: "T020 Verify parity detection via injected divergence"
Task: "T021 Verify 20x green under parallelism"
Task: "T022 Verify zero tests removed (assertion-count non-regression)"
Task: "T023 Verify PowerShell port not regressed (Pester)"
```

---

## Implementation Strategy

### MVP First (Foundational + User Story 1)

1. Phase 1: Setup — record baselines (T001–T003).
2. Phase 2: Foundational — the `curl` shim; all 35 mock files green, parity intact (T004–T009).
3. Phase 3: US1 — the dependency-free runner (T010–T013).
4. **STOP and VALIDATE**: full Bash suite runs fast with only `bats`+`jq`, never a false green. This alone delivers the primary local-dev win.

### Incremental Delivery

1. Foundational + US1 → fast, trustworthy local suite (MVP).
2. US2 → CI caching + runner adoption → cheaper/faster CI.
3. US3 → prove every quality gate intact at prior strength.
4. Polish → changelog, measured savings, final constitution re-check.

---

## Notes

- [P] = different files, no dependency on an incomplete task.
- The whole change lives in `tests/`, `.github/workflows/`, and docs — production `scripts/**` is untouched, which is what keeps coverage and cross-port parity true by construction.
- Verify every test FAILS before implementing it (Constitution XIII).
- The shim and the pwsh mock are kept honest by the conformance diff — never let them drift silently; T009 is the gate.
- Commit after each task or logical group.
