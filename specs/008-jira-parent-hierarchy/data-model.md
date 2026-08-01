# Phase 1 Data Model: A Specification Mirrors as a Jira Hierarchy

Every structure below is either new in this feature or changed by it. Structures the feature
leaves alone are named only where a reader would reasonably expect them to change.

---

## 1. The parent marker line (in `spec.md`)

The durable identifier for a specification's parent artifact, written into the specification
itself. Grammar, placement and write rules are fixed in
[contracts/parent-marker.md](./contracts/parent-marker.md); this section records the data.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | 16 lowercase hex characters | 8 bytes of randomness, or the next value from `SPEC_KIT_JIRA_ID_SOURCE` under the conformance gate |
| `state` | `assigned` \| `creating` \| `bound` | The same three states a story marker has |
| `ticket` | Jira issue key | Present only in `bound` |

Written forms:

```markdown
<!-- speckit-jira spec=3f2a91c04b7e6d18 -->
<!-- speckit-jira spec=3f2a91c04b7e6d18 creating -->
<!-- speckit-jira spec=3f2a91c04b7e6d18 ticket=COMP-412 -->
```

**Cardinality**: exactly one per specification file. Two or more `spec=` lines is the `duplicate`
state and blocks the whole specification — unlike a duplicate story marker, which blocks only the
story it names, because there is no sibling to spare.

**State transitions**:

```text
absent ──assign──▶ assigned ──plan a creation──▶ creating ──create succeeds──▶ bound
                       ▲                                                          │
                       └──────────── recorded key returns 404 ────────────────────┘
```

`creating` is the interrupted-run window. A run that finds it refuses the whole specification and
tells the operator how to resolve it by hand, exactly as the story marker's `creating` state does
today — the difference being that a `creating` parent blocks every story too, since none of them
may be created without a verified parent.

---

## 2. The neutral interchange document

The only object crossing engine → sink. Validated before any write.

**Removed**: `epic.strategy`. The schema rule at `scripts/bash/engine/interchange.sh:38` and its
PowerShell mirror at `Interchange.psm1:74` go with it, as does the `epic_strategy` argument in
`interchange_build`'s context.

**Added** under `epic`:

| Field | Type | Notes |
| --- | --- | --- |
| `epic.local_id` | string | The parent marker's `id`; empty when the marker is absent |
| `epic.marker` | object | `{state, id, ticket?, lines[]}` — the same slim view stories carry |

**Changed**: `epic.description.blocks` now carries more than the opening two paragraphs. See §7.

```jsonc
{
  "schema_version": "1.0",
  "spec_ref": { "repo": "acme/app", "spec_slug": "001-billing-invoices", "folder": "specs/…" },
  "routing": { "project_key": "COMP" },
  "epic": {
    "local_id": "3f2a91c04b7e6d18",
    "marker": { "state": "bound", "id": "3f2a91c04b7e6d18", "ticket": "COMP-412", "lines": [3] },
    "title": "Billing invoices",
    "description": { "blocks": [ /* …see §7… */ ] }
  },
  "stories": [ /* unchanged */ ]
}
```

**Validation rules** (both ports, byte-identical errors):

- `epic.title` non-empty — unchanged.
- `epic.description.blocks` non-empty — unchanged.
- `epic.strategy` — **removed**; a document still carrying one is not an error, it is simply
  ignored, because the field no longer exists in the producer.
- `epic.local_id` — required and 16 hex characters **unless** the marker state is `absent`, which
  only happens on a dry run of a specification the bridge has never touched.

---

## 3. The persisted binding (`config.local.yml` → `resolved_ids.<KEY>`)

The machine-owned, gitignored instance facts. This is the structure R5 unflattens.

**Before** (shipped today):

```yaml
resolved_ids:
  COMP:
    style: company_managed
    issue_types: { Epic: "10001", Story: "10004" }
    priorities: { Highest: "1", Medium: "3", Low: "4" }
    statuses: { To Do: "10000" }
    estimation_field_id: "customfield_20011"
```

**After**:

```yaml
resolved_ids:
  COMP:
    style: company_managed
    style_source: api
    issue_types:
      - { logical_name: "Initiative",  id: "10100", hierarchy_level: 2,  subtask: false }
      - { logical_name: "Deliverable", id: "10101", hierarchy_level: 1,  subtask: false }
      - { logical_name: "Story",       id: "10102", hierarchy_level: 0,  subtask: false }
      - { logical_name: "Defect",      id: "10103", hierarchy_level: 0,  subtask: false }
      - { logical_name: "Sub-task",    id: "10104", hierarchy_level: -1, subtask: true  }
    child_type:  { logical_name: "Story",       id: "10102", source: operator }
    parent_type: { logical_name: "Deliverable", id: "10101", source: derived  }
    required_fields:
      "10101": [ { logical_name: "Summary", field_id: "summary" } ]
      "10102": [ { logical_name: "Summary", field_id: "summary" } ]
    priorities: { Highest: "1", Medium: "3", Low: "4" }
    statuses: { To Do: "10000" }
    estimation_field_id: "customfield_20011"
```

| Field | Type | Source | Notes |
| --- | --- | --- | --- |
| `issue_types` | list of objects | discovery | Was a map; the level and sub-task flag were being discarded at exactly this point |
| `child_type` | object | derived or operator | `source: derived` when the child level held one candidate, `operator` when the ceremony asked (R2) |
| `parent_type` | object | derived | `source` is always `derived`; an ambiguous parent level refuses instead of asking (FR-006) |
| `required_fields` | map, issue-type id → list | create metadata | Only for the two written types (R4); `logical_name` is Jira's `name`, used verbatim in refusals |

**Every `logical_name` is quoted on write, unconditionally** — in `issue_types`, in `child_type`,
in `parent_type` and in `required_fields`. This is not stylistic. Feature 007 fixed a reader that
truncated a binding whose names carried the instance's own language or ordinary punctuation
(`Récit`, `Приоритет`, `完了`, `Done (QA)`, `high/low`), and it fixed it for mapping **keys**. This
section moves the logical name out of the key position and into a **value**, so that protection
does not carry over on its own: the quoting rule and the fail-closed read must be extended to the
new shape in the same change (FR-003b). A name the reader cannot unescape refuses with 007's
located, redacted message; it is never silently dropped.

An issue-type name is opaque text. The bridge does not parse it, translate it, normalise it,
case-fold it or match it against anything — which is precisely why no list of supported languages
exists or is needed.

**Shape compatibility**: none, deliberately. A binding whose `issue_types` is a map was written by
an earlier version. Reconcile detects the map shape **before attempting any type resolution** and
fails closed with its own message — `binding-shape-stale`, which says the binding predates parent
support and points at `/speckit.jira.config`. It is deliberately *not* the "project has not been
bound yet" message: the project is bound, its binding is a version behind, and an operator who has
already run the ceremony reads the wrong message as a bug. The file is gitignored and regenerated
in seconds, so a migration branch would be dead code (R5).

This is the state of **every existing installation** on its first run after the change, so the
detection ships with tests in both ports and a conformance scenario.

**A note on the committable side.** `projects[].issue_types` in a team config — a stray key
present only in one conformance fixture, read by nothing — is deleted rather than kept as a slot
for the future Story-versus-Task switch. That switch declares a logical *name*; this map holds
*identifiers*, which belong here in the binding (R11).

---

## 4. The identity marker (Jira entity property `spec-kit-jira`)

| Field | Type | Notes |
| --- | --- | --- |
| `origin` | `bridge` \| `human` | Unchanged |
| `repo` | string | Unchanged |
| `spec_slug` | string | Unchanged |
| `role` | `parent` \| `story` | **New** (R6) |
| `story` | 16 hex | Unchanged; present only when `role` is `story` |

```jsonc
{ "origin": "bridge", "repo": "acme/app", "spec_slug": "001-billing-invoices", "role": "parent" }
{ "origin": "bridge", "repo": "acme/app", "spec_slug": "001-billing-invoices", "role": "story",
  "story": "9c4e1b77a0d3f562" }
```

A marker with no `role` was written before this feature. It is treated as `story` when it carries
a `story` field and as *unrecognised* otherwise — never as a parent. `identity_claimed_by_other`
still compares `repo` and `spec_slug` alone and works unchanged for both roles.

---

## 5. The plan context

Built by `_reconcile_plan_context` from the binding and the recognition result.

**Removed**: nothing — but `story_type_id` changes provenance. It was
`jq -r '.issue_types.Story'` (`scripts/bash/commands/reconcile.sh:236`); it becomes
`jq -r '.child_type.id'`.

**Added**:

| Field | Type | Notes |
| --- | --- | --- |
| `parent_type_id` | string | From `resolved_ids.<KEY>.parent_type.id` |
| `parent_key` | string | The recognised parent's issue key; empty when the parent is to be created |
| `parent_local_id` | string | The parent marker's id, so the create action can carry it for recording |
| `parent_current` | object | The parent's current Jira fields, for the zero-churn comparison |
| `parent_supports_link` | bool | Whether the child type's create metadata offers `parent` (R4) |

---

## 6. The write plan

`plan_writes` changes return type (R7).

**Before**: `[ {method, url, body, local_id?}, … ]`

**After**:

```jsonc
{
  "parent": {
    "method": "POST",
    "url": "…/rest/api/3/issue",
    "body": { "fields": { "project": {…}, "issuetype": {"id": "10101"}, "summary": "…",
                          "description": {…} } },
    "local_id": "3f2a91c04b7e6d18",
    "role": "parent"
  },
  "stories": [
    { "method": "POST", "url": "…/rest/api/3/issue",
      "body": { "fields": { …, "parent": { "key": "<resolved at apply time>" } } },
      "local_id": "9c4e1b77a0d3f562", "role": "story" }
  ]
}
```

`parent` is `null` when the parent is recognised and unchanged. When the parent is recognised and
its bridge-owned content differs, `parent` is a `PUT` and `stories` carry the literal key.

**Ordering invariant**: the parent action is performed, and its response key read, before the
first story action is scanned for writing. `plan_lifecycle` continues to fold over `stories` only.

---

## 7. What the parent's description carries

The parser produces neutral content blocks; the sink renders them. This is the content change
behind FR-010 and FR-011.

| Section | Source in `spec.md` | Rendered as |
| --- | --- | --- |
| *(no heading)* | The overview prose already extracted — up to two paragraphs before the first Acceptance / Design / Task / Scenario / Requirement / Success / Edge heading | Paragraphs |
| Success Criteria | The `### Measurable Outcomes` list under `## Success Criteria` | A named heading and a bullet list, each item a complete sentence with its `SC-00N` label stripped |
| Out of Scope | The `## Out of Scope` list | A named heading and a bullet list |
| Implementation Plan | `plan.md`'s summary prose (US5, P3) | A named heading and paragraphs |

**Not carried**, and each for a stated reason:

- **A list of user stories** — FR-011. Jira renders the children natively, and the parent exists
  before its children do, so any such list costs a second write on the first run.
- **Functional requirements** — settled in the spec's clarification: the parent is a brief, not a
  copy of the document.
- **Front-matter, marker lines, the `**Input**:` block** — Constitution XVI. `parse_spec` already
  strips marker lines before extraction; the same exclusion covers the `spec=` line.
- **Per-story Gherkin, design links, priority, estimation** — these stay on the child, unchanged.

---

## 8. The recognition result

`recognition_run` gains a parent. Its output grows one key rather than changing shape:

```jsonc
{
  "parent": {
    "state": "bound" | "new" | "blocked",
    "key": "COMP-412",
    "current": { /* fields, for the zero-churn comparison */ },
    "reason": "…", "detail": "…"          // present only when blocked
  },
  "bound": { /* unchanged */ },
  "new": [ /* unchanged */ ],
  "blocked": [ /* unchanged */ ],
  "rerouted": { /* unchanged */ }
}
```

**Decision table for the parent** — the full version with diagnostics lives in
[contracts/hierarchy-resolution.md](./contracts/hierarchy-resolution.md):

| Marker state | Read result | Parent state | Stories |
| --- | --- | --- | --- |
| `absent` | *(not read)* | `new` | planned |
| `assigned` | *(not read)* | `new` | planned |
| `creating` | *(not read)* | `blocked` | **none planned** |
| `duplicate` | *(not read)* | `blocked` | **none planned** |
| `malformed` | *(not read)* | `blocked` | **none planned** |
| `bound` | 404 | `new` (re-created, reported) | planned |
| `bound` | ok, `role: parent`, same spec | `bound` | planned |
| `bound` | ok, different spec | `blocked` | **none planned** |
| `bound` | ok, no marker or no `role` | `blocked` | **none planned** |
| `bound` | transport failure | *(propagates the exit code, zero stdout)* | **none planned** |

The right-hand column is FR-012 in table form: every parent outcome that is not `new` or `bound`
stops the specification before a single child is planned.

---

## 9. Entities the feature deliberately does not change

- **Story marker** — grammar, placement, states and splice are untouched. `spec_marker.sh` calls
  the same primitives rather than copying them.
- **`plan_lifecycle`** — drift, Flagged handling, blockers and transitions apply to stories only.
  A parent has no status target, so it has no transition to withhold.
- **The privacy guard** — mechanism unchanged; the scanned set grows by one payload (R8).
- **The managed-panel splice** — a human-edited parent description is spliced exactly as a
  human-edited story description is.
