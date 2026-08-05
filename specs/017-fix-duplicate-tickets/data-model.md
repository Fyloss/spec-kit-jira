# Phase 1 — Data model

No file format changes. No configuration key is added. The neutral interchange document and its
schema are untouched. What follows is every value whose **shape** changes, and where.

## 1. The target decision (User Story 1)

Not persisted anywhere. A value computed once, at the top of `cmd_reconcile`, from the positional
argument alone.

| Field | Source | Values |
| --- | --- | --- |
| `target_path` | the run's first positional argument | the path as the caller spelled it |
| `target_name` | the path's last component, split by the port's own primitive | any file name |
| `sibling_spec` | `<dirname(target_path)>/spec.md`, when that file exists | a path, or absent |

**Rule**: the run proceeds iff `target_name == "spec.md"` (byte equality, case-sensitive). The
decision consumes no configuration, no credential, and no network. See
[contracts/target-guard.md](./contracts/target-guard.md).

## 2. The stray-marker report (FR-007)

Computed on a **valid** run, from the filesystem, discarded when the run ends.

| Field | Source |
| --- | --- |
| `stray_files` | every top-level file of the feature folder, excluding `spec.md`, that contains the bridge's marker framing comment — sorted, as bare file names |

Emitted as one entry in the run summary's existing `warnings` array when non-empty; nothing at all
when empty. No file in `stray_files` is opened for writing, ever.

## 3. The provenance label (User Story 2)

### Derivation

| Value | Definition |
| --- | --- |
| provenance slug | the neutral document's `spec_ref.spec_slug` — already validated as `^[0-9]{3}-[a-z0-9-]+$` by `interchange_validate` |
| provenance label | `"speckit-" + <provenance slug>` — a sink literal joined to a neutral value |
| `JIRA_LABEL_MAX_LENGTH` | sink constant, `255` — the label is omitted, never truncated, when it would exceed this (contract §4) |

The engine gains nothing. The label string exists only under `sink/jira/`. The regex above bounds
the slug's alphabet but not its length, which is why the constant exists.

### Recognition — two field lists gain `labels`

`sink/jira/recognition.sh`:

| Site | Today | After |
| --- | --- | --- |
| `_recognition_read` (L36) | `summary,description,priority,status,issuelinks,parent` | `…,parent,labels` |
| `_recognition_read_parent` (L71) | `summary,description` | `summary,description,labels` |

and the two `current` objects each gain one key, **normalised on ingest**:

```jsonc
// story  (recognition.sh L360)          // parent (recognition.sh L175)
{ "summary": "…", "description": {…},    { "summary": "…", "description": {…},
  "priority": …, "parent": …,              "labels": ["speckit-001-test-page", "team-x"] }
  "labels": ["…"] }
```

`labels` is always `(.fields.labels // []) | unique` — sorted and deduplicated. That normalisation
is load-bearing, not cosmetic: the zero-churn comparison is `jq`'s `==`, which compares arrays by
position (research R4).

### Plan context — one new map, one extended object

`_reconcile_plan_context` (`commands/reconcile.sh` L332-361) already derives `tickets`,
`ticket_origins`, `ticket_descriptions` and `ticket_parents` from `recog.bound`. It gains:

| Key | Shape | Rule |
| --- | --- | --- |
| `ticket_labels` | `{<local_id>: ["…"]}` | from `bound[*].current.labels`; omitted entirely when empty, like every neighbouring map |
| `parent_current.labels` | `["…"]` | already threaded as `parent_current`; gains the key with the parent recognition read |
| `provenance_label` | `"speckit-001-test-page"` | derived by the sink from the document; **not** stored in the context |

### Payloads

| Path | Site | Desired `labels` |
| --- | --- | --- |
| create (both mirror roles) | `jira_create_fields_base`, `sink/jira/ticket.sh` L64 | `((field_defaults.labels // []) + [provenance]) \| unique` — merged **after** the field-defaults spread, so a recorded `labels` default is preserved rather than overwritten |
| create (feature ceremony) | `_ticket_create_body`, `sink/jira/ticket.sh` L103 | none — the builder's provenance parameter is not passed, so no `labels` key is produced |
| update, story | `plan_writes` update branch, `plan_apply.sh` L261 | `(ticket_labels[sid] + [provenance]) \| unique` |
| update, parent | `_plan_writes_parent` recognised branch, `plan_apply.sh` L334 | `(parent_current.labels + [provenance]) \| unique` |

The union is simultaneously the merge rule (Jira's `PUT` replaces the whole array, so the union is
what preserves an operator's own labels) and the zero-churn rule (a settled ticket's union equals
its current list, so `idempotency_field_status` reports `unchanged` and the action is dropped).

**Suppression**: a ticket whose content write is withheld — halted status, Flagged, unresolved drift
— has its whole action dropped by `plan_lifecycle`, and the label goes with it. No separate rule is
needed; FR-018 is satisfied by not making the label an exception.

## 4. The duplicate probe (User Story 4)

Nothing persisted. One request, one derived verdict.

| Field | Definition |
| --- | --- |
| query | `project = "<KEY>" AND labels = "<provenance label>"` |
| result | `hit` (one or more keys), `clear` (none), or `unavailable` (any non-2xx) |
| `found_keys` | the issue keys returned, sorted, for the refusal message |

Fired **only** when the planning pass is about to create a parent for which the specification holds
no marker. Never on a settled run, never on a run whose parent is recognised. See
[contracts/duplicate-probe.md](./contracts/duplicate-probe.md).

## 5. Run summary

The existing schema is sufficient; no field is added.

| Outcome | Where it appears |
| --- | --- |
| rejected target | the refusal message + exit `1`; no summary is emitted, exactly as every other pre-config refusal |
| stray markers | one string in `warnings` |
| label degraded | one string in `warnings` |
| probe refusal | the refusal message + exit `4`; no summary is emitted, so no `warnings` entry — the refusal returns early, like the rejected target (contract §4) |
| probe unavailable | one string in `warnings` |
| labels sent | inside each action's `body.fields.labels` — visible in `--dry-run` with no new field |

`counts.updated` rises by one per ticket back-filled on the run that back-fills it, and returns to
zero on the run after. That is a state change, not churn.
