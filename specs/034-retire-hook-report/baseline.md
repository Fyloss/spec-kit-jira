# Implementation baseline — 034

Captured before any deletion, on `fix/remove-hooks-check` at `fa931ae`.
Everything here is measurement, not intent: it is what the feature is graded
against, and a stale number in it is worse than none.

---

## T001 — Pre-change counts

**Registry references in the shipped ports** (`git grep -cn 'extensions\.yml\|SPEC_KIT_JIRA_EXTENSIONS_YML' -- scripts/`):

| File | Occurrences |
| --- | --- |
| `scripts/bash/commands/config.sh` | 2 |
| `scripts/bash/commands/reconcile.sh` | 1 |
| `scripts/bash/hooks/register_hooks.sh` | 1 |
| `scripts/bash/lib/config.sh` | 1 |
| `scripts/powershell/commands/Config.psm1` | 1 |
| `scripts/powershell/commands/Reconcile.psm1` | 1 |
| `scripts/powershell/hooks/RegisterHooks.psm1` | 1 |
| **Total** | **8** |

FR-001 is satisfied when this total reaches zero outside the guard's own
explanatory comment.

**Suite sizes** (2026-08-30):

| Suite | Size |
| --- | --- |
| bats files | 274 |
| bats tests | 2688 (full run, PASSED, 940 s / 15 min 40 s) |
| Pester files | 206 |
| Conformance scenarios | 254 |

The conformance count is asserted mechanically by
`tests/bash/ci/test_conformance_no_cross_os_shard.bats` — retiring
`us9-hook-registration` (T053) means bumping that literal to 253.

---

## T002 — Staged pre-change tree, and the instrument check

```
PRE=/var/folders/kc/2vcqx6zn47zck5x67h25g1lh0000gn/T/tmp.Sn0sZdp3ca
```

Created with `git archive HEAD scripts | tar -x -C "$PRE"`.

**Instrument verified before use**: `grep -rc 'extensions\.yml' "$PRE/scripts"`
sums to **8** — matching T001 exactly. The staged tree is therefore readable and
contains the thing the guard must find. A guard whose search root reads nothing
passes vacuously, and that is indistinguishable from a guard that works.

> `$PRE` is a `mktemp -d` path and does not survive a reboot. Re-stage it with
> the same command if T007 or T052 has to be re-run later; the assertion is on
> the count, not on the path.

---

## T003 — `Get-CfgUnsupportedConstruct` disposition

**Resolved: it dies with its module.** No move is required.

Evidence — `git grep -n 'Get-CfgUnsupportedConstruct' -- scripts/ tests/` returns
exactly two hits, both inside the module being deleted:

- `scripts/powershell/hooks/RegisterHooks.psm1:182` — the definition
- `scripts/powershell/hooks/RegisterHooks.psm1:304` — its only call

It is **not** in the module's `Export-ModuleMember` list (which exports only
`Get-JiraHookHealth`, `Get-JiraHookEventList`, `Get-JiraHookCommandFor`,
`Get-JiraHookCommandList`, `Test-JiraHookEntryOwnership`,
`Test-JiraHookEntryIsLeftover`, `Get-JiraHookEntryShapeError`), so nothing
outside the module can reach it even dynamically.

The `Get-Cfg*` prefix is what made this worth checking: the name reads as
belonging to `lib/Config.psm1`, and a reader deleting the module in a hurry could
reasonably assume the config library depends on it. It does not.

Same finding for the module's other unexported helpers — `Get-JiraHookProp`,
`Test-JiraHookProp`, `New-JiraHookUnreadable`, `Get-JiraHookRepairHint` — all
private, all internal-only, all deleted with the module.

---

## T007 — Guard red-proof

Both guards run against `$PRE` (the pre-change port), with
`SPEC_KIT_JIRA_GUARD_ROOT` pointing the scan at it.

### Bash — `tests/bash/ci/test_no_registry_write.bats`

```
1..5
ok 1 the guard reads a non-empty tree — the instrument check
not ok 2 the registry is never named outside an explanatory comment (FR-001, SC-002)
not ok 3 the deleted reader has not come back under any name (FR-001)
not ok 4 no read verb is aimed at a registry-shaped path (FR-001)
not ok 5 the operator disable record has no reader or writer left (FR-005)
```

Instrument check green, all four substantive checks red. Correct.

### PowerShell — `tests/powershell/ci/NoRegistryWrite.Tests.ps1`

```
Tests Passed: 1, Failed: 3
```

Instrument check green, all three substantive checks red. Correct — **after a
repair described below**.

### An inert test found and removed, not kept for symmetry

The first PowerShell run reported **Passed: 2, Failed: 3**. The unexpected pass
was `aims no read verb at a registry-shaped path`, the mirror of the Bash port's
test 4 — and a guard that passes against the pre-change tree is the one result a
red-proof must never produce.

The cause is not a missing case in the regex; it is the port's spelling. Bash
names the registry and reads it on the same line, so a line-level regex fires.
PowerShell resolves the path into `$extPath` on one line and hands it to
`Get-JiraHookHealth` on another, which reads it through `$Path`. **No single line
ever carries both a read verb and the literal**, so no line-level regex can fire
there however it is written.

It was **deleted**, with the reason recorded in the file. Rewriting it to chase
the variable names would only re-check what the absence test already proves, and
shipping it would have added a test that can never be red — the exact defect
class this whole phase exists to prevent, and one this repository has shipped
before.

This is why T007 is a task rather than a step inside T005/T006. Writing the guard
and running it are not the same act, and only the second one tells you anything.


---

## T051 — `test_registry_never_written` disposition: DELETED

Both suites (10 bash tests + 8 Pester) are removed rather than narrowed.

Their claim was behavioural: the registry is byte-identical after every
documented state. Two reasons that claim no longer needs its own tests:

1. **The absence guard subsumes it.** A path the port cannot name cannot be
   written. `test_no_registry_write.bats` proves the tokens occur nowhere in
   `scripts/` outside an explanatory comment, which is a stronger statement than
   "these particular runs did not write it".
2. **They depended on `SPEC_KIT_JIRA_EXTENSIONS_YML`**, the override retired by
   this feature. Keeping them would have meant keeping a dead environment
   variable alive in the port purely to feed its own tests.

Recorded here because T051 required the decision to be explicit rather than a
silent deletion.

---

## T021 — `test_hook_resilience` needed editing after all

T021 said: if this suite needs editing, stop and report. It did, and this is the
report.

**The FR-007 behaviour is untouched.** All seven surviving tests pass, including
the two that matter: one actionable warning in hook context, and exit downgraded
to 0 so the host command is unaffected.

What needed editing was not behaviour:

- **`setup()` sourced the deleted module.** Every test in the file died before
  running, with `register_hooks.sh: No such file or directory`. A harness
  dependency, not a regression — removing the `source` line restored all of them.
- **Three tests had retired behaviour as their subject** and were deleted with
  it: `a recorded event is inert at dispatch` and `the guard is honoured whatever
  the registry currently says` (both the dispatch hold, removed by T041/T042),
  and `no run of any kind brings the registry into existence` (now true by
  construction and covered by the absence guard).

So the deletion did **not** reach further than the spec allows — the three
deleted tests are squarely inside 034's scope. But T021 was written to make this
a decision rather than a reflex, so it is written down.

---

## T074 — SC-006, and a correction to the check itself

**Result: satisfied.** `git grep -nE 'enable-hook|hook_health|held_disabled|hooks\.disabled|SPEC_KIT_JIRA_EXTENSIONS_YML'`
over `scripts/ docs/ commands/ templates/ README.md INSTALL.md` returns two hits,
both explanatory comments of the form *"It used to have a second purpose — the
`hooks.disabled` enum of …"*. That is history for a reader, not a claim about
whether the hooks are registered.

**The task's own check was wrong**, and this is the correction. T074 specified
the grep over `tests/` as well, and demanded it return nothing. That is
unachievable by construction: the guard's token list and every assertion that a
field is now *absent* must name the retired tokens. A check that cannot tell
"the claim survives" from "a test proves the claim is gone" would fail forever.

SC-006 binds what SHIPS. Scoped there, it holds.

---

## A pre-existing test defect, exposed but not caused by 034

`tests/powershell/commands/Reconcile.Target.Tests.ps1` → *"a valid spec.md run
behaves exactly as before this feature (§5 T7)"* asserts the summary carries no
`warnings` key.

**It fails when its own file runs alone, and passes only as part of the full
Pester suite** — a cross-file order dependency. Proven not to be 034's doing by
checking out `HEAD` into a clean `git worktree` and running the test there: it
fails on the pre-change tree too.

Two fixes were tried and neither worked, which is what localises the cause:

- a per-test `Import-Module -Force` of `Reconcile.psm1` in `BeforeEach`, the
  pattern `Config.Degraded.Tests.ps1` uses for exactly this hazard — no effect,
  so the state is not `$script:`-scoped in that module;
- moving 034's replacement test to the end of the block — no effect, so the
  replacement is not the perturbation either.

The state therefore comes from a **different file** that runs earlier in the
full suite. Fixing that is separate work: it needs the producing file
identified, and it predates this feature.

What 034 changed is only the file's visibility. The test it replaced
(`a disabled event silences even the rejected-target refusal`) threw on a
missing cmdlet at its first line and did no work at all, so a per-file run never
got far enough to expose the dependency.

---

## Final verification (clean runs, nothing edited underneath them)

| Suite | Result |
| --- | --- |
| `tests/run-bash.sh` | **271 files, 2616 tests, 0 failures — PASSED** |
| `tests/conformance/ci-conformance.sh` | **exit 0, 0 divergences** (253 scenarios) |
| `Invoke-Pester tests/powershell` | **1957 passed, 0 failed** |
| `shellcheck -x -P scripts/bash` | clean |
| `actionlint` | clean |

Test count moved 2688 → 2616 in bats: 72 fewer, matching the suites retired with
the behaviour they covered.

**T075 is delegated to CI**, not skipped. `kcov` is present locally but a full
coverage run over this suite costs hours, and the 80% gate is a CI gate by
Constitution XIII's own wording. It is the one remaining check that could still
fail: this feature deletes well-tested code *and its tests*, so the net direction
of the percentage is not self-evident.

**T080 and T081 cannot be performed here.** The live integration run on the
release commit and the dogfood record against a real Jira instance both need
credentials and a real site. They are Constitution XII shipping gates and remain
open, deliberately, rather than being marked done without evidence.
