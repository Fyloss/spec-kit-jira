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

- [ ] T001 Capture and record the current-tree baselines in `specs/009-optimize-test-performance/baseline.md`, each on the current tree (pre-shim, real pwsh mock): (a) **serial** wall-clock of `bats -r tests/bash`, and (b) **parallel** wall-clock of `bats -r tests/bash --jobs "$(getconf _NPROCESSORS_ONLN)"` — the mode SC-001 is judged against; CI runner-minutes + wall-clock of the latest `main` CI run; and the current Bash `@test` count (`grep -rhc '^@test' tests/bash --include='*.bats' | paste -sd+ - | bc`). SC-001 is measured like-for-like: the optimized `run-bash.sh` (parallel) vs baseline (b) (parallel), so the improvement reflects the shim, not concurrency alone. These anchor SC-001/SC-004/SC-005/SC-007.
- [ ] T002 [P] Record the exact set of blocking CI gates today (jobs in `.github/workflows/ci.yml` and `.github/workflows/gates.yml`) into `specs/009-optimize-test-performance/baseline.md` under "Gate inventory (must be identical after)" — the SC-006/FR-010 checklist.
- [ ] T003 [P] Confirm the single-HTTP-chokepoint invariant still holds: `grep -rn 'curl ' scripts/bash | grep -v '#'` returns only `sink/jira/client.sh`; note the result in `baseline.md`. If a second call site exists, STOP — the shim design assumes one.

**Checkpoint**: Baselines recorded; the numbers SC-001/004/005/007 will be judged against exist on disk.

---

## Phase 2: Foundational (Blocking Prerequisites) — the `curl` shim

**Purpose**: Replace the per-test PowerShell mock backend with a scripted `curl`
shim reached through the unchanged `mock_start`/`mock_stop`/`mock_calls` contract.
This is the one mechanism US1, US2, and US3 all depend on.

**⚠️ CRITICAL**: No user-story phase may begin until this phase is complete and all 29 existing mock-driving Bash test files are green on the shim backend.

### Tests (write first, observe FAIL)

- [ ] T004 Write the shim contract test in `tests/bash/ci/test_mock_shim_contract.bats` per `contracts/curl-shim.md` and `contracts/mock-driver.md`: via `mock_start`, assert `GET project/COMP`→company fixture and `TEAM`→team fixture; `faults.json` gives 401 (AUTH), 404 (MISSING), 429+`Retry-After` (RATE), network failure (NET); `POST /issue`→201; every request appears once and in order in `mock_calls`; and the `Authorization` header NEVER appears in `${MOCK_CALLLOG}`. Run it, observe it FAIL (no shim yet).

### Implementation (turn it green)

- [ ] T005 Implement the scripted `curl` replacement in `tests/conformance/mock-jira/curl-shim.sh` satisfying `contracts/curl-shim.md`: parse the `--config -` stdin (`url`, `request`, `data=@file`), honor `--output`/`--dump-header`/`--write-out '%{http_code}'`, route path→fixture using the existing `configs/*.json` + `fixtures/*.json`, emit faults (401/403/404/429+`Retry-After`/network=non-zero exit), append `METHOD target` to `${MOCK_CALLLOG}`, and NEVER read or log the `Authorization` header.
- [ ] T006 Edit `tests/conformance/mock-jira/lib.sh` so `mock_start` selects the backend by port: install the `curl` shim on `PATH` for the Bash port (setting `MOCK_BASE_URL` sentinel, `MOCK_CALLLOG`, `MOCK_TMPDIR`; no process) and keep spawning `mock-server.ps1` for the PowerShell port; `mock_stop` removes exactly the recorded `MOCK_TMPDIR` (and the recorded pwsh PID when present). Public function names/outputs unchanged (contract preserved). Make T004 pass.
- [ ] T007 Run the full existing mock-driving suite on the shim backend and fix any shim/lib gaps until green: `bats tests/bash/sink` and the mock-using files under `tests/bash/commands` and `tests/bash/conformance` (all 29 `mock_start` files). In particular `tests/bash/sink/test_client.bats` (retry/backoff/status-mapping) and the "token never under `set -x`" test MUST pass unchanged.
- [ ] T008 Edit `tests/conformance/run-scenario.sh` so the Bash port uses the shim and the PowerShell port uses the real pwsh server (Decision 2); guard the `mock.pid` write so it only runs for the real-server backend, and update `tests/bash/conformance/test_run_scenario.bats` to assert mock lifecycle by the backend actually in use (no name-pattern scan; recorded identity only, Constitution XIII).
- [ ] T009 Verify cross-port conformance still passes end-to-end after the backend split: run `tests/conformance/run-scenario.sh` for a Bash(shim) vs PowerShell(real) pair on 2–3 representative scenarios (e.g. `us3-feature-create.json`, `us8-reconcile-company-managed.json`, `us6-fail-closed.json`) and `diff` stdout/exit/calls.log/workdir — must be byte-identical (this is the shim↔pwsh-mock cross-check).

**Checkpoint**: The Bash suite drives the mock with zero PowerShell processes; all 29 mock files green; conformance parity intact.

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
- [ ] T012 [US1] Confirm the fast path end-to-end: run `tests/run-bash.sh` on this machine, verify it is ≤ half the T001 parallel baseline (b) (SC-001, like-for-like) and that 0 tests skip for missing tooling (SC-002); also record its ratio to the serial baseline (a) for context; record all timings in `specs/009-optimize-test-performance/baseline.md`.
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

- [ ] T014 [US2] Update the CI-guard tests that assert workflow invocations so they match the new commands BEFORE editing the workflows, then observe them fail against the current workflow: adjust `tests/bash/ci/test_workflow_kcov_runner.bats` and any assertion in `tests/bash/ci/` that pins `bats --jobs`/toolchain-install lines, to expect `tests/run-bash.sh` and the cached/targeted-install shape. Keep every gate-existence assertion (SC-006).

### Implementation

- [ ] T015 [US2] Edit `.github/workflows/ci.yml`: replace `bats -r tests/bash --jobs …` with `tests/run-bash.sh`; drop the GNU `parallel` install (Linux + macOS) and stop requiring PowerShell for the Bash run; install `specify-cli` only in the job(s) that run the install-harness scenarios; keep the three-OS matrix and every job. Make T014 pass.
- [ ] T016 [US2] Add dependency caching to `.github/workflows/ci.yml` and `.github/workflows/gates.yml` via `actions/cache`: cache the Pester module (keyed on OS + pinned Pester version) and the `uv`-installed `specify-cli` (keyed on OS + pinned spec-kit ref); on a cache miss, install exactly as today (correct, slower). A cache hit must never change a gate verdict.
- [ ] T017 [US2] Edit `.github/workflows/gates.yml` so the Bash coverage job inherits the shim speedup (no pwsh under kcov) while keeping the 80% threshold, the `kcov-excl` regions, the kcov→traceability fallback, and the `changes` fail-open path filter unchanged; confirm the PowerShell coverage job and its 80% threshold are untouched.
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
- [ ] T021 [P] [US3] Verify no new flakiness (SC-009/FR-007): run `tests/run-bash.sh` 20 times consecutively; all 20 green. Confirm no test locates a process/file/port by name pattern or machine-wide scan (`grep -rn 'pgrep\|pkill\|lsof\|:[0-9]\{4,\}' tests/bash` reviewed; shim/runner use recorded identity only).
- [ ] T022 [P] [US3] Verify zero tests were removed (SC-007/FR-004): compare the current `@test` count and file list to the T001 baseline; the executed-assertion count must be ≥ baseline. Record in `baseline.md`.
- [ ] T023 [P] [US3] Verify the PowerShell port is not regressed (FR-013): run the Pester suite (`Invoke-Pester tests/powershell`) and confirm green + coverage ≥80% unchanged (CI or a pwsh-capable host).

**Checkpoint**: Every constitution gate proven intact at its prior strength.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation, changelog, and measured confirmation of the goals.

- [ ] T024 Run the full `quickstart.md` validation (V1–V7) and record pass/fail for each scenario in `baseline.md`.
- [ ] T025 [P] Measure the achieved CI savings on a representative PR (runner-minutes and wall-clock) vs. the T001/T002 baseline; confirm ≥40% minutes (SC-004) and ≥30% wall-clock (SC-005); record numbers in `baseline.md`.
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

T001 → (T004→T005→T006→T007→T008→T009) → T010→T011 → T015 → T024→T027.

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
2. Phase 2: Foundational — the `curl` shim; all 29 mock files green, parity intact (T004–T009).
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
