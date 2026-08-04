# Phase 1 — Data model: entities, document shapes, traceability

Every shape below is canonical JSON in the sense `lib/output.sh` means it: sorted keys, compact, raw
UTF-8, no trailing newline. Anything crossing the port boundary is byte-identical or the conformance
gate fails.

---

## 1. The task marker, in `tasks.md`

A line of its own, immediately after the task line it belongs to.

| State | Written form | Meaning |
| --- | --- | --- |
| assigned | `<!-- speckit-jira task=<id> -->` | the bridge owns this task; no ticket yet |
| creating | `<!-- speckit-jira task=<id> creating -->` | a creation was planned and the write pass has begun |
| bound | `<!-- speckit-jira task=<id> ticket=<KEY> -->` | mirrored; `<KEY>` is the sub-task |

`<id>` is 16 lowercase hex characters, from `story_marker_generate_id`'s generator and its
`SPEC_KIT_JIRA_ID_SOURCE` test seam — the only reason two ports can be byte-identical over a random
value.

**Non-collision.** `story=` and `spec=` bodies MUST parse as `none` here, and `task=` MUST parse as
`none` in the other two modules — the same construction `spec_marker` and `story_marker` already use
against each other: the body is matched against `^task=`.

**Parse result** (`task_marker_parse_line`):

```json
{"kind":"none"}
{"kind":"valid","id":"3f8a1c02d94b7e65","state":"assigned"}
{"kind":"valid","id":"3f8a1c02d94b7e65","state":"creating"}
{"kind":"valid","id":"3f8a1c02d94b7e65","state":"bound","ticket":"PROJ-412"}
{"kind":"malformed","id":"3f8a1c02d94b7e65"}
```

A malformed attempt still counts as present: assignment never adds a second marker beside one that is
merely broken. Two task lines carrying the **same** id is the duplicate of FR-018 — both are refused,
both named, and every other task still mirrors.

---

## 2. A parsed task, as the engine emits it

`tasks_parse` reads `tasks.md` and emits neutral content only. No Jira identifier, no issue type, no
project key can appear here (FR-005) — the boundary grep enforces it.

| Field | Type | Source in `tasks.md` | Consumed by |
| --- | --- | --- | --- |
| `local_id` | 16-hex string | the marker line | recognition (FR-013) |
| `task_ref` | string (`T014`) | the task line | reporting only — never recognition |
| `title` | string | the task text, marker and file-only markup removed | summary (FR-008) |
| `description.blocks` | array | the task and its continuation lines | description (FR-009) |
| `attribution.story_ordinal` | integer or `null` | `[US<N>]`, else the phase heading | parenting (FR-003) |
| `attribution.source` | `"tag"` \| `"heading"` \| `"none"` | which of the two supplied it | reporting |
| `phase` | string | the enclosing `## Phase …` heading | description |
| `parallel` | boolean | the `[P]` marker | description |
| `files` | array of strings | paths named in the task text | description |
| `depends_on` | array of strings | `(depends on T012, T013)` | description |
| `done` | boolean | `- [x]` vs `- [ ]` | completion (FR-029) |
| `marker` | object | `task_marker_section_info`'s result | assignment and drift |

**Validation the parser enforces before anything downstream sees a task**

- A task whose `title` is empty once the identifier and markup are removed produces no entry and is
  reported by `task_ref` (Edge Cases) — an untitled sub-task is unusable in Jira's own UI.
- A file holding no recognisable task yields an empty list, not an error.
- A missing `tasks.md` yields an empty list and no report at all (FR-001).

---

## 3. The neutral interchange document, extended

```jsonc
{
  "schema_version": "1.0",
  "spec_ref": { "repo": "…", "folder": "…", "spec_slug": "012-jira-task-subtasks" },
  "routing": { "project_key": "PROJ" },
  "epic": { "…": "unchanged" },
  "stories": [
    {
      "local_id": "…", "title": "…", "priority_logical": "P1",
      "description": { "blocks": [ "…" ] },
      "tasks": [
        {
          "local_id": "3f8a1c02d94b7e65",
          "task_ref": "T014",
          "title": "Implement the neutral task parser",
          "description": { "blocks": [ "…" ] },
          "attribution": { "story_ordinal": 1, "source": "tag" },
          "phase": "Phase 3: User Story 1",
          "parallel": true,
          "files": [ "scripts/bash/engine/tasks_parse.sh" ],
          "depends_on": [ "T012" ],
          "done": false,
          "marker": { "state": "assigned", "id": "3f8a1c02d94b7e65", "ticket": "", "lines": [ 41 ] }
        }
      ]
    }
  ]
}
```

`tasks` is **absent** — not an empty array — on every story when no `task` role is declared. That is
what makes FR-011's byte-identical guarantee hold at the document level and not merely at the write
level.

**Schema rules added to `_INTERCHANGE_ERRORS_JQ`** (each blocks every write of the run):

| Rule | Requirement |
| --- | --- |
| `story.tasks` is an array when present | FR-002 |
| `task.local_id` matches `^[0-9a-f]{16}$` unless the marker state is `absent` | FR-013 |
| `task.title` is non-empty | FR-008, Edge Cases |
| `task.description.blocks` is non-empty | FR-009 |
| `task.done` is a boolean | FR-029 |
| no two tasks in the document share a `local_id` | FR-018 |

Unattributed and dangling tasks never reach the document: they are reported during assembly and
carried into the summary as skipped, by `task_ref`, with a reason (FR-004, FR-028).

---

## 4. The plan's third array

```jsonc
{
  "parent":  { "…": "unchanged" },
  "stories": [ { "…": "unchanged" } ],
  "tasks": [
    {
      "method": "POST",
      "url": "…/rest/api/3/issue",
      "body": { "fields": { "project": {}, "summary": "…", "issuetype": {}, "description": {},
                            "parent": { "key": "<resolved at apply time>" } } },
      "local_id": "3f8a1c02d94b7e65",
      "parent_local_id": "<the story's local id>",
      "role": "task"
    }
  ]
}
```

`role: "task"` is what the identity stamp records and what the summary counts on. `parent_local_id` is
the only new resolution input: `apply_writes_with_recognition` builds `local_id → key` as the story
writes complete and substitutes it, exactly as it already substitutes the epic's key into every story
creation.

**A transition action** carries no body fields beyond the transition id and is planned only for a task
whose `done` is true and whose recognised sub-task is not already in a done-category status:

```jsonc
{ "method": "POST", "url": "…/rest/api/3/issue/PROJ-412/transitions",
  "body": { "transition": { "id": "31" } }, "role": "task-transition" }
```

---

## 5. The task-tier satisfiability verdict

Separate from `hierarchy_mandatory_gate`, which keeps its two-type, all-or-nothing answer.

```jsonc
{ "status": "ok" }
{ "status": "unsatisfiable", "fields": [ { "logical_name": "Program Increment" } ], "message": "…" }
{ "status": "undefaultable", "fields": [ { "logical_name": "Team", "reason": "…" } ], "message": "…" }
```

Anything but `ok` drops the whole `tasks` array from the plan before the lifecycle filter and before
any splice. The message names each field by its Jira label and carries feature 011's existing
copy-pasteable `--field-default` remedy.

---

## 6. The run summary's per-tier counts

```jsonc
"counts": {
  "created": 4, "updated": 0, "skipped": 3, "warnings": 1, "errors": 0,
  "recognised": 3, "assigned": 0,
  "tasks": { "created": 12, "updated": 0, "transitioned": 2,
             "unchanged": 5, "skipped": 6, "withheld": 0 }
}
```

The nested `tasks` object is emitted **only** when a `task` role is declared. Every task in the file
is accounted for across `created + updated + transitioned + unchanged + skipped + withheld`, which is
what SC-006 measures.

---

## 7. Requirement traceability

| Requirement | Carried by |
| --- | --- |
| FR-001, FR-002 | `engine/tasks_parse` (§2) |
| FR-003, FR-004 | `attribution` (§2), document assembly (§3) |
| FR-005 | engine-side only; the boundary greps |
| FR-006, FR-007 | the plan's `tasks` array and `parent_local_id` (§4) |
| FR-008, FR-009 | `title` and `description.blocks` (§2) |
| FR-010, FR-011 | `tasks` absent from the document and the counts (§3, §6) |
| FR-012 | retiring the two stale status lines (`commands/config.sh`, `sink/jira/hierarchy.sh`) |
| FR-013, FR-014 | the marker (§1) and `marker_splice` |
| FR-015, FR-016 | recognition on `local_id`; the zero-churn drop in `plan_lifecycle` |
| FR-017, FR-018 | absent-marker handling and the duplicate-id schema rule (§1, §3) |
| FR-019, FR-020 | the existing update and drift paths, over sub-task content |
| FR-021, FR-022 | reported, never performed — summary notes |
| FR-023, FR-037 | the nested counts (§6) |
| FR-024 | the plan computed identically in both modes |
| FR-025 | `privacy_guard_scan` over every task body in the pre-write gate |
| FR-026 | the command layer's existing non-blocking hook wrapper |
| FR-027 | the conformance corpus |
| FR-028 | assembly-time reporting (§3) |
| FR-029, FR-030, FR-031 | the transitions read and the done-category selection (§4) |
| FR-032, FR-033 | withheld backward transitions; no write back into `tasks.md` |
| FR-034, FR-035 | feature 011's per-type maps; the ceremony scope |
| FR-036, FR-038, FR-039 | the task-tier verdict and the plan-time drop (§5) |
| FR-040 | the single consolidated question, over all three tiers |
| FR-041 | no default on a transition body (§4) |
| FR-042 | feature 011's existing provenance reporting |
