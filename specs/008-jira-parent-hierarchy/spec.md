# Feature Specification: A Specification Mirrors as a Jira Hierarchy

**Feature Branch**: `feat/create-epics`

**Created**: 2026-07-31

**Status**: Draft

**Input**: User description: "Feature request: mirror a specification as a real Jira hierarchy — one parent artifact per specification, carrying the specification, with one child issue per user story."

## Context

Today the bridge mirrors a specification as a flat list. A three-story specification produces
exactly three issue creations and nothing else: no parent artifact, no parent link. A Product
Owner opening the project sees three orphan tickets with no object that says which feature they
belong to, and no place where the specification itself can be read.

The engine already knows about the parent. The parser assembles a document shaped
`{epic: {title, description}, stories: [...]}`, the neutral-document validator requires a
non-empty epic title and description, and the assembled document handed to the sink carries all
of it. The sink then drops it on the floor: the write planner never reads the epic and never
emits a parent reference on a child.

This feature closes that gap. One specification becomes exactly one parent artifact, created at
the level the project's own hierarchy puts above its stories, carrying the specification rendered
for a human reader, with every user story created beneath it as a child.

Three defects sit in the way and are repaired here rather than worked around:

- **The child issue type is resolved by literal name.** The reconcile path looks the child type
  up under the key `Story` in the persisted binding. On a French Jira the type is `Récit`, so
  the key is absent, the type reaches the write planner empty, and the run refuses every
  creation. A SAFe project using Capability / Feature / Story hits the same wall.
- **The persisted binding throws away the hierarchy.** Discovery reads the hierarchy level and
  the sub-task flag for every issue type, but the table written into the local binding — the one
  the reconcile path reads — is flattened to logical-name-to-identifier pairs. The level
  information never survives to the point of use, so nothing downstream can resolve a type by its
  position in the hierarchy even though Jira supplied it.
- **Create metadata is inspected for one issue type only.** Discovery requests the create
  metadata of the first issue type the project happens to return. The parent level's own field
  schema is therefore never seen, and no issue type's mandatory fields are recorded at all.

Two things make the work cheaper than it looks: the parent's description path is not new (the
neutral content blocks and the rich-text renderer already exist and already handle the epic's
description shape), and the parent's durable-identifier machinery is not new either (the story
identifier, its in-file marker, the server-side identity marker and the verified read all exist
and generalise).

Neither level is declared by an operator. Both are derived from the hierarchy the project itself
reports, and where the derivation is not unambiguous the run refuses rather than choosing. This
follows the precedent the style detection already sets: on an absent or contradictory signal it
prints nothing and never substitutes a default, leaving the layer above to ask or to fail closed.
A configuration key naming the parent's type would be speculative until the ambiguous case
actually occurs at a real consumer, and Constitution XV forbids shipping it before then.

Finally, the pipeline carries configuration keys that no consumer reads. `epic_strategy` is
validated by the config layer, written by the configuration ceremony, resolved during reconcile,
injected into the plan context, carried into the neutral document and validated a second time —
and never once read to make a decision. `task_strategy` is the same, and `link_type` exists only
to be required when `task_strategy` takes one of its two values. Three keys travelling the whole
pipeline without a consumer is precisely what Constitution XV forbids. Because cardinality is
imposed by this feature (one specification, one parent), `epic_strategy` can never acquire a
consumer, and removing all three now costs nothing. After rollout it would cost a coordinated
edit of a committed file in every consumer repository.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Issue types resolve on a Jira that is not the Atlassian default (Priority: P1)

A team runs a Jira Cloud localised into their own language — the user-story type is named `Récit`,
or `История`, or `ストーリー` — or a SAFe programme whose hierarchy is Capability / Feature /
Story. They configure the bridge and reconcile a specification. The bridge resolves both the type
it writes children at and the type it writes the parent at from the project's own discovered
hierarchy — each type's position in the levels Jira reported — never from a name compiled into the
bridge and never from a name an operator typed. The reconcile succeeds and the tickets carry the
project's own types.

**A type name is opaque text, not a language the bridge knows.** The bridge never parses,
translates, normalises or matches an issue-type name; it carries the bytes Jira supplied,
round-trips them through the binding, and echoes them in diagnostics. French appears in this
specification only as a fixture, never as a supported-language list — and a non-Latin fixture
sits beside it precisely so that no reader, and no future contributor, mistakes the mechanism for
a two-language one.

**Why this priority**: Without this, the feature is unreachable for every consumer whose Jira is
not an English default installation — and the parent level cannot be resolved either, since it
depends on the same repaired hierarchy information. It is the foundation the rest stands on, and
it delivers value alone: today a localised project refuses every creation; after this story it
mirrors its stories correctly, flat.

**Independent Test**: Reconcile one specification against three fixture projects — one whose issue
types carry Latin diacritics, one whose issue types are in a non-Latin script, and one using a
SAFe hierarchy. Assert each creation carries the type identifier its fixture declares at the child
level, with no change to the bridge's code and no configuration difference between the three runs.

**Acceptance Scenarios**:

1. **Given** a project whose child-level issue type is named `Récit`, and a second whose
   child-level type is named in a non-Latin script, **When** a specification is reconciled against
   each, **Then** every user story is created with that project's own type identifier and each run
   reports zero errors.
2. **Given** a project whose hierarchy is Capability / Feature / Story, **When** a specification
   is reconciled, **Then** the children are created at the Story level and the parent at the
   Feature level, because Feature is the single non-sub-task level immediately above Story.
3. **Given** a project offering no non-sub-task issue type above the child level, **When** a
   reconcile is attempted, **Then** the run fails closed before any write, names the project and
   states that it offers no parent-level type — and does not fall back to the child level or to
   any other type.
4. **Given** a project where two or more non-sub-task issue types share the lowest level above the
   child level, **When** a reconcile is attempted, **Then** the run fails closed before any write,
   names every candidate type, and states that the project needs an explicit choice — and does not
   pick one itself.
5. **Given** a project where the child-level type cannot be resolved at all, **When** a reconcile
   is attempted, **Then** the run fails closed before any write, names the project and the level,
   and states the remediation.
6. **Given** any project, **When** the reconcile path resolves an issue type, **Then** no
   Atlassian default type name appears anywhere in the resolution, and a search of the bridge's
   code for such a literal finds none.
7. **Given** a project whose issue-type names carry diacritics, a non-Latin script, or ordinary
   punctuation such as `Done (QA)` or `high/low`, **When** the configuration ceremony writes the
   binding and a later reconcile reads it back, **Then** every name round-trips byte for byte, and
   any name the reader cannot unescape refuses with the located, redacted message feature 007
   established — never a silently truncated binding.

---

### User Story 2 - A specification mirrors as a stable hierarchy (Priority: P1)

A developer reconciles a specification. Jira gains one parent artifact carrying the specification
written for a human reader, and every user story is created as a child of it. The developer runs
the same lifecycle command again, and again the next day: Jira is untouched — no second parent,
no re-created children, no field rewritten.

**Why this priority**: This is the feature. It is also the point at which the bridge stops being a
ticket sprayer and starts being a mirror a Product Owner can navigate. Recognition of the parent
is part of this story and not a follow-up: a parent created without a durable identifier would be
re-created on every single run, reintroducing exactly the duplication defect the previous
idempotency work was written to fix, and producing a demonstration that visibly degrades each time
it is shown.

**Independent Test**: Reconcile a three-story specification against an empty project. Assert one
parent and three children exist, each child references the parent, and the parent's description
reads as prose. Reconcile again unchanged and assert the run reports zero created, zero updated,
zero transitioned, zero commented, zero linked and zero labeled, and that the project still holds
exactly four issues.

**Acceptance Scenarios**:

1. **Given** an empty project and a specification with three user stories, **When** reconcile
   runs, **Then** exactly one parent artifact and three child issues exist, and each child names
   the parent as its parent.
2. **Given** that same specification unchanged, **When** reconcile runs a second time, **Then**
   the run issues zero writes of every kind, the parent included, and the run summary reports
   `created: 0` and `updated: 0`.
3. **Given** a specification already mirrored, **When** a new user story is added and reconcile
   runs, **Then** exactly one child is created beneath the existing parent, no new parent is
   created, and the parent itself is not written to.
4. **Given** a specification already mirrored, **When** its overview prose, success criteria or
   out-of-scope section changes and reconcile runs, **Then** the parent's description is updated
   in place and no artifact is created.
5. **Given** a reconcile run, **When** the parent cannot be created or its identity cannot be
   verified, **Then** no child is created for that specification, the run exits non-zero with a
   documented code, and the failure names the specification and the reason.
6. **Given** a first reconcile interrupted after the parent is created but before any child is,
   **When** reconcile runs again, **Then** the existing parent is recognised and reused and the
   children are created beneath it.
7. **Given** a mirrored specification, **When** a person opens the parent in Jira, **Then** they
   read complete sentences under named sections — never a paste of markdown, front-matter, or
   marker comments — and they reach the user stories through Jira's own child list, not through a
   list written into the description.
8. **Given** any of the above, **When** the same run is performed with the dry-run flag first,
   **Then** the predicted action set names the parent creation or reuse, every parent link, and
   the same set of writes the real run performs.

---

### User Story 3 - A missing mandatory field refuses the run instead of failing mid-write (Priority: P2)

An administrator has made a custom field mandatory on the parent issue type. The developer
reconciles. The run stops before touching Jira and says which issue type requires which fields,
by the names the operator sees in Jira, and what to do about it. No half-built hierarchy is left
behind and no generic transport error is shown.

**Why this priority**: Mandatory custom fields are common in the enterprise projects this bridge
targets, and this is the difference between a clear refusal and an opaque failure that leaves an
orphan parent in the project. It is P2 rather than P1 because a project with no mandatory extras —
the case at the single consumer today — is fully served by User Story 2.

**Independent Test**: Reconcile against a fixture whose parent-level issue type declares a
mandatory custom field the bridge cannot supply. Assert zero write calls were issued, the exit
code is the documented one, and the message names the issue type and the field.

**Acceptance Scenarios**:

1. **Given** a project whose parent issue type declares a mandatory field the bridge cannot
   satisfy, **When** reconcile runs, **Then** zero writes are issued, the run exits non-zero with
   a documented code, and the message names the issue type, the field by its Jira name, and a
   remediation the operator can act on.
2. **Given** the same project, **When** reconcile runs in dry-run, **Then** the report predicts
   the refusal, naming the same issue type and fields, and predicts no writes.
3. **Given** a project whose child issue type declares such a field, **When** reconcile runs,
   **Then** the same refusal occurs — the check covers every issue type the run would write to,
   not only the parent.
4. **Given** a project whose mandatory fields are all satisfiable from what the bridge knows,
   **When** reconcile runs, **Then** the run proceeds normally and no refusal is reported.
5. **Given** any refusal under this story, **When** the operator reads the run summary, **Then**
   the failure is a named mandatory-field refusal, never a generic transport or rejected-request
   error.

---

### User Story 4 - Configuration carries no key without a consumer (Priority: P2)

A tech lead opens their committed team configuration. Every key present changes something. The
three keys that never did — the epic strategy, the task strategy, and the link type that existed
only to serve the task strategy — are gone, from the configuration template, the configuration
ceremony, the validation layer, the neutral interchange document, both implementations, and the
conformance fixtures. A configuration that still declares one of them is refused by name, so no
consumer carries a stale key silently into rollout.

**Why this priority**: It is a rollout-window constraint rather than a functional one. The
committed configuration format can be changed for free while one consumer project exists; the day
a second team installs the extension, the same change becomes a coordinated migration across every
consumer repository. It is grouped at P2 because it must ship in the same release as User Story 2,
which also changes a committed file format.

**Independent Test**: Remove the three keys from a configuration and reconcile: the run behaves
identically to a run with them present did before. Put one key back and assert the run refuses by
name with exit 4. Search both implementations, the templates, the documentation and the
conformance fixtures for the three key names and find none outside the retirement rule itself.

**Acceptance Scenarios**:

1. **Given** a team configuration declaring none of the three removed keys, **When** the
   configuration is validated, **Then** it is accepted and no key is reported missing.
2. **Given** the neutral interchange document produced by any reconcile, **When** it is
   inspected, **Then** it carries no epic strategy field and the schema does not require one.
3. **Given** a team configuration that still declares a retired key, **When** the configuration is
   loaded by a direct invocation, **Then** the run is refused with exit 4 and the message names
   the retired key, the project entry it sits in, and the file to edit.
4. **Given** that same configuration, **When** the run happens inside a lifecycle hook, **Then**
   the same refusal is emitted as a single WARNING line, the run returns success, and the host
   spec-kit command's outcome is untouched.
5. **Given** both implementations, **When** the same reconcile is run through each, **Then** the
   neutral documents, the run summaries and the Jira call sequences are byte-identical, with the
   removal and the retirement rule applied to both in the same change.

---

### User Story 5 - The implementation plan is readable on the parent (Priority: P3)

After planning, the parent artifact also carries the implementation plan, written as prose under
its own named section. Re-planning replaces that section in place; it is never appended a second
time.

**Why this priority**: It is genuinely valuable — the plan is the context a Product Owner or QA
lacks most — but the hierarchy has to exist before anything can be carried on it, and the plan is
not currently read by any part of the bridge except the hook-registration script, so this is new
ingestion work rather than a re-wiring.

**Independent Test**: Reconcile a specification whose feature folder holds an implementation plan.
Assert the parent's description contains a named plan section rendered as prose. Change one
sentence of the plan, reconcile, and assert the section is replaced rather than duplicated and
that the rest of the parent's description is unchanged.

**Acceptance Scenarios**:

1. **Given** a feature folder containing an implementation plan, **When** reconcile runs, **Then**
   the parent's description carries the plan under its own named section, as prose.
2. **Given** the plan changed since the last run, **When** reconcile runs, **Then** the plan
   section is replaced in place and appears exactly once.
3. **Given** the plan unchanged since the last run, **When** reconcile runs, **Then** no write is
   issued to the parent.
4. **Given** a feature folder with no implementation plan, **When** reconcile runs, **Then** the
   parent is created or updated normally with no plan section and no warning.

---

### Edge Cases

- **A project with no level above the child level.** A team-managed project offering only one
  non-sub-task level cannot host a parent above its stories. The run fails closed before any
  write, names the project, and states that it offers no parent-level type. It never falls back.
- **A project offering several candidate parent levels.** Two or more non-sub-task types share the
  lowest level above the child level, so the derivation has no single answer. The run fails
  closed, names every candidate, and states that the project needs an explicit choice. This is the
  signal — and the only signal — that the configuration key recorded in Out of Scope has become
  necessary.
- **The parent's recorded identifier names a ticket that no longer exists.** Jira returned "not
  found" for a key the specification records. The specification's record is stale, not the run:
  the parent is re-created and the record replaced, and the event appears in the run summary.
- **The parent's recorded identifier names a ticket claimed by a different specification.** The
  identity marker on the ticket names another specification. This blocks the whole specification
  closed — no child is created — because every child would otherwise be attached to the wrong
  parent.
- **The parent's ticket exists but carries no identity marker, or a malformed one.** Treated as
  unverifiable: the specification fails closed rather than adopting an unrecognised ticket.
- **A specification with no user-story sections.** The parser already synthesises one implicit
  story. The hierarchy is one parent and one child, not a parent alone.
- **A child already exists but is attached to the wrong parent, or to none.** The child's parent
  reference is reconciled to the correct parent; this counts as a write and must therefore not
  occur on an unchanged second run.
- **A read failure while verifying the parent.** Never downgraded to "no parent exists". An
  inconclusive read fails the whole specification closed.
- **Two specifications in the same repository routed to the same project.** Each keeps its own
  parent; neither adopts the other's.
- **A parent whose description a human has edited in Jira.** The bridge-owned region is
  reconciled and the human-authored prose outside it is preserved, exactly as it is for a story
  today.
- **A run interrupted between the parent's creation and the recording of its identifier.** The
  next run must not create a second parent.
- **A specification whose prose contains a known credential coordinate.** The parent's payload is
  blocked by the pre-write guard, and because the parent blocks, no child is written either.
- **A configuration declaring a retired key inside a lifecycle hook.** The refusal is real but
  non-blocking: one WARNING line, success returned, the host command untouched.

## Requirements *(mandatory)*

### Functional Requirements

#### Hierarchy resolution

- **FR-001**: The bridge MUST resolve the issue type used for child issues in two steps — a
  logical name recorded in the project's binding, resolved to an identifier through that same
  binding — and MUST NOT resolve it by any issue-type name compiled into the bridge. The
  project's discovered hierarchy identifies the LEVEL the child sits at; it cannot identify the
  TYPE, because Jira's base level holds several non-sub-task types in nearly every project. The
  logical name is recorded at configuration time: derived when the level holds a single
  candidate, and answered by the operator when it holds several. See plan research R1 and R2.
- **FR-001a**: When the child-level issue type cannot be resolved — the binding records none, or
  it cannot be resolved for any other reason — the run MUST fail closed before any write, naming
  the project and the level, and directing the operator to the configuration ceremony. This is the
  single requirement behind the contract's `child-type-unresolved` refusal; an earlier draft split
  it across two requirements saying the same thing.
- **FR-002**: The bridge MUST derive the issue type used for the parent artifact as the single
  non-sub-task issue type occupying the lowest hierarchy level strictly above the child level. It
  MUST NOT resolve it by any issue-type name compiled into the bridge, and MUST NOT read it from
  any configuration key.
- **FR-003**: The persisted project binding MUST retain, for every discovered issue type, the
  information needed to resolve it by hierarchy — at minimum its level and whether it is a
  sub-task type — so that the reconcile path never has to re-derive it or guess.
- **FR-003a**: A binding written before this feature carries no hierarchy information. Reconcile
  MUST detect that shape explicitly and refuse with a message that says the binding predates
  parent support and directs the operator to re-run the configuration ceremony. It MUST NOT be
  reported as an unbound project, and it MUST NOT resolve to an empty issue type that fails later
  and less legibly. This is the state every existing installation — including the maintainer's own
  machine — is in on the first run after the change, so it MUST be covered by a test rather than
  by a release note.
- **FR-003b**: Every issue-type logical name the binding carries MUST round-trip byte for byte,
  whatever its script or punctuation, and a name the reader cannot unescape MUST refuse with the
  located, redacted diagnostic rather than truncating the document. This does NOT follow from the
  fix already shipped in feature 007: that fix hardened mapping **keys**, and this feature moves
  the logical name out of the key position into a value (`logical_name: Récit`) inside a list of
  objects. The same write-quoting and fail-closed read discipline MUST be extended to the new
  shape, and to `child_type.logical_name`, `parent_type.logical_name` and every
  `required_fields[].logical_name`. The bridge MUST NOT parse, translate, normalise, case-fold or
  pattern-match a type or field name in any language: it is opaque text carried from Jira to the
  binding to the diagnostic.
- **FR-004**: The CARDINALITY of the mapping MUST NOT be configurable: one specification always
  maps to exactly one parent artifact. The LEVEL follows the project's own hierarchy and is
  likewise never declared by an operator in this feature.
- **FR-005**: When the project offers no non-sub-task issue type above the child level, the run
  MUST fail closed before any write, naming the project and stating that it offers no parent-level
  type. It MUST NOT fall back to the child level, to a sub-task type, or to any other type.
- **FR-006**: When two or more non-sub-task issue types share the lowest hierarchy level above the
  child level, the derivation is ambiguous and the run MUST fail closed before any write, naming
  every candidate type and stating that the project needs an explicit choice. The bridge MUST NOT
  select one of them.
*(FR-007 was a restatement of FR-001a — same trigger, same refusal, same diagnostic — and has been
merged into it. The number is retired rather than reused, so existing references stay unambiguous.)*

#### The parent artifact

- **FR-008**: A reconcile MUST create exactly one parent artifact per specification, in the
  project the specification routes to.
- **FR-009**: Every user story of a specification MUST be created as a child of that
  specification's parent artifact.
- **FR-010**: The parent MUST carry the specification rendered for a human reader: the overview
  prose, the success criteria, and the out-of-scope boundaries, each under its own named section,
  in complete sentences. It MUST NOT contain raw markdown, front-matter, or marker comments.
- **FR-011**: The parent's description MUST NOT contain a list of the specification's user
  stories. Jira renders the children under the parent natively, and a list written into the
  description could only be produced after the children exist — forcing a second write to the
  parent on the very first run and on every run that adds or removes a story, which FR-013 and
  FR-034 forbid.
- **FR-012**: When the parent cannot be created, or its identity cannot be verified, NO child
  MUST be created for that specification.
- **FR-013**: A parent whose bridge-owned content already matches the specification MUST NOT be
  written to.

#### Recognition

- **FR-014**: The bridge MUST record a durable identifier for the parent artifact in the
  specification file, using the same marker grammar and byte-preserving write discipline the story
  identifier already uses.
- **FR-015**: The bridge MUST stamp its identity marker on the parent artifact it creates, and
  that marker MUST distinguish a parent artifact from a story ticket of the same specification.
- **FR-016**: On every run the bridge MUST read the recorded parent by its recorded key — never by
  search — and verify its identity marker before deciding to reuse or create.
- **FR-017**: A parent read that is inconclusive (authentication failure, network error, exhausted
  retries) MUST fail the whole specification closed and MUST NOT be treated as "no parent exists".
- **FR-018**: A recorded parent that Jira reports as absent MUST be re-created, the record
  replaced, and the event reported in the run summary.
- **FR-019**: A recorded parent whose identity marker names a different specification, or whose
  marker is missing or malformed, MUST block that specification closed with a named warning.
- **FR-020**: The parent's identifier MUST be marked as in-flight before its creation and replaced
  with the recorded key immediately after, so a run interrupted between the two never causes a
  second parent to be created.

#### Mandatory fields

- **FR-021**: Discovery MUST capture the create-time field schema for every issue type the bridge
  writes to — at minimum the parent level and the child level — and not for one arbitrary type.
- **FR-022**: Discovery MUST record, per issue type, which fields Jira marks as required on
  creation, identified by their logical name wherever Jira supplies one.
- **FR-023**: When a required field cannot be satisfied from what the bridge knows, the run MUST
  fail closed BEFORE any write, naming the issue type, the fields concerned, and a remediation.
- **FR-024**: A mandatory-field refusal MUST be reported as such and MUST NOT surface as a generic
  transport or rejected-request error.
- **FR-025**: The dry-run report MUST predict a mandatory-field refusal exactly, naming the same
  issue type and fields as the real run.

#### The implementation plan

- **FR-026**: When the feature folder contains an implementation plan, its content MUST be carried
  onto the parent artifact, rendered as prose under its own named section.
- **FR-027**: A later run MUST replace that section in place; the plan MUST NEVER be appended a
  second time.
- **FR-028**: A feature folder with no implementation plan MUST reconcile normally, with no plan
  section and no warning.

#### Configuration

- **FR-029**: The `epic_strategy` key MUST be removed from the configuration template, the
  configuration ceremony, the configuration validation layer, the plan context, the neutral
  interchange document and its schema, both implementations, and every conformance fixture.
- **FR-030**: The `task_strategy` key and the `link_type` key that exists solely to serve it MUST
  be removed from the same places, in the same change.
- **FR-030a**: The stray `projects[].issue_types` map MUST be deleted from the conformance
  fixture that declares it, and MUST NOT be reserved as a slot for a future committable switch.
  It is a logical-name-to-IDENTIFIER map, and identifiers belong in the gitignored binding
  (Constitution V) — the future switch declares a logical NAME. It is also not part of the
  shipped configuration template, so no consumer's committed file contains it and deleting it
  costs no edit anywhere but the fixture.
- **FR-031**: A team configuration that still declares a retired key MUST be refused with the
  configuration exit code, naming the retired key, the project entry it sits in, and the file to
  edit. Deleting the three validation rules alone does NOT produce this behaviour: the validator
  rejects unknown keys at the top level only and applies no unknown-key check inside project
  entries, so an explicit retirement rule is required in both implementations.
- **FR-032**: Inside a lifecycle hook that refusal MUST be emitted as a single WARNING line and
  MUST return success, leaving the host spec-kit command's outcome untouched, while a direct
  invocation MUST return the configuration exit code. This is the behaviour of the existing fault
  path and requires no new branch.

#### Cross-cutting

- **FR-033**: The dry-run report MUST predict the parent creation or reuse, every parent link, and
  every write the real run performs, exactly.
- **FR-034**: A second run against an unchanged specification MUST issue zero writes of every
  kind — created, updated, transitioned, commented, linked, labeled — the parent included.
- **FR-035**: Both implementations MUST change in the same commit and MUST produce byte-identical
  neutral documents, run summaries and Jira call sequences for the same input.
- **FR-036**: Every payload written for a parent artifact MUST pass through the existing pre-write
  privacy guard before any write, on the same terms as a story payload.

### Key Entities

- **Parent artifact**: the single Jira issue representing one specification. It sits at the level
  the project's hierarchy puts immediately above its stories, carries the specification rendered
  for a human, holds the bridge's identity marker, and is the parent of every child issue for that
  specification.
- **Parent identifier**: the durable, opaque identifier the bridge generates for a specification's
  parent and records in the specification file. It is the key by which the parent is recognised on
  every later run. Its lifecycle mirrors the story identifier's: assigned, in-flight during
  creation, then bound to a ticket key.
- **Identity marker**: the bridge-owned record stored on a Jira issue naming its origin, its
  repository, its specification, and — for a story ticket — its story identifier. It gains a way
  to say "this issue is the parent of this specification".
- **Hierarchy binding**: the persisted, per-project table of the project's own issue types
  carrying, for each, its identifier, its level in the hierarchy, and whether it is a sub-task
  type. It is what makes level-based derivation possible without re-querying Jira.
- **Required-field schema**: the per-issue-type record of which fields Jira marks required at
  creation, by logical name, captured during discovery for every type the bridge writes to.
- **Retired configuration key**: a key the extension once accepted and no longer does. The
  validator knows the three by name so it can refuse them with a message that says what to delete,
  rather than ignoring them silently.
- **Neutral interchange document**: the validated, Jira-free document crossing from the engine to
  the sink. It loses its epic strategy field and gains whatever the parent needs that it does not
  already carry.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | The specification on disk remains the reference; the parent is a derived mirror of it. This feature issues no delete and adopts no human-created ticket: FR-019 blocks, rather than adopts, a parent whose marker names another specification or is malformed. Drift on the parent is reported through the existing named-warning path before any overwrite. |
| II | Zero-Churn Idempotency | FR-013, FR-034 and User Story 2 scenario 2 require a second run against an unchanged specification to issue zero writes of every kind, the parent included. FR-011 removes the one description element that could not satisfy this — a user-story list, which would have to be written after the children exist and rewritten whenever the set changes. FR-014 to FR-016 make the parent's identity rest on a recorded identifier and a server-side marker, never on its summary or any editable display name. The zero-write assertion list is extended to cover the parent link, since attaching a child to a parent is a write kind the sink now performs. Live verification against a real instance is required; mocks alone are explicitly not sufficient. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-001a, FR-005, FR-006, FR-012, FR-017, FR-019 and FR-023 each specify zero writes and a documented non-zero exit. FR-012 is the strongest form: a story is never orphaned by a half-built hierarchy. FR-032 is the principle's other half, stated explicitly: the same configuration refusal that exits non-zero on a direct invocation becomes one WARNING and a success return inside a hook, so no bridge fault can fail its host command. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | No credential is introduced, read, or persisted. FR-036 routes every parent payload through the existing pre-write privacy guard on the same terms as a story payload, so a leak in the specification's prose blocks the parent write exactly as it blocks a story write. The fixtures added for the non-default and mandatory-field cases carry invented type names and field identifiers only. |
| V | Separation of Team Config / Local Binding / Secrets | This feature adds nothing to the committable layer, removes three keys from it (FR-029, FR-030) and deletes a fourth, fixture-only stray (FR-030a). The hierarchy binding of FR-003 — resolved identifiers and levels — is machine-owned and belongs in the gitignored local binding, where the resolved-identifier table already lives. The deleted `projects[].issue_types` map is the counter-example proving the boundary: it held resolved identifiers in the committable layer, and its committed value already disagreed with the binding's. No configuration moves inside the extension folder. |
| VI | macOS / Linux / Windows Portability | FR-035 requires both implementations to change in the same commit and stay byte-identical. Removing the strategy keys touches the neutral document schema, so it crosses the engine, both sinks, the configuration layer and the conformance scenarios; it is planned as its own task rather than a one-line edit. FR-031 requires the retirement rule in both ports for the same reason. The parent identifier is generated through the existing deterministic-identifier seam, which is what keeps the two ports byte-identical under the conformance gate. The byte-identical requirement now covers diagnostics that interpolate a project's own type names, so both ports MUST emit non-ASCII names in the same encoding — the case FR-003b's non-Latin fixture exercises across the three-OS matrix, Windows PowerShell output included. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | This is the principle the feature exists to restore. FR-001 and FR-002 forbid resolving either level by a compiled-in type name: the parent's type is derived from the project's reported hierarchy, and the child's is resolved in two steps through a recorded logical name — the shape this principle prescribes and `priority_map` already uses. FR-022 names required fields by their logical name. User Story 1 requires a Latin-diacritic fixture, a non-Latin-script fixture and a SAFe fixture to all work with no code change; its scenario 6 makes the absence of Atlassian literals an explicit assertion, and its scenario 7 with FR-003b makes the absence of any language assumption one too — a type name is opaque text the bridge never parses, translates, normalises or matches. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | The parent artifact is a neutral concept — a title, description blocks, and an opaque identifier — and stays in the engine. Everything Jira-specific — hierarchy levels, type identifiers, the parent reference on a creation payload, the required-field schema, the rich-text rendering — stays in the sink. The neutral document remains the only object crossing the boundary and is still validated before any write. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unchanged in behaviour, extended in reach: FR-036 subjects the parent's payload to the same two-tier scan and the same allowlist. Because the parent carries more of the specification than a story does, the guard now sees more text — which is the point, not a regression. |
| X | Self-Healing Automatic Mirror | Unaffected in its own mechanics. FR-032 respects the boundary it depends on: the hook path continues to warn and return success, so a retired key or an ambiguous hierarchy can never fail a lifecycle command. |
| XI | Universal Dry-Run and Auditability | FR-025 and FR-033 require the dry-run report to predict the parent creation or reuse, every parent link and every mandatory-field refusal exactly. FR-018 requires a re-created parent to appear in the run summary. The guarded destructive re-mode is unaffected; note that removing the strategy keys removes one of the mapping-shape changes that re-mode is described as following, which is a documentation consequence, not a behavioural one. |
| XII | Quality and Catalog Publication | The feature ships with a CHANGELOG entry and a version bump, runs the full suite on all three operating systems, and — per Principle II — is dogfooded against a real Jira instance before release, which is also where the live idempotency proof of FR-034 is obtained. |
| XIII | TDD With a Minimum 80% Coverage | Tests come first, including the two fixtures this feature specifically requires: one whose issue types are not the Atlassian defaults, and one whose parent type declares a mandatory custom field. Two further fixtures cover the derivation refusals of FR-005 and FR-006. The three defects repaired here — literal type lookup, the hierarchy dropped at persistence, and create metadata read for one type only — each get a regression test written before its fix, per the repository's bug-fix policy. FR-003a gets one too: a binding written by the current code is the state every existing installation is in on its first run after the change, so its refusal is tested rather than release-noted. Recognition of the parent, being a critical path alongside idempotency and fail-closed, targets coverage close to 100%. Tests identify what they observe by identifiers they recorded, never by machine-wide scan. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | The parent reuses the existing identifier, marker, recognition, rendering, fault and privacy machinery rather than introducing a parallel mechanism; the work is largely generalisation, not new structure. FR-011 removes a description element rather than engineering a way to keep it correct. No new abstraction layer and no new external dependency is introduced. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | The feature's own removals are the proof: three configuration keys with no consumer are deleted rather than tolerated, the retirement rule of FR-031 exists precisely so their absence is enforced rather than assumed, and a fourth, fixture-only stray is deleted rather than reserved (FR-030a) — reserving a slot for a key nobody has yet is exactly what this principle forbids. No key is added to the committable layer: the parent's type is derived (FR-002) and the child's is an operator answer in the machine-owned binding (FR-001). Both deferred keys sit in Out of Scope with their triggers written down, the parent-type key conditionally and the child-type switch on a date. No key for mandatory-field VALUES is added — this feature only detects and refuses. |
| XVI | Human Readable — Readable by a Human Above All | FR-010 requires the parent to read as prose under named sections, never a paste of markdown or front-matter; FR-005, FR-006, FR-019, FR-023 and FR-031 require every refusal to name the artifact, the field, the level or the key, plus an actionable remediation — FR-031 goes as far as naming the file to edit. FR-022 names required fields by the logical names the operator sees in Jira. One consequence to record: the constitution's own illustration of a business-language configuration key is `epic_strategy: per_feature`, which FR-029 deletes. That illustration becomes stale and should be replaced by a patch-level amendment to the constitution, handled separately — this specification does not dilute the principle, it flags the example. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A Product Owner opening the mirrored project can, from a single artifact and without
  opening the repository, read what the feature is, what "done" means for it, and what it
  excludes, and can reach every one of its user stories through Jira's own child list.
- **SC-002**: Reconciling a three-user-story specification into an empty project produces exactly
  four issues — one parent and three children — and every child names the parent.
- **SC-003**: A second reconcile of an unchanged specification produces zero created, zero
  updated, zero transitioned, zero commented, zero linked and zero labeled, verified against a
  real Jira instance and not only against a mock.
- **SC-004**: The same specification mirrors correctly into projects whose issue types are named
  in any language and any script — including one Latin-with-diacritics fixture, one non-Latin
  fixture (Cyrillic or CJK), and one using a Capability / Feature / Story hierarchy — with no
  change to the bridge's code and no configuration difference between the runs. The language of a
  Jira instance is never a dimension the bridge is written against; it is data the fixtures vary.
- **SC-005**: A project with no level above its stories, and a project with two candidates for the
  level above its stories, each refuse before any write with a message naming the project and, in
  the ambiguous case, every candidate type.
- **SC-006**: When an issue type the run would write to declares a mandatory field the bridge
  cannot supply, the run performs zero write calls and its message names the issue type and every
  field concerned.
- **SC-007**: For every scenario in this specification, the dry-run report and the real run
  describe the same set of actions.
- **SC-008**: A configuration declaring a retired key is refused by name with the configuration
  exit code on a direct invocation, and produces one WARNING with a success return inside a hook.
  A search of both implementations, the templates and the documentation for the three removed keys
  returns nothing outside the retirement rule.
- **SC-009**: An operator interrupting a first reconcile at any point and running it again never
  ends with two parents. Where the interruption left the record conclusive, the second run
  completes the hierarchy — exactly one parent and one child per user story. Where it left the
  record inconclusive — the window between the creation request and the recording of its key — the
  second run refuses that specification by name with zero writes and states how to resolve it by
  hand, rather than guessing whether a parent exists.
- **SC-010**: Every functional requirement in this specification is exercised by at least one
  automated scenario, and both implementations pass the shared conformance suite with identical
  output bytes.

## Assumptions

- **The parent is an ordinary issue at an ordinary hierarchy level.** It is created through the
  same creation path as a child, differing only in its issue type and in carrying no parent of its
  own. No Jira-specific epic-link mechanism beyond the ordinary parent reference is assumed.
- **The child level is the lowest non-sub-task level.** Sub-task types are excluded from
  consideration at both levels; sub-task creation is out of scope.
- **A Scrum project derives an Epic parent and a SAFe project derives a Feature parent.** In a
  default Scrum project Epic is the only non-sub-task level above Story; in a SAFe project Feature
  sits between Story and Epic. The derivation of FR-002 therefore produces the level each
  methodology expects without anyone declaring it, which is why no key is needed yet.
- **The parent's marker lives in the specification file, near its top.** The natural placement is
  immediately after the document's title, mirroring the convention the implicit-story marker
  already follows. It is written through the same byte-preserving splice, so no other byte of the
  file changes.
- **The parent's summary is the specification's title.** The parser already derives this through
  the deterministic title ladder and already carries it in the neutral document.
- **The existing epic description is a starting point, not the answer.** Verified: the parser
  currently puts at most the first two paragraphs of overview prose preceding the first
  Acceptance, Design, Task, Scenario, Requirement, Success or Edge heading into the epic's
  description — falling back to the title, then to a fixed sentence. Carrying the success criteria
  and the out-of-scope boundaries onto the parent therefore requires extending what the parser
  extracts.
- **What stays on each story is what is on it today.** Its own description, its Gherkin acceptance
  criteria panel, its design section, its priority and its estimation stay on the child issue.
  Nothing is moved off a story onto the parent; the parent gains material the stories never
  carried.
- **The single consumer project can be re-run from a clean state.** No mirror created by the
  current flat behaviour needs to be converted.
- **The hierarchy binding is refreshed by re-running the configuration ceremony.** An operator
  whose local binding predates this feature re-runs it once; the run reports what it discovered.
- **Removing `task_strategy` removes `link_type` with it.** Verified: `link_type` has no consumer
  other than the validation rule that requires it when `task_strategy` takes one particular value.
  Leaving it would leave a second orphan behind, so the instruction to remove a second dead key is
  applied to a third.
- **The extension's own specifications are consumers too.** This repository dogfoods the bridge on
  its own `specs/` folder, so the new parent marker will appear in its own specification files as
  well as in the consumer's.

## Out of Scope

- **A configuration key naming the parent's issue type.** The parent's type is derived (FR-002).
  When a project makes the derivation ambiguous, FR-006 refuses and names the candidates; that
  refusal firing at a real consumer is the event that makes the key necessary, and until then
  shipping it would be speculative. It is recorded here and not in the schema.
- **Migrating existing flat mirrors.** A single consumer project exists today, used for testing
  ahead of rollout. Tickets already created without a parent are not converted, re-parented, or
  detected. The consumer re-runs from a clean state.
- **Supplying values for mandatory custom fields.** This feature detects them and refuses cleanly.
  The configuration surface that lets an operator declare values, the ranked proposal of sensible
  defaults, and the interactive recommendation during the configuration ceremony are a separate
  feature. No configuration key for field values is added here.
- **Ingesting the task list and creating sub-tasks.**
- **The committable Story-versus-Task switch — deferred to the release immediately before
  rollout, not to an unspecified later.** In this feature the child issue type is resolved from
  the *gitignored* local binding: derived when the child level holds one candidate, and answered
  once by the operator when it holds several (FR-001). That is the right call for the committed
  format, which stays untouched, but it carries a divergence risk that must be written down
  rather than discovered.

  Unlike `style`, which is an objective property of the Jira project and yields the same answer
  for everybody, the child issue type is a **team preference**: in a project offering both,
  `Story` and `Defect` are each a legitimate answer. Because `config.local.yml` is gitignored,
  every developer answers independently, so two developers on the same repository can mirror new
  specifications into the same Jira project as different issue types. Nothing breaks — each
  mirror is internally consistent and idempotent — but the project's backlog becomes
  inconsistent, and the inconsistency is invisible until someone reads the issue types.

  The committable key is therefore **required before the extension is rolled out to a second
  team**, which is the moment the risk becomes real. It is purely additive: a project entry
  declaring the key uses it, and one that does not falls back to the local answer exactly as
  today. It costs no migration and breaks no existing configuration — the cost of deferring it is
  inconsistency at rollout, not breakage.

  The parent-type key listed at the top of this section is on the same footing, with a narrower
  trigger: the FR-006 ambiguity refusal firing at a real consumer.
- **A general unknown-key check inside project entries.** FR-031 names the three retired keys
  specifically. Rejecting every unrecognised project-level key is a broader change with its own
  blast radius and no functional requirement demanding it here. The stray `projects[].issue_types`
  map described in FR-030a is the concrete evidence that this check is the right next piece of
  work, and it is the reason that item is recorded here rather than left unnamed.
- **Retiring or cancelling tickets for user stories removed from the specification.**
- **Amending the constitution's illustrative example of a business-language configuration key**,
  which this feature makes stale. Recorded under Constitution Check XVI; handled as a separate
  patch-level amendment.

## Clarifications

### Session 2026-07-31

- **Q**: How is the parent's hierarchy level chosen — a committable configuration key, or derived
  from discovery alone? → **A**: Derived only, with two fail-closed rules, following the precedent
  the style detection already sets (on an absent or contradictory signal it prints nothing and
  never substitutes a default). No parent-level type above the child level, or several types
  sharing the lowest level above it, each refuse before any write and name what they found. The
  second refusal is the signal that a configuration key has become necessary; until it fires at a
  real consumer the key would be speculative, so it is recorded in Out of Scope rather than added
  to the schema. Captured in FR-002, FR-004, FR-005 and FR-006.

- **Q**: Which sections of the specification does the parent carry? → **A**: The overview prose,
  the success criteria and the out-of-scope boundaries, each under its own named section — and
  **no list of user stories**. Jira renders the children under the parent natively, so the list
  would be a duplicate; and because the parent is created before its children exist (a child is
  never created without its parent), a list derived from the recognised child set could only be
  written by a second write to the parent on the first run, and again whenever a story is added or
  removed. Dropping it keeps the parent honest and keeps the second run at zero writes. Captured
  in FR-010 and FR-011.

- **Q**: How is a configuration that still declares a removed key handled? → **A**: Refused with
  the configuration exit code, naming the retired key and the file to edit. The split between
  direct invocation and hook context needs no new code: the existing fault path already returns
  the mapped code on a direct invocation and downgrades to one WARNING with a success return under
  hook context. Note that the free-behaviour hypothesis does not hold — the validator rejects
  unknown keys at the top level only and applies no unknown-key check inside project entries, in
  either implementation, so deleting the three validation rules would silently accept the stale
  keys. An explicit retirement rule is required. Captured in FR-031 and FR-032.

### Session 2026-07-31 (post-planning sign-off)

Planning found that hierarchy level identifies the child's tier but not its type, because Jira's
base level holds several non-sub-task types in nearly every project — including this repository's
own company-managed fixture, where `Story` and `Defect` both sit at level 0. The resolution —
derive when the level is unambiguous, ask once at configuration time when it is not, and persist
the answer with its provenance in the gitignored binding, following the `style` / `style_source`
precedent — was signed off with two conditions, both recorded above:

- **The per-developer divergence risk is written down with a trigger, not left undated.** Unlike
  `style`, which is an objective property of the project, the child issue type is a team
  preference: `Story` and `Defect` are each legitimate. Because the binding is gitignored, every
  developer answers independently, so two developers can mirror into the same project as different
  issue types. Nothing breaks — the risk is backlog inconsistency, not failure — but the
  committable switch is therefore required before rollout to a second team. It is purely additive
  and costs no migration. Recorded in Out of Scope.
- **The stray `projects[].issue_types` map is settled deliberately rather than swept.** It is
  deleted, not reserved as a slot for the future switch: it maps logical names to identifiers,
  and identifiers belong in the gitignored binding, whereas the future switch declares a name.
  Because it is absent from the shipped configuration template, deleting it costs no edit to any
  consumer's committed file, so the "two edits where one would do" concern does not apply.
  Recorded in FR-030a.

Planning also confirmed that `config_resolved_ids_for` discards `hierarchy_level` and `subtask`
when writing the binding, so every existing installation — the maintainer's own machine included —
will hit the new code with a binding that lacks the fields. Recorded in FR-003a as an explicit,
distinctly-worded refusal that must be covered by a test rather than a release note.
