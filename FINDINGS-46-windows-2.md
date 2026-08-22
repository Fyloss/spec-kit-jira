# Findings 2 — issue #46, B and D worked on a real Windows machine

Interim report, written 2026-08-22 on Windows 11 (MINGW64, bash 4.4.23,
pwsh 7, jq 1.8.2 native), branch `fix/windows-remaining-divergences`.

Companion to `FINDINGS-46-windows.md`, which answered §4. This one reports the
fixes, and — more usefully — the two places where the handoff's estimate of the
work was wrong.

**Read §1 first. Category B is NOT closed.**

---

## 1. Status, plainly

| | scope | state |
|---|---|---|
| **D1** `state_file` | `lib/RunState.psm1:53-55` | **done**, guard red→green |
| **D2** `seed_material` | `commands/Feature.psm1:582` | **done**, guard red→green |
| **D3** trailing CRLF | `commands/Reconcile.psm1:2086/2090/2091` | **done**, guard red→green |
| **B** E2BIG | **twelve** sites | **2 of 12 — INCOMPLETE** |

Every guard below was run against the pre-fix file and **seen to fail**, per
§13. None was inert.

What is NOT done, and must not be assumed:

- Category B. `us023-sixty-stories-due` still fails.
- `tests/run-bash.sh` in full, and `ci-conformance.sh`.
- `shellcheck` — **not installed on this machine**, so it has not run at all.
- Any run on `ci/windows-probe`. Nothing here is proven until that is green.

## 2. Category B is twelve sites, not one

§12 gives B as `lib/output.sh:69`, *caller in the parse path* — singular.
`output.sh:69` is only where the error surfaces: it is the line inside the
CRLF wrapper that execs jq, so every E2BIG in the port reports that line
whatever the caller. The callers are twelve.

**Two are fixed** — `engine/parse.sh:757` (`stories`) and
`engine/interchange.sh:154` (`parse`). The parse-stage failure is genuinely
gone: exit went 4 → 2 and "the specification could not be parsed" no longer
appears, and `parse_spec`'s output is byte-identical on a 10-story spec (6843
bytes before and after).

**Ten remain**, found by sweeping for a document-sized payload reaching argv:

```
reconcile.sh:1042 1054 1092 1141 1157 1233 1247 1277
seed.sh:610 625
```

A jq shim recorded the live offending argument: **43475 bytes**, beginning
`{"epic":{"description":{"blocks":[` — the neutral document, passed as
`--argjson doc "${doc_for_write}"` at 1233, 1247 and 1277, and as
`--argjson tp "${tasks_parsed}"` at the others.

### Why the guard built for this defect never caught it

This is the part worth keeping. `tests/bash/sink/test_argv_size.bats` is a
portable, cause-level detector written for exactly this failure, and it passes.
Its threshold is Linux's `MAX_ARG_STRLEN`, 131072. **Windows' cap is
CreateProcess's command line and it is four times tighter.** Measured here:

```
 8000 bytes: OK      32000 bytes: OK      33000 bytes: E2BIG
16000 bytes: OK      32700 bytes: OK      40000 bytes: E2BIG
```

A story costs ~660 bytes (a 10-story spec yields 6607 bytes of `stories`), so
the payload crosses Windows' cap at ~50 stories and Linux's at ~200. **Every
scenario between those two bounds fails on `windows-latest` and passes
everywhere else** — which is precisely the four category-B scenarios, and
precisely why a 100-story Linux test proves nothing about them.

The right fix is therefore not a list of call sites. It is
`HELPER_ARGV_SIZE_LIMIT` in `tests/bash/helpers/argv_size.bash`, pinned at
131072 by `tests/bash/ci/test_argv_size_helper.bats:60`, recalibrated to the
tightest supported host. That single constant turns the two existing
behavioural tests into a guard covering the whole class. The helper's own
header already claims the verdict is "identical on every host — including
macOS"; with a Linux-only threshold that claim does not hold, and Windows is
the host it silently exempts.

The guard committed here names only the two sites it pins. It is deliberately
narrow and it is the wrong shape for twelve — say so rather than trust it.

## 3. What was fixed, and the one test that had to change

D1 and D2 are the same defect: `Join-Path` spelling an operator-facing path.
D3 is independent: `[Console]::Out.WriteLine` taking its terminator from
`[Environment]::NewLine`. All three are described in their commit messages with
the measured bytes; not repeated here.

One thing does need flagging, because it is a test that was **weakened in
appearance and corrected in fact**:

`tests/powershell/lib/RunState.Tests.ps1:241` asserted

```powershell
$want = Join-Path (Join-Path $env:JIRA_CONFIG_DIR 'state') '021-example.json'
```

— the function compared against the very primitive whose renormalisation is
D1. A tautology: it passed on Windows precisely because both sides were wrong
in the same way, while `state_file` reached stdout with backslashes in nine
scenarios. It now asserts the Bash twin's spelling. This is a corrected
assertion, not a relaxed one, but it should be reviewed as such.

## 4. Two traps in the tooling, independent of #46

**`tests/conformance/diagnose-windows-silent.sh` cannot fire.** Its hook guards
on

```sh
case "$0" in
  */spec-kit-jira.sh) ;;
  *) return 0 …
```

but inside a file sourced through `BASH_ENV`, `$0` is **`bash`** — not the
script path. Verified directly on this host:

```
$ BASH_ENV=h.sh bash inner.sh
HOOK FIRED, dollar-zero=[bash]
```

The guard can never match, so the trace file is always empty and the script
reports *"NO TRACE — the port never started, or BASH_ENV was not honoured"* for
every scenario. `BASH_ENV` itself works; the guard is what is wrong. Fix it (a
marker variable set by the caller works) or delete the script — as it stands it
is a trap that costs the next agent a cycle to discover.

**Instrumenting this corpus on MSYS has a cost trap.** My first argument-size
shim ran `printf | wc -c` plus a `cut` per argument. On MSYS, where fork is
emulated, that made a 60-story scenario unfinishable — killed after 15 minutes
having produced nothing. Rewritten with `${#a}` and `printf '%.70s'`, both
builtins, no subprocess, it completes. `tests/bash/helpers/argv_size_measure.sh`
already spawns `printf | wc -c` per argument for the same job; it is fine at
the scale it runs today, but it is the same shape.

## 5. A defect in the test harness, unrelated to #46

`tests/conformance/mock-jira/Mock.psm1` passed unquoted paths to
`Start-Process -ArgumentList`, which joins the array with spaces and quotes
nothing. A path containing a space — `C:\Users\First Last\…`, the ordinary
shape on a developer machine — arrives as two arguments and every parameter
after it binds to the wrong value:

```
mock-server.ps1: Cannot process argument transformation on parameter 'Port'.
Cannot convert value "THIBAUD\AppData\Local\Temp\x\calls.log" to type "System.Int32"
```

followed by `mock process exited before ready` from **every mock-backed Pester
test**. GitHub's runner is `C:\Users\runneradmin`, no space anywhere, so this
has never fired in CI and reads as a broken machine rather than a broken
harness.

Fixed here: `Feature.Designators.Tests.ps1` went from 7 passed / 11 failed to
18/18, and `RunState.Tests.ps1`'s S6 dry-run case came back green with it.
Committed separately — move it to its own branch if you would rather.

## 6. Environment, for whoever picks this up

This machine had **neither `jq`, nor `bats`, nor `Pester`** installed. All
three were needed and all three are now present:

- jq 1.8.2 via winget — the official `jq-windows-amd64.exe`, the native build
  Chocolatey also ships. Verified it reproduces the runner's defining
  behaviour (`Could not open /tmp/…`, fixed by `cygpath -m`) before any
  measurement was trusted.
- bats 1.13.0 via npm.
- Pester 6.1.0 via `Install-Module`.

`shellcheck` is still absent and was not run.

Timings on this host, both ports, idle: ~90 s for an ordinary conformance
scenario; a 10-story `parse_spec` takes ~52 s; the four category-B scenarios
are far slower still and one verification cycle over them costs ~20 minutes.

## 7. What the next session should do

1. Convert the ten remaining sites to `json_build`.
2. Recalibrate `HELPER_ARGV_SIZE_LIMIT` to the tightest supported host and
   update the assertion at `test_argv_size_helper.bats:60`, so the existing
   behavioural tests cover the class instead of a hand-kept list.
3. Re-run the four category-B scenarios. **`us023-sixty-stories-due` exiting 0
   is the bar** — not a green source guard, which is what I mistook for a fix
   once already in this session.
4. Re-run the sixteen D scenarios cross-port. **Compare with `cmp`, never
   `diff` alone** — D3 renders identically under `diff`.
5. `tests/run-bash.sh`, `ci-conformance.sh`, `shellcheck`.
6. Only then `git push --force origin HEAD:ci/windows-probe`, and read the
   uploaded artifact rather than the annotation.
