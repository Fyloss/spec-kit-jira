---
description: "Task list 021 — A Reconcile Costs Seconds, and Costs Nothing When Nothing Changed"
---

# Tasks: A Reconcile Costs Seconds, and Costs Nothing When Nothing Changed

**Input**: Design documents from `/specs/021-reconcile-performance/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: REQUIRED, not optional. Constitution Principle XIII mandates TDD with a ≥80% coverage gate and
states that no implementation task may be planned without its test task preceding it. Every implementation
task below is preceded by a test that must be observed to fail first.

**A note on what "failing first" means here.** Most of this feature changes *how fast* something happens,
not *what* happens, so a test that asserts behaviour would pass before the change and prove nothing. The
failing tests are therefore **counting** tests — how many times the secret store was consulted, how many
lines `calls.log` holds — and **differential** tests — the same scenario run two ways, diffed. Those do
fail before the change, for the right reason.

**Organization**: grouped by user story. Phase 3 (User Story 1) is the instrument every later phase is
measured with, which is why it is the MVP even though User Story 2 is the change an operator would notice
first (research R10, spec FR-001…FR-006).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: `[US1]`..`[US6]`, mapping to the user stories in spec.md
- Exact file paths are given in every task

## Path Conventions

Two native ports, mirrored trees (see plan.md → Project Structure):

- Bash: `scripts/bash/{lib,sink/jira,commands}/` — tests in `tests/bash/{lib,sink,commands}/`
- PowerShell: `scripts/powershell/{lib,sink/jira,commands}/` — tests in `tests/powershell/{lib,sink,commands}/`
- Cross-port byte equivalence: `tests/conformance/scenarios/`, mock in `tests/conformance/mock-jira/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: establish the "nothing else moved" baseline this feature is judged against. No project
initialisation — this changes a shipped codebase.

- [x] T001 Capture the pre-change baseline: run `tests/run-bash.sh` and `bash tests/conformance/ci-conformance.sh`, and record the resulting pass counts so Phase 9 can prove no other behaviour moved. **DONE 2026-08-07 on `feat/improve-scripts-performances`, both green:**

  | Suite | Result |
  | --- | --- |
  | `tests/run-bash.sh` (Bats 1.13.0, FULL) | 167 files, **1667 tests**, 0 files failed — PASSED |
  | `bash tests/conformance/ci-conformance.sh` | exit 0, **0** divergence lines, **107** scenarios in the corpus |

  Conformance success is silent — there is no pass banner. The evidence is exit 0 together with zero lines
  matching `conformance divergence`; the temporary paths printed at the end of the log are harness noise.
  Phase 9's T016/T033/T045/T061 comparisons are against **these** counts, which will grow as this feature adds
  tests: what must not change is `files failed: 0` and `0 divergence lines`.
- [x] T002 [P] Confirm the linters are clean at baseline. Use the **CI invocation**, not a whole-tree scan: `find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +` (`.github/workflows/ci.yml:120`) and `actionlint`. A bare `shellcheck $(git ls-files '*.sh')` also lints the spec-kit host's own scripts under `.specify/scripts/bash/`, which are not ours and are not clean — it is not the gate. **DONE 2026-08-07: both clean, exit 0.**
- [x] T003 [P] Record `main`'s current `windows-latest` check-run annotations as the Windows baseline — `main` has been red there since feature 015, so a red run on this branch proves nothing until it is diffed against this list. **DONE 2026-08-07**, `main` @ `aa19a6e`, check-run `92778816758`, job "Unit suites (windows-latest)", conclusion `failure`. The baseline is **exactly one** failing test plus the job's exit-1 rollup:

  ```text
  [failure] refuses plan.md before any request, exit 1, plan.md untouched (§5 T1, T2)   478ms
  [failure] Process completed with exit code 1.
  ```

  (Two further annotations are runner noise, not ours: the Node.js 20 deprecation notice and a `uv.lock` cache-glob warning.)

  **This baseline is load-bearing for Phase 4, not just for Phase 9.** The one test already red on Windows is feature 017's target guard — the very path T021b adds a state-phase scenario to. Expect that scenario to fail on `windows-latest` for a reason this branch did not cause, and diff against this line before attributing it here. Per the standing rule: at most one Windows retry, then hand the result back.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the shared *test* infrastructure every later phase asserts through. There is no shared
production code here — this feature's modules are per-story.

**⚠️ CRITICAL**: no user story below can assert its central claim without T004 and T005.

- [ ] T004 [P] Add a `calls.log` request-counting helper to `tests/bash/helpers/` and its Pester twin in `tests/powershell/helpers/`, returning the number of requests a scenario issued and the count per URL path — the authoritative request count for US2, US4, and US5 (research R5: it is subshell-proof where an in-process counter is not)
- [ ] T005 [P] Add a counting secret-store stub to `tests/bash/helpers/` and `tests/powershell/helpers/`: it wraps the existing `_CRED_SECRET_TOKEN` seam and records each invocation to a run-scoped file, so a test asserts on a count it recorded rather than on a machine-wide scan (Constitution XIII test isolation)
- [ ] T006 Prove that a conformance scenario's `env` block reaches the port for `SPEC_KIT_JIRA_TIMING` and `_TIMING_FAKE_CLOCK` despite the prefix scrub in `tests/conformance/run-scenario.sh` (the scrub runs before the `env` block is applied, so this is expected to pass unmodified — a failure here means the harness needs an exemption and that is a change to make now, not in Phase 3)

**Checkpoint**: the suites can now count requests and secret-store consultations. Nothing about the product has changed.

---

## Phase 3: User Story 1 — A run explains where its time went (Priority: P1) 🎯 MVP

**Goal**: one documented switch makes a reconcile report, per phase, how long it took and how many tracker
requests it issued — on stderr, changing nothing else.

**Independent Test**: run the same scenario with the switch off and on; assert stdout, exit code, every
written file, and `calls.log` are byte-identical, and that only the second run emitted a per-phase
breakdown on stderr.

**Why first**: every later phase's acceptance is a number this phase produces. Research R10 refuses to
admit an optimisation whose cost the instrument did not find.

### Tests for User Story 1 (write first, observe failing)

- [ ] T007 [P] [US1] Write `tests/bash/lib/test_timing.bats`: the three clock tiers of research R1 resolve correctly and the third announces its degradation; phase marks accumulate; the report renders the fixed-width shape of `contracts/timing-report.md` §2; `_TIMING_FAKE_CLOCK` yields deterministic durations and returns its last reading when exhausted
- [ ] T008 [P] [US1] Write the Pester twin `tests/powershell/lib/Timing.Tests.ps1` asserting the same shape and the same phase names
- [ ] T009 [P] [US1] Add conformance scenarios `tests/conformance/scenarios/us021-timing-off.json` and `us021-timing-on.json` (the second setting `SPEC_KIT_JIRA_TIMING` and `_TIMING_FAKE_CLOCK` in its `env` block), asserting invariants T1–T6 of `contracts/timing-report.md` §3. Invariant T8 — a short-circuited run reports `prereq`, `state`, and the total and nothing else — needs Phase 4 and is asserted there by T020
- [ ] T010 [P] [US1] Extend `tests/bash/lib/test_token_leak.bats` and `tests/powershell/lib/TokenLeak.Tests.ps1` with invariant T7: run with timing **and** tracing on at maximum verbosity, and assert neither the token nor the derived base64 value appears anywhere in the captured output

### Implementation for User Story 1

- [ ] T011 [P] [US1] Implement `scripts/bash/lib/timing.sh`: resolve the clock strategy once at load (research R1 — `EPOCHREALTIME`, then a probed `date +%s%N`, then whole seconds), and expose `timing_phase_begin`, `timing_phase_end`, `timing_report`. Route no output through `jq` directly (`lib/output.sh` owns that), and put no `$'\r\n'` in any glob pattern
- [ ] T012 [P] [US1] Implement `scripts/powershell/lib/Timing.psm1` using `[datetime]::UtcNow.Ticks`, with the same function names' PowerShell equivalents and an `Export-ModuleMember -Function` list at the end of the file
- [ ] T013 [US1] Add the non-exported `JIRA_REQUEST_COUNT` to `scripts/bash/sink/jira/client.sh` and its `$script:` twin to `scripts/powershell/sink/jira/Client.psm1`, incremented once per curl attempt including retries, and document the command-substitution undercount boundary of `contracts/timing-report.md` §6 in the code comment
- [ ] T014 [US1] Wire the eight phase marks into `scripts/bash/commands/reconcile.sh` — `prereq`, `state`, `config`, `parse`, `gate`, `recognition`, `plan`, `apply` — placed **outside** every function that suspends xtrace, never inside one. `gate` brackets `hierarchy_mandatory_gate` (`reconcile.sh:652`), which runs **before** `recognition_run` (`:780`, `:924`), not after it; `state` brackets the short-circuit of Phase 4 and is the only phase besides `prereq` a short-circuited run reaches
- [ ] T015 [US1] Wire the same eight marks into `scripts/powershell/commands/Reconcile.psm1`
- [ ] T016 [US1] Run `tests/run-bash.sh`, the Pester suite, and `bash tests/conformance/ci-conformance.sh`: all green, and T001's counts unchanged except for the new tests
- [ ] T017 [US1] Record the **BEFORE** measurement on the real instance per `quickstart.md` §7: a changed run and an unchanged run, both with the switch on, saved into this file's Measurement Log below. Every later phase is judged against these numbers

**Checkpoint**: the feature can now be measured. Nothing is faster yet, and that is the point.

---

## Phase 4: User Story 2 — A specification nobody touched costs nothing (Priority: P1)

**Goal**: a re-run whose local inputs are unchanged exits successfully in under a second, having issued
zero tracker requests.

**Independent Test**: reconcile a fixture to completion, reconcile it again unchanged, assert
`calls.log` is empty, the exit code is 0, and the summary names the short-circuit. Then touch the
specification and assert the next run reconciles in full.

### Tests for User Story 2 (write first, observe failing)

- [ ] T017a [US2] **Before writing any test**, sweep every option `cmd_reconcile` accepts and decide, one by one, whether it changes the action set — `--on-drift` provably does (`scripts/bash/commands/reconcile.sh:436, 1131, 1171, 1192`), and it is already recorded in the document; `--style`, `--child-type`, `--issue-type`, `--field-default`, `--field-value`, `--accept-defaults`, and `--use-team` are unexamined. Every option that changes the action set becomes a field of the document or a documented reason it cannot. Spec A-2 calls a missing input a defect, not a gap, because it produces a wrongful skip
- [ ] T018 [P] [US2] Write `tests/bash/lib/test_run_state.bats`: `run_state_compose` is deterministic and byte-identical across repeated calls; each row of the decision table in `contracts/run-state.md` §3 produces the stated outcome; the document carries no credential; `git hash-object --no-filters` is the hashing primitive; the document carries **no** resolved project key, because the phase runs before routing resolves
- [ ] T019 [P] [US2] Write the Pester twin `tests/powershell/lib/RunState.Tests.ps1`, asserting the composed document is byte-identical to the Bash port's for the same inputs
- [ ] T020 [P] [US2] Add conformance scenario `tests/conformance/scenarios/us021-state-unchanged.json` using the harness's two-run `runs` array: assert the second run's `calls.log` is empty, its exit is 0, and its stdout names the short-circuit — and, with `SPEC_KIT_JIRA_TIMING` set in the `env` block, that its stderr carries only `prereq`, `state`, and the total (invariant T8 of `contracts/timing-report.md` §3)
- [ ] T021 [P] [US2] Add fail-open conformance scenarios `us021-state-corrupt.json`, `us021-state-version-changed.json`, and `us021-state-config-changed.json`: each must produce a **full** reconcile, never a skip
- [ ] T021a [P] [US2] Add the remaining fail-open scenarios of `contracts/run-state.md` §9 that T020 and T021 do not cover: `us021-state-tasks-appeared.json` and `us021-state-tasks-deleted.json` (the `inputs` key appearing and disappearing must each invalidate), `us021-state-first-run.json`, and `us021-state-ondrift-changed.json` (reconcile with `--on-drift=abort`, then with `--on-drift=proceed`, and assert the second run reconciles in full)
- [ ] T021b [P] [US2] Add the two FR-027 placement scenarios: a **disabled lifecycle event** and a **rejected target** (`plan.md` passed instead of `spec.md`), each run with a matching state already recorded, each asserting today's exact behaviour — exit 0 silently with no config read, and exit 1 with zero requests — and that the state file was never read
- [ ] T022 [P] [US2] Write bats + Pester assertions that `--dry-run` neither reads nor writes the state document, and that `--force` bypasses the read and still records on success
- [ ] T023 [P] [US2] Write bats + Pester assertions that no state is recorded after a run that warned, stopped at a pending confirmation, or failed — one test per case, each asserting the file is absent afterwards
- [ ] T024 [P] [US2] Write a bats test that two concurrent reconciles never observe a partial document and never wrongly skip, identifying each run by a path the test itself created (Constitution XIII test isolation — no machine-wide scan)
- [ ] T025 [P] [US2] Write a bats test that `git status --porcelain` is clean after a short-circuit in a repository whose root `.gitignore` predates this feature, proving the self-ignoring `.specify/jira/state/.gitignore` carries the guarantee

### Implementation for User Story 2

- [ ] T026 [P] [US2] Implement `scripts/bash/lib/run_state.sh` — `run_state_compose`, `run_state_matches`, `run_state_record` per `contracts/run-state.md` §1, serialising through `lib/output.sh`'s `json_canonical`, and creating `.specify/jira/state/.gitignore` containing `*` when it creates the directory
- [ ] T027 [P] [US2] Implement `scripts/powershell/lib/RunState.psm1` as the twin, hashing via `git hash-object --no-filters <path>` on a file (never via stdin, to avoid a PowerShell encoding divergence)
- [ ] T028 [P] [US2] Add `--force` to `scripts/bash/lib/cli.sh` and `scripts/powershell/lib/Cli.psm1`, emitting it in the existing fixed key order so both ports produce identical parse bytes
- [ ] T029 [US2] Wire the state phase into `scripts/bash/commands/reconcile.sh` after the dispatch guard and the target guard and before the config phase, per `contracts/run-state.md` §2. It runs before routing resolves, so it composes from hashed inputs only — there is no resolved project key available to it
- [ ] T030 [US2] Wire the same state phase into `scripts/powershell/commands/Reconcile.psm1`
- [ ] T031 [US2] Record the state on success in both ports, only under the four conditions of `contracts/run-state.md` §4, writing to a sibling temporary file and renaming
- [ ] T032 [US2] Add the short-circuit line to the run summary in both ports, naming the file that recorded it (Principle XVI: a short-circuited run must not look like a run that did nothing for unclear reasons)
- [ ] T033 [US2] Run all three suites: green, and the new scenarios assert zero requests

**Checkpoint**: the commonest case is now free. User Story 1's report should show a short-circuited run
reporting `prereq`, `state`, and the total, and nothing else.

---

## Phase 5: User Story 3 — The secret store is asked once, not once per request (Priority: P1)

**Goal**: the operating system's secret store is consulted at most once per reconcile process, with the
credential discipline unchanged in every respect.

**Independent Test**: with the counting stub from T005, run a reconcile issuing many requests including a
retried one, and assert the counter reads exactly 1. Separately assert the token appears in no argument
list, no child environment, no trace, no transcript, and no file.

**Depends on**: Phase 4, for T035's zero-consultation case only.

### Tests for User Story 3 (write first, observe failing)

- [ ] T034 [P] [US3] Write a bats test asserting the secret store is consulted **exactly once** for a run issuing many requests including one retried after a 429 — this fails today with the request count, which is the whole point of the story
- [ ] T035 [P] [US3] Write bats tests asserting **zero** consultations for a run that short-circuits on run state, a run in a repository with no base URL, and a run whose token came from the environment
- [ ] T036 [P] [US3] Write a bats test asserting the cache variable is not exported (`declare -p` shows no `-x`) and that a child process spawned mid-run has no environment entry holding the token
- [ ] T037 [P] [US3] Write bats tests for rotation (two runs, two different stub tokens, the second run uses the second token) and for the `unresolved` state being distinct from an empty token
- [ ] T038 [P] [US3] **Constitution v1.3.0 scope** — write bats tests for the macOS and Linux rungs' fall-through paths that the existing `tests/bash/lib/test_credentials.bats` does not cover: `security` / `secret-tool` absent from PATH, and present but exiting non-zero. Each must fall through silently to `.env` with no error output and no non-zero return
- [ ] T039 [P] [US3] Write the Pester twins of T034, T036, T037, and T038 in `tests/powershell/lib/Credentials.Tests.ps1`
- [ ] T040 [P] [US3] Extend the token-leak suites to assert the derived base64 authorisation value — not only the raw token — is absent from every stream, the state document, and every temp path

### Implementation for User Story 3

- [ ] T041 [P] [US3] Add the non-exported `_CRED_CACHE_STATE` / `_CRED_CACHE_TOKEN` pair and `cred_prime_cache` to `scripts/bash/lib/credentials.sh`, keeping every existing function-local xtrace-suspension bracket and the `kcov-excl` markers intact
- [ ] T042 [P] [US3] Add the `$script:` cache to `scripts/powershell/lib/Credentials.psm1`, and confirm no module in the dependency chain re-imports it with `-Force` mid-run (a `-Force` import in a sink module clobbers caller scope and would silently empty the cache)
- [ ] T043 [US3] Call `cred_prime_cache` exactly once from `cmd_reconcile` in `scripts/bash/commands/reconcile.sh`, **in the main shell**, after the state phase and after the config phase has established a base URL — research R3: a cache filled inside a `$(jira_request …)` subshell dies with it, so this call site is the requirement, not an optimisation
- [ ] T044 [US3] Run T034 again and confirm the counter reads 1 rather than the request count — if it reads the request count, the prime is in the wrong place
- [ ] T045 [US3] Run all three suites: green, with the credential critical path still near 100% covered

**Checkpoint**: the largest constant-factor cost is gone. Compare the `apply` phase duration against T017's before numbers.

---

## Phase 6: User Story 4 — Recognition reads the estate in a bounded exchange (Priority: P2)

**Goal**: the read phase costs one request per 100 recorded keys instead of one per key, with every
classification unchanged.

**Independent Test**: against the mock, assert the read-phase request count is bounded by a constant plus
one per chunk. Replay every existing recognition fixture and assert identical classifications, warnings,
and exit codes.

### Tests for User Story 4 (write first, observe failing)

- [ ] T046 [P] [US4] Add a `POST /rest/api/3/issue/bulkfetch` handler to `tests/conformance/mock-jira/`, composing its response from the same per-key fixtures the mock already serves, honouring the requested `fields` and `properties`, returning issues in ascending id order, and **omitting** both unknown and forbidden keys as the real endpoint does
- [ ] T047 [P] [US4] Write `tests/bash/sink/test_prefetch.bats`: chunking at 100; case-insensitive key matching; a returned key that differs from the requested one is matched by value, never by position; field projection yields exactly the caller's field set; a non-2xx response empties the map and returns 0
- [ ] T048 [P] [US4] Write the Pester twin `tests/powershell/sink/Prefetch.Tests.ps1`
- [ ] T049 [P] [US4] Add the **differential** conformance set `tests/conformance/scenarios/us021-prefetch-*.json` and a runner assertion that each scenario is byte-identical with `_RECOGNITION_NO_PREFETCH=1` and without it, across stdout, stderr, exit, and the post-run tree — only `calls.log` may differ, and only by having no more lines than the unprefetched run and no line that is neither a prefetch nor a fall-through read (with a single recorded key the two are equal in length, so "fewer" would be the wrong assertion)
- [ ] T050 [P] [US4] Add conformance scenarios for the classification cases of `contracts/recognition-prefetch.md` §6: a deleted key classifies `new` with `recreated_from`; a forbidden key fails the whole specification closed at exit 3 with zero writes; a `400` and a `401` from `bulkfetch` both fall through to today's per-key behaviour
- [ ] T051 [P] [US4] Add conformance scenarios for the counting cases: 61 keys → 1 read request; 101 keys → 2; 61 keys with one deleted → 2; 0 recorded keys → 0 prefetch requests
- [ ] T052 [P] [US4] Add a conformance scenario asserting a ticket created moments earlier in the same run sequence is recognised — the immediate-consistency assertion that makes research R2's substitution legitimate rather than a reintroduction of the feature 005 defect

### Implementation for User Story 4

- [ ] T053 [P] [US4] Implement `scripts/bash/sink/jira/prefetch.sh` — `prefetch_load`, `prefetch_get`, `prefetch_reset` per `contracts/recognition-prefetch.md` §2, always sending an explicit `fields` list (the endpoint's default is `*navigable`, unlike `GET /issue/{key}`)
- [ ] T054 [P] [US4] Implement `scripts/powershell/sink/jira/Prefetch.psm1` as the twin
- [ ] T055 [US4] Make `_recognition_read` and `_recognition_read_parent` in `scripts/bash/sink/jira/recognition.sh` consult `prefetch_get` first and, on a miss, execute today's `GET` **unchanged** — the fall-through is what preserves the 404/403 distinction the endpoint cannot express
- [ ] T056 [US4] Apply the same change to `scripts/powershell/sink/jira/Recognition.psm1`
- [ ] T057 [US4] Call `prefetch_load` once from the command layer in both ports, with the full key list — parent, stories, and tasks — before the recognition phase begins
- [ ] T058 [US4] Add the `_RECOGNITION_NO_PREFETCH` test seam to both ports, underscore-prefixed and absent from the CLI contract
- [ ] T059 [US4] Update the header comment of `scripts/bash/sink/jira/recognition.sh`, which currently states that recognition never batches: replace it with why a key-addressed bulk fetch is admissible where a search is not, so the next reader inherits research R2 instead of re-deriving it
- [ ] T060 [US4] **Confirm assumption A-1 against the live instance**: that `bulkfetch` returns a ticket created seconds earlier. If it does not, revert to per-key reads, take the speed from Phase 7's connection reuse, and record the SC-003 shortfall in the Measurement Log rather than working around it
- [ ] T061 [US4] Run all three suites: green, with the differential set byte-identical and the counting scenarios passing

**Checkpoint**: the read phase no longer scales with the estate. SC-003 is now assertable.

---

## Phase 7: User Story 5 — Fewer connections and fewer processes (Priority: P3)

**Goal**: sequential independent reads share one connection, and the hot loops stop forking a helper per
field. Observable behaviour is frozen.

**Independent Test**: the entire existing conformance corpus, unmodified, stays green. A scenario that had
to be edited to accommodate this phase is a behaviour change, and behaviour was supposed to be frozen.

### Tests for User Story 5 (write first, observe failing)

- [ ] T062 [US5] Write a bats test asserting that a chained independent read set produces the same bodies, the same statuses, and the same `calls.log` ordering as the same reads issued one curl at a time
- [ ] T063 [P] [US5] Write a bats test asserting the process-spawn count of one per-story loop iteration falls, using a counting wrapper on the `jq` seam recorded to a run-scoped file
- [ ] T063b [P] [US5] Write a conformance assertion for the FR-031 prohibition: the same fixture reconciled twice produces a byte-identical `calls.log`, and the two ports produce a byte-identical `calls.log` for that fixture — the observable proof that nothing on the reconcile path runs concurrently
- [ ] T063a [P] [US5] Write a bats test asserting the **ordered write path is untouched** by this phase: a fixture whose parent and children must be written in order produces a `calls.log` whose ordering is byte-identical before and after Phase 7, and no `--next` chain spans an ordering edge (spec FR-030, US5 AC2)

### Implementation for User Story 5

- [ ] T064 [US5] Add `--next` chaining for independent reads to `scripts/bash/sink/jira/client.sh`, each response written to its own `--output` file, keeping the auth config on stdin and the whole function's xtrace suspension intact. Do **not** touch the ordered write path
- [ ] T065 [US5] De-fork the first per-story loop in `scripts/bash/commands/reconcile.sh` to one `jq -r '[…] | @tsv'` per item, keeping summaries and descriptions in JSON and never round-tripping them through a shell variable (research R9)
- [ ] T066 [US5] De-fork the remaining per-story and per-task loops one at a time, running `bash tests/conformance/ci-conformance.sh` green between each — not once at the end
- [ ] T068 [US5] Measure with the User Story 1 instrument and **drop any de-forking the instrument does not justify** — research R10 refuses an optimisation performed for tidiness

**This phase is Bash-only, deliberately.** An earlier draft carried a task applying the same consolidation to
`scripts/powershell/commands/Reconcile.psm1`. It is removed. FR-032 names a cost — "one helper process per
item per field" — that does not exist on the PowerShell port, which parses with built-in cmdlets and forks
nothing; the consolidation there would be a refactor no requirement demands, which Principle XV forbids and
Principle XIII would have required a failing Pester test for first. FR-041 permits exactly this: "a change
with no observable difference may differ in mechanism between ports, never in outcome." If measurement on
Windows later finds a per-item cost, that is a task with its own failing test, not a tidy-up smuggled in here.

**Checkpoint**: the changed run is as fast as it is going to get. Record the numbers.

---

## Phase 8: User Story 6 — Windows keeps its token in an encrypted vault (Priority: P3)

**Goal**: the Windows resolution order becomes environment → SecretManagement vault → gitignored `.env`,
matching macOS and Linux.

**Independent Test**: with a stand-in for the vault, the token resolves from it when the environment
variable is absent; each of the four unavailability paths falls through silently, without an error and
without waiting.

**Authorised by**: constitution **v1.3.0** (2026-08-07). This phase was gated on that amendment; it is not
gated any more. The amendment's all-platform fall-through rule was already discharged by T038 and T039.

### Tests for User Story 6 (write first, observe failing)

- [ ] T069 [P] [US6] Write a Pester test in `tests/powershell/lib/Credentials.Tests.ps1` asserting the token resolves from a stubbed vault when `$env:JIRA_API_TOKEN` is absent, and that the environment still wins over it
- [ ] T070 [P] [US6] Write Pester tests for the four fall-through paths of `contracts/credential-cache.md` §5 — module absent, no vault registered, no secret named `spec-kit-jira`, vault locked — each asserting silence, no error record, and **that the call returns rather than waiting**
- [ ] T071 [P] [US6] Write a Pester test asserting `prereq_check` passes on a host without the module (Constitution IV, v1.3.0: the rung is never a prerequisite)
- [ ] T072 [P] [US6] Write a Pester test asserting a vault-sourced token never enters `$env:` and never appears in the output of an active `Start-Transcript`

### Implementation for User Story 6

- [ ] T073 [US6] Implement `Get-JiraSecretManagerToken` in `scripts/powershell/lib/Credentials.psm1` to read `Get-Secret -Name spec-kit-jira -AsPlainText` from the registered default vault, keeping `$env:_CRED_SECRET_TOKEN` as the precedence-taking test seam, and swallowing every failure into `$null` with no error record and no prompt
- [ ] T074 [US6] Run the Pester suite and `bash tests/conformance/ci-conformance.sh`: green, with the existing environment and `.env` paths unchanged

**Checkpoint**: all three operating systems have the same three-rung credential shape.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T075 [P] Update `docs/05-reconcile-flow.md`: add the state phase to the pipeline diagram between the target guard and routing, and state the out-of-band-drift trade in the same breath as the speed
- [ ] T076 [P] Update `docs/07-configuration-and-secrets.md`: replace the paragraph beginning "there is no OS secret-manager rung on Windows" and add Windows to the three-rung diagram
- [ ] T077 [P] Update `README.md` and `INSTALL.md` with a Windows storage section mirroring the macOS and Linux ones — `Install-Module` for SecretManagement and SecretStore, `Register-SecretVault`, `Set-Secret` — including the `Set-SecretStoreConfiguration -Authentication None` trade-off for hook-driven use, and remove the "do not put it in the Credential Manager" guidance
- [ ] T078 [P] Update `docs/02-module-architecture.md` with the three new modules per port and the prefetch's place in the sink
- [ ] T079 [P] Add the CHANGELOG entry, naming the behavioural change an operator will notice: an unchanged reconcile now performs no tracker read, and out-of-band tracker changes are not detected until a local edit or `--force`
- [ ] T080 Run `quickstart.md` end to end, all seven steps
- [ ] T081 Record the **AFTER** measurement on the real instance beside T017's before numbers in the Measurement Log below, and state plainly whether SC-001 and SC-002 were met
- [ ] T082 Confirm the three-OS matrix is green; diff any `windows-latest` annotations against T003's baseline before attributing a failure to this branch, and retry the Windows job at most once before handing the result back
- [ ] T083 Confirm the coverage gate: ≥80% statement coverage on both ports, with credential resolution near 100%
- [ ] T084 `shellcheck $(git ls-files '*.sh')` and `actionlint` clean

---

## Measurement Log

Research R10 requires every optimisation to be justified by a number the tool produced. Fill this in as the
phases land; an entry that shows no improvement is a reason to drop the change, not to keep it quietly.

| Phase | Metric | Before (T017) | After | Met? |
| --- | --- | --- | --- | --- |
| — | Unchanged run, total wall time | | | SC-001 < 1 s |
| — | Unchanged run, tracker requests | | | SC-001 = 0 |
| — | Changed run, total wall time | | | SC-002 < 30 s |
| 5 | Secret-store consultations per run | | | SC-004 ≤ 1 |
| 6 | Read-phase requests, 61 recorded keys | | | SC-003 |
| 7 | `apply` phase wall time | | | — |
| 7 | Helper processes per story-loop iteration | | | — |

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately
- **Foundational (Phase 2)**: depends on Setup — **blocks every user story**, because no story can assert its central claim without the counting helpers
- **User Story 1 (Phase 3)**: depends on Phase 2. Blocks nothing formally, but research R10 requires it first so later phases are measured rather than asserted
- **User Story 2 (Phase 4)**: depends on Phase 2
- **User Story 3 (Phase 5)**: depends on Phase 2; T035's zero-consultation case additionally depends on Phase 4
- **User Story 4 (Phase 6)**: depends on Phase 2
- **User Story 5 (Phase 7)**: depends on Phase 6 — de-forking the recognition loop after the prefetch lands avoids doing it twice
- **User Story 6 (Phase 8)**: depends on T038/T039 in Phase 5 (the all-platform fall-through tests the constitution amendment requires)
- **Polish (Phase 9)**: depends on every story that is being shipped

### Within Each User Story

- Tests are written and observed to **fail** before any implementation task in the same phase
- Library modules before their call sites
- Both ports before the conformance assertion that compares them
- Story green before moving to the next priority

### Parallel Opportunities

- T002 and T003 in parallel
- T004 and T005 in parallel
- Every `[P]` test task within a phase in parallel — they touch different files
- The two port implementations of a module are `[P]`: `timing.sh` / `Timing.psm1`, `run_state.sh` / `RunState.psm1`, `prefetch.sh` / `Prefetch.psm1`
- Phases 4, 5, and 6 can be worked in parallel by different people once Phase 3 has landed the instrument
- Phase 9's documentation tasks T075–T079 are all `[P]`

### Parallel Example: User Story 2

```bash
# Launch the failing tests together:
Task: "Write tests/bash/lib/test_run_state.bats"                        # T018
Task: "Write tests/powershell/lib/RunState.Tests.ps1"                   # T019
Task: "Add tests/conformance/scenarios/us021-state-unchanged.json"      # T020
Task: "Add the three fail-open conformance scenarios"                   # T021

# Then the two ports together:
Task: "Implement scripts/bash/lib/run_state.sh"                         # T026
Task: "Implement scripts/powershell/lib/RunState.psm1"                  # T027
Task: "Add --force to lib/cli.sh and lib/Cli.psm1"                      # T028
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1 → Phase 2 → Phase 3.
2. **STOP AND VALIDATE**: `SPEC_KIT_JIRA_TIMING=1` on the real instance produces a per-phase breakdown, and
   the corpus proves the mode changes nothing else.
3. This is shippable on its own: the slowness becomes diagnosable even if nothing else lands, and T017's
   numbers decide which of the remaining phases are worth their risk.

### Incremental delivery

1. Setup + Foundational → the suites can count.
2. **US1** → the run explains itself → ship (MVP).
3. **US2** → the commonest case is free → ship. This is the change an operator notices.
4. **US3** → the largest constant factor is gone → ship.
5. **US4** → the read phase stops scaling with the estate → ship.
6. **US5** → the remaining constant factors → ship, or drop what T068 does not justify.
7. **US6** → three-OS credential parity → ship.

Each step is independently valuable and independently revertible.

### Two places to stop and think rather than push through

- **T060** — if the live instance does not return a recently created ticket from `bulkfetch`, the honest
  outcome is per-key reads and a recorded SC-003 shortfall. Feature 005's defect is not available as a
  performance budget.
- **T068** — if the instrument does not find the fork cost, Phase 7's de-forking is a refactor with a story
  about it, and Principle XV says do not ship it.
