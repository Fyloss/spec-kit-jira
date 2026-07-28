# Feature Specification: Ticket Creation Reaches Its Destination Project

**Feature Branch**: `004-jira-create-project-field`

**Created**: 2026-07-28

**Status**: Draft

**Input**: User description: "Another bug reported by the project consuming
the extension: when the extension tries to connect through `spec-kit-jira
reconcile` there is an error, as if the `project` field were missing from the
Jira payload. Apparently the Jira API requires that field for
`/rest/api/3/issue`."

> This is a second, independent defect from the one covered by feature 003.
> Feature 003 makes the bridge *fire*; this feature makes the write it sends
> *land*. Both were reported from the same consuming repository.

## Overview

A developer installs the extension, configures the binding to their tracker
project, and runs the reconcile step on a specification for the first time.
Reconciliation parses the specification, assembles the neutral document, plans
the writes — and then every ticket-creation request is refused by the tracker,
which reports that the destination project is missing. No ticket is created.
The run is a total loss for the developer: the extension appears configured,
reports no configuration problem, and still mirrors nothing.

The cause is that the **destination project never reaches the creation
request**. The bridge already knows which project a specification mirrors
into — the binding resolves it, and the neutral document carries it as routing
information — but that knowledge is dropped between planning a creation and
sending it. The tracker requires a destination on every new ticket and refuses
the request without one. Updates of already-mirrored tickets are unaffected,
because an update addresses an existing ticket that already lives in a
project; this is why the failure only shows up on a *first* reconcile, which
is exactly the run a new consumer performs.

A second, quieter problem is exposed by the same report. When the destination
project cannot be resolved from the configuration, the bridge substitutes a
built-in placeholder instead of stopping. That placeholder cannot be right for
any real repository: at best the tracker rejects it with a confusing message
about an unknown project, at worst it names a project that happens to exist
and the developer's specifications are mirrored somewhere nobody expects. An
unresolved destination is a configuration fault and must be reported as one,
before anything is written.

This feature therefore covers three things: creations carry their destination,
an unresolvable destination stops the run before any write, and a refusal that
concerns the destination is reported in terms the developer can act on.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - A first reconcile actually creates the tickets (Priority: P1)

A developer with a configured repository runs the reconcile step on a
specification that has never been mirrored. Every story in that specification
is created in the project the repository is bound to, and the run reports what
it created.

**Why this priority**: This is the reported defect, and it blocks the
extension's entire purpose. Until a creation can succeed, no consumer can
mirror anything at all — the extension is unusable in a new repository.

**Independent Test**: Can be fully tested by reconciling a specification with
no existing tickets against a bound project and verifying that each planned
creation is accepted and lands in that project, with no refusal mentioning a
missing destination.

**Acceptance Scenarios**:

1. **Given** a repository bound to a destination project and a specification
   whose stories have never been mirrored, **When** the developer runs the
   reconcile step, **Then** every story is created in that destination project
   and the run reports the created tickets.
2. **Given** the same repository, **When** the reconcile step plans a
   creation, **Then** the planned creation names the destination project the
   specification is bound to — not a default, not a placeholder, and not the
   project of some other specification.
3. **Given** a specification whose stories are already mirrored, **When** the
   reconcile step plans updates for them, **Then** no update carries a
   destination project, and the existing tickets stay in the project they are
   already in.
4. **Given** a repository containing several specifications bound to different
   destination projects, **When** each is reconciled, **Then** each
   specification's creations name its own destination and no ticket is created
   in another specification's project.
5. **Given** a first reconcile that succeeds, **When** the developer runs the
   same reconcile again with no change to the specification, **Then** the
   already-created tickets are recognised and no duplicate ticket is created.

---

### User Story 2 - An unresolved destination stops the run, loudly (Priority: P1)

A developer runs the reconcile step in a repository where the destination
project is not configured, or is configured with an unusable value. The run
stops before contacting the tracker, writes nothing, and says which piece of
configuration is missing and how to supply it.

**Why this priority**: A placeholder destination is worse than a failure. It
produces either a baffling refusal from the tracker or — the dangerous case —
a silent write into a project the developer never chose. Stopping early is
also what makes the User Story 1 fix trustworthy: once creations carry a
destination, that destination must never be a guess.

**Independent Test**: Can be fully tested by running the reconcile step in a
repository with the destination unset, then with an unusable value, and
verifying in both cases that nothing is sent to the tracker, the exit outcome
is the configuration fault, and the message names the missing setting.

**Acceptance Scenarios**:

1. **Given** a repository where the destination project is not configured,
   **When** the developer runs the reconcile step, **Then** the run stops with
   a configuration fault before any request is sent, and reports that the
   destination project is not configured together with the way to configure
   it.
2. **Given** a repository where the destination project is set to a value the
   tracker cannot accept as a project identifier, **When** the developer runs
   the reconcile step, **Then** the run stops with a configuration fault
   before any request is sent and reports the rejected value.
3. **Given** either of the above, **When** the run stops, **Then** zero
   tickets are created, zero tickets are updated, and zero transitions are
   applied.
4. **Given** an unconfigured repository, **When** the developer runs the
   reconcile step in preview mode, **Then** it stops with the same
   configuration fault rather than printing a preview built on a placeholder.

---

### User Story 3 - The preview shows where tickets will go (Priority: P2)

Before letting the bridge write anything, a developer runs the reconcile step
in preview mode and reads, for each ticket that would be created, which
destination project it would be created in.

**Why this priority**: The preview is the project's stated safety mechanism
for every write. A preview that hides the destination cannot protect a
developer from the very mistake this feature is about, and it is the cheapest
way for a new consumer to confirm their binding before touching the tracker.

**Independent Test**: Can be fully tested by running the preview on a
specification with unmirrored stories and confirming that the destination
project appears for every planned creation, in both the human-readable and the
machine-readable report.

**Acceptance Scenarios**:

1. **Given** a configured repository and unmirrored stories, **When** the
   developer runs the reconcile step in preview mode, **Then** each planned
   creation shows its destination project.
2. **Given** the same run, **When** the developer requests the
   machine-readable report, **Then** each planned creation carries its
   destination project as data.
3. **Given** a preview run, **When** it completes, **Then** nothing was
   written to the tracker.

---

### User Story 4 - A refusal about the destination is explained (Priority: P2)

A developer whose destination is configured but wrong — a project that does
not exist on their site, or one they may not create tickets in — runs the
reconcile step and is told which project was refused and why, instead of a raw
tracker error.

**Why this priority**: Once creations carry a destination, the next thing a
new consumer hits is a destination that is well-formed but not usable. Without
a readable explanation this reproduces the original symptom: a failed run and
no idea what to change.

**Independent Test**: Can be fully tested by pointing the binding at an
unknown project, then at a project without creation rights, and verifying each
run reports the destination it used and a distinct, actionable cause.

**Acceptance Scenarios**:

1. **Given** a destination project that does not exist on the developer's
   site, **When** the reconcile step attempts a creation, **Then** the run
   fails reporting the destination it used and that the project is unknown.
2. **Given** a destination project the developer may not create tickets in,
   **When** the reconcile step attempts a creation, **Then** the run fails
   reporting the destination it used and that permission was refused —
   distinctly from the unknown-project case.
3. **Given** a destination project that does not offer the configured ticket
   type, **When** the reconcile step attempts a creation, **Then** the run
   fails naming both the destination and the ticket type, distinctly from the
   two cases above.
4. **Given** any of these failures, **When** the message is emitted, **Then**
   it contains no credential material of any kind.

---

### User Story 5 - Both ports behave identically (Priority: P3)

A developer on Windows and a developer on macOS or Linux, working from the
same repository and the same specification, get the same tickets in the same
destination project.

**Why this priority**: The defect exists on both ports, and a fix applied to
one only would leave half the consumers broken while appearing resolved.

**Independent Test**: Can be fully tested by producing the write plan for one
specification on each port and comparing them for equality.

**Acceptance Scenarios**:

1. **Given** one specification and one configuration, **When** the write plan
   is produced on each port, **Then** the two plans are equal, including the
   destination project on every creation.
2. **Given** an unresolved destination, **When** the reconcile step runs on
   each port, **Then** both stop with the same configuration fault and the
   same reported cause.

---

### Edge Cases

- What happens when the destination project is configured in more than one
  place — the repository configuration and an environment override — and the
  two disagree? One of them must be authoritative, and the run must use it
  consistently for planning, preview and writing.
- How does the system handle a destination project written in a shape the
  tracker does not accept — lower-case, or containing spaces or punctuation?
  It must be refused as a configuration fault before any request, not sent and
  bounced back.
- What happens when a specification's stories are partly mirrored, so that one
  run contains both creations and updates? Creations must carry the
  destination and updates must not, within that same plan.
- How does the system handle a creation the tracker accepts but places
  elsewhere because of a tracker-side rule? The reported result must reflect
  where the ticket actually ended up.
- What happens when the destination project exists but is archived or
  read-only? It must be reported as a refused destination, not as a transient
  failure the developer might retry forever.
- How does the system handle a run where the first creation succeeds and the
  second is refused for a destination-related reason? The run must report what
  was created and what was not, so that a retry does not duplicate the
  successful ticket.
- What happens when the destination resolves correctly but the tracker is
  unreachable? That is a connectivity fault and must not be reported as a
  configuration fault.

## Requirements _(mandatory)_

### Functional Requirements

#### Destination on every creation

- **FR-001**: Every planned ticket creation MUST carry the destination project
  the specification is bound to.
- **FR-002**: The destination carried by a creation MUST be the one resolved
  for that specification, never a value derived from another specification, a
  previous run, or a built-in constant.
- **FR-003**: A planned update of an existing ticket MUST NOT carry a
  destination project; an update addresses a ticket that already has one.
- **FR-004**: A plan containing both creations and updates MUST satisfy
  FR-001 and FR-003 simultaneously within the same run.
- **FR-005**: FR-001 to FR-004 MUST hold identically on both supported ports,
  which MUST produce equal write plans for equal inputs.

#### Resolving the destination

- **FR-006**: The destination project MUST come from the repository's resolved
  binding. The system MUST NOT substitute any built-in default or placeholder
  when it is absent.
- **FR-007**: When the destination cannot be resolved, the run MUST stop with
  the configuration fault outcome before any request is sent to the tracker.
- **FR-008**: When the destination is present but not in a shape the tracker
  accepts as a project identifier, the run MUST stop with the configuration
  fault outcome before any request is sent, and report the rejected value.
- **FR-009**: A run stopped under FR-007 or FR-008 MUST perform zero
  creations, zero updates and zero transitions.
- **FR-010**: When the destination can be specified in more than one place,
  the system MUST define one precedence order, apply it identically to
  planning, preview and writing, and document it.
- **FR-011**: Preview mode MUST apply FR-007 and FR-008 exactly as a writing
  run does, rather than producing a preview based on an unresolved
  destination.

#### Reporting

- **FR-012**: The preview report MUST show the destination project for every
  planned creation, in both its human-readable and its machine-readable form.
- **FR-013**: A message reporting a configuration fault about the destination
  MUST name the setting that is missing or rejected and state how to supply a
  correct value.
- **FR-014**: A refusal from the tracker that concerns the destination MUST be
  reported with the destination that was used, and MUST distinguish at
  minimum: unknown project, insufficient permission to create, and ticket type
  unavailable in that project.
- **FR-015**: A destination-related failure MUST be distinguishable from a
  connectivity failure and from a credential failure.
- **FR-016**: No message emitted under FR-013 to FR-015 may contain credential
  material.
- **FR-017**: When a run creates some tickets and then fails, the report MUST
  state which tickets were created, so that a repeat run does not duplicate
  them.

#### Regression protection

- **FR-018**: The contract that a creation carries its destination and an
  update does not MUST be verifiable without a live tracker.
- **FR-019**: The reported failure MUST be covered by an automated check that
  fails against the current behaviour and passes once the destination is
  carried.

### Key Entities

- **Destination project**: the single tracker project a given specification
  mirrors into. Resolved from the repository's binding, identified by its
  project identifier, and required by every ticket creation.
- **Write plan**: the ordered set of creations, updates and transitions a
  reconcile run intends to perform. It is what preview mode reports and what
  the write guard inspects, so a destination absent from the plan is a
  destination absent from the write.
- **Creation**: a planned new ticket. Carries its destination project, its
  ticket type and its content. Distinguished from an update, which addresses
  an existing ticket and carries neither destination nor type.
- **Routing information**: the part of the neutral document that records which
  destination a specification belongs to, already present and validated before
  any write is planned.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: In a correctly configured repository, 100% of first-time
  reconcile runs create their tickets, with zero failures attributable to an
  absent destination.
- **SC-002**: Zero creation requests are sent without a destination project.
- **SC-003**: Zero update requests carry a destination project.
- **SC-004**: 100% of runs with an unresolved or unusable destination stop
  before the first request and perform zero writes.
- **SC-005**: Zero runs proceed using a destination the developer did not
  configure.
- **SC-006**: For the same specification and configuration, the write plans
  produced by the two ports are equal — zero differences, including the
  destination on every creation.
- **SC-007**: 100% of previewed creations display their destination project.
- **SC-008**: Across the destination fault matrix — unset, wrongly shaped,
  unknown project, permission refused, ticket type unavailable — 100% of runs
  produce a distinct message identifying the cause, and zero produce a raw
  tracker error.
- **SC-009**: Zero messages emitted by these paths contain credential
  material.
- **SC-010**: A repeat run after a partially failed run creates zero duplicate
  tickets.
- **SC-011**: A developer following the documented setup reaches a first
  successful mirrored specification with zero troubleshooting steps related to
  the destination project.

## Assumptions

- The consumer's report is taken at face value and confirmed as stated: the
  creation request omits the destination project, and the tracker requires it.
  The fix is to carry the destination that is already resolved, not to
  introduce a new way of choosing one.
- A specification mirrors into exactly one destination project. Splitting one
  specification across several projects stays outside this feature, as it is
  already outside the existing routing rules.
- The destination project is identified by the project identifier the
  configuration step already resolves. This feature consumes that value; it
  does not change how it is discovered.
- A ticket's project is fixed once the ticket exists. Correcting a ticket
  created in the wrong project is a manual operation for the developer, not
  something the bridge performs.
- The ticket type is already resolved per destination by the configuration
  step; this feature reports a mismatch between type and destination but does
  not resolve types.
- "Stops before any request is sent" means before any request that would
  create or modify anything. Read-only lookups performed while resolving
  configuration are unaffected.
- The reported error text is treated as a symptom. This feature does not
  preserve its wording, only the requirement that the underlying failure no
  longer occurs and that any remaining destination failure is explained.

## Dependencies

- The configuration and discovery behaviour delivered by feature 002 supplies
  the resolved destination project; this feature depends on it and does not
  duplicate it.
- Feature 003 determines whether the reconcile step runs at all. The two are
  independent: 003 without this feature fires a write that is refused; this
  feature without 003 fixes a write the developer must trigger by hand.
- The tracker requires a destination project and a ticket type on every new
  ticket; this is a property of the tracker, not a choice this feature makes.
- The existing fail-closed write guard and preview mechanism are reused as
  they are; this feature adds the destination to what they inspect and report.

## Out of Scope

- Changing what content is mirrored into a ticket — titles, descriptions,
  priority, estimation and transitions are unchanged.
- Creating or linking epics, and any change to the epic strategy.
- Moving an existing ticket from one project to another.
- Supporting more than one destination project per specification.
- Changing how the destination project, ticket type or priority values are
  discovered or configured.
- Anything covered by feature 003: hook registration, hook dispatch, and the
  runnability of the bridge entry point.
