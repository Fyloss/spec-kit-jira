# Findings — issue #46 category D, measured on a real Windows machine

Written 2026-08-22 on Windows 11 (MINGW64, bash 4.4.23), against
`ci/windows-d-diagnostic` at `ae83ecf`. Answers §4 of `HANDOFF-46-windows.md`.

Host profile:

```
host:   MINGW64_NT-10.0-26200
bash:   4.4.23(1)-release
jq:     jq-1.8.2  (native Windows build, installed for this work — see §5)
pwsh:   /c/Program Files/PowerShell/7/pwsh
```

---

## 1. The answer to §4 — several stopping points, but not sixteen

**None of the sixteen "stop" anywhere.** They all run to completion, on both
ports, and exit 0. That is why they are silent: there is no failure to report.

The question §4 asks — "do the sixteen stop at the same `file:line` or at
several?" — has no answer as posed, because its premise does not hold. The
question that *does* have an answer is "where do the two ports disagree?", and
there the sixteen fall into **two causes and three emitting sites**:

| # | cause | site | scenarios |
|---|---|---|---|
| 1 | `\` vs `/` in `state_file` | `lib/RunState.psm1:53-55` | **9** |
| 2 | `\` vs `/` in `seed_material` | `commands/Feature.psm1:582` | **5** |
| 3 | trailing **CRLF** vs LF on stdout | `commands/Reconcile.psm1:2086` | **2** |

Causes 1 and 2 are the same defect class in two places. Cause 3 is genuinely
independent and would not have been found by looking for the first.

`us021-state-unchanged` — the 17th scenario, the one #46 filed under "other" —
is **cause 1 as well**. It was classified apart only because it also writes
stderr (132 bytes bash / 135 pwsh), which made it look unlike the silent set.
Its stdout divergence is byte-for-byte the same defect. So the real tally over
the 21 remaining divergences is: 16 from causes 1+2, 2 from cause 3, 4 from
category B (E2BIG, not ours).

### Cause 1 — `state_file` (9 scenarios)

```
us022-checklist-crlf              us3-markdown-idempotent
us022-checklist-two-phases        us4-migration-clean
us022-checklist-unchanged-rerun   us5-plan-on-parent
us023-idempotent-rerun            us2-preserve-human-prefix
us028-template-form-ac
```

Every one is `reconcile … --json` run **twice**; the second run short-circuits
and prints the recorded document's path:

```
bash: {…,"short_circuited":true,"state_file":".specify/jira/state/001-feature.json"}
pwsh: {…,"short_circuited":true,"state_file":".specify\\jira\\state\\001-feature.json"}
```

`Reconcile.psm1:789` calls `Get-JiraRunStatePath`, which builds its answer with
`Join-Path`:

```powershell
$stateDir = Join-Path (Get-JiraConfigDir) 'state'
return (Join-Path $stateDir "$featureDir.json")
```

`Get-JiraConfigDir` itself is clean — it returns the literal `.specify/jira`,
matching the Bash twin's `${JIRA_CONFIG_DIR:-.specify/jira}`. `Join-Path`
renormalises it to `\` on Windows, and the result goes straight to stdout.

### Cause 2 — `seed_material` (5 scenarios)

```
us027-refuse-exists                       us29-feature-mention-with-designator
us027-three-url-forms                     us29-feature-reuse-yes-auto-accept
us29-feature-designator-reuse-yes-silent
```

All are `feature --json`:

```
bash: …,"seed_material":".specify/jira/state/ijt-1.seed-material.json",…
pwsh: …,"seed_material":".specify\\jira\\state\\ijt-1.seed-material.json",…
```

`Feature.psm1:582` builds one variable and uses it for two different jobs:

```powershell
$seedMaterialPath = Join-Path $configDir "state/$shortName.seed-material.json"
[System.IO.File]::WriteAllText($seedMaterialPath, …)   # line 584 — correct
…
seed_material = $materialOut                            # line 597 — the defect
```

Reaching the file with `Join-Path` is right. Spelling it back to the operator
with the same value is not. Note that `Join-Path` rewrites even the `/` already
inside the `"state/$shortName…"` literal — the "both directions" the doc warns
about.

### Cause 3 — trailing CRLF (2 scenarios)

```
us2-field-defaults-question    us2-field-defaults-option-question
```

**This one does not render in a diff.** Both sides print identical-looking
text; `diff -u` names nothing. Only `cmp` sees it:

```
stdout: sizes bash=414 pwsh=415 — differ at byte 414
  bash=0x0a   pwsh=0x0d
  bash tail: … 70 65 6e 64 69 6e 67 22 7d 0a
  pwsh tail: … 70 65 6e 64 69 6e 67 22 7d 0d 0a
```

The PowerShell port terminates that one line with CRLF. Source:

```powershell
[Console]::Out.WriteLine($fdConfirmationJson)     # Reconcile.psm1:2086
```

`[Console]::Out` is a `TextWriter` whose `NewLine` is `Environment.NewLine` —
CRLF on Windows. The port's own idiom everywhere else is an explicit LF, via
`Write` with a literal backtick-n rather than `WriteLine`:

```powershell
[Console]::Out.Write($Payload + "`n")             # Feature.psm1:607, Config.psm1:189, …
```

**There are exactly three `[Console]::Out.WriteLine` calls in the whole
PowerShell port, and all three are in this single block** (2086 for `--json`,
2090-2091 for the prose branch). The two scenarios above exercise 2086. Lines
2090-2091 are the same defect on the prose path and no corpus scenario covers
them — an unmeasured but certain third instance.

The 110 `[Console]::Error.WriteLine` calls are **not** affected: stderr is not
compared by `ci-conformance.sh`.

---

## 2. What this rules out, and what it does not

**Ruled out.**

- *A halt, a crash, a swallowed exception, an `exit` on an unset variable.*
  Every scenario completes and exits 0 on both ports. Nothing to trace.
- *A Bash-port defect.* In all seventeen the Bash port produces exactly the
  bytes the corpus expects on every host. The divergence is the PowerShell
  port's, on Windows only. This is worth stating plainly because #46 has been
  read throughout as "the Bash port on Windows".
- *Any relation to jq, MSYS path translation, or PR #47's cause class.* Causes
  1-3 involve no jq call and no `/dev/fd` or `/tmp` path.
- *Category B (E2BIG).* Untouched, and it lives in different files
  (`lib/output.sh`) than causes 1-3 (`RunState.psm1`, `Feature.psm1`,
  `Reconcile.psm1`). Per §5: **no collision** — the D fix does not go near it.

**Not ruled out.**

- *That the same defect class hides in sites no scenario exercises.* The port
  has 192 `Join-Path` calls. The overwhelming majority are correct — reaching
  the filesystem. Only those whose result reaches stdout or written file
  content are defects, and I have confirmed exactly the three the corpus
  exposes. `Reconcile.psm1:2090-2091` is a fourth, found by reading, not by
  measurement. A systematic audit is a separate task from this diagnosis.
- *That the written-tree comparison is clean.* Every divergence I measured was
  in `stdout`; none of the seventeen diverged in `exit`, `calls.log`, or the
  written tree. But the corpus only covers what it covers.
- *That fixing 1-3 turns the corpus green on the real runner.* Not proven, and
  cannot be from here. That needs `ci/windows-probe`.

---

## 3. What in the brief turned out to be wrong

Said plainly, as §10.3 asks. None of this was unreasonable from the far side of
the machine boundary — it was inference, and it is labelled as such there.

1. **The core premise of §4 and of `diagnose-windows-silent.sh`.** "Something
   ends the run and says nothing"; "the last frame is where the run stops".
   Nothing ends the run. Both ports complete and exit 0. The script's xtrace
   hook is well built and would work, but it answers a question these
   scenarios do not pose — it would print the tail of a *successful* run and
   invite reading its last line as a stopping point, which it is not. I did not
   paste its output into this file (§10 asks for it): it would be a long trace
   of normal completion with no bearing on the cause. The measurement above
   replaces it.

2. **"They write nothing to stderr, which is why the stderr channel PR #47 adds
   is blind to them."** The first half is true; the causal half is not. The
   report is blind to them because **`ci-conformance.sh` never compares stderr
   at all** — by design, and its comment says so ("the two ports owe each other
   byte-identical stdout, exit code, call sequence and written tree, never
   identically phrased diagnostics"). These scenarios are silent because they
   *succeed*, not because a diagnostic went missing.

3. **`us021-state-unchanged` is not "other".** It is cause 1, and it is not
   silent — it writes stderr on both ports. Its separate classification came
   from the stderr, not from a different divergence.

4. **§5's invocation names the port `pwsh`.** `run-scenario.sh` accepts only
   `bash|powershell`; `pwsh` exits with `unknown port: pwsh`. Minor, but it
   costs a cycle.

5. **The estimate.** §4 says the answer "changes the estimate from a day to a
   week". It is nearer the day: two causes, three known sites, all with a
   remedy already prescribed in-repo.

**And the brief is right about the thing that matters most.** Causes 1 and 2
are **quirk 8**, already documented at `docs/10-windows-portability.md:93`,
already stated in AGENTS.md, and already fixed once in this repo — on
`sc008-deleted-managed-region-restored` (byte 138, bash=`2f`, pwsh=`5c`). The
comment recording that fix is at `RunState.psm1:109-120`, **twelve lines below
`Get-JiraRunStatePath`, in the same file, and the function above it still
leaks**. The reconcile path is careful in the same way elsewhere: lines 706-713
use the prescribed `LastIndexOfAny` cut, and 1118 and 1207 scrub `Split-Path`
with `-replace '\\', '/'`.

This is not a new defect. It is a known defect class in the sites the first
sweep missed, which is why a source guard — not just a fix — is what closes it.

---

## 4. What I did not do

Nothing is fixed. No source file is modified. This branch carries this report
and nothing else, per the instruction to answer §4 before touching anything.

The remedy is not in doubt (quirk 8's `LastIndexOfAny` cut for causes 1-2; the
port's own `Write` + literal backtick-n idiom for cause 3), but a fix wants a
guard that fails against the pre-fix file, and — per §6 — a green run on
`ci/windows-probe` before it counts. Neither is done.

## 5. One environment fact that cost nothing here but will cost you

**This machine had no `jq` at all** — not on PATH, not in Chocolatey, nowhere.
The Bash port, `run-scenario.sh` and `diagnose-windows-silent.sh` all need it,
and the failure mode is not obvious. I installed jq 1.8.2 via winget (the
official `jq-windows-amd64.exe`, the same native build Chocolatey ships) and
put it on PATH.

Verified it reproduces the runner's defining behaviour before trusting any
measurement above:

```
$ MSYS_NO_PATHCONV=1 jq . /tmp/tmp.QBaGOp9DBV
jq: error: Could not open file /tmp/tmp.QBaGOp9DBV: No such file or directory
$ MSYS_NO_PATHCONV=1 jq . "$(cygpath -m /tmp/tmp.QBaGOp9DBV)"
{ "a": 1 }
```

That is PR #47's cause class, live on this box — so the host is a faithful
match for `windows-latest` on the axis that matters.

## 6. How this was measured

Not with `diagnose-windows-silent.sh`, for the reason in §3.1. Each scenario was
run through **both** ports with `run-scenario.sh` and compared on the four
artifacts `ci-conformance.sh` actually compares — `stdout`, `exit`, `calls.log`,
and the written tree — with its two `base_url` normalisations applied first, so
the mock-port masking matches CI exactly.

Where `diff` reported a change it could not render, the comparison was repeated
with `cmp` plus a hex dump of the first differing byte — which is the only
reason cause 3 was seen at all. **A `diff`-only sweep would have folded those
two scenarios into "no visible difference" and lost them.** `ci-conformance.sh`
already knows this; its `byte_diff` exists for exactly this failure, and the
lesson generalises: on this corpus, never conclude from `diff` alone.

Roughly 90 seconds per scenario, both ports, on an idle machine.
