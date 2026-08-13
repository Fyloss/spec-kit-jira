# Feature Specification: Each Tier Advances Along Its Own Declared Workflow

**Feature Branch**: `feat/advance-board-position`

**Created**: 2026-08-10

**Updated**: 2026-08-13 — revised against 021, 022 and 024, which shipped on `main` after this
specification was first written. See *What shipped underneath this specification*.

**Status**: Draft

**Input**: User description: "Advance a mirrored ticket on the board by actually issuing the Jira transition its declared phase_status_map calls for. Today phase_status_map is schema-validated, resolved per project, and feeds drift classification and warnings, but no ticket at the specification/story tier is ever moved. Scope: resolve the target status NAME declared in phase_status_map into a transition id available from the ticket's CURRENT status, and emit the transition, on a workflow the bridge does not know in advance. Reuse the resolution shapes 012 already established at the task tier. The genuinely new question is a target reachable only through intermediate statuses (multi-hop) — refusing while naming the unreachable target is a defensible v1. Everything the drift engine already decides must keep its current meaning; this feature only connects the decision to the write. Documentation correction is in scope. Both ports, byte-equivalent under the conformance corpus."

**Clarified scope**: The declared mapping is **per hierarchy role**, not per project. The specification tier
(Epic, Feature, or whatever the project calls it) has its own workflow with its own steps mapped to the
lifecycle events; the story tier has its own; and the task tier has its own when the team mirrors its tasks
as sub-tasks. A team running three different workflows on its three roles — which is the ordinary
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
records it: *"zero transition requests in scenario — this release evaluates the rules but never moves a
ticket's status"*.

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

**The third half of the gap: the run never learns which event fired.** The mapping is keyed by lifecycle
event, and the bridge is told which event dispatched it by a single value the caller supplies. Nothing in
the shipped extension manifest, and nothing in the agent-facing reconcile procedure, ever supplies it. On
the real path that value is therefore always absent, the declared step for the run is always empty, and the
entire drift evaluation is inert — not merely reading-without-writing, but never reached at all. Every
scenario that exercises it does so through a test-only override. The read half of this machinery is
demonstrated, not delivered, and no amount of connecting a decision to a write fixes that on its own.

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

## What shipped underneath this specification

Three features landed on `main` between this specification's first draft and this revision. Two of them
were performance work whose guarantees this feature can trivially undo; one of them changed the shape of
the tier this feature was going to key a mapping to. None of them is optional context: each turns something
this specification treated as an implementation detail into a stated requirement.

**021 taught the run to skip itself, and it skips exactly the events this feature needs.** A reconcile
whose local inputs hash identically to the last fully successful run now exits in under a second having
issued zero requests. The hashed inputs are the specification, the task list, and the configuration files —
`plan.md` is not among them. So `/speckit.plan` fires its event, changes nothing the recorded evidence
covers, and the run short-circuits before it can consider a move. `/speckit.analyze` writes nothing at all
and short-circuits for the same reason. The two events most likely to carry a declared step are the two
this feature would never reach. And the recorded evidence carries no notion of *which* event it was
recorded under, so even with `plan.md` hashed, two consecutive events over byte-identical files would
collapse into one advance.

The same omission already costs a consumer something today, in a way that has nothing to do with moving
tickets: the implementation plan is read on every run and written onto the parent ticket, so a plan summary
produced by `/speckit.plan` does not reach Jira until some other file happens to change. This feature
cannot promise "finishing the plan advances the board" without closing that, and closing it is the same
change seen from the content side.

**021 and 024 made the cost of a run a stated guarantee, not a preference.** 021 replaced one read per
recorded ticket with a bounded bulk read and committed to a request count bounded by the writes performed
plus a small constant. 024 replaced per-item process spawns with batched ones and committed to a spawn
count that does not change when the number of stories and tasks is doubled, measured against a baseline of
20 243 process creations for a 61-item specification. The obvious way to build this feature — ask the
tracker, per ticket, which moves are available, then resolve the answer per ticket with an external tool —
restores both shapes at once. On the reference profile that is one extra round-trip and one extra process
per moved ticket, against a budget that was bought at the cost of two whole features.

**022 split the task tier in two.** A project now mirrors its tasks either as sub-tasks or as a checklist
inside the story's description, chosen by one line of configuration. In checklist mode there is no task
ticket at all — nothing to move, and no workflow to declare a step against. A task-role mapping is inert
there and must say so, rather than warning once per entry that a step could not be reached. The switch also
leaves behind sub-tasks the mirror has deliberately abandoned, still named by markers in the task list;
those must never be moved by anything, including this feature.

**024 fixed the instrument this feature will be measured with.** The per-phase timing report attributes
every request to the phase that issued it, and the per-phase counts are asserted to sum to the run's total.
A request this feature issues outside that accounting silently breaks an assertion 024 shipped.

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

### User Story 2 - The event that fired actually reaches the mirror (Priority: P1)

A team finishes its plan. The host fires the plan event, the mirror runs, and the mirror knows it is running
for the plan event — so the step that event declares is the step it aims for. A developer who invokes the
mirror by hand, with no event at all, sees exactly today's behaviour.

**Why this priority**: The mapping is keyed by event. A run that does not know its event has no declared
step, evaluates no drift, and can move nothing, however completely the rest of this feature is built. It is
listed second only because User Story 1 defines what the event is *for*; in build order it comes first, and
it is the requirement that turns the existing read half from demonstrated into delivered.

**Independent Test**: Fire each of the six after-events through the shipped dispatch, and assert the mirror
resolved the declared step belonging to that event and no other; invoke the mirror directly and assert it
resolved none.

**Acceptance Scenarios**:

1. **Given** a project declaring a different step for the specify event and the plan event, **When** each
   event fires in turn through the shipped dispatch, **Then** each run aims at its own event's step.
2. **Given** a direct invocation carrying no event, **When** the mirror runs, **Then** no step is declared
   for the run, no drift rule is evaluated, no move is considered, and the output is byte-identical to the
   same invocation before this feature.
3. **Given** an event the operator disabled, **When** the host fires it, **Then** the mirror exits silently
   exactly as it does today, having read no configuration and considered no move.

---

### User Story 3 - A second event over unchanged files still advances the board (Priority: P1)

A team runs `/speckit.specify` and the ticket lands at "To Do". They then run `/speckit.plan`, which writes
only the implementation plan. The ticket moves to "In Progress" — the run does not decide that nothing has
changed and skip itself.

**Why this priority**: Without it, User Story 1's headline example is the one case that provably does not
work. The advance a team most wants — the board following the lifecycle — is precisely the advance a
short-circuit swallows, and it swallows it silently, on a green run.

**Independent Test**: Reconcile under one event, then reconcile under a second event with every hashed
input byte-identical, and assert the second run reached the board and moved the ticket to the second
event's step.

**Acceptance Scenarios**:

1. **Given** a fully mirrored specification and a run recorded under the specify event, **When** the plan
   event fires with the specification and task list unchanged, **Then** the run is not short-circuited, the
   ticket stands at the plan event's declared step, and the plan summary reaches the parent.
2. **Given** the same specification, **When** the same event fires twice with nothing changed in between,
   **Then** the second run performs zero moves and zero writes.
3. **Given** a run under an event for which no role declares a step, **When** every hashed input is
   unchanged, **Then** the run short-circuits exactly as it does today.
4. **Given** any recorded evidence that cannot be read, is not valid, or was written by another version,
   **When** the mirror runs, **Then** it reconciles fully — every doubt still fails open.

---

### User Story 4 - Each tier follows its own workflow (Priority: P1)

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
3. **Given** a project that mirrors its tasks as sub-tasks and declares a mapping for the task role, **When**
   the mirror runs under a mapped event, **Then** sub-tasks whose task is unchecked advance along the task
   role's declared steps.
4. **Given** a project that mirrors its tasks as a checklist, **When** it declares a mapping for the task
   role, **Then** no ticket is created or moved for that role and the mirror reports once that the mapping
   has no effect in this mirroring mode.
5. **Given** a project whose mapping was written before roles existed — a single mapping with no role named
   — **When** the mirror runs after upgrading, **Then** it is honoured as the story role's mapping exactly
   as it is classified today, and neither the parent nor any sub-task begins moving because of it.

---

### User Story 5 - Every existing protection keeps its meaning (Priority: P1)

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

### User Story 6 - An ambiguous workflow is reported, never guessed (Priority: P1)

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

### User Story 7 - A move that demands a value stands down and names it (Priority: P1)

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

### User Story 8 - A step that cannot be reached from here is named, not forced (Priority: P2)

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

### User Story 9 - The board advances without the run getting slower (Priority: P2)

A team mirroring a large specification — one parent, sixty stories — declares a mapping and sees the whole
board advance in the run they already have. The run does not become a run per ticket again.

**Why this priority**: The two features that shipped immediately before this one exist to remove exactly the
per-ticket request and the per-ticket process spawn. Reintroducing either would spend a measured, hard-won
budget on a feature that does not need it, and the regression would be invisible on a small specification —
which is exactly how it would reach a consumer.

**Independent Test**: Mirror a specification whose every ticket is due a move; count the requests and the
external processes; double the number of stories and assert the round-trip count and the process count do
not double with it.

**Acceptance Scenarios**:

1. **Given** a specification of sixty stories all due a move, **When** the mirror runs, **Then** the total
   requests are the moves performed plus a small constant, and the round-trips spent learning which moves
   are available do not grow one-for-one with the number of tickets.
2. **Given** the same specification with the story count doubled, **When** the mirror runs, **Then** the
   number of external processes the run creates is unchanged.
3. **Given** any run with the timing mode on, **When** the mirror moves tickets, **Then** every request it
   issued is attributed to the phase that issued it, and the per-phase counts sum to the run's total.
4. **Given** a run that reaches the pipeline in which no ticket is due a move, **When** the mirror runs,
   **Then** it costs exactly what the same run costs today, on every counted quantity. The one exception is
   the first run under an event that changes no hashed input, which performs a full reconcile instead of
   short-circuiting — the narrowing recorded in the plan's Complexity Tracking.

---

### User Story 10 - The dry run predicts the move exactly (Priority: P2)

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
2. **Given** a specification whose recorded evidence matches the current files, **When** the operator
   previews the run, **Then** the preview still computes and reports the moves in full, and the evidence is
   neither consumed nor rewritten.

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
- **A sub-task the mirror abandoned when the project switched to checklist mirroring.** Its marker is still
  in the task list and the ticket still exists in the tracker. It is never moved, by this feature or any
  other — an abandoned ticket is left exactly as it was, which is what abandoning it means.
- **The same step name appears in two roles' workflows and means different things.** Each role is resolved
  only against its own tickets' available moves, so the coincidence has no effect.
- **A role is declared in the mapping but not in the project's hierarchy** — a task mapping in a project
  that mirrors tasks as a checklist, or a role the project does not use. The mapping is inert and the mirror
  says so once, rather than failing or warning per ticket.
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
- **The bulk read of available moves fails while the individual reads would succeed.** The run falls back to
  the cost it would have had without the bulk read and produces the identical outcome; a transport failure
  of an optimisation is never a classification.
- **A full reconcile is forced while an event is in flight.** Forcing a run never suppresses a move the
  event declares, and never records evidence that would suppress the next event's move.
- **An event fires against a specification whose every ticket already stands at the declared step.** The run
  reaches the board, asks nothing about available moves, moves nothing, warns about nothing, and records its
  evidence exactly as a fully successful run does.

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
- **FR-009**: A run over unchanged state under an event already honoured MUST perform zero moves, and this
  MUST hold on every re-run.

**The event that fired**

- **FR-010**: The lifecycle event that dispatched a run MUST reach the mirror on every one of the declared
  after-events, carried by the shipped dispatch itself rather than by a value only a test supplies. The
  agent-facing procedure MUST state how it is carried, normatively, in the same terms it states the target
  file.
- **FR-011**: A run invoked with no lifecycle event MUST behave exactly as it does today: no declared step,
  no drift rule evaluated, no move considered, and output byte-identical to the same invocation before this
  feature.
- **FR-012**: An event the operator disabled MUST continue to exit silently before any configuration read
  and any network call, unchanged by this feature.

**Reaching the board on the event that matters**

- **FR-013**: A run dispatched for a lifecycle event MUST NOT be skipped by the recorded evidence of a
  previous run when that evidence was recorded under a different event. Two consecutive events over
  byte-identical local files MUST both reach the board.
- **FR-014**: The implementation plan MUST participate in the recorded evidence of a completed run. Its
  content is already read on every run and written onto the parent ticket, so a change to it that reaches
  no other file MUST invalidate the evidence and produce a full reconcile.
- **FR-015**: Every doubt MUST continue to fail open to a full reconcile: unreadable, invalid, or
  foreign-version evidence, and any evidence whose shape this feature changes, MUST produce a full run
  rather than a skip. No condition introduced here may cause a skip.
- **FR-016**: Knowing the event MUST NOT by itself cost a consumer the speed 021 delivered. A repeat of the
  **same** event over unchanged local inputs MUST short-circuit exactly as it does today. Because the
  recorded evidence is composed before the configuration is read, the run cannot know whether any role
  declares a step for the event, so a **differing** event over unchanged inputs MUST perform one full
  reconcile — bounded, by the enumeration in the run-state contract, to `after_analyze` alone, once per
  input state. That narrowing and its two rejected alternatives are recorded in the plan's Complexity
  Tracking.

**A workflow per hierarchy role**

- **FR-017**: The lifecycle mapping MUST be declarable independently for each hierarchy role the project
  uses — specification, story, and task — each with its own lifecycle events and its own step names. A
  project MUST be able to declare a different workflow for each role, and MUST NOT be required to declare
  more than one.
- **FR-018**: A ticket MUST be evaluated only against the mapping declared for its own role. A step name
  declared for one role MUST NEVER participate in another role's decision, classification, or warning.
- **FR-019**: A role for which the project declares no mapping MUST never be moved, MUST raise no warning
  about not being moved, and MUST cost no additional question to the tracker.
- **FR-020**: A mapping written in the existing role-blind form MUST keep its current meaning: it is the
  story role's mapping. Upgrading MUST NOT cause a specification-tier parent or a sub-task to begin moving
  because of a mapping that was written before roles existed.
- **FR-021**: The safety rules — classification of the current step, the halted designation, the refusal to
  move a ticket backward without authorisation, the impediment marker, and open blocking links — MUST be
  evaluated for the specification-tier parent exactly as they are for a story, producing the same decisions
  and the same warning wording.
- **FR-022**: A mapping declared for the task role MUST take effect only in a project whose tasks are
  mirrored as sub-tasks. Where tasks are mirrored as a checklist, or where no task tier exists at all, the
  mapping MUST be inert, MUST create and move nothing, and the mirror MUST say so once per run rather than
  once per entry and rather than failing.
- **FR-023**: A sub-task the mirror abandoned when its project switched to checklist mirroring MUST never be
  moved, whatever its marker still records.
- **FR-024**: Where tasks are mirrored as sub-tasks, a task's own completion remains authoritative for its
  sub-task: the declared mapping MUST NOT move a sub-task whose task is checked. The mapping governs
  sub-tasks whose task is not yet complete.
- **FR-025**: Exactly one change is made to the team-facing configuration surface — the lifecycle mapping
  becomes declarable per role. No other key, flag, or option is introduced, and a project that declares
  nothing sees no change of any kind.

**What the move is allowed to cost**

- **FR-026**: The mirror MUST NOT ask the tracker which moves are available for a ticket that is not due a
  move — no lifecycle event, no declared step for the ticket's role, already standing at the declared step,
  or a safety decision against advancing. The machinery costs nothing when it is not used.
- **FR-027**: For the tickets that are due a move, the number of round-trips the mirror spends learning
  which moves are available MUST NOT grow one-for-one with the number of such tickets. A run's total
  requests MUST remain bounded by the writes it performs plus a small constant for reads, which is the
  guarantee 021 shipped.
- **FR-028**: Resolving and performing moves MUST NOT add an external process per ticket, per candidate
  move, or per declared role. The number of external processes a run creates MUST NOT change when the number
  of tickets due a move is doubled.
- **FR-029**: The per-role mapping MUST be read from the configuration the run has already parsed. No
  configuration source may be opened or parsed an additional time because a second or third role declares a
  workflow.
- **FR-030**: Every request this feature issues MUST be attributed, in the per-phase timing report, to the
  phase that issued it, and the per-phase request counts MUST continue to sum exactly to the requests the
  run issued.
- **FR-031**: A failure of any bulk mechanism used to learn available moves MUST fall back to the outcome
  and the cost the mirror would have had without it, and MUST NOT itself become a classification, a warning
  about the ticket, or a fail-closed read.

**Safety, reporting, and equivalence**

- **FR-032**: Every existing safety decision MUST keep its current meaning and its current wording: a
  withheld decision suppresses the move while content still reconciles; a halted ticket has every write
  suppressed; a backward move happens only under explicit operator authorisation; an impediment marker
  withholds the move and is itself neither set nor cleared; open blocking links produce a note rather than a
  block.
- **FR-033**: A withheld, ambiguous, gated, unreachable, or rejected move MUST NOT suppress the ticket's
  content update, and a content update MUST NOT be undone because a move did not happen. One ticket's
  outcome MUST NOT suppress another's, including between a parent and its stories.
- **FR-034**: When the mirror cannot reliably learn which moves are available, it MUST fail closed for the
  affected specification — no move and no content write for it — and exit with the documented code, matching
  how the sub-task tier already treats the same failure.
- **FR-035**: When a move the mirror performs is rejected by the tracker, the mirror MUST report the
  rejection naming the ticket and MUST NOT retry it, re-ask for the available moves, or attempt a different
  move within the same run.
- **FR-036**: The preview mode MUST predict exactly the moves and warnings the real run against the same
  state produces, naming each ticket's role and both steps, MUST perform no move, and MUST neither consume
  nor rewrite the recorded evidence of a previous run.
- **FR-037**: The run summary MUST count tickets moved at the specification and story tiers as their own
  named quantity, alongside and never folded into created and updated, in both the prose report and the
  machine-readable one. The task tier's existing moved count MUST keep its current name, place, and meaning.
- **FR-038**: Every warning introduced here MUST name the ticket, its role, what did not happen, and what a
  human can do about it, and MUST remain non-blocking when the mirror runs inside a lifecycle hook.
- **FR-039**: The configuration MUST stay readable by a tech lead without the documentation: each role's
  mapping is identified by the same role names the project already uses elsewhere in its configuration, and
  the file states what each section governs.
- **FR-040**: The repository's documentation MUST describe only behaviour that ships, in the same change.
  Specifically: the safety-model document's statement that a decision to advance emits a move; the vision
  document's account of board advancement; the reconcile-flow document's pipeline, which must show where a
  move is decided and issued and must state how the event reaches the run; and the agent-facing reconcile
  procedure, which must state how the event is carried and must list every flag the mirror accepts.
- **FR-041**: Both ports MUST implement this identically and MUST be proven byte-equivalent by the shared
  conformance corpus, including the request sequence sent to the tracker.

### Key Entities

- **Hierarchy role**: One of the three tiers the project already maps — specification, story, task. It
  already governs which issue type a ticket is created as; this feature makes it govern which workflow the
  ticket advances along.
- **Declared lifecycle mapping**: The team's committable statement, for one role of one project, that a
  given lifecycle event corresponds to a given workflow step, written in the team's own vocabulary.
- **Lifecycle event**: The moment in the specification lifecycle a run belongs to — the specification was
  finished, the plan was finished, and so on. Supplied by the host through the dispatch; a run may carry
  none.
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
- **Recorded run evidence**: The record that one specific set of local inputs was mirrored to completion,
  which lets an unchanged run skip itself. This feature adds the lifecycle event and the implementation plan
  to what it attests to, so that the record can never assert that an event was honoured when it was not.
- **Task mirroring mode**: The project's choice between mirroring its tasks as sub-tasks and mirroring them
  as a checklist inside the story. It decides whether a task-role mapping has anything to act on.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Directly served, and no new exception. The specification on disk is what says where each ticket belongs; the mirror acts on that only through the safety rules, which already refuse to regress a ticket without a named warning (FR-032). Nothing is deleted. Only tickets already recognised as this specification's are moved. FR-014 adds the implementation plan to what the run's own evidence attests to — a read of a file already read, not a new write to the tree. |
| II | Zero-Churn Idempotency | FR-008, FR-009 and FR-019 state it: a ticket already at its role's declared step is not asked about and not moved, and an undeclared role is not asked about at all, so a second run over unchanged state under the same event performs zero moves. FR-013 sharpens what "unchanged state" means rather than weakening it — a *different* event is a different state, and treating it as the same one is what makes the current skip wrong. The constitution's own count of write kinds names "transitioned"; this feature is the first to make that count non-zero at the story and specification tiers, and the live double-run assertion covers it. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-034 fails closed for the affected specification when the available moves cannot be read, matching the sub-task tier's existing treatment of the same read. FR-035 refuses to improvise after a rejected move. FR-031 keeps the *optimisation* fail-open — a bulk read that fails costs requests, never a classification — which is the same asymmetry 021's own prefetch contract holds. FR-038 keeps every warning non-blocking inside a hook. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. No credential is read, written, recorded, or reported; the available-moves question uses the same authenticated conduit as every other request, and the credential is still resolved once per process. Nothing this feature adds to the recorded run evidence is credential-shaped: an event name is a lifecycle constant. |
| V | Separation of Team Config / Local Binding / Secrets | The one team-facing configuration change (FR-017, FR-025) lands entirely in the committable team layer, which is where a statement about a team's workflow belongs and where the mapping already lives. Nothing is added to the local binding or the secrets layer, and no value in the new shape is credential-shaped: role names and step names are public within the organisation. |
| VI | macOS / Linux / Windows Portability | FR-041 requires both ports and byte equivalence proven by the shared corpus, including the request sequence — the sequence is the part a divergence would show up in first, since this feature adds a read and a write per moved ticket across three roles. The batching FR-027 and FR-028 require is the shape most likely to diverge between a port that batches with an external tool and one that does its structured work in-process; the corpus assertion is on the recorded call sequence, which is port-independent. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | The principle this feature exists to honour, and the reason the mapping becomes per-role: assuming one workflow serves an Epic, a Story and a Sub-task is exactly the hard-coded assumption the principle forbids, and it is the assumption the current shape makes. FR-002 states the rule in its strongest form — the move is found by the declared step's name against what the project offers, with no built-in table of step names, no assumed ordering, and no default workflow. FR-004, FR-005 and FR-007 are the three ways a real enterprise workflow differs from the default, each answered by reporting rather than assuming. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | The engine keeps deciding *whether* to advance; the sink alone knows what a move is and how to find one. The role is already a neutral concept in the interchange document, so routing a decision by role adds no tracker vocabulary to the engine; the available moves and the chosen move reach the decision as opaque data, exactly as the recognised ticket's current position does today. The lifecycle event FR-010 conveys is a spec-kit concept, not a tracker one, and stays on the engine side of the seam. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. A move sends no composed text — it names a move and, where the workflow demands a value, this feature declines to supply one (FR-005, FR-006), so no new surface is written and none needs scanning. |
| X | Self-Healing Automatic Mirror | Directly served, and partly restored. A board that drifted behind the specification is brought back to each tier's declared step on the next run without anyone intervening. FR-013 and FR-014 are what make "the next run" mean the next lifecycle event rather than the next time a file happens to change — without them the automatic mirror is automatic only for the events that edit the specification. |
| XI | Universal Dry-Run and Auditability | FR-036 requires the preview to predict the moves and withholdings exactly, by role and by step, perform none, and leave the recorded evidence untouched — the last clause preserves the property that a preview never changes what the following real run does. FR-037 puts moves in the summary as their own count. No destructive operation is added — a move changes a ticket's position and destroys nothing. |
| XII | Quality and Catalog Publication | A change to shipped behaviour, carrying a CHANGELOG entry, gated by the full suite, the conformance corpus, and the linters on all three operating systems, and dogfooded against a real instance before release — which for this feature means watching a real board advance on more than one tier, on a second lifecycle event that changed no file. FR-040 corrects the documentation in the same change. |
| XIII | TDD With a Minimum 80% Coverage | Every story states an independent test. The first test written is the one that fails today: a declared mapping, a recognised ticket one step behind, a run under a real dispatched event, and an assertion that a move was performed. The test that currently pins "zero transition requests in scenario" is the honest record of the gap; it is rewritten by this feature, not deleted quietly, and the corpus keeps a scenario asserting zero moves where no mapping is declared. Two of the new requirements are counting requirements — FR-027 and FR-028 — and are asserted with the counting stand-ins 024 established, in runs separate from any timing run. Drift decision is a named critical path and targets near-total coverage; the per-role routing is covered by a fixture declaring a different workflow on each role. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Nothing is invented. The mapping, the safety decision, the warning channel, the run summary, the available-moves question, the bulk read, the recorded run evidence and the three hierarchy roles all exist; the sub-task tier already settled the four resolution outcomes. This feature generalises one selection rule — from the kind of step to the declared name of the step — keys an existing mapping by an existing concept, adds one field to an existing record, and connects a decision that already exists to a write that already exists. The per-role shape is not speculative genericity: it is the project's own hierarchy, and FR-017 requires no team to declare more than the one role it uses. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | FR-025 admits exactly one team-facing configuration change and forbids any other key or flag. FR-013 and FR-014 are not scope growth: without them FR-001's headline promise is unreachable for the plan event, and a specification may not require an outcome it also makes impossible. Walking a multi-step path, proposing the mapping at configuration time, per-role halted designations, reconciling a position a human chose back into the specification, an expiring run record, and moving anything the safety rules do not evaluate are all named out of scope and are not built. |
| XVI | Human Readable — Readable by a Human Above All | FR-039 requires the configuration to name each role's workflow in the vocabulary the file already uses, so a tech lead reads three named sections and understands which board each governs. Every outcome that is not a move is a sentence naming the ticket, its role, the step that was wanted, and what stood in the way — the candidate moves, the demanded value, or what is reachable instead (FR-004, FR-005, FR-007, FR-038). FR-022's inert-mapping notice is one sentence per run, not one per entry, because a reader learns nothing from the sixtieth copy. FR-040 makes the documentation itself honest. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

**The board advances**

- **SC-001**: In a project declaring a step for a lifecycle event on a role, 100% of that role's eligible
  tickets — recognised, not halted, not flagged, one ungated move away — stand at the declared step after
  the run.
- **SC-002**: In a project declaring different workflows for two roles, 100% of each role's tickets land on
  their own role's declared step, and 0 tickets are evaluated against another role's step name.
- **SC-003**: Each of the six lifecycle events, fired through the shipped dispatch, resolves the step its own
  mapping declares; a direct invocation resolves none. Today 0 of the 6 resolve one on that path.
- **SC-004**: Two consecutive lifecycle events over byte-identical local files both reach the board: the
  second run is not skipped and the ticket stands at the second event's declared step. Today the second run
  issues 0 requests.
- **SC-005**: A project upgrading with a mapping written before roles existed sees its stories advance and
  0 parents and 0 sub-tasks moved as a result.
- **SC-006**: In a project whose tasks are mirrored as a checklist, a task-role mapping moves 0 tickets,
  creates 0 tickets, and produces exactly 1 notice per run saying it has no effect.

**Nothing moves that should not**

- **SC-007**: In a project declaring no mapping, 0 tickets are moved and 0 additional questions are asked of
  the tracker compared with the same run today; the same holds per role for every role left undeclared.
- **SC-008**: The run following any run performs 0 moves when nothing on disk changed and no event that
  declares a step has fired since.
- **SC-009**: In each of the three workflows that cannot be resolved — several candidates, a gated move, an
  unreachable step — 0 tickets are moved and exactly 1 warning is raised per affected ticket, naming the
  ticket, its role, and the declared step.
- **SC-010**: Every scenario in the existing safety corpus produces the same decision and the same warning
  wording as before, with the single documented addition that an advance decision now moves the ticket.
- **SC-011**: The set of moves and warnings predicted by a preview matches the set performed by a real run
  against the same state, 100% of the time, and a preview leaves the recorded run evidence byte-unchanged.

**The run does not get slower**

- **SC-012**: On a specification of 60 stories all due a move, the run's total requests are the moves it
  performs plus a small constant, and the round-trips spent learning which moves are available do not grow
  one-for-one with the 60 tickets.
- **SC-013**: Doubling the number of tickets due a move leaves the number of external processes the run
  creates unchanged — asserted by a counting stand-in, in a run separate from any timing run.
- **SC-014**: With moves performed, the summed per-phase request counts still equal the number of requests
  the run actually issued, asserted against the harness's own request log.
- **SC-015**: A run that reaches the pipeline in which no ticket is due a move costs exactly what the same
  run costs today on every counted quantity: requests, external processes, and configuration-source parses.
  Excluded, and only there: the first run under an event that changes no hashed input, which pays one full
  reconcile per input state (see FR-016).

**Both ports, and the documentation**

- **SC-016**: Both ports produce byte-identical output and an identical request sequence for every scenario
  introduced here, proven by the shared conformance corpus.
- **SC-017**: A reader comparing the safety-model document, the reconcile-flow document, the vision document
  and the agent-facing reconcile procedure against the shipped behaviour finds no claim the code does not
  satisfy, and no flag the mirror accepts that the procedure does not list.

## Assumptions

- **The event conveyance and the run-skip fix belong to this feature.** Both are defects of other features
  seen from this one's vantage point, and either could be argued into its own specification. They are here
  because this feature's headline promise — the board follows the lifecycle — is unreachable without them,
  and shipping a mapping that only advances on the events that happen to edit a file would be a second
  invisible half-feature of exactly the kind this specification exists to end. The cost is bounded: one
  value carried through the dispatch, one field and one hashed file added to a record that already exists.
- **Adding the implementation plan to the recorded evidence fixes a live defect, and this is where it
  surfaces.** The plan is already read on every run and written onto the parent, so a plan summary today
  reaches Jira only when some other file changes. This feature does not create that defect and does not go
  looking for others like it; it closes this one because FR-013's promise is not verifiable while it stands.
- **The tracker can be asked about the available moves for several tickets at once, or the question can ride
  a read the run already performs.** FR-027 is written as a bound on round-trips rather than as a mechanism
  precisely because which of those is available is a research question for planning, not a decision this
  specification should make. If neither turns out to be available, the fallback is one question per ticket
  *due a move* — never per recorded ticket — and FR-026's exclusions are what keep that bounded. The
  planning round must settle this before anything else is designed, because the answer decides whether the
  request-budget guarantee 021 shipped survives this feature.
- **A task's completion outranks the declared mapping on its own sub-task.** Two authorities can act on a
  sub-task once the task role is mappable: the checked box on disk, and the lifecycle event. FR-024 gives
  the checkbox precedence because it is the more specific statement — it is about *that* task — while the
  mapping is about every ticket of the role. The mapping therefore governs sub-tasks still in flight. This
  is the one interaction of the feature that was decided rather than inherited, and it is the first thing
  worth revisiting if it reads wrong in practice.
- **A task-role mapping in a checklist project is a notice, not a warning.** It is very likely deliberate —
  a team that switches mirroring mode should not have to rewrite its workflow declaration to silence the
  mirror — and it is certainly not per-entry. One sentence per run, in the notes channel.
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
- **Both ports carry every one of these gaps identically**, since they share the design, and all are closed
  in the same change.
- **The existing warning channel is sufficient; the summary needs one count.** The task tier already reports
  its own moved count, and the constitution already names "transitioned" among the write kinds a re-run must
  leave at zero — this feature gives the specification and story tiers the same named quantity rather than
  inventing a reporting surface.

## Out of Scope

- **Walking a multi-step path to reach a declared step.** Refused and named instead (FR-007). Revisiting it
  would be its own specification, because performing undeclared intermediate moves is a different promise
  from performing the one a team declared.
- **Proposing the mapping at configuration time.** Making the configuration ceremony discover each role's
  steps and offer a mapping is a separate item in the vision document; it is worth doing *after* the mapping
  has an effect, never before — and it becomes more valuable, not less, now that there are three of them.
- **Healing a board that drifted with no local change and no lifecycle event.** The run-skip fix here is
  narrow: an event that has not been honoured is not a run that can be skipped. It does not restore
  detection of a change made only on the tracker's side, which 021 traded away deliberately, and it does not
  introduce an expiring record — that follow-up is 021's to make, not this feature's.
- **Auditing the rest of the recorded run evidence.** The implementation plan is added because FR-013
  depends on it. This feature does not survey every other file a run reads for the same omission.
- **A per-role halted designation**, and any other per-role split of configuration this feature does not
  require.
- **Choosing between ambiguous candidate moves by any rule** — a preference order, a naming convention, or
  an operator-supplied tie-break. Reported, not resolved.
- **Supplying a value a workflow demands before a move completes**, from a recorded default or any other
  source, and any new configuration for doing so.
- **Changing how a task's completion moves its sub-task.** That model is shipped, is decided on a different
  basis, and is left exactly as it is; this feature only declares which authority wins where both could act.
- **Moving, restoring, or tidying a sub-task abandoned by a switch to checklist mirroring.** It is left
  exactly as it was, which is what 022 decided.
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
