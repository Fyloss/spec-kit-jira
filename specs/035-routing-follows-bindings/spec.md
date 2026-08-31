# Feature Specification: routing follows a specification's own bindings

**Feature Branch**: `035-routing-follows-bindings`

**Created**: 2026-08-31

**Status**: Draft

**Input**: User description: "Routing must follow a specification's own bindings. Observed in a real multi-team company-managed Jira, on a feature folder carrying no team-specific prefix. The operator's `personal.yml` selects team A; `config.yml` declares `routing_default: B`; both projects are fully bound locally. At `/speckit-specify` the specification was unbound, so routing rank 3 placed it in project A and recorded the keys as markers in `spec.md`. At `/speckit-plan`, the `after_plan` hook's dry-run reconcile of the SAME specification resolved project B instead, and planned to CREATE a new story rather than update the recorded one. Only the agent reading the dry-run summary noticed; the bridge itself reported nothing about it. Three linked defects: a bound specification reroutes to `routing_default`; the parent and the stories disagree about what 'the project' means; `--dry-run` is silent about a re-route."

## Context — the guard that removed the rank that did the work

A specification reconciles against exactly ONE Jira project. Since 033 that
project is resolved by four ranks, first non-empty wins: a committed `routing:`
rule, a committed `teams[]` folder prefix, the team the operator selected in
their gitignored `personal.yml`, and the committed `routing_default`.

033 added rank 3 and, with it, a guard. FR-004 of that feature requires
resolution to **skip rank 3 whenever any story carries a bound marker**, and to
fall from rank 2 to rank 4 instead. The guard exists for a real reason: without
it, two operators with different team selections would resolve the same
specification differently, and each run would mirror it afresh into the other
one, leaving two live ticket sets.

The reasoning 033 recorded for that guard is sound. Its words are:

> Once a story carries a ticket, the specification itself records which project
> it lives in, and that record outranks whoever happens to be reconciling it.

**Nothing ever reads that record.** The guard only suppresses rank 3.
Resolution therefore falls through to `routing_default`, which is a committed
value that may name an entirely different project from the one the markers
name. The stopping condition 033 reached for — "the answer is already in the
filesystem" — was identified correctly and then never consulted.

### What that produces, in order

1. At `/speckit-specify` the specification is unbound. Rank 3 applies, the
   operator's team places it in project A, and the parent and stories are
   created there. Their keys are recorded in `spec.md` as markers.
2. At `/speckit-plan` the same specification is now bound. The guard fires
   **because step 1 succeeded**, rank 3 is suppressed, and resolution falls to
   `routing_default` — project B.
3. Story recognition compares each recorded key's project against the routed
   project, finds a mismatch, and classifies the story as NEW: it plans to
   create a fresh ticket in B, leaving the recorded one in A untouched.

The sharpest statement of the defect is that **the guard uninstalls precisely
the rank that created the tickets, and does so because that rank created them**.
The second reconcile of a specification routes differently from the first, for
no reason other than that the first one worked.

There is a further irony worth recording, because it shows the answer was
within reach. When no rank yields anything at all, the existing refusal already
tells the operator:

> not consulted — this specification is already bound, so its project is fixed
> by its own markers

The message names the correct answer and the code declines to act on it. A
repository that declares no `routing_default` therefore gets a clean refusal
today, while a repository that declares one gets silent re-creation: the more
completely configured repository is the one that loses tickets.

### Two further defects the same scenario exposes

**The parent and the stories do not agree on what "the project" means.** Story
and task recognition compare a recorded key's project against the routed project
and treat a mismatch as a re-route. Parent recognition performs no such
comparison at all — it reads the recorded key wherever it lives. With the routed
project wrong, one single run therefore plans to UPDATE the parent in project A
and CREATE duplicate stories in project B. One specification, one run, two
projects, and a child hierarchy that cannot legally hold.

**`--dry-run` says nothing about any of it.** The note that explains a re-route
is emitted only outside dry-run, because the replacement key is not known until
the create response arrives. The consequence is that the one mode whose entire
purpose is to predict a real run omits the single fact that matters. The
observed summary contained an action creating in the wrong project, a
field-default note naming the wrong project, and a provenance-label warning
naming the wrong project — and not one word saying the story was already bound
elsewhere. What stopped the run was a human-facing agent noticing the
contradiction between a planned create and a marker on the page. That is not a
control the product provides.

### Where this stops

This feature does not revisit the four ranks themselves and does not touch
`personal.yml`'s schema. A committed routing decision still outranks the record
a specification carries — what changes is that the bridge no longer acts on the
resulting mismatch by itself. Three things, then: the record a specification
already carries becomes authoritative over the two ranks that know nothing about
it; one run becomes unable to split one specification across two projects; and
the preview stops withholding what the real run would say.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - a bound specification stays in the project it is bound to (Priority: P1)

A developer works in a repository shared by several teams, on a feature folder
whose name carries no team-specific prefix. Their `personal.yml` selects team A;
the repository's committed `config.yml` declares a default naming project B.
`/speckit-specify` mirrors the specification into project A. Every subsequent
lifecycle step — `/speckit-plan`, `/speckit-tasks`, `/speckit-implement`, and
every manual reconcile — continues to mirror into project A, updating the
tickets that already exist there.

**Why this priority**: this is the defect. Without it, the second reconcile of
any specification in a multi-team repository silently abandons its tickets and
creates a duplicate set elsewhere. It is also the only story whose absence
cannot be worked around from the outside: an operator can add a per-feature
routing rule or set an explicit override, but only after noticing, and nothing
in the product tells them to notice.

**Independent Test**: fully testable on its own. Build a repository with two
declared projects, a `routing_default` naming the second, a `teams[]` entry
naming the first, and a specification whose markers are bound to the first.
Reconcile and assert the resolved project is the first, that the run plans
updates rather than creates, and that a second operator selecting a different
team resolves identically.

**Acceptance Scenarios**:

1. **Given** a specification whose stories are bound to project A, an operator
   selecting team A, and a committed `routing_default` naming project B,
   **When** the specification is reconciled, **Then** the run resolves project A
   and plans updates against the recorded tickets — no create is planned for any
   bound story.
2. **Given** the same specification and configuration, **When** a second
   operator selecting team B reconciles it, **Then** the run resolves project A
   as well, and plans the identical set of actions.
3. **Given** a specification whose stories carry no bound marker, **When** it is
   reconciled, **Then** resolution is unchanged from today for every declared
   configuration: the operator's selected team places it, and the committed
   default places it where no team is selected.
4. **Given** a specification bound to project A **and** a committed `routing:`
   rule matching its folder and naming project B, **When** it is reconciled,
   **Then** the run resolves project B — a committed decision about this
   specification still outranks the record of where it currently lives.
5. **Given** a specification bound to project A in a repository that declares no
   `routing_default` at all, **When** it is reconciled, **Then** the run
   resolves project A and proceeds, rather than refusing as it does today.

---

### User Story 2 - one run never splits one specification across two projects (Priority: P2)

Whatever the routed project turns out to be, a single reconcile either treats
the whole specification — its parent and all its children — as living in one
project, or it stops. It never updates a parent in one project while creating
that parent's children in another.

**Why this priority**: US1 removes the common cause of a mismatch, but not every
cause. An explicit project override, or a committed routing rule genuinely
changed by a team, both still produce a routed project that differs from the
recorded one. In those states today's behaviour is not merely wrong, it is
incoherent: the two tiers apply opposite rules, and the resulting hierarchy is
one Jira will not accept. This is the story that makes the remaining paths safe
rather than merely rarer.

**Independent Test**: testable without US1 by forcing the routed project through
an explicit override that names a project other than the one the markers name,
then asserting the run's behaviour is uniform across the parent and story tiers
and that no action set spans two projects.

**Acceptance Scenarios**:

1. **Given** a specification whose parent and stories are all bound to project A
   and a run whose routed project is B, **When** the run is planned, **Then** no
   action set is produced in which the parent's project and any child's project
   differ.
2. **Given** the same state, **When** the run is planned, **Then** it refuses
   with zero Jira writes rather than creating anything in the routed project,
   and the refusal names the recorded project, the routed project, and where the
   routed project came from.
3. **Given** a specification whose markers name more than one project, **When**
   it is reconciled, **Then** it refuses with zero Jira writes and the refusal
   names every project the markers named.
4. **Given** any refusal this story introduces, **When** it occurs under a
   lifecycle hook, **Then** the host spec-kit command still completes normally
   and the refusal is reported as a single actionable warning.

---

### User Story 3 - the preview and the real run tell the same story (Priority: P3)

An operator running `--dry-run` — or an agent reading a lifecycle hook's dry-run
summary — sees exactly what a real run against the same state would do, and sees
it in the same words. No outcome is reported in one mode and withheld in the
other.

**Why this priority**: it changes no outcome, so it ranks below the two stories
that do. But it is the clause of Principle XI this feature found violated, and
it is what keeps every future instance of this class of problem reported rather
than invisible. The observed incident was stopped by an agent noticing a
contradiction the summary never stated; that must not be the control.

**Independent Test**: testable on its own by running every state this feature
introduces under `--dry-run` and then for real against the same starting state,
and comparing the predicted and actual outcomes as sets rather than as prose.

**Acceptance Scenarios**:

1. **Given** any refusal this feature introduces, **When** the run is executed
   under `--dry-run`, **Then** the refusal is reported with the same facts and
   the same exit code as a run without `--dry-run` against the same state.
2. **Given** any run under `--dry-run`, **When** its predicted action set is
   compared with the action set the same run performs for real against the same
   state, **Then** the two sets are identical.
3. **Given** the report path that explained a silent re-route only outside
   `--dry-run`, **When** this feature is complete, **Then** that path is
   unreachable and has been removed rather than left behind reporting a state
   that can no longer occur.

---

### Edge Cases

- A specification whose stories are bound but whose parent marker is absent,
  `creating`, or malformed — what places it?
- A specification whose parent is bound but none of whose stories are.
- A specification whose bound markers name more than one project, which is
  reachable today when a re-routing run is interrupted after some children are
  re-created and before the rest are.
- A recorded key whose project prefix names a project the repository never
  declares in `projects[]`.
- A bound specification in a repository that declares no `routing_default`,
  no matching rule and no matching team prefix — refused today, placed by its
  own markers under this feature.
- A specification bound to a project whose local binding is absent, so the
  project the markers name cannot be reconciled against.
- An explicit project override that contradicts the markers: the override is a
  deliberate instruction and must keep winning over routing, but must not
  thereby produce a split run.
- A tasks document whose task markers are bound to a different project from the
  specification's own — the task tier applies the same re-route rule stories do.
- Markers carrying a CRLF line ending, on Windows, in every scan this feature
  adds or changes.

## Requirements *(mandatory)*

### Functional Requirements

**Routing follows the binding (US1)**

- **FR-001**: Where a specification carries at least one bound marker, routing
  MUST resolve the project those markers record, ahead of the operator's
  selected team and ahead of the committed default.
- **FR-002**: A committed `routing:` rule and a committed `teams[]` folder
  prefix MUST both remain ahead of the marker-derived project. A team that
  commits a decision about where a specification belongs MUST still be able to
  move it.
- **FR-003**: The marker-derived project MUST be determined from the
  specification's own bytes as they stood before this run, with no Jira read and
  no additional file opened.
- **FR-004**: A bound specification MUST resolve to the same project for every
  operator, whatever team each has selected and whether or not any has selected
  one.
- **FR-005**: For a specification carrying no bound marker, resolution MUST be
  byte-identical to today's for every possible configuration. This feature MUST
  be inert on every unbound specification.
- **FR-006**: "Bound" MUST mean exactly "the specification's markers yield at
  least one usable project". A specification whose markers are all absent, in
  flight, bare or malformed MUST therefore be treated as not bound and resolve
  exactly as it does today, with the operator's selected team offered as it is
  today. No state may exist in which a specification counts as bound and yet
  yields no project for the marker rank — the two predicates are one, and that
  is what keeps the degenerate case from reintroducing the per-operator
  divergence 033 removed.
- **FR-007**: Where the marker-derived project is not declared in the
  repository's `projects[]`, the run MUST refuse with zero writes and a message
  naming the project, the specification, and that the project came from the
  specification's own markers rather than from a routing rule.
- **FR-008**: Determining the marker-derived project MUST NOT spawn an external
  process per story, per line, or per marker, and MUST be performed at most once
  per run.

**One run, one project (US2)**

- **FR-009**: A single run MUST NOT produce an action set in which a parent and
  any of its children are written to different projects.
- **FR-010**: The parent tier MUST evaluate a recorded key's project against the
  routed project by the same rule the story and task tiers apply. The three
  tiers MUST NOT hold different definitions of a project mismatch.
- **FR-011**: Where a specification's own markers name more than one project,
  the run MUST refuse with zero Jira writes, and the refusal MUST name every
  project the markers named and the specification concerned (Q1).
- **FR-012**: Where the routed project differs from the project the
  specification's markers name — reachable through an explicit override or a
  committed routing change — the run MUST refuse with zero Jira writes rather
  than create anything in the routed project, identically for the parent, story
  and task tiers. The refusal MUST name the recorded project, the routed
  project, and where the routed project came from (Q2).
- **FR-013**: Any refusal this feature introduces MUST fail closed with zero
  Jira writes, and MUST be downgraded to a single actionable warning under a
  lifecycle hook, leaving the host spec-kit command's exit code unaffected.

**The preview tells the truth (US3)**

- **FR-014**: Every refusal this feature introduces MUST be reported identically
  under `--dry-run` and without it — same facts, same exit code, same wording.
  No outcome may be conditioned on the run being a real one.
- **FR-015**: Every message this feature adds MUST be composable without any
  value that exists only after a Jira write has been performed. A message that
  can only be written after the fact cannot be part of a preview.
- **FR-016**: The set of actions a `--dry-run` predicts MUST be identical to the
  set the same run performs against the same state without `--dry-run`, for
  every state this feature introduces or changes.
- **FR-017**: Every message this feature adds MUST name the ticket, the project,
  and the specification it concerns, and MUST tell the operator what to do next.
  A refusal that reports a project mismatch without naming the recorded ticket
  does not satisfy this.
- **FR-018**: The report path that explained a re-route only outside `--dry-run`
  MUST be removed once FR-012 makes the state it reports unreachable. A report
  for a state that can no longer occur is not kept as a precaution.

**Cross-cutting obligations**

- **FR-019**: Both ports MUST produce byte-identical resolved project keys,
  byte-identical messages, byte-identical report entries and identical exit
  codes for every state this specification describes.
- **FR-020**: The conformance corpus MUST cover, at minimum: one scenario per
  acceptance scenario of US1; one scenario per outcome class resolved in Q1 and
  Q2; and one scenario proving FR-005 against a repository configured exactly as
  it is today.
- **FR-021**: Re-running a reconcile against an unchanged bound specification
  MUST produce zero Jira writes of every kind, in the repository shape US1
  describes — the shape that produces a full duplicate ticket set today.
- **FR-022**: Every message literal this feature adds MUST be runnable exactly
  as spelled where it names a command, and MUST be covered by the existing
  message-to-command check.
- **FR-023**: Every scan this feature adds over specification or tasks content
  MUST tolerate CRLF input on both ports, and MUST NOT express a line ending
  inside a glob pattern.
- **FR-024**: The documentation that states the resolution order MUST be updated
  wherever it appears — the architecture documents, the configuration template's
  own commentary, and any README block a consumer reads — so that no shipped
  text continues to describe a chain this feature has changed.

### Key Entities

- **Bound marker**: the record, carried in the specification or tasks document
  itself, of the ticket a given item was mirrored to. Already exists in three
  forms — parent, story, and task — and is already the authority recognition
  reads. This feature gives it authority over routing as well.
- **Marker-derived project**: the project a specification's own bound markers
  record. Derived, never stored, never configured, and never read from Jira.
- **Routed project**: the single project a run reconciles against, resolved from
  the ranks in order.
- **Re-route**: the existing classification of a bound item whose recorded key
  lives in a project other than the routed one. Today it applies to two tiers of
  three and is invisible under `--dry-run`.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Strengthened, and this is the principle the feature is an application of. The record of where a specification lives is already on disk; the defect is that routing ignored it. No new state store, no registry, no controlled exception widened: FR-001 consults a marker the filesystem already carries. FR-009 removes a path that leaves a ticket stranded in another project with nothing recording it. |
| II | Zero-Churn Idempotency | Central. Today the second reconcile of a bound specification in the observed shape creates a full duplicate ticket set — the largest possible churn violation. FR-021 requires the zero-write assertion in exactly that shape. Ticket identity is untouched: it stays in the server-side entity property, never a label or summary. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-007, FR-012 and FR-013 all refuse with zero writes. FR-013 pins the hook-context downgrade explicitly, because this feature both adds refusal states and removes one (a bound specification that no rank could place is now placed), and both directions of that change need their own test rather than inheriting the unchanged branch's. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. No key this feature reads or writes can hold a credential; no message it adds carries one; the credential resolution order is untouched. Fixture repositories added for FR-020 carry project keys and marker identifiers only. |
| V | Separation of Team Config / Local Binding / Secrets | Respected and clarified. No key is added to any layer. The per-operator layer's influence over routing is narrowed, not widened: it stops being consulted where the specification already answers the question. The committed layer keeps its ability to state both a rule and a default, and FR-002 keeps both ahead of the marker. |
| VI | macOS / Linux / Windows Portability | FR-019 requires byte-identical behaviour from both ports and FR-023 pins the CRLF and glob-pattern hazards that have produced Windows-only divergences before. FR-020 extends the conformance corpus, which is where cross-port equivalence is proven. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. This feature resolves a project key and compares project prefixes; it asserts nothing about statuses, types, transitions, or field names. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Respected. FR-003 keeps resolution a pure function of configuration and specification content, with no Jira read. The marker-derived project is engine-side data that reaches the sink as a parameter, exactly as the routed project does today. FR-010 unifies a rule three sink tiers already hold in two different forms; it moves no decision across the seam. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. No specification content is newly transmitted to Jira, and nothing this feature writes into a tracked file originates from Jira. The values its messages name — project keys and issue keys — are already public within the organisation and already appear in existing messages. |
| X | Self-Healing Automatic Mirror, Within Its Own Boundary | Respected. This feature neither reads nor reports the hook registry, which constitution 4.0.0 forbids outright. It operates entirely within the reconcile path's own boundary and adds no dispatch behaviour. |
| XI | Universal Dry-Run and Auditability | The principle this feature found violated, and US3 is its repair. FR-016 restates the principle's own enforcement test — predicted and actual action sets identical — for every state this feature touches; FR-014 forbids conditioning any outcome on the run being real, which is what made the prediction incomplete; and FR-018 removes the report path that was withheld rather than leaving it in place. FR-017 keeps every added message auditable by naming the ticket, project and specification it concerns. |
| XII | Quality and Catalog Publication | A version bump and a CHANGELOG entry accompany the change. FR-001 changes a resolved project for a configuration that is valid today, so the release is breaking and the bump is major. FR-024 keeps the shipped documentation from describing a chain that no longer exists. Dogfooding against the real instance that produced the report is the acceptance evidence. |
| XIII | TDD With a Minimum 80% Coverage | Each of the three defects gets its failing test before its fix, in both ports, per the repository's bug-fix policy. FR-020 requires conformance scenarios per outcome class, which per-port unit tests do not satisfy. Routing resolution and the fail-closed refusals are critical paths and target coverage close to 100%. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | One rank inserted into an existing chain, one comparison made uniform across three tiers that already hold two versions of it, and one report entry made available in a mode it was withheld from. Zero new keys, zero new files in the consumer's tree, zero new state, no new dependency. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Every requirement traces to one observed incident in a real multi-team company-managed Jira. Nothing here is anticipatory: FR-009's split is not hypothetical but the state the observed run planned, and the silence FR-014 forbids is the reason a person, rather than the product, caught it. |
| XVI | Human Readable — Readable by a Human Above All | FR-017 requires every added message to name the ticket, project and specification. The refusal this feature inherits already demonstrates the failure mode it guards against — a message that names the right answer without acting on it — and FR-007's message must say where the project came from, not merely that it is wrong. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a repository with two declared projects, a committed default
  naming the second, and a feature folder carrying no team-specific prefix, a
  specification mirrored into the first project at `/speckit-specify` is still
  mirrored into that same project at every subsequent lifecycle step, with no
  configuration edit and no override by the operator.
- **SC-002**: In that same repository, the number of tickets a specification
  holds after running the full lifecycle once is equal to the number it holds
  after running it twice — zero duplicates, against a count of one full
  duplicate set today.
- **SC-003**: Two operators with different team selections, reconciling the same
  bound specification against the same repository state, produce identical
  action sets.
- **SC-004**: No run produces an action set naming more than one project for one
  specification, across every state the conformance corpus covers.
- **SC-005**: For every run that would create a ticket for an item already bound
  elsewhere, the `--dry-run` summary alone is sufficient to identify the
  abandoned ticket and its project, without reading the specification, without
  reading Jira, and without a second run.
- **SC-006**: A repository configured exactly as it is today, whose
  specifications carry no bound markers, resolves every one of them to the
  project it resolves them to today.

## Assumptions

- The observed report was produced against a real multi-team company-managed
  Jira. Project and team names are anonymised throughout as A and B; only the
  configuration shape that produces the defect is retained.
- Both projects in the observed repository were fully bound locally. The defect
  therefore reaches the planning stage rather than being caught by a
  not-bound refusal, and a run without `--dry-run` would have performed the
  creates. Repositories where the wrongly-routed project is unbound already
  refuse for an unrelated reason and are not the case this feature addresses.
- A specification's parent marker is the natural authority for
  "which project this specification lives in", since a specification has exactly
  one parent and parent recognition already reads that key wherever it lives.
  Where the parent is bound, it is assumed to determine the marker-derived
  project; Q1 below settles what happens when the children disagree with it.
- Where the parent is not bound but stories are, the marker-derived project is
  assumed to come from the bound stories. This is the state a run interrupted
  between parent creation and key recording leaves behind, and it is assumed
  not to warrant its own refusal.
- 033's suppression of the operator's selected team for a bound specification
  becomes an identity rather than a separate rule: FR-006 makes "bound" and
  "the marker rank has a value" the same predicate, so the suppression is not
  kept as dead code and no unreachable fallback is carried. This was flagged by
  the analysis pass, which found the original wording governed a state the
  design cannot produce.
- The existing `config.local.yml` override of `routing_default` is a general
  override over the whole committed configuration rather than a routing feature,
  and is left in place, exactly as 033 left it.
- An explicit project override supplied by the caller continues to outrank all
  routing, including the marker-derived project. It is a deliberate instruction
  from an operator who can see both values; FR-012 governs only what the run
  then does, not whether the override wins.
- The existing re-route classification is assumed to remain the correct way to
  DETECT that a bound item's recorded project differs from the routed one. What
  it then does changes: Q2 resolves it to a refusal rather than a create, so the
  silent story-only re-creation shipped today is retired by this feature. The
  detection, its cross-port equivalence, and its existing tests are reused.

## Resolved Decisions

Two decisions changed what the feature does rather than how it is built. Both
were resolved fail-closed, and both are recorded here rather than left as
clarification markers so that planning could proceed. **Either may be revisited
without disturbing the rest of the specification** — each governs exactly one
outcome class and is named by exactly one functional requirement.

- **Q1 — authority when a specification's markers name more than one project.**
  **Resolved: the run refuses with zero writes and names every project its
  markers found.** The alternatives were "the parent's project wins and the
  children are re-routed into it" and "the most frequent project wins". Both
  resolve the ambiguity by re-creating tickets, which is the very action this
  feature exists to stop the bridge taking on its own. The state is reachable
  only from a run interrupted partway through a re-route, so it is rare, it is
  evidence that something already went wrong, and an operator is better served
  by being told than by having the bridge guess. This matches how the codebase
  already handles a ticket claimed by two stories: blocked, nothing written, the
  operator resolves. Governed by FR-011.

- **Q2 — parent behaviour when the routed project differs from the recorded
  one.** **Resolved: the run refuses with zero writes; the bridge does not move
  a bound specification between projects on its own.** The alternative was to
  re-route the parent as well, so that a committed routing change moves the
  whole specification coherently. That alternative satisfies FR-009 too, and it
  is the more convenient one — but moving an entire specification is effectively
  irreversible, it strands a complete ticket set, and having it fire as a side
  effect of a configuration edit is the same class of surprise as the defect
  this feature repairs. Refusing keeps the option open: an explicit opt-in can
  be added later by a spec that asks for one, whereas a silent move cannot be
  taken back. Governed by FR-012.

  **This retires the silent story-only re-route as shipped behaviour.** The
  re-route classification itself is kept — it is how the mismatch is detected —
  but it now produces a refusal rather than a create. FR-014 is what makes that
  refusal identically legible under `--dry-run`, and FR-018 retires the report
  path that only ever spoke outside it.
