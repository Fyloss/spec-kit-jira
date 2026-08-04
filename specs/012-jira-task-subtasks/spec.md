# Feature Specification: Every Task Lands as a Sub-Task Under Its Own Story

**Feature Branch**: `feat/handle-tasks`

**Created**: 2026-08-02

**Status**: Draft

**Input**: User description: "après avoir généré le fichier tasks.md via Spec Kit, créé ses sub
tasks dans chaque stories dans Jira automatiquement en attribuant les bonnes sub tasks au bonnes
User Stories et en ajoutant de leur description correspondante."

## Context

The bridge mirrors two tiers today: one specification-level issue per `spec.md`, and one story-level
issue per user story inside it. The third tier — the task list — is declared but inert.

Feature 010 shipped the `task` role: a team can already write `hierarchy.task: Sous-tâche` in its
committed configuration, the role is validated against the project's reported sub-task types,
refused when it names a type that is not a sub-task type, and persisted with provenance. What it
does *not* do is create anything. Feature 010 said so out loud and left a status line that says it
too — `task is recorded as "<NAME>" but is not mirrored yet — this release creates no sub-tasks` —
precisely so that no team would commit the key, see no error, and conclude sub-tasks existed.

Feature 010's Phase 8 (T066–T071) is the work this specification covers, and its deferral note
states the size accurately: nothing parses `tasks.md` in either port today, the neutral interchange
document is shaped `{epic, stories[]}`, and durable identifiers, recognition and drift all enumerate
exactly two tiers. Three tiers is not two tiers plus a loop.

Feature 011 shipped since this specification was first drafted, and it changes one of its premises.
A project whose written issue types require custom fields the bridge cannot invent is no longer
refused outright: the configuration ceremony asks for a default per field per issue type, records it
in the committable team config under `field_defaults`, and a single consolidated confirmation before
the first write of a run lets the developer keep those values or supply others for that run. That
mechanism is scoped, deliberately, to the two types the bridge writes today — feature 011's FR-025
names the specification and story roles and no others — and it reports a default recorded for any
other type as *recorded, not yet consumed*, the same holding pattern feature 010 left the `task`
role in.

This feature is what ends both holding patterns. The moment sub-tasks are created, the sub-task type
becomes a type the bridge writes, and it must join the defaults mechanism on the same terms rather
than gaining one of its own — otherwise the exact defect feature 011 closed reopens one tier lower,
and the two status lines that say the tier is inert become false.

The request adds one thing feature 010 did not state: the sub-task must carry **its corresponding
description**, not only a title. A task line in `tasks.md` is dense — it names the story it serves,
the phase it belongs to, whether it is parallel-safe, the files it touches, and the tasks it depends
on. A sub-task whose summary is the line and whose description is empty throws all of that away, and
the reader has to open the repository to recover it. That is the failure this feature avoids.

It adds a second thing feature 010 did not state: a task the implement command has checked off must
read as done in Jira, in the story's own view of its sub-tasks. A mirror whose sub-tasks never
advance understates the work permanently, and a team would end up maintaining status by hand — which
is the labour this bridge exists to remove. The target status is resolved from the classification the
project itself reports, never from a status name the bridge expects to find (Constitution VII).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A team that works in sub-tasks sees its task list in Jira (Priority: P1)

A developer runs `/speckit-tasks`, the task list is generated, and the mirror fires on the
`after_tasks` event as it already does. Every task recorded against a user story appears in Jira as a
sub-task of that story's issue, titled with the task's own text and described with the task's own
content — its identifier, its phase, the files it names, what it depends on, and whether it is
parallel-safe. Nobody opens the repository to find out what a sub-task means.

**Why this priority**: This is the request, and it is the whole of the value. Without it the `task`
role remains a key that validates and does nothing.

**Independent Test**: Declare a `task` role against a fixture project that reports a sub-task type,
reconcile a specification whose task list attributes tasks to three different stories, and observe
one sub-task per task under the correct story, each carrying a non-empty description derived from
its task.

**Acceptance Scenarios**:

1. **Given** a declared `task` role and a task list whose tasks name the stories they serve, **When**
   the specification is reconciled, **Then** each such task is created as a sub-task of that story's
   issue and of no other issue.
2. **Given** a task whose text exceeds what a Jira summary accepts, **When** it is mirrored, **Then**
   the summary is shortened deterministically and the full text is present in the description, so no
   content is lost.
3. **Given** a task that names files and dependencies, **When** it is mirrored, **Then** those appear
   in the sub-task's description without the reader consulting the repository.
4. **Given** a story that carries no task at all, **When** it is reconciled, **Then** the story is
   created or updated exactly as it is today and no empty or placeholder sub-task is invented.
5. **Given** no `task` role is declared, **When** any specification is reconciled, **Then** no
   sub-task is created and the run's output is byte-for-byte what the previous release produced.
6. **Given** the feature directory holds no `tasks.md`, **When** the specification is reconciled,
   **Then** the run succeeds unchanged — no refusal, no warning, no write.

---

### User Story 2 - Regenerating the task list does not duplicate anything (Priority: P1)

`/speckit-tasks` rewrites `tasks.md` wholesale, and it renumbers tasks when the list changes. A
developer regenerates the list, adds two tasks, reconciles, and gets two new sub-tasks — not a second
copy of the twenty that already existed.

**Why this priority**: A mirror that duplicates on regeneration is worse than no mirror, because the
damage accumulates in a system the team cannot easily clean. Zero-churn idempotency is
constitutional, and the task tier is the tier most exposed to it: unlike `spec.md`, `tasks.md` is
regenerated by a command rather than edited by hand.

**Independent Test**: Reconcile a task list, regenerate it with the task identifiers renumbered and
the task content unchanged, reconcile again, and observe zero writes of every kind and no new issue.

**Acceptance Scenarios**:

1. **Given** a task list already mirrored, **When** it is reconciled again unchanged, **Then** zero
   writes of every kind are issued, sub-tasks included.
2. **Given** a task list whose task identifiers were renumbered by regeneration while the durable
   identifiers were preserved, **When** it is reconciled, **Then** every task is recognised as the
   one it already is and no issue is created.
3. **Given** a task that has never been mirrored, **When** it is reconciled, **Then** it receives a
   durable identifier recorded in `tasks.md`, and the record is a byte-preserving edit of that file —
   nothing else in it changes.
4. **Given** a task whose durable identifier was lost because the file was regenerated over it,
   **When** it is reconciled, **Then** it is treated as a new task and the resulting duplication is
   reported in the run summary rather than left silent.

---

### User Story 3 - An edited task reaches Jira, and a Jira-side edit is reported first (Priority: P2)

A developer rewords a task, or moves it to a different phase, and the change reaches its sub-task on
the next reconcile. When someone edited that sub-task in Jira instead, the run says so — naming the
issue and the field — before anything is overwritten.

**Why this priority**: It is what makes the mirror trustworthy rather than a one-shot import, and it
is the constitutional drift rule applied to a new tier. It is separable from User Story 1: an import
that never updates is already useful for a release.

**Independent Test**: Mirror a task list, change one task's text in the repository and a different
sub-task's summary in Jira, reconcile, and observe one content update on the first and one named
drift warning on the second.

**Acceptance Scenarios**:

1. **Given** a mirrored task whose text changed in the repository, **When** it is reconciled, **Then**
   its sub-task is updated, and only the fields that changed are written.
2. **Given** a mirrored sub-task whose content was changed in Jira, **When** it is reconciled,
   **Then** a named warning identifies the issue and the divergent field before any overwrite
   decision, exactly as it does for a story today.
3. **Given** a task removed from `tasks.md`, **When** the specification is reconciled, **Then**
   nothing is deleted in Jira, and the now-orphaned sub-task is reported once by key.
4. **Given** a task whose story attribution changed, **When** it is reconciled, **Then** its sub-task
   is not silently re-parented; the divergence is reported by key, naming both stories.

---

### User Story 4 - Tasks that belong to no user story are reported, not invented into Jira (Priority: P2)

A generated task list opens with setup and foundational phases and closes with a polish phase. Those
tasks carry no story attribution, and a Jira sub-task cannot hang from the specification-level issue.
None of them is mirrored, and no issue is invented to host them — but the developer reads every one
of them by name in the run summary and is never left guessing why a third of the list is absent from
Jira.

**Why this priority**: It is a scope boundary, not an enhancement — a generated list routinely leaves
a third of its tasks unattributed, and silence about them would be read as a defect. It ships after
User Story 1 because the reporting is only meaningful once the attributed tasks land.

**Independent Test**: Reconcile a task list containing setup, foundational and polish tasks alongside
story-attributed ones, and observe the attributed tasks mirrored and every unattributed task
accounted for by identifier in the run summary.

**Acceptance Scenarios**:

1. **Given** tasks carrying no story attribution, **When** the specification is reconciled, **Then**
   none of them is mirrored at any tier, no issue is created to host them, and each is accounted for
   individually in the run summary, by task identifier and with the reason.
2. **Given** a task carrying no attribution tag but sitting inside a phase whose heading names a user
   story, **When** it is reconciled, **Then** it is attributed to that story — the heading is a
   statement of attribution as much as the tag is.
3. **Given** a task attributed to a story the specification does not contain, **When** it is
   reconciled, **Then** nothing is created for it, it is reported by identifier and tag, and every
   other task in the list is still mirrored.
4. **Given** any of these situations occurring inside a lifecycle hook, **When** the run finishes,
   **Then** it is reported as one warning and the host command still succeeds.

---

### User Story 5 - A completed task reads as completed in Jira (Priority: P2)

A developer finishes a piece of work, `/speckit-implement` checks the task off in `tasks.md`, the
mirror fires on the `after_implement` event it already fires on, and the sub-task shows as done in
the story's own sub-task list. Progress is readable from Jira alone; nobody keeps two sources of
truth aligned by hand.

**Why this priority**: It is the second half of the request, and a mirror whose sub-tasks never
advance is a mirror a team stops trusting. It is P2 rather than P1 only because it presupposes the
sub-tasks of User Story 1 exist — it cannot ship first, but it should ship.

**Independent Test**: Mirror a task list, mark two tasks complete in the file, reconcile, and observe
exactly those two sub-tasks reaching a status the project classifies as done with no other write;
reconcile again and observe zero transitions.

**Acceptance Scenarios**:

1. **Given** a mirrored task newly marked complete, **When** it is reconciled, **Then** its sub-task
   reaches a status the project classifies as done, and the story's sub-task list shows it as
   completed without anyone opening the repository.
2. **Given** a task list whose completed tasks are already mirrored as completed, **When** it is
   reconciled again, **Then** zero transitions are issued.
3. **Given** a sub-task whose workflow offers no reachable status classified as done, **When** it is
   reconciled, **Then** no transition is issued, one named warning identifies the issue, and every
   other task in the list is still reconciled.
4. **Given** a task that reverts from complete to incomplete, **When** it is reconciled, **Then** its
   sub-task is not moved backwards; the divergence is reported by issue key and the backward move
   happens only under the operator's existing backward-pull authorisation.
5. **Given** a sub-task a person moved to a completed status in Jira while its task is unchecked,
   **When** it is reconciled, **Then** the divergence is reported as named drift and is not silently
   overwritten.

---

### User Story 6 - A mandatory field on the sub-task type never blocks anything (Priority: P1)

A team's project demands a custom field on every sub-task — a team picker, a program increment, a
mandatory single-select. The operator runs the configuration ceremony, is asked for that field's
default by the label Jira shows, and answers once; from then on every mirrored sub-task lands filled
in. Nobody is ever told that the mirror cannot run because of a field.

And when nobody has recorded anything yet, the mirror still runs: the specification and its stories
land exactly as they always did, the sub-tasks are the only thing held back, and the run names the
field and prints the one command that unblocks it. The team is never worse off for having declared a
`task` role than for not having declared one.

**Why this priority**: this is the difference between the feature working on a real project and
working only on a permissive one. Feature 011 exists because a mandatory field turned a whole mirror
into a refusal; reproducing that defect one tier lower would undo it. It ships with User Story 1
rather than before it, because there is nothing to withhold until sub-tasks exist.

**Independent Test**: point the bridge at a project whose sub-task type requires a custom field, run
with nothing recorded and observe the two upper tiers mirrored, the task tier withheld, and every
unsatisfiable field named with its remedy; record the default through the ceremony, run again, and
observe exactly the withheld sub-tasks created with no other action.

**Acceptance Scenarios**:

1. **Given** a declared `task` role whose type requires a custom field, **When** the configuration
   ceremony runs, **Then** it asks for that field's default by its Jira label exactly as it does for
   the two types it already asks about, and records the answer under that type; **And** when no
   `task` role is declared it asks nothing about any sub-task type.
2. **Given** a recorded default for the sub-task type, **When** a specification is reconciled,
   **Then** every sub-task is created carrying that value, and the run reports the field and where
   the value came from.
3. **Given** a run that will create all three tiers, each of whose types carries a field with a
   recorded default, **When** it reaches the point of writing, **Then** the developer is asked one
   consolidated question covering all three, never one question per tier.
4. **Given** a required field on the sub-task type that nothing satisfies — no recorded default, no
   answer for this run — **When** the specification is reconciled, **Then** the specification and
   story tiers are mirrored exactly as they would be with no `task` role declared, no sub-task is
   written, and each unsatisfiable field is named once by its Jira label with the command that
   records a default for it.
5. **Given** that same run, **When** its summary is read, **Then** the withheld tier is stated as
   such and cannot be mistaken for a complete mirror; **And** when the run was fired by a lifecycle
   hook, the host command still succeeds and the developer sees one warning line.
6. **Given** a withheld task tier, **When** the operator records the missing default and reconciles
   again, **Then** exactly the withheld sub-tasks are created, with no manual step, no cleanup and
   no flag, and nothing else in the mirror changes.
7. **Given** a required field whose shape cannot be expressed as a recorded default at all, **When**
   the specification is reconciled, **Then** the task tier is withheld on the same terms and the
   two upper tiers keep mirroring on every subsequent run — a field nobody can answer never
   degrades into a permanently broken mirror.

---

### Edge Cases

- **`tasks.md` exists but holds no recognisable task.** Treated as an empty list: no write, no
  refusal, no warning. A template that was never filled in is not an error.
- **A task's text is empty once its identifier and markup are removed.** No issue is created from it;
  it is reported by identifier, because an untitled sub-task is unusable in Jira's own UI.
- **Two tasks carry the same durable identifier** — a copy-paste of a marked line. Refused for those
  two tasks with both identifiers named, rather than picking one; the remaining tasks still mirror.
- **The task list attributes tasks to a story that exists in `spec.md` but has no mirrored issue yet**
  — for instance a story whose creation was withheld by the privacy guard or by drift. No sub-task is
  created under a parent that does not exist; the tasks are reported and reconcile on the next run
  once the story exists.
- **A story's issue is recorded but has since been deleted in Jira.** Existing behaviour for a
  missing recorded ticket governs the story; no sub-task is created against a parent that cannot be
  read (Constitution III).
- **The project reports no sub-task type but a `task` role is declared.** Unchanged from feature 010:
  refused as an unknown type for that role, with the candidate list stated as empty.
- **A task's description content trips the privacy guard** — a task line naming a real Jira
  coordinate or a token-shaped string. The guard's existing tiers apply unchanged: BLOCK stops the
  write for that payload, WARN surfaces and proceeds, an allowlisted match does neither.
- **The task list is mirrored while the specification-level and story-level issues are being created
  in the same run.** Sub-tasks are planned against the stories created in that same run, not deferred
  to a second run.
- **A task belongs to a story that itself is not mirrored because the specification declares no
  stories at all.** No sub-task tier exists to attach to; the run behaves exactly as it does today.
- **`tasks.md` uses CRLF line endings.** The durable-identifier edit preserves them, and the mirrored
  content is identical to what the same file with LF endings produces (Constitution VI).
- **A task is checked and reworded in the same run.** One content update and one transition, each
  counted on its own line of the summary; neither suppresses the other.
- **The sub-task type requires a custom field for which nobody recorded a default.** The task tier
  alone is withheld — zero sub-task writes — while the specification and story tiers mirror exactly
  as they do without a `task` role. The field is named by its Jira label with feature 011's
  copy-pasteable remedy, and recording it is the only thing needed to complete the mirror.
- **The required field's shape cannot be expressed as a recorded default at all** (feature 011,
  FR-010 — a field the bridge cannot state a value for). The same withholding applies, and it
  persists across runs without ever degrading the two tiers that do work. Making the field optional
  in the project's field configuration remains the administrator's remedy, but nothing is broken
  while they get to it.
- **A default was already recorded for the sub-task type before this feature shipped**, through
  feature 011's explicit opt-in for a type the bridge did not write yet. It is consumed as it
  stands — nothing is re-recorded, no question is re-asked — and the ceremony stops describing it as
  recorded but not yet consumed.
- **The sub-task's workflow demands a field value on the transition itself** — a resolution, a
  reason. Recorded defaults are a creation-time mechanism only (feature 011, FR-017), so none is
  sent here: the completion transition is withheld for that issue, it is named, and the rest of the
  list still reconciles.
- **A task is checked before its sub-task has ever been created.** The sub-task is created and then
  reaches the completed status in the same run; a task that was done before the mirror existed does
  not arrive in Jira as outstanding work.
- **The project classifies more than one reachable status as done.** The bridge does not invent a
  preference between them; the ambiguity is reported by issue key with the candidates named, exactly
  as an ambiguous issue type is today, and no transition is issued.

## Requirements *(mandatory)*

### Functional Requirements

**Reading the task list**

- **FR-001**: The bridge MUST read the feature's `tasks.md` when it is present beside the
  specification it is mirroring, and MUST treat its absence as a silent no-op — no refusal, no
  warning, no write.
- **FR-002**: The bridge MUST recognise each task entry in the task list and MUST extract, for each:
  its task identifier, its text, its story attribution, its phase, whether it is marked
  parallel-safe, the file paths it names, and the tasks it declares a dependency on.
- **FR-003**: The bridge MUST attribute a task to the user story named by its own attribution tag;
  when no tag is present, it MUST attribute the task to the user story named by the heading of the
  phase that encloses it; when neither names a story, the task is unattributed.
- **FR-004**: Attribution MUST resolve against the user stories of the specification being
  reconciled. A task attributed to a story that specification does not contain MUST produce no write,
  MUST be reported by task identifier and attribution, and MUST NOT prevent any other task from being
  mirrored.
- **FR-005**: No Jira identifier, issue type, or project key may cross into the layer that reads the
  task list; it emits neutral task content only (Constitution VIII).

**Creating sub-tasks**

- **FR-006**: For each attributed task, the bridge MUST create exactly one issue of the configured
  `task` role's type, as a child of the issue mirroring the story that task is attributed to.
- **FR-007**: A sub-task MUST NEVER be created under an issue that is not a mirrored user story, and
  in particular never under the specification-level issue.
- **FR-008**: The sub-task's summary MUST be the task's own text with the durable identifier and the
  markup that serves only the task file removed. When that text exceeds what the sink accepts as a
  summary, it MUST be shortened deterministically — the same text always yielding the same summary —
  and the untruncated text MUST appear in the description.
- **FR-009**: The sub-task's description MUST carry the task's corresponding content: its task
  identifier, its phase, its story attribution, its parallel-safety marker, the file paths it names,
  the dependencies it declares, and any continuation lines beneath it. The description MUST be
  derived from the task alone — it MUST NOT restate the story or the specification.
- **FR-010**: A user story that carries no task MUST be mirrored exactly as it is today, and no empty
  or placeholder sub-task may be invented for it.
- **FR-011**: When no `task` role is declared, the bridge MUST create no sub-task, MUST read no task
  list for that purpose, and MUST produce output byte-for-byte identical to the two-tier mirror of
  the previous release — on every surface, the configuration ceremony's question set included.
- **FR-012**: Every status line announcing that this tier is inert MUST be replaced by one that
  describes what this release actually does — both the line feature 010 emits when a `task` role
  resolves (the role is recorded but not mirrored, the release creates no sub-tasks) and the line
  feature 011 emits for a field default recorded against the sub-task type (recorded, not yet
  consumed). A release that mirrors sub-tasks while still announcing that it does not is a defect.

**Identity and zero churn**

- **FR-013**: Every mirrored task MUST carry a durable identifier, assigned by the bridge and
  recorded in `tasks.md`, and that identifier MUST be the only key used to recognise the task's
  issue. Recognition MUST NOT be keyed on the task identifier (`T012`), the task's text, its
  position in the file, or any other operator-editable or regenerated value (Constitution II).
- **FR-014**: Recording a durable identifier in `tasks.md` MUST be a byte-preserving edit: line
  endings, surrounding whitespace and every unrelated byte of the file are unchanged.
- **FR-015**: Re-running the mirror against an unchanged repository state MUST issue zero writes of
  every kind the sink can perform, sub-tasks included.
- **FR-016**: A task list regenerated with its task identifiers renumbered, its durable identifiers
  preserved and its content unchanged MUST produce zero writes and create no issue.
- **FR-017**: A task whose durable identifier is absent MUST be treated as new. When this produces an
  issue that duplicates one already mirrored, the run summary MUST report it rather than leave it
  silent.
- **FR-018**: Two tasks sharing one durable identifier MUST be refused for those two tasks, naming
  both, without preventing the remaining tasks from being mirrored.

**Change, drift and removal**

- **FR-019**: A task whose content changed MUST update its sub-task, writing only the fields that
  differ.
- **FR-020**: A sub-task whose content diverges on the Jira side MUST produce a named warning
  identifying the issue and the divergent field before any overwrite decision, on the same terms as
  a story today (Constitution I).
- **FR-021**: A task removed from `tasks.md` MUST NOT cause any deletion or any status change in
  Jira. The orphaned sub-task MUST be reported once, by issue key.
- **FR-022**: A task whose story attribution changed MUST NOT be re-parented. The divergence MUST be
  reported by issue key, naming the story it is under and the story it is now attributed to.

**Reporting, dry-run and safety**

- **FR-023**: The run summary MUST report sub-task outcomes — created, updated, transitioned,
  unchanged, skipped — as their own counts, distinct from the specification and story tiers, and MUST
  name every skipped task with its reason.
- **FR-024**: Dry-run MUST show every sub-task it would create or update, its parent story, its
  summary, its description and every transition it would perform, and MUST write nothing
  (Constitution XI).
- **FR-025**: Every sub-task write MUST pass the privacy guard before it is issued, on the same terms
  and with the same two tiers and allowlist as every other write (Constitution IX).
- **FR-026**: Any refusal or warning this feature produces, when it occurs inside a lifecycle hook,
  MUST be reported as one warning while the host command still succeeds (Constitution III).
- **FR-027**: Both ports MUST produce byte-identical output for the same task list, and the
  conformance corpus MUST cover the task tier (Constitution VI).

**Unattributed tasks**

- **FR-028**: A task carrying no story attribution MUST NOT be mirrored. No issue is created for it
  at any tier, and no issue may be invented to host it — the bridge never creates a Jira artifact
  that no repository artifact corresponds to (Constitution I). Each unattributed task MUST be named
  individually in the run summary, by task identifier, with the reason.

**Completion state**

- **FR-029**: A task marked complete in `tasks.md` MUST cause its sub-task to reach a status the
  project classifies as done, so that the parent story's own view of its sub-tasks reads the task as
  completed without anyone opening the repository.
- **FR-030**: The target status MUST be resolved from the classification the project reports for the
  statuses reachable in the sub-task type's own workflow. No status name may be hard-coded, assumed,
  or required to exist under any particular spelling or language (Constitution VII). When that
  workflow offers no reachable status classified as done, the run MUST issue no transition for that
  issue, MUST report one named warning identifying it, and MUST continue reconciling every other
  task.
- **FR-031**: A sub-task already in a status the project classifies as done MUST NOT be transitioned
  again: a completed task reconciled a second time issues zero transitions (Constitution II).
- **FR-032**: A task reverting from complete to incomplete MUST NOT move its sub-task backwards by
  default. The backward transition is withheld and reported by issue key, and is performed only when
  the operator authorises a backward pull through the drift option that already exists for the story
  tier. A sub-task a person moved to a completed status while its task is unchecked is the same
  divergence and is reported the same way (Constitution I).
- **FR-033**: Completion MUST be mirrored in one direction only. A sub-task completed in Jira MUST
  NOT check the task off in `tasks.md`; the filesystem remains the source of truth and the
  divergence is reported.

**Mandatory fields on the sub-task type**

- **FR-034**: The type carrying the `task` role MUST participate in the recorded field-defaults
  mechanism on exactly the same terms as the specification and story types: recorded per project and
  per issue type in the committable team config, keyed by the field's human label, applied on
  creation and never retro-filled onto an existing sub-task. This feature MUST NOT introduce a second
  defaults surface, a sub-task-specific configuration key, or a separate question.
- **FR-035**: The configuration ceremony MUST ask its field-default questions about the sub-task type
  whenever a `task` role is declared, on the same closed-question terms it already uses for the other
  two types. When no `task` role is declared, the ceremony MUST ask nothing about any sub-task type:
  the question set follows what the bridge writes, never what the project offers.
- **FR-036**: A required field on the sub-task type that nothing satisfies — no recorded default, no
  answer for this run, or a shape no recorded value can express — MUST NOT refuse the specification.
  The specification and story tiers MUST be mirrored exactly as they would be with no `task` role
  declared; the task tier alone MUST be withheld, with zero sub-task writes; and every unsatisfiable
  field MUST be named once by its Jira label with the copy-pasteable command that records a default
  for it. Withholding the writes that cannot be formed correctly is the fail-closed outcome for
  those writes; taking a working two-tier mirror down with them is not (Constitution III).
- **FR-037**: A withheld task tier MUST be reported as withheld in the run summary, distinctly from a
  tier that simply had nothing to mirror, so a partial mirror can never be read as a complete one.
- **FR-038**: A task whose sub-task was withheld MUST NOT receive a durable identifier in
  `tasks.md`. The task list records only what reached Jira, so the withheld tasks remain new.
- **FR-039**: Recording the missing default MUST be the only action needed to complete the mirror:
  the next reconcile creates exactly the sub-tasks that were withheld, with no manual step, no
  cleanup and no flag, and changes nothing else (Constitution X).
- **FR-040**: The consolidated creation-time confirmation MUST remain exactly one question per run.
  Pending sub-task creations MUST fold into that single question alongside the other tiers; a run
  that creates sub-tasks MUST NOT ask a second time.
- **FR-041**: No recorded default may be sent on a transition. A transition is not a creation, so a
  sub-task workflow whose transition screen demands a field value MUST have its completion transition
  withheld and named, without blocking the rest of the run (FR-030).
- **FR-042**: The run summary and the dry-run preview MUST attribute the field values a sub-task
  creation carries to their source — recorded team default, operator answer for this run, or
  bridge-supplied — through the reporting surface that already does this for the other two tiers,
  adding no sub-task-specific one.

### Key Entities

- **Task**: One entry in a feature's task list. Carries a task identifier, text, a phase, an optional
  story attribution, a parallel-safety marker, file paths, declared dependencies, and a completion
  checkbox. Regenerated wholesale by the task-generation command, which is what makes its identity
  problem different from a story's.
- **Task attribution**: The relation binding a task to exactly one user story of one specification,
  stated by the task's own tag or by its enclosing phase heading. It is the relation the request calls
  "les bonnes sub tasks aux bonnes User Stories".
- **Durable task identifier**: The bridge-assigned, opaque, stable key recorded in the task list and
  paired with the mirrored issue. The third tier of an identifier scheme that carries two today.
- **Sub-task issue**: The mirrored artifact — an issue of the configured `task` role's type, child of
  a story's issue, whose summary and description derive from one task and nothing else.
- **Task role**: The already-shipped configuration entry naming which of the project's sub-task types
  carries this tier. Absent by default; never derived; its absence is this feature's off switch.
- **Completion state**: Whether a task is checked in the task list. One bit, owned by the repository,
  read forward into the sub-task's status and never read back (FR-033).

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | `tasks.md` is the reference and the sub-task tier is derived from it. FR-021 forbids deletion when a task disappears; FR-020 requires a named drift warning identifying issue and field before any overwrite; FR-022 refuses silent re-parenting; FR-032 withholds and reports a backward transition rather than pulling a ticket back silently; FR-033 keeps completion one-way, so Jira never writes into the repository. FR-028 refuses to create any issue no repository artifact corresponds to. No new exception to the two controlled ones is introduced. |
| II | Zero-Churn Idempotency | FR-015 states zero writes of every kind on an unchanged re-run, sub-tasks included, and FR-016 extends that guarantee across regeneration with renumbered task identifiers — the specific churn risk this tier introduces. FR-031 covers the write kind this feature adds: a completed task reconciled twice issues zero transitions. FR-013 keys recognition on a durable identifier and explicitly forbids keying on task text, task number or position. The live idempotency assertion list gains the sub-task create, update and transition kinds in the same change (Constitution II enforcement test). |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | An unreadable parent story yields no sub-task write (Edge Cases); a task attributed to a non-existent story writes nothing (FR-004). FR-036 applies the principle at the level it is written for — the write — when a mandatory field on the sub-task type cannot be satisfied: the sub-task writes that cannot be formed correctly are not issued, while the specification and story writes, which are correct and independently satisfiable, still happen. The task tier is a leaf, so withholding it leaves precisely the coherent two-tier mirror of the previous release; refusing the whole specification instead would let one field on an opt-in tier take down a mirror that works, which fail-closed does not ask for. FR-026 keeps every refusal and warning to one warning with host success when the run is a lifecycle hook — which is the normal case here, since `after_tasks` is what fires it. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. This feature adds no credential surface: it reads one more repository file and writes one more issue type through the existing authenticated client. |
| V | Separation of Team Config / Local Binding / Secrets | This feature adds no configuration key. The two it touches already exist and are already committable team decisions: the `task` role (feature 010, with its provenance) and `field_defaults` (feature 011). FR-034 and FR-035 widen the ceremony's question scope to a third issue type under the existing key rather than opening a surface of their own, and feature 011's rule that a hook never edits the team config (its FR-021) is unchanged — the sub-task tier reads defaults, it never records them. |
| VI | macOS / Linux / Windows Portability | FR-027 requires byte-identical output from both ports with conformance coverage of the task tier. FR-014's byte-preserving edit must hold for CRLF task lists (Edge Cases), which is the portability hazard this feature actually carries — a third file the bridge splices into. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | The sub-task type is whatever the team declared as the `task` role — never a hard-coded name, never a hard-coded hierarchy level. The completion target of FR-029 is resolved by FR-030 from the classification the project itself reports for the statuses reachable in that type's own workflow: no status name is hard-coded, assumed, or required to exist in any spelling or language — which matters directly for the consumer instance whose types are named in French. A workflow with no reachable completed status, or with several, is reported rather than forced. A mandatory custom field on the sub-task type is likewise never invented: FR-034 satisfies it only from a value the team recorded against that type by the field's own Jira label, and FR-036 withholds the tier cleanly, naming the field, when nobody recorded one — no value is ever guessed to keep a write alive. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | FR-005 forbids any Jira identifier from crossing into task parsing; the reader emits neutral task content and the sink alone knows what a sub-task is. The neutral interchange document gains tasks under their story, keeping the same one-way flow the two existing tiers use. |
| IX | Two-Tier Privacy Guard, With an Allowlist | FR-025 puts every sub-task write behind the existing guard with its existing tiers and allowlist. Task text is the content most likely to name real paths, so the guard runs on the description as it does on any other payload — no new exemption, no new tier. |
| X | Self-Healing Automatic Mirror | Unaffected. The trigger is the already-registered `after_tasks` hook; no hook is added, removed or re-registered, so the manifest's seven events stay the complete set. |
| XI | Universal Dry-Run and Auditability | FR-024 requires dry-run to show every sub-task it would create or update with its parent, summary and description, writing nothing. FR-023 makes the summary account for every task, including the ones deliberately skipped. |
| XII | Quality and Catalog Publication | Both ports ship together with `shellcheck`, `PSScriptAnalyzer` and `actionlint` clean, the conformance corpus extended to the task tier (FR-027), and the extension version raised in `extension.yml` as its single source of truth. |
| XIII | TDD With a Minimum 80% Coverage | Each acceptance scenario above becomes a failing test before its implementation, in both ports. The two-way proof of FR-011 — no `task` role means byte-identical output — is a test written before the tier exists, as feature 010's T071 already specified. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | The third tier reuses rather than parallels: the durable-identifier mechanism generalises the story marker instead of duplicating it (feature 010, T068), attribution reuses the story identities the mirror already resolves, the completion transition reuses the lifecycle rules the story tier already applies — transition, withhold, halt — instead of introducing a second transition mechanism, and the trigger is an existing hook. Mandatory fields on the new type join feature 011's defaults mechanism as a third scope entry (FR-034) rather than gaining a mechanism of their own, and stay inside its one-question-per-run budget (FR-040). Withholding one tier (FR-036) reuses the tier-by-tier planning the mirror already performs rather than adding a recovery mode: the withheld state needs no marker, because FR-038 simply leaves those tasks unrecorded and the next run plans them again. No new command, no new configuration key, no new file. FR-028 is the simplest possible answer for unattributed tasks: report them, invent nothing. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | This is feature 010's Phase 8, deferred with a written trigger — a team declaring the `task` role and expecting sub-tasks — which the request now fires. Completion mirroring is included because the request asks for it in as many words, and no further. Feature 011 is consumed exactly as far as this tier requires — one more issue type inside its existing scope (FR-034/FR-035) — and not extended: no default on a transition (FR-041), no per-tier question, no new flag, no new way to record a value. The only behaviour this feature adds beyond it is the one the requester asked for: a leaf tier withheld instead of a specification refused (FR-036). Everything not asked for is refused into Out of Scope: no assignees, no estimates, no sprints, no fourth tier, no cross-project routing, no deletion of orphans, no reverse direction, no configurable status mapping, and no bridge-owned issue to host unattributed tasks. |
| XVI | Human Readable — Readable by a Human Above All | The feature exists to make a sub-task readable on its own: FR-009 puts the task's own context into the description rather than leaving a bare title, and FR-008 guarantees no text is lost to truncation. FR-023 makes the run summary answer "what happened to every task" without reading a log. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For a specification whose task list attributes N tasks across at least three user
  stories, one reconcile produces exactly N sub-tasks, each under the story its task names — 100%
  correct attribution, zero sub-tasks under any other parent.
- **SC-002**: A second reconcile of an unchanged repository issues zero writes of every kind,
  sub-tasks included.
- **SC-003**: Regenerating the task list with renumbered task identifiers and unchanged content, then
  reconciling, leaves the issue count unchanged — zero duplicates.
- **SC-004**: 100% of mirrored sub-tasks are understandable without opening the repository: every
  task whose text is shortened for the summary still exposes its full text, its files and its
  dependencies in the description.
- **SC-005**: A team that declares no `task` role sees output byte-for-byte identical to the previous
  release, proved by the conformance corpus rather than by inspection.
- **SC-006**: Every task in the list is accounted for in the run summary — created, updated,
  unchanged or skipped with a reason — so no task is silently dropped, measured as zero unaccounted
  task identifiers on a fixture containing attributed, unattributed and dangling tasks.
- **SC-007**: Both ports produce byte-identical output for the same fixture, verified by the
  cross-port conformance run.
- **SC-008**: A developer who has just run `/speckit-tasks` needs no additional command and no manual
  step to see the sub-tasks in Jira.
- **SC-009**: A task checked off in the task list reads as completed in its story's sub-task list in
  Jira after the reconcile that check already triggers — no additional command, no manual status
  change — and reconciling again issues zero transitions.
- **SC-010**: The completion behaviour holds on a project whose statuses are named in a language
  other than English, with no configuration naming a status, proving no status name is assumed.
- **SC-011**: A project whose sub-task type requires a custom field mirrors its task tier with no
  refusal and no extra command once a default is recorded for that type — the case that refused the
  whole mirror before feature 011, now closed one tier lower.
- **SC-012**: A run creating all three tiers asks the developer exactly one consolidated question
  about field values — never one per tier — measured on a fixture whose three types each require a
  field.
- **SC-013**: On a project whose sub-task type requires a field nobody has recorded, a reconcile
  still produces the same specification and story issues it produces with no `task` role declared —
  zero sub-tasks, zero lost tickets, and every unsatisfiable field named with the command that
  unblocks it. Declaring a `task` role never reduces what a team already gets.
- **SC-014**: Recording that default and reconciling again creates exactly the withheld sub-tasks
  and nothing else — no duplicate, no orphan, no manual cleanup — measured as an issue count that
  moves by precisely the number of tasks withheld.

## Assumptions

- The task list follows the shape of the Spec Kit task template: checkbox entries carrying a task
  identifier, an optional parallel marker, an optional story attribution tag, and phase headings that
  name the user story a phase serves. A file that departs from that shape yields fewer recognised
  tasks, never a corrupted mirror.
- Story attribution tags identify user stories by their ordinal within the specification, matching how
  the task-generation command writes them; the bridge resolves that ordinal against the stories it
  already mirrors rather than re-deriving story identity from the task list.
- "Description correspondante" means the task's own surrounding content — identifier, phase,
  attribution, parallel-safety, files, dependencies and continuation lines — not the story's
  description and not a copy of the specification.
- A Jira sub-task can only be a child of a standard-level issue. The story tier is therefore the only
  legal parent for this tier, which is what makes FR-028 a real question rather than a detail.
- Feature 010's `task` role, its validation, its persistence and its provenance are in place and are
  not re-specified here; this feature consumes them.
- Feature 011's recorded field defaults — the ceremony's closed questions, the `field_defaults`
  region of the team config, the consolidated creation-time confirmation, the flags that record and
  override a value, and the message that names a field and prints its remedy — are in place and are
  not re-specified here. This feature widens their issue-type scope by one, and reuses everything
  else as it stands; the one thing it does differently is what happens when a field cannot be
  satisfied for the task tier (FR-036), and that difference is confined to that tier.
- Declaring a `task` role can never make a team's mirror worse than not declaring one. This is the
  premise behind FR-036: feature 011 refuses a whole specification when a required field on the
  specification or story type cannot be satisfied, because those tiers are the mirror — without the
  specification issue there is nothing for a story to hang from. The task tier is a leaf, so the
  same refusal is not required to keep the result coherent, and applying it anyway would reproduce
  one tier lower the exact defect feature 011 was written to close.
- The `after_tasks` lifecycle hook is already registered and already fires a reconcile, so no new
  command and no manifest change is required for the trigger.
- Sub-task fields beyond summary, description and status — assignee, estimate, priority, sprint,
  labels beyond the bridge's own identity — are left unset, and the team is free to set them without
  the bridge overwriting them.
- "Checked and visible in Jira in the Story" is taken to mean Jira's own rendering of a completed
  sub-task in its parent story's sub-task panel — the native mechanism, which also advances the
  story's progress — rather than a checklist rendered inside the story's description. Duplicating the
  task list into the story's description would restate in prose what the sub-tasks already are, and
  would have to be kept churn-free against them.
- The team's sub-task workflow offers exactly one reachable status classified as done. Where it
  offers none, or several, the bridge reports and issues no transition rather than choosing
  (FR-030, Edge Cases) — this is a reporting path, not a refusal of the run.

## Out of Scope

- **Deleting or cancelling sub-tasks whose tasks were removed from the repository.** Unchanged from
  feature 010: orphans are reported, never deleted (FR-021).
- **Re-parenting a sub-task whose task moved to another story.** Reported, not performed (FR-022) —
  the same position feature 010 took on re-typing and re-parenting recorded tickets.
- **A destination in Jira for unattributed tasks.** Setup, foundational and polish tasks are reported
  and not mirrored (FR-028). A bridge-owned story created to host them would be a Jira artifact with
  no repository artifact behind it, needing its own identity, drift and zero-churn handling.
  *Written trigger for revisiting this: a team reports that its board understates its work because
  the setup and polish phases are absent — at which point a destination is added as an opt-in key,
  additively, with FR-028's behaviour remaining the default.*
- **A fourth tier below sub-tasks.** Jira offers none under a sub-task, and no artifact asks for one.
- **Mirroring `plan.md`, `research.md`, `data-model.md` or contract documents as issues.** Only the
  task list joins the mirror here.
- **Routing a story's tasks to a different Jira project than the story itself.** Cross-project routing
  remains what it is today.
- **A field-default surface of this feature's own.** Feature 011 shipped one; the sub-task type joins
  it as a third scope entry (FR-034/FR-035) and nothing about how a default is recorded, questioned,
  overridden or reported is redesigned here.
- **Sending a recorded default on a transition screen.** Defaults are creation-time only, so a
  transition demanding a field value is withheld and reported (FR-041). *Written trigger for
  revisiting this: a team reports a sub-task workflow whose completion transition requires a
  resolution, making the completion tier unusable for them — at which point transition-time values
  are specified additively, on feature 011's existing terms.*
- **Changing how feature 011 refuses for the specification and story types.** FR-036 governs the
  task tier only; the two tiers that carry the mirror keep refusing as they do today, because
  neither can be withheld without leaving the other incoherent.
- **Recording a field default from inside a reconcile run.** The withheld tier prints the command
  that records it; running it stays the operator's deliberate, reviewable act through the
  configuration ceremony, exactly as feature 011 (its FR-021) requires.
- **Adopting sub-tasks a human created by hand under a mirrored story.** Label-based adoption
  (Constitution I) covers specifications, and extending it to this tier is its own change.
- **Mirroring task ordering or dependency edges as Jira issue links.** Dependencies appear in the
  description as text (FR-009); creating link artifacts from them is not asked for.
- **Reading completion back from Jira into `tasks.md`.** One direction only (FR-033). A sub-task
  completed by a person is reported as divergence, never written into the repository.
- **A configurable status name for the completed target.** The target is resolved from the project's
  own classification (FR-030). *Written trigger for revisiting this: a team reports a workflow with
  several reachable completed statuses where the choice between them is meaningful to them — the
  ambiguity is reported today rather than configured away.*
- **Mirroring completion for the story or specification tiers from the task list.** Their lifecycle
  is governed by the existing lifecycle events and is unchanged here. *Written trigger: a team asks
  for a story to close when its last task is checked.*
- **Intermediate task states.** A task is checked or it is not; the task list records no "in
  progress", so the bridge invents none.
