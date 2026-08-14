# Quickstart — validating that each tier advances along its own workflow

Runnable checks that prove the feature end to end. Ordered so that each one fails for a single, identifiable
reason. Every scenario references its contract rather than restating it.

## Prerequisites

- `bash` ≥ 4, `jq`, `git`, `curl` (Bash port); PowerShell 7+ (Windows port).
- No live Jira for §1–§6 — the conformance mock and the scripted `curl` replacement serve every case.
- §7 needs the dogfood instance the project already uses for Principle XII.

```bash
tests/run-bash.sh --since main          # change-scoped inner loop, ≤60s on one module
tests/run-bash.sh                       # full bash suite, ~190s
bash tests/conformance/ci-conformance.sh   # cross-port byte equivalence
shellcheck / actionlint                 # must stay clean
```

Conformance success is **silent**: exit 0 and zero "conformance divergence" lines is the pass signal; there
is no banner.

---

## 1. The red test — this must fail before anything is built

The behaviour this feature exists to add, asserted first (Principle XIII):

```bash
bats tests/bash/commands/test_reconcile_lifecycle.bats \
  -f "a declared step for the dispatched event moves the ticket"
```

Declare a story-role mapping, bind a recognised story one agreed step behind, dispatch a real lifecycle
event, and assert a transition request was issued.

**Expected before the change**: fail — zero transition requests. That is what the currently-passing pin
records (`test_reconcile_lifecycle.bats:123`, and `Reconcile.Lifecycle.Tests.ps1:132`). The pin is rewritten
in place, never deleted, to keep asserting what stays true: a project declaring **no** mapping still issues
zero transition requests.

---

## 2. The event reaches the run

Contract: [`lifecycle-event.md`](./contracts/lifecycle-event.md).

```bash
SPEC_KIT_JIRA_HOOK_EVENT=after_plan \
  .specify/extensions/jira/scripts/bash/spec-kit-jira.sh reconcile specs/NNN-x/spec.md --json
```

| Check | Expected |
| --- | --- |
| Each of the six after-events, with a different step declared per event | Each run aims at its own event's step |
| The variable unset | Byte-identical stdout, exit code, written tree and call log to the pre-change bridge |
| An event name outside the closed set | Same as unset — zero availability reads, zero warnings |
| A disabled event | Exit `0` silently, no config read, no state read |

The unset case is the one to run against both the pre-change and post-change bridge and diff. It is the
whole of FR-011.

---

## 3. A second event over unchanged files still advances the board

Contract: [`run-state-v2.md`](./contracts/run-state-v2.md). **This is the check that fails against `main`.**

```bash
SPEC_KIT_JIRA_HOOK_EVENT=after_specify  … reconcile specs/NNN-x/spec.md --json
# change nothing on disk
SPEC_KIT_JIRA_HOOK_EVENT=after_plan     … reconcile specs/NNN-x/spec.md --json
```

| Check | Expected | Against `main` |
| --- | --- | --- |
| Second run reaches the pipeline | not short-circuited | **short-circuits, empty call log** |
| Ticket position | the plan event's declared step | unchanged |
| Parent's Implementation Plan section | present and current | **never written** |
| Same event twice, nothing changed | second run short-circuits, exit 0, empty call log | same |
| Touch only `plan.md` | full reconcile | **short-circuits** |
| A schema-1 state document present | full reconcile, schema-2 recorded on success | n/a |
| A run raising an unreachable-step warning | no state recorded; next run reconsiders | n/a |

The third row is a defect of 021 that this feature closes because FR-013 is unverifiable while it stands —
it costs a consumer mirrored content, not only a board position.

---

## 4. Each tier follows its own workflow

Contract: [`role-lifecycle-config.md`](./contracts/role-lifecycle-config.md).

```yaml
projects:
  - key: COMP
    hierarchy: { specification: "Epic", story: "Story", task: "Sub-task" }
    phase_status_map:
      specification: { after_plan: "Building" }
      story:         { after_plan: "In Progress" }
```

| Check | Expected |
| --- | --- |
| One `after_plan` run | Parent at "Building", every story at "In Progress" |
| Cross-role evaluation | Zero — no ticket is ever compared against the other role's step name |
| `story` declared alone | Stories advance; parent not moved; no warning about the parent |
| Legacy shape 1 (events at the top level) | Stories advance; parent and sub-tasks untouched |
| `task` role, project in `subtask` mode | Sub-tasks whose task is unchecked advance |
| `task` role, project in `checklist` mode | Zero tickets moved; exactly **one** note per run, not one per entry |
| An abandoned sub-task marker left by a mode switch | Never enters the move set |
| Mixed key sets in one mapping | Exit `4`, zero requests, the §3 message |
| Three roles declared, counting stand-in on config opens | One open, one parse — same as a one-role project |

---

## 5. The four resolution outcomes

Contract: [`transition-resolution.md`](./contracts/transition-resolution.md) §3, §4.

Drive each through the mock's per-key transitions override
(`tests/conformance/mock-jira/mock-server.ps1`, the `transitions` config key, keyed by exact issue key).

| Workflow shape | Expected |
| --- | --- |
| One ungated move onto the declared step | Ticket moves; `counts.transitioned` is 1 |
| Two moves landing on the declared step | Zero moves; **one** warning naming both candidates; content still mirrored |
| One move, gated on a required field | Zero moves; one warning naming the field |
| …with a creation-time default recorded for a field of that name | The default is **not** sent; the same warning |
| No move landing on the declared step | Zero moves; one warning naming current step, declared step, reachable set |
| Declared step absent from the workflow entirely | Same, with the empty-set wording |
| Declared step differing only in case or spacing | Reported unreachable — never silently accepted |
| Ticket already at the declared step | **Zero availability requests**, zero moves, zero warnings |

The assertion that matters most: every non-move outcome carries exactly one warning. A silent drop — today's
behaviour when `transition_id` is empty — is a defect after this change.

---

## 6. Nothing else moved

| Check | Command | Expected |
| --- | --- | --- |
| Safety corpus unchanged | full bash + Pester suites | Same decision and same wording everywhere, with the single addition that an advance decision now moves the ticket |
| Idempotency | run twice, unchanged | 0 created, 0 updated, **0 transitioned**, 0 commented, 0 linked, 0 labeled |
| Dry run | `--dry-run` then the real run, same state | Identical action sets, moves included; the preview performs none and leaves the state document byte-unchanged |
| Request budget | 60-story spec, every ticket due a move, recorded call log | Contract §6 B2 |
| Spawn budget | 024's `PATH` shim, in a run **separate** from any timing run | Count unchanged when the due set doubles |
| Timing attribution | `SPEC_KIT_JIRA_TIMING=1` | Requests attributed to `plan`; per-phase counts sum to the run's total |
| No-move run | any run with no event | Requests, external processes and config parses identical to today |
| Cross-port | `bash tests/conformance/ci-conformance.sh` | Exit 0, zero divergence lines |

---

## 7. Dogfood — Principle XII

Not optional, and not satisfiable by the mock. Against the real instance:

1. A project with **two** roles on genuinely different workflows.
2. Run `/speckit.specify`, then `/speckit.plan` — the second changes only `plan.md`.
3. Watch the parent and its stories each land on their own declared step, on the second event.
4. Re-run with nothing changed: zero writes of every kind.
5. Record the wall-clock split with `SPEC_KIT_JIRA_TIMING=1` as evidence, **not** as a CI assertion — CI
   runners are an order of magnitude slower than a developer laptop.

Step 2 is the point: a board advancing on an event that edited no specification file is exactly what this
feature adds and exactly what `main` cannot do.

---

## 8. Documentation

Contract: spec FR-040. A reader comparing these four against the shipped behaviour must find no claim the
code does not satisfy, and no accepted flag the procedure does not list:

- `docs/08-safety-model.md` — the decision table's `transition | emitted` row becomes true for the first
  time at the story and specification tiers.
- `docs/05-reconcile-flow.md` — the pipeline shows where a move is decided and issued, and states how the
  event reaches the run.
- `docs/VISION.md` — Part 2 item 3 moves from *Specified, not shipped* to *Shipped*, and the Part 1 bullet
  drops its "does not yet act on" clause.
- `commands/speckit.jira.reconcile.md` — the event conveyance, the host-command → event table, the per-role
  mapping, and `--force` in the Flags list.
