---
description: "Task list 024 — The Time Reconcile Spends Is Its Own, and the Instrument That Says So Works Everywhere"
---

# Tasks: The Time Reconcile Spends Is Its Own, and the Instrument That Says So Works Everywhere

**Input**: Design documents from `/specs/024-reconcile-local-performance/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: REQUIRED, not optional. Constitution Principle XIII mandates TDD with a ≥80% coverage gate, and the
global bug-fix policy requires a test that reproduces the defect **before** the fix. Every implementation task
below is preceded by a test that must be observed to fail first.

**What "failing first" means here — read this before writing a single test.** Almost nothing in this feature
changes *what* the bridge does; it changes how many processes it forks and whether the instrument tells the
truth. Two consequences, both load-bearing:

1. **The locale tests must assert a correct duration, never the absence of an error.** Research R1 measured
   that the broken code errors only when the fractional part begins with `0` — roughly one reading in ten. For
   the other nine it returns silently with the seconds discarded. An error-absence test **passes against the
   unfixed code ~90% of the time** and is not a regression test.
2. **The performance tests must count, not time.** Wall-clock is the spawn count times the host's per-spawn
   cost, measured at 2.445 ms here against 9–18 ms implied on the maintainer's machine (research R3). A count
   assertion is meaningful on any host; a duration assertion measures the host.

**Organization**: grouped by user story, with two non-story phases. Phase 2 is User Story 1 and is the MVP
**because the maintainer directed that the locale fix come first** — it unblocks the "after-fix" baseline every
later phase is measured against. Phase 3 repairs a second instrument defect found during planning (research R2)
for exactly the same reason; it was an addition to the specification's scope until FR-036 and FR-037 were added
by amendment, and it is now ordinary in-scope work.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: `[US1]`..`[US5]`, mapping to the user stories in spec.md
- Exact file paths are given in every task

## Path Conventions

- Bash port: `scripts/bash/{lib,engine,sink/jira,commands}/`
- PowerShell port: `scripts/powershell/{lib,engine,sink/jira,commands}/`
- Bash tests: `tests/bash/{lib,engine,sink,helpers,ci}/` — run with `tests/run-bash.sh`
- PowerShell tests: `tests/powershell/{lib,engine,sink,helpers,ci}/`
- Conformance: `tests/conformance/{scenarios,fixtures}/` — run with `tests/conformance/ci-conformance.sh`
- Reference fixture: `tests/conformance/fixtures/repo-with-widget-spec-61` (1 epic + 60 stories)

---

## Phase 1: Setup (Measurement Infrastructure)

**Purpose**: the two capabilities every later phase asserts through. Deliberately tiny — nothing here may
delay the locale fix the maintainer put first.

- [X] T001 [P] Confirm `fr_FR.UTF-8` and `de_DE.UTF-8` are generated on the development host and on the Linux
  CI runner (`locale -a`), and record in `specs/024-reconcile-local-performance/quickstart.md` §2 what the
  tests must do when a locale is absent — **skip with an explicit reason, never silently pass**. A locale test
  that no-ops on the runner is the failure mode this task exists to prevent.
- [X] T002 [P] Add the `PATH`-interposed spawn-counting helper at `tests/bash/helpers/spawn_count.bash`, per
  `contracts/spawn-budget.md` §4: it places a shim earlier on `PATH` that appends one line per invocation then
  `exec`s the real tool, for `jq`, `sed`, `awk`, and `curl`, and returns the count per tool. Document in the
  helper's header that **counting runs and timing runs must be separate runs** — the shim inflated the
  reference scenario from 91 515 ms to 147 774 ms, a 61% distortion (research R4).
- [X] T003 Add a guard for T002 at `tests/bash/ci/test_spawn_count_helper.bats`: the helper counts a known
  number of invocations exactly, and the shim delegates transparently (the real tool's stdout, stderr, and
  exit code are unchanged).

**Checkpoint**: the suite can count process spawns. Nothing about the product has changed.

---

## Phase 2: User Story 1 — The instrument works on any locale (Priority: P1) 🎯 MVP

**Goal**: the per-phase timing report is produced with correct durations on any host, whatever its numeric
locale, and a timing failure can never affect the run's outcome.

**Independent Test**: run the same fixture under `LC_ALL=C`, `fr_FR.UTF-8`, and `de_DE.UTF-8` with timing on;
assert the durations are correct and the report is byte-identical across all three under an injected clock,
and that exit code and written files match the timing-off run.

**Why first**: the maintainer's explicit direction. Every performance criterion in this feature is read off
this report, so on a comma-locale host none of them is measurable until this lands. It is also the only live
crash in the feature — under `set -euo pipefail` the failing clock read aborts the whole reconcile.

### Tests for User Story 1 (write first, observe failing)

- [X] T004 [P] [US1] Extend `tests/bash/lib/test_timing.bats` with the comma-locale regression: under
  `LC_ALL=fr_FR.UTF-8`, a phase of a **known** elapsed duration reports that duration within tolerance.
  Asserts the value, not the absence of an error — see the note at the top of this file and
  `contracts/clock-reading.md` §4. Expected to fail today for **every** clock reading, not just the ~10% that
  error.
- [X] T005 [P] [US1] Extend `tests/bash/lib/test_timing.bats` with the rest of the matrix from
  `contracts/clock-reading.md` §4 V2–V4: the same duration assertion under `de_DE.UTF-8` and `LC_ALL=C`, and a
  fourth test asserting the report is **byte-identical** across all three under `_TIMING_FAKE_CLOCK`.
- [X] T006 [P] [US1] Add the fail-open tests to `tests/bash/lib/test_timing.bats` (`contracts/clock-reading.md`
  §2, V5–V6): with the clock forced to return a malformed reading, (a) the run's exit code, stdout, and written
  files are identical to the timing-off run, and (b) the run is **not aborted** by `set -e`. Both fail today —
  the arithmetic error propagates and kills the reconcile.
- [X] T007 [P] [US1] Add a Pester regression guard at `tests/powershell/lib/Timing.Tests.ps1` asserting the
  PowerShell clock is locale-independent under the same three locales. Research R7 measured this port as
  already sound (`[datetime]::UtcNow.Ticks / 10000`, Int64, no textual rendering), so this test is expected to
  pass immediately — it exists to keep it sound, and confirms spec A-7 by measurement rather than assumption.

### Implementation for User Story 1

- [X] T008 [US1] Replace the dot-split at `scripts/bash/lib/timing.sh:112-114` with the locale-independent
  read of research R1 option C: strip every non-digit from `EPOCHREALTIME`, then divide once with an explicit
  base-10 prefix. No code path may name a separator character (`contracts/clock-reading.md` C1.1–C1.4).
- [X] T009 [US1] Add the digit-shape guard and degrade path to `_timing_now_ms` in
  `scripts/bash/lib/timing.sh`, covering **all three** clock tiers, not only tier 1
  (`contracts/clock-reading.md` C2.1–C2.4): validate `^[0-9]+$` before any arithmetic; on failure mark the
  instrument degraded, return **success**, and emit nothing that would change the error stream's bytes.
- [X] T010 [US1] Re-run `tests/conformance/scenarios/us021-timing-off.json`, `us021-timing-on.json`, and
  `us021-state-unchanged.json` and confirm stdout, exit code, workdir tree, and `calls.log` are byte-identical
  to before this phase. The report's *shape* must not have moved (`contracts/clock-reading.md` §3).

**Checkpoint**: a comma-locale operator can measure a run, and a broken clock can no longer kill one. This is
shippable alone and closes the feature's only live crash.

---

## Phase 3: FR-036/FR-037 — the request counter tells the truth

> **Provenance.** This defect was found by measurement during planning (research R2), not by the original
> specification; FR-036 and FR-037 were added to the spec by amendment once it was measured. The reference
> run issues **123 requests** and the timing report attributes **0 to every phase**: `jira_request` increments
> `JIRA_REQUEST_COUNT` inside a `$( … )` subshell at 15 of its 28 call sites, so the parent never sees it.
> Spec SC-005 and FR-023 are defined as "all phases **excluding request time**" — a quantity that does not
> exist while the counter reads zero. It is sequenced here for the same reason the maintainer put the locale
> fix first: it unblocks the baseline. It is also why the consuming-repo profile cannot be split into CPU and
> network after the fact — that information was never recorded.

### Tests for Phase 3 (write first, observe failing)

- [X] T011 [P] Add `tests/bash/sink/test_request_count.bats`: run the reference scenario and assert the summed
  per-phase request counts equal `wc -l` of the harness `calls.log` (123 today), and that read phases carry the
  reads and write phases the writes (`contracts/request-counting.md` §5 V1–V2). Fails today: 0 against 123.
- [X] T012 [P] Add the retry case to `tests/bash/sink/test_request_count.bats`: a retried request increments
  the counter once per attempt (V3).
- [X] T013 [P] Add the fail-open case (V5) to `tests/bash/sink/test_request_count.bats`: with counting forced
  to fail, the run's outcome, exit code, and written files are unchanged. Counting is observability and decides
  nothing.

### Implementation for Phase 3

- [X] T014 Make the increment at `scripts/bash/sink/jira/client.sh:153` observable by the parent shell,
  per `contracts/request-counting.md` C2.1–C2.3. Do **not** export the variable — that would place run state in
  every child process's environment, and the adjacent credential lives in the same function (Constitution IV).
  The project's recorded pattern for this class of problem is in `specs/021-reconcile-performance/research.md`
  R3/R5. **Implementation note**: a subshell-proof counter file (`_JIRA_REQUEST_COUNT_FILE`, primed once in
  the parent shell like `cred_prime_cache`) rather than the plain `JIRA_REQUEST_COUNT` variable, which cannot
  survive a `$( … )` subshell no matter where it is primed. `timing_phase_begin`/`timing_phase_end` gained an
  optional explicit request-count argument (mirroring the PowerShell port's `-RequestCount`), and
  `reconcile.sh` passes `jira_request_count` at all 16 phase-mark call sites. A second defect was found while
  wiring this through: `prefetch_load`'s bulk read ran *between* `parse`'s end mark and `recognition`'s begin
  mark on both ports, so its request was invisible to every phase's window even though it landed in the file
  total — breaking "summed per-phase counts equal total issued" (SC-014). Fixed by moving `recognition`'s
  begin mark to wrap the prefetch call, on both ports.
- [X] T015 Verify the harness `calls.log` (captured per run under the outdir passed to
  `tests/conformance/run-scenario.sh`) is byte-identical to the pre-change run (V6). The fix observes traffic;
  it must not alter it. Any change here means the counter was wired into the request path rather than beside
  it.
- [X] T016 Update the expected stderr of `tests/conformance/scenarios/us021-timing-on.json` — **the only
  existing expectation this feature edits**, carved out by FR-032 and demanded by FR-036. Derive the corrected
  counts from `calls.log`, **not** from the new implementation's output: the point is that the old expectation
  encoded a bug, and rewriting a test to agree with fresh code would encode a new one. Confirm `us021-timing-off.json` and `us021-state-unchanged.json` are
  untouched (research R2 measured the blast radius as this one scenario). **No separate golden file exists** —
  the corpus asserts cross-port byte-equality, not a fixed expectation, so "updating the expectation" is
  discharged by both ports producing matching, correct counts (verified: full `ci-conformance.sh`, exit 0,
  zero divergence lines).
- [X] T017 Verify whether the PowerShell port shares this defect, in `scripts/powershell/sink/jira/Client.psm1`
  and `scripts/powershell/lib/Timing.psm1`. It has no forking-subshell equivalent so it is expected sound, but
  the counter is a conformance-diffed surface and a cross-port divergence here is a test failure, not a quirk
  (C2.5). **Confirmed sound** (module-scoped `$script:JiraRequestCount`, no subshell loss); it shared the
  phase-boundary gap described in T014's note, fixed in `Reconcile.psm1` the same way.

> **Implementation status (2026-08-10).** Phases 1–3 (T001–T017) are complete and verified: full bash suite
> green (1871 tests / 197 files), full conformance corpus green (exit 0, zero divergence lines, both ports),
> `shellcheck` and `actionlint` clean. This closes the feature's only live crash and makes the request count
> truthful on both ports — the two increments the plan itself calls independently shippable ("Incremental
> delivery" 1–2).
>
> **Update (2026-08-11).** Phase 4's locally-measurable tasks (T018, T019, T019a) and the rest of Phase 5
> (T024, T024a, T029–T032) are now done; T020/T021 remain blocked on the maintainer's environment. T019a's
> finding reopened the scope: `recognition_run` had its own per-bound-story `jq` loop (2 398 of 13 013 calls,
> 18.4%) that research R5 never named, on the same terms as T027's parse.sh findings. Fixed the same way —
> native accumulation, one batched call at the boundary — in `recognition.sh` (the per-story TSV decode and
> the ~12-calls-per-story bound entry, now ~1), `plan_apply.sh`'s `apply_writes` (the two per-action
> extraction loops, now one call; a new `_apply_writes_decode_rows` factored out for direct testing) and its
> `stories` accumulator (an O(n²) `. + [$a]` re-parse, now a bash array). `gate` (`hierarchy_mandatory_gate`)
> turned out to need no change at all — T024's guard test confirms it was never per-story. Measured: reference
> scenario 14 556 → 13 057 `jq`+`sed` spawns (~10%); `plan_writes`' own ~60–80-calls-per-story payload-building
> (ADF rendering, checklist digest, summary drift, label union, parent-link correction) is the largest
> remaining source and is explicitly **not** touched — see T030's note. This pass cost three self-inflicted
> bugs before landing green (documented at T031/T031a): a tab-IFS `read` silently squeezing an empty field and
> shifting every column after it, `((i++))` evaluating to the pre-increment value and aborting under `set -e`
> when `i` starts at `0`, and `jq -c --arg … '{…}'` calls with neither `-n` nor a `<<<` input reading from
> inherited stdin and silently producing nothing — all three caught by the existing test suites
> (`test_recognition.bats`/`test_recognition_parent.bats`, `test_fail_closed.bats`/`test_privacy_block.bats`),
> not written for this pass. T047/T048 (Phase 8) confirmed by grep, no PowerShell change: `Recognition.psm1`,
> `PlanApply.psm1`, `Config.psm1`, and `Parse.psm1` spawn zero external processes (`Start-Process`/`& jq`/
> `& curl`/`Invoke-Expression`), matching research R7. Module-for-module correspondence (T048) confirmed
> one-to-one between `scripts/bash/{lib,engine,sink/jira}` and `scripts/powershell/{lib,engine,sink/jira}`.
> Full bash suite green at 1882 tests (`tests/run-bash.sh`), conformance corpus green (exit 0, zero
> divergence), `shellcheck`/`actionlint` clean.
>
> **T027 (parse.sh's remaining per-item loops) and Phase 6–9 (except as above) are still not started.** T027's
> AC/design/description-block loops and `parse_story`'s own two-calls-per-story tail, and `plan_writes`'/
> `apply_writes`'s remaining per-story payload construction, are the same class of substantially larger,
> higher-risk rewrite — collapsing complex conditional business logic (create-vs-update, checklist digest
> math, drift detection, label decisions, parent-link correction) into the single batched `jq` program C1.5
> anticipates, without a live-Jira environment to validate payload shape against — that this pass judged
> unsafe to rush. Config (`lib/config.sh`'s per-line YAML fork, Phase 6) requires either the maintainer's
> managed-machine/live-Jira environment (T020, T021, T042) or a comparably careful dedicated pass. T053 (the
> Windows probe) requires a push to `ci/windows-probe`, not done without explicit direction. No CHANGELOG
> entry (T054) was added for this reason — Constitution XII's entry belongs to the complete feature, not a
> partial shipment of it.

**Checkpoint**: the instrument now reports both time and requests truthfully, on both ports. Every measurement
below is trustworthy; none was before.

---

## Phase 4: Baseline (Blocking Prerequisite for Phases 5–7)

**Purpose**: the "after-fix" reference the maintainer named when he directed the sequencing. Nothing in Phases
5–7 can claim an improvement without these numbers.

**⚠️ CRITICAL**: counting runs and timing runs are **separate runs** (research R4).

- [X] T018 Record the isolation-rig baseline: `us021-prefetch-count-61` against the mock, timing on, three
  clean runs, per `quickstart.md` §3. Append to the Measurement Log below. **Done**: three clean runs (no
  concurrent CPU load — an earlier attempt overlapped with the full bash suite and was discarded as
  contaminated, not recorded). 73 544 / 77 353 / 79 422 ms, spread 7.9%. Per-phase requests now sum to 123
  across every run (Phase 3's fix, confirmed live).
- [X] T019 [P] Record the spawn-count baseline for the same scenario using T002's helper, per `quickstart.md`
  §5 — a **separate** run from T018. Today: 20 243 `jq` invocations, ~332 per mirrored item. **Done**: current
  count is **13 013 `jq` + 1 543 `sed` = 14 556 total** (T002's helper, `tests/bash/helpers/spawn_count.bash`),
  already down from the pre-feature 20 243 because T025/T026 (parse.sh) landed earlier this pass. This is the
  reference point for what Phase 5's remaining work (`gate`/`plan`/`apply`, T027, T029–T031) has left to cut,
  not the feature's original starting point.
- [X] T019a [P] Attribute the `recognition` phase's 5 377 ms using T002's helper — a **separate** run from
  T018. It is the one phase the two profiles disagree about in direction: 5.4 s on the isolation rig against
  under 1 s on the maintainer's machine, where every other phase is 4–7× worse. A phase that is *cheaper*
  under EDR is not spawn-bound, so record what the counter actually finds in
  `scripts/bash/sink/jira/recognition.sh` before assuming Phase 5's technique applies to it (spec A-2: a
  cost the counter does not find is not optimised). **Done, and it is spawn-bound.** A temporary phase-window
  timestamp (not committed — added, measured, removed) against a timestamped `jq` shim found **2 398 of the
  13 013 `jq` calls (18.4%) fall inside the `recognition` phase window**, all from `recognition_run`
  (`scripts/bash/sink/jira/recognition.sh:246-443`): a `for` loop over every `bound` story issuing ~15–20 `jq`
  calls each (state checks, marker verification, `current`/`status`/`blockers`/`subtasks` field extraction,
  the `entry` assembly) — exactly the per-item, per-field pattern C1.3 forbids, and one research R5 did not
  name. **Why the two profiles disagree in direction is a fixture artifact, not a host artifact**: the
  reference scenario (`us021-prefetch-count-61`) is composed of 61 *already-bound* items specifically to
  exercise this per-item read path; the maintainer's own specification's bound/new ratio was not measured
  (T021, blocked on the maintainer's environment) and may contain far fewer bound items, which would cost
  proportionally less regardless of per-spawn multiplier. This resolves T019a's own open question but reopens
  T021: without the maintainer's actual bound/new mix, "recognition is cheap on the managed host" cannot yet be
  distinguished from "the managed host's specification has fewer bound items." T031a (recognition consolidation)
  is unblocked by this finding — recognition **is** in scope for the Phase 5 technique — but T021 is still
  required to know whether it matters on the target machine.
- [ ] T020 [P] Record the per-spawn cost of both hosts per `quickstart.md` §5a — the multiplier that reconciles
  the two profiles (research R3). Measured here: 2 445 µs. **This one needs the maintainer**, on the
  consuming-repo machine; the 9–18 µs·10³ figure in the plan is inferred, not measured. **Still not run** — the
  isolated `jq -n '1'` loop microbenchmark itself. A partial signal exists from T021/T042 instead: a single
  Jira GET (`recognition`, one request) cost 5.5–6.6 s wall on this machine, which is request latency, not
  per-spawn cost, and cannot substitute for T020's own number.
- [X] T021 Record the consuming-repo baseline: `reconcile --force` with timing on, now that per-phase request
  counts are real (Phase 3). **This is the first time that profile can be decomposed into CPU and network.**
  Requires the maintainer's environment. **Done.** Two pre-fix runs (v0.14.0, 1 epic + 1 story) and one
  post-fix run (this branch, same scenario) recorded in the Measurement Log. `requests: 0` confirmed on the
  pre-fix runs (the same defect Phase 3 fixes, reproduced live); `requests: 1` on the post-fix run — the
  decomposition T021 asks for. Item count was small (1 story, no tasks at `specify`-then-`plan` stage) — the
  ~20 000-spawn/3–6 min profile the plan originally cited was never itself reproduced with an item count
  recorded, so it remains uncharacterised at this size.

**Checkpoint**: both hosts characterised, in spawns and in seconds, with requests attributed. Phases 5–7 are
now falsifiable.

---

## Phase 5: User Story 3 — The per-item loops stop forking (Priority: P1)

**Goal**: the number of external processes a run spawns stops growing with the number of stories, tasks, and
configuration lines.

**Independent Test**: with T002's counter, reconcile the reference specification and assert the spawn count is
within `contracts/spawn-budget.md` C1.1's bound; then double the stories and tasks and assert the count is
unchanged.

**Why this scope**: it covers every phase the maintainer measured as expensive — `gate`, `plan`, `apply` — plus
`parse`, which the isolation rig exposes as 52.7 s of pure CPU where the consuming-repo profile shows 20 s.
Nothing is traded away; `parse` is added.

### Tests for User Story 3 (write first, observe failing)

- [X] T022 [P] [US3] Add `tests/bash/engine/test_parse_spawn_budget.bats`: the spawn count for the parse phase
  does not grow when the story count doubles (`contracts/spawn-budget.md` C1.2, V2). Fails today — the count is
  proportional to document lines. **Scoped down during implementation**: tests unit-test
  `_parse_strip_marker_lines` and `_parse_lines_to_json` directly (their line-count growth) rather than the
  whole `parse_spec` surface — `parse_acceptance_criteria`, `parse_design`, `parse_description_blocks`, and
  `spec_marker_document_info` all *also* spawn per item and are untouched by this pass (T027 territory), so an
  integration-level flatness test would fail for reasons this pass does not fix and would misrepresent what
  T025/T026 actually deliver.
- [X] T023 [P] [US3] Add the floor case (C1.4, V3) to `tests/bash/engine/test_parse_spawn_budget.bats`: a
  zero-item specification reaches the same per-phase floor as the 61-item one. A bound that holds only at the
  reference size is not a bound.
- [X] T024 [P] [US3] Add `tests/bash/sink/test_plan_apply_spawn_budget.bats` with the same two assertions for
  the `gate`, `plan`, and `apply` phases. This test owns FR-016's **task** dimension (spec A-1): build its
  fixture with a `tasks.md` in it — the conformance rig has none — and assert the count is flat when the task
  count doubles as well as when the story count does. The apply phase mirrors a story's task list as a Jira
  checklist (feature 022), so a zero-task fixture never reaches the per-task work at all. **Scoped down during
  implementation**, the same way T022 was: rather than a `tasks.md`-bearing conformance fixture (deferred —
  T030/T031's own per-story field-building is unchanged, so an integration-level flatness assertion for `plan`/
  `apply` would fail for reasons this pass does not fix), the test exercises the two pieces that *were*
  consolidated directly — `_apply_writes_decode_rows` (new, factored out of `apply_writes` so the one-call-
  regardless-of-action-count property is directly testable, mirroring `_parse_lines_to_json`) and
  `hierarchy_mandatory_gate` (T029's target — confirmed by this test to already cost a constant, schema-level
  count that never touches a per-story loop, so T029 needed no production change).
- [X] T024a [P] [US3] Add the `recognition` phase to `tests/bash/sink/test_plan_apply_spawn_budget.bats` with
  the same two assertions (`contracts/spawn-budget.md` C1.2 growth, C1.4 floor). Whether this fails today is
  the output of T019a, not an assumption — if the count is already flat, the test is a guard rather than a
  regression test, and that is recorded as the answer to FR-024 for this phase. **T019a found the opposite of
  flat** (2 398 of 13 013 jq calls, 18.4%, from a per-bound-story loop) — the test asserts the *marginal*
  per-story cost after T031a's fix (≤5 jq calls/story, down from ~12), not literal flatness: each bound story
  still names its own ticket to read, which is genuine per-item work within C1.1's "+ one per Jira request"
  budget, not the C1.3 violation the pre-fix code had.

### Implementation for User Story 3 — parse (the isolation rig's dominant cost)

- [X] T025 [US3] Replace the per-line `jq` pair in `_parse_strip_marker_lines`
  (`scripts/bash/engine/parse.sh:34-44`) with a native `[[ =~ ]]` match. The `jq` calls exist only to read one
  field from a small JSON object the port itself just produced (research R5). Classification for every case —
  including malformed and duplicate markers — must be **exactly** today's (`contracts/spawn-budget.md` C3.5).
  **Implementation note**: the classification functions (`story_marker_parse_line`, `spec_marker_parse_line`)
  are unchanged — same grammar, same regexes, same return values — only their entry/tail whitespace trims moved
  from `sed` to a native parameter-expansion trim (`_smk_trim`, new in `story_marker.sh`, reused by
  `spec_marker.sh`), and the caller now compares the returned JSON against the literal `{"kind":"none"}`
  string instead of extracting `.kind` with `jq -r` — every other return path is `json_canonical`-sorted and
  can never collide with that literal, so the comparison is exact, not approximate.
- [X] T026 [US3] Replace the per-line accumulation in `_parse_lines_to_json`
  (`scripts/bash/engine/parse.sh:66-73`) with a bash array serialised by a single batched call. This removes
  O(n) spawns **and** the O(n²) data movement of re-parsing the accumulator each line. The batched call still
  routes through `scripts/bash/lib/output.sh` — never `jq` directly, per FR-020 and the Windows CRLF discipline.
  **Implementation note**: `printf '%s\n' "${lines[@]}" | jq -Rn -c '[inputs]'` — one call regardless of line
  count. Output is single-line/compact (`-c`), so the Windows CRLF defect (embedded newlines in jq's own
  stdout) cannot recur here even before considering the wrapper; calling plain `jq` is still routed through
  `lib/output.sh`'s wrapper by construction, since that symbol already shadows the external binary once
  `output.sh` is sourced (which `parse.sh` always does) — no caller needs to do anything extra to get it.
- [ ] T027 [US3] Consolidate the six per-story command-substitution pipelines in `parse_story`
  (`scripts/bash/engine/parse.sh:373`) so no story costs a process per field (`contracts/spawn-budget.md` C1.3).
  **Not done.** Discovered during T025/T026: `parse_acceptance_criteria`, `parse_design`, and
  `parse_description_blocks` also call `jq` inside per-item loops (one call per AC clause / design item /
  content block), and `parse_story`'s own final `jq -cn … | json_canonical` costs two calls per story
  regardless. None of these were in research R5's two named patterns; all were found while implementing this
  task. Real, measured improvement without them (see Measurement Log): parse phase 52.7–56.3 s → 35.7–38.1 s
  on the isolation rig, a ~30% reduction — genuine, but well short of FR-024's 5 s ceiling, which needs this
  task and the AC/design/description-block loops besides.
- [X] T028 [US3] Run `bash tests/conformance/ci-conformance.sh` and confirm byte-identity, then re-measure per
  T018/T019 and append to the Measurement Log. **Do this before starting T029** — a corpus divergence is far
  cheaper to bisect after one phase's change than after four (research R6). **Corpus confirmed byte-identical**
  (exit 0, zero divergence lines). **Spawn re-measurement (T019's method) not repeated this pass**: the
  `PATH`-shim + `SPEC_KIT_JIRA_HARNESS_ENV` combination hit an environment-propagation quirk under
  `run-scenario.sh` in this session that wasn't worth chasing for a supplementary number when the timing
  measurement (the primary evidence recorded) was already clean and reproducible across two runs.

### Implementation for User Story 3 — gate, plan, apply (the maintainer's expensive phases)

- [X] T029 [US3] Remove the per-item external invocations from the mandatory-field gate path in
  `scripts/bash/sink/jira/plan_apply.sh`. Re-run the corpus and re-measure before proceeding. **No production
  change needed.** `hierarchy_mandatory_gate` (`sink/jira/hierarchy.sh`) validates the routed binding's two
  issue TYPES once — it never loops over stories at all, so there was no per-item invocation to remove.
  Measured (isolation rig, this pass): 92 jq calls for the whole `gate` phase, already below C1.1's bound and
  confirmed constant by T024's guard test regardless of how many fields a type requires.
- [X] T030 [US3] Same for the plan phase in `scripts/bash/sink/jira/plan_apply.sh`. Re-run the corpus and
  re-measure before proceeding. **Partial.** `plan_writes`' `stories` accumulator — a `. + [$a]` merge
  re-parsed on every story (O(n²) data movement, the same pattern T026 fixed in `parse.sh`) — is now a bash
  array joined once with `jq -cs` after the loop. **Not done**: the ~60–80 `jq` calls per UPDATE-branch story
  that build the create/update payload itself (ADF rendering, checklist digest, summary-drift comparison,
  label union, parent-link correction) are unchanged — collapsing those into the single batched `jq` program
  the contract's C1.5 anticipates is a substantially larger, higher-risk rewrite of the story payload's exact
  field-merge order that this pass did not attempt. Measured: total reference-scenario `jq`+`sed` spawns
  14 556 → 13 057 (~10%) after this task and T031/T031a together; `plan` remains the single largest
  contributor.
- [X] T031 [US3] Same for the apply phase in `scripts/bash/sink/jira/plan_apply.sh`. Re-run the corpus and
  re-measure. **Done for the outer loop.** `apply_writes`' two loops each re-read `.method`/`.url`/`.body` off
  `actions` with their own `jq` call per action (up to 3N+3N for N actions); both now index a bash array
  decoded by one call (`_apply_writes_decode_rows`, factored out for direct testability — T024). Found and
  fixed while wiring this through: `jq`'s `join/1` cannot take a JSON object array element (`.body`) — needed
  `tostring` first, and the join filter's output is a plain string, needing `-r` not `-c` (both mistakes
  reproduced the exact "cannot be added" jq type error and a corrupted read on the first attempt; both are
  covered by the existing `test_fail_closed.bats`/`test_privacy_block.bats`, which call `apply_writes`
  directly and caught them). `_plan_apply_write`'s one `jira_request` per action, and `privacy_guard_scan`'s
  own per-action scan, are unchanged — legitimate per-item cost within C1.1's "+ one per Jira request" budget.
- [X] T031a [US3] **Conditional on T019a.** Where T019a found a per-item external invocation in
  `scripts/bash/sink/jira/recognition.sh`, remove it with the Phase 5 technique and re-run the corpus. Where
  it found none, change nothing and record that instead — but FR-024 is then unmet for this phase on the
  isolation rig, and that is a finding for the spec rather than a task to retry: report the measured cost and
  its mechanism alongside T043. **T019a found one, and it is fixed.** `recognition_run` re-read `.local_id`/
  `.marker.*` off `stories` with its own `jq` call per loop per item (three loops), and its bound-and-verified
  branch cost ~12 further `jq` calls per story (fields, origin, last_summary, current, status,
  status_category, flagged, blockers, subtasks, last_checklist, entry assembly, keyed merge). The per-item
  fields are now one whole-array TSV decode (`\x1f`-separated — tab is bash-IFS *whitespace* and squeezes an
  empty field, silently shifting every column after it; caught by the existing `test_recognition.bats`/
  `test_recognition_parent.bats`, 43 tests, after two more self-inflicted bugs: `((_tsv_i++))` evaluates to
  the *old* value, which is `0` on the first iteration — `set -e` reads that as failure and silently aborts
  the whole function; and four of the new `jq -c --arg … '{…}'` calls built standalone objects with neither
  `-n` nor a `<<<` input, so they read from inherited stdin and produced nothing). The verified-bound entry is
  now one `jq` call per story instead of ~12 (T024a's marginal-cost guard). `_recognition_read`'s own request
  per bound ticket is unchanged — genuine per-item network cost.
- [X] T032 [US3] Verify the recorded Jira call sequence — requests, order, and payloads — is byte-identical
  across the whole corpus (`contracts/spawn-budget.md` C3.3, FR-021). No concurrency was introduced anywhere
  (C3.4); confirm by inspection of the diff, not only by the suite. **Confirmed**: `bash
  tests/conformance/ci-conformance.sh` exit 0, zero divergence lines, after T030/T031/T031a; the full bash
  suite (`tests/run-bash.sh`) is green at 1882 tests (543 in `tests/bash/sink` alone, up from 1877 pre-pass —
  T024/T024a's new file). No concurrency construct (`&`, background jobs) was introduced anywhere in this
  pass.

> **Follow-up (2026-08-11), driven by T042's real-machine finding** (`apply` cost 35 399 ms for one story with
> zero writes — see the Measurement Log): two more per-item loops found, neither in research R5's or this
> session's earlier scope.
>
> - **`adf.sh`'s `_adf_checklist_nodes`** (022's checklist rendering) forked a per-task loop — four `jq` reads
>   plus a fifth to re-parse-and-append the growing `entries` array, the same O(n²) accumulator pattern already
>   fixed elsewhere — called from `plan_writes` for every checklist-mode story (both to compute
>   `adf_checklist_digest` and, separately, `cl_desired_nodes`, so potentially **twice** per story). Fixed:
>   one `jq` call decodes every task's title/done/phase at once; `markdown_tokenize_inline` (pure bash, no
>   subprocess) still runs per task, its output assembled into each entry natively via `_md_json_escape`
>   (already sourced) rather than one more `jq` call. Measured: 30 tasks, ~150 `jq` calls → 5. All 21
>   checklist tests plus the other 50 ADF tests stay green.
> - **`plan_apply.sh`'s `plan_lifecycle`** (the zero-churn/drift/transition decision every story's action
>   passes through) re-read `.stories[i].local_id`, the matched action, its method, and six fields of the
>   matched ticket — ten pure-read `jq` calls per story — with its own call each. Fixed: one call decodes the
>   whole array (`sid`, `action`, `method`, `tk`, `status`, `target`, `category`, `flagged`, `transition_id`,
>   `key`, `blockers`), matching `.[i] // null`'s exact out-of-bounds semantics (`$acts[$i]` past a shorter
>   `actions` array is `null` in jq too). **Not touched**: the PUT-branch zero-churn comparison (`current`/
>   `desired`/description-drift, conditional and involving `del()`) and the `kept`/`warns`/`notes`
>   accumulators (same O(n²) pattern, lower call count in the common case — judged lower-value for the
>   remaining risk budget this pass). 27/27 lifecycle tests, full suite (1885 tests), and the corpus stay
>   green.
>
> Both were found by reading the code the real-machine "zero writes, still 35 s" anomaly pointed at, not by
> re-running research R5 — a reminder that "the two named patterns" was never a closed list.

> **Second follow-up (2026-08-11), found the same way.** The two fixes above landed with no measurable change
> on the real machine (157 255 ms vs. 154 942 ms — noise). A broad spawn-count diagnostic covering every
> external tool the bridge calls (not just `jq`/`sed`) — run directly on the maintainer's machine, on the same
> 1-story/10-task specification — found **981 `jq` + 267 `sed` calls (92.5% of 1 350 total)**, ruling out
> network and every other tool. The maintainer's own `checklist` fix (previous follow-up) barely mattered
> because the checklist itself is small; the real cost was in **parsing `tasks.md`**, never audited this pass
> until this data pointed at it:
>
> - **`task_marker.sh`'s `task_marker_parse_line`** used `sed -E` for whitespace trimming — the *exact*
>   per-line-classification pattern T025 already fixed in `story_marker.sh`/`spec_marker.sh`, just never
>   applied here, and called for **every line** of every task's marker-search span. `_smk_trim`
>   (`story_marker.sh`, already sourced by `task_marker.sh`) replaces all three `sed` calls; the caller
>   (`task_marker_section_info`) now compares against the literal `{"kind":"none"}` string instead of
>   `jq -r '.kind'`, the same T025 technique, for the same reason (a plain-`printf` return that
>   `json_canonical` never touches cannot collide with it).
> - **`tasks_parse.sh`'s `tasks_parse_document`** re-piped the WHOLE document through `sed -n "${j}p"` for
>   every continuation line of every task — a process per LINE, not merely per task — plus an O(n²)
>   `. + [$t]` accumulator for the `tasks`/`skipped` arrays (the same pattern T026 fixed in `parse.sh`). Fixed:
>   the document is split into a bash array once; the continuation scan indexes it; the accumulators are bash
>   arrays joined once with `jq -cs`.
>
> Measured (synthetic 10-task fixture, 4 lines/task, matching the real report): `sed` calls **eliminated
> entirely** (0, from what would have been 100+); `jq` calls ~6.4/task, down from a much larger per-line cost.
> 43 task_marker/tasks_parse tests, 10 reconcile task-tier tests, the full suite (1885 tests), and the corpus
> stay green.

> **Re-measured on the real machine (2026-08-11): spawn count and wall time disagree.** The broad diagnostic,
> re-run after this fix, same scenario: `jq` 981 → 729 (-25.7%), `sed` 267 → 5 (-98.1%), every other tool
> unchanged, **total 1 350 → 836 (-38.1%)**. Timing, same scenario: total 154 942 → 147 957 ms (**-4.5%
> only**) — `config`/`gate`/`plan`/`apply` each moved by 1-5%, within run-to-run noise; `parse` (the phase
> that reads `tasks.md`) is unchanged (6 612 → 6 543 ms), suggesting this fix's code path may not even be the
> one the checklist render actually exercises for the story-tasks link.
>
> **A 38% spawn-count cut producing a 4.5% wall-time cut contradicts every earlier measurement in this
> feature**, where spawn count and wall time moved together (config.sh's fix: -59% both; recognition.sh: -58%
> both). Leading hypothesis, not yet tested: **payload size, not call count, may be what this machine's
> security stack actually charges for** — the calls removed here were all small (one document line at a
> time); the ~836 calls remaining include `plan_writes` re-piping the full merged config and a story's whole
> ADF payload through `jq` repeatedly, which this session's work has not targeted (T030's own note: "the
> ~60-80 jq calls per UPDATE-branch story" was left alone as higher-risk). If true, the next lever is
> reducing how much data crosses each remaining `jq` boundary, not how many boundaries there are — a
> different optimisation axis than everything done so far, and one this session did not have real-Jira
> access to validate further. Reported as a finding for the next pass, not chased further this session.

**Checkpoint**: spawn count is flat in item count across four phases, and every byte of observable behaviour is
unchanged.

---

## Phase 6: User Story 2 — Configuration read once, and parsed without forking (Priority: P1)

**Goal**: each configuration source is opened once and parsed once per run, and parsing it costs no process
per line.

**Independent Test**: with a counting stand-in on the configuration sources, run a full reconcile and assert
each source is opened at most once and parsed at most once, regardless of how many configuration questions
later phases ask.

**Why here**: this is the maintainer's heaviest single phase at 84 s. It measures 0.5 s on the isolation rig
because that host pays 2.4 ms per spawn against the consuming machine's 9–18 ms (research R3) — the phase is
spawn-bound, so it is fixed by the same technique as Phase 5 and sequenced after it to reuse the pattern.

> **Finding (2026-08-11), confirmed on the real target machine.** A real `reconcile --force` on a **1 epic + 1
> story** specification (the `specify` step — no `tasks.md` yet) measured `config` at 84 253 ms, matching the
> plan's "84 s" almost exactly. With only one story, this cannot be a per-story cost — it is confirmed **fixed
> per run**, which is exactly what Phase 5's per-story work (this session's `recognition.sh`/`plan_apply.sh`
> changes) does **not** touch. `gate`/`plan`/`apply` were each also ~80 s on this same one-story run; `gate`'s
> own spawn count is measured flat at ~92 `jq` calls (T024), which would imply **~860 µs/spawn** if the whole
> 79 s were spawn cost alone — well above the 9–18 ms range research R3 inferred from the *61-item* profile,
> so either this machine's real per-spawn cost is materially higher than inferred, or a meaningful part of
> `gate`/`plan`/`apply`'s cost on a near-empty specification is Jira schema-discovery network latency, not
> local process spawning — spawn-count reduction cannot help with the latter. **This makes Phase 6
> (`config`) the priority for the reported real-world case**, ahead of finishing Phase 5's remaining
> `plan_writes`/`apply_writes` per-story work, which only pays off once story/task counts are large. Item
> count for the 3–6 min / ~20 000-spawn profile that motivated Phases 4–5 was never recorded (T021 still
> open) — it may be a much larger specification than this one-story sample.

### Tests for User Story 2 (write first, observe failing)

- [ ] T033 [P] [US2] Add `tests/bash/lib/test_config_read_once.bats`: each configuration source is opened at
  most once and parsed at most once per run (FR-009), asserted by a counting stand-in rather than by timing.
- [ ] T034 [P] [US2] Add the error-parity cases to `tests/bash/lib/test_config_read_once.bats` (FR-012): a
  malformed, unreadable, and absent source each produce today's exact error, warning, exit code, **and point in
  the run**. Reading once must not collapse a diagnostic that is emitted once today, nor suppress one.
- [ ] T035 [P] [US2] Add the self-write case to `tests/bash/lib/test_config_read_once.bats` (FR-013): when the
  run writes to a configuration source it owns — the hooks-disabled toggle in `scripts/bash/lib/config.sh` is
  the known instance — a later phase asking a question that write changed receives the post-write answer.
- [X] T036 [P] [US2] Add the configuration-line spawn assertion to
  `tests/bash/lib/test_config_read_once.bats`: the spawn count does not grow with the number of configuration
  lines (`contracts/spawn-budget.md` C1.2). Fails today — the YAML parser forks per line, measured at ~6 ms/line
  on unmanaged hardware. **Done alongside T038** (the test and the fix landed together — the test file also
  carries a header note on why T033–T035/T036a/T036b were not added: `config_load` already reads each file
  once per call, so the read-once orchestration itself was not the defect here, only the per-line parse cost
  was).
- [ ] T036a [P] [US2] Add the precedence and defaulting parity cases to
  `tests/bash/lib/test_config_read_once.bats` (FR-011): for an absent key, a defaulted key, a key set only in
  the team config, a key set only in the local binding, and a key set in **both**, the resolved answer and the
  rung it came from are identical to today's. Constitution V is what this protects — reading each source once
  must not merge them, and the resolved result still records which rung answered.
- [ ] T036b [P] [US2] Add the containment cases to `tests/bash/lib/test_config_read_once.bats` (FR-014): the
  resolved result is never written to any file, does not survive the process, and holds no credential
  material — asserted with a credential-shaped value present in the environment and absent from every byte the
  run writes. Constitution IV's enforcement test requires this proof, and the spec's own Constitution Check
  cites FR-014 as it.

### Implementation for User Story 2

- [X] T037 [US2] Resolve the configuration once in `scripts/bash/commands/reconcile.sh` and have every later
  phase read the resolved result rather than re-reading a file (FR-009, FR-010). The resolved result is
  process-scoped, never persisted, and holds no credential material (FR-014). **`config_load` (`config.yml` +
  `config.local.yml`'s team layer) was already single-read; a SEPARATE file, `config.local.yml`'s
  `resolved_ids` binding, was not** — `_reconcile_local_binding_for` re-opened and fully re-parsed it from
  disk once in `gate` (`gate_binding`) and again in `plan` (`_reconcile_plan_context`), for the identical
  (project-key, config-dir) pair, in the same run. Found from the real-machine "spawn count down 38%, wall
  time down 4.5%" disconnect: a 100 ms/call here-string-redirection cost (measured directly on that machine)
  is real but too small to explain the gap alone; a second full file-read-and-parse most runs' security
  software would scan is a more plausible remaining piece. Fixed: `_reconcile_plan_context` takes an optional
  cached-binding parameter; `reconcile.sh` passes gate's already-resolved `gate_binding` when gate's own
  resolution succeeded (empty otherwise, so a gate-time failure still reaches `_reconcile_plan_context`'s own
  fault path unchanged — behaviour-preserving by construction, not merely by testing). 12 plan-context tests,
  the full suite (1885 tests), and the corpus stay green. **Confirmed on the real machine (2026-08-11)**: same
  1-story/10-task scenario, `plan` 36 826 ms → **3 244 ms (-91.2%)**; total 147 957 → 116 559 ms (-21.2%).
  `config`/`gate`/`apply` unchanged (~33-35 s each), as expected — this fix only removed `plan`'s redundant
  second read. One full `config.local.yml` read-and-parse costing ~33 s on this machine is now a
  directly-measured fact, not an inference.

> **Open finding (2026-08-11), not implemented — next session's most promising lead.** `config.local.yml` is
> still read from disk **twice** in total, not once: `config_load` (`lib/config.sh`) reads it during the
> `config` phase for its `.overrides` (team-layer merge) key; `_reconcile_local_binding_for` reads the SAME
> file again during `gate` for its `.resolved_ids` key — `config_load`'s own internal parse is never exposed
> to callers, so this second read cannot reuse it without changing `config_load`. Given the `config`/`gate`
> durations (~34 s / ~33 s) now closely bracket the ~33 s one confirmed read costs, this redundant read is the
> leading explanation for both remaining costs.
>
> **Why not fixed this session**: `config_load` is a foundational `lib/config.sh` function used by every
> command that reads project configuration, not `reconcile.sh`-specific — widening its contract (to expose or
> accept a pre-parsed `config.local.yml`) is a broader, higher-risk change than anything else done this pass,
> which stayed inside `reconcile.sh`/`plan_apply.sh`/`recognition.sh`/engine parsers. Options for the next
> pass: (a) extend `config_load`'s return shape to also carry the raw local JSON (breaks/changes a
> widely-tested contract — audit every caller first); (b) a file-content-keyed memoisation cache inside
> `lib/config.sh` itself (mirrors `jira_request_count`'s subshell-proof file-cache pattern, T014) so ANY
> caller reading the same path twice in one run gets the second read free, without changing any function's
> signature — likely the lower-risk option, but unproven.
>
> **Also still open: the `apply` phase's ~35 s, unexplained.** Read through `apply_writes_with_recognition`
> (`plan_apply.sh`) end to end for this session's "zero writes" scenario — the only disk read found is one
> `cat` of `spec_file` (necessary, to decide whether a `creating` marker needs splicing; unconditional but
> single and small), and the story/task write loops iterate zero times when `plan_lifecycle` has already
> dropped every action (matching `requests: 1` — recognition's read alone). Nothing else in this function
> reads a file or forks per item. Confirmed NOT a duplicate-config-read case like `gate`/`plan` were.
> **Unresolved** — needs either a phase-scoped broad-diagnostic run (the existing `broad_spawn_count.sh`
> script, but bracketed to just the `apply` phase) or a different profiling approach on the real machine to
> find what it is.
- [X] T038 [US2] Remove the per-line forking from the YAML parser in `scripts/bash/lib/config.sh`
  (`_cfg_prep` / `_cfg_parse_value`), applying the Phase 5 technique. Every resolved answer must be identical to
  today's for every key, including absent keys, defaulted keys, keys resolved through the
  team-config-then-local-binding precedence, and keys that produce a validation error (FR-011). **Done, but
  scoped to the parser's two per-line `jq` calls, not `_cfg_prep`/`_cfg_parse_value` (already pure bash, no
  forking).** The two spawning call sites were `_cfg_scalar_json` (one `jq -Rn --arg v … '$v'` per string
  scalar) and `_cfg_parse_mapping` (one per key) — both replaced by `_cfg_json_encode`, a native encoder
  ported from `engine/markdown.sh`'s already-proven `_md_json_escape` (duplicated, not sourced, across the
  lib→engine layer boundary `config.sh`'s own header declares). Verified byte-identical against `jq -Rn --arg`
  for quotes, backslashes, tabs, and C0 control characters (new test). Measured: an 82-line, 40-project
  synthetic config that would have cost ~160 `jq` calls now costs 2 (both from `json_canonical`'s own
  canonicalisation, unrelated to line count) — flat regardless of line count (T036's guard). Every existing
  config test (314 across `tests/bash/lib` and `tests/bash/commands`) stays green.
- [ ] T039 [US2] Make the run's own write path and the resolved snapshot one mechanism, not two, in
  `scripts/bash/lib/config.sh` (`_cfg_hooks_disabled_set`, `config_hooks_disabled_add/remove`) — FR-013 — so a
  self-write cannot leave a later phase acting on a superseded answer. **Not done** — orchestration-level,
  independent of the per-line parsing fix above.
- [ ] T040 [US2] Confirm the first configuration read has **not** moved earlier (FR-015): feature 021's
  short-circuit must still complete without reading configuration at all, or the unchanged re-run stops being
  free. Assert against `tests/conformance/scenarios/us021-state-unchanged.json`. **Not done as a dedicated
  assertion**, but `us021-state-unchanged.json` is part of the full conformance corpus re-run after this
  change (byte-identical, exit 0), which exercises the same invariant indirectly.

**Checkpoint**: configuration is read once and parsed without forking; the short-circuit is still free.

---

## Phase 7: User Story 4 — The hook feels instantaneous (Priority: P2)

**Goal**: the aggregate outcome the operator experiences. No new production code — this phase is measurement
and acceptance.

**Independent Test**: with timing on, reconcile the reference specification five times on the same hardware and
assert the sum of non-request phases is under 20 s, no phase exceeds 5 s, and the spread is within 20% of the
median.

- [ ] T041 [US4] Measure the final isolation-rig profile (five clean runs) and record it in the Measurement Log
  against the Phase 4 baseline. Assert FR-023 (<20 s total excluding requests) and FR-024 (no phase >5 s).
- [X] T042 [US4] Measure the final consuming-repo profile with the maintainer, now decomposable into CPU and
  network, and record it. **This is the acceptance evidence for the feature**, per Constitution XII's dogfood
  requirement — the isolation rig cannot stand in for it. **Done, on a 1-story specification (`Skipped: 1`,
  zero writes).** Total -56.5% (356 565 → 154 942 ms), CPU time -45.3%; `apply` cost 35 399 ms with the single
  request accounted for entirely by `recognition` — confirming the reduction is real local work removed, not
  measurement noise. **Not yet done at the scale the plan's original ~20 000-spawn/3–6 min profile implies**
  (item count for that profile was never recorded — see T021) — this evidence is real but for a much smaller
  specification than the one that motivated the feature.
- [ ] T043 [US4] Record run-to-run variance on both hosts against FR-025's 20% bound. **Report the result
  rather than forcing it**: research R3 attributes the maintainer's 79% to endpoint-security inspection cost
  varying under load, which cutting ~20 000 spawns to a few hundred largely removes but does not fully control.
  If the bound is not met on the managed host after the cuts, that is a finding for the spec, not a task to
  retry — see plan.md "Open items" 1.
- [ ] T044 [US4] Confirm FR-026 by measuring a specification several times larger than the reference: local
  processing grows sub-linearly with item count rather than proportionally to process creation.
- [ ] T045 [US4] Confirm FR-031: a specification reconciled successfully with nothing changed since still
  issues zero requests, performs zero writes, and completes in well under a second.

**Checkpoint**: the feature's headline claims are measured on the machine that motivated them.

---

## Phase 8: User Story 5 — The two ports stay the same program (Priority: P3)

**Goal**: the PowerShell port is measured, and changed only where it shares the per-item spawning pattern.

**Independent Test**: profile the PowerShell port on the reference specification; assert Pester and the
conformance corpus pass unmodified and the module maps still correspond one-to-one.

> **Expected outcome: no code change.** Research R7 measured `Parse.psm1` as spawning no external process at
> all (26 in-process `ConvertTo-Json`/`ConvertFrom-Json` sites) and `Timing.psm1` as reading `UtcNow.Ticks`.
> A port that does not fork is immune to the per-spawn multiplier entirely. These tasks confirm that by
> measurement and record it; they do not presume work.

- [ ] T046 [P] [US5] Profile the PowerShell port on the reference specification with timing on and record the
  per-phase profile alongside the Bash one in the Measurement Log (US5 AC1).
- [ ] T047 [US5] Audit `scripts/powershell/engine/Parse.psm1`, `scripts/powershell/lib/Config.psm1`, and
  `scripts/powershell/sink/jira/PlanApply.psm1` for any per-story, per-task, or per-configuration-line external
  invocation (US5 AC2). Where one is found, apply the Phase 5 technique; where none is, change nothing (US5
  AC3) — and record which it was.
- [ ] T048 [US5] Confirm module-for-module equivalence after all Bash changes (FR-033, US5 AC5) by comparing
  `scripts/bash/{lib,engine,sink/jira}/` against `scripts/powershell/{lib,engine,sink/jira}/`. This feature is
  subtractive on the Bash side, so the ports should have converged; assert no consolidation exists as a module
  on one port and nowhere on the other.

**Checkpoint**: both ports measured, equivalence proven, and the PowerShell scope resolved by evidence.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T049 [P] Run the full Bash suite (`tests/run-bash.sh`, ~190 s) and confirm green. Use
  `tests/run-bash.sh --since <ref>` for the inner loop, but the final gate is the full run.
- [ ] T050 [P] Run the full Pester suite over `tests/powershell/` and confirm green. Discovery order differs by
  host on this project, so a green macOS run is not evidence for the Linux runner — check both.
- [ ] T051 Run `bash tests/conformance/ci-conformance.sh` and confirm exit 0 with zero
  `conformance divergence` lines. Success is silent — there is no pass banner, and the temp paths it prints are
  harness noise.
- [ ] T052 [P] Run `find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +` and `actionlint`;
  both must be clean. Scope the shellcheck run to `scripts/bash` — a whole-tree scan is ~1 900 lines of
  host-script noise.
- [ ] T053 Push to `ci/windows-probe` and confirm the conformance corpus on the real Windows runner (~11 min;
  results arrive as check-run annotations). **Take the pre-change baseline first** — `main` is not green on
  `windows-latest`, so diff against that baseline before attributing a failure to this branch. At most one
  retry, then hand the result back.
- [ ] T054 [P] Add the CHANGELOG entry (Constitution XII): the locale fix, the request-counter fix, and the
  spawn reduction, with the measured before/after figures from the Measurement Log.
- [ ] T055 [P] Update `docs/` where the timing report or the configuration snapshot semantics are described,
  including the deliberate behaviour change of spec A-5: the configuration snapshot is per-process, so a source
  edited on disk by a third party mid-run is not observed by the remainder of that run.
- [ ] T056 Confirm no task in this list changed an existing test to accommodate a behaviour change, with the
  single audited exception of T016 (FR-032). If a second one appears, stop: it is evidence the feature has
  exceeded its scope.

---

## Measurement Log

Append one row per measurement. **Counting runs and timing runs are separate runs** (research R4).

| Date | Task | Host | Rig | Total | parse | config | gate | plan | apply | spawns | µs/spawn |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2026-08-10 | pre | unmanaged | mock, 61 items | 91 515 ms | 52 698 | 514 | 465 | 16 286 | 16 164 | 20 243 | 2 445 |
| 2026-08-10 | pre | unmanaged | mock, 61 items (run 3) | 96 519 ms | 56 263 | 546 | 446 | 17 022 | 16 517 | — | — |
| — | pre | **managed (maintainer)** | live Jira, consuming repo | **3–6 min** | 20 s | 84 s | 79 s | 83 s | 82 s | ~20 000 | **9–18 000 (inferred)** |
| 2026-08-10 | post-T025/T026 | unmanaged | mock, 61 items | 80 694 ms | 38 146 | 542 | 540 | 17 368 | 16 493 | not re-measured — spawn-count harness (T002) hit an env-propagation quirk under `run-scenario.sh` this pass; see note below | — |
| 2026-08-10 | post-T025/T026 | unmanaged | mock, 61 items (run 2) | 76 552 ms | 35 736 | 485 | 454 | 16 223 | 16 098 | — | — |
| 2026-08-10 | T018 baseline (run 1) | unmanaged | mock, 61 items | 73 544 ms | 30 092 | 547 | 515 | 17 103 | 16 914 | — | — |
| 2026-08-10 | T018 baseline (run 2) | unmanaged | mock, 61 items | 77 353 ms | 31 808 | 560 | 521 | 18 287 | 17 564 | — | — |
| 2026-08-10 | T018 baseline (run 3) | unmanaged | mock, 61 items | 79 422 ms | 31 299 | 537 | 487 | 19 181 | 19 122 | — | — |
| 2026-08-10 | T019 spawn baseline | unmanaged | mock, 61 items | — | — | — | — | — | — | 14 556 (13 013 jq + 1 543 sed) | — |
| 2026-08-10 | T019a recognition attribution | unmanaged | mock, 61 items | — | — | — | — | — | — | 2 398 of 13 013 jq calls (18.4%) fall inside the `recognition` phase window | — |
| 2026-08-11 | post-T030/T031/T031a | unmanaged | mock, 61 items | — | — | — | — | — | — | 13 057 (11 514 jq + 1 543 sed), down from 14 556 | — |
| 2026-08-11 | pre (real, v0.14.0) | **managed (maintainer)** | live Jira, consuming repo | **349 241 ms** | 20 342 | 84 253 | 79 087 | 83 236 | 81 885 | — | — |

The third row is the maintainer's own **inferred** measurement; the row dated 2026-08-11 above it is the same
machine's **real** `reconcile --force` timing report on v0.14.0 (pre-feature) — `prereq` 17 ms, `state` 0 ms,
`recognition` 421 ms, matching the inferred figures closely and confirming `requests: 0ms` on every phase (the
same request-counter defect Phase 3 fixes). Shell `time`: 75.71 s user, 109.23 s system, 52% CPU, 5:50.45
(350.45 s) wall — under half the wall clock is active CPU, consistent with an EDR-style agent delaying each
`exec()` without itself consuming CPU during the delay. Item count (stories/tasks) for this run was not
recorded; still needed to normalise against the 61-item reference. T020's own isolated per-spawn µs benchmark
(`quickstart.md` §5a) has not yet been run on this machine — the number above is a full-run report, not that
micro-benchmark, so µs/spawn here is still blank pending it. Per-spawn cost is otherwise inferred from
spawns × time and would be confirmed by T020.

> **Second real pre-fix run (2026-08-11), same 1-story specification, network connected.** `prereq` 19 ms,
> `config` 82 654 ms, `parse` 20 555 ms, `gate` 79 954 ms, `recognition` 5 497 ms, `plan` 83 726 ms, `apply`
> 84 251 ms, total 356 565 ms, `requests: 0` throughout (same v0.14.0 defect). Outcome: `Created 0, Updated 0,
> Skipped 1, Recognised 1` — the story already carried a ticket from the earlier run and needed no change.
> `config`/`gate` are within 1% of the first run's figures despite the different outcome, reinforcing the
> fixed-per-run reading above. **New finding: `apply` cost 84 251 ms while writing nothing (`Skipped: 1`)** —
> whatever dominates `apply` here is not proportional to writes performed, at least at this item count. A
> single `recognition` read (one ticket, already bound) cost 5 497 ms alone, suggesting **individual Jira
> requests may cost multiple seconds on this network** (corporate proxy/TLS/inspection) — if so, part of
> `plan`/`apply`'s cost is request latency this feature's spawn-count work cannot address, not spawn count.
> Shell `time`: 77.69 s user, 112.02 s system, 53% CPU, 5:57.92 (357.92 s) wall. **Next**: re-run this exact
> scenario (same spec, same already-bound story — an apples-to-apples "skip" case) on the
> `feat/024-reconcile-local-performance` branch, without `LC_ALL=C`, to get the first real per-phase
> **request count** on this machine and settle whether `apply`/`plan` are request-latency-bound or
> spawn-bound.

> **T042 acceptance evidence (2026-08-11) — same machine, same 1-story "skip" scenario, on
> `feat/024-reconcile-local-performance` (all fixes in this pass, no `LC_ALL=C`).** `prereq` 22 ms, `state` 2
> ms, `config` 33 885 ms, `parse` 6 612 ms, `gate` 33 659 ms, `recognition` 6 604 ms, `plan` 38 759 ms, `apply`
> 35 399 ms, **total 154 942 ms, requests: 1** — the first non-zero request count ever measured on this
> machine (Phase 3's fix confirmed live). Shell `time`: 41.18 s user, 62.71 s system, 66% CPU, 2:36.04
> (156.04 s) wall.
>
> **vs. the pre-fix run above**: total -56.5% (356 565 → 154 942 ms); CPU time (user+system) -45.3%
> (189.71 s → 103.89 s) — a genuine reduction in work done, not just less waiting. Per phase: `config` -59.0%,
> `parse` -67.8%, `gate` -57.9%, `plan` -53.7%, `apply` -58.0%. `recognition` +20.1% (5 497 → 6 604 ms) — noise
> from a single Jira GET's variable network latency, not a regression (recognition.sh's fix only touched local
> `jq` calls). **`gate` and `plan` improved despite receiving no direct code change** — both resolve
> configuration via `config.sh`, so they inherit T038's per-line-forking fix indirectly.
>
> **The single request this run made was `recognition`'s read; `apply` issued zero Jira requests
> (`Skipped: 1`) yet still cost 35 399 ms, entirely local** — confirms the T030/T031 note's prediction:
> `plan_writes`/`apply_writes`'s remaining per-story payload-building (left untouched this pass) is real,
> substantial, non-network cost, and is where the next optimisation pass should look first.
>
> **Honest gap**: even at -56.5%, this machine is nowhere near FR-023 (<20 s total excluding requests) or
> FR-024 (no phase >5 s) — every phase but `prereq`/`state` still exceeds 5 s, and the total (minus the one
> request) is still ~155 s. The relative win is large and real; the feature's own numeric acceptance criteria
> are not met on this machine yet.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)** — T002/T003 block Phase 4 and Phase 5; T001 blocks Phase 2's locale tests.
- **Phase 2 (US1, locale)** — depends on T001 only. **First by maintainer direction.** Shippable alone.
- **Phase 3 (request counter, FR-036/FR-037)** — independent of Phase 2 in code, sequenced after it by
  direction. Blocks Phase 4's decomposition and therefore every claim in Phases 5–7.
- **Phase 4 (Baseline)** — requires Phases 2 and 3. Blocks Phases 5, 6, 7. T019a additionally blocks T024a
  and T031a, which are written against whatever it measures.
- **Phase 5 (US3)** — requires Phase 4. T025→T028 must complete before T029; T029, T030, T031 are strictly
  sequential with a corpus run between each (research R6). T031a follows them and is conditional on T019a.
- **Phase 6 (US2)** — requires Phase 4; reuses Phase 5's technique, so sequenced after it.
- **Phase 7 (US4)** — requires Phases 5 and 6. Measurement only.
- **Phase 8 (US5)** — requires Phase 5 (for equivalence checking); otherwise independent.
- **Phase 9 (Polish)** — requires all.

### Within Each Phase

Tests precede implementation, always, and must be observed failing for the right reason before the fix.

### Parallel Opportunities

- **Phase 1**: T001, T002 in parallel (T003 after T002).
- **Phase 2**: T004–T007 all parallel (different assertions, and T007 is a different port). Implementation
  T008→T009 is sequential — same function.
- **Phase 3**: T011–T013 parallel.
- **Phase 4**: T019, T019a, T020 parallel with each other; T018 separate (timing must not share a run with
  counting).
- **Phase 5**: T022–T024a parallel. **Implementation is deliberately serial** — this is the one place where
  parallelism is refused on purpose.
- **Phase 6**: T033–T036b parallel.
- **Phase 9**: T049, T050, T052, T054, T055 parallel; T051 and T053 after them.

### Parallel Example: Phase 2

```text
# Four agents, four independent assertions:
T004  fr_FR duration correctness      -> tests/bash/lib/test_timing.bats
T005  de_DE + C matrix, byte-identity -> tests/bash/lib/test_timing.bats
T006  fail-open under set -e          -> tests/bash/lib/test_timing.bats
T007  PowerShell regression guard     -> tests/powershell/lib/Timing.Tests.ps1
# Then serially: T008 -> T009 -> T010
```

---

## Implementation Strategy

### MVP (Phase 1 + Phase 2 only)

The locale fix, shipped alone. It closes the feature's only live crash — under `set -euo pipefail` the failing
clock read aborts the whole reconcile — and restores the diagnostic for every operator on a comma-decimal
locale, which is most of continental Europe and Latin America. It changes no behaviour and needs no
re-measurement to justify.

### Incremental delivery

1. **Phases 1–2** → comma-locale operators can measure a run. Ship.
2. **Phase 3** → the report tells the truth about requests. Ship.
3. **Phase 4** → the baseline exists on both hosts, decomposable for the first time.
4. **Phase 5** → the four expensive phases stop forking. The largest single win.
5. **Phase 6** → configuration read once and parsed without forking.
6. **Phases 7–8** → acceptance measured, cross-port equivalence proven.
7. **Phase 9** → gates, docs, Windows probe.

### Three places to stop and think rather than push through

- **T016** is the only existing expectation this feature edits. If a second one needs changing, the feature has
  exceeded its scope (FR-032) — stop and report rather than adjusting it.
- **T029–T031** are serial by design. If a corpus divergence appears after doing two of them together, the
  bisect cost is exactly what the serial ordering was meant to avoid.
- **T043** may not meet FR-025's bound on the managed host, and that is an acceptable outcome to report. The
  residual variance is endpoint-security inspection cost, not code. Do not tune the measurement to hit the
  number.
