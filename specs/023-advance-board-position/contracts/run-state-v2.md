# Contract — the run-state document, version 2

Covers spec FR-013, FR-014, FR-015, FR-016. Extends 021's
[`contracts/run-state.md`](../../021-reconcile-performance/contracts/run-state.md), which stays in force
for everything this document does not change.

The governing rule is 021's and is unchanged: **every doubt fails open to a full reconcile.** The
short-circuit may only ever skip work after a proven-complete prior run; it may never mask a failure, and
now, may never mask an unhonoured lifecycle event.

## 1. What changes

| # | Change | Why |
| --- | --- | --- |
| C1 | `schema` becomes `2` | The *set* of recorded inputs changed. 021's own rule bumps the shape version and invalidates every existing document; invariant S7 already guarantees an upgrade produces a full reconcile. |
| C2 | New field `hook_event` (string, `""` when none) | Two consecutive lifecycle events over byte-identical files must both reach the board (FR-013). Recorded verbatim, exactly as `on_drift` and `field_values` are — it is a run input, not a file. |
| C3 | New `inputs` member `plan.md` | It is read on every run and spliced onto the parent's description (`commands/reconcile.sh:861–869`), so a change to it must invalidate. Same "present when the file exists, key omitted otherwise" rule as `tasks.md`. |

Nothing else moves. The location, the self-ignoring `.gitignore`, the atomic write, the
`git hash-object --no-filters` primitive, and the placement of the state phase before routing and before
config are all unchanged.

## 2. The document

```json
{"base_url":"…","email":"…","extension_version":"0.15.0","field_values":"",
 "hook_event":"after_plan","inputs":{"plan.md":"…","spec.md":"…","tasks.md":"…",
 ".specify/jira/config.yml":"…"},"on_drift":"abort","schema":2}
```

`run_state_compose` gains the event as an **explicit argument**, never reading
`SPEC_KIT_JIRA_HOOK_EVENT` itself — `lib/run_state.sh` stays a pure function of its arguments, the same
discipline 021 states for `base_url`/`email`/`on_drift`/`field_values`.

```
run_state_compose <spec-path> <base-url> <email> <on-drift> <hook-event> <field-values>
run_state_matches <spec-path> <base-url> <email> <on-drift> <hook-event> <field-values>
run_state_record  <spec-path> <base-url> <email> <on-drift> <hook-event> <field-values>
```

**Matching stays byte-equality** of a freshly composed document against the recorded one. There is no
per-field match, no partial match, and no repair of a stale document.

## 3. Decision table

Rows in **bold** are new or changed; every other row is 021's, unchanged.

| Condition | Outcome |
| --- | --- |
| `--force` given | Full reconcile. The recorded document is not read. |
| `--dry-run` given | Full reconcile. The document is neither read nor written. |
| No state file | Full reconcile. |
| State file unreadable, not valid JSON, or missing a required field | Full reconcile. |
| **`schema` is not `2`** (including every document written by an earlier release) | **Full reconcile.** |
| `extension_version` differs | Full reconcile. |
| Any input hash differs, or an input appeared/disappeared | Full reconcile. |
| **`plan.md` appeared, disappeared, or changed** | **Full reconcile** — closes the defect where a `/speckit.plan` reached no ticket at all. |
| `base_url`, `email`, `on_drift`, or `field_values` differs | Full reconcile. |
| **`hook_event` differs** | **Full reconcile** — the event has not been honoured against these inputs. |
| Byte-equal | **SHORT-CIRCUIT** |

Short-circuit behaviour is unchanged: exit `0`, zero requests, zero writes, zero secret-store
consultations, one summary line naming the short-circuit and the file that recorded it.

Recording conditions are unchanged: a real, non-preview run that applied every planned action, emitted no
warning, and has no pending confirmation. **A run that raised an unreachable-step, ambiguous-move or
gated-move warning therefore records nothing** — which is the correct outcome, because the next run must
reconsider that ticket rather than skip it.

## 4. The one event that loses its short-circuit

The state phase runs **before** the config phase, deliberately (021 §2), so the composer cannot know whether
any role declares a step for this event — only the raw event name is available to it. A differing event
therefore forces a full reconcile even for a project that declares nothing.

Enumerated against the six events, after C3 adds `plan.md`:

| Event | Changes a hashed input? | Cost of C2 |
| --- | --- | --- |
| `after_specify` | `spec.md` | none — already invalidated |
| `after_clarify` | `spec.md` | none — already invalidated |
| `after_plan` | `plan.md` (newly hashed) | none — now invalidated by hash |
| `after_tasks` | `tasks.md` | none — already invalidated |
| `after_implement` | `tasks.md` | none — already invalidated |
| `after_analyze` | nothing | **one full reconcile**, once per input state |

A repeat of the **same** event over unchanged inputs still short-circuits, because the recorded
`hook_event` matches.

This narrows spec FR-016, which asks for a short-circuit *exactly* as today wherever no step is declared.
The narrowing and its two rejected alternatives are recorded in `plan.md`'s Complexity Tracking; the short
version is that both alternatives break byte-equality or move a phase 021 placed deliberately, to buy back
one full reconcile on one event.

## 5. Invariants

021's S1–S8 all survive. Restated where this change touches them, plus two new ones:

| # | Invariant |
| --- | --- |
| S1 | Every doubt fails open to a full reconcile. No condition introduced here can cause a skip. |
| S2 | A short-circuited run issues zero Jira requests and consults the secret store zero times. |
| S3 | A short-circuited run writes nothing — not to Jira, not to `spec.md`, not to `tasks.md`, not to the state file. |
| S4 | No credential enters the document. `hook_event` is one of six lifecycle constants. |
| S5 | The document is byte-identical between ports for identical inputs, `hook_event` included. |
| S6 | `--dry-run` neither reads nor writes it, so the preview still predicts the real run exactly. |
| S7 | An upgrade invalidates every recorded document — here by `schema` as well as `extension_version`. |
| S8 | The document is never deleted or repaired; a stale one is invalidated by comparison. |
| **S9** | **A lifecycle event that has not been honoured against the current inputs can never be skipped.** |
| **S10** | **A run that raised any warning records nothing, so an unresolvable move is always reconsidered by the next run.** |

## 6. Scenario coverage

| Case | Assertion |
| --- | --- |
| Reconcile under `after_specify`, then under `after_plan` with `spec.md` and `tasks.md` byte-identical | Second run is **not** short-circuited; the ticket stands at the plan event's step; the plan summary reaches the parent |
| The same event twice, nothing changed | Second run short-circuits: exit 0, empty call log |
| Touch `plan.md` only, same event | Full reconcile — fails against the pre-change code, which short-circuits |
| Delete `plan.md`, same event | Full reconcile in both directions |
| A schema-1 document present | Full reconcile; a schema-2 document is recorded on success |
| Run under an event, raising an unreachable-step warning | No state recorded; the next run reconsiders the ticket |
| `--dry-run` under a new event | Full preview; state neither consumed nor written |
| `--force` under an unchanged event | Full reconcile; state re-recorded |
| Disabled event with a matching state recorded | Exit 0 silently, no config read, no state read |
| Two runs racing under different events | Neither observes a partial document; no wrongful skip |
| Fresh clone, `git status` after a short-circuit | Clean; the state directory is ignored |
| Both ports, every case above | Byte-identical documents and identical outcomes |
