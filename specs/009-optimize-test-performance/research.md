# Research: Optimize Automated Test Performance (macOS / Linux)

**Feature**: 009-optimize-test-performance | **Date**: 2026-07-31

This document records the technical decisions that resolve the "how" behind the
spec. Each decision states what was chosen, why, and what was rejected. All
measurements below are from the current tree on this branch.

## Baseline measurements (the problem, quantified)

- Bash suite: **955 `@test`s across 115 `.bats` files**; **35 files call
  `mock_start`**. (Re-measured on the 008 merge commit `21068d6`; was 775 / 95 /
  29 before 008 landed.)
- Every mock-dependent test spawns a **fresh PowerShell process**
  (`pwsh -NoProfile -File mock-server.ps1`) in `mock_start` and waits up to 10s
  for a readiness file. `pwsh` cold start is ~0.5–1.0s; **no test uses
  `setup_file`**, so the cost is paid *per test*, not per file.
- `bats --jobs` requires GNU `parallel`. On a host without it (default macOS),
  `bats --jobs` prints `parallel: command not found` and **executes 0 tests
  while still exiting cleanly** — a silent false green (reproduced locally).
- Mock-dependent Bash tests **fail without PowerShell installed** (reproduced:
  `mock process exited before ready → pwsh: command not found`).
- CI reinstalls Pester, `specify-cli` (from git), and OS packages on **every job
  across three OSes**, with **no caching**. The kcov coverage gate is documented
  at **20–35 minutes** against a `timeout-minutes: 30` ceiling (gates.yml:87) —
  i.e. the gate is at or over its own budget by construction.
- 008 multiplied the conformance cost: the corpus grew **39 → 51 scenarios** and
  moved from a Linux-only `conformance` job to a step of the three-OS `unit` job,
  so it now runs **3×** per PR instead of once. This is the largest non-coverage
  CI cost driver and it landed *after* this feature's baselines were first taken.
- The Bash port makes HTTP calls through a **single chokepoint**:
  `scripts/bash/sink/jira/client.sh` → `jira_request()` → one `curl --config -`
  invocation (line 139 post-008; was line 96). Re-verified after the 008 merge:
  no other Bash code path issues HTTP, so the shim design still holds.

## Decision 1 — Replace the per-test PowerShell mock with a scripted `curl` shim (Bash unit suite)

**Decision**: For the Bash unit suite, back `mock_start`/`mock_stop`/`mock_calls`
with a **scripted `curl` replacement** (a small executable placed first on
`PATH`) that serves canned responses from the existing fixtures and appends every
request to a call log — instead of spawning a real HTTP server. The `curl` shim
is pure Bash + `jq`. `jira_request()` in `client.sh` is **unchanged**: it still
runs its full retry/backoff/status-mapping/credential logic; only the `curl`
binary it calls is swapped for the shim.

**Rationale**:
- **SC-002 forces it.** A real HTTP double needs a process that can `accept()` on
  a socket. Bash cannot (`/dev/tcp` is client-only); `jq` cannot listen. Any real
  server therefore requires a runtime beyond `bats`+`jq` (PowerShell, Python,
  `nc`/`socat`). So the *only* design that lets the full Bash suite run with only
  `bats`+`jq` is to not use a socket at all — intercept `curl`.
- **Zero startup cost**: no process, no ephemeral port, no readiness wait. This
  removes the dominant per-test cost (SC-001).
- **Coverage stays honest (FR-005/SC-008)**: `jira_request()` runs unchanged, so
  every statement the transport suite covered before still executes. The `curl`
  binary itself was never in the coverage denominator (the function is
  `kcov-excl`), so swapping it changes no measured line.
- **Single-file migration**: all 35 test files reach the mock only through
  `lib.sh`'s public functions, so changing that one file migrates all of them
  with no per-file edits.
- **Faithful faults**: the shim reproduces 401/403/404/2xx/201, `429` +
  `Retry-After` (returned on every call to exhaust the bounded retry), and
  network failure (the shim exits non-zero, exactly what `jira_request` treats as
  a dropped connection). The existing `configs/*.json` and `fixtures/*.json` are
  reused verbatim.

**Alternatives considered**:
- *Per-file mock via `setup_file`* (start one pwsh mock per file): ~10× fewer
  startups, but still **requires PowerShell** — fails SC-002 outright.
- *Bash-native socket server* (`/dev/tcp`): impossible — Bash cannot accept
  connections.
- *`nc`/`socat`/Python micro-server*: introduces a dependency beyond `bats`+`jq`
  (fails SC-002) and adds cross-platform `nc`-dialect fragility.
- *Stub `jira_request()` itself*: would erase transport coverage (retry loop,
  status mapping) and shrink the denominator — violates FR-005/SC-008.

## Decision 2 — Split mock backends by port: shim for Bash, real pwsh server for PowerShell

**Decision**: The mock driver selects its backend by target port. **Bash port →
`curl` shim** (unit tests, coverage exercise, and the Bash side of conformance).
**PowerShell port → the real pwsh `mock-server.ps1`** (unchanged). The conformance
corpus therefore compares `bash(shim)` captures against `pwsh(real-server)`
captures.

**Rationale**:
- The PowerShell port's transport is native pwsh, not our `curl`, so it needs a
  real socket server — the pwsh mock stays exactly as-is for it.
- The Bash port only ever talks to Jira through `curl`, which the shim intercepts,
  so the Bash side needs no server anywhere — including under kcov, removing 51
  pwsh startups from the coverage job.
- **The conformance diff becomes a continuous cross-check** between the shim and
  the pwsh mock: both consume the same fixtures, so identical responses are
  expected, and any divergence (in either the ports *or* the two mock
  implementations) fails a conformance scenario — which is the correct outcome.
- The pwsh mock remains the single documented source of truth (its README
  contract); the shim is validated against it on every conformance run.

**Alternatives considered**:
- *Real pwsh server for both conformance ports* (isolate the comparison to the
  ports only): keeps pwsh on the Bash-side conformance run, re-introducing pwsh
  startups into CI for no correctness gain — the fixtures are identical either
  way. Rejected for cost; the cross-check in the chosen design is a bonus, not a
  risk, because fixtures are shared.

**Complexity note**: this yields two mock implementations. Tracked and justified
in plan.md Complexity Tracking (SC-002 forbids a socket for the fast path; the
pwsh port needs a server regardless; conformance cross-checks the two every run).

## Decision 3 — A dependency-free parallel test runner (`tests/run-bash.sh`)

**Decision**: Add a runner that discovers the Bash test files and runs them
concurrently by sharding across cores with **`xargs -P`** (POSIX — always
present), one `bats` invocation per file. It never depends on GNU `parallel`. If
concurrency is unavailable for any reason it runs the suite **serially** rather
than skipping. It always executes every file and aggregates exit codes; it
**fails loudly and non-zero** on any error and can never report success while
running zero tests. CI and the quickstart call this runner instead of
`bats --jobs`.

**Rationale**:
- Removes the GNU-`parallel` dependency (SC-002) and the silent-zero-tests trap
  (FR-003).
- `xargs -P N` gives real cross-core parallelism with a tool guaranteed present
  on macOS and Linux.
- With mock tests now server-less, even the serial fallback is fast; parallelism
  is a bonus, not a prerequisite.

**Alternatives considered**:
- *Keep `bats --jobs`, just document the `parallel` need*: leaves the false-green
  trap and the extra dependency in place — fails SC-002/FR-003.
- *`bats --jobs` with a `parallel` auto-install*: adds a dependency and install
  time; rejected.

**Regression test (FR-015)**: run the runner with GNU `parallel` forced off
`PATH` and assert the executed-test count equals the full suite count (never
zero). Written before the runner exists, observed to fail, then made green.

## Decision 4 — CI resource reduction: caching, targeted installs, fewer packages

**Decision**: Cut CI cost without dropping any gate:
1. **Cache** the Pester module and the `uv`-installed `specify-cli` across runs,
   keyed on OS + pinned versions; on a cache miss, install as today (correct but
   slower).
2. **Install `specify-cli` only in the jobs that run the install-harness
   scenarios**, not on every matrix leg.
3. **Drop now-unneeded packages**: GNU `parallel` (replaced by Decision 3) on
   Linux and macOS; the Bash unit run no longer needs PowerShell at all.
4. **Keep the existing fail-open path filter** (gates.yml `changes` job) and
   apply the same conservative, fail-open filtering only where a diff provably
   cannot change a gate's verdict. When affectedness is uncertain, the gate runs
   (FR-009).

**Rationale**: Reinstalling toolchains on every job across three OSes is the
bulk of the avoidable CI minutes; caching and targeted installs remove it while
a cache miss still produces a correct run. Removing pwsh/`parallel` from the Bash
path both speeds runs and shrinks install steps.

**Alternatives considered**:
- *Custom prebuilt runner image / container*: larger change, new maintenance
  surface; violates KISS for the savings available from caching alone. Deferred
  (YAGNI).
- *Aggressive path-based skipping of whole suites on PRs*: risks hiding
  regressions; the constitution keeps the three-OS matrix a merge gate. Only
  fail-open filtering that cannot change a verdict is used.

## Decision 5 — Coverage job speed follows from Decisions 1–3

**Decision**: No new coverage mechanism. The kcov gate keeps its two-collector
design (kcov over the conformance corpus + traced bats), the 80% floor, the
`kcov-excl` regions, and the denominator unchanged. It simply runs faster
because (a) the traced bats suite no longer starts any pwsh process, and (b) the
Bash-side conformance exercise uses the shim (Decision 2), removing 51 pwsh
startups from under kcov.

**Rationale**: Meets SC-004/SC-005 by removing work, not by weakening the gate
(FR-005/FR-010). The measured lines are identical, so the percentage and floor
are untouched (SC-008).

**Alternatives considered**:
- *Lower the threshold or narrow the denominator*: explicitly forbidden
  (FR-005, Out of Scope).

## Decision 6 — The shim carries session state (resolves OQ-1)

**Decision**: The `curl` shim keeps a **mutable issue store** as a JSON file under
the recorded `MOCK_TMPDIR`: seeded from the existing fixtures at `mock_start`,
mutated on `POST`/`PUT` (recording the created key and its `fields`, including
`parent`), and read on `GET /rest/api/3/issue/{key}`. `mock_issue_field` is
therefore served correctly without a socket.

**Rationale**:
- 008's `mock_issue_field` has **9 call sites** asserting on fields (e.g.
  `.fields.parent.key`) of issues an *earlier POST in the same test* created.
  A stateless fixture router cannot serve those values — they exist in no file.
- The store lives inside the per-instance `MOCK_TMPDIR` that `mock_start` records
  and `mock_stop` deletes, so isolation-by-recorded-identity (Constitution XIII)
  and green-under-parallel (FR-007/SC-009) hold: concurrent tests never share it.
- It keeps the shim honest against the pwsh mock, which holds the same state in
  `$script:Issues` — the conformance diff continues to cross-check the two.

**Alternatives rejected**:
- *Reconstruct the issue from the call log*: cheaper, but the reconstruction would
  drift from what the pwsh mock returns and would surface as conformance failures
  — trading a design cost for a correctness risk.
- *Keep the two hierarchy files on the real pwsh mock*: fastest to build, but it
  **violates SC-002** (those tests would again require PowerShell) and leaves 9
  assertions unrunnable on a `bats`+`jq` host.

## Decision 7 — Shard the conformance corpus **within** each OS, never across OSes

**Decision**: Parallelise the 51-scenario corpus by running it as N shards on the
**same** host, using the sharding `tests/conformance/ci-conformance.sh` already
supports (`SPEC_KIT_JIRA_SHARD_TOTAL` / `SPEC_KIT_JIRA_SHARD_INDEX`, introduced by
008 for the Windows probe). **Every OS still executes all 51 scenarios.**

**Rationale**:
- This is the largest available saving: 008 promoted the corpus from a Linux-only
  job to a step of the three-OS `unit` job *and* grew it 39 → 51 scenarios, so the
  most expensive non-coverage work in the pipeline multiplied by ~3.9×.
- It changes **no** gate and **no** verdict — the same scenarios run against the
  same two ports; only their arrangement in time changes. It therefore needs none
  of the tiering that spec.md puts Out of Scope.
- The mechanism is already implemented and exercised in the tree; this reuses it
  rather than inventing one (KISS/YAGNI).

**The trap this decision exists to close**: the *other* reading of "shard the
conformance across the matrix" is to give Linux scenarios 1–17, macOS 18–34 and
Windows 35–51. That is 3× cheaper and **silently destroys the guarantee**: no OS
would ever prove the whole corpus, and a Windows-only divergence in scenarios 1–17
would become invisible. FR-018 forbids it and SC-011 checks the per-OS scenario
count mechanically so the mistake cannot be made quietly later.

## Decision 8 — A change-scoped local mode for the inner loop

**Decision**: `tests/run-bash.sh` gains an opt-in mode that runs only the test
files affected by a diff (`--since <ref>`), for developers and coding agents. It
is **local only**: no CI gate may invoke it, and CI always runs the full suite.
Selecting nothing runs everything (fail-open), never zero.

**Rationale**:
- The reported pain is a 4–5 hour implementation loop; that time is dominated by
  re-running 955 tests after every small edit. Running the ~dozens of affected
  files instead is the single biggest lever on it.
- It is **not** the tiering that is Out of Scope: that exclusion governs which
  gates block a *pull request*. This changes nothing about CI, so no gate, verdict
  or coverage floor is affected.
- Fail-open on an undeterminable diff keeps the mode from ever being a false
  green — the same discipline FR-003 imposes on the parallel path.

## Decision 9 — Absolute budgets replace relative reduction targets

**Decision**: SC-001/SC-004/SC-005 become absolute wall-clock budgets (≤ 5 min
local suite, ≤ 15 min `coverage-bash`, ≤ 20 min to a merge decision), with
SC-005b keeping a directional runner-minutes check.

**Rationale**: the relative targets were unverifiable. The local baseline cannot
be measured on macOS (0 tests without GNU `parallel`; mock files fail without
PowerShell), and the CI "baseline" was a figure quoted in a gates.yml comment
rather than a measurement. Worse, feature 008 grew the workload ~23% *while this
spec was being written*, which would have moved any percentage target silently. An
absolute budget is measurable today, survives suite growth, and fails loudly —
which is exactly the behaviour the 30-minute timeout failed to provide.

## Cross-cutting: test isolation under parallelism (Constitution XIII)

The shim writes its call log and response state into a per-instance `mktemp`
directory recorded by `mock_start`; `mock_stop` removes exactly that directory.
No pwsh PID exists to leak, and nothing is located by name pattern or
machine-wide scan. This satisfies the identity-by-recorded-value rule and keeps
the suite green under maximum parallelism (FR-007/SC-009).

## Open questions

None outstanding. **OQ-1 is RESOLVED by Decision 6** (option 1: session state in
the recorded `MOCK_TMPDIR`). The statement of the question is kept below because
it documents why the shim is not the stateless router Decisions 1–2 first
described.

### OQ-1 (resolved) — Does the `curl` shim need mutable session state?

008 added two public functions to `tests/conformance/mock-jira/lib.sh`, which the
mock-driver contract this plan was written against does not cover:

- `mock_write_config <json>` — writes an ad hoc config to a temp file and prints
  the path. **0 call sites in `tests/bash`** (used from `Mock.psm1` only), so it
  costs the shim nothing today.
- `mock_issue_field <key> <jq-path>` — runs
  `curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/${key}" | jq -r "${path}"` to read
  a field back out of **an issue the mock already holds**. **9 call sites** across
  `tests/bash/sink/test_hierarchy.bats` and
  `tests/bash/commands/test_reconcile_hierarchy.bats`, asserting things like
  `.fields.parent.key` on an issue a *previous* POST in the same test created.

Decisions 1 and 2 specify the shim as a **stateless router** from request path to
a canned fixture. That cannot serve `mock_issue_field`: the value asserted was
written earlier in the same session and exists in no fixture file.

Options considered:

1. **✅ CHOSEN — Give the shim session state** — keep a mutable issue store in the
   recorded `MOCK_TMPDIR` (seeded from the fixtures, mutated on POST/PUT, read on
   GET). Preserves the isolation-by-recorded-identity rule (Constitution XIII)
   since the store lives in the per-instance temp dir. Costs the most shim
   complexity. See Decision 6.
2. **Serve `mock_issue_field` from the call log** — reconstruct the issue from the
   recorded POST bodies rather than holding state. Cheaper, but diverges from what
   the pwsh mock returns and risks failing the conformance cross-check.
3. **Exclude the 2 hierarchy files from the shim backend** — they keep the real
   pwsh mock. Fastest to implement, but **violates SC-002** (those tests would
   then require PowerShell) and leaves 9 assertions unrunnable on a bats+jq host.

Resolved by Decision 6; `contracts/curl-shim.md` and `contracts/mock-driver.md`
carry the resulting state model, and T004/T005 are scoped accordingly.
