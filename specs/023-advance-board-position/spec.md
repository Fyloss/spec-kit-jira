# Feature Specification: Each Tier Advances Along Its Own Declared Workflow

**Feature Branch**: `feat/advance-board-position`

**Created**: 2026-08-10

**Status**: Draft

**Input**: User description: "Advance a mirrored ticket on the board by actually issuing the Jira transition its declared phase_status_map calls for. Today phase_status_map is schema-validated, resolved per project, and feeds drift classification and warnings, but no ticket at the specification/story tier is ever moved. Scope: resolve the target status NAME declared in phase_status_map into a transition id available from the ticket's CURRENT status, and emit the transition, on a workflow the bridge does not know in advance. Reuse the resolution shapes 012 already established at the task tier. The genuinely new question is a target reachable only through intermediate statuses (multi-hop) — refusing while naming the unreachable target is a defensible v1. Everything the drift engine already decides must keep its current meaning; this feature only connects the decision to the write. Documentation correction is in scope. Both ports, byte-equivalent under the conformance corpus."

**Clarified scope**: The declared mapping is **per hierarchy role**, not per project. The specification tier
(Epic, Feature, or whatever the project calls it) has its own workflow with its own steps mapped to the
lifecycle events; the story tier has its own; and the task tier has its own when the team has enabled
sub-task mirroring. A team running three different workflows on its three roles — which is the ordinary
enterprise case — declares three mappings and gets three independently advancing boards.

## The reported gap

A team declares, in its committable configuration, which workflow step each lifecycle event corresponds to:
finishing the specification puts the ticket at "To Do", finishing the plan puts it at "In Progress". The
mapping is accepted, validated, resolved for the routed project, and read on every run. It decides how the
mirror classifies the ticket's real position, whether the position counts as agreed, halted, or already past
the point the specification describes, and which warning a reader sees when the two disagree.

Then nothing moves. The mirror reaches the conclusion that this ticket should stand at "In Progress", and
that conclusion is where the machinery stops. **No ticket at the specification or story tier is ever moved
on the board, in any circumstance.** The behaviour is not accidental — it is fixed by a test whose own name
records it: *"zero transition requests in every scenario — this release evaluates the rules but never moves
a ticket's status"*.

**What this costs a consumer.** The configuration key exists, is documented, and is described in the
repository's own documentation as producing a move. A team that declares the mapping therefore gets the half
that reads — correct drift warnings, correct refusal to overwrite a position a human chose — and none of the
half that writes. Their board never advances. Nothing in the run summary says so: the run is green, the
content is mirrored, the warnings are accurate, and the tickets sit where they were. The gap is invisible
precisely to the team most likely to trust it.

**The second half of the gap: the mapping has no notion of tier.** It is declared once per project and
evaluated only against story-tier tickets. That is survivable while nothing moves, and wrong the moment
something does. An Epic and a Story rarely share a workflow: an Epic passes through funnel, analysis,
delivery and release states that no Story has, and a Story passes through review and verification states
that make no sense on an Epic. Sub-tasks, where a team mirrors them, are different again. One mapping
cannot describe three workflows, and applying one tier's step names to another tier's tickets would
produce exactly the unreachable-step failure this feature must avoid.

**Why the half that writes was never built.** Moving a ticket is not the same shape of problem as writing a
field. A field is written by naming it. A move must first be *found*: the tracker offers, from the ticket's
current position and for the current user, a set of available moves, and which of them exists depends on a
workflow the mirror is forbidden to assume. Two moves may land on the same step. One may demand a value
before it completes. The declared step may not be reachable from here at all. Every one of those is a real
configuration a real enterprise ships, and none of them has a safe default.

**The shape already exists in this repository.** The task tier solves exactly this problem for sub-task
completion, and settled every one of those cases: no candidate, do nothing; one ungated candidate, move; one
candidate whose completion demands a value, stand down and name the value; several candidates, report them
all and invent no preference. It differs in only one respect — it selects candidates by the *kind* of step
they land on (finished or not finished), while this feature must select them by the step's declared *name*.
That difference is the feature. Everything around it is a shape this project has already agreed on, tested,
and shipped.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A declared mapping moves the ticket (Priority: P1)

A team declares that finishing the plan corresponds to "In Progress". A mirrored ticket stands at "To Do".
The team finishes the plan, the mirror runs, and the ticket is at "In Progress" when they next look at the
board — without anyone opening the tracker, and without the mirror having been told anything about this
project's workflow beyond the step's name.

**Why this priority**: It is the whole feature. Every other story here either protects this one from doing
harm in a workflow the mirror does not know, or extends it to the tiers a team actually runs. Without it the
configuration key remains documentation for behaviour that does not exist.

**Independent Test**: Declare a mapping for one role, place a ticket of that role one agreed step behind,
run the mirror under the matching lifecycle event, and observe the ticket standing at the declared step.
Fully testable alone and delivers the advertised value on its own.

**Acceptance Scenarios**:

1. **Given** a project declaring "In Progress" for the plan event on the story role, a recognised story at
   "To Do", and exactly one available move from "To Do" landing on "In Progress", **When** the mirror runs
   under that event, **Then** the story stands at "In Progress" and the run summary counts one ticket moved.
2. **Given** the same project and a story already standing at "In Progress", **When** the mirror runs under
   that event, **Then** no move is attempted, no warning is raised, and the summary counts zero moved.
3. **Given** a project declaring no mapping at all, **When** the mirror runs under any event, **Then** no
   move is attempted and the mirror asks the tracker nothing about available moves.
4. **Given** a project whose steps are named in the team's own vocabulary rather than the tracker's defaults,
   **When** the mirror runs, **Then** the move is found by the declared name alone, with no built-in list of
   step names participating in the decision.

---

### User Story 2 - Each tier follows its own workflow (Priority: P1)

A team's Epics live on a delivery workflow — Funnel, Analysing, Building, Released — while its Stories live
on a development workflow — To Do, In Progress, In Review, Done. The team describes both, each against the
same lifecycle events, and each tier advances along its own steps. Neither tier's vocabulary is ever applied
to the other's tickets.

**Why this priority**: It is the shape of every enterprise project this extension targets, and getting it
wrong is not a missing feature but an active harm: one shared mapping would send an Epic toward a step that
exists only on the Story workflow, producing an unreachable-step warning on every run for a team that
configured everything correctly.

**Independent Test**: Declare two different mappings for two roles in one project, run the mirror under one
event, and assert each tier's ticket landed on its own declared step and neither was offered the other's.

**Acceptance Scenarios**:

1. **Given** a project declaring "Building" for the plan event on the specification role and "In Progress"
   for the same event on the story role, **When** the mirror runs under that event, **Then** the parent
   stands at "Building", each story stands at "In Progress", and no ticket was ever evaluated against the
   other role's step name.
2. **Given** a project declaring a mapping for the story role only, **When** the mirror runs, **Then**
   stories advance, the parent is not moved, and no warning is raised about the parent.
3. **Given** a project that has enabled sub-task mirroring and declares a mapping for the task role, **When**
   the mirror runs under a mapped event, **Then** sub-tasks whose task is unchecked advance along the task
   role's declared steps.
4. **Given** a project that has not enabled sub-task mirroring, **When** it declares a mapping for the task
   role, **Then** no sub-task is created or moved and the mirror reports that the mapping has no effect
   while the tier is disabled.
5. **Given** a project whose mapping was written before roles existed — a single mapping with no role named
   — **When** the mirror runs after upgrading, **Then** it is honoured as the story role's mapping exactly
   as it is classified today, and neither the parent nor any sub-task begins moving because of it.

---

### User Story 3 - Every existing protection keeps its meaning (Priority: P1)

A team that already relies on the mirror's refusal to overwrite a position a human chose sees that refusal
behave exactly as before, and sees it extended, unchanged in meaning, to the tiers this feature newly moves.

**Why this priority**: The safety rules are the reason a team trusts the mirror with its board at all. This
feature is the first one able to act on them, so a rule that was merely advisory becomes consequential —
a regression here is a ticket moved against a human's wishes, which is the failure mode the whole safety
model exists to prevent.

**Independent Test**: Run the existing safety corpus unchanged and assert every decision produces the
behaviour it produced before, with the single addition that a decision to advance now also moves the ticket;
then run the same corpus against a parent ticket and assert identical decisions.

**Acceptance Scenarios**:

1. **Given** a ticket standing at a step its role's mapping has not classified, **When** the mirror runs,
   **Then** the move is withheld, the drift is named, and the content is still mirrored.
2. **Given** a ticket standing at a step the team designated as halted, **When** the mirror runs, **Then**
   every write to that ticket is suppressed, including the move, and the remediation is named.
3. **Given** a ticket standing ahead of the step the specification implies, **When** the mirror runs without
   explicit authorisation to pull it back, **Then** no backward move is attempted; **And** when the operator
   authorises it explicitly, the backward move is performed.
4. **Given** a ticket carrying the impediment marker, **When** the mirror runs, **Then** the move is
   withheld, the marker is surfaced, and the marker itself is neither set nor cleared.
5. **Given** a ticket carrying open blocking links, **When** the mirror moves it, **Then** the move proceeds
   and a note records that it advanced past open blockers; **And** no link is created, changed, or removed.
6. **Given** a parent ticket in any of the situations above, **When** the mirror runs, **Then** the decision
   and the warning wording are the same as they are for a story in that situation.

---

### User Story 4 - An ambiguous workflow is reported, never guessed (Priority: P1)

A team's workflow offers two different moves out of "To Do" that both land on "In Progress" — one routine,
one that also assigns and notifies. The mirror does not choose between them. It moves nothing, names both,
and lets the team decide.

**Why this priority**: Guessing here is worse than doing nothing. The two moves differ in what they do *in
addition* to changing the step — notifications, assignment, automation — and none of that is visible to the
mirror. A wrong guess fires side effects at real people, and it fires them silently.

**Independent Test**: Configure a workflow with two moves landing on the declared step, run the mirror, and
assert zero moves and one warning listing both candidates by name.

**Acceptance Scenarios**:

1. **Given** two available moves landing on the declared step, **When** the mirror runs, **Then** no move is
   performed, exactly one warning names the ticket, its role, the declared step, and every candidate move,
   **And** the content is still mirrored.
2. **Given** the same situation on a later run with the workflow unchanged, **When** the mirror runs again,
   **Then** the same single warning is raised and still no move is performed.

---

### User Story 5 - A move that demands a value stands down and names it (Priority: P1)

A team's workflow requires a resolution reason before a ticket may leave "In Review". The mirror does not
hold that reason, does not invent one, and does not reach for a value the team recorded for a different
purpose. It stands down and tells the reader exactly which value the workflow wants.

**Why this priority**: This is the enterprise workflow this project exists to serve, and the failure mode is
severe: a value guessed into a mandatory workflow field is wrong data written into a team's process, in a
place that is often audited and hard to correct.

**Independent Test**: Configure a gated move onto the declared step, run the mirror, and assert zero moves
plus one warning naming the demanded value.

**Acceptance Scenarios**:

1. **Given** exactly one available move landing on the declared step whose completion demands a value the
   mirror does not hold, **When** the mirror runs, **Then** no move is performed and exactly one warning
   names the ticket, the declared step, and the demanded value.
2. **Given** that the team recorded a default for a field of the same name for use when a ticket is created,
   **When** the mirror meets the gated move, **Then** that recorded value is not sent, and the outcome is
   the warning of scenario 1.

---

### User Story 6 - A step that cannot be reached from here is named, not forced (Priority: P2)

A team's workflow forbids going straight from "To Do" to "Done" — the ticket must pass through "In Review"
first. The mirror does not walk that path on the team's behalf. It reports that the declared step is not
reachable in one move from where the ticket stands, and names what is reachable, so the team can either move
it by hand or reconsider the mapping.

**Why this priority**: It is the one genuinely new question this feature raises, and refusing is the
conservative answer. Walking a multi-step path means performing moves the team never declared, each with its
own side effects, in an order the mirror inferred. That is a larger decision than this feature should make.

**Independent Test**: Configure a workflow where the declared step is reachable only through an intermediate
step, run the mirror, and assert zero moves plus one warning naming the current step, the declared step, and
the reachable set.

**Acceptance Scenarios**:

1. **Given** no available move landing on the declared step, **When** the mirror runs, **Then** no move is
   performed and exactly one warning names the ticket, its current step, the declared step, and the steps
   that are reachable from here.
2. **Given** the declared step names something this role's workflow does not contain at all, **When** the
   mirror runs, **Then** the same outcome follows and the warning tells the reader the declared step was not
   found among the reachable ones.

---

### User Story 7 - The dry run predicts the move exactly (Priority: P2)

An operator meeting an unfamiliar project asks the mirror what it would do. The answer names every ticket it
would move, of which role, from which step to which, and every move it would withhold and why — and the
board is untouched.

**Why this priority**: This is the first feature able to change a team's board, which makes the preview the
control an operator uses before letting it run for real. It is one priority below the safety stories because
those protect the board even when nobody previews.

**Independent Test**: Run the preview and the real run against the same state and assert the predicted set of
moves and warnings is identical to the performed set, and that the preview performed none.

**Acceptance Scenarios**:

1. **Given** any state covered by the stories above, **When** the operator previews the run, **Then** the
   predicted moves and warnings are identical to those of a real run against the same state, **And** the
   tracker records no move.

---

### Edge Cases

- **The ticket moves between the question and the answer.** A human changes the ticket's step after the
  mirror asked which moves were available and before it performs one. The tracker rejects the move; the
  mirror reports the rejection naming the ticket, and does not retry, does not re-ask, and does not attempt
  a different move — the next run reconsiders from the ticket's new position.
- **The move succeeds but lands somewhere unexpected.** A workflow rule attached to the move sends the
  ticket to a different step than the one advertised. The mirror does not notice, and does not check: the
  tracker confirms the move without saying where the ticket came to rest. The next run reads the ticket's
  real position, treats it as the truth, and reports the divergence like any other — so the situation
  surfaces one run later rather than immediately, at no cost to the run that caused it.
- **A sub-task's task is checked and the task role also maps the current event.** The task's completion
  governs that sub-task; the declared mapping does not also act on it in the same run.
- **The same step name appears in two roles' workflows and means different things.** Each role is resolved
  only against its own tickets' available moves, so the coincidence has no effect.
- **A role is declared in the mapping but not in the project's hierarchy** — a task mapping where sub-task
  mirroring is off, or a role the project does not use. The mapping is inert and the mirror says so once,
  rather than failing.
- **The declared step and the ticket's step differ only in spacing or letter case.** Treated as different
  steps: the mirror matches the declared name against the tracker's own spelling exactly, and a near miss is
  reported as unreachable rather than silently accepted.
- **Several mirrored tickets in one run each need a different move.** Each is decided on its own available
  moves; one ticket's ambiguity, gate, or rejection never suppresses another ticket's move, and a parent's
  failure never suppresses its stories'.
- **The lifecycle event carries no declared step for a role.** Nothing is asked of the tracker for that
  role and nothing is reported: a team that mapped two events out of six, on one role out of three, sees
  everything else stay silent.
- **The run is not a lifecycle event at all** — a direct invocation. No move is considered, exactly as today.
- **The same run both mirrors changed content and moves the ticket.** Both happen; neither suppresses the
  other, and a withheld move never withholds the content update.
- **The tracker cannot be asked which moves are available.** No move and no content write happen for that
  specification, and the run reports the failure with its documented exit code.

## Requirements *(mandatory)*

### Functional Requirements

**Finding and performing the move**

- **FR-001**: When a run carries a lifecycle event, the routed project declares a target step for that event
  on the ticket's hierarchy role, and the safety rules decide the ticket should advance, the mirror MUST ask
  the tracker which moves are available from that ticket's current step and MUST perform the one that lands
  on the declared step.
- **FR-002**: The mirror MUST identify a candidate move by the name of the step it lands on, compared
  against the declared step name. It MUST NOT identify it by the move's own name, by its position in the
  offered set, by any ordering of steps, or by any list of step names built into the product.
- **FR-003**: When exactly one available move lands on the declared step and completing it demands nothing
  of the mirror, the mirror MUST perform it and MUST record the ticket as moved in the run summary.
- **FR-004**: When two or more available moves land on the declared step, the mirror MUST perform none of
  them and MUST report exactly one warning naming the ticket, its role, the declared step, and every
  candidate. It MUST NOT prefer one candidate over another by any rule.
- **FR-005**: When exactly one available move lands on the declared step but completing it demands a value
  the mirror does not hold, the mirror MUST perform no move and MUST report exactly one warning naming the
  ticket, the declared step, and the demanded value.
- **FR-006**: A value the team recorded for use when a ticket is created MUST NOT be sent to satisfy a
  demand made by a move. The two are recorded for different purposes and are never substituted.
- **FR-007**: When no available move lands on the declared step, the mirror MUST perform no move and MUST
  report exactly one warning naming the ticket, its current step, the declared step, and the steps that are
  reachable from the current one. The mirror MUST NOT perform an intermediate move in order to reach the
  declared step.
- **FR-008**: When the ticket already stands at the declared step, the mirror MUST attempt no move, ask the
  tracker nothing about available moves, and raise no warning.
- **FR-009**: A run over unchanged state MUST perform zero moves, and this MUST hold on every re-run.

**A workflow per hierarchy role**

- **FR-010**: The lifecycle mapping MUST be declarable independently for each hierarchy role the project
  uses — specification, story, and task — each with its own lifecycle events and its own step names. A
  project MUST be able to declare a different workflow for each role, and MUST NOT be required to declare
  more than one.
- **FR-011**: A ticket MUST be evaluated only against the mapping declared for its own role. A step name
  declared for one role MUST NEVER participate in another role's decision, classification, or warning.
- **FR-012**: A role for which the project declares no mapping MUST never be moved, MUST raise no warning
  about not being moved, and MUST cost no additional question to the tracker.
- **FR-013**: A mapping written in the existing role-blind form MUST keep its current meaning: it is the
  story role's mapping. Upgrading MUST NOT cause a specification-tier parent or a sub-task to begin moving
  because of a mapping that was written before roles existed.
- **FR-014**: The safety rules — classification of the current step, the halted designation, the refusal to
  move a ticket backward without authorisation, the impediment marker, and open blocking links — MUST be
  evaluated for the specification-tier parent exactly as they are for a story, producing the same decisions
  and the same warning wording.
- **FR-015**: A mapping declared for the task role MUST take effect only where the team has enabled sub-task
  mirroring. Where the tier is disabled, the mapping MUST be inert and the mirror MUST say so once rather
  than failing the run.
- **FR-016**: Where the task tier is enabled, a task's own completion remains authoritative for its
  sub-task: the declared mapping MUST NOT move a sub-task whose task is checked. The mapping governs
  sub-tasks whose task is not yet complete.
- **FR-017**: Exactly one change is made to the configuration surface — the lifecycle mapping becomes
  declarable per role. No other key, flag, or option is introduced, and a project that declares nothing sees
  no change of any kind.

**Safety, reporting, and equivalence**

- **FR-018**: Every existing safety decision MUST keep its current meaning and its current wording: a
  withheld decision suppresses the move while content still reconciles; a halted ticket has every write
  suppressed; a backward move happens only under explicit operator authorisation; an impediment marker
  withholds the move and is itself neither set nor cleared; open blocking links produce a note rather than a
  block.
- **FR-019**: A withheld, ambiguous, gated, unreachable, or rejected move MUST NOT suppress the ticket's
  content update, and a content update MUST NOT be undone because a move did not happen. One ticket's
  outcome MUST NOT suppress another's, including between a parent and its stories.
- **FR-020**: When the mirror cannot reliably learn which moves are available, it MUST fail closed for the
  affected specification — no move and no content write for it — and exit with the documented code, matching
  how the sub-task tier already treats the same failure.
- **FR-021**: When a move the mirror performs is rejected by the tracker, the mirror MUST report the
  rejection naming the ticket and MUST NOT retry it, re-ask for the available moves, or attempt a different
  move within the same run.
- **FR-022**: When a run carries no lifecycle event, no role declares a step for the event, or the safety
  rules decided against advancing, the mirror MUST NOT ask the tracker about available moves at all. The
  machinery costs nothing when it is not used.
- **FR-023**: The preview mode MUST predict exactly the moves and warnings the real run against the same
  state produces, naming each ticket's role and both steps, and MUST perform no move.
- **FR-024**: The run summary MUST count tickets moved separately from tickets created and updated, in both
  the prose report and the machine-readable one.
- **FR-025**: Every warning introduced here MUST name the ticket, its role, what did not happen, and what a
  human can do about it, and MUST remain non-blocking when the mirror runs inside a lifecycle hook.
- **FR-026**: The configuration MUST stay readable by a tech lead without the documentation: each role's
  mapping is identified by the same role names the project already uses elsewhere in its configuration, and
  the file states what each section governs.
- **FR-027**: The repository's documentation MUST be corrected in the same change so that it describes only
  behaviour that ships. Specifically, the safety-model document's statement that a decision to advance is
  emitted, and the vision document's claim in its shipped section that the mirror advances the ticket on the
  board, MUST match what the code does once this feature lands.
- **FR-028**: Both ports MUST implement this identically and MUST be proven byte-equivalent by the shared
  conformance corpus, including the request sequence sent to the tracker.

### Key Entities

- **Hierarchy role**: One of the three tiers the project already maps — specification, story, task. It
  already governs which issue type a ticket is created as; this feature makes it govern which workflow the
  ticket advances along.
- **Declared lifecycle mapping**: The team's committable statement, for one role of one project, that a
  given lifecycle event corresponds to a given workflow step, written in the team's own vocabulary.
- **Lifecycle event**: The moment in the specification lifecycle a run belongs to — the specification was
  finished, the plan was finished, and so on. Supplied by the host; a run may carry none.
- **Declared step**: The workflow step a role's mapping names for the current event. The target this feature
  tries to reach for tickets of that role.
- **Available move**: One of the transitions the tracker offers out of a ticket's current step, for the
  current credentials, in this project's workflow. It advertises the step it lands on and whether completing
  it demands a value. Discovered per ticket, never assumed.
- **Gated move**: An available move that demands a value before it completes.
- **Reachable set**: The steps the available moves land on. Used to tell a reader why a declared step could
  not be reached.
- **Safety decision**: The existing conclusion — advance, withhold, or halt — that the mirror already
  reaches for a recognised ticket. This feature consumes it, extends where it is evaluated, and never
  changes what it means.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Directly served, and no new exception. The specification on disk is what says where each ticket belongs; the mirror acts on that only through the safety rules, which already refuse to regress a ticket without a named warning (FR-018). Nothing is deleted. Only tickets already recognised as this specification's are moved. |
| II | Zero-Churn Idempotency | FR-008, FR-009 and FR-012 state it: a ticket already at its role's declared step is not asked about and not moved, and an undeclared role is not asked about at all, so a second run over unchanged state performs zero moves. The constitution's own count of write kinds names "transitioned" — this feature is the first to make that count non-zero, and the live double-run assertion covers it. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-020 fails closed for the affected specification when the available moves cannot be read, matching the sub-task tier's existing treatment of the same read. FR-021 refuses to improvise after a rejected move. FR-025 keeps every warning non-blocking inside a hook. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. No credential is read, written, recorded, or reported; the available-moves question uses the same authenticated conduit as every other request. |
| V | Separation of Team Config / Local Binding / Secrets | The one configuration change (FR-010, FR-017) lands entirely in the committable team layer, which is where a statement about a team's workflow belongs and where the mapping already lives. Nothing is added to the local binding or the secrets layer, and no value in the new shape is credential-shaped: role names and step names are public within the organisation. |
| VI | macOS / Linux / Windows Portability | FR-028 requires both ports and byte equivalence proven by the shared corpus, including the request sequence — the sequence is the part a divergence would show up in first, since this feature adds a read and a write per moved ticket across three roles. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | The principle this feature exists to honour, and the reason the mapping becomes per-role: assuming one workflow serves an Epic, a Story and a Sub-task is exactly the hard-coded assumption the principle forbids, and it is the assumption the current shape makes. FR-002 states the rule in its strongest form — the move is found by the declared step's name against what the project offers, with no built-in table of step names, no assumed ordering, and no default workflow. FR-004, FR-005 and FR-007 are the three ways a real enterprise workflow differs from the default, each answered by reporting rather than assuming. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | The engine keeps deciding *whether* to advance; the sink alone knows what a move is and how to find one. The role is already a neutral concept in the interchange document, so routing a decision by role adds no tracker vocabulary to the engine; the available moves and the chosen move reach the decision as opaque data, exactly as the recognised ticket's current position does today. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. A move sends no composed text — it names a move and, where the workflow demands a value, this feature declines to supply one (FR-005, FR-006), so no new surface is written and none needs scanning. |
| X | Self-Healing Automatic Mirror | Directly served. A board that drifted behind the specification is brought back to each tier's declared step on the next run without anyone intervening — which is what a self-healing mirror of the lifecycle means. Hook registration and health are untouched. |
| XI | Universal Dry-Run and Auditability | FR-023 requires the preview to predict the moves and withholdings exactly, by role and by step, and perform none; FR-024 puts moves in the summary as their own count. No destructive operation is added — a move changes a ticket's position and destroys nothing. |
| XII | Quality and Catalog Publication | A change to shipped behaviour, carrying a CHANGELOG entry, gated by the full suite, the conformance corpus, and the linters on all three operating systems, and dogfooded against a real instance before release — which for this feature means watching a real board advance on more than one tier. FR-027 corrects the documentation in the same change. |
| XIII | TDD With a Minimum 80% Coverage | Every story states an independent test. The first test written is the one that fails today: a declared mapping, a recognised ticket one step behind, a run, and an assertion that a move was performed. The test that currently pins "zero transition requests in every scenario" is the honest record of the gap; it is rewritten by this feature, not deleted quietly, and the corpus keeps a scenario asserting zero moves where no mapping is declared. Drift decision is a named critical path and targets near-total coverage; the per-role routing is covered by a fixture declaring a different workflow on each role. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Nothing is invented. The mapping, the safety decision, the warning channel, the run summary, the available-moves question and the three hierarchy roles all exist; the sub-task tier already settled the four resolution outcomes. This feature generalises one selection rule — from the kind of step to the declared name of the step — keys an existing mapping by an existing concept, and connects a decision that already exists to a write that already exists. The per-role shape is not speculative genericity: it is the project's own hierarchy, and FR-010 requires no team to declare more than the one role it uses. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | FR-017 admits exactly one configuration change and forbids any other key or flag. Walking a multi-step path, proposing the mapping at configuration time, per-role halted designations, reconciling a position a human chose back into the specification, and moving anything the safety rules do not evaluate are all named out of scope and are not built. |
| XVI | Human Readable — Readable by a Human Above All | FR-026 requires the configuration to name each role's workflow in the vocabulary the file already uses, so a tech lead reads three named sections and understands which board each governs. Every outcome that is not a move is a sentence naming the ticket, its role, the step that was wanted, and what stood in the way — the candidate moves, the demanded value, or what is reachable instead (FR-004, FR-005, FR-007, FR-025). FR-027 makes the documentation itself honest. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a project declaring a step for a lifecycle event on a role, 100% of that role's eligible
  tickets — recognised, not halted, not flagged, one ungated move away — stand at the declared step after
  the run.
- **SC-002**: In a project declaring different workflows for two roles, 100% of each role's tickets land on
  their own role's declared step, and 0 tickets are evaluated against another role's step name.
- **SC-003**: In a project declaring no mapping, 0 tickets are moved and 0 additional questions are asked of
  the tracker compared with the same run today; the same holds per role for every role left undeclared.
- **SC-004**: A project upgrading with a mapping written before roles existed sees its stories advance and
  0 parents and 0 sub-tasks moved as a result.
- **SC-005**: The run following any run performs 0 moves when nothing on disk or on the board changed.
- **SC-006**: In each of the three workflows that cannot be resolved — several candidates, a gated move, an
  unreachable step — 0 tickets are moved and exactly 1 warning is raised per affected ticket, naming the
  ticket, its role, and the declared step.
- **SC-007**: The set of moves and warnings predicted by a preview matches the set performed by a real run
  against the same state, 100% of the time.
- **SC-008**: Every scenario in the existing safety corpus produces the same decision and the same warning
  wording as before, with the single documented addition that an advance decision now moves the ticket.
- **SC-009**: Both ports produce byte-identical output and an identical request sequence for every scenario
  introduced here, proven by the shared conformance corpus.
- **SC-010**: A reader comparing the safety-model and vision documents against the shipped behaviour finds
  no claim the code does not satisfy.
- **SC-011**: A ticket for which a move is due costs at most one additional question, and one additional
  write only when that question resolves to a single ungated candidate; a ticket for which no move is due —
  no lifecycle event, no declared step for its role, already standing at the declared step, or the safety
  rules decided against advancing — costs nothing at all.

## Assumptions

- **A task's completion outranks the declared mapping on its own sub-task.** Two authorities can act on a
  sub-task once the task role is mappable: the checked box on disk, and the lifecycle event. FR-016 gives
  the checkbox precedence because it is the more specific statement — it is about *that* task — while the
  mapping is about every ticket of the role. The mapping therefore governs sub-tasks still in flight. This
  is the one interaction of the feature that was decided rather than inherited, and it is the first thing
  worth revisiting if it reads wrong in practice.
- **Refusing a multi-step path is the right answer for this version.** The alternative — inferring an order
  and performing moves the team never declared, each with side effects the mirror cannot see — is a larger
  decision than this feature should make. FR-007 names what could not be reached so a team can move the
  ticket by hand or reconsider the mapping. Revisiting this is listed out of scope, not ruled out.
- **The four resolution outcomes settled at the sub-task tier are the right ones here.** They were reasoned
  through, tested, and shipped for the same question in the same product; adopting a second, different set
  of answers for the same shape of problem would be the harder thing to justify.
- **The halted designation stays project-wide rather than per role.** A step name only matches tickets that
  actually stand at it, so a single list covering all three workflows behaves correctly; splitting it per
  role would add a configuration surface no requirement here needs.
- **A step name is compared exactly as the team wrote it and as the tracker spells it.** A near miss is
  reported as unreachable rather than accepted, because accepting it would mean guessing which step a team
  meant — precisely what this feature must not do.
- **The safety decisions are correct today.** They were built and tested against real recognised state; this
  feature consumes them unchanged, extends the set of tickets they are evaluated for, and protects them with
  regression scenarios rather than revising them.
- **Both ports carry the gap identically**, since they share the design, and both are closed in the same
  change.
- **The existing warning channel and summary counts are sufficient.** The summary already names a
  transitioned count that has always been zero; this feature makes it meaningful rather than adding a
  reporting surface.

## Out of Scope

- **Walking a multi-step path to reach a declared step.** Refused and named instead (FR-007). Revisiting it
  would be its own specification, because performing undeclared intermediate moves is a different promise
  from performing the one a team declared.
- **Proposing the mapping at configuration time.** Making the configuration ceremony discover each role's
  steps and offer a mapping is a separate item in the vision document; it is worth doing *after* the mapping
  has an effect, never before — and it becomes more valuable, not less, now that there are three of them.
- **A per-role halted designation**, and any other per-role split of configuration this feature does not
  require.
- **Choosing between ambiguous candidate moves by any rule** — a preference order, a naming convention, or
  an operator-supplied tie-break. Reported, not resolved.
- **Supplying a value a workflow demands before a move completes**, from a recorded default or any other
  source, and any new configuration for doing so.
- **Changing how a task's completion moves its sub-task.** That model is shipped, is decided on a different
  basis, and is left exactly as it is; this feature only declares which authority wins where both could act.
- **Reading a position a human chose back into the specification on disk.** That is a write to the
  repository and belongs to the controlled exceptions, not here.
- **Setting, clearing, or reacting to the impediment marker beyond the existing withholding**, and creating,
  changing, or removing any link.
- **Verifying where a move actually landed.** The tracker confirms a successful move without returning a
  position, so checking that the ticket reached the declared step would cost a second read on every moved
  ticket — paying today for information the next run reads for nothing and reports as ordinary drift. The
  task tier has never verified its own moves either; adopting a different answer here for the same question
  would be the harder thing to justify. If real workflows turn out to divert moves often enough to matter,
  that deserves its own specification with its own request budget.
- **Repairing boards already behind because the mapping never acted.** The next run advances what it can and
  names what it cannot; no migration or catch-up mode is built.
