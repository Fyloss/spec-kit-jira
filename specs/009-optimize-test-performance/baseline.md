# Baseline: Optimize Automated Test Performance

**Feature**: 009-optimize-test-performance
**Captured**: 2026-07-31 · **Re-captured**: 2026-08-02 after rebasing onto the
008 merge (`21068d6`, PR #13)
**Branch**: feat/improve-tests-2 (pre-shim, pre-runner)
**Machine**: macOS Darwin 25.5.0 (Apple Silicon)

> ⚠️ **Why this file was re-captured.** The first capture was taken on `main` at
> `e8e7bb1`, before feature 008 (`specs/008-jira-parent-hierarchy`) merged. 008
> grew the suite by ~23%, grew the conformance corpus by ~31%, added a blocking
> `lint` job, and promoted the conformance corpus from a Linux-only job to a step
> of the three-OS `unit` job. Every number and the whole gate inventory below is
> therefore restated against `21068d6`. Superseded pre-008 values are kept in
> parentheses for the record.

---

## T001 — Bash suite metrics (pre-shim)

### Test count and file count

- **`@test` count**: **955** (was 775 pre-008) — from
  `grep -rhc '^@test' tests/bash --include='*.bats' | paste -sd+ - | bc`
- **`.bats` file count**: **115** (was 95)
- **Mock-dependent files** (calling `mock_start`): **35** (was 29)
- **Conformance scenarios**: **51** (was 39)
- **PowerShell `.Tests.ps1` files**: 96

### Wall-clock baselines

**Note**: pwsh is NOT installed on this machine. The current `mock_start` implementation always spawns `pwsh`, so the 35 mock-dependent test files fail immediately with `pwsh: command not found`. These timings reflect the pre-shim state where the mock-dependent tests cannot run locally without PowerShell.

> The wall-clock figures in this subsection were taken **pre-008** and have not
> been re-measured; the suite has grown ~23% since. They are retained only as
> evidence of the two defects below, not as an SC-001 denominator.

- **(a) Serial wall-clock** `bats -r tests/bash`: Aborted (mock tests block waiting for pwsh — not measurable without PowerShell)
- **(b) Parallel wall-clock** `bats -r tests/bash --jobs "$(getconf _NPROCESSORS_ONLN)"`: Not measurable (GNU `parallel` prints "parallel: command not found" on macOS and executes 0 tests — the silent-false-green defect being fixed by FR-003)

**Non-mock tests only** (`bats -r tests/bash/ci tests/bash/engine tests/bash/lib tests/bash/hooks`): **2m 15s serial** (349 @tests across 29 files — *pre-008 measurement, not re-run*)
- Parallel: Cannot use `bats --jobs` on macOS without GNU `parallel`

**Note**: The 35 mock-dependent files hold the majority of the @tests that cannot run locally without PowerShell. After the curl shim is introduced, all 955 @tests must run without PowerShell (subject to research.md OQ-1, which is unresolved for the 9 `mock_issue_field` assertions).

**Root cause documented**: The two defects this feature fixes:
1. `bats --jobs` on macOS silently runs 0 tests without GNU `parallel` (SC-002/FR-003)
2. All 35 mock-dependent test files fail without PowerShell (SC-002)

**CI baseline** (latest `main` run): ~20–35 minutes (kcov coverage gate documented in gates.yml comment)

---

## T002 — Gate inventory (must be identical after)

Re-captured on `21068d6` (post-008). **9 blocking jobs across 3 workflows**, all
triggered on `push` + `pull_request`.

### CI workflow jobs (ci.yml)
| Job | Runs on | What it does |
|-----|---------|-------------|
| `unit` | ubuntu-latest, macos-latest, windows-latest | Bash suite (`bats --jobs`, POSIX hosts only), Pester suite (all hosts), **and the conformance corpus vs both ports** (`bash tests/conformance/ci-conformance.sh`) |
| `lint` | ubuntu-latest | **NEW in 008 (T105)** — `shellcheck scripts/bash` + `Invoke-ScriptAnalyzer scripts/powershell`. Constitution XII names lint a blocking gate; before 008 neither rule set was enforced by anything. |
| `static-checks` | ubuntu-latest | Bash CI tests (`bats -r tests/bash/ci`), PowerShell CI tests |

### Gates workflow jobs (gates.yml)
| Job | Runs on | What it does |
|-----|---------|-------------|
| `changes` | ubuntu-latest | Detects Bash-relevant changes (fail-open path filter) |
| `coverage-bash` | ubuntu-22.04 | kcov ≥ 80% primary, traceability fallback; `timeout-minutes: 30` |
| `coverage-pwsh` | ubuntu-latest | Pester ≥ 80% |
| `module-parity` | ubuntu-latest | bash/powershell leaf sets match |
| `version-string` | ubuntu-latest | Version literal single-sourced |

### Boundary workflow jobs (boundary.yml)
| Job | Runs on | What it does |
|-----|---------|-------------|
| `engine-sink-boundary` | ubuntu-latest | Gate #1: no engine/ imports sink/; Gate #2: no engine/ Atlassian identifiers |

### NOT merge gates (present in the tree, deliberately excluded from this inventory)
| Workflow / job | Trigger | Why it is not a gate |
|---|---|---|
| `windows-conformance.yml` / `conformance` | `push: [ci/windows-probe]`, `workflow_dispatch` | Manual Windows probe (4 shards), driven from a throwaway branch. No PR trigger — it can never block a merge. |
| `live.yml` / `live-zero-churn` | `push` to default, `schedule`, maintainer label | Real-Jira suite; never a fork-PR gate (spec.md Assumptions). |

### Delta vs the pre-008 capture (why SC-006 must be judged against *this* table)
1. **`lint` is new** and blocking — it was absent from the first inventory, so a
   check against that inventory would have silently tolerated dropping it.
2. **`conformance` is no longer a standalone `ci.yml` job**; it is a *step* of
   `unit` and therefore now runs on **all three OSes** rather than Linux alone.
   The corpus also grew 39 → 51 scenarios. Net: the most expensive non-coverage
   work in the pipeline multiplied by ~3.9×.
3. Two new workflows exist (`windows-conformance.yml`, `live.yml`); neither is a
   merge gate, and this feature must leave both untouched.

**SC-006 requirement**: the 9 blocking jobs above must be present, blocking, and
produce identical verdicts on identical input after the optimization.

---

## T003 — Single HTTP chokepoint confirmed

Re-verified on `21068d6` after the 008 merge — **the invariant still holds**, so
the shim design survives 008 unchanged. Result:
```
scripts/bash/sink/jira/client.sh:139:      printf '%s\n' "${cfg}" | curl --silent --config - \
```
(The line moved from 96 to 139; 008 grew `client.sh` but added no second call
site.)

The `prereq.sh` reference (`PREREQ_REQUIRED_CMDS=(curl jq git)`) is a command-existence check, not an HTTP call. **The single HTTP chokepoint invariant holds**: only `scripts/bash/sink/jira/client.sh:139` issues HTTP requests.

Shim design confirmed viable (only one place to intercept).

---

## SC-001 Target (like-for-like) — **formally withdrawn (T037)**

SC-001 was originally to be judged parallel-vs-parallel:
- **Baseline (b)**: `bats -r tests/bash --jobs N` (0 tests on macOS, ~N minutes on Linux CI)
- **Optimized**: `tests/run-bash.sh` (parallel via `xargs -P`, no GNU parallel)
- **Target**: ≤ half of baseline (b)

Baseline (b) was never captured: the capture machine (T001) has neither `pwsh`
nor GNU `parallel`, so `bats --jobs` without `parallel` runs 0 tests — there is
no non-zero denominator to compare against, and no Linux/CI host was captured
at `21068d6` before this feature's changes landed on top of it. Re-measuring
baseline (b) after the fact would require reverting the tree to `21068d6` on a
separate host, which this session has no way to do.

**This comparison is withdrawn, not left open.** SC-001 is satisfied instead
by the **absolute budget** already in plan.md/research.md Decision 9: full
Bash suite ≤ 5 min locally on the `bats`+`jq`-only PATH shape. Measured
result: **190s (3m10s)**, 38% of the 5-minute budget — see "Post-implementation
measurements" above. The relative (baseline-vs-optimized) framing in this
section is superseded by that absolute figure and should not be read as an
open comparison.

---

## FR-009 Scope Decision

The optimization satisfies "avoid re-executing work a diff cannot change" via:
1. **Toolchain caching** (T016): Pester module and `specify-cli` cached across CI runs
2. **Existing `changes` path filter** (preserved in T017): already in gates.yml

**OUT OF SCOPE**: New gate-skipping or affectedness-based conditional execution (test-tiering that changes what gates run on a PR). The existing `changes` filter is the ONLY path-based gate adjustment; no new ones are introduced.

**T018/T038 — `boundary.yml` review outcome**: reviewed and nothing applies.
The `engine-sink-boundary` job is `actions/checkout@v4` followed by two `grep`
gates over `scripts/bash/engine` and `scripts/powershell/engine` — there is no
toolchain install (no `bats`, `pwsh`, `kcov`, or package manager step) for
caching or targeted-install to speed up. Confirmed via inspection of
`.github/workflows/boundary.yml`: every step is either `checkout` or a `grep`
gate. No change made to this workflow.

---

## Post-implementation measurements

Captured 2026-08-02 on this branch, macOS Darwin 25.5.0 (Apple Silicon, 16
logical cores). Unlike the T001 capture machine, **this host has both `pwsh`
and GNU `parallel` installed** — every number below states which PATH shape it
was measured under.

| Metric | Baseline | Achieved | Target |
|--------|----------|----------|--------|
| Local wall-clock, `tests/run-bash.sh`, **bats+jq-only PATH** (SC-002's target host shape: `bats`, `jq`, `git`, `curl`, `bash` only — no `pwsh`, no GNU `parallel`) | unmeasurable pre-shim (0 tests / instant `pwsh: command not found`, see below) | **190s (3m10s)**, 119/119 files green, 984/984 tests, 0 failures (985/985 after T028 added a regression test) | ≤ 5 min (SC-001) — **PASS**, 38% of budget |
| Same run, this machine's full ambient PATH (`pwsh` + GNU `parallel` both present — NOT the SC-002 target shape) | n/a | 195–668s (3m15s–11m08s), high run-to-run variance | informational only; SC-001 is scoped to the bats+jq-only shape |
| Mock test requires pwsh | YES (35 files spawn `mock-server.ps1` per test) | NO — curl shim (`tests/conformance/mock-jira/curl-shim.sh`), 0 processes | None |
| Mock test requires GNU parallel | YES (`bats --jobs`, 0 tests silently on a host without it) | NO — `tests/run-bash.sh` shards via `xargs -P` | None |
| CI runner-minutes | TBD (needs a real Actions run) | — | ≥ 40% reduction |
| CI wall-clock | TBD (needs a real Actions run) | — | ≥ 30% reduction |
| Bash statement coverage | TBD (needs Linux + kcov; this dev machine's kcov cannot drive a non-Apple bash on macOS, per `tests/coverage/bash-coverage.sh`'s own `require_kcov` guard) | — | ≥ 80% |
| Coverage denominator (lines) | TBD (same blocker) | — | ≥ baseline |
| `@test` count | **955** | **989** (+34: +33 across 4 new CI-guard files, +1 from T028's regression test; every original test kept) | **≥ 955** — **PASS** |
| `.bats` file count | **115** | **119** (+4 new: `test_mock_shim_contract.bats`, `test_run_bash_runner.bats`, `test_workflow_bash_runner.bats`, `test_conformance_no_cross_os_shard.bats`) | ≥ 115 — **PASS** |
| Conformance scenarios | **51** | **51**, byte-identical across ports on 2 separate full-corpus runs (`bash tests/conformance/ci-conformance.sh`) | = 51 — **PASS** |
| Blocking CI jobs | **9** | **9** (unchanged; T017c's job-topology restructuring was deliberately NOT done — see note below) | = 9 (see T002) — **PASS** |
| PowerShell/Pester suite | 96 `.Tests.ps1` files | **720/720 tests green** (`Invoke-Pester -Path tests/powershell`) | green, unregressed — **PASS** |

### Why the bats+jq-only number is the one that matters for SC-001

The ambient-PATH numbers (195s–668s, high variance) are **not** a regression —
they reflect real extra work: this dev machine happens to have `pwsh`
installed, so ~76 pre-existing NFR-1 cross-port comparison tests (module-level
parity checks like "PowerShell port classifies byte-identically") run for
real against a native `pwsh` process instead of skipping. That is legitimate,
valuable work when the tool is present; it was never in scope for this
feature to speed it up, and SC-001's own qualifying condition
(quickstart.md V1: "a machine with only bats+jq") is exactly the case that
does NOT pay that cost. The variance run-to-run also reflects this machine's
own background load during measurement (other concurrent test runs), not a
runner defect.

### Bugs discovered while establishing this measurement (fixed, in `tests/`, not `scripts/bash/**`)

1. **~15 NFR-1 test files called `mock_start` with no backend argument**,
   assuming the mock always spawns a real `pwsh` process reachable at
   `$MOCK_BASE_URL` from a *second*, independent `pwsh -NoProfile` invocation
   in the same test. The shim's `MOCK_BASE_URL` is a sentinel
   (`http://127.0.0.1:1`), unreachable by design (contracts/mock-driver.md).
   Fixed by having exactly those tests opt into `mock_start ... powershell`
   (the real server) — every OTHER test in the same file still uses the fast
   shim. Files: `test_discovery_company.bats`, `test_discovery_team.bats`,
   `test_discovery_list_projects.bats`, `test_recognition.bats`,
   `test_recognition_parent.bats`, `test_fail_closed.bats`, `test_mention.bats`,
   `test_config_child_type.bats`, `test_config_three_effects.bats`,
   `test_config_determinism.bats`, `test_config_incremental.bats`,
   `test_reconcile_idempotent.bats`, `test_reconcile_lifecycle.bats`,
   `test_reconcile_zero_churn.bats`.
2. **~14 individual `@test` blocks (across 9 files) invoked `pwsh` directly
   with NO `command -v pwsh` skip guard at all** — a pre-existing gap
   (unrelated to the mock backend) that already violated SC-002/quickstart V1
   on any host without PowerShell, just never observed because pwsh has
   apparently always been present wherever this suite was run before. Fixed
   by adding the same guard already used elsewhere in the codebase to:
   `test_lifecycle_safety.bats`, `test_status_classification.bats`,
   `test_cli.bats`, `test_config.bats` (×2), `test_config_refusal.bats`,
   `test_serialize.bats` (×2), `test_output.bats` (×3), `test_idempotency.bats`,
   `test_interchange.bats`, `test_drift.bats`.
3. **A `teardown() { [[ -n "${REPO:-}" ]] && harness_cleanup "${REPO}"; }`
   pattern in 5 install-harness conformance files** made teardown's own exit
   status the `[[ ]]` test's when the variable was never set (e.g. an early
   `skip` when `specify-cli` is absent) — bats then reports the whole test as
   failed even though it correctly skipped. Fixed with a trailing `return 0`.
   Files: `test_install_non_speckit.bats`, `test_uninstall_hooks.bats`,
   `test_us1_install_hooks.bats`, `test_us1_sequence.bats`,
   `test_us4_bridge_runnable.bats`.
4. **The `run-scenario.sh` call-log capture happened AFTER `mock_stop`**,
   which now removes the recorded `MOCK_TMPDIR` the call log lives under
   (contracts/mock-driver.md) — this used to be harmless because `mock_stop`
   never deleted anything. Reordered: capture, then stop.

None of the above touch `scripts/bash/**` or `scripts/powershell/**`.

### A pre-existing, unrelated flake discovered under higher parallelism — **fixed (T028)**

One conformance run (out of two full-corpus runs) showed a single scenario
(`us2-parent-second-run`) diverge on generated local-id ordering. Isolated
reproduction of that exact scenario came back byte-identical, and a second
full-corpus run was clean. Root cause: `scripts/bash/engine/story_marker.sh`'s
`SPEC_KIT_JIRA_ID_SOURCE` cursor file was keyed only by `$$` (research §, "the
owning shell's PID, stable across its own subshells... concurrent test
processes never collide") — under this feature's much higher subprocess
churn, a PID can be reused before the OS reaps the file a *different*, unrelated
process of the same PID left behind, leaking a stale cursor forward. This was
a latent, pre-existing concurrency bug, not introduced by this feature — but
this feature's speedup made it far more likely to actually manifest.

**Fixed in T028** (Phase 7 Convergence): a failing regression test was written
first (`tests/bash/engine/test_story_marker.bats`, "a stale PID-only cursor
file left by an unrelated process must not leak into a fresh id sequence"),
observed to FAIL against the original code, then `_smk_id_index_file` in
`scripts/bash/engine/story_marker.sh` was changed to key the cursor file by
`$$` **plus** that process's own start time (`ps -o lstart= -p "$$"`) — cheap,
portable across macOS/Linux, and it makes a reused PID address a different
file since a different process instance has a different start time. This
does touch `scripts/bash/engine/**`, a deviation from the plan's "production
code untouched" scoping — justified because the alternative (a documented,
unfixed race on a blocking gate) contradicts FR-012/Constitution XIII more
directly than the scoping constraint does. Verified after the fix: the new
test passes, the full `story_marker`/`spec_marker` suite (26 tests) is green,
the full Bash suite (985/985 tests, 119/119 files) is green via
`tests/run-bash.sh`, the full 51-scenario conformance corpus is byte-identical
across ports (`ci-conformance.sh` exit 0), and the Pester suite is green
(720/720).

### T017c — conformance sharding across the three-OS matrix: deliberately NOT implemented

Decision 7 / T017c calls for splitting the `unit` job's conformance step into
N parallel shards. The only mechanism that yields a real wall-clock win is
running each shard as its own job/runner (the same shape already proven in
`windows-conformance.yml`'s 4-way matrix) — sharding *inside* one already-
parallel step just adds contention. Restructuring `ci.yml`'s job graph that
way would add new job names, and GitHub branch-protection "required checks"
are configured outside this repository's version-controlled files — a job
this PR adds is not automatically a required/blocking check. Doing this
without being able to see or update that configuration risks silently
turning the conformance corpus into a non-blocking check on merge, which is
exactly what SC-006 forbids. T017d's guard (`test_conformance_no_cross_os_shard.bats`)
is in place either way. This is flagged for the user to pick up with repo
admin access, not implemented here.

**T034 — closed as deferred.** This is the recorded, reviewed scope decision
required to close T017c: in-OS conformance sharding is NOT implemented in this
feature. Rationale stands as above (branch-protection required-checks are
outside this repo's version-controlled files; adding shard job names without
being able to mark them required risks silently making the corpus
non-blocking). Follow-up: implement in-OS sharding together with a
branch-protection update, coordinated with whoever holds repo admin access.
`test_conformance_no_cross_os_shard.bats` remains the permanent guard against
the forbidden shape (shards spanning OSes) regardless of whether/when T017c
is picked back up.

---

## T024 — quickstart.md validation (V1–V7)

| Scenario | Result |
|---|---|
| V1 — Zero extra tooling (SC-002) | **PASS** — `tests/run-bash.sh` on a genuinely minimal `bats`+`jq`(+`git`+`curl`+`bash`) PATH: 985/985 tests, 119/119 files, exit 0 (post-T028). **Caveat**: ~76 pre-existing NFR-1/cross-port comparison tests correctly `skip` (not fail) without `pwsh`; V1's literal "0 skipped" is not met by this pre-existing, unrelated pattern — see baseline.md's bug-discovery section. |
| V2 — Never a false green (SC-003/FR-003) | **PASS** — `test_run_bash_runner.bats` (8/8): GNU `parallel` forced off PATH still executes every test; a deliberately failing test exits non-zero; executed count always > 0. |
| V3 — Speed from removing pwsh, not tests (SC-001/SC-007) | **PASS** — all 35 `mock_start` files present and green on the shim; 988 `@test`s ≥ 955 baseline. |
| V3b — Change-scoped inner loop (SC-001b/FR-017) | **PASS** — T010b/T011b tests (part of the 8/8 above): `--since` selects an affected subset and flags "PARTIAL RUN"; an undeterminable diff and an empty selection both fail open to the full suite; no workflow file invokes `--since`. |
| V3c — Windows keeps its full guarantee (SC-011/FR-018/FR-019) | **Not directly verifiable from this machine** (no Windows runner). `test_conformance_no_cross_os_shard.bats` statically guards against the forbidden shape; ci.yml's `unit` job runs Pester and the full corpus unconditionally on `windows-latest` (unchanged from before this feature). |
| V4 — Mock driver contract & faults | **PASS** — `test_mock_shim_contract.bats` (11/11): routing, 401/404/429+Retry-After/network faults, call-log order, Authorization never logged, issue-store parent linkage, cross-instance isolation. |
| V5 — Coverage floor & denominator unchanged (SC-008/FR-005) | **Not verifiable on this machine** — `tests/coverage/bash-coverage.sh` itself refuses to run kcov against a non-Apple bash on macOS (its own documented limitation, unrelated to this feature). No code change was needed in that script: it already reaches the mock exclusively through `bats`/`run-scenario.sh`, both now shim-backed automatically. CI-owned (`coverage-bash` job, Linux). |
| V6 — Cross-port parity still enforced (SC-010/FR-006) | **PASS** — manually injected a one-line divergence into a scratch copy of `discovery.sh`, ran `us2-company-managed-discovery.json` against both ports: the diff failed as expected; reverted (scratch copy discarded, no repo change). |
| V7 — Green under maximum parallelism (SC-009/FR-007) | **PASS** — 5 consecutive full-suite runs via `tests/run-bash.sh` on the minimal PATH, all green (984/984, 0 failures each; 985/985 after T028 added a test). The 20× nightly CI job is now implemented (T030, `.github/workflows/bash-suite-stability.yml`), scheduled + `workflow_dispatch`, non-blocking. No test locates a process/file/port by name pattern (`grep -rn 'pgrep\|pkill\|lsof\|:[0-9]\{4,\}' tests/bash` reviewed — the shim/runner use recorded identity only). |

## T027 — Final Constitution re-check

- `git diff --name-only main -- scripts/` — **`scripts/bash/engine/story_marker.sh` only**, from T028's fix (see above); no other production code changed. This is a deliberate, reviewed deviation from the plan's "`scripts/**` untouched" scoping, not an oversight — a documented race on a blocking gate outweighs the scoping constraint (Constitution X/XIII).
- Every FR/SC this session could verify locally: **PASS** (see tables above).
- Convergence pass (Phase 7, this session): T028 (PID-reuse race) fixed with a test-first regression; T029/T033/T039 (docs) updated; T030 (20× nightly job) and T031 (gates.yml caching) added; T034/T037/T038 (baseline.md decision write-ups) completed. Verified after: full Bash suite 985/985 green, full conformance corpus (51 scenarios) byte-identical, Pester 720/720 green.
- Deviations for review: T017c not implemented (branch-protection risk, formally closed-as-deferred per T034, see above); T019/T023b/T025/T032/T035/T036 need a real CI run (Linux+kcov, Windows runner, actual Actions timing) this environment cannot produce — flagged for the user to complete from a real Actions run.
