# Phase 1 — Data Model: Each Tier Advances Along Its Own Declared Workflow

**Feature**: `specs/023-advance-board-position` | **Date**: 2026-08-10

All structures below are canonical JSON as produced by `json_canonical` (Bash) and its PowerShell twin, and
must be byte-identical between the ports. Field order is the canonical order; keys absent rather than null
where the contract says "omitted".

---

## 1. Role-keyed lifecycle mapping (configuration)

Lives in the committable team config, per project, at the existing `phase_status_map` key. Two accepted
shapes, discriminated structurally (research R3).

### Shape A — role-blind (what ships today)

```yaml
phase_status_map:
  after_specify: "To Do"
  after_plan: "In Progress"
```

**Meaning**: the story role's mapping, and only the story role's. Reading it any other way would move
parents and sub-tasks a team never asked to move (FR-013).

### Shape B — one workflow per role

```yaml
phase_status_map:
  specification:
    after_specify: "Funnel"
    after_plan: "Building"
  story:
    after_specify: "To Do"
    after_plan: "In Progress"
  task:
    after_implement: "In Progress"
```

### Normalised form (internal)

Both shapes normalise to one structure before anything else reads them:

```json
{ "specification": { "<event>": "<step name>" },
  "story":         { "<event>": "<step name>" },
  "task":          { "<event>": "<step name>" } }
```

A role absent from the declaration is absent here — never an empty object — so "declared nothing" stays
distinguishable from "declared an empty workflow" (FR-012).

### Validation rules

| Rule | Message names |
|---|---|
| Shape A: every value is a string | the project index and the offending event key |
| Shape B: every key is one of `specification`, `story`, `task` | the project index and the unknown role |
| Shape B: every role's value is an object of string values | the project index, the role, the offending key |
| The two shapes are never mixed in one declaration | the project index and both an event key and a role key |

Events are the six the host emits: `after_specify`, `after_clarify`, `after_plan`, `after_tasks`,
`after_implement`, `after_analyze`. An unrecognised event key is **not** an error — a declaration for an
event this host does not emit is inert, matching how an unmapped event behaves today.

---

## 2. Lifecycle ticket entry (planning input)

The per-ticket context `plan_lifecycle` consumes. Existing fields are unchanged; the additions are marked.

```json
{
  "local_id":      "US1",
  "role":          "story",
  "key":           "COMP-2",
  "current":       { "...": "the ticket's current fields" },
  "status":        "To Do",
  "category":      "mapped",
  "target":        "In Progress",
  "flagged":       false,
  "origin":        "bridge",
  "blockers":      [],
  "move":          { "...": "see §3 — omitted when no move is due" }
}
```

| Field | Status | Notes |
|---|---|---|
| `local_id` | existing | the parent's own id now appears here too (research R5) |
| `role` | **new** | `specification` \| `story` \| `task`; selects the mapping, the order, and the warning wording |
| `target` | existing, re-derived | now from the **role's** mapping for the current event, not the project's |
| `category` | existing, re-derived | classified against the **role's** own mapping and the project-wide halted list |
| `move` | **new** | present only when a move is due and the availability read succeeded |

`plan_lifecycle` is given an explicit ordered list of these entries rather than deriving it from the
document's stories — that derivation is what made the parent unreachable (research R5).

---

## 3. Move resolution (`move`)

Produced by the availability read, one per ticket, only when a move is due (research R8).

```json
{
  "transition_id":  "31",
  "candidates":     [ { "id": "31", "name": "Start progress", "to": "In Progress" } ],
  "withheld_field": null,
  "reachable":      [ "In Progress", "Done" ]
}
```

| Field | Meaning |
|---|---|
| `transition_id` | the move to perform; `null` in every unresolvable case |
| `candidates` | every offered move landing on the declared step; empty when none does |
| `withheld_field` | `{ logical_name, field_id }` when the single candidate's screen demands a value; else `null` |
| `reachable` | every step the offered moves land on, in the order the tracker offered them |

### The four outcomes, and the fifth

| `candidates` | `withheld_field` | `transition_id` | Outcome | Requirement |
|---|---|---|---|---|
| exactly 1 | `null` | set | the move is performed | FR-003 |
| exactly 1 | set | `null` | withheld; the demanded value is named | FR-005 |
| 2 or more | `null` | `null` | withheld; every candidate is named | FR-004 |
| empty | `null` | `null` | withheld; current step, declared step and `reachable` are named | FR-007 |
| — | — | — | the read failed: no `move` entry, the run fails closed for this specification | FR-020 |

The first four are the task tier's shipped contract, adopted verbatim (research R2). `reachable` is the one
addition, and it exists so the fourth outcome can say something useful.

---

## 4. Transition action (planning output)

Unchanged in shape from what `_plan_transition_action` already emits, so both tiers keep producing one
action kind:

```json
{ "method": "POST",
  "url":    "<base>/rest/api/3/issue/COMP-2/transitions",
  "body":   { "transition": { "id": "31" } } }
```

Nothing else is sent. In particular no field values accompany the move (FR-006), which is why a gated
candidate is refused rather than satisfied.

---

## 5. Run summary counts

```json
{ "created": 0, "updated": 2, "transitioned": 1, "skipped": 0,
  "warnings": 0, "errors": 0, "recognised": 3, "assigned": 0,
  "tasks": { "created": 0, "updated": 0, "transitioned": 0,
             "unchanged": 4, "skipped": 0, "withheld": 0 } }
```

`transitioned` is **new at the top level** and counts lifecycle moves across all three roles, derived by
counting emitted transition actions so it can never disagree with the action list (research R7).
`tasks.transitioned` keeps its existing meaning — sub-task completions driven by checked boxes — so a reader
can tell the two apart.

The human-readable report carries the same count, on its own line, so the two surfaces can never disagree
(FR-024):

```text
Created: 0, Updated: 2, Skipped: 0
Transitioned: 1
Recognised: 3, Assigned: 0
Warnings: 0, Errors: 0
```

The line is emitted **only when `counts.transitioned` is present**, exactly as `Recognised: / Assigned:`
already is (`scripts/bash/lib/output.sh:229-234`), so no other command's prose summary changes by a byte.
Appending the count to the existing `Created: … Skipped:` line was rejected: that string is pinned by every
conformance scenario in the corpus, and editing it would make an unrelated diff of the whole suite. Note
that `summary_render_prose` renders no transitioned count at all today — not even `tasks.transitioned` —
so this is a genuine addition to the renderer in both ports, not a re-derivation of an existing line.

---

## 6. Warnings introduced

Each is one line, names the ticket and its role, and ends in something a human can act on (FR-025,
Principle XVI). Wording is pinned by the conformance corpus and identical in both ports.

| Trigger | Shape |
|---|---|
| Two or more candidates (FR-004) | *`<key>` (`<role>`) offers more than one move onto "`<step>`": `<names>`; none was performed — declare which one applies or move the ticket by hand* |
| Gated candidate (FR-005) | *`<key>` (`<role>`) cannot move to "`<step>`" without a value for "`<field>`"; the move was withheld and no value was invented* |
| Unreachable step (FR-007) | *`<key>` (`<role>`) stands at "`<current>`" and cannot reach "`<step>`" in one move; reachable from here: `<reachable>`* |
| Rejected move (FR-021) | *`<key>` (`<role>`) was moved toward "`<step>`" but the tracker refused; the ticket was left where it stands and the move was not retried* |
| Task mapping while the tier is off (FR-015) | *a workflow is declared for the task role but sub-task mirroring is off for this project; the declaration has no effect* |

Existing drift, halt, flagged and blocker wording is unchanged (FR-018) — those strings are asserted by the
current corpus and any edit to them is a regression.

---

## 7. State transitions

For one ticket in one run:

```text
recognised
  └─ run carries a lifecycle event?            no ─→ no move considered            (FR-022)
       yes
  └─ role declares a step for that event?      no ─→ no move considered            (FR-012)
       yes
  └─ current step == declared step?            yes ─→ no move, no read, no warning (FR-008)
       no
  └─ safety decision                halt ─→ every write suppressed                 (FR-018)
       │                        withhold ─→ move suppressed, content reconciles    (FR-018)
       └─ transition
            └─ flagged?                        yes ─→ move withheld, flag surfaced (FR-018)
                 no
            └─ task role and its task is checked? yes ─→ completion governs it     (FR-016)
                 no
            └─ availability read       failed ─→ fail closed for this spec         (FR-020)
                 succeeded
            └─ resolution → one of the four outcomes of §3
                 └─ performed → tracker refuses? ─→ report, do not retry           (FR-021)
```

Content writes are decided independently at every branch below `halt`: only `halt` suppresses them
(FR-019).
