# Handoff — issue #46, the Bash port on Windows

**Read this first.** It is written for an agent starting on a Windows machine
with no history of the work so far. It is not documentation; it is a state
transfer, and it should be deleted with this branch.

Written 2026-08-22 from the macOS side, where the diagnosis up to this point was
done.

---

## 1. Where you are

Branch `ci/windows-d-diagnostic`, based on `78b5d06`, the head of **PR #47**
(open, not merged). So this tree already contains every fix described below —
do not go looking for defects that are already gone.

- **PR #45** (merged) made `Unit suites (windows-latest)` green for the first
  time since feature 015, and sharded the conformance corpus per OS.
- **PR #47** (open) fixes the dominant Windows cause. **Your work is what it
  deliberately leaves behind.**
- **Issue #46** carries the running measurements. Read its comments in order.

## 2. The measured state

231 scenarios in the corpus. On `windows-latest`, measured across all four
shards (CI run 32530470422, commit `78b5d06`):

| cause | before #47 | now | |
|---|---|---|---|
| **A1** `jq … /dev/fd/N: Could not open` | 103 | **0** | fixed |
| **A2** `jq … /tmp/tmp.X: Could not open` | 12 | **0** | fixed |
| **C** `seed: no seeded-not-bound state was found` | 12 | **0** | fell out with A1 |
| **B** `jq: Argument list too long` | 4 | 4 | **not yours — see §5** |
| **D** no bash stderr at all | 11 | **16** | **yours** |
| other | 2 | 1 | `us021-state-unchanged` |
| **total** | **144** | **21** | −85% |

Zero scenarios diverge that did not diverge before.

**Do not trust any other number you find.** Earlier comments in #46 quote 89 and
144 and 13; the first two were read off a **truncated GitHub annotation** and
the third off three shards out of four. Only the artifact, all four shards, is
sound.

## 3. What was already solved, and the rule it produced

The native `jq.exe` on PATH under git-bash resolves **no MSYS path** — neither
`/dev/fd/N` from a `<(…)` process substitution nor `/tmp/tmp.X` from `mktemp`.
`lib/output.sh` runs jq under `MSYS_NO_PATHCONV=1`, so MSYS translates nothing
on our behalf and the translation has to be explicit.

The rule now has exactly one home: **`json_path_arg`** in `scripts/bash/lib/output.sh`.
`cygpath` appears nowhere else in the port except `_jira_curl_path` in
`sink/jira/client.sh`, and a guard pins that.

Seven call sites were migrated. Six guards in
`tests/bash/ci/test_jq_path_spelling.bats` keep them migrated.

**If your diagnosis leads you to add a jq call that opens a file, wrap the path
in `json_path_arg` or a guard will fail — correctly.**

## 4. Your job — category D, the sixteen silent scenarios

```
us022-checklist-crlf            us2-field-defaults-option-question
us022-checklist-two-phases      us2-field-defaults-question
us022-checklist-unchanged-rerun us2-preserve-human-prefix
us023-idempotent-rerun          us29-feature-designator-reuse-yes-silent
us027-refuse-exists             us29-feature-mention-with-designator
us027-three-url-forms           us29-feature-reuse-yes-auto-accept
us028-template-form-ac          us3-markdown-idempotent
us4-migration-clean             us5-plan-on-parent
```

They write **nothing** to stderr, which is why the stderr channel PR #47 adds to
the divergence report is already blind to them.

**This section's premise is WRONG — see the ADDENDUM, §11.** Nothing stops.
The scenarios complete and exit 0 on both ports; the divergence is in stdout
CONTENT. The script this section used to send you to has been deleted, and
`docs/10-windows-portability.md` quirk 9 records why it could never have worked.
Go to §11.

**The first question to answer, before any fixing:** do the sixteen stop at the
**same** `file:line` or at several? A1 was 103 scenarios and one cause. C looked
like an independent defect and was merely downstream of A1. Either shape is
plausible here, and the answer changes the estimate from a day to a week.

To drive one scenario by hand:

```bash
bash tests/conformance/run-scenario.sh \
  tests/conformance/scenarios/us022-checklist-crlf.json bash /tmp/out
cat /tmp/out/exit /tmp/out/stderr; head -c 300 /tmp/out/stdout
```

## 5. What is NOT yours

**Category B (E2BIG), 4 scenarios** — `us021-prefetch-count-61`, `-101`,
`-61-deleted`, `us023-sixty-stories-due`. All four fail identically:

```
output.sh: line 69: jq: Argument list too long
reconcile: the specification could not be parsed (zero writes)
```

Already diagnosed, being fixed from the macOS side on a separate branch. Leave
it alone or you will collide. If your D work lands in the same files, say so and
we rebase.

## 6. Doctrine — non-negotiable

- **Never diagnose or fix a Windows divergence by emulation.** This repo tried:
  a stub jq that appended CR the way jq.exe does. The emulation passed the whole
  corpus while the real runner failed fifteen scenarios. *A model of Windows is
  not Windows.* You are on real Windows — that is the entire point of your being
  there.
- **A platform fix is unproven without a green run on the real runner.** Your
  machine accelerates diagnosis; it does not replace `windows-conformance.yml`.
  Read `docs/10-windows-portability.md` before touching either port.
- **Write the failing test first** (project policy). For a Windows-only defect,
  the corpus on the probe *is* that test — but a source guard you add must be
  run against the pre-fix file (`git show <commit>:<path>`) and seen to fail.
  Two of the three guards written for #47 were **inert on their first version**
  and would have shipped green forever.
- **`trash`, never `rm`**, for your own file deletions. Code in the repo uses
  `rm -f` for temp files; that is fine and idiomatic.
- English everywhere: code, comments, commits, branch names. Conventional
  commits.

## 7. Dead ends already explored — do not repeat these

- **Joining shell logical lines by quote parity** (to catch a jq path operand
  inside a multi-line filter): unusable. An apostrophe in any comment — *"the
  caller's own bytes"* — desyncs parity for the rest of the file. Measured with
  the buffer still open thirty lines earlier.
- **A runtime guard** using a recording `cygpath` plus a `jq` shim: it cannot
  separate the port's jq calls from the mock's inside one scenario.
  `MOCK_CONFIG_PATH` is not exported that far, and `JIRA_PATH_STYLE` injected
  through `SPEC_KIT_JIRA_HARNESS_ENV` reaches the mock too.
- **Sweeping for jq's file-reading flags** (`--slurpfile`, `--rawfile`): misses
  the positional form `jq -Rs '…' "${f}"`.
- **Sweeping for mktemp variables on jq lines**: misses a filter whose `jq`
  token is eleven lines above its own operand.
- What *did* work when reading failed: **a shim on PATH that logs argv** during a
  real scenario run.

## 8. Environment facts that cost a probe cycle each to learn

- `run-scenario.sh` **unsets every ambient `JIRA_*` / `SPEC_KIT_JIRA_*`
  variable** before applying a scenario's own `env`. Use
  `SPEC_KIT_JIRA_HARNESS_ENV` (newline-separated `KEY=VALUE`) to get anything
  through.
- `SHELLOPTS=xtrace` **cannot** be injected that way: the harness `export`s the
  pair, `SHELLOPTS` is readonly in a running shell, and the failure takes the
  harness down under `set -e`. `BASH_ENV` is the way in.
- The dispatcher runs under **`set -euo pipefail`** (`scripts/bash/spec-kit-jira.sh`).
  A cleanup line placed after a function's last command silently becomes its
  return status — that exact mistake was made and caught in review on this
  branch; see `tests/bash/commands/test_reconcile_notes_fail_closed.bats`.
- The runner's jq is `/c/ProgramData/Chocolatey/bin/jq` — a **native Windows
  binary**. Match it locally.
- A GitHub check-run **annotation is truncated as a whole**. Always read the
  uploaded artifact (`conformance-divergences-*`) instead.
- Windows runners die: *"The hosted runner lost communication with the server"*
  cost a shard on roughly half the runs. A step with `conclusion: null` was
  killed, not failed. One retry maximum, then work with what you have.
- The whole corpus on `windows-latest` is ~2 h 44 unsharded, 43–54 min per shard
  across four.

## 9. Before you claim it is done

```bash
tests/run-bash.sh                       # full suite; run it on an IDLE machine
bash tests/conformance/ci-conformance.sh
shellcheck -x -P scripts/bash $(find scripts/bash -name '*.sh')
```

A loaded machine produces `status 134` (SIGABRT) inside pwsh on tests unrelated
to your change — six files failed that way here at load average 53. Re-run cold
before believing a red.

Then push to `ci/windows-probe` (force-push is the documented way to drive it)
and read the artifact, not the annotation.

## 10. How to report back

Do not paste the report into a chat — it is long and it will be retyped by
hand. Write it to a file and push it:

Write your measurements to `FINDINGS-46-windows.md` and, in your own words:

1. **The answer to §4** — same `file:line` for all sixteen, or several? Give the
   distinct stopping points and how many scenarios each accounts for.
2. What you can already rule out, and what you cannot.
3. Anything in this brief that turned out to be **wrong** — say so plainly, it
   was written from the other side of the machine boundary and some of it is
   inference.

Commit it to `ci/windows-d-diagnostic` and push. That branch is the exchange
channel; the macOS side reads it with `git fetch`.

```bash
git add FINDINGS-46-windows.md
git commit -m "docs: report where the silent Windows failures stop (#46)"
git push origin ci/windows-d-diagnostic
```

---

# ADDENDUM — 2026-08-22, after PR #47 merged

Written after reading `FINDINGS-46-windows.md`. **Read that file too**; it
corrects §4 of this brief and it is right.

## 11. What changed

- **PR #47 is merged** (`385147e` on `main`). This branch is cut from that, so
  causes A1/A2/C are gone from the tree.
- **§4 of this brief was wrong.** Nothing "stops". All sixteen scenarios run to
  completion and exit 0 on both ports. The divergence is in stdout CONTENT, and
  it is the **PowerShell** port's, not the Bash port's. I verified this against
  the CI artifact I already had: `us022-checklist-crlf` is `bash=2f pwsh=5c`
  at byte 206, sizes 236/239 — comparable sizes, not 1-vs-2877. I had
  classified by "no stderr" and never looked at the sizes.
- `diagnose-windows-silent.sh` answered a question these scenarios do not pose,
  and its `$0` guard could never match on the bash MSYS ships anyway. **Deleted.**
  The durable part — BASH_ENV works, `$0` is the shell on bash <= 4.4, scope such
  a hook with a marker variable — is now quirk 9 in
  `docs/10-windows-portability.md`.

## 12. The work, in order

**B first** — it is bash-side and touches `lib/output.sh`, which #47 just
changed; doing it first keeps the two apart.

| | cause | site | scenarios |
|---|---|---|---|
| B | `jq: Argument list too long` | `lib/output.sh:69`, caller in the parse path | 4 |
| D1 | `\` vs `/` in `state_file` | `lib/RunState.psm1:53-55` | 9 (+`us021-state-unchanged`) |
| D2 | `\` vs `/` in `seed_material` | `commands/Feature.psm1:582` | 5 |
| D3 | trailing CRLF on stdout | `commands/Reconcile.psm1:2086`, and 2090-2091 uncovered | 2 |

## 13. Guard specification — the part that must not be skipped

Six guards already exist in `tests/bash/ci/test_jq_path_spelling.bats`. Match
their shape, and obey the one rule that produced them:

> **Run every guard against the pre-fix file and SEE IT FAIL** —
> `git show 385147e:<path> > /tmp/before` then run the rule over `/tmp/before`.
> Two of #47's three guards were inert on their first version and would have
> shipped green forever. A guard that has never fired guards nothing.

**D1 and D2 — reproduce OFF Windows.** `Join-Path` does not merely re-spell, it
**normalises**, and that is visible on any host. The proven trick from #47: give
the config dir a **trailing separator**. `Join-Path` collapses it, string
concatenation keeps it, so the two disagree on macOS and Linux too. That makes
the regression test cross-platform rather than a Windows-only claim nobody can
run. Mirror-direction assertions (a `\`-spelled input coming back with `/`) also
work — that is how #45 tested the target guard.

**D3 — source guard.** `Environment.NewLine` is LF on POSIX, so this one does
not reproduce in mirror. Pin it lexically instead: `[Console]::Out.WriteLine`
must not appear in `scripts/powershell/` at all; the port's own idiom is
`[Console]::Out.Write($x + "`n")`. There are exactly three occurrences today and
all three are the defect, so the guard is red before and silent after by
construction. Fix 2090-2091 as well — no scenario covers them, and they are the
same call.

**B.** Assert the offending call site goes through `json_build` (or a temp file)
rather than argv. Prove it red the same way.

## 14. Sequence to close it

1. Fix + guard, verified red-then-green locally.
2. `tests/run-bash.sh` and `bash tests/conformance/ci-conformance.sh` — on an
   IDLE machine (see §9).
3. Run the affected scenarios through `run-scenario.sh` on Windows — ~90s each,
   both ports, per `FINDINGS-46-windows.md` §6. **Compare with `cmp`, never
   `diff` alone**: cause 3 renders identically under `diff` and would be lost.
4. Only then `git push --force origin HEAD:ci/windows-probe`, and read the
   uploaded artifact rather than the annotation.

## 15. Report back the same way

`FINDINGS-46-windows.md` worked. Append to it, or start a second file, and push
to this branch — the macOS side reads it with `git fetch`. Keep saying plainly
what in these instructions turns out to be wrong; §3 of the findings is the most
useful part of this whole exchange.
