# Feature Specification: A Story Carries Its Task List as a Checklist, Instead of a Sub-Task Each

**Feature Branch**: `feat/handle-checklist`

**Created**: 2026-08-09

**Status**: Draft

**Input**: User description: "add a setting to the extension's configuration so that, instead of creating sub-tasks, the
bridge writes one checklist per story; the checklist is kept up to date on reconcile exactly as
sub-tasks are when a task is completed; the setting stays editable afterwards in the extension's Jira
configuration file; and the configuration command offers the choice when it runs. The stated reason is
volume: a team should not end up with an enormous number of Jira tickets."

## Context

Feature 012 shipped the third tier. Every entry in `tasks.md` becomes a sub-task under the story it is
attributed to, carrying the task's own text as its summary and the task's content — identifier, phase,
attribution, parallel-safety, files, dependencies — as its description, and a task checked off in
`tasks.md` transitions its sub-task to a status the project classifies as done.

That is the right shape for a team whose sprint board, time tracking and estimation genuinely operate
at task granularity. It is the wrong shape for everyone else, and the cost is not subtle. A spec-kit
`tasks.md` routinely holds sixty to a hundred and fifty entries — feature 021's own task list holds
over a hundred. Mirrored one-for-one, a single feature adds that many issues to the project: the
backlog stops being readable, every board filter has to learn to exclude them, JQL over the project
returns pages of sub-tasks, and everybody watching the project receives a notification per created
issue. The user's report is exactly this — _"cela évite de se retrouver avec énormément de ticket sur
Jira"_.

The alternative this feature adds is not a reduction of the task tier, it is a different rendering of
it: the same task list, attributed to the same stories, ticked by the same checked box in `tasks.md` —
carried **inside the story's own ticket as a checklist** rather than as one issue per line. A story
with twenty tasks stays one issue with twenty checklist entries, and the developer who opens it still
sees the breakdown and still sees which parts are done.

What already exists to build on:

- the `tasks.md` reader and the neutral task content it emits — task text, story attribution, phase,
  checked state (012, FR-001…FR-005);
- the story description's **managed region** and the two-marker splice that owns the bytes below the
  boundary while preserving a human's prose above it (018, 020);
- the neutral-content-to-ADF rendering path, including the Markdown subset every mirrored `tasks.md`
  line already goes through (016);
- the configuration ceremony's closed-question machinery and the byte-preserving managed-region splice
  it uses to record answers into the committed team config (011, `field_defaults`);
- the drift vocabulary: a named warning identifying the ticket and the divergent field before any
  overwrite decision.

What must not be reused: `task_strategy` is a **retired** configuration key. It is rejected by
validation in both ports (008), and the new setting must not resurrect that name.

`docs/VISION.md` §2 names a checklist entry inside the user story as part of an envisioned completion
sync, and flags the direction of that sync as a genuine design decision rather than a detail. This
specification is what authorises the work, and it takes only the disk-driven direction: `tasks.md` is
the source of truth, and nothing is ever written back to it. The Jira-driven direction stays
envisioned and unbuilt.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - A team mirrors a hundred-task feature without creating a hundred tickets (Priority: P1)

A tech lead sets their project to mirror tasks as checklists. A developer runs `/speckit-tasks`, the
mirror fires on the `after_tasks` event as it already does, and the feature's task list appears in
Jira: one specification issue, one issue per user story, and inside each story a checklist holding
exactly that story's tasks. No sub-task is created. The backlog holds the same number of issues it held
before the task list existed.

**Why this priority**: This is the request, and it carries the whole of the stated value. A team that
cannot bound the ticket count is a team that turns the task tier off entirely, and loses it.

**Independent Test**: Configure checklist mode against a fixture project, reconcile a specification
whose task list attributes tasks to three stories, and observe zero issues created beyond the
specification and story tiers, with each story's ticket carrying a checklist of exactly its own tasks
in the order `tasks.md` gives them.

**Acceptance Scenarios**:

1. **Given** a project set to checklist mode and a task list attributing tasks to three stories,
   **When** the specification is reconciled, **Then** each story's ticket carries one checklist holding
   exactly the tasks attributed to it, and no issue is created at the task tier.
2. **Given** the same project, **When** the run finishes, **Then** the run summary reports the
   checklists it wrote as their own counts, distinct from the sub-task counts, and names every task it
   did not mirror with the reason.
3. **Given** a story that no task is attributed to, **When** it is mirrored, **Then** its ticket carries
   no checklist at all — not an empty one, and not a placeholder entry.

---

### User Story 2 - Checking a task off ticks it in Jira (Priority: P1)

A developer finishes a task, `/speckit-implement` checks its box in `tasks.md`, and the next reconcile
shows that entry ticked in the story's checklist. Nobody opens the repository to find out how far the
story has got, and nobody maintains the checklist by hand.

**Why this priority**: A checklist that never advances is worse than no checklist — it states,
permanently and visibly, that nothing has been done. This is what makes the mode a real substitute for
sub-tasks rather than a decorative summary.

**Independent Test**: Reconcile a task list with every box unchecked, check three boxes, reconcile
again, and observe exactly those three entries ticked and every other byte of the ticket unchanged.

**Acceptance Scenarios**:

1. **Given** a mirrored checklist and a task whose box is now checked in `tasks.md`, **When** the
   specification is reconciled, **Then** that entry reads as checked in the story's ticket.
2. **Given** a checklist whose entries already match `tasks.md`, **When** the specification is
   reconciled again, **Then** zero writes are issued and every ticket is left byte-for-byte unchanged.
3. **Given** a person who ticked an entry in Jira that `tasks.md` reports as unchecked, **When** the
   specification is reconciled, **Then** the run reports one named warning identifying the story and the
   entry before the checklist is rewritten from the file, and the box in `tasks.md` is not touched.

---

### User Story 3 - The choice is offered once, and stays editable afterwards (Priority: P2)

An operator runs the configuration command. Among the questions it already asks, it asks — once, per
project, as a closed question over exactly two answers — whether that project's tasks should be
mirrored as sub-tasks or as a checklist on each story. The answer is written into the committed team
configuration in the same business vocabulary as every other key there, so a tech lead can read it,
change it in an editor months later, and have the next reconcile honour the new value without running
anything else.

**Why this priority**: An option nobody is offered is an option nobody uses, and an option that can only
be set by re-running a ceremony is a trap. Both halves of the request are here.

**Independent Test**: Run the configuration command against a fixture project, answer the question,
observe the value in the committed team config; re-run the command and observe that nothing is re-asked
and the file is rewritten byte-for-byte identically; edit the value by hand and observe the next
reconcile follow it.

**Acceptance Scenarios**:

1. **Given** a project with no mode recorded, **When** the configuration command runs, **Then** it asks
   one closed question over exactly the two accepted answers and records the answer in the committed
   team configuration.
2. **Given** a project whose mode is already recorded, **When** the configuration command runs again,
   **Then** it asks nothing about the mode and the configuration file is rewritten byte-for-byte
   identically.
3. **Given** a recorded mode edited by hand in the configuration file, **When** the next reconcile runs,
   **Then** it mirrors the task tier in the edited mode with no other action required — no re-run of the
   ceremony, no flag, no cleanup.
4. **Given** a configuration file carrying a value that is neither accepted answer, **When** anything
   reads it, **Then** the run refuses with zero writes, naming the setting, the project, the offending
   value and the accepted values.

---

### User Story 4 - A team already mirroring sub-tasks is not disturbed, and switching destroys nothing (Priority: P2)

A team that shipped on the sub-task tier upgrades. Nothing changes: no question forces an answer, no
existing sub-task moves, and a project that records no mode keeps mirroring exactly as it did. When
that team later chooses the checklist, the sub-tasks already in Jira are not deleted and not silently
abandoned — the run says what is now unmaintained, once, by name.

**Why this priority**: An upgrade that rewrites a working mirror is a defect, and a mode switch that
quietly orphans dozens of issues is the kind of surprise that ends trust in an automatic mirror.

**Independent Test**: Reconcile a specification in sub-task mode, switch the project to checklist mode,
reconcile again, and observe that the issue count did not fall, that the checklist now carries the task
list, and that the run named the sub-tasks it no longer maintains.

**Acceptance Scenarios**:

1. **Given** a project carrying no recorded mode, **When** it is reconciled, **Then** every surface is
   byte-for-byte identical to the previous release's output.
2. **Given** a project switched from sub-tasks to checklists, **When** it is reconciled, **Then** no
   sub-task is deleted, and the run reports once, by story, what is no longer maintained.
3. **Given** a project switched from checklists back to sub-tasks, **When** it is reconciled, **Then**
   the checklist is removed from the story's managed region, and tasks whose sub-tasks still exist are
   re-bound to them rather than duplicated.

---

### User Story 5 - A project that offers no sub-task type can still mirror its task list (Priority: P3)

A team whose Jira project exposes no sub-task issue type — or whose administrators do not permit one —
has had no way to mirror the task tier at all. In checklist mode the task tier needs no sub-task type
and no `task` role: the tier becomes available to them for the first time.

**Why this priority**: Real value, and it falls out of the design at no extra cost — but it is a
consequence of the feature rather than the reason for it.

**Independent Test**: Point the bridge at a fixture project reporting no sub-task issue type, set
checklist mode, reconcile, and observe the task list mirrored with no refusal and no role declaration.

**Acceptance Scenarios**:

1. **Given** a project reporting no sub-task issue type and no declared `task` role, **When** it is set
   to checklist mode and reconciled, **Then** the task list is mirrored as checklists and no refusal is
   produced.

---

### Edge Cases

- **A task carries no story attribution.** It is not mirrored, exactly as in sub-task mode: no checklist
  can host it, and no issue is invented to. It is named individually in the run summary.
- **A task is attributed to a story the specification does not contain.** No write, named by task
  identifier and attribution, and every other task still mirrors.
- **`tasks.md` is absent beside the specification.** Silent no-op: no refusal, no warning, no write, and
  the story's managed region carries no checklist section.
- **`tasks.md` is regenerated with every task identifier renumbered** and the task text and order
  unchanged. Zero writes: nothing an entry carries can change under a renumber.
- **A task's text is reworded.** The one entry is rewritten; the rest of the checklist and every byte
  above the managed boundary are unchanged.
- **A task is removed from `tasks.md`.** Its entry disappears from the checklist on the next reconcile.
  Nothing is deleted in Jira, because a checklist entry is not a Jira artifact — but the removal is
  visible, and the summary counts the story as updated.
- **A person ticks, unticks, rewords or deletes an entry in Jira.** The divergence is reported by name
  before the checklist is rewritten from the file; the file wins; and `tasks.md` is never edited in
  response.
- **A person writes prose above the story's managed boundary.** Preserved verbatim, as it already is —
  the checklist lives strictly below the boundary.
- **The story's description already carries more than one boundary marker.** Malformed: the description
  field is omitted from that write entirely rather than guessed at, and every other field of the ticket
  still reconciles.
- **The rendered description, checklist included, exceeds what the sink accepts.** That one story's
  description write is withheld and named; every other story, and every other field of that story, still
  reconciles.
- **`tasks.md` uses CRLF line endings.** The host's dominant line ending is respected and the mirrored
  result is identical to what the same file with LF endings produces.
- **The project is set to checklist mode and also declares a `task` role.** The mode wins: checklist
  entries are written and no sub-task is created. The declared role is reported once as recorded and not
  consumed in this mode, so nobody concludes both are happening.
- **A story is mirrored for the first time with every one of its tasks already checked.** The checklist
  is created with every entry ticked in one write; a finished story does not arrive in Jira as
  outstanding work.
- **Two stories in the same specification hold tasks whose text is identical.** Each story's checklist
  holds its own entry; entries are never shared or deduplicated across stories.
- **The specification is reconciled with `--dry-run`.** Every checklist that would be written is shown,
  per story, with its entries and their checked state, and nothing is written.

## Requirements _(mandatory)_

### Functional Requirements

**Choosing how the task tier is mirrored**

- **FR-001**: The committable team configuration MUST accept a per-project setting that names how that
  project's task tier is mirrored, with exactly two accepted values: one issue per task (the behaviour
  shipped by feature 012) and one checklist entry per task inside the story's own ticket. The setting
  MUST be expressed in the same business vocabulary as the keys beside it, so a tech lead can read it
  without opening the documentation.
- **FR-002**: The setting MUST be absent-safe. A project that does not carry it MUST behave exactly as
  it does today — sub-tasks when a `task` role is declared, no task tier when one is not — and MUST
  produce output byte-for-byte identical to the previous release on every surface, the configuration
  ceremony's question set included.
- **FR-003**: The setting MUST be editable by hand in the committed configuration file after the fact.
  Changing it MUST be the only action required: the next ordinary reconcile mirrors the task tier in the
  new mode with no re-run of the configuration command, no flag, and no cleanup step.
- **FR-004**: A value that is neither accepted answer MUST be refused at configuration-validation time
  with zero writes and the exit code that already covers an invalid team configuration. The refusal MUST
  name the setting, the project, the offending value and the accepted values. It MUST NOT be guessed at
  and MUST NOT silently fall back to a default.
- **FR-005**: Checklist mode MUST NOT require a declared `task` role and MUST NOT require the project to
  offer any sub-task issue type. A project that offers none MUST be able to mirror its task tier in this
  mode without a refusal.
- **FR-006**: The new setting MUST NOT reuse the name of the retired `task_strategy` key, and MUST NOT
  cause that key to stop being refused as retired.
- **FR-007**: A project MUST be in exactly one mode per run. No task may receive both a sub-task and a
  checklist entry, and no run may mirror one story's tasks as sub-tasks and another's as entries.

**Offering the choice at configuration time**

- **FR-008**: The configuration ceremony MUST offer the choice, per project, as a closed question over
  exactly the two accepted values, on the same terms as the closed questions it already asks. The
  question MUST be posed whether or not a `task` role is declared, because checklist mode needs none.
- **FR-009**: An answer already recorded MUST NOT be re-asked. A ceremony re-run over an unchanged
  repository MUST ask nothing about the mode and MUST rewrite the configuration file byte-for-byte
  identically.
- **FR-010**: The answer MUST be persisted into the committed team configuration through the same
  byte-preserving managed-region splice the ceremony already uses to record answers: every byte outside
  the region is preserved, and a hand-written entry the ceremony did not ask about is re-emitted
  unchanged.
- **FR-011**: When no answer can be obtained — the operator declines, or the run is non-interactive —
  nothing MUST be recorded, behaviour MUST be unchanged, and the ceremony MUST report that the question
  went unanswered rather than assuming either value.
- **FR-012**: When the recorded answer is sub-task mode and no sub-task issue type can be resolved for
  that project, the ceremony MUST say so at configuration time, with the remedy, rather than letting the
  first reconcile discover it.
- **FR-013**: The ceremony MUST report the recorded mode per project in its run summary, alongside the
  effects it already reports separately.

**What the checklist is**

- **FR-014**: In checklist mode, every task attributed to a mirrored user story MUST appear as one entry
  of exactly one checklist **section** carried by that story's ticket. A story MUST NOT carry two
  checklist sections — a reader MUST NOT find the task list in two places — and an entry MUST NOT appear
  under a story the task is not attributed to. A single section MAY hold one list per phase group, which
  is how FR-018's grouping is expressed: no list node can contain a heading.
- **FR-015**: The checklist MUST be carried by the story's ticket using only what Jira itself offers,
  with no Marketplace add-on installed, so that the mode is available in every project the bridge can
  already write to. Each entry MUST present its completion state to a reader who never opens the
  repository. A rendering that is interactive in Jira's own interface is preferred; where the tracker
  does not offer one, a rendering that merely states each entry's completion state legibly satisfies
  this requirement, and no add-on may be required to reach either.
- **FR-016**: An entry's text MUST be the task's own text with the durable identifier and the markup
  that serves only the task file removed — the same text a sub-task's summary carries in the other mode,
  so the two modes read identically.
- **FR-017**: An entry MUST NOT carry the task's positional identifier (`T012`) or any other value that a
  regeneration of `tasks.md` can change, so that a renumbered task list produces zero writes.
- **FR-018**: Entries MUST appear in the order `tasks.md` gives them, and MUST be grouped under the phase
  that encloses them when the task list declares phases.
- **FR-019**: The per-task detail a sub-task description carries in the other mode — files touched,
  declared dependencies, parallel-safety, continuation lines — is deliberately NOT carried into a
  checklist entry. The bridge MUST NOT invent a second place on the story to hold it; `tasks.md` remains
  where that detail lives, and the trade MUST be stated in the documentation.
- **FR-020**: The checklist MUST live strictly below the story description's managed boundary marker. A
  human's prose above the boundary MUST be preserved verbatim on every reconcile, and a description
  carrying more than one boundary marker MUST have that field omitted from the write entirely rather
  than guessed at, while every other field of the ticket still reconciles.
- **FR-021**: A user story that no task is attributed to MUST carry no checklist at all — no empty
  checklist and no placeholder entry — and MUST otherwise be mirrored exactly as it is today.
- **FR-022**: A task carrying no story attribution MUST NOT be mirrored in checklist mode, and no
  checklist may be invented to host it. Each such task MUST be named individually in the run summary,
  by task identifier, with the reason.
- **FR-023**: The Markdown subset already honoured in a mirrored task line MUST be honoured in an entry,
  producing the same rendered result the sub-task tier produces for the same line.
- **FR-024**: No Jira identifier, issue type, project key or checklist representation may cross into the
  layer that reads the task list and assembles neutral content. That layer MUST emit neutral checklist
  content — entries, their order, their grouping and their completion state — and the sink alone MUST
  render it.

**Completion state**

- **FR-025**: A task whose box is checked in `tasks.md` MUST have its entry read as complete, and a task
  whose box is unchecked MUST have its entry read as incomplete, after one reconcile.
- **FR-026**: An entry's completion state MUST follow `tasks.md` in both directions. Unlike a sub-task's
  status — an independent Jira state that this bridge never pulls backwards — a checklist entry is
  content the mirror owns inside the managed region, so a task reverting to unchecked renders unchecked
  again.
- **FR-027**: When the checklist found on the ticket differs from the one the mirror last wrote — an
  entry ticked, unticked, reworded, added or removed by a person — the run MUST report one named warning
  identifying the story and the divergent entries **before** the checklist is rewritten.
- **FR-028**: Completion MUST be mirrored in one direction only. A person completing an entry in Jira
  MUST NOT check the box in `tasks.md`; the filesystem remains the source of truth and the divergence is
  reported under FR-027.
- **FR-029**: Completing every entry of a story's checklist MUST NOT transition, close or otherwise
  change the status of that story's issue, or of the specification's issue. This feature changes no
  issue's status.

**Zero churn and identity**

- **FR-030**: A reconcile over an unchanged repository and unchanged tickets MUST issue zero writes of
  every kind in checklist mode.
- **FR-031**: Checklist mode MUST assign no durable identifier in `tasks.md`, and MUST leave every
  durable identifier already recorded there untouched — so that a team switching back to sub-task mode
  re-binds to the sub-tasks it already has instead of duplicating them.
- **FR-032**: Any refusal or warning this feature produces MUST NOT prevent a story, a specification or
  another story's checklist from reconciling.

**Switching modes**

- **FR-033**: Switching a project from sub-tasks to checklists MUST leave every sub-task already
  mirrored exactly as it stands: not deleted, not closed, not transitioned, not updated, and never
  written to again while the project stays in checklist mode. The switch MUST NOT require a
  confirmation step, a flag, or a second run — editing the setting remains the only action needed
  (Constitution X) — and the mirror MUST NOT keep the abandoned sub-tasks in step with `tasks.md`,
  because a task mirrored in two places at once is the duplication this feature exists to end.
- **FR-034**: A switch in either direction MUST be reported once in the run summary, naming the stories
  affected, the count of sub-tasks the mirror no longer maintains, and a copy-pasteable query that
  selects exactly those sub-tasks in the tracker — so the cleanup this feature deliberately leaves to a
  human is one action away rather than a hunt (Constitution XVI). A partially migrated project MUST
  never be readable as a fully migrated one.
- **FR-035**: Switching a project from checklists back to sub-tasks MUST remove the checklist from the
  story's managed region — leaving every byte above the boundary and every other managed block intact —
  and MUST create the sub-tasks, re-binding by durable identifier any task whose sub-task still exists
  rather than creating a duplicate.

**Reporting, dry run, safety and portability**

- **FR-036**: The run summary MUST report checklist outcomes as their own counts — stories whose
  checklist was created, updated, or left unchanged, and entries completed this run — distinct from the
  specification, story and sub-task tiers, and MUST name every task it did not mirror with its reason.
- **FR-037**: A dry run MUST show every checklist it would write, per story, with each entry's text and
  completion state, and MUST write nothing.
- **FR-038**: Every checklist payload MUST pass the privacy guard before it is issued, on the same terms
  and with the same two tiers and allowlist as every other write, preserving the guard-then-write
  ordering.
- **FR-039**: Any refusal or warning this feature produces, when it occurs inside a lifecycle hook, MUST
  be reported as one warning while the host command still succeeds.
- **FR-040**: Both ports MUST produce byte-identical output for the same repository state, and the
  conformance corpus MUST cover checklist mode, the completion of an entry, a switch in each direction,
  and the ceremony's new question.
- **FR-041**: When a story's rendered description including its checklist exceeds what the sink accepts,
  that one description write MUST be withheld and named, and every other field of that story and every
  other story MUST still reconcile.
- **FR-042**: The documentation surfaces that describe the task tier — the configuration ceremony, the
  reconcile flow, the configuration layers, and the README's managed block — MUST describe both modes in
  the same change that ships them. A release that offers the choice while its documentation names
  sub-tasks as the only outcome is a defect.

### Key Entities

- **Task mirror mode**: a per-project choice, recorded in the committable team configuration, taking one
  of exactly two values — sub-task per task, or checklist entry per task. Absent means the shipped
  behaviour. It is a team decision about how their Jira reads, not a machine-resolved identifier and not
  a secret.
- **Story checklist**: the single, ordered, phase-grouped collection of entries a story's ticket carries
  in checklist mode, holding exactly the tasks attributed to that story, living entirely below the
  description's managed boundary.
- **Checklist entry**: one task, rendered as its own text plus a completion state. It is derived content
  owned by the mirror — not an independently addressable Jira artifact, and therefore carrying no
  durable identifier of its own.

## Constitution Check _(mandatory)_

| #    | Principle                                                             | Proof of compliance                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ---- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| I    | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | No new exception is claimed. FR-028 keeps the sync one-directional and FR-031 keeps `tasks.md` unwritten by this feature; FR-027 requires a named drift warning identifying the story and the divergent entries before any overwrite; FR-033 forbids deleting, closing, transitioning or even updating a sub-task on a mode switch, and FR-029 forbids changing any issue's status at all. FR-034 makes the resulting cleanup a human's decision, handed to them by name and with a query rather than performed for them. |
| II   | Zero-Churn Idempotency                                                | FR-030 (zero writes on an unchanged re-run), FR-017 (no value a `tasks.md` regeneration can change may reach an entry, so a renumbered task list churns nothing), FR-009 (a ceremony re-run rewrites the configuration file byte-for-byte), FR-020 (the managed-region splice leaves a settled description untouched). No identity is keyed on a mutable field: FR-031 states plainly that an entry is not independently addressed.                |
| III  | Fail-Closed on Writes, Non-Blocking on Hooks                          | FR-004 refuses an unrecognised mode at validation time with zero writes; FR-041 withholds exactly the one description that cannot be formed and lets everything else reconcile; FR-020 omits a malformed description field rather than guessing; FR-039 keeps every hook non-blocking with a single actionable warning.                                                                                                                            |
| IV   | Credential Security — Zero Tokens in the Tree, Ever                   | Unaffected. The feature adds one non-secret enumerated setting to the committed team configuration and introduces no new credential path, no new transport call shape and no new logging surface. The existing refusal of credential-shaped values in that file covers it unchanged.                                                                                                                                                               |
| V    | Separation of Team Config / Local Binding / Secrets                   | The mode is a team decision about how their Jira reads, so FR-001 and FR-010 place it in the committable team layer beside `hierarchy` and `field_defaults`. No resolved id, no machine-owned value and no secret is introduced: the local binding and the environment file are untouched.                                                                                                                                                         |
| VI   | macOS / Linux / Windows Portability                                   | FR-040 requires byte-identical output from both ports and extends the conformance corpus to checklist mode, entry completion, both switch directions and the new question. No new line-ending surface is created: the checklist is written through the same managed splice that already respects the host's dominant line ending, and the CRLF edge case is called out explicitly.                                                                 |
| VII  | No Hard-Coded Assumptions About the Jira Workflow                     | Strengthened. A checklist carries no status, so checklist mode needs neither a done-status resolution nor a sub-task issue type (FR-005) — it removes two workflow dependencies rather than adding one. No type name, status name or field id is compiled in, and FR-015 forbids depending on a Marketplace add-on, so no assumption is made about what a given project has installed either.                                                     |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface                 | FR-024: the layer that reads the task list emits neutral checklist content — entries, order, grouping, completion state — and no Jira identifier, issue type, project key or checklist representation crosses into it. The sink alone renders it.                                                                                                                                                                                                  |
| IX   | Two-Tier Privacy Guard, With an Allowlist                             | FR-038: every checklist payload is scanned before it is issued, with the same two tiers and the same allowlist as every other write, and the guard-then-write ordering is unchanged — a blocked payload aborts the apply as it does today.                                                                                                                                                                                                         |
| X    | Self-Healing Automatic Mirror                                         | FR-003 makes a hand-edit of one line the only action required; the next ordinary reconcile converges with no flag, no manual step and no cleanup. FR-035 re-binds rather than duplicates when a team switches back, so a round trip through the other mode heals itself.                                                                                                                                                                           |
| XI   | Universal Dry-Run and Auditability                                    | FR-037: a dry run shows every checklist it would write, per story, with each entry's text and completion state, and writes nothing. FR-036 and FR-013 give the checklist and the recorded mode their own reported lines rather than folding them into an opaque total.                                                                                                                                                                             |
| XII  | Quality and Catalog Publication                                       | FR-042 updates the four documentation surfaces in the same change that ships the behaviour; FR-040 grows the conformance corpus with the feature; the existing static-analysis gates are unaffected by a specification-level change and stay clean.                                                                                                                                                                                                |
| XIII | TDD With a Minimum 80% Coverage                                       | Every requirement here is stated as an outcome observable from outside, so each can be written as a failing test first: the refusal of an unrecognised value, the zero-write re-run, the renumber-produces-nothing case, the drift warning, the ceremony question and its non-repetition, and both switch directions. Tests identify what they observe by identifiers they recorded, never by a name-pattern scan.                                 |
| XIV  | KISS — The Simplest Solution That Satisfies the Spec                  | One enumerated setting with two values, in the file a tech lead already reads, reusing the `tasks.md` reader, the managed-region splice, the Markdown subset, the drift vocabulary and the ceremony's closed-question machinery. Nothing new is invented, and FR-006 refuses to carry two names for one idea by resurrecting the retired key.                                                                                                      |
| XV   | YAGNI — Nothing Is Built Before a Spec Requires It                    | Scope is bounded to the request: two modes, one question, one checklist per story, disk-driven completion. Explicitly out of scope and named as such below: per-story overrides, a third mode, transitioning a story when its checklist completes (FR-029), writing back to `tasks.md`, and the Jira-driven direction `docs/VISION.md` §2 leaves envisioned.                                                                                       |
| XVI  | Human Readable — Readable by a Human Above All                        | FR-001 requires business vocabulary for the setting and its values; FR-004's refusal names the setting, the project, the offending value and the accepted values; FR-034's switch report names what changed and what is unmaintained instead of emitting a code; FR-019 states the detail trade in the documentation rather than letting a reader discover it by absence.                                                                          |

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: Mirroring a feature of 5 user stories and 100 tasks in checklist mode creates 6 Jira
  issues, against 106 in sub-task mode — at least a 90% reduction in issues created for the same
  feature, with no loss of which tasks belong to which story.
- **SC-002**: 100% of the tasks checked off in `tasks.md` read as complete in Jira after one reconcile,
  with no manual step in Jira.
- **SC-003**: A second reconcile over unchanged inputs performs zero writes and leaves every mirrored
  ticket byte-for-byte unchanged, in both modes.
- **SC-004**: A team changes how its tasks are mirrored by editing a single line of its configuration
  file; the next reconcile honours it with no other action.
- **SC-005**: An operator configuring a project answers exactly one additional closed question, and a
  second run of the configuration command asks it zero times.
- **SC-006**: Switching a project's mode never reduces the number of Jira issues: the issue count after
  the switch is greater than or equal to the count before it.
- **SC-007**: A project that offers no sub-task issue type mirrors its full task list without a single
  refusal — a case that produces no task tier at all today.
- **SC-008**: A team that records no mode observes output byte-for-byte identical to the previous
  release on every surface, including the configuration command's question set.
- **SC-009**: Both ports produce byte-identical output across the whole conformance corpus, checklist
  scenarios included, on macOS, Linux and Windows.

## Out of Scope

- Writing anything back into `tasks.md` from Jira, including ticking a box because someone completed an
  entry. That is `docs/VISION.md` §2's Jira-driven direction and would require a third controlled
  exception to Principle I.
- Changing the status of a story or a specification when its checklist completes (FR-029).
- A per-story or per-specification override of the mode: the choice is per project.
- A third mode, including "mirror the task tier as neither" — removing the `task` role and recording no
  mode already produces that.
- Carrying the sub-task tier's per-task detail (files, dependencies, parallel-safety) onto the story in
  some other form (FR-019).
- Migrating existing sub-tasks into checklist entries, or the reverse, as a data migration. A mode switch
  changes what future reconciles write; it does not rewrite history.
- Cleaning up the sub-tasks a switch leaves behind. FR-034 names them and hands the operator a query;
  bulk-closing or deleting them is theirs to do, and Principle I forbids the bridge doing it for them.
- Support for a Jira Marketplace checklist app's field (Smart Checklist, Issue Checklist for Jira, and
  the like). FR-015 rules out any add-on dependency. Should a team want their app's checklist to be the
  target instead, that is a separate feature with its own discovery, its own degradation path for
  projects without the app, and its own spec.

## Assumptions

- **The setting belongs in the committed team configuration**, not in the gitignored local binding: the
  request calls it "le fichier de configuration de l'extension Jira", it is a team-wide decision about
  how their Jira reads, and it holds no resolved id and no secret. It sits per project alongside
  `hierarchy`, so a repository routing several projects can answer differently for each.
- **Absent means the behaviour shipped today.** No migration writes a mode into an existing
  configuration, because doing so would rewrite a file the team owns to state something they never
  chose.
- **Checklist mode ignores a declared `task` role rather than refusing it**, so a team can switch modes
  without first deleting a key. The unused role is reported once as recorded and not consumed.
- **The engine's `tasks.md` reader is reused unchanged**: attribution, phase, text and checked state are
  already extracted (012, FR-002/FR-003), and this feature adds a rendering of that neutral content, not
  a second reader.
- **A checklist is content, not an artifact.** That is what makes FR-026's two-directional completion and
  FR-031's absence of durable identifiers consistent with Principle I, and it is the one place this
  feature deliberately behaves differently from the sub-task tier.
- **`--dry-run`, the privacy guard, the drift vocabulary and the hook non-blocking rule apply unchanged**;
  none of them needs an extension for this feature, only coverage.
- **Whether the tracker offers an interactive checkbox inside a ticket's description was a matter for
  measurement, not assumption** — and the measurement has been taken. FR-015 is written so that the
  feature is deliverable either way; `research.md` §1 records that Jira Cloud's `taskList`/`taskItem`
  nodes are undocumented and publicly unsupported, so the **non-interactive rendering is what ships**.
  That is the outcome FR-015 anticipates, not a failure: it states each entry's completion state legibly,
  needs no add-on, and reaches every project the bridge can already write to. The measurement was
  documentary rather than live, which is stronger here than one instance's behaviour — what a single site
  accepts today is not what Atlassian has committed to.
- **Abandoning a sub-task is a state a human resolves, not a state the mirror maintains.** FR-033 and
  FR-034 assume the duplication a switch creates is transient because someone acts on the report; a
  mirror that kept both representations in step would make it permanent, which is the outcome this
  feature exists to prevent.
