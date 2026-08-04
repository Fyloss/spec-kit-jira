# Phase 0 — Research: the third tier

Nine decisions. Each is stated with what it rejected, because the rejected option is usually the one
a later reader will re-propose.

---

## R1 — Where a task's durable identifier lives

**Decision.** A marker line of its own, inserted immediately **after** its task line, carrying a third
grammar beside the two that ship today:

```markdown
- [ ] T014 [P] [US1] Implement the neutral task parser in scripts/bash/engine/tasks_parse.sh
<!-- speckit-jira task=3f8a1c02d94b7e65 ticket=PROJ-412 -->
```

Three states, exactly as `story_marker` has: bare (`task=<id>`, assigned), `creating`, and
`ticket=<KEY>` (bound). The identifier is 16 lowercase hex characters from the same generator, and the
ticket key is opaque text handed in by the caller — the engine cannot know what a Jira key is
(Constitution VIII).

**Rationale.** `engine/marker_splice.sh` already owns byte offsets, dominant line-ending detection,
atomic writes and whole-line replacement, and `engine/spec_marker.sh` already proves the primitive
carries a *second* grammar without modification. A third grammar is the shape this codebase already
has. A separate line is also the only placement that survives the single most frequent mutation of
`tasks.md`: `/speckit-implement` rewriting `- [ ]` into `- [x]` on the task line itself.

**Rejected — an inline suffix on the task line.** `- [ ] T014 … <!-- speckit-jira task=… -->` halves
the added line count and keeps the file denser. It loses on the checkbox rewrite: the completion bit
and the identifier would share one line, so every completion edit is an opportunity for an agent
rewriting that line to drop the identifier — and losing it costs a duplicate sub-task (FR-017). The
most frequent edit must be the one that cannot break identity.

**Rejected — a mapping region at the end of the file.** A managed region needs a stable key per task
to point at. A regenerated task list has none by design: the task number is renumbered (FR-016 exists
precisely because of this), the text is editable, and the position is meaningless. Keying it on any of
those is what FR-013 forbids.

**Rejected — the gitignored local binding.** It would put the identity outside the tracked tree
(against Principle I) and make the mirror unshareable: a colleague's clone, having no binding, would
re-create every sub-task the team already has.

---

## R2 — How a task is attributed to a user story

**Decision.** The `[US<N>]` tag first; failing that, the enclosing `## Phase …: User Story <N>`
heading; failing both, unattributed. `N` is the story's **ordinal within the specification**, and the
engine emits nothing but that ordinal plus which of the two sources supplied it. Resolution against
real stories happens where the neutral document is assembled, in document order.

**Rationale.** FR-003 states both sources and gives the tag precedence; the spec's Assumptions state
that the generating command writes ordinals. Emitting the *source* alongside the ordinal costs one
field and lets the run summary explain an attribution a reader did not expect (Principle XVI).

**Rejected — matching the story's title text.** It breaks the moment a story is reworded, which is a
routine spec edit, and it re-derives story identity from a second document — exactly the coupling the
neutral document exists to avoid.

**Rejected — requiring the tag always.** FR-003 promotes the heading deliberately: a phase heading
that names a user story *is* a statement of attribution, and a generated list routinely relies on it.

---

## R3 — The shape of tasks in the neutral document

**Decision.** Nested: `stories[].tasks[]`. Each task carries `local_id`, `task_ref` (`T014` — carried
for reporting only, never for recognition), `title`, `description.blocks`, `attribution`, `phase`,
`parallel`, `files`, `depends_on`, `done`, and `marker`. Validation rules join
`_INTERCHANGE_ERRORS_JQ` so an invalid task blocks every write of the run, as the schema already does
for a story.

**Rationale.** Nesting makes "a task attributed to a story this specification does not contain"
*unrepresentable* in the document rather than a runtime check downstream — the dangling task is
reported during assembly and never becomes a document the sink could act on (FR-004). It also matches
how `plan_writes` already iterates: one loop over stories, which now plans a story and its tasks
together.

**Rejected — a top-level `tasks[]` with a `story_local_id` foreign key.** It permits a dangling
reference to exist inside a validated document, which means every consumer must re-check it. The
nesting is the check.

---

## R4 — Ordering, and resolving the parent key

**Decision.** The plan's return shape grows a third array: `{parent, stories, tasks}`. Each task
action carries `local_id`, `role:"task"`, `parent_local_id` (its story's local id) and
`fields.parent.key = "<resolved at apply time>"`. `apply_writes_with_recognition` writes the epic
first, then the stories, building a `local_id → key` map from their create responses, then the tasks —
resolving each placeholder from that map, or from the story's already-recorded key when the story was
recognised rather than created.

**Rationale.** This is the mechanism the story tier already uses for the epic, one level down, and it
is what makes the spec's edge case true — "sub-tasks are planned against the stories created in that
same run, not deferred to a second run" — without a second pass. Each created sub-task's key is
recorded into `tasks.md` immediately, never batched, for the same reason the story tier does it: a run
interrupted between a create's response and its record leaves every other task creatable.

**Rejected — deferring tasks to the next run when their story is new.** It makes the first mirror of
a feature take two runs, which the hook cannot arrange, and it contradicts the spec.

---

## R5 — How a completed task reaches a done status *(the one genuinely new capability)*

**Finding first, because it changes the size of User Story 5.** `plan_lifecycle` emits a transition
action when the lifecycle context carries a `transition_id` — and **nothing in either port ever
populates one**. A grep across `scripts/` finds exactly one producer: the `SPEC_KIT_JIRA_LIFECYCLE`
environment seam the tests drive. The story tier's transition machinery is therefore planned but
inert: drift is evaluated and warned about, and no transition has ever been issued by a shipped path.

**Decision.** Add one Jira read to the sink — `GET /rest/api/3/issue/{key}/transitions` — and select
the transition whose destination the project classifies as done (`to.statusCategory.key == "done"`).
Exactly one candidate transitions; zero candidates or two or more issue nothing and report once,
naming the issue and, where there are several, the candidates (FR-030, and the spec's edge case on an
ambiguous done status). The read is issued only for a task that is checked in the file and whose
sub-task is not already in a done-category status — which `recognition` already reports as
`status_category`. An unchanged re-run therefore issues zero reads and zero transitions (FR-031).

**Rationale.** FR-030 forbids a status name in any spelling or language, so the destination's
classification is the only admissible input, and it is knowable only from this endpoint.

**Rejected — a configurable status name.** The spec's Out of Scope, and Principle VII's exact
prohibition. It fails on the consumer instance whose statuses are French — the case SC-010 exists to
prove.

**Rejected — reusing `phase_status_map`.** It maps a *hook event* to a status *name* for the whole
run. The task tier needs a per-issue target derived from classification: wrong granularity, and it
would import the hard-coded-name problem the map has always had at the story tier.

**Rejected — reading the workflow scheme once at binding time.** A sub-task's available transitions
depend on its *current* status, so a per-project cache answers a per-issue question and goes stale
silently.

**Obligation this creates.** Transition is a new write kind for the sink, so Constitution II's
enforcement clause applies literally: the live idempotency assertion list must be extended in this
same change. Planned as a task, not left as a note.

---

## R6 — Withholding the task tier instead of refusing the specification (FR-036)

**Decision.** `hierarchy_mandatory_gate` keeps its current two-type, all-or-nothing verdict untouched
— it governs the tiers that carry the mirror, and neither can be withheld without leaving the other
incoherent. A **separate** verdict answers for the sub-task type alone, returning `ok`,
`unsatisfiable` (a required field with no recorded default and no answer) or `undefaultable` (a
required field whose shape no recorded value can express — feature 011's FR-010). Anything but `ok`
drops the whole `tasks` array from the plan, before the lifecycle filter and before any splice, and
emits one warning naming each field with feature 011's existing remedy line plus one summary note that
the tier was withheld.

**Rationale.** Dropping the tier *at plan time* makes three requirements true by construction rather
than by rule: no sub-task write is issued (FR-036), no durable identifier is recorded because
identifiers are assigned to the tasks the plan kept (FR-038), and recovery needs no state because the
next run simply plans them again (FR-039).

**Rejected — refusing in the shared gate.** The spec's superseded position. It reproduces one tier
lower the exact defect feature 011 was written to close, and permanently so when the field is
undefaultable.

**Rejected — a fourth marker state (`withheld`) written into `tasks.md`.** Nothing would read it: the
next run recomputes the verdict from the binding anyway. It would be persisted state no requirement
asks for (Principle XV) and a byte written into a tracked file for the bridge's own convenience.

---

## R7 — Widening the configuration ceremony's question scope (FR-035)

**Decision.** In `commands/config.sh`, the two expressions that build the field-defaults question
scope — the asked-about type list and the "types the bridge writes" id list — gain the `task` role
when it resolved. One expression each, in both ports. Two shipped status lines are retired in the same
change: feature 010's `task is recorded as "…" but is not mirrored yet` and feature 011's
`recorded, not yet consumed` for the sub-task type, the latter simply by the type joining the
bridge-writes list.

**Rationale.** FR-035 asks for the question only when a `task` role is declared, which is exactly the
condition under which the role resolves. Nothing else in feature 011 needs to know a third type
exists: `plan_resolve_field_defaults` is already keyed by type id and `jira_create_fields_base`
already scopes its merge to the type being created (which is what makes FR-018 true by construction
for the new type too).

**Rejected — a sub-task-specific configuration key or question.** FR-034 forbids a second surface, and
there is nothing about a sub-task type that feature 011's per-type scoping does not already handle.

---

## R8 — Per-tier counts without breaking the byte-identical guarantee

**Decision.** The run summary's `counts` object gains a nested `tasks` object —
`{created, updated, transitioned, unchanged, skipped, withheld}` — and **emits it only when a `task`
role is declared**. A repository that declares none produces a summary byte-for-byte identical to the
previous release's (FR-011, SC-005).

**Rationale.** Absence as the off switch is this codebase's established pattern: feature 011's
`field_defaults` region is never introduced for a project that recorded nothing, for the same reason.
A nested object also leaves the existing top-level tallies and the idempotent-re-run signature
(`created: 0, updated: 0, recognised == story count`) untouched for every reader that already parses
them.

**Rejected — new top-level count keys.** They would change every run's output for every team,
including those that never asked for this tier.

---

## R9 — Two new engine modules rather than growing the existing ones

**Decision.** `engine/task_marker.sh` and `engine/tasks_parse.sh`, each with its PowerShell twin
(`TaskMarker.psm1`, `TasksParse.psm1`) — the CI gate comparing leaf sets modulo extension and case
requires both ports to gain both.

**Rationale.** `engine/parse.sh` is 584 lines and owns `spec.md`'s title ladder, never-empty
descriptions, Gherkin extraction and priority — a different document with different rules; merging a
second grammar into it would make both harder to read (Principle XVI) with no shared logic to gain.
`engine/story_marker.sh` would have to branch on grammar in every function, which is more complexity
than a sibling that reuses the same splice primitives.

**Rejected — one combined `task_tier.sh`.** Marker identity and content parsing are independent
concerns with independent tests; the existing layout already separates them (`story_marker` vs
`parse`), and following it keeps the twin-port leaf comparison legible.
