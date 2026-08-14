# Contract — how the lifecycle event reaches the run

Covers spec FR-010, FR-011, FR-012. The governing rule: **the event is stated by the caller, never
inferred.** The bridge does not guess which lifecycle step it is running for, and a run that was told
nothing behaves exactly as it does today.

## 1. The closed event set

Six after-events, plus one before-event that fires a different command:

| Host command | Hook | Command fired |
| --- | --- | --- |
| `/speckit.specify` | `before_specify` | `speckit.jira.feature` |
| `/speckit.specify` | `after_specify` | `speckit.jira.reconcile` |
| `/speckit.clarify` | `after_clarify` | `speckit.jira.reconcile` |
| `/speckit.plan` | `after_plan` | `speckit.jira.reconcile` |
| `/speckit.tasks` | `after_tasks` | `speckit.jira.reconcile` |
| `/speckit.implement` | `after_implement` | `speckit.jira.reconcile` |
| `/speckit.analyze` | `after_analyze` | `speckit.jira.reconcile` |

The set is closed. `extension.yml`'s own comment states it: "These seven events are the complete set…
adding an eighth requires a spec (Principle XV)." The six after-event names are the only accepted keys of a
role's lifecycle mapping (`role-lifecycle-config.md` §2).

## 2. The mechanism

`SPEC_KIT_JIRA_HOOK_EVENT`, read by `_reconcile_hook_event` (`commands/reconcile.sh:63`) and its PowerShell
twin. Both ports already read it; nothing shipped currently sets it (research R5).

**No new flag is introduced** (spec FR-025). The variable is the one door.

The agent-facing procedure `commands/speckit.jira.reconcile.md` becomes normative about it, in the same
register as its existing target rule:

> **You MUST set `SPEC_KIT_JIRA_HOOK_EVENT` to the event you are performing**, from the table in §1, before
> invoking the bridge. It is the only thing that tells the bridge which lifecycle step this run belongs to;
> without it the run mirrors content and considers no board position. Set it for the hook that fired — never
> for the host command you would like to have fired.

The same document's Flags section is corrected in the same change to list `--force`, which `lib/cli.sh`
has accepted since 021 and which the procedure never documented (spec FR-040).

## 3. Placement — the dispatch guard stays first

Unchanged from today, and load-bearing:

```text
0  · dispatch guard        reads the event; a disabled event exits 0 SILENTLY
                           — before any prerequisite check, config read, or network call
0a · spec file readable?   exit 1
0b · basename == spec.md?  exit 1, zero requests (017 target guard)
1  · STATE PHASE           the event is now one of the recorded inputs (run-state-v2.md)
2  · …
```

`_reconcile_is_held` (`commands/reconcile.sh:78`) already reads the event first and returns silently for a
disabled one, with no warning — "a warning on every single lifecycle command for an event the operator
deliberately turned off is precisely the noise the design forbids" (`docs/03-lifecycle-hooks.md`). That
ordering does not move (FR-012).

## 4. A run with no event

A direct invocation, a script, or an agent that did not set the variable:

| Consequence | Mechanism |
| --- | --- |
| No declared step for any role | `target` resolves to `""` (`commands/reconcile.sh:1490`) |
| No drift rule evaluated | `plan_lifecycle`'s `[[ -n "${target}" ]]` guard (`plan_apply.sh:1121`) is false |
| No availability read | nothing reaches the due set (`transition-resolution.md` §1) |
| No `counts.transitioned` key | its presence condition is unmet (`data-model.md` §5) |
| **Output byte-identical to the same invocation before this feature** | all of the above |

That last row is the assertion, not a description of one: the corpus runs a no-event scenario through the
pre-change and post-change bridge and diffs stdout, stderr, exit code, the written tree, and the recorded
call log.

## 5. Invariants

| # | Invariant |
| --- | --- |
| E1 | The event is never inferred — not from the argument path, not from which files changed, not from the recorded run state. A run told nothing has no event. |
| E2 | An unrecognised event value is treated as no event at all: no role can declare a step for it, so nothing is asked of the tracker and nothing is warned about. It is never a config refusal — the caller's vocabulary is not the team's configuration. |
| E3 | A disabled event exits `0` silently, before any config read or network call, unchanged. |
| E4 | The event reaches the run-state document verbatim (`run-state-v2.md` §2) and reaches no other recorded artefact. |
| E5 | The event never appears in a ticket, a description, a comment, or any Jira payload. It selects a status name; it is not itself mirrored. |

## 6. Scenario coverage

| Case | Assertion |
| --- | --- |
| Each of the six after-events, dispatched with a per-role mapping declaring a different step for each | Each run aims at its own event's step; six distinct outcomes |
| No event set | Byte-identical to the pre-change run on every channel (§4) |
| Event set to a name outside the closed set | Same as no event: zero availability reads, zero warnings (E2) |
| Disabled event, with a matching run state recorded | Exit `0` silently, no config read, no state read — today's behaviour exactly |
| Event set, project declares no mapping at all | Zero availability reads, zero moves, no `counts.transitioned` key |
| Event set, `--dry-run` | The preview reports the moves it would make; the state document is neither read nor written |
| Both ports, every case above | Byte-identical stdout, exit code, written tree, and recorded call sequence |
