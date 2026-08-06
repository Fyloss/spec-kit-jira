# Baseline — Cut CI Wall-Clock to a 20-Minute Merge Decision

Evidence log for feature 018. Every figure below carries a run id (or the exact
command that produced it) and a date, per FR-022/SC-013. Entries are appended
as later tasks measure them — nothing here is edited retroactively except to
correct a transcription error, and any such correction is noted inline.

---

## T001 — Starting point (run `30947466217`, gates run `30947468905`, 2026-08-04)

### Blocking inventory, job-level

| Workflow | Job definition | Check runs | Duration |
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

Push to complete merge decision: **≈ 95 minutes**, set entirely by the
`windows-latest` leg of `unit`.

### `unit` job, step-level

| Step | ubuntu | macos | windows |
| --- | --- | --- | --- |
| checkout + toolchain + specify-cli | ~20s | ~19s | ~14s |
| `tests/run-bash.sh` (Bash suite) | 38m55s | 33m17s | skipped |
| Pester | 4m29s | 3m40s | 6m54s |
| conformance corpus | 4m44s | 5m03s | **88m04s** |

Source: research.md §1.1–1.2, both traceable to run `30947466217` (unit) and
`30947468905` (gates), 2026-08-04.

---

## T002 — Frozen reference counts (measured 2026-08-05, this worktree)

| Metric | Count | Command |
| --- | --- | --- |
| Conformance scenarios | **84** | `find tests/conformance/scenarios -name '*.json' \| wc -l` |
| `.bats` files | **149** | `find tests/bash -name '*.bats' \| wc -l` |
| `@test`s across those files | **1427** | `grep -rhoE '^\s*@test' tests/bash --include='*.bats' \| wc -l` |
| Pester `.Tests.ps1` files | **125** | `find tests/powershell -iname '*.Tests.ps1' \| wc -l` |
| Job definitions | **9** | manual count across `.github/workflows/{ci,gates,boundary}.yml` `jobs:` blocks (see T003 table) |
| Check runs | **11** | `unit` renders 3 (matrix), the other 8 job definitions render 1 each |

**Scenario, `.bats`-file, `@test`, and Pester-file counts reproduce the figures
in plan.md's Scale/Scope and data-model.md §1 exactly.**

**Pester assertion count — discrepancy noted, not silently reconciled.**
plan.md and data-model.md state "1128 Pester assertions across 125 files".
The 125-file count reproduces exactly. For the assertion count itself, three
interpretations were tried against the current tree:

| Interpretation | Command | Result |
| --- | --- | --- |
| `It` blocks (test-case unit, the Pester analogue of a bats `@test`) | `grep -rhoE '^\s*It\b' tests/powershell --include='*.Tests.ps1' \| wc -l` | **1112** |
| `Should` invocations, one per physical line | `grep -rhE '^\s*\S.*\bShould\b' tests/powershell --include='*.Tests.ps1' \| grep -cE '\bShould\b'` | 2484 |
| `Should -Xxx` cmdlet calls | `grep -rhoE 'Should -\S+' tests/powershell --include='*.Tests.ps1' \| wc -l` | 2500 |

None reproduces 1128 exactly. The closest and most defensible reading — `It`
blocks are the Pester unit that plays the same role bats' `@test` plays for the
1427 figure — comes in at 1112, 16 short of 1128. Given the `@test` figure
reproduced exactly, this is most likely ordinary drift (a handful of `It`
blocks added or removed) between whenever the design docs' number was taken
and this measurement, rather than a different command. **Recorded for T049 to
re-check against**: the SC-008 non-shrinkage bound is `≥ 1128` as documented;
today's actual `It`-block count (1112) is *below* that documented figure,
which T049 must resolve — either the design docs' number needs correcting to
1112 (a documentation fix) or 16 `It` blocks were genuinely lost since
2026-08-04/05 (a real regression). This baseline does not resolve it; it flags
it.

### Job definitions and check-run names (verified against workflow source, 2026-08-05)

| Workflow | Job id | Check-run name |
| --- | --- | --- |
| ci.yml | `unit` | `Unit suites (ubuntu-latest)` |
| ci.yml | `unit` | `Unit suites (macos-latest)` |
| ci.yml | `unit` | `Unit suites (windows-latest)` |
| ci.yml | `lint` | `Lint (shellcheck, PSScriptAnalyzer)` |
| ci.yml | `static-checks` | `Static checks (manifest, messages, registry writes)` |
| gates.yml | `changes` | `Detect Bash-relevant changes` |
| gates.yml | `coverage-bash` | `Bash coverage >= 80% (kcov primary, traceability fallback)` |
| gates.yml | `coverage-pwsh` | `PowerShell coverage >= 80% (Pester)` |
| gates.yml | `module-parity` | `Twin ports mirror module-for-module` |
| gates.yml | `version-string` | `Version literal single-sourced (SC-006, FR-021/022)` |
| boundary.yml | `engine-sink-boundary` | `engine/ carries zero Jira knowledge` |

Matches `contracts/blocking-inventory.md`'s frozen set byte-for-byte.

---

## T003 — Pre-existing `windows-latest` verdict set (FR-019's comparison baseline)

Per spec.md checklist notes and research.md, `main` is red on `windows-latest`
for two genuine divergences this feature does not own:

- `us2-field-defaults-option-question` — **fail**
- `us2-field-defaults-question` — **fail**
- every other scenario — **pass**

This is the verdict set T045/T046 must reproduce unchanged (no new failure,
none hidden) after the speed-up.

---

## T004–T009b — Instrumentation and guards (landed 2026-08-05)

All six tasks are local, host-independent changes — no CI push required to
validate. Each was written failing first (bats), confirmed red, then made
green (Constitution XIII).

- **T004/T005** — `tests/bash/ci/test_conformance_worker_accounting.bats`
  added; `tests/conformance/ci-conformance.sh` now writes a `VERDICT_DIR`
  marker per scenario, unconditionally, as the LAST line of `run_scenario` —
  a worker killed before reaching it (simulated in the test via a stub
  harness that kills its own `$PPID`) leaves no marker, which is counted as
  a shortfall against the corpus size and printed as `verdicts: N/M`. Full
  local corpus re-run after landing: `verdicts: 84/84`, exit 0 — no
  regression.
- **T006/T007** — `tests/bash/ci/test_conformance_timings.bats` added;
  `tests/conformance/run-scenario.sh` now writes a `duration` file (seconds,
  `$EPOCHREALTIME` before/after minus via `awk`) per port leg; `ci-conformance.sh`
  reads both legs' durations, prints `timing: <name> bash=Xs pwsh=Ys` per
  scenario, and an `amortised per-scenario cost: Xs (wall-clock Ys / N
  scenarios)` summary line. Full local corpus re-run: 84 timing lines,
  `amortised per-scenario cost: 15.517s (wall-clock 93.702s / 84 scenarios)`
  on this macOS host — **not** a CI figure, recorded here only as evidence
  the mechanism works; do not cite this number for a budget decision
  (research §4.2's local-timing caveat applies here too).
- **T008/T009** — `tests/bash/ci/test_blocking_inventory.bats` added,
  asserting B1 (nine job ids / eleven check-run names, byte-identical to
  `contracts/blocking-inventory.md`), B3 (no workflow outside
  ci.yml/gates.yml/boundary.yml carries an unscoped `pull_request` or a
  `push` on `main`, with `live.yml` and `windows-conformance.yml` as the two
  named exemptions) and B4 (`bash-suite-stability.yml` is `schedule` +
  `workflow_dispatch` only). **Green on first run against the current
  tree — no workflow change was needed**, exactly as the task anticipated.
  The two detection patterns (unscoped-`pull_request`, push-on-`main`) were
  each verified against a synthetic violation file to confirm they are not
  vacuously true.
- **T009a/T009b** — `tests/bash/ci/test_no_machine_wide_state.bats` added,
  scanning `tests/` for `pgrep -f`/`pidof`, `lsof -i`, and hard-coded shared
  `/tmp` paths (the last scoped to harness/mock runtime code — `tests/conformance/**/*.sh`,
  `tests/coverage/**/*.sh`, `tests/run-bash.sh` — never `*.bats`/`*.Tests.ps1`
  fixture data, which can legitimately contain an arbitrary string that
  happens to look like a path). **Two allowlisted occurrences**, both prose
  comments naming the anti-pattern to explain why the code does NOT use it:
  - `tests/bash/conformance/test_run_scenario.bats:109`
  - `tests/conformance/run-scenario.sh:115`

  Both comments point at the identifier the code actually uses instead:
  `MOCK_PID=$!` in `tests/conformance/mock-jira/lib.sh:123`, verified by its
  own assertion in the guard test. The `/tmp` detector was verified against a
  synthetic `/tmp/spec-kit-jira.lock` literal to confirm it is not vacuously
  true. This guard is the FR-008 precondition every later concurrency raise
  (T021, T027, T031) must pass before landing.

## Dependency gap resolved: `SPEC_KIT_JIRA_CONFORMANCE_JOBS` override (pulled forward from T018/T021)

T010's W2 measurement ("does the corpus survive at concurrency 3 and 4")
needs a way to ASK the probe run for a specific degree. That mechanism —
`SPEC_KIT_JIRA_CONFORMANCE_JOBS` overriding `core_count()` — was not due to
land until T021 (Phase 3), which is gated behind Phase 2 finishing. Rather
than block T010 on a phase ordering the original task graph did not
reconcile, the override half alone was pulled forward, test-first:

- `tests/bash/ci/test_conformance_concurrency.bats` (new) asserts only the
  override property — `SPEC_KIT_JIRA_CONFORMANCE_JOBS=1` forces serial
  execution (peak overlap 1) and a higher value raises it above the host
  default — verified by an overlap count derived from each worker's own
  recorded `[start,end]` interval (`sort`+`awk`, no dependency beyond this
  project's existing bats+jq baseline).
- **Deliberately not yet asserted here**: R4's other clause, "on MSYS the
  default may exceed 2 only with a recorded probe run at that degree" — that
  needs T026's evidence, which does not exist yet. **T018, when Phase 3
  starts, extends this same file with that assertion; T021's remaining job
  is raising the actual MSYS default once T026/T028 prove a degree, not
  re-adding the override itself.**
- `core_count()` in `tests/conformance/ci-conformance.sh` now checks
  `SPEC_KIT_JIRA_CONFORMANCE_JOBS` first, on every host, before falling
  through to the existing MINGW/MSYS/CYGWIN branch. Unset (the `ci.yml`
  case) is behaviourally identical to before this change.
- Full local corpus re-run after landing: `verdicts: 84/84`, exit 0,
  `amortised per-scenario cost: 10.888s (wall-clock 68.580s / 84 scenarios)`
  — again a local macOS figure, not a CI one.

## T010 — W1–W4 measurement lines added to `windows-conformance.yml`

Restructured the probe from "one step emits one notice" to "every shard-0
step appends to one accumulator file (`${RUNNER_TEMP}/probe-notice.txt`),
and the last step emits it as the single `::notice::`" — required because
W3 depends on facts the real corpus step produces, which runs after the
host-profile step that used to emit the notice directly.

- **W1** (process-spawn cost, Defender exclusions off/on): 20 iterations
  each of `jq -n 1`, `bash -c true`, `pwsh -NoProfile -Command exit`,
  timed before and after an `Add-MpPreference` pass (workspace, `RUNNER_TEMP`,
  git-bash's dir, jq's dir) run from a generated `.ps1` file. Wrapped in
  try/catch per path so a failed exclusion is reported, not fatal.
- **W4** (MSYS-built jq): looks for MSYS2's own `pacman` (documented as
  present separately from git-bash's bundled MINGW64 env on GH's Windows
  image) and, if found, installs `jq` and checks whether IT emits LF; if so,
  runs a 10-way corpus subset (`SPEC_KIT_JIRA_SHARD_TOTAL=10`, ~8-9
  scenarios) with it first on `PATH`, reporting cost and verdict count. If
  no MSYS2 `pacman` exists on the runner, reports that plainly — itself a
  fact bearing on T015's option (a).
- **W3** (per-port/per-scenario split): parsed from shard 0's own real
  corpus run (the `timing:` lines T007 added), teed to a log file; no extra
  corpus run needed for this one.
- **W2** (concurrency 3/4 survival): two more 10-way-subset runs, at
  `SPEC_KIT_JIRA_CONFORMANCE_JOBS=3` and `=4`, reporting exit status,
  wall-clock, and the `verdicts: N/M` line (T005's mechanism) for each. A
  genuine runner loss shows up as the whole job failing/timing out with no
  notice at all — a distinct, stronger signal than anything a graceful
  in-script line could report; `continue-on-error: true` on W1/W4/W2 is
  there so a bug in this new code cannot block the real corpus step, not to
  paper over a real runner loss.

**Verified before pushing anywhere** (Constitution VI's measure-on-the-real-
host rule applies to the DESIGN QUESTIONS W1-W4 answer, not to whether this
harness code parses and runs at all):
- `actionlint` clean on the whole `.github/workflows/` tree, `shellcheck`
  clean on every extracted script block (two `SC2016` false positives on
  intentional single-quoted PowerShell variables, disabled with a comment
  matching the file's existing precedent).
- Every `run: bash` block extracted from the YAML and checked with `bash -n`.
- Every block also **executed** locally (macOS, with `cygpath` stubbed as a
  passthrough — the one command genuinely unavailable off Windows) end to
  end: the accumulator file's `%0A`-boundary discipline holds across all
  seven steps with no run-together lines, `Add-MpPreference`'s absence on
  this host is caught and reported rather than crashing the step, the
  "no MSYS2 pacman" branch reports correctly, W3's aggregation over a real
  84-line `timing:` log produced `n=84 bash_total=690.4s ... pwsh_total=247.4s`,
  and W2's two 9-scenario subset runs both reported `verdicts: 9/9`.
- What remains **genuinely unverifiable off Windows** and is exactly what
  T011's probe push answers: whether `Add-MpPreference` succeeds under this
  runner's actual privilege level, whether MSYS2 `pacman` exists on the
  image at all, and every one of W1-W4's real numbers.

## T011 — first probe push (run `31023793448`, commit `de255a3`, 2026-08-05)

Pushed to `ci/windows-probe`. Result: **a real bug found, not a flake** —
`docs/10-windows-portability.md` quirk 8 (a bare `\r` from `pwsh`'s CRLF
output truncates a `::notice::` message). Fixed and a second push queued
immediately after (not counted against the one-retry budget: that rule
covers re-rolling an inconclusive MEASUREMENT, not fixing a bug in the
harness that prevented any measurement from completing).

**What this run DID establish, cleanly**:

- **Verdict set unchanged (FR-019, SC-010)**: shard 0 failed exactly
  `us2-field-defaults-option-question`; shard 2 failed exactly
  `us2-field-defaults-question`; shards 1 and 3 passed cleanly. This is
  T003's recorded pre-existing baseline, byte for byte — this feature's
  changes (verdict counting, timing capture, the concurrency override,
  the restructured probe) introduced **zero new Windows failures**.
- **Host profile** (shard 0, this run): MINGW64_NT-10.0-26100,
  bash 5.3.15(1), **jq 1.8.1 (emits CRLF: yes)**, GNU sed 4.9, curl
  8.21.0 (mingw32), pwsh 7.6.4, **4 cores**, `core.autocrlf: true`
  (harmless per quirk 6 — the checkout stays clean), no CR bytes in either
  fixture. `jq`'s install path on this run: `C:\ProgramData\Chocolatey\bin`.
- **W1 (partial)**: the FIRST `Add-MpPreference` call (workspace-independent
  path) reported `excluded: C:\ProgramData\Chocolatey\bin` — so
  `Add-MpPreference` **does** run without an elevation prompt on this
  runner. The remaining three exclusion attempts and all six spawn-cost
  numbers were lost to quirk 8, not measured yet.
- **W4/W3/W2**: none ran on shard 0 this trip. W4 ran but its result was lost
  to quirk 8 too (it landed between W1's truncated line and where W3/W2
  would have appended). **A second, distinct bug**: W3 and W2 were declared
  `if: matrix.shard == 0` only, no `always()` — and shard 0's own slice
  reliably contains one of the two pre-existing failures, so the corpus step
  fails on shard 0 **every single run** of this probe, which skipped both
  steps entirely regardless of quirk 8. Fixed alongside quirk 8 (`if:
  always() && matrix.shard == 0`), same commit. **Re-queued for the next
  push.**

## T011 — second probe push (run `31028591939`, commit `07e2965`, 2026-08-05)

Both fixes held. **Verdict set unchanged again**: shard 0 failed exactly
`us2-field-defaults-option-question`, shard 2 exactly
`us2-field-defaults-question`, shards 1/3 clean — same as the first push and
as T003's baseline. Job durations: shard 1 = 21m54s, shard 2 = 22m36s,
shard 3 = 21m28s (all close to the ~22-23 min baseline for a 21-scenario
quarter of the corpus); **shard 0 = 60m08s**, almost entirely W4's cost
(below).

### W1 — process-spawn cost, Defender exclusions off/on (measured, real numbers)

`Add-MpPreference` succeeded on all four paths without an elevation prompt:
workspace, `RUNNER_TEMP`, git-bash's `usr/bin`, and Chocolatey's `jq` dir.

| Spawn | Off | On | Improvement |
| --- | --- | --- | --- |
| `jq.exe` | 48.74 ms | 47.47 ms | ~2.6% |
| git-bash fork | 25.31 ms | 25.08 ms | ~0.9% |
| `pwsh` start | 219.83 ms | 217.51 ms | ~1.1% |

**This overturns research.md §3's lever B estimate.** Research costed
Defender exclusions at 1.3–2.0×, "the standard MSYS-on-Actions tax." Measured
on this runner, the effect is **≤ 3% on every spawn type** — Defender
exclusions are not the lever research.md expected them to be. Whatever this
GitHub-hosted `windows-latest` image already does (a lighter default
scan policy, or these three operations already sitting outside its
on-access scan path) means lever B contributes negligibly to SC-001.

### W2 — corpus survival and verdict count at concurrency 3 and 4 (measured)

10-way subset (9 scenarios), both degrees driven by
`SPEC_KIT_JIRA_CONFORMANCE_JOBS` (T010's pulled-forward override):

| Degree | Result | Wall-clock | Verdicts |
| --- | --- | --- | --- |
| 3 | survived (exit 0) | 233.6s | 9/9 |
| 4 | survived (exit 0) | 235.1s | 9/9 |

**The runner survives at both degrees, with a complete verdict set at
each** — R4/P2's proof obligation, satisfied. Wall-clock is essentially flat
between 3 and 4 on this 9-scenario subset (233.6s vs 235.1s), which on this
sample size does not by itself argue for 4 over 3; a larger subset or the
full corpus at the chosen degree is what T026/T028 need before raising the
default (FR-007 still requires the determinism check first — this run is
survival evidence, not the determinism proof).

### W3 — per-port, per-scenario time split (measured, shard 0's real 21-scenario run)

`n=21 bash_total=1614.4s bash_avg=76.87s pwsh_total=93.5s pwsh_avg=4.45s`

**Confirms research §2.1's spawn model directly**: the bash leg costs
**~17× the pwsh leg per scenario** on this real host (76.87s vs 4.45s),
consistent with "93% of spawns are the Bash port's own `jq` calls, frozen by
FR-020." The PowerShell leg is not the problem; it never was.

### W4 — MSYS-built jq: not established

`pacman`/MSYS2 detection-and-install-and-compare step ran for **37m09s**
(17:08:46–17:45:55) and produced **zero output** in the notice — not even
its first line, which carries no external command substitution and should
have been immune to quirk 8. The cause is not established: raw job logs
answer 403 (non-admin token), and the step's own `continue-on-error: true`
plus lack of any intermediate breadcrumb means there is no artifact to
diagnose further from here.

**Decision: not pursuing a third probe push to chase this.** Budget
discipline (contracts/windows-probe.md: ~11 min and four runners per round
trip; this project's own convention is one retry maximum on an inconclusive
run) applies to the spirit of "stop iterating blindly," not only to its
literal letter — two pushes have already landed real answers for W1/W2/W3,
and W4's specific sub-experiment (installing a second jq and re-running a
corpus slice under it) is the most complex, most novel, and least essential
of the four. **W4 is reported as unmeasured, not guessed at.** If it is
needed later, the right next step is a narrower, single-purpose probe (just
the pacman/jq LF-check, no corpus re-run) with a breadcrumb written before
every step of it — not a repeat of this attempt.

**Update, same day**: after the user chose option (a) for T015 (below), W4
was rewritten exactly that way — detection only, a breadcrumb written before
every sub-step, no corpus re-run — and queued for a third push, since
option (a)'s implementation in `ci.yml` needs W4's answer (does an
LF-emitting `jq` actually exist on this runner) confirmed before it can be
trusted on a blocking, production workflow.

## T011 — third probe push (run `31036041946`, commit `1fb524c`, 2026-08-05)

**W4, finally answered.** MSYS2's `pacman` exists at
`/c/msys64/usr/bin/pacman.exe`; `pacman -Sy jq` (exit 0) installs
`/c/msys64/usr/bin/jq.exe`, and that binary **emits LF, not CRLF** — the
narrowed, breadcrumbed step completed in seconds this time (no 37-minute
mystery), confirming the earlier version's cost lived entirely in the
corpus-re-run half that was cut, not in detection itself. **Option (a) is
technically feasible on this runner image.**

Shard 3 failed this run with "the hosted runner lost communication with
server" — an infrastructure flake, not a regression: shard 3 runs no W1-W4
code (shard-0-only) and its corpus step is byte-identical to the prior two
runs where it passed cleanly. Not retried — this project's own convention
(one retry maximum on an inconclusive run) and Constitution VI both treat an
isolated infra flake as noise, not a finding. Shards 0 and 2 again failed
on exactly `us2-field-defaults-option-question` and `us2-field-defaults-question`
respectively — the third consecutive confirmation of an unchanged verdict
set across all three probe pushes.

**W1/W3 cross-validated against the second push** (same order of magnitude,
confirming the earlier numbers were not noise):

| Measurement | Push 2 | Push 3 |
| --- | --- | --- |
| `jq.exe` spawn, excl off/on | 48.74 / 47.47 ms | 56.64 / 53.40 ms |
| git-bash fork, excl off/on | 25.31 / 25.08 ms | 27.54 / 28.11 ms |
| `pwsh` start, excl off/on | 219.83 / 217.51 ms | 255.55 / 269.36 ms |
| bash leg avg (per scenario) | 76.87s | 94.30s |
| pwsh leg avg (per scenario) | 4.45s | 6.12s |

Defender's effect stays within measurement noise on both runs (once even
reversing, i.e. "on" slower than "off") — the ~1.9× lever this feature
still needs is the CRLF-guard doubling, not Defender exclusions. The
bash-leg-dominates-cost finding (≈15-17× the pwsh leg) held on both runs.

**All four questions are now answered.** Proceeding to T025.

## T025 — option (a) applied to `ci.yml` (2026-08-05)

A new step, `Prefer an LF-emitting jq for the corpus (Windows only, T015
option (a))`, added to the `unit` job's Windows leg immediately before the
conformance-corpus step. Guarded at every point (no `pacman` found, install
fails, no binary found after a claimed-successful install, binary still
emits CRLF) — each falls back to the native `jq` via `exit 0` with nothing
written to `GITHUB_PATH`, matching D3's "degrade to slower-but-correct,
never fail the job" pattern. Only the success path appends the MSYS2 `jq`'s
directory to `GITHUB_PATH`, ahead of the native one, for the remainder of
the job.

**A real bug caught by local testing before this ever reached a real
runner**: the first draft wrapped the `pacman` sync in `timeout 120 ...`.
`timeout` is a GNU coreutils command with no confirmed presence on either
this macOS dev host (confirmed absent) or `windows-latest`'s git-bash
(unconfirmed either way) — had it been silently assumed, its absence alone
would have made `pacman -Sy` report as "failed" via `command not found`
(exit 127) on **every run**, defeating T025 entirely while looking like a
successful, guarded fallback. Fixed: `timeout` is used only when
`command -v timeout` finds it, never assumed.

**Every branch verified locally** (macOS, `pacman`/`jq.exe` stubbed — the
hardcoded `/c/msys64/...` paths themselves cannot be exercised off Windows,
same category as `cygpath`):
- no `pacman` on PATH → fallback, `GITHUB_PATH` untouched
- `pacman` exits non-zero → fallback, `GITHUB_PATH` untouched
- alt `jq` found but still emits CRLF → fallback, `GITHUB_PATH` untouched
- alt `jq` found and emits LF → `GITHUB_PATH` gains its directory

Full local bash suite re-run after landing: see T025 entry below for the
count. `actionlint` clean on both `ci.yml` and `windows-conformance.yml`.

**Deviation from the literal task wording, by the user's own condition**:
T025 says "install the LF-emitting `jq` in `ci.yml` **and the probe**."
Applied to `ci.yml` only — `windows-conformance.yml` deliberately keeps the
runner's native `jq` so the `output.sh` CRLF guard's active branch stays
exercised on demand (T015's record, above). This is not an oversight; it
is the condition the user attached when choosing option (a).

**Not yet pushed to the probe or measured on the real runner**: this step
has been verified by local stub only. Whether it actually shortens the real
`windows-latest` corpus step by anything close to the ~1.9× research.md
estimated is unmeasured until a real `unit` job run (on `ci.yml`, not the
probe) exercises it — that requires either a push to a PR/branch that
triggers `ci.yml`, or `windows-conformance.yml` temporarily pointed at this
same guarded step for one measurement run. Recorded here as the next open
question, not silently assumed.

## T019/T020/T022/T023 — test-owned spawn reduction (D4, 2026-08-05)

Both landed test-first, both verified against the real 84-scenario corpus
(`verdicts: 84/84`, exit 0) after implementation.

**Curl shim** (`tests/conformance/mock-jira/curl-shim.sh`, T019/T022):
`style`/`meta_style`/`status_style` were computed unconditionally for every
request, even though only 4 of ~15 route branches read them. Made lazy —
computed only inside the branches that use them. Verified with a counting
`jq` wrapper: a route needing neither (e.g. `/priority`) now costs ≤ 1 jq
call (was 3); a project-style route costs ≤ 2 (was 3); an issue GET costs
≤ 3 (was 5).

**Harness** (`tests/conformance/run-scenario.sh`, T020/T023): two changes.
`jq_lines` piped every call through `sed` unconditionally; now conditional
on the SAME CRLF-detection `output.sh`'s own wrapper uses — zero `sed`
calls on any LF-emitting host (verified: 0 on this macOS host). The
post-run workdir snapshot spawned one `mkdir` + one `cp` PER FILE; replaced
with a single `cp -R` of the whole tree followed by `rm -rf .git` — the
`cp -R` on `.` copies contents including hidden dirs (matching the old
`find`'s traversal), and pruning `.git` after is equivalent to the old
loop's `-prune` on it. Verified: the harness's total `cp` count is
identical whether the fixture has 3 files or 12 (proving no per-file
scaling), and file contents/paths land correctly either way.

**A real behavioural question raised and resolved by testing, not assumed**:
`cp -R` copies empty directories; the old per-file `find -type f` loop
never created one (only directories containing a file got an `mkdir -p`).
This is a genuine difference between the two mechanisms — checked against
the real corpus rather than reasoned about, since Constitution VI's
measure-don't-assume rule applies here too, even though this is a POSIX-
only question. Result: **84/84 verdicts unchanged**, so no scenario's
fixture or port-written tree currently depends on that distinction; flagged
here in case a future scenario ever does.

Full local bash suite after all four: 154 files, 1451 tests, 0 failures.

## T030/T031 — `run-bash.sh` oversubscription and LPT ordering (D5, FR-009, 2026-08-05)

`SPEC_KIT_JIRA_BATS_JOBS` overrides the worker count on any host (default:
core count × 3, since these workers are process-creation/IO-bound per
research §4.1, not CPU-bound). `SPEC_KIT_JIRA_BATS_TIMINGS` points at a
profile file (`<seconds>\t<path>` per line, default
`tests/bash-suite-timings.txt`); when present, `FILES` is sorted
longest-first before dispatch. A path is matched exactly first, then
relative-to-`ROOT` — so a profile committed with repo-relative paths (what
T032 will produce) and a test using absolute paths (this feature's own
fixture-based tests) both resolve correctly. Unprofiled files (added since
the profile was last refreshed) sort last, not excluded.

**T032 not yet done**: no real profile file has been committed (it needs a
CI run's per-file timing data — research §4.2's own local-timing caveat
applies to building it, not just to citing it). Every real invocation of
`run-bash.sh` today therefore takes the "no timing profile" branch and runs
in discovered (alphabetical) order — the oversubscription (T031's other
half) is active regardless, since it does not depend on the profile.

Full local run via `tests/run-bash.sh` itself (dogfooding the change):
`ordering: no timing profile ... — discovered order`, `jobs: 48` (this
16-core host × 3), `files executed: 154, tests executed: 1455, files
failed: 0`, `PASSED`.

## T032/T033 — profile capture mechanism built, not yet populated (2026-08-05)

`tests/run-bash.sh` now times each worker (`EPOCHREALTIME` around the
`bats` call, written to `<log>.dur`) and, when
`SPEC_KIT_JIRA_BATS_DUMP_TIMINGS=<path>` is set, aggregates every executed
file's duration into `<seconds>\t<path-relative-to-ROOT>` lines at that
path — the exact format T031's reader expects. Verified: a small fixture
run writes exactly one well-formed line per executed file.

**Deliberately not used to produce the real profile from this host.**
Research §4.2 measured this dev host at load average 167 when the original
per-file timing was attempted, and this project's standing rule is that a
budget-relevant number comes from a CI run, never a local wall clock — the
same rule applies to PRODUCING the profile, not only to citing it. Running
`SPEC_KIT_JIRA_BATS_DUMP_TIMINGS=tests/bash-suite-timings.txt tests/run-bash.sh`
locally right now and committing the result would satisfy T032's letter
while violating the reason it exists.

**T033 not started — flagged rather than made silently**: refreshing this
profile from `bash-suite-stability.yml`'s nightly means that scheduled job
committing a file back to the repo, which needs `contents: write`.
`bash-suite-stability.yml` currently declares `permissions: contents: read`
— a deliberate minimum this feature should not widen without saying so.
Raised to the user rather than changed silently, same posture as T015.

## PR #26 (`018-optimize-ci-wall-clock` → `main`) — first two real CI runs

Merged `main` in first (one real conflict: `.specify/feature.json`, a
trivial active-feature pointer, resolved by keeping this feature's value;
`tests/conformance/mock-jira/curl-shim.sh` and `mock-server.ps1` both
changed on both sides — feature 017 added `_shim_label_search` — but
merged cleanly, verified: `bash -n`, the full local suite, and the real
corpus at 90/90 verdicts (84 + 6 scenarios 017 added) all green before
pushing).

**Run 1 (`31050522526`, commit `627b949`) — three failures, none of them
what they first looked like:**

- **`Static checks` / `Unit suites (ubuntu-latest)`** — a real bug in
  MY OWN test. `test_conformance_worker_accounting.bats`'s R5/R6 test
  asserted an exact "verdicts: 2/3" after killing one worker. Reproduced in
  an `ubuntu:24.04` Docker container (started Docker Desktop locally for
  this — raw job logs answer 403, non-admin token, so a real Linux host was
  the only way to see the actual failure): **GNU `xargs` (Linux) aborts the
  whole `-P` batch when a child dies by signal (0/3 survive); BSD `xargs`
  (macOS) lets already-dispatched siblings finish (2/3 survive).** Both
  satisfy R5/R6 — a shortfall is reported either way, which is the actual
  guarantee — so the fix relaxed the assertion to the portable invariant
  (fewer verdicts than the corpus), not a specific fraction. Verified green
  in the container AND locally after the fix; **confirmed green for real**
  on the second CI run (below).
- **`Unit suites (windows-latest)`** — NOT this feature's bug. Failure:
  `[-] refuses plan.md before any request, exit 1, plan.md untouched (§5
  T1, T2)`, a Pester test from feature 017's target-guard work. Confirmed
  by checking `main`'s own most recent CI run (`31006298347`, before this
  PR): **identical failure, identical message.** Pre-existing on `main`,
  inherited by the merge, not caused by this branch. Not fixed here — out
  of scope, and not this feature's code.

**Run 2 (`31055241513`/`31055241515`/`31055241528`, commit `0e1630b`) —
after the worker-accounting fix:**

| Check | Result |
| --- | --- |
| Lint, Static checks, Boundary, module-parity, version-string, Detect Bash-relevant changes, PowerShell coverage | **pass** |
| Unit suites (ubuntu-latest) | **pass** (47m35s) |
| Unit suites (macos-latest) | **pass** (55m14s) |
| Unit suites (windows-latest) | **fail** — same pre-existing 017 bug, confirmed unrelated |
| Bash coverage (kcov) | **fail** — the pre-existing, documented-since-2026-07-28 red gate (Phase 5 of this feature, not yet started) |

**Both failures here are already-documented, pre-existing states this PR
did not create.** No new regression from this feature's changes across
either run.

### An open question this run surfaced: macOS may have gotten SLOWER

Two consecutive real measurements, both above the pre-change baseline:

| Host | Pre-change baseline (run `30947466217`) | Run 1 (`627b949`) | Run 2 (`0e1630b`) |
| --- | --- | --- | --- |
| ubuntu-latest | 48m33s | ~47m24s (failed) | **47m35s** — essentially unchanged |
| macos-latest | 42m25s | ~50m57s | **55m14s** — up ~25-30% |

ubuntu-latest tracks its baseline closely. macos-latest is **consistently
higher** across both runs, not a one-off — this looks like a real effect,
not noise, though two data points from one PR is thin evidence for a
mechanism.

**Not yet diagnosed. Leading hypothesis, not confirmed**: T031's
oversubscription (3x core count, uniform across every host) may backfire
specifically on `macos-latest`, whose GH-hosted runners are historically
the most resource-constrained of the three (fewest vCPUs) — 3x on an
already-tight core budget could turn process-creation overhead into
context-switch thrashing rather than better utilisation, unlike Windows/
Linux where the same multiplier helped. The suite also grew (149→159
files, 1427→1521 tests) from merging feature 017, which alone would add
some time on every host but should not explain a Linux/macOS split this
large.

**Not acted on without more evidence.** Raised to the user rather than
tuned blindly — the fix, if the hypothesis holds, is most likely an
OS-specific oversubscription multiplier (e.g. lower on macOS) rather than
a uniform one, but that needs at least one more data point (a run with
`SPEC_KIT_JIRA_BATS_JOBS` pinned to the OLD default on macOS, for a clean
A/B) before being justified as a real fix rather than a guess.

### T015 — the escalated decision (answered by the user, 2026-08-05)

Put to the user with W1's measured number attached (W4's, per above, was not
yet available at the time of asking). **Decision: option (a)** — install an
LF-emitting `jq` on the Windows runner — **with one condition attached that
the user approved**: apply it only to the blocking `ci.yml` leg, and
deliberately leave `windows-conformance.yml` (the probe) on the runner's
native, CRLF-emitting `jq`. Rationale for the condition, raised before the
decision was asked and accepted as part of it: option (a) applied
everywhere would mean the corpus never again exercises the `output.sh` CRLF
guard's active branch on Windows — the exact code path that found quirks 1
and 7. Keeping the probe on native `jq` preserves that coverage on demand
(a manual `ci/windows-probe` push, or a future nightly run) without paying
its cost on every blocking PR. No FR-020 exception is needed for this
decision — (a) touches no production code — but it IS recorded here as the
deliberate, named divergence FR-022/T016 requires between what the blocking
CI exercises and what a stock Windows git-bash user's `jq` actually does.

### Consequence for T015

The Complexity Tracking decision can be put to the user with W1's number
attached (as the task requires) but **not** W4's: option (a) (an LF-emitting
`jq` on the Windows runner) remains costed only by research.md's estimate,
not by a measurement of whether MSYS2's `jq` is even reachable on this image
or what it would cost. What IS now measured and materially changes the
decision's inputs: **lever B (Defender exclusions) is worth ~1-3%, not the
1.3-2.0× research.md assumed** — the "realistic case" arithmetic in
plan.md's Complexity Tracking table should be re-run with B's real multiplier
before the decision is presented, since it materially lowers the frozen-code
ceiling and therefore strengthens the case for options (a)/(b)/(c) over
"levers alone get there."

---
