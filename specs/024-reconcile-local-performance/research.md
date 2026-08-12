# Phase 0 Research: Reconcile Local Performance

**Feature**: 024-reconcile-local-performance | **Date**: 2026-08-10 | **Revised**: 2026-08-10 (R3 reframed)

Two independent measurements exist, and **both are valid**. They were taken on different machines, against
different inputs, with different trackers — and R3 below shows they are the same run seen through two different
per-spawn costs. Neither supersedes the other.

| | **Consuming-repo profile** (authoritative) | **Isolation profile** (secondary) |
| --- | --- | --- |
| Taken by | The maintainer, on a real consuming repository | This session, on the conformance fixture |
| Tracker | Live Jira | Local mock |
| Machine | macOS M1 Max, corporate-managed | macOS Apple Silicon, unmanaged |
| Proves | What the operator actually experiences, in the environment that matters | What the cost is with network time removed by construction |

**The consuming-repo profile is the target environment and is treated as authoritative throughout.** The
isolation profile's role is narrow and specific: because its tracker is a local mock, every second it measures
is provably local CPU. It is used to isolate mechanism, never to re-rank the maintainer's phases.

**Isolation rig**: `tests/conformance/scenarios/us021-prefetch-count-61.json`, fixture
`tests/conformance/fixtures/repo-with-widget-spec-61` — 1 epic + 60 stories, 545-line `spec.md`, matching the
spec's reference shape (A-1).

---

## R1 — The locale defect: root cause, and why it is a crash *and* a lie

**Decision**: Read the clock by stripping every non-digit from `EPOCHREALTIME` and dividing once, guarded by a
digit-shape check that degrades instead of erroring.

**Root cause, measured.** Three mechanisms compound, and only the third is in the bug report.

1. `scripts/bash/lib/timing.sh:112-114` splits on a literal dot. Under a comma locale neither `${r%.*}` nor
   `${r#*.}` matches, so **both halves come away holding the entire string**, comma included.
2. The arithmetic evaluator then meets `10#1786381617,093486` and applies the **comma operator**: it evaluates
   the left operand, discards it, and yields the right. The seconds are thrown away.
3. Whether that is loud or silent depends on the first fractional digit:

   | Fractional part | Evaluated as | Result |
   | --- | --- | --- |
   | `,093486` | `093486` → octal literal, `8`/`9` invalid | `value too great for base` — the reported crash |
   | `,226619` | `226619` → valid decimal | **no error**, duration computed from microseconds alone |

   Reproduced directly, both branches. Roughly one reading in ten begins with `0`, so the instrument fails
   loudly about 10% of the time and silently the other 90%.

**Why the crash is fatal rather than cosmetic.** `scripts/bash/spec-kit-jira.sh:17` sets `set -euo pipefail`.
An arithmetic error is a non-zero status, so the failing clock read aborts the entire reconcile. This is the
mechanism behind spec FR-003: the instrument currently *can* kill the run it measures, and must not.

**Options considered.**

| Option | Mechanism | Verdict |
| --- | --- | --- |
| A. Force `LC_ALL=C` process-wide | Set the numeric locale at the entry point | **Rejected.** Blunt and far-reaching: also changes collation and risks UTF-8 handling across every module, for a defect confined to one variable. |
| B. Split on the first non-digit | `${r%%[!0-9]*}` / `${r##*[!0-9]}` | Works, verified under `C`, `fr_FR.UTF-8`, `de_DE.UTF-8`. Assumes one separator run and no digit grouping. |
| C. **Strip all non-digits, divide once** | `d=${r//[!0-9]/}` then `ms=$(( 10#$d / 1000 ))` | **Chosen.** |

**Rationale for C.** It names no separator character at all, which is what spec FR-002 means by
"locale-independent by construction" — there is nothing in it a new locale could invalidate. It is also
grouping-proof, which B is not. Its one assumption is on bash's *own* fixed format (`EPOCHREALTIME` is always
six fractional digits), which the port already controls: tier 1 is selected only when `EPOCHREALTIME` exists,
i.e. bash 5+. Verified:

```
LC_ALL=fr_FR.UTF-8 → raw=1786383575,080459  ms=1786383575080  (seconds check: 1786383575 ✓)
LC_ALL=C           → raw=1786383548.861137  ms=1786383548861                             ✓
LC_ALL=de_DE.UTF-8 → raw=1786383547,762406                                               ✓
```

It is also fewer operations than today's code, satisfying Principle XIV directly rather than by argument.

**Fail-open guard (FR-003)**. `10#` on an empty or non-digit string still errors under `set -e`. The chosen
shape validates `[[ ${d} =~ ^[0-9]+$ ]]` first and, on failure, marks the instrument degraded and returns
success. This must wrap **every** clock tier, since FR-003 is written about any failure.

**Rejected**: `date +%s%N` for tier 1 (reintroduces a fork per phase mark — the instrument distorting what it
measures; feature 021 rejected it for the same reason); `printf %.6f` normalisation (still locale-sensitive,
and forks).

---

## R2 — The request counter always reports zero *(now spec FR-036, FR-037)*

**Found here rather than in the specification, and it blocks the same baseline the locale fix blocks.** The
spec was amended to carry FR-036 and FR-037 once this was measured; the paragraphs below are the measurement
that produced them.

Measured on the isolation rig: the run issues **123 requests** (`wc -l calls.log`) and the timing report
attributes **0 requests to every phase**.

**Root cause**: `scripts/bash/sink/jira/client.sh:153` increments `JIRA_REQUEST_COUNT` in the shell running
`jira_request`. That function is invoked through `$( … )` at **15 of its 28 call sites**, so the increment lands
in a command-substitution subshell and is discarded on exit. The parent's counter never moves.

**Consequence.** Spec SC-005 and FR-023 are written about "all phases **excluding request time**". With the
counter stuck at zero, that quantity cannot be computed on a live tracker — so the feature's headline criterion
is unverifiable in exactly the environment the maintainer measures in. This is also why the consuming-repo
profile cannot be decomposed into CPU and network after the fact: the information was never recorded.

**Decision**: fix it immediately after the locale fix, for the reason the user gave for sequencing the locale
fix first — it unblocks the baseline.

**Cost, stated plainly**: the `requests` column changes from `0` to real numbers, changing the expected stderr
of one conformance scenario (`us021-timing-on.json`). FR-032 carves out this one case — the expectation was
encoding a bug — and treats any second changed expectation as scope creep. Blast radius measured: three
scenarios enable timing, one asserts counts.

---

## R3 — The two profiles are the same run at two different per-spawn costs

> **Partly superseded, 2026-08-11 — see R3a.** The arithmetic here holds; the attribution of the multiplier
> to `exec` does not. Kept in full because the error is instructive.

This is the central finding, and it **confirms the consuming-repo profile rather than competing with it**.

**The invariant across both environments is the spawn count.** A `PATH`-interposed counting stand-in recorded
**20 243 `jq` invocations** for the 61-item reference run — roughly **332 per mirrored item**.

**The variable is what one spawn costs.** Measured on this machine: **2.445 ms** per `jq` spawn (200
iterations), 0.545 ms for a bare subshell.

The two profiles then follow from one multiplication:

| | spawns | × cost/spawn | = predicted | measured |
| --- | ---: | ---: | ---: | ---: |
| This machine (unmanaged) | 20 243 | 2.445 ms | **49.5 s** | 91.5 s total, of which parse+plan+apply = 85 s |
| Consuming repo (implied) | ~20 000 | **9–18 ms** | **3–6 min** | **3–6 min** ✓ |

A per-spawn cost of 9–18 ms is the well-documented signature of an endpoint-security agent inspecting every
`exec` — standard on corporate-managed macOS, and precisely the condition feature 021's own research named
("under an endpoint-security agent that inspects every process spawn, far more"). It also explains the
**run-to-run variance**: EDR inspection cost varies with system load, which a pure-CPU workload would not.

**What this means for the plan, and it is favourable to the maintainer's reading:**

1. **The consuming-repo attribution stands.** Its phases are heavier because that machine pays 4–7× per spawn
   and because a real repository's configuration and folder content produce more spawns than a synthetic
   fixture. Nothing about it needed to reproduce on unmanaged hardware to be true.
2. **The isolation profile adds one phase rather than subtracting any.** With network removed by construction,
   `parse` alone burns 52.7 s of pure CPU — 58% of that run. That is a cost the consuming-repo profile
   under-weights at 20 s, and it is added to the work list, not traded against anything.
3. **Spawn count is the better success criterion than wall-clock**, because it is machine-independent. Two
   engineers on differently-managed laptops will disagree about seconds and agree exactly about spawns. This
   is why spec FR-016/FR-017 are written as counting requirements and why the plan leads with them.
4. **The fix helps the managed machine 4–7× more than it helps this one.** Every eliminated spawn is worth
   2.4 ms here and 9–18 ms there.

**Isolation-rig phase table**, recorded for the record — as a pure-CPU decomposition, not as a correction to
the maintainer's phases:

| phase | run 1 | run 3 | | phase | run 1 | run 3 |
| --- | ---: | ---: | --- | --- | ---: | ---: |
| prereq | 6 ms | 8 ms | | recognition | 5 377 ms | 5 712 ms |
| state | 5 ms | 5 ms | | plan | 16 286 ms | 17 022 ms |
| config | 514 ms | 546 ms | | apply | 16 164 ms | 16 517 ms |
| parse | 52 698 ms | 56 263 ms | | **total** | **91 515 ms** | **96 519 ms** |
| gate | 465 ms | 446 ms | | | | |

Two config-phase hypotheses were tested against this rig and **failed to explain the gap**, which is what
pointed to per-spawn cost: the YAML parser is linear at ~6 ms/line (11→146 lines: 81→879 ms), so 84 s would
need ~14 000 config lines; and `marker_splice_stray_files` over a real 2 400-line spec folder costs **34 ms**.
Neither is a bottleneck on unmanaged hardware. Multiply either by an EDR-inflated spawn cost and by a
production-sized configuration, and the maintainer's figure follows.

---

## R3a — What the multiplier actually applies to (correction to R3, 2026-08-11)

R3 inferred a per-spawn cost of 9–18 ms on the managed machine from spawns × time, and identified it as an
endpoint-security agent inspecting every `exec`. R3 flagged that figure as *implied*, never measured. It has
now been measured, on that machine:

| measurement | result |
| --- | ---: |
| `jq -n '1'` × 100, no redirection | **1.1 ms/spawn** |
| `jq -n '1' <<< "x"` × 100 (one-byte here-string) | **6.1 ms/spawn** |
| `jq -R '.' <<< $BIG` × 100 (50 KB here-string) | 8.6 ms/spawn |
| spawn count 1 350 → 836 (−38%) | **−4.5% wall time** |
| one duplicated `config.local.yml` read removed | **−91% on that phase** |

A bare spawn costs **1.1 ms** — an order of magnitude below R3's inferred range, and *lower* than the 2.4 ms
measured on unmanaged hardware. The ×5.5 jump appears only when a here-string is attached, and a 50 KB payload
adds just 41% on top. **The agent is not inspecting `exec`; it is inspecting file operations** — and a
here-string is one, because the shell materialises it as a temporary file.

This also closes R3's own loose end. R3 tested two config-phase hypotheses, found neither explained the 84 s,
and concluded per-spawn cost by elimination. The elimination was sound; the hypothesis space was not — it did
not contain *"the read itself is expensive"*. One full read-and-parse of `config.local.yml` is now directly
measured at **~33 s** on that machine, and `config` (~34 s) and `gate` (~33 s) each perform exactly one.

**Survives from R3**: the two profiles are the same run at different costs; the cost is dominated by a security
agent; spawn count is machine-independent and worth reducing; the variance is agent-load-dependent.
**Does not survive**: the 9–18 ms figure, the "inspecting every `exec`" mechanism, the ×4–7 per-spawn value
claim, and conclusion 3's elevation of spawn count to *the* success criterion.

---

## R4 — Measuring spawns: method and one trap

A `PATH`-interposed shim (append a line, then `exec` the real tool) is sufficient, needs no new dependency, and
works identically for `jq`, `sed`, `awk`, and `curl`.

**The trap**: the shim costs a process per call. The instrumented run took **147 774 ms** against the clean
run's **91 515 ms** — a **61% distortion**. **Counting runs and timing runs must be separate runs**; a test
that asserts both at once is measuring the shim.

---

## R5 — Where the spawns are

`scripts/bash/engine/parse.sh`, two patterns, both O(spawns) in document size:

1. **`_parse_strip_marker_lines` (l. 34-44)** — for **every line** it runs `story_marker_parse_line | jq -r`
   *and* `spec_marker_parse_line | jq -r`: two pipelines, ≥4 processes, per line. Called on the whole document
   (`parse_spec`, l. 557) **and again per story section** (`parse_story`, l. 376).
2. **`_parse_lines_to_json` (l. 66-73)** — one `jq` **per line**, each re-parsing the accumulator: O(n) spawns,
   O(n²) data.

Plus `parse_story` (l. 373): six command-substitution pipelines + `jq` + `json_canonical`, per story.

The same shape drives the `config` phase (the YAML parser forks per line, ~6 ms/line here — far more under
EDR) and the `gate`/`plan`/`apply` phases (`sink/jira/plan_apply.sh`, per-item work).

**Decision**: marker recognition becomes a native `[[ =~ ]]` match — the `jq` calls exist only to read one
field from a small JSON object the port itself just produced. Array accumulation becomes a bash array
serialised by a single batched call.

**Constraint carried in**: FR-020 forbids reaching for `jq` directly on the Bash port for multi-line output
(the Windows build emits CRLF). Removing `jq` calls satisfies this a fortiori; the one remaining batched call
still routes through `scripts/bash/lib/output.sh`.

---

## R6 — Sequencing the cuts

Every phase the maintainer named is in scope, plus `parse`. They are cut **one phase at a time, re-measuring
between**, because FR-021 requires the recorded call sequence to stay byte-identical and a corpus divergence is
far cheaper to bisect after one phase's change than after four.

Because spawn count is machine-independent (R3), each phase's exit condition is stated as a spawn-count
reduction — verifiable on any machine — with wall-clock recorded as supporting evidence on both the maintainer's
hardware and the isolation rig.

---

## R7 — The PowerShell port needs no equivalent work

- **`scripts/powershell/lib/Timing.psm1:76`** reads `[datetime]::UtcNow.Ticks / 10000` — Int64 arithmetic on a
  .NET primitive, no textual rendering, therefore no decimal separator anywhere in the path. **The locale
  defect cannot occur**, confirming spec A-7 by measurement.
- **`scripts/powershell/engine/Parse.psm1`** does its JSON work with in-process `ConvertTo-Json` /
  `ConvertFrom-Json` (26 sites) and spawns **no external process**. The per-item forking pattern structurally
  does not exist there — and by R3's arithmetic, a port that does not spawn is immune to EDR spawn cost
  entirely.

**Decision**: spec US5 is discharged by a recorded profile, not code changes (US5 AC1/AC3). Module-for-module
equivalence is preserved because the Bash consolidation *removes* helpers rather than adding modules — the two
ports converge.

**Open item carried to implementation**: whether the PowerShell port shares the R2 counter defect. It has no
forking-subshell equivalent so it is expected sound, but the counter's cross-port shape is conformance-diffed
and is verified before the timing contract is updated.

---

## R8 — The dominant cost is a fork the counter cannot see (2026-08-11)

**This is the finding the whole feature was hunting, and it explains every anomaly the earlier rounds left
open.** It was reached only after R3's per-spawn inference was falsified (R3a) and the "one config read costs
33 s" attribution was itself downgraded from fact to inference.

**Measured on the motivating machine**, against its real 8 658-line `config.local.yml`:

| | wall | user | system |
| --- | ---: | ---: | ---: |
| One `config_yaml_to_json` of the real file | **31.0 s** | 11.43 s | 16.17 s |
| `x="$(f abc)"` × 10 000 (command substitution) | 7.192 s | 1.04 s | 4.67 s |
| `f abc; x=$_OUT` × 10 000 (out-variable) | **0.101 s** | 0.05 s | 0.01 s |

One command substitution costs **0.72 ms**; the same call through a variable costs **0.010 ms** — a factor of
**71**.

**The parser forks 3–4 times per configuration line**, at four sites: `_cfg_prep:169`
(`_cfg_strip_inline_comment`), `_cfg_parse_mapping:447` (`_cfg_scalar_json`), `_cfg_parse_mapping:471`
(`_cfg_json_encode`), and `_cfg_scalar_json:8` (`_cfg_decode_escapes`). On 8 658 lines that is **26 000–35 000
subshell forks**.

Two independent routes agree on the count:

- *Structural*: 3–4 sites × 8 658 lines = 26 000–35 000.
- *Arithmetic*: the parse's 16.17 s of system time ÷ 0.467 ms of system time per fork = **34 600**.

The 31 s therefore decompose as **~25 s of fork overhead** and **~7.8 s of real work** (the character-by-
character loops inside those same helpers). Removing the substitutions projects the parse to **~8 s**.

**Why no instrument in this feature saw it.** A `$( … )` around a shell function forks and never calls
`exec`. The `PATH`-interposed counting stand-in (R4, T002) shims external binaries — it is structurally
incapable of observing such a fork. The broad diagnostic reported 836 spawns for a 116-second run and was
read as "spawns are not the problem"; the correct reading was "*this counter* cannot see the spawns". Spec
FR-016/FR-018 said "external process", which the code satisfied while forking 34 600 times.

**What this retires, and what it restores.** It retires R3a's implication that process creation is
second-order — process creation is first-order after all, just not the kind anyone was counting. It also
explains why T038 (removing the per-line `jq` calls from this same parser) moved nothing: it replaced `exec`
forks with subshell forks and character loops, roughly a wash. And it explains the isolation rig's silence —
its fixture config is 14 lines against the real 8 658, so the rig under-represents this cost by ~600×.

**The fix is already idiomatic here.** `_cfg_map_entry_key` sets `_CFG_KEY`/`_CFG_REST`, the block parsers set
`_CFG_RET`, and `lib/timing.sh` sets `_TIMING_NOW_MS` — each with a comment saying it must never be called
through `$( … )`, for precisely this reason. The four hot helpers were simply never converted.

---

## Summary of decisions

| # | Decision | Drives |
| --- | --- | --- |
| R1 | Strip non-digits, single divide, digit-shape guard, fail-open on every tier | FR-001…FR-005, FR-008 |
| R2 | Fix the request counter now; accept one corpus expectation change | FR-036, FR-037, SC-005, SC-014, FR-023 |
| R3 | Spawn count is the invariant and the primary criterion; wall-clock is machine-dependent | FR-016, FR-017, SC-008 |
| R4 | `PATH`-interposed counting shim; count and time in **separate** runs | SC-008 |
| R5 | Native regex matching and array accumulation; one batched serialisation | FR-018, FR-019 |
| R6 | All maintainer-named phases plus `parse`; one at a time, re-measure between | FR-021, FR-024 |
| R7 | PowerShell: profile and record, no code change | US5, A-7, FR-033 |

## Unresolved — carried to the user, not silently decided

1. **FR-025's 20% variance bound.** On the isolation rig it already measures 5.3%. On the maintainer's machine
   the reported 79% is consistent with EDR inspection cost varying under load (R3), which no code change fully
   controls — though cutting 20 000 spawns to a few hundred removes almost all of the exposure. Recommendation:
   keep the bound but measure it after the cuts land, rather than treating it as a design constraint now.
2. **Fixing the request counter changes one conformance scenario's expected stderr** — the single place this
   feature knowingly edits an existing expectation. **Resolved 2026-08-10**: FR-036 now requires the fix and
   FR-032 carves out the expectation, so this is in scope rather than an open question.
