# Quickstart: Reproducing and Validating Feature 024

**Feature**: 024-reconcile-local-performance | **Date**: 2026-08-10

Every command below was run on this machine while writing the plan; the numbers quoted are what it produced.
Run from the worktree root.

## Prerequisites

`bash` 5+, `jq`, `git`, `bats`, `shellcheck`; `pwsh` 7+ for the PowerShell port. No new dependency is
introduced by this feature.

The reference specification is already in the repository — **do not create a fixture**:

- Scenario: `tests/conformance/scenarios/us021-prefetch-count-61.json`
- Fixture: `tests/conformance/fixtures/repo-with-widget-spec-61` — 1 epic + 60 stories, 545-line `spec.md`

---

## 1. Reproduce the locale defect (before the fix)

Both branches, in one command each. The first is the reported crash; the second is the silent one that matters
more.

```bash
# Loud branch: fractional part begins with 0 → read as octal → rejected
bash -c 'usec="1786381617,093486"; echo $(( 10#${usec} / 1000 ))'
#=> bash: 10#1786381617,093486: value too great for base (error token is "093486")

# Silent branch: any other fractional part → NO error, seconds silently discarded
LC_ALL=fr_FR.UTF-8 bash -c 'r=$EPOCHREALTIME; echo "raw=$r"; echo "sec=[${r%.*}] usec=[${r#*.}]"'
#=> raw=1786383305,226619   sec=[1786383305,226619]  usec=[1786383305,226619]
```

> The second is why a test must assert **duration correctness**, not error absence: the broken code is
> error-free for roughly nine readings in ten.

Confirm the abort mechanism — `set -euo pipefail` at `scripts/bash/spec-kit-jira.sh:17` turns the arithmetic
failure into a full run abort.

### 1a. Locale prerequisite (T001)

The locale matrix (§4 V1-V3) needs `fr_FR.UTF-8` and `de_DE.UTF-8` generated on whatever host runs it.
Confirmed present on the development host and the Linux CI runner via `locale -a`. A bats test in this
matrix MUST NOT silently pass when a locale is absent from the host it runs on: check with
`locale -a | grep -qi '^fr_FR.utf8$'` (respectively `de_DE`) in `setup()` and, if absent, `skip "fr_FR.UTF-8
not generated on this host"` — an explicit, visible skip, never a no-op that reports green. A test that
degrades to a silent pass on a runner missing the locale is the exact failure mode this task exists to
prevent (research A-4b, contracts/clock-reading.md §4).

## 2. Validate the fix

```bash
LC_ALL=fr_FR.UTF-8 bash -c 'r=$EPOCHREALTIME; d=${r//[!0-9]/}; echo "raw=$r ms=$(( 10#$d / 1000 ))"'
#=> raw=1786383575,080459 ms=1786383575080
```

Verified under `LC_ALL=C`, `fr_FR.UTF-8`, and `de_DE.UTF-8`. Contract: `contracts/clock-reading.md` §4.

```bash
bats -r tests/bash/lib/test_timing.bats     # the -r is load-bearing
```

---

## 3. Take a timing baseline

```bash
SPEC_KIT_JIRA_HARNESS_ENV="SPEC_KIT_JIRA_TIMING=1" \
  bash tests/conformance/run-scenario.sh \
    tests/conformance/scenarios/us021-prefetch-count-61.json bash /tmp/out61
cat /tmp/out61/stderr
```

Measured today on **unmanaged** hardware with a **mock** tracker — so every second here is local CPU, and the
absolute numbers are 4–7× lower than on a corporate-managed machine (see §5a):

```
timing: prereq           6 ms    0 requests
timing: state            5 ms    0 requests
timing: config         514 ms    0 requests
timing: parse        52698 ms    0 requests     <-- 58% of the run
timing: gate           465 ms    0 requests
timing: recognition   5377 ms    0 requests
timing: plan         16286 ms    0 requests
timing: apply        16164 ms    0 requests
timing: total        91515 ms    0 requests
```

> **How to read this against the consuming-repo profile.** These are the *same run at a different per-spawn
> cost* (§5a), not a correction to it. `config` and `gate` look cheap here because this host pays 2.4 ms per
> spawn; the maintainer's pays 9–18 ms. What this rig adds is `parse`: with network removed by construction it
> burns 52.7 s of pure CPU, which the consuming-repo profile under-weights at 20 s. Also note every phase says
> `0 requests` while the run actually issued 123 (§4).

## 4. Reproduce the request-counter defect

```bash
wc -l /tmp/out61/calls.log
#=> 123
```

123 requests issued, 0 reported. Root cause in `contracts/request-counting.md` §1. Until this is fixed, "phases
excluding request time" — the quantity SC-005 and FR-023 are written about — cannot be computed.

## 5. Count external processes

```bash
mkdir -p /tmp/countjq
printf '#!/bin/sh\nprintf "x\\n" >> "$JQ_COUNT_FILE"\nexec "$REAL_JQ" "$@"\n' > /tmp/countjq/jq
chmod +x /tmp/countjq/jq
: > /tmp/jqcount.txt

REAL_JQ=$(command -v jq) JQ_COUNT_FILE=/tmp/jqcount.txt PATH="/tmp/countjq:$PATH" \
SPEC_KIT_JIRA_HARNESS_ENV="SPEC_KIT_JIRA_TIMING=1
REAL_JQ=$(command -v jq)
JQ_COUNT_FILE=/tmp/jqcount.txt" \
  bash tests/conformance/run-scenario.sh \
    tests/conformance/scenarios/us021-prefetch-count-61.json bash /tmp/out61b

wc -l < /tmp/jqcount.txt
#=> 20243        (~332 per mirrored item)
```

> **Never read a duration from this run.** The shim costs a process per call and inflated the same scenario
> from 91 515 ms to 147 774 ms — 61%. Count and time in separate runs (`contracts/spawn-budget.md` §4).

## 5a. Measure your host's per-spawn cost — the number that reconciles the two profiles

```bash
now() { local r=$EPOCHREALTIME; echo $(( 10#${r//[!0-9]/} / 1000 )); }
N=200; s=$(now); for ((i=0;i<N;i++)); do jq -n '1' > /dev/null; done; e=$(now)
echo "$(( (e-s)*1000/N )) us per jq spawn"
```

Measured here: **2445 µs**. The consuming repo's 3–6 minutes over ~20 000 spawns implies **9000–18000 µs** —
4–7× higher, the signature of an endpoint-security agent inspecting every `exec`, and standard on
corporate-managed macOS. That single multiplier explains why the same code profiles so differently on the two
machines, and why the run-to-run variance is high there (EDR cost varies with load) and low here.

**Run this on the consuming-repo machine when you next profile.** It converts that host's wall-clock numbers
into spawn counts, which are comparable across machines and are what the suite actually asserts.

---

## 6. Prove nothing else moved

The behavioural gate, after **each** phase's consolidation rather than once at the end:

```bash
bash tests/conformance/ci-conformance.sh
```

Success is silent: exit 0 and zero `conformance divergence` lines. There is no pass banner, and the temp paths
it prints are harness noise.

```bash
tests/run-bash.sh                      # full bash suite, ~190 s
tests/run-bash.sh --since HEAD~1       # change-scoped inner loop, <=60 s
find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +
```

Windows is verified by pushing to `ci/windows-probe` (~11 min, results arrive as check-run annotations). A
platform claim is unproven without a green run there — never by emulation.

---

## 7. Acceptance walkthrough

| Step | Command | Expected |
| --- | --- | --- |
| 1 | §2 locale matrix | Correct durations under `C`, `fr_FR`, `de_DE`; byte-identical under injected clock |
| 2 | §2 with forced malformed reading | Exit code, stdout, written files identical to timing-off; run not aborted |
| 3 | §4 | Summed per-phase requests == `wc -l calls.log` |
| 4 | §5 after Step 4 of the plan | Spawn count no longer grows with item count |
| 5 | §5 with stories doubled | Spawn count unchanged |
| 6 | §3 after all steps | `parse` < 5 s; total excluding requests < 20 s |
| 7 | §6 | Corpus, bats, Pester all green; `calls.log` byte-identical |

## Known gap, carried to the user

FR-025 asks for run-to-run variance within 20%. On this rig it already measures **5.3%** (91 515 ms vs
96 519 ms) — but that is expected on a host paying 2.4 ms per spawn. The 79% measured on the consuming repo is
consistent with endpoint-security inspection cost varying under system load (§5a), which is real and is not
something a bound on this rig can demonstrate. Cutting ~20 000 spawns to a few hundred removes most of the
exposure; the residual is not fully under this feature's control. See `plan.md` "Open items".
