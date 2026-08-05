# Contract — the task tier

Normative. Where this contract and a functional requirement disagree, the requirement wins and this
document is the defect.

---

## §1 The marker grammar

```
<!-- speckit-jira task=<16 lowercase hex> -->
<!-- speckit-jira task=<16 lowercase hex> creating -->
<!-- speckit-jira task=<16 lowercase hex> ticket=<ISSUE KEY> -->
```

- Exactly one space between tokens in the **written** form. The **parsed** form tolerates leading and
  trailing whitespace and a trailing `\r`.
- An issue key matches `^[A-Z][A-Z0-9_]*-[1-9][0-9]*$`. A `ticket=` tail that does not is
  `malformed`, never `bound`.
- A body that does not start `task=` parses as `none`. `story=` and `spec=` therefore never collide,
  and neither of those two modules recognises `task=`.

**Placement.** The marker line goes immediately after the task line it belongs to. Assignment inserts
in descending line order so that no insertion shifts a lower anchor's line number — the same
construction `story_marker_assign` uses.

**Idempotence.** Assignment over a file where every task already carries a marker attempt returns the
input byte-for-byte, including its line endings.

---

## §2 Reading `tasks.md`

| Input | Outcome |
| --- | --- |
| the file is absent | empty list, no report, no warning, no write (FR-001) |
| the file holds no recognisable task | empty list, no report (Edge Cases) |
| a task line whose text is empty once markup is removed | no entry; reported by `task_ref` |
| two tasks carrying one `local_id` | both refused and named; every other task still mirrors (FR-018) |
| CRLF line endings | preserved exactly; mirrored content identical to the LF file's (FR-014, VI) |

**Recognised on a task line**: the checkbox (`- [ ]` / `- [x]`), the task reference (`T014`), the
parallel marker (`[P]`), the story tag (`[US1]`), the text, the paths it names, and a trailing
`(depends on T012, T013)`. Continuation lines beneath a task belong to that task.

**Attribution** resolves in this order and stops at the first hit: the task's own `[US<N>]` tag; the
`## Phase …: User Story <N>` heading enclosing it; otherwise unattributed.

---

## §3 Assembly

- An attributed task whose ordinal names a story the specification does contain is nested under that
  story.
- An **unattributed** task is not in the document. It is reported once by `task_ref` with the reason,
  and nothing is created for it at any tier (FR-028).
- A **dangling** task — attributed to an ordinal the specification does not contain — is not in the
  document. It is reported once by `task_ref` and its tag, and every other task still mirrors
  (FR-004).
- A story that carries no task is mirrored exactly as it is today; no placeholder sub-task is
  invented (FR-010).
- When no `task` role is declared, no story carries a `tasks` key at all.

---

## §4 Planning

1. A task with no bound marker plans a **POST** to `…/issue`, carrying `local_id`,
   `parent_local_id`, `role:"task"`, and `fields.parent.key = "<resolved at apply time>"`.
2. A task with a bound marker whose content changed plans a **PUT** carrying only the fields that
   differ (FR-019).
3. A task with a bound marker whose content is unchanged plans nothing (FR-015).
4. A sub-task is never planned under anything but a mirrored user story — never under the
   specification-level issue (FR-007).
5. A task attributed to a story whose issue does not exist yet **and is not being created this run**
   (withheld by drift or by the privacy guard) plans nothing and is reported; it reconciles on the
   next run once the story exists.

**Summary and description.** The summary is the task's own text with the marker and file-only markup
removed. When it exceeds what the sink accepts, it is shortened **deterministically** — the same text
always yielding the same summary — and the untruncated text appears in the description (FR-008). The
description carries the task's identifier, phase, attribution, parallel-safety, files, dependencies
and continuation lines, and nothing about the story or the specification (FR-009).

---

## §5 Applying

Order within one run: **epic → stories → tasks**. Each task's parent key is resolved from the
`local_id → key` map built as the story writes complete, or from the story's already-recorded key when
it was recognised rather than created.

- Every task body passes `privacy_guard_scan` in the same pre-write sweep as every other payload,
  before the first write of the run (FR-025).
- A created sub-task's key is stamped and recorded into `tasks.md` **immediately**, never batched
  (FR-013).
- `--dry-run` computes this identically and writes nothing — no Jira call and no marker line
  (FR-024).

---

## §6 Completion

Planned only for a task whose `done` is true.

1. If the recognised sub-task's `status_category` is already `done`: no read, no transition (FR-031).
2. Otherwise read the issue's available transitions and select those whose destination the project
   classifies as done.
   - **exactly one** → transition to it.
   - **none** → no transition; one named warning identifying the issue; every other task still
     reconciles (FR-030).
   - **two or more** → no transition; one report naming the issue and the candidates. The bridge
     invents no preference (Edge Cases).
3. A transition the workflow gates behind a required field value is **withheld and named**: recorded
   defaults are a creation-time mechanism and are never sent on a transition body (FR-041).
4. A task reverting from checked to unchecked does not move its sub-task backwards; the divergence is
   reported by key and the backward move happens only under the operator's existing backward-pull
   authorisation (FR-032).
5. A sub-task a person completed while its task is unchecked is the same divergence, reported the
   same way, and is never overwritten.
6. Completion is never read back: a sub-task completed in Jira never checks a task off in `tasks.md`
   (FR-033).

A task that is checked before its sub-task has ever been created is created and then transitioned in
the same run (Edge Cases).

---

## §7 Mandatory fields on the sub-task type

**Recording.** The type carrying the `task` role joins feature 011's question scope whenever the role
is declared, on the same closed-question terms. No `task` role means no question about any sub-task
type (FR-035). No new configuration key, no second surface (FR-034).

**Confirming.** Pending sub-task creations fold into the one consolidated confirmation per run
alongside the other tiers. A run that creates sub-tasks never asks twice (FR-040).

**Withholding.** When a required field on the sub-task type is satisfied by nothing — no recorded
default, no answer this run, or a shape no recorded value can express:

| Must happen | Must not happen |
| --- | --- |
| the specification and story tiers mirror exactly as they would with no `task` role declared | the specification is refused |
| zero sub-task writes | a partial sub-task tier |
| each field named once by its Jira label with its remedy line | a field named by an internal identifier |
| the summary states the tier as withheld, distinctly from a tier with nothing to mirror (FR-037) | the run reading as a complete mirror |
| no durable identifier recorded for a withheld task (FR-038) | a fourth marker state |
| the next run, once the default is recorded, creates exactly the withheld sub-tasks (FR-039) | a cleanup step, a flag, or a repair command |

Inside a lifecycle hook this is one warning and the host command still succeeds (FR-026).

---

## §8 What is never done

Deleting or cancelling an orphaned sub-task; re-parenting one whose task moved; creating any issue to
host unattributed tasks; a fourth tier; issue links from `depends_on`; adopting a hand-made sub-task;
writing completion back into `tasks.md`; and any status name in either port, in any spelling or
language.
