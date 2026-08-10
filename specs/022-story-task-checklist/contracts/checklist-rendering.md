# Contract: rendering a story's tasks as a checklist

**Feature**: 022-story-task-checklist | **Normative for**: FR-014…FR-030, FR-041

The one place ADF node names may appear for this feature is `sink/jira/adf.sh` and its PowerShell mirror
`sink/jira/Adf.psm1` (Constitution VIII). Everything below is sink-side.

---

## 1. Position in the managed region

`_adf_content_nodes` (`adf.sh:113`) composes a story's managed nodes in a fixed order. The checklist is
**appended last**:

```
description body
[Acceptance Criteria heading + info panel]     (when there is any AC)
[Design heading + bullet list]                 (when there is any design content)
[Tasks heading + checklist]                    (NEW — when checklist mode and ≥1 attributed task)
```

Appending rather than inserting is deliberate: a story with no tasks, or a project not in checklist mode,
produces byte-identical managed nodes to the previous release, which is how FR-002 is satisfied without a
compatibility branch.

The section sits **below the boundary marker**, like everything `_adf_content_nodes` produces, so human
prose above it survives verbatim (FR-020). Malformed markers and the `migrated-warned` path are handled
by `_adf_resolve_managed` upstream and are untouched by this feature.

## 2. Structure

```
heading level 3: "Tasks"
  for each phase group, in document order:
    [strong paragraph: the phase text]         (omitted for the no-phase group)
    checklist node holding that group's entries, in document order
```

**FR-014 vs FR-018, resolved.** FR-014 requires "exactly one checklist"; FR-018 requires entries "grouped
under the phase that encloses them". A checklist node cannot contain a heading, so grouping means one
node per phase. The reading this contract fixes: **one checklist *section* per story** — one `Tasks`
heading, one contiguous block, never two `Tasks` sections. That satisfies FR-014's actual concern (a
reader must not find the task list in two places) and FR-018's grouping together. No downstream task has
to re-decide this.

Entries whose task declares no phase form a single leading group with no phase paragraph. Phase groups
appear in the order their first task appears in `tasks.md`.

## 3. The entry

The shipped rendering is candidate B (research §1): the existing `bulletList`/`listItem` pair, each
item's first span carrying the state glyph.

| Property | Value | FR |
| --- | --- | --- |
| text | the task's `title`, tokenised through the existing Markdown subset into marked spans | FR-016, FR-023 |
| state | a leading span of `"☑ "` when `done` is `true`, `"☐ "` otherwise | FR-025 |
| identity | **none.** `bulletList`/`listItem` carry no identity attribute, so no entry is independently addressed — which is also FR-031's requirement, satisfied by the node choice rather than by discipline | FR-031 |

**Never present in an entry** (FR-017): the `T012` task reference, the durable identifier, the file list,
the dependency list, the parallel-safety marker, the phase text (it is the group's, not the entry's).
A `tasks.md` regenerated with every reference renumbered and its text and order unchanged therefore
renders byte-identical nodes, and produces zero writes.

## 4. Which tasks appear

Exactly the tasks nested under that story in the neutral document — attribution is already resolved by
the nesting (feature 012, FR-003/FR-004).

- A task attributed to no story is nested under no story, so it appears in no checklist (FR-022) and is
  named individually in the run summary with its reason.
- A task attributed to a story the specification does not contain is already dropped upstream with its
  own report; this feature adds nothing.
- A story with zero attributed tasks produces **no section at all** — no heading, no empty list (FR-021).

## 5. Comparison normalisation

Applied **only** when comparing two descriptions, and to both sides equally. Never applied to what is
sent, recorded, or displayed.

> Strip `attrs.localId` from every checklist node and entry node, then compare through
> `json_canonical`.

**Under the shipped candidate B this strips nothing** — `bulletList` and `listItem` have no `localId`, so
the normalisation is the identity function. It ships anyway, as a defensive no-op: it costs one function,
it keeps the two consumers below written against one rule instead of two, and it is what would make a
future move to candidate A a change to one file rather than to the comparison path.

Two consumers, and they answer different questions:

| Consumer | Question | Uses |
| --- | --- | --- |
| `plan_managed_description_status` (`plan_apply.sh:608`) | Is this write churn? | normalised current vs. normalised new (Constitution II) |
| the drift decision, §6 | Did a person edit this? | digest of the normalised **checklist nodes only** vs. the recorded digest |

The precedent and the discipline are `_summary_normalise` (`plan_apply.sh:624`), whose comment states the
same rule. The normalisation was designed for an identity attribute that is required on the node but is
not content; research §1 selected a rendering that has no such attribute, so it is inert and both
consumers below are unaffected.

## 6. Drift decision

Three-way, mirroring `contracts/summary-record.md` §4 from feature 018.

Inputs: the digest of the checklist currently on the ticket, the digest recorded in the identity property,
and the digest of the checklist about to be written.

| current | recorded | desired | Outcome |
| --- | --- | --- | --- |
| any | absent | any | Write. **No warning** — no record means no warning. |
| == recorded | present | any | Write silently. Nobody intervened. |
| != recorded | present | == current | Write. Not drift — a person already made it match `tasks.md`, so there is nothing to protect them from. |
| != recorded | present | != current | **Drift.** Emit the warning below, **then write.** |

```
reconcile: ticket PROJ-42's checklist differs from the one the mirror last wrote — a human appears to
           have edited it since. tasks.md is the source of truth and the checklist has been rewritten
           from it; no box in tasks.md was changed.
```

**The deliberate divergence from the summary contract**, restated here because it is the clause most
likely to be "corrected" by a reviewer who knows the summary rule: a drifted **summary** is omitted from
the payload and only sent under `--on-drift=proceed`; a drifted **checklist** is warned about and then
written. FR-026 requires it — an entry's state follows `tasks.md` in both directions because the checklist
is content the mirror owns inside the managed region, whereas a summary is an independent Jira field a
Product Owner legitimately owns. Constitution I requires the named warning before the overwrite, which is
what this table produces; it does not require withholding.

`--on-drift` does not gate the checklist. A flag that could suppress the rewrite would make `tasks.md`
stop being the source of truth for the tier, which is the opposite of FR-026.

**One direction only** (FR-028): no path in this contract writes to `tasks.md`. A person completing an
entry in Jira is the fourth row above, and its only effect is a warning.

## 7. Size ceiling

When the rendered description including its checklist exceeds what the sink accepts (FR-041):

- the `description` field is omitted from **that one story's** payload;
- every other field of that story is still written;
- every other story, and the specification, still reconcile;
- one warning names the story and the limit, with the remedy (fewer tasks in that story, or `subtask`
  mode for that project).

This reuses the per-field withholding shape `_plan_apply_managed_field` already implements for a
malformed description — the whole field is dropped, the rest of the ticket proceeds — rather than
introducing a second way to fail a field.

## 8. Cross-port equivalence

Both ports emit byte-identical nodes for the same neutral input, through the same `json_canonical` path
every other ADF node already uses. The conformance corpus covers (FR-040):

1. a story with tasks across two phases, mixed complete and incomplete;
2. an unchanged re-run — zero writes;
3. a switch from `subtask` to `checklist`, including the report and its query;
4. a switch from `checklist` back to `subtask`, re-binding by preserved durable identifier;
5. the ceremony's question, its answer, and its byte-for-byte re-run.
