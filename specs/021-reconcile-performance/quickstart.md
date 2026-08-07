# Quickstart — validating reconcile performance

How to prove this feature works, in the order the work lands. Every claim below is checked by a **count
or a byte comparison**, never by a wall clock — the two timing criteria (SC-001, SC-002) are dogfood
evidence, gathered last, on a real instance.

Design details live in [`contracts/`](./contracts/) and [`data-model.md`](./data-model.md); this file
says what to run and what you should see.

## Prerequisites

Nothing new. Bash ≥ 4 with `curl`, `jq`, `git`; PowerShell 7+ for the twin; `bats` and `shellcheck` for
the suites. The SecretManagement module is **not** a prerequisite and `prereq_check` must not test for it.

```bash
tests/run-bash.sh                      # full bash suite, ~190 s
tests/run-bash.sh --since main         # change-scoped inner loop, ≤60 s
bash tests/conformance/ci-conformance.sh   # cross-port byte equivalence
pwsh -c 'Invoke-Pester -Path tests/powershell -Output Detailed'
shellcheck $(git ls-files '*.sh')
```

Conformance success is silent: exit 0 with no `conformance divergence` lines is the pass signal. There is
no pass banner.

---

## Step 1 — The instrument (build this first)

```bash
SPEC_KIT_JIRA_TIMING=1 .specify/extensions/jira/scripts/bash/spec-kit-jira.sh \
  reconcile specs/021-reconcile-performance/spec.md 2>&1 >/dev/null
```

Expect a `timing:` line per phase reached and a `total` line, on **stderr only**.

The check that matters is that the mode changes nothing else:

```bash
# same scenario, mode off then on — everything but stderr must be identical
# usage: run-scenario.sh <scenario.json> <bash|powershell> [outdir]
bash tests/conformance/run-scenario.sh tests/conformance/scenarios/us021-timing-off.json bash /tmp/off
bash tests/conformance/run-scenario.sh tests/conformance/scenarios/us021-timing-on.json  bash /tmp/on
diff /tmp/off/stdout /tmp/on/stdout && diff /tmp/off/exit /tmp/on/exit
diff -r /tmp/off/workdir /tmp/on/workdir
diff /tmp/off/calls.log /tmp/on/calls.log
```

All four must be silent. With `_TIMING_FAKE_CLOCK` set in the scenario, the cross-port stderr diff must
be silent too.

**Secrecy check**, run under tracing at maximum verbosity:

```bash
grep -R "$JIRA_API_TOKEN" /tmp/on/ ; echo "exit $? (1 = clean)"
```

---

## Step 2 — The credential is asked for once

The counting stub replaces the secret-store seam and records every invocation.

```bash
bats tests/bash/lib/test_credentials_cache.bats
```

| Scenario | Expected count |
| --- | --- |
| Run issuing many requests, one of them retried after a 429 | **1** |
| Run that short-circuits on run state | **0** |
| Run in a repository with no base URL | **0** |
| Token supplied in the environment | **0** (the store is never reached) |

The trap this guards against: a cache filled inside `resp="$(jira_request …)"` dies with the subshell.
If the first row reads the number of requests instead of `1`, the prime is being called in the wrong
place — see [`contracts/credential-cache.md`](./contracts/credential-cache.md) §2.

Then confirm the token stayed where it belongs:

```bash
bats tests/bash/lib/test_token_leak.bats
pwsh -c 'Invoke-Pester -Path tests/powershell/lib/TokenLeak.Tests.ps1'
```

---

## Step 3 — Recognition reads the estate in one exchange

The decisive test is **differential**: the same scenarios with the prefetch on and off must be
byte-identical everywhere except `calls.log`.

```bash
for s in tests/conformance/scenarios/us021-prefetch-*.json; do
  bash tests/conformance/run-scenario.sh "$s" bash /tmp/pre-on
  _RECOGNITION_NO_PREFETCH=1 \
    bash tests/conformance/run-scenario.sh "$s" bash /tmp/pre-off
  diff /tmp/pre-on/stdout /tmp/pre-on/exit /tmp/pre-off/stdout /tmp/pre-off/exit
  diff -r /tmp/pre-on/workdir /tmp/pre-off/workdir
done
```

Then count, against the mock:

| Fixture | `calls.log` read-phase lines |
| --- | --- |
| 61 recorded keys, all present | **1** |
| 101 recorded keys, all present | **2** |
| 61 keys, one deleted | **2** (the batch, plus the individual fall-through read) |
| 61 keys, `bulkfetch` returns 400 | **61** — today's cost, today's outcome |
| 0 recorded keys (first run) | **0** |

The last two rows are the point of the design: a prefetch that fails costs speed, never correctness.

**The classification checks are the ones that must not be skipped.** A deleted key must still classify
`new` with `recreated_from`; an invisible key must still fail the whole specification closed at exit 3
with zero writes. `bulkfetch` cannot tell those apart — it omits both — so if either regresses, the
fall-through of [`contracts/recognition-prefetch.md`](./contracts/recognition-prefetch.md) §3 is not
wired in.

---

## Step 4 — The unchanged run costs nothing

```bash
bash tests/conformance/run-scenario.sh \
  tests/conformance/scenarios/us021-state-unchanged.json bash /tmp/state
wc -l < /tmp/state/calls.log     # second run: 0
```

Walk the decision table by hand once, in a scratch repository:

```bash
reconcile spec.md            # full run; state recorded
reconcile spec.md            # short-circuit: exit 0, no network, summary names it
touch spec.md && reconcile spec.md          # content unchanged → still short-circuits
printf '\n' >> spec.md && reconcile spec.md # content changed → full run
reconcile spec.md --force                   # full run, state re-recorded
reconcile spec.md --dry-run                 # full preview; state neither consumed nor written
```

Then the fail-open cases — each must produce a **full reconcile**, never a skip:

```bash
printf 'not json' > .specify/jira/state/<feature-dir>.json && reconcile spec.md
```

And the ignore guarantee, which must hold in a repository bound before this release:

```bash
git status --porcelain | grep -c '.specify/jira/state'   # 0
```

---

## Step 5 — Connections and forks

Pure refactors. The acceptance criterion is that **the entire existing corpus is unmodified and green**:

```bash
bash tests/conformance/ci-conformance.sh
tests/run-bash.sh
```

A scenario that had to be edited to accommodate Step 5 is a behaviour change, and behaviour was supposed
to be frozen. Apply the loop de-forking one loop at a time, with the corpus green between each.

---

## Step 6 — The secret-manager rung falls through silently, on all three platforms

Authorised by constitution v1.3.0. Note that the amendment made this a **three-platform** step, not a
Windows one: the rung is soft-optional everywhere, and every unavailability path needs a test.

```bash
bats tests/bash/lib/test_credentials.bats            # macOS + Linux rungs
pwsh -c 'Invoke-Pester -Path tests/powershell/lib/Credentials.Tests.ps1 -Output Detailed'
```

| Platform | Paths that must fall through silently |
| --- | --- |
| macOS / Linux | `security` / `secret-tool` absent from PATH; present but exiting non-zero; entry missing |
| Windows | SecretManagement module absent; no vault registered; no secret named `spec-kit-jira`; **vault locked** |

Each must produce no error record, no output, and **no wait**. The locked-vault case is the one that
matters most — a lifecycle hook has nobody to answer a prompt, and a hang there is worse than the
slowness this whole feature exists to remove.

The macOS and Linux rows are new work the amendment created: the existing suite proves the
empty-source fall-through but never the tool-absent or tool-failing paths.

---

## Step 7 — Dogfood, which is where the timings come from

On the real instance whose 3-to-7-minute measurement motivated this feature:

```bash
SPEC_KIT_JIRA_TIMING=1 reconcile <a typical spec> 2>&1 >/dev/null    # changed run
SPEC_KIT_JIRA_TIMING=1 reconcile <the same spec>  2>&1 >/dev/null    # unchanged run
```

| Criterion | Evidence |
| --- | --- |
| SC-001 | Second run: `total` under 1000 ms, `0 requests` |
| SC-002 | First run: `total` under 30000 ms |
| SC-003 | `recognition` phase request count does not grow with the number of recorded tickets |
| SC-004 | Counting stub, in the suite — not measured here |

Record the before/after numbers in `tasks.md` as research R10 requires. An optimisation whose cost the
instrument never found is dropped, not shipped for tidiness.

---

## Three-OS gate

Nothing merges without a green matrix. Two hazards on this feature specifically:

- **Windows.** Note that `main` is currently red on `windows-latest`; diff a run's annotations against
  `main`'s before blaming this branch. A Windows-only divergence is diagnosed by measurement on the real
  runner (`ci/windows-probe`, ~11 min, results arrive as check-run annotations), never by emulation, and
  one retry is the limit before handing the result back.
- **stderr.** The timing report is the first thing this project has deliberately written to stderr in a
  fixed format that the corpus diffs across ports. Line endings and column padding are exactly where the
  Bash and PowerShell ports have diverged before.
