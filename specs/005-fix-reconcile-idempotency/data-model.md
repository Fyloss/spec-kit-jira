# Phase 1 Data Model: Reconcile Recognises the Tickets It Already Created

Every shape this feature introduces or changes. Entities first, then the four
in-memory structures the run passes between layers. Nothing here is a database:
the durable state is one comment line per user story in `spec.md` and one entity
property per Jira ticket.

---

## Entities

### Durable story identifier

The value that makes a user story recognisable after it is retitled, reordered, or
rewritten (spec FR-006, FR-007).

| Property | Value |
| --- | --- |
| Shape | 16 lowercase hexadecimal characters, `^[0-9a-f]{16}$` |
| Source | 8 bytes of cryptographic randomness (research R4), through the `SPEC_KIT_JIRA_ID_SOURCE` test seam |
| Assigned | Once, when a story is first seen without one |
| Mutated | Never — not on retitle, reorder, rewrite, or re-route |
| Lives in | `spec.md`, in the story marker line; mirrored into the ticket's identity marker |
| Scope of uniqueness | The specification file. Two stories carrying one identifier is a fail-closed conflict (FR-011) |

Storing it in the specification is what makes it survive a clone, a folder rename, and
a colleague's machine (FR-017, FR-018) — the file is committed.

### Story marker line

The single line of `spec.md` that binds one user story to its identifier and, once
created, to its ticket. Full grammar and placement rules:
[contracts/story-marker.md](./contracts/story-marker.md).

```markdown
<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->
<!-- speckit-jira story=7f3a9c1e40b2d85a -->
```

The second form — identifier assigned, no ticket yet — exists for exactly one moment in
a first run (research R5 step 1) and for the fail-closed window of R8.

### Identity marker (Jira entity property `spec-kit-jira`)

Unchanged in location and purpose; one key added.

| Field | Today | After |
| --- | --- | --- |
| `origin` | `"bridge"` \| `"human"` | unchanged |
| `repo` | repository reference | unchanged |
| `spec_slug` | specification folder name | unchanged |
| `story` | — | **new**: the durable story identifier |

`story` is absent on tickets created by the feature-naming ceremony and the
mentioned-ticket flow, which mirror a whole feature rather than one story. Those tickets
are not story tickets and never match a story recognition (see the decision table in
[contracts/recognition-contract.md](./contracts/recognition-contract.md)).

### Recognised ticket state

Read once per recorded ticket (research R3) and consumed by three independent rules. Not
persisted anywhere; it lives for the duration of the run.

| Field | From | Consumed by |
| --- | --- | --- |
| `key` | the recorded marker line | every rule, and the update URL |
| `marker` | `?properties=spec-kit-jira` | the verification decision table |
| `origin` | `marker.origin` | human-panel splice (FR-014), churn diff shape |
| `current` | `fields.summary`, `fields.description`, `fields.priority` | churn comparison (FR-013) |
| `status` | `fields.status.name` | drift evaluation (FR-020) |
| `category` | `fields.status.statusCategory` classified through `config_classify_statuses` | drift evaluation |
| `flagged` | the configured Flagged field | Flagged withholding (FR-020) |
| `blockers` | `fields.issuelinks`, inward blocking links | blocker notes (FR-020) |

### Run summary counts

`counts` gains one member; the rest keep their meaning and their position.

| Key | Meaning |
| --- | --- |
| `recognised` | **new** — stories bound to an existing ticket by this run |
| `assigned` | **new** — identifiers written into `spec.md` by this run |
| `created` | tickets created (unchanged: create-endpoint POSTs) |
| `updated` | tickets written (unchanged: PUTs surviving the churn drop) |
| `skipped` | **now populated** — recognised tickets whose write was dropped as no-op |
| `warnings`, `errors` | unchanged |

`skipped` is currently hard-coded `0` in both ports. Populating it is what makes FR-023's
"visible rather than silently absent" true, and it is how a reader confirms an unchanged
re-run did nothing rather than mirrored nothing.

---

## Structures passed between layers

### 1. Neutral document — `stories[].local_id` (changed)

```jsonc
{ "local_id": "7f3a9c1e40b2d85a", "title": "…", "description": {…}, … }
```

Was `s1`, `s2`, … by position; becomes the durable identifier (research R7). Every story
in an assembled document has one, because assignment (R5 step 1) precedes assembly. The
interchange schema already requires a non-empty string and needs no change; every
fixture that asserts on `local_id` does.

### 2. Plan context — `tickets`, `ticket_origins`, `ticket_descriptions` (now populated)

The three maps `plan_writes` already documents and consumes, keyed by `local_id`,
filled from recognition instead of only from the `SPEC_KIT_JIRA_PLAN_CONTEXT` override:

```jsonc
{
  "base_url": "…", "story_type_id": "…", "priority_ids": {…}, "estimation_field_id": "…",
  "tickets":             { "7f3a9c1e40b2d85a": "PROJ-142" },
  "ticket_origins":      { "7f3a9c1e40b2d85a": "bridge" },
  "ticket_descriptions": { "7f3a9c1e40b2d85a": { "type": "doc", … } }
}
```

A `local_id` absent from `tickets` is a creation — the existing rule, now reached only by
genuinely new stories. The explicit override keeps winning wholesale (004 FR-013).

### 3. Lifecycle context (now built, was override-only)

Same shape `plan_lifecycle` already documents. Recognition fills `tickets`; `order` comes
from `config_phase_status_targets`; `target` from the lifecycle event (research R9);
`transition_id` is deliberately never set.

```jsonc
{
  "on_drift": "abort", "base_url": "…", "order": ["To Do", "In Progress", "Done"],
  "tickets": {
    "7f3a9c1e40b2d85a": {
      "key": "PROJ-142", "origin": "bridge",
      "current": { "summary": "…", "description": {…}, "priority": {"id":"3"} },
      "status": "In Progress", "category": "mapped",
      "target": "In Progress", "flagged": false, "blockers": []
    }
  }
}
```

`SPEC_KIT_JIRA_LIFECYCLE` remains an override seam for tests, exactly as
`SPEC_KIT_JIRA_PLAN_CONTEXT` does.

### 4. Recognition result (new, internal to the command layer)

What the recognition step returns to the sequencer, before it is split into the two
contexts above.

```jsonc
{
  "bound":   { "7f3a9c1e40b2d85a": { …recognised ticket state… } },
  "new":     ["a1b2c3d4e5f60718"],
  "blocked": [ { "story": "…", "reason": "key-unrecorded" | "marker-mismatch" | "orphan" | "claimed-by-other" | "duplicate-claim", "detail": "…" } ]
}
```

`blocked` stories are excluded from the write plan entirely and each produce one warning
(FR-011, FR-016, FR-021, and research R8). A blocked story never blocks the others: the
rest of the specification reconciles normally.

---

## State transitions

A user story moves through five states across runs. Only the transitions drawn here
exist; there is no path back to `unassigned` except a hand-edit.

```text
unassigned ──assign identifier, write spec.md──▶ assigned
                                                   │
                                    (plan + guard pass; mark `creating`)
                                                   ▼
                                                creating
                                                   │
                                                   ├─create ticket, stamp marker,
                                                   │  replace `creating` with key ──▶ bound
                                                   │
                                                   └─run interrupted after create ──▶ creating
                                                      (persists; next run fails closed) │
bound ──re-run: read key, marker verifies──▶ bound (updated or skipped)                 │
bound ──re-run: marker absent / mismatched──▶ blocked ◀──────────────────────────────────┘
bound ──ticket deleted in Jira (404)──▶ assigned  (re-created, FR-010 / edge case)

Any failure before the `creating` mark — a privacy-guard BLOCK, a rejected credential,
an interrupt — leaves the story at `assigned`, which the next run creates normally.
```

| State | `spec.md` holds | Jira holds | Next run does |
| --- | --- | --- | --- |
| unassigned | nothing | nothing | assign, create |
| assigned | `story=` | nothing — no creation was ever attempted | create, stamp, record key |
| creating | `story=` + `creating` | a ticket that may or may not exist | fail closed for this story (R8) |
| bound | `story=` + `ticket=` | ticket with matching marker | update, or skip as unchanged |
| blocked | `story=` + `ticket=` | a ticket that contradicts the record | fail closed for this story, warn |

The `bound → assigned` edge is the deleted-ticket case: a `404` on the recorded key is
not a failure, it is "the mirror lost its ticket". The identifier is kept, the key line is
rewritten on re-creation, and the summary says so.

---

## Validation rules

| Rule | Where enforced | On violation |
| --- | --- | --- |
| Identifier matches `^[0-9a-f]{16}$` | parser | line ignored as a marker; story treated as unassigned |
| Issue key matches `^[A-Z][A-Z0-9_]+-[1-9][0-9]*$` | parser | marker malformed → story blocked, named warning |
| At most one marker line per story section | parser | story blocked, named warning naming both line numbers |
| An identifier appears at most once per specification | recognition | both stories blocked (FR-011) |
| A recorded key's marker names this repo, this spec, and this story | recognition | story blocked (FR-011 / FR-021) |
| A key is never recorded for a ticket that was not stamped first | sequencer (R5 step 6) | run fails closed before recording |
| A story is never created without being marked `creating` first | sequencer (R5 step 4) | run fails closed before the create |
| A ticket is never created for a story whose identifier is unrecorded | sequencer (R5 step 1) | run fails closed before any write |
| Writing `spec.md` preserves every byte outside the marker lines | splice | refuse, zero writes (FR-009) |
| An unchanged `spec.md` is not rewritten | splice | no file write at all (FR-009) |
