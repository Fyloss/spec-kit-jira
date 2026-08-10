# Contract: the `task_mirror` setting

**Feature**: 022-story-task-checklist | **Normative for**: FR-001…FR-013

This contract is the whole surface an operator and a tech lead see. Every clause is testable without a
Jira instance.

---

## 1. Grammar

Top-level key in `.specify/jira/config.yml`:

```yaml
task_mirror:
  <PROJECT_KEY>: subtask | checklist
```

- `task_mirror` is a mapping. Any other type is an error.
- Each key MUST name a project declared in `projects[]`.
- Each value MUST be exactly `subtask` or `checklist`, lowercase.
- The key MAY be absent entirely, and MAY omit any project. Absence is a third state, not a default
  value — see [data-model.md](../data-model.md) §1.

## 2. Refusals

Each returns `EXIT_CONFIG` (4) with **zero writes**, at config-read time, before any Jira call (FR-004).
The offending value is echoed because it is not credential-shaped; the existing credential-shape guard
over `config.yml` still applies to it unchanged.

| Condition | Message |
| --- | --- |
| `task_mirror` is not a mapping | `config: task_mirror must be a mapping` |
| Key names an undeclared project | `config: task_mirror.<PK> names a project key that is not declared in projects[]` |
| Value is not one of the two | `config: task_mirror.<PK> is '<value>' — accepted values are: subtask, checklist (answer with --task-mirror '<PK>=checklist')` |
| `task_strategy` present | *unchanged from today* — the retired-key refusal. FR-006 forbids resurrecting the name; this row exists so a test pins it after this feature ships. |

No value is ever guessed at, and no invalid value falls back to a default (FR-004).

## 3. The managed region

Written by the ceremony through `managed_section_splice`, mirroring `_config_field_defaults_write`
(`commands/config.sh:579`) exactly — same marker convention, same four outcomes.

```
# --- spec-kit-jira:task_mirror:begin ---
# How each project's task list reaches Jira (022), written by
# `/speckit.jira.config`. `subtask` creates one sub-task per task;
# `checklist` writes one checklist into each story instead. Edit a value here
# by hand if you like — keep it between these markers; an entry outside them
# is a duplicate top-level key and the next read refuses it (exit 4).
task_mirror:
  CONSUMER: checklist
# --- spec-kit-jira:task_mirror:end ---
```

**Outcomes**, in the vocabulary the ceremony already reports:

| Outcome | When |
| --- | --- |
| `inert` | Nothing recorded and the region has never existed. **The file is not touched at all** — no marker is introduced for a team that has chosen nothing (FR-002, FR-011). |
| `created` | The file did not exist. |
| `written` | The region changed. |
| `unchanged` | A re-run with the same answer reproduces the file byte-for-byte (FR-009). |
| `refused` | Malformed markers — `EXIT_CONFIG`, zero writes. |

Every byte outside the region is preserved, including a hand-written entry inside it that the ceremony
did not ask about this run (FR-010).

## 4. The flag

```
--task-mirror <PROJECT_KEY>=<subtask|checklist>
```

Repeatable, one project per occurrence, last occurrence wins for a given key. Parsed in `lib/cli.sh`
beside `--issue-type` and `--field-default`, with the same two usage errors:

| Condition | Message |
| --- | --- |
| No value | `--task-mirror requires a value (--task-mirror KEY=<subtask\|checklist>)` |
| Malformed shape | `invalid --task-mirror value: <arg> (expected <PROJECT_KEY>=<subtask\|checklist>)` |

Accepted by the **config** command, which records it. The reconcile command does not accept it: the mode
is a recorded team decision, not a per-run override — a reconcile flag would be a second way to answer
one question (Constitution XIV) and would sit outside the `config.yml` hash the run-state cache relies
on (research §Cross-cutting).

## 5. The ceremony's question

The ceremony is non-interactive throughout (research §5). A "closed question" is a report line naming
both values and the flag that answers it, in the shape `_config_field_default_notes` already uses.

**Asked** — per project, when nothing is recorded for it (FR-008), whether or not a `task` role is
declared (FR-005):

```
config: project CONSUMER: how should tasks be mirrored — choose one of: subtask, checklist
        (answer with --task-mirror 'CONSUMER=checklist'). Recording nothing keeps today's
        behaviour: one sub-task per task when a task role is declared, and no task tier otherwise.
```

**Not asked** — when a value is already recorded (FR-009). The run is silent about it beyond §6's effect
line, and rewrites `config.yml` byte-for-byte.

**Answered** — the value is spliced into the region, and §6 reports the effect.

**Unanswerable** — no flag was passed. Nothing is recorded, behaviour is unchanged, and the question line
above is the report (FR-011). This is the ordinary path, not an error path.

**FR-012 check** — when the recorded value is `subtask` and no sub-task issue type can be resolved for
that project, the ceremony says so at config time rather than leaving it to the first reconcile:

```
config: project CONSUMER: task_mirror is 'subtask' but no sub-task issue type is resolved for this
        project — declare hierarchy.task, or switch with --task-mirror 'CONSUMER=checklist'
```

## 6. The ceremony's effect line

Reported per project, alongside the effects the run already reports separately (FR-013):

```
Task mirror: CONSUMER — checklist (recorded)
Task mirror: PLATFORM — subtask (unchanged)
Task mirror: OTHER — not recorded; today's behaviour applies
```

## 7. Resolution at reconcile time

`config_task_mirror_for <project_key> <merged-cfg-json>` → `subtask` | `checklist` | `""`.

The empty string is resolved into effective behaviour by the caller, not by this function:

| Recorded | `task` role declared | Effective tier |
| --- | --- | --- |
| `""` | yes | sub-tasks (feature 012, unchanged) |
| `""` | no | none (feature 012, unchanged) |
| `subtask` | yes | sub-tasks |
| `subtask` | no | none, and §5's FR-012 line was already emitted at config time |
| `checklist` | yes | **checklist**; the declared role is reported once as recorded and not consumed |
| `checklist` | no | **checklist** |

The last two rows are FR-007's "exactly one mode per run": the mode wins over the role, and no task ever
receives both a sub-task and an entry.
