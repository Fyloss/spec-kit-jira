# Feature Specification: Cut CI Wall-Clock to a 20-Minute Merge Decision

**Feature Branch**: `018-optimize-ci-wall-clock`

**Created**: 2026-08-05

**Status**: Ready for implementation — plan, tasks and contracts complete;
SC-001 conditional on the escalated decision recorded in Assumptions

**Input**: User description: "Optimise les tests Windows qui sont beaucoup trop long sur la CI. […] Cut CI wall-clock to meet the 20-minute push-to-merge-decision target that feature 009 left unmet, by parallelising the conformance corpus within each OS job and re-architecting the Bash coverage gate."

## Overview

Feature 009 set a target — a complete merge decision within 20 minutes of a push
— and did not reach it. Since then the workload roughly doubled: the conformance
corpus grew from 51 to **84 scenarios** and the Bash unit suite from 986 to
**1427 assertions**. A pull request today waits **95 minutes** for its slowest
blocking job, and one of the nine blocking job definitions (`coverage-bash`) has been red on
`main` since 2026-07-28 because it cannot finish inside any budget it is given.

This feature makes the merge decision arrive in 20 minutes without removing a
single test, scenario, or gate. It has three levers, in descending order of
payoff:

1. **The Windows conformance step** — 88 of the 95 minutes. Each scenario costs
   roughly two minutes of wall-clock on `windows-latest` against roughly four
   seconds on `macos-latest`, and the step is throttled to two concurrent
   scenarios because a wider fan-out once killed the runner outright.
2. **The Bash unit suite inside the `unit` job** — 33 to 39 minutes on the POSIX
   hosts, where it is now the dominant step. Not named in the original request,
   but the 20-minute target is arithmetically unreachable while it stands.
3. **The Bash coverage gate** — red by construction under a two-collector
   architecture that needs more time than any sane budget allows.

Nothing in `scripts/bash/**` or `scripts/powershell/**` changes. Every one of the
nine blocking job definitions keeps its exact name, and every operating system keeps
executing the complete corpus.

### Measured starting point

All figures from GitHub Actions run `30947466217` (2026-08-04), the most recent
full run before this spec, plus the paired `gates.yml` run `30947468905`.

| Blocking check run | Wall-clock | Dominant step |
| --- | --- | --- |
| Unit suites (windows-latest) | **95m18s** | conformance corpus **88m04s**; Pester 6m54s |
| Unit suites (ubuntu-latest) | **48m33s** | Bash suite **38m55s**; Pester 4m29s; conformance 4m44s |
| Unit suites (macos-latest) | **42m25s** | Bash suite **33m17s**; Pester 3m40s; conformance 5m03s |
| Bash coverage ≥ 80% | **15m39s — FAILED** | killed at its 15-minute step timeout |
| PowerShell coverage ≥ 80% | 13m02s | Pester with coverage instrumentation |
| Lint | 39s | — |
| Static checks | 46s | — |
| Twin ports mirror module-for-module | 7s | — |
| Version literal single-sourced | 5s | — |
| Detect Bash-relevant changes | 4s | — |
| engine/ carries zero Jira knowledge | ~30s | — |

Eleven check runs, from **nine job definitions** across three workflows — the
`unit` definition is a three-OS matrix and renders three. Branch protection
matches check-run names, so both counts matter and both are frozen.

Push to complete merge decision: **≈ 95 minutes**. Corpus size: 84 scenarios.
Bash suite: 1427 assertions across 149 files. Pester suite: 1128 assertions
across 125 files.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The Windows verdict arrives in minutes, not in an hour and a half (Priority: P1)

A maintainer or an AI coding agent pushes a change and needs to know whether the
two ports still behave identically on Windows. Today that answer takes 95
minutes, and the answer's cost is entirely structural: the corpus runs at most
two scenarios at a time on a four-core runner, and each scenario pays for a fresh
mock server, a fresh native PowerShell process, and MSYS's emulated fork — twice,
once per port. The maintainer either waits out the hour and a half or, far more
commonly, stops reading Windows results altogether, which is how a Windows-only
divergence reaches `main` unnoticed.

**Why this priority**: it is 88 of the 95 minutes on the critical path. No other
change moves the merge decision until this one lands.

**Independent Test**: run the corpus on a real `windows-latest` runner through the
existing probe workflow, before and after. The step completes within its budget,
reports the same per-scenario pass/fail set it reported before, and reports every
one of the 84 scenarios.

**Acceptance Scenarios**:

1. **Given** a pull request touching either port, **When** the `unit` job runs on
   `windows-latest`, **Then** the job reports a verdict within 18 minutes.
2. **Given** that run, **When** the conformance step's output is read, **Then** all
   84 scenarios were executed on that host — none sampled, deferred, or delegated
   to another operating system.
3. **Given** a scenario that diverges between the two ports, **When** the corpus
   runs in its faster form, **Then** that scenario still fails and its byte-level
   divergence report still names the first differing byte and both sides' sizes.
4. **Given** the faster form raises concurrency on the Windows host, **When** the
   corpus runs, **Then** the runner survives the whole corpus — no lost
   communication with the server, no truncated result set read as a short list of
   failures.

---

### User Story 2 - A complete merge decision within 20 minutes (Priority: P1)

A contributor pushes to a pull request that touches Bash code and waits for all
eleven blocking check runs to report. Today the last one lands after 95 minutes, and the
POSIX legs are no better than half that: the Bash unit suite alone costs 33 to 39
minutes inside the `unit` job. The contributor's inner loop is a coffee break;
for an autonomous agent it is wasted budget on every iteration.

**Why this priority**: this is the target feature 009 set and missed, and the one
the requester states as deliverable 3. Story 1 alone does not reach it — with the
Windows leg fixed, the Linux leg's 48 minutes becomes the new critical path.

**Independent Test**: push a commit touching a Bash module to a pull request and
measure the interval from push to the last of the eleven blocking check runs
reporting a conclusion. It is at most 20 minutes.

**Acceptance Scenarios**:

1. **Given** a pull request touching Bash code, **When** it is pushed, **Then**
   all eleven blocking check runs have reported a conclusion within 20 minutes.
2. **Given** that run, **When** each `unit` job is inspected, **Then** none of the
   three exceeds 18 minutes.
3. **Given** that run, **When** the executed test inventory is enumerated, **Then**
   it is at least as large as before this feature — no assertion, scenario, or
   file was dropped to reach the budget.
4. **Given** a pull request that does not touch Bash-covered paths, **When** it is
   pushed, **Then** the existing path filter still applies and cannot cause a gate
   to pass on input it would previously have failed.

---

### User Story 3 - The Bash coverage gate is green and means something again (Priority: P1)

A reviewer opens a pull request and sees `coverage-bash` red. Today that tells
them nothing: the gate has been red on every run since 2026-07-28, killed at its
timeout rather than failing on a real coverage drop. A permanently red gate is a
gate nobody reads, and a coverage floor nobody reads is not a floor.

**Why this priority**: Constitution XIII names the 80% statement floor as a
blocking gate. A gate that cannot complete is a broken guarantee, not a slow one,
and it also sits on the 20-minute critical path.

**Independent Test**: run the gate on a pull request touching Bash code. It
completes inside its declared budget with measurable headroom, publishes a real
coverage percentage, and fails only on a genuine drop below 80% or a genuinely
red suite.

**Acceptance Scenarios**:

1. **Given** a pull request touching Bash code, **When** `coverage-bash` runs,
   **Then** it completes within its declared budget and publishes a statement
   coverage percentage.
2. **Given** a change that drops statement coverage below 80%, **When** the gate
   runs, **Then** the job fails and names the shortfall.
3. **Given** a run where coverage genuinely cannot be measured, **When** the gate
   runs, **Then** the documented traceability fallback rescues the job — and a run
   that merely exceeded its budget does **not** reach that fallback.
4. **Given** the coverage evidence the traced suite used to supply, **When** the
   nightly non-blocking workflow runs, **Then** that evidence is still produced
   and published, as evidence rather than as a gate.

---

### User Story 4 - Every guarantee survives the speed-up (Priority: P1)

A reviewer must be able to trust that the faster pipeline proves everything the
slow one did. The nine blocking job definitions — and the eleven check-run names
they render — are unchanged, so branch protection keeps matching them. Every operating system still runs the complete corpus. Two
identical parallel runs produce identical bytes, so a "pass" is a fact rather
than a scheduling accident.

**Why this priority**: this is the guardrail on Stories 1 to 3, and the reason
feature 009 deliberately stopped short of in-OS sharding: a restructuring that
introduces new job names silently converts required checks into optional ones,
because branch protection is configured outside this repository.

**Independent Test**: compare the blocking-job inventory, the per-OS scenario
count, and the per-scenario verdict set before and after. All three are identical.

**Acceptance Scenarios**:

1. **Given** the changed pipeline, **When** the set of jobs that block a merge is
   enumerated, **Then** it contains the same nine job definitions and the same
   eleven rendered check-run names, spelled identically.
2. **Given** the corpus in its parallel form, **When** it runs twice on the same
   commit on the same host, **Then** both runs produce byte-identical captures for
   every scenario and identical per-scenario verdicts.
3. **Given** a deliberately injected cross-port divergence, **When** the corpus
   runs, **Then** it is still caught.
4. **Given** the two scenarios currently failing on `windows-latest`, **When** the
   faster corpus runs, **Then** those two still fail and no other scenario's
   verdict changes — the speed-up neither hides the pre-existing red nor adds to
   it.

---

### Edge Cases

- **Runner death under wider concurrency**: the Windows throttle exists because a
  wider fan-out once lost communication with the runner mid-corpus, which also
  silenced every divergence after that point. Any raise must be proven on the real
  runner, and a lost runner must never read as a short list of failures.
- **A worker dies mid-corpus**: if any unit of parallel work fails to report, the
  step must fail loudly. Reporting fewer scenarios than the corpus holds must be
  impossible to mistake for success.
- **Annotation budget**: GitHub keeps only the first ten annotations per check
  run. The existing single-folded-annotation report must survive the new execution
  shape — with many scenarios failing, the byte-level report must still arrive
  whole.
- **Slow versus unmeasurable coverage**: exceeding the budget is a genuine failure;
  only an unmeasurable run may reach the traceability fallback. The distinction
  must survive the re-architecture.
- **Corpus growth**: budgets set today were blown by the 51→84 growth. The new
  budgets must be accompanied by a per-scenario cost figure so the next growth is
  diagnosable before it turns a gate red.
- **A red baseline**: `windows-latest` is currently red for a genuine two-scenario
  divergence unrelated to performance. Timing evidence must be collectable from a
  red run, and the divergence set must be compared rather than assumed.
- **Cache miss or cold runner**: a missing cache must degrade to a slower correct
  run, never to a wrong verdict, and never to a budget overrun that reads as a
  coverage failure.
- **The Windows probe is the only Windows oracle**: any Windows-specific change
  that cannot be proven on a real `windows-latest` runner does not gate.

## Requirements *(mandatory)*

### Functional Requirements

#### Conformance corpus throughput

- **FR-001**: Every operating system in the matrix MUST continue to execute the
  **complete** conformance corpus. Distributing scenarios across operating systems
  is forbidden; a scheme that gives one host a subset silently converts a full
  per-OS guarantee into a partial one (carried forward from 009 FR-018).
- **FR-002**: Corpus parallelism MUST be distributed **within** each operating
  system's existing job step. No new job name may be introduced — for the corpus
  or for anything else — because branch protection's required-check list is
  configured outside this repository and a job it does not name is not blocking
  (the reason 009 deliberately deferred this work).
- **FR-003**: The per-scenario cost on `windows-latest` MUST be reduced, not merely
  redistributed. The reduction MUST be driven by a measured breakdown of where a
  scenario's wall-clock goes on a real `windows-latest` runner (process spawn,
  mock startup, per-request cost), recorded in this feature's evidence document
  before the change is designed.
- **FR-004**: If the Windows in-step concurrency cap is raised above its current
  value of two, the raise MUST be justified by a measurement on a real
  `windows-latest` runner showing the complete corpus finishing without loss of
  the runner. An unproven raise MUST NOT gate.
- **FR-005**: The corpus MUST fail the step if any unit of parallel work does not
  report a result. Executing fewer scenarios than the corpus contains MUST NEVER
  produce a passing step.
- **FR-006**: The byte-level divergence report MUST survive the change: a failing
  scenario still names the first differing byte, both sides' hex values, and both
  sides' sizes, and the whole report still arrives within the annotation budget
  when many scenarios fail at once.

#### Parallel determinism

- **FR-007**: Before the parallel form becomes the gating form, the corpus MUST be
  demonstrated deterministic under it: two consecutive runs of the full corpus on
  the same commit and host produce byte-identical captures for every scenario and
  an identical per-scenario verdict set. A determinism failure blocks adoption of
  the parallel form; it is not a flake to be retried away.
- **FR-008**: Every scenario MUST continue to identify the state it creates —
  temporary directories, mock ports, process identifiers — by an identifier it
  recorded from what it spawned, never by a name pattern or a machine-wide scan
  (Constitution XIII). Any increase in concurrency — in the corpus runner or in
  the bats runner — MUST be preceded by a mechanical check that no test or
  harness identifies state by a machine-wide scan, and followed by a two-run
  confirmation at the new degree that the executed set and the verdict set are
  identical.

#### The Bash unit suite inside the `unit` job

- **FR-009**: The Bash unit suite step MUST complete inside a budget that keeps its
  `unit` job within the per-OS budget of FR-015, on both POSIX hosts. Its current
  33 to 39 minutes is the second critical path and blocks the 20-minute target
  independently of the corpus.
- **FR-010**: No assertion, test file, or scenario may be removed, skipped,
  sampled, or moved to a non-blocking trigger to reach any budget in this
  specification. The executed inventory after this feature MUST be greater than or
  equal to the inventory before it.

#### The Bash coverage gate

- **FR-011**: The Bash coverage gate MUST measure statement coverage with **kcov
  alone** — the tool Constitution XIII names as the primary Bash collector —
  measuring the conformance corpus. The second collector (the xtrace-traced bats
  phase) MUST leave the blocking gate.
- **FR-012**: The xtrace-traced suite MUST move to the existing non-blocking
  nightly workflow (or a sibling of it) and be published there as coverage-gap
  evidence. It MUST NOT gate a pull request, and the workflow carrying it MUST NOT
  become part of the blocking inventory.
- **FR-013**: The coverage gate MUST declare a wall-clock budget enforced by CI
  that leaves headroom above its measured duration rather than sitting at or below
  it. Exceeding the budget MUST fail the job loudly; it MUST NOT be absorbed by the
  traceability fallback, which exists for *unmeasurable* kcov runs and never for
  slow ones (FR-016 semantics carried forward from 009).
- **FR-014**: The gate MUST keep the 80% statement floor and MUST NOT shrink the
  measured denominator to fit the budget.

#### Budgets and the blocking inventory

- **FR-015**: Each of the three `unit` jobs MUST report a conclusion within
  **18 minutes**, and the interval from push to the last of the eleven blocking
  check runs reporting MUST be at most **20 minutes**, on a pull request touching
  Bash code.
- **FR-016**: The set of blocking jobs and their names MUST remain byte-identical
  (nine job definitions rendering eleven check runs — the set 009 SC-006/FR-010
  froze). No gate may be dropped, renamed,
  downgraded to non-blocking, or made to pass on input it would previously have
  failed.
- **FR-017**: Every *per-job* and *per-step* budget introduced by this feature
  MUST be enforced mechanically by the pipeline itself — a `timeout-minutes` the
  runner honours — not documented as an aspiration. The 20-minute
  push-to-merge-decision figure of FR-015 is the one budget no runner can
  enforce, because it spans independently-scheduled jobs: it is **derived** from
  the enforced per-job budgets and **measured** on a real pull-request run, and
  a breach is reported against the evidence document rather than caught by a
  timeout.

#### Evidence and scope

- **FR-018**: Any Windows-specific behaviour introduced by this feature MUST be
  proven on a real `windows-latest` runner through the existing probe workflow
  before it gates. Emulation on a POSIX host is not evidence (Constitution VI,
  `docs/10-windows-portability.md`).
- **FR-019**: Timing evidence MUST be collectable while `windows-latest` is red for
  the pre-existing two-scenario divergence. Success is measured on wall-clock and
  on the *comparison* of the per-scenario verdict sets before and after — never on
  a green Windows run this feature does not own.
- **FR-020**: Production code under `scripts/bash/**` and `scripts/powershell/**`
  MUST remain untouched. All work lives in `tests/`, `.github/workflows/`, and
  documentation. Should a defect in production code be discovered as a blocker, it
  is raised as a separate finding rather than fixed silently here.
- **FR-021**: Feature 009's open verification tasks T032 (coverage floor and
  denominator), T035 (Windows scope verification), and T036 (CI measurement) MUST
  be closed by this feature's evidence — absorbed by its success criteria, not left
  dangling.
- **FR-022**: The measured breakdown, the chosen budgets, and the per-scenario cost
  figures MUST be recorded in this feature's evidence document, and the Windows
  quirks catalog MUST be extended with anything new the probe establishes, so the
  next feature inherits the measurement instead of rediscovering it.

### Key Entities

- **Conformance corpus**: 84 language-agnostic scenarios, each run against both
  ports and diffed for byte-identical stdout, exit code, Jira call sequence, and
  written-file tree. Runs as one step of the `unit` job on all three hosts. The
  dominant cost on Windows.
- **`unit` job**: the three-OS matrix job carrying, on each host, the port's own
  unit suite, the Pester suite, and the full corpus. Its three job names are part
  of the blocking inventory.
- **Blocking inventory**: the nine job definitions — eleven rendered check-run
  names — branch protection marks required. Its
  membership and spelling are an invariant of this feature, not a design choice.
- **Bash coverage gate**: the ≥80% statement-coverage measurement for the Bash
  port. Currently red on every run since 2026-07-28.
- **Windows conformance probe**: the manually-triggered workflow that runs the
  corpus, and only the corpus, on a real `windows-latest` host from a throwaway
  branch. The only oracle for Windows-specific behaviour.
- **Nightly stability workflow**: the existing non-blocking scheduled workflow;
  the destination for the xtrace-traced coverage evidence.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Unaffected — this feature changes test execution and CI configuration only. No reconcile, drift, adoption, or write path is touched (FR-020). |
| II | Zero-Churn Idempotency | Unaffected — the live idempotency suite's triggers and scope are untouched; the mocked zero-churn scenarios keep running unchanged (FR-001, FR-010). |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Unaffected — no write or hook code path changes. FR-005's "a missing worker result fails the step" is the same fail-closed instinct applied to the pipeline. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Preserved — no fixture or log gains a credential. The coverage collector's xtrace suspension around credential and transport machinery must survive the re-architecture (FR-011). |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected — no configuration layering changes. |
| VI | macOS / Linux / Windows Portability | Central and strengthened: FR-001 keeps the complete corpus on every host, FR-002 forbids cross-OS distribution and new job names, FR-018 requires measurement on the real Windows runner before anything Windows-specific gates, FR-022 extends the quirks catalog. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Preserved — the non-default workflow fixtures stay in the corpus (FR-001, FR-010); no engine assumption changes. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Unaffected — the boundary greps stay blocking and untouched (FR-016). |
| IX | Two-Tier Privacy Guard, With an Allowlist | Preserved — every privacy-tier test and fixture keeps running (FR-010). |
| X | Self-Healing Automatic Mirror | Unaffected functionally; the install-harness scenarios remain in the corpus every host executes (FR-001). |
| XI | Universal Dry-Run and Auditability | Unaffected — dry-run behaviour and run summaries are unchanged and their tests keep running (FR-010). |
| XII | Quality and Catalog Publication | Restored: the mocked suites, lint, and both coverage gates stay blocking on the same nine definitions and eleven check-run names (FR-016), and FR-011/FR-013 turn a permanently-red gate back into a meaningful one. The live suite's fork exemption is untouched. |
| XIII | TDD With a Minimum 80% Coverage | Central: FR-014 holds the 80% floor and the denominator; FR-011 restores kcov, the tool this principle names, as the primary collector; FR-008 enforces identity-based isolation at the new degree of parallelism; FR-007's determinism check is the failing-test-first discipline applied to a parallel execution form; per Constitution VI the probe run on the real Windows runner is that failing test for Windows-only behaviour. |
| XIV | KISS | The feature removes machinery rather than adding it: one coverage collector instead of two, no new job topology, no new workflow for the corpus. Any new indirection must be justified in the plan's Complexity Tracking. |
| XV | YAGNI | Only what the three budgets require is in scope. Job-topology restructuring, test tiering, and reducing any Windows verification are explicitly Out of Scope. |
| XVI | Human Readable | FR-006 keeps the byte-level divergence report legible when a scenario fails; FR-022 records the measurement where the next reader will find it; budgets are stated as numbers a reader can check against a run. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The `unit` job on `windows-latest` reports a conclusion within
  **18 minutes**, measured on a pull request run. Baseline: 95m18s.
  **Conditional** on the CRLF-guard decision — see Assumptions.
- **SC-002**: The `unit` job on `ubuntu-latest` and on `macos-latest` each report a
  conclusion within **18 minutes**. Baselines: 48m33s and 42m25s.
- **SC-003**: The interval from push to the last of the **eleven** blocking check
  runs reporting a conclusion is at most **20 minutes** on a pull request touching
  Bash code. Baseline: ≈ 95 minutes.
- **SC-004**: `coverage-bash` completes and publishes a coverage percentage, within
  a declared budget it does not exceed, with **at least 20% headroom** between its
  measured duration and that budget, and with the budget itself no greater than
  18 minutes so the gate never becomes the critical path. Baseline: red on every
  run since 2026-07-28.
- **SC-005**: Each of the three hosts executes **all 84** conformance scenarios;
  the per-OS scenario count equals the corpus count on every host, asserted
  mechanically.
- **SC-006**: The blocking inventory is the same **nine** job definitions and the
  same **eleven** check-run names, spelled identically to today, asserted
  mechanically.
- **SC-007**: Two consecutive full-corpus runs in the parallel form, on the same
  commit and host, produce **byte-identical** captures for every scenario and an
  identical per-scenario verdict set — demonstrated on a POSIX host and on the real
  `windows-latest` runner before the parallel form gates.
- **SC-008**: Zero tests removed: **≥ 84** conformance scenarios, **≥ 1427** Bash
  assertions across **≥ 149** files, **≥ 1128** Pester assertions across **≥ 125**
  files, measured against the counts recorded in this specification.
- **SC-009**: The amortised per-scenario conformance cost on `windows-latest` is
  published alongside the wall-clock, so a future corpus growth can be sized
  against the budget before it turns the gate red. Baseline: ≈ 126 seconds per
  scenario (88m04s for 84 scenarios at a concurrency of two).
- **SC-010**: A deliberately injected cross-port divergence is still caught by the
  corpus in its faster form, and the two scenarios failing on `windows-latest`
  today still fail — no verdict changes except by a fix this feature does not own.
- **SC-011**: The xtrace-traced coverage evidence is produced and published by a
  non-blocking scheduled workflow, and that workflow is not among the nine blocking
  jobs.
- **SC-012**: Total runner-minutes for a pull request touching Bash code are lower
  than the baseline run `30947466217` (2026-08-04).
- **SC-013**: Feature 009's T032, T035, and T036 are each closed by a recorded
  measurement in this feature's evidence document: the coverage floor and
  denominator (T032), the Windows scope verification (T035), and the CI
  measurement (T036).

## Assumptions

- **The Bash unit suite is in scope, though the original request named only the
  Windows corpus.** At 33 to 39 minutes inside the `unit` job it is a second
  critical path; deliverable 3's 20-minute target is arithmetically unreachable
  while it stands, so FR-009 treats it as a first-class lever. If the requester
  prefers to scope it out, SC-002 and SC-003 must be relaxed accordingly.
- **SC-001 is conditional on an escalated decision this specification does not
  take.** Phase 0 measurement (research.md §3 and §3.1) puts the realistic
  frozen-code Windows case at ≈ 33 minutes against the ≈ 10.5-minute corpus step
  SC-001 implies, and the optimistic case at ≈ 16. The gap is a single factor: on
  Windows the port's CRLF guard puts a second process behind every `jq` call —
  roughly 500 of a scenario's ~1000 process creations, ≈ 1.9× on the dominant
  cost. FR-020 freezes the file that guard lives in, so the choice is raised
  rather than made: **(a)** an LF-emitting `jq` on the Windows runner —
  workflow-scoped and FR-020-safe, but a deliberate divergence between what CI
  exercises and what a stock Windows host runs, to be recorded in
  `docs/10-windows-portability.md`; **(b)** a spawn-free guard inside the port —
  production code, requiring an explicit FR-020 exception and its own
  measurement; **(c)** relax SC-001 to what frozen code delivers. If (c) is
  chosen, SC-001's 18-minute figure is replaced by the measured achievable figure
  recorded in the evidence document, and SC-002/SC-003 relax with it. Under no
  option is SC-001 allowed to be missed silently: FR-021 and SC-013 make the
  outcome — including a shortfall — part of this feature's evidence.
- The figures the original request quoted (36m57s Windows conformance, 51
  scenarios, a 42m10s Windows job) were measured on 2026-08-02. This specification
  restates them against run `30947466217` of 2026-08-04, where the corpus has grown
  to 84 scenarios and the Windows job to 95m18s. The direction and the diagnosis
  are unchanged; the magnitude is roughly doubled.
- In-step parallelism for the corpus already exists — the corpus is distributed
  across cores today, throttled to two on Windows. This feature's lever is
  therefore per-scenario cost and a measured, proven raise of that throttle, not
  the introduction of parallelism.
- `windows-latest` is red today for a genuine two-scenario divergence
  (`us2-field-defaults-option-question`, `us2-field-defaults-question`) unrelated
  to performance. Fixing it belongs to another feature; this one must not be
  blocked by it, must not hide it, and must not add to it (FR-019, SC-010).
- Branch protection's required-check list remains configured outside this
  repository and unreadable from it, which is why no new job name may be
  introduced (FR-002) rather than merely discouraged.
- GitHub Actions remains the CI provider; the matrix stays ubuntu / macOS /
  Windows on GitHub-hosted runners at their current sizes.
- The Windows probe workflow remains available and continues to reach a real
  `windows-latest` host from a throwaway branch in roughly eleven minutes.
- Budgets are stated as absolute wall-clock figures rather than as reductions from
  a baseline, for the reason 009 recorded and this feature confirms: the workload
  moved by roughly 65% underneath the previous targets, so a percentage target
  drifts silently with suite growth.

## Out of Scope

- **Fixing the two Windows conformance divergences currently failing on `main`.**
  They are a correctness defect, not a performance one; this feature measures
  around them and forbids masking them.
- **Any new job name, or any restructuring of the job graph**, including the
  shard-per-runner shape rejected by 009 T034 — branch protection would not mark
  new names required, silently unblocking the corpus.
- **Distributing scenarios across operating systems**, sampling the corpus, or
  moving any Windows verification to a non-blocking trigger.
- **Reducing Pester scope on any host.** The Pester step's 6m54s on Windows is a
  fixed cost this feature works around, not one it cuts by removing tests.
- **Lowering the 80% coverage floor or narrowing the coverage denominator.**
- **Test tiering** — running a reduced subset on pull requests and the full corpus
  only on push or nightly. Excluded by 009 and still excluded.
- **Changes to `scripts/bash/**` or `scripts/powershell/**`.**
- **Changing the live (real-Jira) integration suite's triggers or scope.**
- **Optimising non-test build or release tooling.**
