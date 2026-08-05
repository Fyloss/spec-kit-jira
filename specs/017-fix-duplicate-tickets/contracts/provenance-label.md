# Contract — the provenance label

Covers FR-009 – FR-018. Both ports implement this identically; the conformance corpus compares the
bytes.

## §1 Derivation

```text
provenance_label := "speckit-" + document.spec_ref.spec_slug
```

- `spec_ref.spec_slug` comes from the neutral interchange document and is already validated against
  `^[0-9]{3}-[a-z0-9-]+$` before any write. The label therefore contains no whitespace by
  construction, and FR-010's whitespace rule can never fire — it is satisfied upstream, not
  re-implemented here.
- That regex bounds the label's *alphabet*, not its *length*. A slug long enough to push
  `speckit-<slug>` past the tracker's label limit is therefore reachable, and it is the concrete way
  FR-014's second branch — "the folder reference cannot be expressed as a label" — fires. It is
  handled in §4, not here: the label is omitted with a warning, never sent to be rejected.
- `"speckit-"` is a literal in the sink. The engine never sees it and never learns the word "label".

Example: `specs/001-test-page/spec.md` → `speckit-001-test-page`.

## §2 Where it is applied

| Path | Site (bash) | Desired value |
| --- | --- | --- |
| create, all three mirror roles | `jira_create_fields_base`, `sink/jira/ticket.sh` | `((defaults.labels // []) + [L]) \| unique` |
| create, feature ceremony | `_ticket_create_body`, `sink/jira/ticket.sh` | **none** — no label is sent |
| update, story | `plan_writes` update branch, `sink/jira/plan_apply.sh` | `(ctx.ticket_labels[sid] + [L]) \| unique` |
| update, parent | `_plan_writes_parent` recognised branch | `(ctx.parent_current.labels + [L]) \| unique` |
| update, task | `plan_writes_tasks` update branch, `sink/jira/plan_apply.sh` | `(ctx.ticket_current[tid].labels + [L]) \| unique` |

All three mirror creation roles funnel through one builder, so a single change covers the parent,
every story child, and every sub-task feature 012's task tier mirrors beneath them.

**The task tier reads its current labels from a different map, and that is not an inconsistency.**
The story branch reads `ctx.ticket_labels[sid]` because recognition's story pass hands the command
layer a labels-only map; the task branch reads `ctx.ticket_current[tid].labels` because the task
pass already carries the sub-task's whole `current` record — the same recognition read, exposed
through the map that tier already had. Both are the ticket's `unique`-normalised current labels, so
the union, the back-fill and the zero-churn comparison behave identically on either tier.

**A pure back-fill on the task tier is not drift.** The task tier's update branch attaches feature
012's FR-020 divergence warning whenever a desired field differs from Jira's. `labels` is excluded
from that naming: a sub-task that merely lacks its provenance label has not diverged from the
specification, and back-filling it must stay as silent as it is on the story tier (FR-011). Real
content drift on `summary` or `description` still names its field exactly as before.

**The builder has a second caller, and it must not be labelled.** `jira_create_fields_base` is
shared by `plan_writes` (the mirror) and `_ticket_create_body` (the feature ceremony's single-item
path, reached from `commands/feature.sh`). Feature 004's FR-025 made it shared precisely so the two
payloads cannot drift apart. The provenance label is therefore added as an **optional fifth
parameter**, passed by the mirror and omitted by `_ticket_create_body` — the shared base stays
identical, and the one field that legitimately differs does so explicitly.

The ceremony must not label its ticket, and the reason is not stylistic: in the normal
`before_specify` state the specification folder does not exist yet, and `feature.sh` builds
`spec_ref.spec_slug` as the literal fallback `"spec"`. Passing it through would stamp
`speckit-spec` onto the board — a label naming no specification, on tickets from every repository
that ever ran the ceremony. The spec's own edge case states the intended behaviour: a ceremony
ticket carries no label at creation, and the first reconcile of its specification back-fills it
through §3 like any other unlabelled ticket.

**Merge order on creation is load-bearing.** `jira_create_fields_base` today spreads the
field-defaults object **last**:

```jq
{project: …, issuetype: …, summary: …} + (($dbt[$t]) // {})
```

A project that records a `labels` default would have it overwritten by a naive `+ {labels: [L]}`.
The provenance label is therefore merged **after** the spread, as a union with whatever the defaults
put there.

## §3 Back-fill and zero churn

No dedicated back-fill pass exists, and none is wanted. The label is part of the desired field set,
so the existing `idempotency_field_status` comparison decides it:

| Ticket state | Desired labels | Comparison | Outcome |
| --- | --- | --- | --- |
| carries the label | equals current | `unchanged` | action dropped — zero churn (FR-013) |
| missing the label | current ∪ {L} | `changed` | one `PUT`, counted as an update (FR-011) |
| operator deleted it | current ∪ {L} | `changed` | restored, no warning (self-healing, Constitution X) |
| carries other labels | current ∪ {L} | preserves them | FR-012 — Jira's `PUT` replaces the array, so the union is the merge |

**Both sides must be `unique`-normalised.** `idempotency_field_status` compares with `jq`'s `==`,
which compares arrays by position. Without normalisation a settled ticket whose label order differs
from ours would be re-sent on every run — a churn bug inside the feature that must not have one.
Recognition normalises on ingest; the desired list is built with `unique`, which sorts.

## §4 Suppression and degradation

- **Suppressed writes** (halted status, Flagged, unresolved drift): the whole action is dropped by
  `plan_lifecycle`; the label is dropped with it. FR-018 needs no rule of its own — the label is
  never an exception to an operator's hold.
- **A project that cannot hold the label**: decided from the local binding's per-type
  `defaultable_fields`, which already records every createmeta field the bridge does not supply —
  `labels` among them. Three-valued:

  | `defaultable_fields[<type>]` | `labels` entry | Behaviour |
  | --- | --- | --- |
  | recorded | present | send the label |
  | recorded | absent | omit it, one warning |
  | not recorded | — | send it (a pre-metadata binding must not gain a second refusal) |

  **"Present" means the key exists, not that it is defaultable.** `_disc_defaultable_fields`
  (`sink/jira/discovery.sh:188-205`) records `labels` with `defaultable: false` and an
  `undefaultable_reason` for every type whose create screen offers it — an array-shaped field cannot
  be a recorded scalar. That entry is exactly the evidence this rule wants: the type *accepts*
  labels. Reading "present" as `defaultable: true` would omit the label on every project and warn on
  every run, which is the inverse of FR-014.

  Every ticket is still created and updated exactly as today, and one warning is emitted:

  ```text
  the provenance label "speckit-001-test-page" could not be applied to <TYPE> in <KEY>; every ticket was mirrored without it
  ```

  Never a refusal, never a failed write (FR-014, Constitution VII).

- **A label the tracker cannot hold**: FR-014's second branch. The rendered `speckit-<slug>` is
  measured against the sink constant `JIRA_LABEL_MAX_LENGTH` (255, Jira Cloud's documented cap —
  one named constant per port, so a tracker that differs is a one-line correction). Over the limit,
  the label is **omitted before the payload is built** and one warning is emitted:

  ```text
  the provenance label for "001-a-very-long-slug" is 264 characters, past the tracker's 255-character limit; every ticket was mirrored without it
  ```

  Omitting is the whole point: sending an over-long label would have Jira reject the **creation**,
  costing the ticket its write for a cosmetic field — exactly what FR-014 forbids. The label is
  never truncated: a truncated label names a specification that does not exist and would break the
  one-search guarantee of SC-003. The remedy the operator holds is to shorten the folder name; until
  they do, the mirror is exactly as correct as it is today, minus one piece of evidence.

## §5 Guarantees inherited without new code

- **Privacy** (FR-017): the guard scans each action's whole `body`, and the label is inside
  `body.fields`. Ordering "guard, then write" is untouched. Pinned by test, not assumed.
- **Dry run** (FR-015): the label is part of the action body, so the reported action set already
  carries it and equals the real run's exactly.

## §6 Test obligations

| # | Assertion | Where |
| --- | --- | --- |
| T1 | Parent and every child creation payload carries `speckit-<slug>` | bats + Pester |
| T2 | A project with a recorded `labels` field default: the payload carries **both** | bats + Pester |
| T3 | A recognised ticket missing the label is updated exactly once; `counts.updated` reflects it | bats + Pester |
| T4 | The run after that reports `created: 0, updated: 0` and a byte-identical summary | conformance `us2-label-second-run` |
| T5 | A ticket carrying operator labels keeps every one of them after the update | bats + Pester |
| T6 | Current labels in a different order than ours still compare `unchanged` (the R4 regression) | bats + Pester |
| T7 | A type whose metadata offers no `labels`: tickets mirrored, one warning, exit unchanged | bats + Pester |
| T8 | A halted ticket is not labelled and no write is issued for it | bats + Pester |
| T9 | `--dry-run` action bodies equal the real run's, labels included | bats + conformance |
| T10 | A BLOCK-tier string reachable through the slug is caught by the privacy guard | bats |
| T11 | Both ports emit byte-identical payloads and summaries | conformance |
| T12 | A feature-ceremony creation carries **no** `labels` key — in particular never `speckit-spec` — while its shared base stays byte-identical to the mirror's | bats + Pester |
| T13 | A slug pushing the label past `JIRA_LABEL_MAX_LENGTH`: the label is absent from every payload, every ticket is still created, one §4 warning, exit unchanged, nothing truncated | bats + Pester |
| T14 | A ticket adopted from a human author through `mention` gains the provenance label on its next ordinary update — **additively**: the human's own labels survive, and no field they wrote is altered | bats + Pester |
| T15 | A created sub-task carries `speckit-<slug>`; with no label resolved its payload carries no `labels` key at all (012 interaction) | bats + Pester |
| T16 | A bound sub-task missing the label is back-filled by a PUT carrying `labels` **alone**, with no FR-020 divergence warning | bats + Pester |
| T17 | A sub-task's existing labels survive the union, and a sub-task already carrying the label plans nothing (task-tier zero churn) | bats + Pester |
| T18 | Real task-tier content drift still names `summary`/`description` in its warning, and never names `labels` | bats + Pester |
| T19 | Both ports emit a byte-identical **labelled** task plan, on the create, the back-fill and the merge path | bats (pwsh parity) |
