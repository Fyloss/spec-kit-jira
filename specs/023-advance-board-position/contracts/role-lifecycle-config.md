# Contract — `phase_status_map`, declared per hierarchy role

Covers spec FR-017, FR-018, FR-019, FR-020, FR-022, FR-023, FR-025, FR-029, FR-039. The governing rule:
**a ticket is only ever evaluated against the mapping declared for its own role**, and a project that
declares nothing sees no change of any kind.

## 1. The two accepted shapes

`projects[].phase_status_map`, in the committable team layer, beside the mapping it extends.

```yaml
projects:
  - key: COMP
    hierarchy:
      specification: "Epic"
      story: "Story"
      task: "Sub-task"

    # Shape 1 — legacy. Every key is a lifecycle event. Means the STORY role.
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"

    # Shape 2 — per role. Every key is a hierarchy role.
    phase_status_map:
      specification:
        after_plan: "Building"
      story:
        after_specify: "To Do"
        after_plan: "In Progress"
      task:
        after_implement: "Done"

    halted_statuses:
      - "Blocked"
```

A project may declare one role, two, or all three. Declaring more than one is never required (FR-017).

`halted_statuses` stays **project-wide** and is not split per role: a status name only matches tickets
actually standing at it, so one list covering three workflows behaves correctly, and splitting it would add
a configuration surface no requirement needs (spec Assumptions, and FR-025's one-change rule).

## 2. Discrimination — two closed, disjoint key sets

| Set | Members | Source of truth |
| --- | --- | --- |
| Lifecycle events | `after_specify`, `after_clarify`, `after_plan`, `after_tasks`, `after_implement`, `after_analyze` | `extension.yml`'s `hooks:` block; `lifecycle-event.md` §1 |
| Hierarchy roles | `specification`, `story`, `task` | `JIRA_ROLE_NAMES` (`lib/config.sh:1015`) — the repository's single source for the role set |

The sets share no member, so the rule is total:

| All keys are… | Verdict |
| --- | --- |
| lifecycle events | Shape 1 — the whole mapping is the **story** role's |
| hierarchy roles | Shape 2 — each value is that role's own event → status mapping |
| empty mapping | Inert. Identical to declaring nothing. |
| a mix of the two sets, or any key in neither | **Config refusal** — see §3 |

No version marker, no nesting hint, and no new key is introduced (FR-025). The discrimination needs none,
and a marker would be a surface a reader has to learn.

## 3. Validation

Every message names the file position, the offending key, and a copy-pasteable correction (Principle XVI).
All are config refusals — `EXIT_CONFIG` (`4`), before any read of the tracker and with zero writes.

| Condition | Message |
| --- | --- |
| `phase_status_map` is not a mapping | `projects[<i>].phase_status_map must be a mapping of lifecycle-event name to status name, or of hierarchy role to that role's own mapping` |
| Mixed key sets | `projects[<i>].phase_status_map mixes lifecycle events and hierarchy roles; declare either one mapping for the story role, or one mapping per role (specification, story, task)` |
| A key in neither set | `projects[<i>].phase_status_map declares unknown key \`<k>\`; the lifecycle events are after_specify, after_clarify, after_plan, after_tasks, after_implement, after_analyze and the roles are specification, story, task` |
| Shape 1, a value is not a non-empty string | `projects[<i>].phase_status_map.<event> must be a non-empty status name` |
| Shape 2, a role's value is not a mapping | `projects[<i>].phase_status_map.<role> must be a mapping of lifecycle-event name to status name` |
| Shape 2, a role's inner key is not an event | `projects[<i>].phase_status_map.<role> declares unknown lifecycle event \`<k>\`` |
| Shape 2, an inner value is not a non-empty string | `projects[<i>].phase_status_map.<role>.<event> must be a non-empty status name` |

The existing message for shape 1 (`lib/config.sh:928–930`) is preserved verbatim where it still applies, so
a project that has been valid stays valid with byte-identical diagnostics.

A role declared here that the project's `hierarchy:` does not name is **not** a validation error — it is the
inert case of §5. Refusing it would fail a run over a workflow declaration that harms nothing.

## 4. The resolved form

Both shapes normalise to one, so every consumer has a single case (`data-model.md` §1):

```json
{"specification":{"after_plan":"Building"},"story":{"after_specify":"To Do"},"task":{}}
```

All three keys are always present; a role the project declares nothing for is an empty object. Derived once
per run, per role — never per ticket (FR-029):

| Value | Definition | Consumer |
| --- | --- | --- |
| `target` | `resolved[<role>][<hook_event>]`, else `""` | the step this run aims for, for that role's tickets |
| `order` | the distinct values of `resolved[<role>]`, in lifecycle-event order | `drift_evaluate`'s advance/regress comparison |
| `mapped_targets` | the set of values of `resolved[<role>]` | classifying a ticket's own status as `mapped` |

**Resolution reads the configuration the run has already parsed** — `_reconcile_phase_status_map`
(`commands/reconcile.sh:1474`) is handed the parsed object. Three declared roles cost no additional open and
no additional parse (FR-029, spec SC-015).

## 5. Per-role isolation, and the inert cases

| # | Rule |
| --- | --- |
| I1 | A ticket is evaluated only against `resolved[<its own role>]`. A step name declared for one role never enters another role's decision, classification, warning, or reachable set (FR-018). |
| I2 | A role with an empty mapping is never moved, never warned about, and costs no question to the tracker (FR-019). |
| I3 | The same status name appearing in two roles' mappings is a coincidence with no effect — each role resolves only against its own tickets' available moves. |
| I4 | A `task` mapping takes effect only where `config_task_mirror_for` returns `subtask`. Under `checklist`, or where the project declares no `task` role, it is inert (FR-022). |
| I5 | An inert mapping produces **one note per run**, never one per ticket and never a warning: `the task-role lifecycle mapping for <PROJECT> has no effect while its tasks are mirrored as a checklist`. Wording for the no-task-role case names that instead. |
| I6 | A sub-task the mirror abandoned when the project switched to `checklist` — its marker still in `tasks.md`, its ticket still in the tracker — never enters the move set (FR-023). |
| I7 | A `checklist`-mode task list is part of the story's managed description, so the **story** role's mapping governs it, exactly as it governs a story with no tasks at all. |

## 6. Back-compatibility

| # | Guarantee |
| --- | --- |
| B1 | A committed shape-1 mapping keeps its current meaning: the story role's. Its diagnostics, its classification, and its warnings are byte-identical to today. |
| B2 | Upgrading never starts moving a specification-tier parent or a sub-task on the strength of a mapping written before roles existed (FR-020). |
| B3 | A project that declares no `phase_status_map` at all sees no change on any channel. |
| B4 | The config ceremony asks no new question. Both keys stay hand-edited, as `docs/VISION.md` Part 2 item 3 records; proposing a mapping at config time remains out of scope. |

## 7. Scenario coverage

| Case | Assertion |
| --- | --- |
| Shape 1, story at one agreed step behind | Story advances; parent and sub-tasks untouched (B1, B2) |
| Shape 2, different steps for `specification` and `story`, one event | Parent lands on its step, each story on its own; zero cross-role evaluations (I1) |
| Shape 2, `story` only | Stories advance; parent not moved; no warning about the parent (I2) |
| Shape 2, `task`, project in `subtask` mode | Sub-tasks whose task is unchecked advance (I4) |
| Shape 2, `task`, project in `checklist` mode | Zero tickets created or moved; exactly one note per run (I4, I5) |
| Shape 2, `task`, project declares no `task` role | Same — one note, no failure (I4, I5) |
| `checklist` mode with an abandoned sub-task marker in `tasks.md` | That key never enters the move set (I6) |
| Same status name under two roles | Each role resolves against its own tickets only (I3) |
| Mixed key sets | Exit `4`, zero requests, the §3 message |
| Unknown key in either position | Exit `4`, zero requests, the §3 message |
| Empty `phase_status_map: {}` | Inert; identical to absent |
| Three roles declared, counting stand-in on config opens | One open, one parse — unchanged from a one-role project (FR-029) |
| Both ports, every case above | Byte-identical diagnostics, resolved form, and call sequence |
