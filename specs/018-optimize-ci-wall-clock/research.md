# Phase 0 Research — Cut CI Wall-Clock to a 20-Minute Merge Decision

**Feature**: 018-optimize-ci-wall-clock
**Date**: 2026-08-05
**Status**: complete for the POSIX-measurable questions; **four** questions
(W1–W4, §6) are answerable only on a real `windows-latest` runner and are stated
below with the decision rule each one settles (Constitution VI,
FR-003/FR-004/FR-018).

---

## 1. Where the wall-clock actually goes

### 1.1 The blocking inventory and the critical path

Nine job **definitions** across three workflows, expanding to eleven check runs
(the `unit` definition is a three-OS matrix). This is the inventory SC-006 pins.

| Workflow | Job definition | Check runs | Duration (run `30947466217`, 2026-08-04) |
| --- | --- | --- | --- |
| ci.yml | `unit` | 3 | **95m18s** (windows) / 48m33s (ubuntu) / 42m25s (macos) |
| ci.yml | `lint` | 1 | 39s |
| ci.yml | `static-checks` | 1 | 46s |
| gates.yml | `changes` | 1 | 4s |
| gates.yml | `coverage-bash` | 1 | **15m39s — FAILED at its timeout** |
| gates.yml | `coverage-pwsh` | 1 | 13m02s |
| gates.yml | `module-parity` | 1 | 7s |
| gates.yml | `version-string` | 1 | 5s |
| boundary.yml | `engine-sink-boundary` | 1 | ~30s |

Push to complete merge decision: **≈ 95 minutes**, entirely set by the
`windows-latest` leg of `unit`.

### 1.2 Step-level breakdown of the `unit` job

| Step | ubuntu | macos | windows |
| --- | --- | --- | --- |
| checkout + toolchain + specify-cli | ~20s | ~19s | ~14s |
| `tests/run-bash.sh` (Bash suite) | **38m55s** | **33m17s** | skipped |
| Pester | 4m29s | 3m40s | 6m54s |
| conformance corpus | 4m44s | 5m03s | **88m04s** |

Two independent critical paths, not one:

- **windows**: the corpus, at 88 of 95 minutes.
- **ubuntu / macos**: the bats suite, at 33–39 of 42–48 minutes.

The second was not in the original request. It is included because SC-003's
20-minute target is arithmetically unreachable while a `unit` leg costs 48
minutes (spec.md Assumptions, first entry).

---

## 2. Why a conformance scenario costs 33× more on Windows

### 2.1 Decision: the cost is process creation, and it is dominated by the *Bash* port

**Measured 2026-08-05** on this macOS host, by wrapping `jq`, `curl`, `mktemp`,
`sed`, `cp`, `pwsh` and `git` in counting shims on PATH and running
`tests/conformance/run-scenario.sh` once per port over
`us1-config-idempotent.json` (8 HTTP calls, 2 runs — a mid-weight scenario):

| Port leg | Total counted spawns | Composition |
| --- | --- | --- |
| **bash** | **610** | 492 `jq`, 86 `sed`, 20 `mktemp`, 12 `cp` |
| **powershell** | **28** | 10 `cp`, 7 `jq`, 6 `sed`, 3 `mktemp`, **2 `pwsh`** |

Attributed by walking each `jq` process's parent (same method, same scenario):

| Caller of `jq` | Spawns | Ownership |
| --- | --- | --- |
| `scripts/bash/spec-kit-jira.sh` — the port itself | **457 (93%)** | **production code, frozen by FR-020** |
| the curl shim (`mock-jira/curl-shim.sh`) | 27 (5%) | test code, changeable |
| `run-scenario.sh` (`jq_lines`) | 8 (2%) | test code, changeable |

**On Windows the count is higher still.** `ci-conformance.sh`'s own header
records that "the text-mode-jq guard in `lib/output.sh` doubles the process
count of the Bash port on that host alone" — every `jq` call on Windows carries
a second process to strip the CR that `jq.exe`'s text-mode stdout appends. The
Windows bash leg is therefore ≈ **1000 process creations per scenario**, against
28 for the PowerShell leg.

**Rationale**: 88m04s / 84 scenarios at a concurrency of 2 = ~126 s of worker
time per scenario. Divided by ~1000 process creations that is ~120 ms per
spawn — the expected order for an MSYS emulated `fork` plus a native PE image
load plus Defender's on-access scan. The model closes to within its own
precision, on data measured rather than assumed, and it identifies the
PowerShell leg (28 spawns) as a rounding error rather than the cause.

**This overturns the diagnosis in the request.** The brief attributes the
Windows cost to "git-bash fork + pwsh mock startup". The pwsh mock is two
process spawns out of roughly a thousand. What costs is the Bash port's own
`jq`-per-JSON-operation design, multiplied by MSYS's spawn price and doubled
again by the CRLF guard.

**Alternatives considered**:
- *Mock-server reuse across scenarios* — the obvious read of the brief. Rejected
  as a lever: it removes at most 2 of ~1000 spawns on the bash leg and 2 of 28 on
  the pwsh leg. It would also break the per-scenario isolation FR-008 requires.
- *Batching scenarios into one long-lived pwsh session* — same objection, same
  ceiling, and it couples scenarios that are currently independent.

### 2.2 Decision: scenario cost is wildly uneven, and dynamic scheduling already handles it

**Measured** on Windows probe run `30972259389` (2026-08-05, 84 scenarios split
statically 4 ways, each shard at concurrency 2):

| Shard | Scenarios | Wall-clock |
| --- | --- | --- |
| 0 | 21 | 30m56s |
| 1 | 21 | 14m27s |
| 2 | 21 | **46m00s** |
| 3 | 21 | 10m22s |

A **4.4× spread** across equal-sized static shards. Per-scenario cost tracks the
number of HTTP writes (hence `jq` calls), and the corpus's round-robin slice —
alphabetical, striped — does not balance it.

**Consequence**: any *static* partition of the corpus is bound by its unluckiest
slice. The `unit` job's in-step form already avoids this — `ci-conformance.sh`
feeds scenarios to `xargs -P`, which is work-stealing — so there is **no win
available from better sharding inside the job**. The win must come from spawn
cost or from concurrency.

**Rationale for keeping `xargs -P`**: it is dynamic, dependency-free, and
already proven on all three hosts. Replacing it with a static N-way split would
be a regression against the numbers above.

### 2.3 Decision: in-step parallelism is not the missing piece — it already exists

The request's deliverable 1 asks to "shard the conformance corpus by scenario
across cores within each OS's existing job step". `ci-conformance.sh` has done
exactly that since the 008 merge (`21068d6`): `xargs -P "$(core_count)"`, with
`core_count()` returning `nproc`/`sysctl`/`NUMBER_OF_PROCESSORS` — **except on
MSYS, where it returns a hard-coded 2**, because an unthrottled run "died with
the hosted runner lost communication with the server partway through the
corpus".

So the lever is not "add parallelism", it is "raise a cap that was lowered for a
measured reason, and prove the reason no longer applies".

---

## 3. What can be done under FR-020 (production code frozen)

Arithmetic against the 88m04s Windows corpus step, each factor independent:

| Lever | Scope | Expected factor | Confidence |
| --- | --- | --- | --- |
| A. Raise the MSYS concurrency cap 2 → 4 | `tests/` | up to 2.0× | **unproven** — the cap exists because 4 killed the runner |
| B. Windows Defender exclusions for the workspace, temp dir, git-bash and `jq.exe` | `.github/workflows/` | 1.3–2.0× | **unproven** — Defender's per-spawn scan is the standard MSYS-on-Actions tax |
| C. Remove test-owned spawns (curl shim's 27 `jq`, harness's 8 `jq_lines` + `sed`, `mktemp`/`cp` churn) | `tests/` | ~1.25× | measured share: 153 of 610 POSIX spawns (25%) |
| D. Run a scenario's two port legs concurrently | `tests/` | ~1.08× | the pwsh leg is 28 of ~1030 spawns |

**Best case with A×B×C×D all landing at their optimistic ends**:
88m04s ÷ (2.0 × 2.0 × 1.25 × 1.08) ≈ **16 minutes**.
**Realistic case** (A at 1.6×, B at 1.4×, C at 1.2×, D ignored): ≈ **33 minutes**.

SC-001 needs the whole `unit` job under 18 minutes, i.e. the corpus step under
~10.5 minutes once Pester's 6m54s is paid. **The optimistic case barely misses
it; the realistic case misses it by 3×.**

### 3.1 The largest remaining factor: the second process per `jq` call

**Read from `scripts/bash/lib/output.sh` (lines 50–71), 2026-08-05.** The port
installs a `jq` wrapper **conditionally**, and the condition is asked of jq
rather than of the OS:

```bash
if [[ "$(command jq -rn '"a\nb"' 2> /dev/null)" == *$'\r'* ]]; then
  jq() { … MSYS_NO_PATHCONV=1 command jq "$@" | sed $'s/\r$//'; }
fi
```

On a host whose `jq` emits LF the wrapper is **not defined at all** — no extra
process, POSIX behaviour untouched. On a host whose `jq` emits CRLF (Windows,
where the `jq` on PATH is the native `jq.exe` and its stdout is a text-mode
stream) every one of the port's ~457 `jq` calls per scenario carries a second
process. That is the doubling `ci-conformance.sh`'s header records, and it is
**~500 of a scenario's ~1000 process creations — ~1.9× on the dominant cost**.

Two ways to remove it, with very different scopes:

**(a) Give the Windows runner a `jq` that emits LF.** The wrapper's own
condition then reports false and the wrapper is never installed. **Workflow-
scoped: zero production-code change, FR-020-safe.** An MSYS/Cygwin-built `jq`
writes LF because its stdout is not a Windows text-mode stream.
*The trade-off is real and must not be waved through*: the corpus would then
exercise a `jq` that a Windows user with stock git-bash does not have, and the
CRLF class this guard exists for is exactly what quirks 1 and 7 were. It swaps
a performance problem for a fidelity question, so it is a decision, not a
shortcut — but it is a decision available **without touching production code**,
which is why it leads here.

**(b) Make the guard spawn-free in the port.** Tempting and harder than it
looks. `sed $'s/\r$//'` is a **per-line** transform over a whole stream, not a
trailing-scalar strip: a pure-bash equivalent must walk the entire payload, and
quirk 1 of `docs/10-windows-portability.md` forbids the obvious `$'\r\n'` glob
on that very host — the safe forms are single-character (`${x%$'\r'}`,
`[!$'\r']`, `*$'\r'*`), so it needs a CR-by-CR walk in the style of
`_ms_count_crlf`. For large payloads that can cost **more** than the `sed` it
replaces. This path is production code (FR-020) *and* unproven; it would need
its own measurement before anyone should believe it.

**Arithmetic either way**: removing the doubling puts the realistic case at
≈ 17 minutes and the optimistic case at ≈ 8.5 — i.e. **SC-001 is reachable with
it and probably not without it.**

FR-020 freezes `scripts/bash/**`, and the spec's own escape clause says such a
discovery "is raised as a separate finding rather than fixed silently here".
This research **raises it**, with (a) as the option that respects the freeze and
(b) as the one that does not. Carried into plan.md's Complexity Tracking as a
decision for the user. Feature 009 faced the identical tension and resolved it
the other way (T028 touched `engine/story_marker.sh` because leaving a race on a
blocking gate was worse than the scoping rule).

**Alternatives considered and rejected**:

- *Stop running the Bash port's leg of the corpus on Windows.* This is by far
  the largest possible win — it removes ~97% of the Windows corpus cost — and it
  has a real argument behind it: Constitution VI ships "a Bash implementation for
  macOS and Linux, and a PowerShell 7+ implementation for Windows", so the Bash
  port under git-bash on Windows is not a configuration this project ships.
  **Rejected here**: quirks 1 and 7 of the Windows catalog were both real Bash-port
  defects found precisely by that leg, spec.md puts "reducing Windows verification
  in any form" out of scope, and 009's FR-019 forbids it. Changing it is a
  constitution-level scope decision needing its own spec — recorded so the next
  reader does not have to rediscover the option.
- *Reduce the Bash port's `jq`-per-operation design.* A production performance
  refactor an order of magnitude larger than this feature, touching the module
  every command depends on. Out of scope under FR-020 and under YAGNI.
- *A RAM disk or alternate drive for the scenario workdirs on Windows.* The
  runner's workspace is already on SSD; Defender, not I/O bandwidth, is the
  documented tax. Subsumed by lever B and not worth a separate mechanism (KISS).

---

## 4. The Bash unit suite (the second critical path)

### 4.1 Decision: oversubscribe the workers and schedule longest-first

**Measured shape** (this repository, 2026-08-05): 149 `.bats` files, 1427
`@test`s, discovered `find … | sort` — **alphabetical** — and fed to
`xargs -P "$(getconf _NPROCESSORS_ONLN)"`, i.e. **4 workers on a GitHub runner**.
One `bats` process per file. Largest files: `lib/test_config.bats` (91 tests),
`commands/test_config_field_defaults.bats` (52), `sink/test_hierarchy.bats` (37).

38m55s × 4 workers ÷ 1427 tests ≈ **6.5 s of worker time per test**, on a suite
whose tests mostly drive the port end to end — the same spawn-heavy profile as
§2.1, on slower cores.

Two changes follow from the shape, neither of which removes a test:

1. **Oversubscription.** These workers are process-creation- and I/O-bound, not
   CPU-bound: a `bats` worker spends most of its life waiting on `fork`/`exec`
   and on short-lived `jq` children. `-P 4` on a 4-vCPU runner therefore leaves
   the box idle a large fraction of the time. Raising the multiplier (`-P 2×`
   or `3×` the core count) is the standard remedy and costs nothing when the
   machine is genuinely saturated.
2. **Longest-processing-time-first ordering.** With 149 uneven files on N
   workers, alphabetical order leaves the makespan hostage to whichever heavy
   file starts last; LPT ordering is the classic ≤4/3-of-optimal fix. The order
   can be derived from a committed timing profile, refreshed by the nightly.

**Rationale**: both are changes to `tests/run-bash.sh` alone, both are
verdict-neutral (the same files run, only the order and the degree of
concurrency change), and both are guarded by the existing determinism
requirement (FR-007/FR-008).

**Alternatives considered**:
- *Splitting the 91-test file.* Helps the tail, but hand-partitioning test files
  to please a scheduler is exactly the fragility LPT ordering avoids. Kept in
  reserve if measurement shows a single file still bounds the makespan.
- *Skipping the ~322 `pwsh` invocations across 75 files when a faster double
  exists.* Those are the NFR-1 cross-port parity assertions; on CI `pwsh` is
  preinstalled, so they all run for real. They are worth ~5 worker-minutes in
  total and they are the parity guarantee — removing them fails FR-010.
- *Running the bats suite, Pester, and the corpus concurrently inside the `unit`
  job.* Adds no capacity on an already-saturated box and would interleave three
  logs into one unreadable stream (Constitution XVI). Rejected.

### 4.2 Why this was not measured locally

The intended measurement — per-file durations, to build the LPT profile — was
not taken on this host: load average was **167** at the time of writing with
~1 GB free, from concurrent sessions. Any timing taken there is noise, and this
project's own memory rule is to size budgets from real runner timings rather
than local wall clocks. The profile is therefore built in CI, as task work.

---

## 5. The Bash coverage gate

### 5.1 Decision: shard the kcov exercise phase, drop the second collector

**How it works today** (`tests/coverage/bash-coverage.sh`, 534 lines): two
collectors, merged.

- **kcov** owns the denominator and measures `exercise_scenarios`, which walks
  **all 84 scenarios strictly serially inside one kcov process** (`for scenario
  in …/scenarios/*.json; do … done`), plus `exercise_dispatcher` and
  `exercise_libraries`. Bounded by `SPEC_KIT_JIRA_COVERAGE_TIMEOUT` (600 s in
  CI) — a bound the phase already exceeds: 009's evidence records it reaching
  scenario 46 of 51 when the 600 s expired, in a container faster than the
  runner.
- **A raw `bash` xtrace on fd 8** owns the rest of the numerator, tracing the
  bats unit suite through `tests/run-bash.sh` with `SHELLOPTS=xtrace`. Measured
  at **≈ 5× the untraced suite** — ~31 minutes on a 4-vCPU runner.

The two together cannot fit any budget under 45 minutes. Hence red since
2026-07-28.

**Decision, in three parts**:

1. **Parallelise the kcov phase by sharding it across processes and merging.**
   kcov supports merging independent output directories, so N shards of the
   corpus can each run under their own kcov instance and be merged into one
   report. This is the architectural change FR-011 needs: the phase is serial
   today *by construction*, not by necessity. On 4 vCPU this is the difference
   between ~15 minutes and ~4.
2. **Remove the xtrace collector from the gate** (FR-011) and publish it from
   the non-blocking nightly as coverage-gap evidence (FR-012).
3. **Compensate the numerator inside kcov, not outside it.** Dropping collector
   2 drops every line only the bats suite reached. The compensation lives in
   `exercise_libraries`/`exercise_dispatcher` — test code that already runs
   *under* kcov — extended to drive the library surface the corpus cannot reach.
   This raises the numerator without touching the denominator, which is exactly
   what FR-014 permits and what shrinking the denominator would violate.

### 5.2 Open question — the kcov-alone percentage

**Unknown**: what statement coverage does kcov alone report today? The merged
figure is all that has ever been published, and the gate's floor is 80%.

**Not measurable on this host**: `require_kcov` refuses to run on macOS because
kcov can only drive Apple's SIP-signed `/bin/bash` 3.2, which this port rejects;
the local Docker daemon is not running.

**Decision rule** (settles the shape of task work, not the design):

| kcov-alone result | Action |
| --- | --- |
| ≥ 80% | Ship the kcov-only gate as designed. No numerator work needed. |
| 70–80% | Extend `exercise_libraries` under kcov until the floor is met, then ship. |
| < 70% | Stop and report: the gap is too large to close with exercise code alone, and the honest options (a longer budget, or keeping a second collector in a cheaper form) become a spec question rather than a plan decision. |

Measured first, before any workflow change lands — this is the coverage
equivalent of FR-003's measure-before-design rule.

---

## 6. Questions only `windows-latest` can answer

Per Constitution VI and FR-018, these do not get answered by reasoning. Each is
one measurement line added to the probe's existing `::notice::` channel (the doc's
own prescription: "when a new question needs a fact only Windows can supply, add
one measurement line to that notice").

| # | Question | Decision it settles |
| --- | --- | --- |
| W1 | What does one process creation cost on this runner — `jq.exe`, a git-bash `fork`, a `pwsh` start — with and without Defender exclusions? | Whether lever B is real, and the size of the prize for §3.1 |
| W2 | Does the corpus survive at concurrency 3 and 4, and what is the wall-clock at each? | Lever A, and FR-004's proof obligation |
| W3 | What is the per-port, per-scenario time split on that host? | Confirms §2.1's spawn model on the real host, and sizes what remains after A–D |
| W4 | Does an MSYS-built `jq` emit LF on this runner (making the `output.sh` wrapper condition report false), and what does the corpus then cost? | Option (a) of §3.1 — measured before the user is asked to weigh a fidelity trade-off against an unknown |

W2 must report the *runner's survival*, not just a duration: the cap exists
because a wider fan-out lost the runner, and "it finished" is the only evidence
that matters.

---

## 7. Determinism, before any of this gates (FR-007)

The corpus is already parallel, so the determinism requirement is not about a
new execution model — it is about a **wider** one. Two consecutive full-corpus
runs at the new concurrency, on one POSIX host and on `windows-latest`, must
produce byte-identical captures per scenario and an identical verdict set.

This is not a formality. 009 found exactly this class of defect at exactly this
point: a PID-keyed cursor file in `engine/story_marker.sh` collided only under
the higher subprocess churn its speed-up created, and surfaced as one scenario
diverging in one run out of two. The check is the tripwire for the next one.

---

## 8. Summary of decisions

| # | Decision | Rationale | Requirement |
| --- | --- | --- | --- |
| D1 | Keep `xargs -P` dynamic scheduling; add no static sharding inside the job | Measured 4.4× imbalance across equal static shards; work-stealing already solves it | FR-002 |
| D2 | Raise the MSYS concurrency cap only after a probe run proves the runner survives | The cap encodes a real measured failure | FR-004, FR-018 |
| D3 | Add Defender exclusions in the workflow and measure the effect | Per-spawn scan is the standard MSYS-on-Actions tax; workflow-scoped, so FR-020-safe | FR-003 |
| D4 | Remove test-owned spawns from the shim and the harness | 25% of measured spawns, entirely in `tests/` | FR-003, FR-020 |
| D5 | Oversubscribe and LPT-order `tests/run-bash.sh` | Workers are spawn-bound, not CPU-bound; 149 uneven files on 4 workers | FR-009 |
| D6 | Shard the kcov exercise phase and merge; drop the xtrace collector to the nightly | The serial phase is serial by construction; two collectors cannot fit any sane budget | FR-011, FR-012 |
| D7 | Compensate the numerator inside kcov via the exercise phase | Raises the numerator without shrinking the denominator | FR-014 |
| D8 | Raise the CRLF-guard doubling to the user with both options costed — (a) an LF-emitting `jq` on the Windows runner, workflow-scoped and FR-020-safe but a fidelity trade-off; (b) a spawn-free guard in the port, production code and unproven | ~1.9× on the dominant cost, and SC-001 is probably unreachable without it; the spec's escape clause says raise, do not fix silently | FR-020, plan Complexity Tracking |
