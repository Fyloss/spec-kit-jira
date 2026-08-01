# Feature Specification: Optimize Automated Test Performance (macOS / Linux)

**Feature Branch**: `feat/improve-tests-2`

**Created**: 2026-07-31

**Status**: Draft

**Input**: User description: "la durée des tests auto sont beaucoup trop longue pour Mac OS et Linux, ce qui ralentie les agents pour le développement mais aussi qui consomme énormement de ressource sur la CI Github Actions. Optimise au maximum les tests pour améliorer l'expérience de développement et éconimiser des ressources tout en assurant la qualité du code"

## Overview

The automated test suite for the Bash implementation (which serves macOS and Linux)
takes too long to run. This hurts two audiences at once:

- **Developers and AI coding agents working locally**: slow feedback loops break
  concentration and, for autonomous agents, waste wall-clock time and budget on
  every iteration.
- **The GitHub Actions CI**: long, resource-hungry runs consume scarce runner
  minutes (macOS runners especially), delay merges, and inflate cost.

This feature makes the test suite run substantially faster and consume far fewer
resources, **without removing any test and without weakening any quality gate**
guaranteed by the project constitution (three-OS parity, 80% coverage,
conformance byte-equivalence). In addition, the Bash suite becomes runnable at
full speed with no tooling beyond `bats` and `jq` — no PowerShell install and no
GNU `parallel` required.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Fast local feedback for developers and agents (Priority: P1)

A developer or an AI coding agent changes a Bash script or a test, then runs the
Bash test suite locally to confirm the change. Today the run is slow because
nearly a third of the test files each spawn a fresh PowerShell mock server
(paying a cold-start every time), and the parallel execution path silently runs
**zero** tests when GNU `parallel` is absent — so the developer either waits a
long time or is misled into thinking the suite passed. The optimized suite
returns a correct pass/fail result quickly, using only `bats` and `jq`.

**Why this priority**: This is the core pain the request names first ("ralentie
les agents pour le développement"). Fast, trustworthy local feedback is the
highest-frequency interaction and the biggest multiplier on developer and agent
productivity. It is independently valuable even if CI were untouched.

**Independent Test**: On a clean macOS or Linux machine with only `bats` and `jq`
installed (no PowerShell, no GNU `parallel`), run the full Bash suite. It
completes in a fraction of today's time, executes every test (none silently
skipped for missing tooling), and reports an accurate result.

**Acceptance Scenarios**:

1. **Given** a machine with `bats` and `jq` but no PowerShell, **When** the
   developer runs the full Bash suite, **Then** every test executes (none fail or
   skip for a missing mock runtime) and the suite reports a correct pass/fail.
2. **Given** a machine without GNU `parallel`, **When** the developer runs the
   suite in its parallel mode, **Then** all tests actually execute (never zero),
   or the command fails loudly with an actionable message — never a false green.
3. **Given** an unchanged, already-passing tree, **When** the developer runs the
   suite twice in a row, **Then** both runs pass and the second is not slower than
   the first (no state leaked between tests that forces re-setup or serialization).
4. **Given** the suite runs in parallel, **When** any two tests run concurrently,
   **Then** they never collide on shared state (each identifies its own
   processes/files/ports by recorded identity, per Constitution XIII).

---

### User Story 2 - Cheaper, faster CI runs (Priority: P1)

A maintainer opens or updates a pull request. CI must validate it across the
three-OS matrix. Today each run reinstalls toolchains from scratch (Pester, the
Spec Kit CLI from git, Homebrew/apt packages) on every job and every OS, runs the
long kcov coverage measurement, and executes the conformance corpus against both
ports — consuming large amounts of runner time, including on the scarce macOS
runners. The optimized CI produces the same verdicts (same gates, same coverage
floor, same parity guarantees) while consuming markedly fewer runner minutes and
finishing sooner.

**Why this priority**: This is the second pain the request names ("consomme
énormement de ressource sur la CI"). It directly saves money and unblocks merges.
It is independently valuable and independently testable from the local-experience
work.

**Independent Test**: Trigger a CI run on a representative pull request before and
after the change; compare total runner minutes and wall-clock to completion. The
after-run consumes materially fewer minutes and finishes sooner, while every gate
that was blocking before is still blocking and still produces the same verdict on
the same input.

**Acceptance Scenarios**:

1. **Given** a pull request that touches Bash code, **When** CI runs, **Then**
   every gate that previously blocked (three-OS unit suites, conformance parity,
   80% Bash and PowerShell coverage, lint, static checks) still runs and still
   blocks, with the same pass/fail verdict it would have produced before.
2. **Given** repeated CI runs, **When** unchanged dependencies are needed, **Then**
   toolchains and downloaded tools are reused from cache rather than reinstalled
   from scratch on every run.
3. **Given** a pull request whose diff cannot affect a given gate's result, **When**
   CI runs, **Then** work that cannot change that gate's verdict is skipped or
   reused — never re-executed purely out of habit — provided skipping can never
   hide a real regression (fail-open on uncertainty).
4. **Given** the same commit, **When** the optimized CI and the previous CI both
   run, **Then** the set of blocking verdicts is identical (no gate silently
   dropped).

---

### User Story 3 - Quality guarantees fully preserved (Priority: P1)

A reviewer must be able to trust that the faster suite still proves everything the
slow one did. No test is deleted to gain speed; no coverage threshold is lowered;
the two ports are still proven byte-identical by the conformance corpus; and the
test-isolation discipline (identify state by recorded identity, green under
parallel execution) is upheld, not undermined, by the optimizations.

**Why this priority**: The request is explicit — "tout en assurant la qualité du
code". Speed that erodes the safety net is a regression, not an improvement. This
story is the guardrail on Stories 1 and 2.

**Independent Test**: Diff the set of executed test assertions and the set of
enforced gates before and after. The executed-assertion set is a superset-or-equal
(nothing dropped), the coverage floors are unchanged (≥80% both ports), and the
conformance corpus still runs every scenario against both ports with a
byte-identical comparison.

**Acceptance Scenarios**:

1. **Given** the optimized suite, **When** the full test inventory is enumerated,
   **Then** every assertion that ran before still runs (no test removed to save
   time).
2. **Given** the optimized coverage gate, **When** it runs on the mocked unit
   suites, **Then** the statement-coverage floor is still 80% for both ports and
   the denominator is not shrunk to inflate the percentage.
3. **Given** a deliberately introduced cross-port divergence, **When** the
   conformance corpus runs, **Then** it still fails (parity is still proven for
   every scenario against both ports).
4. **Given** the optimized harness, **When** the suite runs under maximum
   parallelism, **Then** it stays green and no test locates a process, file, or
   port by name pattern or machine-wide scan.

---

### Edge Cases

- **Mock runtime absent locally**: a Bash-only developer without PowerShell must
  still run every mock-dependent test. Tests must not fail or skip for a missing
  PowerShell runtime.
- **GNU `parallel` absent**: the parallel run path must never silently execute
  zero tests. It either runs all tests through an available mechanism or fails
  with a clear, actionable message.
- **Concurrency collisions**: sharing or reusing a mock across tests must not let
  one test observe or corrupt another's requests/state; isolation by recorded
  identity is mandatory.
- **CI cache miss / poisoning**: a stale or missing cache must degrade to a
  correct (if slower) run, never to a wrong verdict.
- **CI change-detection uncertainty**: if the system cannot determine whether a
  diff affects a gate, it must run the gate (fail-open), never skip it.
- **Flakiness introduced by parallelism**: increased concurrency must not turn a
  deterministic test into an intermittently failing one.
- **Windows/PowerShell port unaffected**: optimizations targeted at the Bash
  (macOS/Linux) suite must not regress the PowerShell port's tests or its parity
  with the Bash port.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The Bash test suite MUST run to completion using only `bats` and
  `jq` — no PowerShell runtime and no GNU `parallel` required for any test to
  execute.
- **FR-002**: Mock-dependent Bash tests MUST NOT incur a per-test PowerShell
  cold-start; the redundant repeated startup of the mock double MUST be eliminated
  (via a shared/reused mock, an in-suite lightweight double, or equivalent) while
  preserving each test's isolation.
- **FR-003**: The parallel execution path MUST either run every test without
  requiring GNU `parallel`, or, when a required mechanism is unavailable, fail
  loudly with an actionable message — it MUST NEVER report success while
  executing zero (or a silently reduced set of) tests.
- **FR-004**: No existing test assertion may be removed, disabled, or skipped to
  achieve the speed-up; the set of assertions executed after the change MUST be a
  superset of, or equal to, the set executed before.
- **FR-005**: The statement-coverage gate MUST remain at ≥80% for both the Bash
  and PowerShell ports, computed on the mocked unit suites, with no shrinking of
  the measured denominator to inflate the percentage (Constitution XIII).
- **FR-006**: The conformance corpus MUST continue to run every scenario against
  both ports and compare the captured stdout, exit code, Jira call sequence, and
  written-file tree for byte-identical equality (Constitution VI).
- **FR-007**: Every test MUST identify the state it observes, asserts on, or
  cleans up (processes, files, directories, ports) by an identifier it recorded
  from what it spawned or created — never by a name pattern or machine-wide scan —
  and the whole suite MUST stay green under maximum parallel execution
  (Constitution XIII).
- **FR-008**: CI MUST reuse toolchains and downloaded tools (test runners,
  coverage tooling, the Spec Kit CLI, OS packages) across runs via caching rather
  than reinstalling them from scratch on every run, wherever caching cannot change
  a gate's verdict.
- **FR-009**: CI MUST avoid re-executing work whose result a given diff cannot
  change (e.g. via path-scoped triggering or result reuse), on the strict
  condition that skipping can never hide a regression; when affectedness is
  uncertain, CI MUST run the work (fail-open). This is satisfied by
  toolchain/result caching and the CI's pre-existing path filter; no new
  affectedness-based gate-skipping is introduced (test-tiering that changes which
  gates a PR runs is Out of Scope).
- **FR-010**: The set of blocking CI gates and their verdicts on a given commit
  MUST be identical before and after this change: no gate may be silently dropped,
  downgraded to non-blocking, or made to pass on input it would previously have
  failed.
- **FR-011**: The three-OS matrix (Linux, macOS, Windows) green status MUST remain
  a merge gate (Constitution VI, XII).
- **FR-012**: Optimizations MUST NOT introduce test flakiness; a test that was
  deterministic MUST remain deterministic under the new execution model.
- **FR-013**: The change MUST NOT regress the PowerShell port's tests, its
  coverage, or its byte-for-byte parity with the Bash port.
- **FR-014**: Documentation describing how to run the tests locally MUST be
  updated to reflect the reduced tooling requirements and the fast path (per
  Constitution XVI, discoverable without reading source).
- **FR-015**: Per Constitution XIII (TDD) and X (regression tests), the silent
  "zero tests executed when GNU `parallel` is missing" behavior MUST be covered by
  a regression test written before its fix.

### Key Entities

- **Bash test suite**: the `bats` test corpus for the macOS/Linux implementation
  (~96 files, ~775 assertions today); the primary optimization target.
- **Mock Jira double**: the loopback HTTP server both ports drive over a base URL;
  today a per-test PowerShell process. Its startup cost and cross-runtime
  dependency are central to the local-speed problem.
- **Conformance corpus**: the ~39 language-agnostic scenarios run against both
  ports and diffed for byte-equivalence; a quality gate whose behavior must be
  preserved.
- **Coverage gate**: the ≥80% statement-coverage measurement for each port; a
  quality gate whose floor and honesty must be preserved.
- **CI pipeline**: the GitHub Actions workflows (unit matrix, static checks,
  conformance, coverage/gates) whose resource consumption is the second
  optimization target.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth | Unaffected — this feature changes only test execution and CI, not reconcile/write behavior or Jira artifact handling. |
| II | Zero-Churn Idempotency | Unaffected at the requirement level; the live idempotency suite (real Jira) is out of scope here and its guarantees are untouched. FR-004/FR-006 keep the mocked idempotency/zero-churn scenarios running. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Unaffected — no write or hook code path changes. The CI "fail-open on uncertainty" rule (FR-009) applies to *skipping test work*, not to production writes, and never hides a regression. |
| IV | Credential Security — Zero Tokens in the Tree | Preserved — no fixtures or logs gain credentials; the coverage tracer's secret-suspension behavior (Constitution XIII / NFR-3) MUST be retained by any harness change. |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected — no configuration layering changes. |
| VI | macOS / Linux / Windows Portability | Preserved and strengthened: FR-006/FR-011 keep the three-OS matrix and byte-identical conformance a merge gate; FR-013 forbids regressing the PowerShell port or parity. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Preserved — non-default workflow fixtures remain in the corpus (FR-004/FR-006); no engine assumptions change. |
| VIII | Neutral Engine / Jira Sink | Unaffected — the engine/sink separation and its CI grep checks are untouched; FR-010 keeps every static gate. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Preserved — privacy-tier fixtures/tests remain (FR-004); no guard behavior changes. |
| X | Self-Healing Automatic Mirror | Unaffected functionally; FR-015 honors the "every fixed bug ships with a regression test" rule for the zero-tests defect. |
| XI | Universal Dry-Run and Auditability | Unaffected — dry-run behavior and run summaries are unchanged; their tests keep running (FR-004). |
| XII | Quality and Catalog Publication | Preserved: FR-005/FR-010/FR-011 keep the mocked suite, lint, and coverage blocking on all three OSes; the live suite's non-blocking-on-forks rule is untouched. |
| XIII | TDD With a Minimum 80% Coverage | Central: FR-005 holds the 80% floor honestly; FR-007 enforces identity-based isolation and green-under-parallel; FR-015 requires a failing test first for the parallel defect. |
| XIV | KISS | The chosen approach removes complexity (a cross-runtime dependency, a fragile parallel path) rather than adding it; any new abstraction must be justified in the plan's Complexity Tracking. |
| XV | YAGNI | Only the optimizations required to hit the speed/resource goals are in scope; no speculative test infrastructure. Test-tiering that changes gating was explicitly excluded (see Out of Scope). |
| XVI | Human Readable | FR-014 updates the run-the-tests documentation; failure messages (e.g. the loud parallel-unavailable error, FR-003) name the problem and a remediation. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The full Bash test suite completes locally in **at most half** of its
  current wall-clock time on the same macOS or Linux machine. "Current wall-clock
  time" is the suite run in parallel (`bats --jobs`), so the optimized parallel
  runner is compared like-for-like and the improvement reflects the harness
  refactor, not concurrency alone.
- **SC-002**: A developer or agent can run the complete Bash suite with **only
  `bats` and `jq` installed** — zero PowerShell, zero GNU `parallel` — and every
  test executes (0 tests skipped or failed for missing tooling).
- **SC-003**: Running the parallel path without GNU `parallel` executes **100% of
  the tests** (never zero) or exits non-zero with an actionable message; it never
  reports a false green.
- **SC-004**: Total CI runner-minutes for a representative pull request drop by at
  least **40%** compared with the current pipeline, measured on an equivalent
  commit.
- **SC-005**: CI wall-clock time to a merge decision on a representative pull
  request is reduced by at least **30%**.
- **SC-006**: **100%** of the quality gates that block a merge today still block a
  merge after the change, with identical verdicts on identical input (no gate
  dropped or weakened).
- **SC-007**: **Zero** test assertions are removed or disabled to achieve the
  speed-up (the executed-assertion count is ≥ the pre-change count).
- **SC-008**: Statement coverage remains **≥80%** for both ports on the mocked
  unit suites, with an unchanged (or larger) measured denominator.
- **SC-009**: The suite stays **green across 20 consecutive runs** under maximum
  parallelism (no new flakiness introduced).
- **SC-010**: A deliberately injected cross-port divergence is still caught by the
  conformance corpus (parity detection unimpaired).

## Assumptions

- The primary optimization target is the Bash implementation and its CI, because
  it serves macOS and Linux (the platforms named in the request). The PowerShell
  port must not regress but is not the focus.
- "Ensuring code quality" means preserving every constitution-mandated gate at its
  current strength: no removed tests, no lowered coverage floor, no weakened
  parity check.
- The chosen strategy (confirmed with the requester) is **harness refactor + CI
  optimization while keeping every test and every gate**, and **removing the hard
  PowerShell-mock and GNU-`parallel` dependencies** for the Bash suite. Running a
  reduced subset on PRs and the full corpus only on push/nightly (test-tiering
  that changes what gates a PR) is **out of scope** for this feature.
- The live integration suite (real Jira credentials) is unaffected: it already
  runs only on push-to-default / schedule / maintainer label and is never a fork
  PR gate.
- CI caching keys can be derived from stable inputs (lockfiles, tool versions,
  OS) such that a cache hit can never serve stale content that changes a verdict;
  on any doubt the run falls back to a fresh install.
- GitHub Actions remains the CI provider; the three-OS matrix stays
  ubuntu/macos/windows.
- Baseline timings for SC-001/SC-004/SC-005 are the measured durations of the
  current suite/pipeline on the commit immediately preceding this feature's
  changes.

## Out of Scope

- Test-tiering that changes which gates block a pull request (running a reduced
  subset on PRs and the full corpus only on push/nightly). Explicitly excluded per
  the requester's decision.
- Deleting, merging, or sampling tests to reduce count.
- Lowering the 80% coverage floor or narrowing the coverage denominator.
- Rewriting the PowerShell port's test strategy beyond what is needed to keep it
  green and at parity.
- Changing the live (real-Jira) integration suite's triggers or scope.
- Optimizing non-test build/release tooling.
