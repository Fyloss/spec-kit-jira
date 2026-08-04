# Feature Specification: A Recorded Field Default Is Sent in the Shape Its Field Accepts

**Feature Branch**: `fix/field-default-encoding`

**Created**: 2026-08-04

**Status**: Draft

**Input**: User description: "Bug: the values held in `field_defaults` are not serialised according to the
Jira field's declared type. `reconcile --accept-defaults` exits 2 and creates zero tickets, because a
default recorded for a single-select field is sent as a bare string and Jira rejects it. The type
information discovery already captured is thrown away between discovery and serialisation. Fix the
encoding at the point where the recorded label is joined to the field id, mirror it in the PowerShell
port, de-encapsulate the value shown in the confirmation question, stop reporting created tickets that
were never created, and consider validating a recorded value against the field's allowed values at
configuration time."

## Context — the defect this feature closes

Feature 011 gave operators a place to write down, once, the value the bridge should send for a field
Jira demands. Discovery does its half of the job correctly: for every defaultable field it records the
field's identifier, whether Jira requires it, the field's **declared type**, and — when Jira enumerates
them — its allowed values.

The declared type is then dropped. Everything downstream of discovery treats a recorded default as an
opaque scalar: the recorded value is joined to its field identifier, carried through planning as a bare
string, and merged verbatim into the creation payload. For a free-text field that is exactly right. For
a single-select field it is wrong in a way Jira refuses outright — a select-list field is only accepted
as a structured value naming which option was chosen, never as the option's label on its own.

The consequence is not a degraded mirror, it is no mirror at all. A project whose specification-role or
story-role issue type requires **one** single-select field cannot create a single ticket: the run exits
with a fail-closed status, zero tickets exist in Jira, and the specification file is left carrying
`creating` markers that no run will ever resolve. The operator has done nothing wrong — they recorded a
valid option, chosen from the very list discovery enumerated for them — and there is no value they could
have recorded instead that would have worked. A mandatory single-select is ordinary on a corporate Jira
instance, so for those projects feature 011 does not merely fall short, it never functions.

The existing rejection diagnostic is working as designed and is not the fix. It **translates** Jira's
refusal into one readable line per rejected field — it never corrects what was sent. The result today is
a clean, accurate, unactionable error message. The missing piece is the one fact discovery already holds:
this field is a select list, so send it the way a select list is sent.

Two further defects surfaced with it, both cheap to close here and both misleading in the same episode:

- The run summary reported two tickets **created** on a run where Jira created none. The tally is taken
  from the planned write actions, before any of them is attempted, so a fail-closed apply leaves the
  summary claiming work that did not happen. Principle XI requires a summary a human and CI can trust;
  today, on the failure path, it cannot be trusted.
- The consolidated confirmation question reads the value straight out of the resolved defaults. Once
  those values carry their wire shape, an operator would be asked to confirm a machine-shaped value
  instead of the words they typed.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A recorded default on a select-list field actually creates the ticket (Priority: P1)

An operator has bound a repository to a Jira project whose specification-role and story-role issue types
each require a single-select custom field, and whose specification-role type additionally requires a
free-text custom field. They ran the configuration ceremony, answered each closed question with one of
the options Jira enumerated, and committed the resulting team config. A developer then runs an ordinary
spec-kit command; the hook fires and the bridge creates the mirror.

Today that run dies on the first creation. After this change, each recorded value is sent in the shape
its own field accepts — the select-list answers as a structured option, the free-text answer as the plain
string it always was — the tickets are created, and the markers in the specification file resolve.

**Why this priority**: it is the whole defect. Without it, feature 011 delivers nothing at all to any
project with a mandatory select-list field, and the two other fixes in this spec are cosmetic
improvements on a run that cannot succeed.

**Independent Test**: bind a project whose written issue types require one single-select and one free-text
field, record a default for each, run the reconcile accepting the recorded values, and confirm both
tickets exist in Jira carrying those values, that the select field's value is the option the operator
recorded, and that the free-text field's value is unchanged from what was typed.

**Acceptance Scenarios**:

1. **Given** a recorded default on a field Jira declares as a single-select, **When** the bridge builds
   the creation payload for that issue type, **Then** the field carries a structured value naming the
   recorded option, and the creation is accepted.
2. **Given** a recorded default on a field Jira declares as free text, a number, or a date, **When** the
   bridge builds the creation payload, **Then** the field carries the recorded value exactly as recorded,
   byte for byte — this change alters nothing for fields that were already working.
3. **Given** one issue type carrying both a select-list default and a free-text default, **When** the
   creation payload is built, **Then** both fields appear in it, each in its own shape, in the same
   payload.
4. **Given** a recorded default on a field Jira declares as a named-entity field — a priority, a
   resolution, a version, a component, or a group — **When** the payload is built, **Then** the field
   carries a structured value naming the recorded entity by name.
5. **Given** a recorded default on a field Jira declares as a user field, **When** the payload is built,
   **Then** the field carries the recorded value exactly as recorded — no account shape is derived, and the
   payload for that field is byte-identical to today's.
6. **Given** an operator who has written a structured value into the team config by hand — because their
   field needs a shape the bridge does not derive — **When** the payload is built, **Then** that value is
   passed through untouched and is never wrapped a second time.
7. **Given** a recorded default whose field is unknown to discovery, or whose declared type discovery did
   not report, **When** the payload is built, **Then** the value is sent as recorded and the existing
   unresolved-entry and rejection diagnostics behave exactly as they do today.
8. **Given** the same recorded defaults on the same project, **When** the run is repeated on either
   supported platform, **Then** the payload produced is identical — the two ports encode a value the same
   way or the conformance corpus fails.

---

### User Story 2 - The confirmation question shows the value a human recorded (Priority: P2)

Before creating tickets whose type carries mandatory fields, the bridge asks the developer one
consolidated question naming each field and the value recorded for it. That value is read from the
resolved defaults — which, after User Story 1, hold the shape Jira wants rather than the words the
operator typed.

The question must keep speaking the operator's language: it names the option, the priority, or the account
that was recorded, never the structure the bridge will put on the wire. The developer is being asked to
approve a business decision, not to proofread a payload.

**Why this priority**: it ships with User Story 1 or it degrades it. It cannot precede it — there is no
wire shape to unwrap until the encoding exists — but leaving it undone turns a readable question into an
unreadable one and violates Principle XVI on the one surface an operator actually reads.

**Independent Test**: with a select-list default recorded and a creation pending, trigger the consolidated
question and confirm the field's recorded value is displayed as the plain option the operator recorded,
with no trace of the structure the bridge will send.

**Acceptance Scenarios**:

1. **Given** a pending creation on a type with a select-list default, **When** the consolidated question is
   built, **Then** the field's recorded value reads as the plain option the operator recorded.
2. **Given** a pending creation on a type with a free-text default, **When** the question is built, **Then**
   the displayed value is unchanged from today.
3. **Given** a pending creation on a required field with no recorded default, **When** the question is
   built, **Then** the field is still listed with no recorded value, exactly as today — this change alters
   which value is *shown*, never which fields are *asked about*.
4. **Given** an operator who overrides a select-list field's value in their answer, **When** the ticket is
   created, **Then** the overridden value is encoded by the same rules as a recorded one and the summary
   attributes it to the operator, as today.

---

### User Story 3 - The summary counts tickets Jira actually created (Priority: P2)

A developer reads a run summary — or CI parses it — to know what happened. Today the created tally is the
count of creations the run *planned*. On a run that fails closed partway, or fails on its very first
creation, the summary reports tickets that do not exist.

After this change the tally counts only creations Jira confirmed. A run that plans two creations and has
both refused reports zero created; a run that creates one and is refused on the second reports one. The
`--dry-run` report, which has no confirmations by definition, keeps predicting exactly the actions the real
run would attempt — Principle XI's dry-run equivalence is about the predicted **action set**, and that is
unchanged here.

**Why this priority**: an inaccurate count is how this whole episode was nearly missed — the summary said
two tickets had been created while Jira held none. It is a correctness defect in the one artifact CI
consumes, and it is independent of the encoding fix.

**Independent Test**: force the creation of a ticket to be refused by Jira, run the reconcile, and confirm
the summary reports zero created, a non-zero error status, and the refusal in its warnings.

**Acceptance Scenarios**:

1. **Given** a run whose planned creations are all refused by Jira, **When** the summary is produced,
   **Then** the created count is zero and the run's fail-closed status is unchanged.
2. **Given** a run that creates a parent successfully and is refused on its child, **When** the summary is
   produced, **Then** the created count is one.
3. **Given** a run in which every planned creation succeeds, **When** the summary is produced, **Then** the
   created count is what it is today — a fully successful run's summary is byte-for-byte unchanged.
4. **Given** a `--dry-run` invocation, **When** the report is produced, **Then** it predicts the same action
   set as the corresponding real run, exactly as today.

---

### User Story 4 - A value the field cannot accept is refused when it is recorded, not when it is sent (Priority: P3)

Discovery already enumerates a select-list field's allowed values, and the configuration ceremony already
asks about such a field as a closed question. But a default can also arrive by hand — an operator editing
the committable team config directly, or a value that was valid when recorded and has since been removed
from the list in Jira. Such a value survives until a hook fires in the middle of someone's work, and only
then produces a refusal.

The configuration ceremony should say so at the moment it inspects the config: the value recorded for this
field is not one it accepts, here are the values it does accept. It names the field and the accepted values
but never repeats the recorded value back — the operator is looking at the file that holds it, and a
recorded value is exactly the kind of string Principle IV keeps out of messages. The operator learns it
while they are looking at their configuration, not while they are trying to ship.

**Why this priority**: it converts a late failure into an early one, which is worth having, but the late
failure it prevents is already reported clearly and — once User Stories 1–3 ship — is no longer the common
case. It is the one slice of this spec that could be dropped without leaving a broken feature behind.

**Independent Test**: hand-edit a recorded default to a value outside its field's enumerated allowed values,
run the configuration ceremony, and confirm it names the field and the accepted values, never the offending
value itself, without writing the config.

**Acceptance Scenarios**:

1. **Given** a recorded default whose value is not among its field's enumerated allowed values, **When** the
   configuration ceremony runs, **Then** it refuses, naming the field by its Jira label and the values the
   field accepts, and the recorded value appears nowhere in the refusal.
2. **Given** a recorded default on a field for which Jira enumerates no allowed values, **When** the ceremony
   runs, **Then** no such check applies and the value is accepted — an absent list is not an empty one.
3. **Given** a ceremony run in degraded mode with no Jira read, **When** it runs, **Then** no allowed-value
   check happens at all — the list is a discovery result, never a guess.
4. **Given** a config in which every recorded default is valid, **When** the ceremony runs, **Then** the
   written config is byte-for-byte unchanged and the run is silent about allowed values.

---

### Edge Cases

- A recorded value that is already a structured value in the team config: passed through untouched, never
  wrapped twice. This is the escape hatch for a field shape the bridge does not derive.
- A recorded value that is a number, a boolean, or null rather than text: passed through untouched; the
  encoding rules apply to recorded text only.
- A field whose declared type discovery did not report, or reported as empty: no derivation is possible, so
  the value is sent as recorded and the run behaves exactly as it does today.
- A label that resolves to no known field, or a type name that resolves to no known issue type: unchanged —
  the entry is reported as unresolved and no encoding is attempted.
- A field declared as a shape that cannot be a single recorded value at all (a multi-select, a checkbox
  group, an issue link): unchanged — discovery already marks it non-defaultable with a readable reason and
  no default can be recorded for it.
- An operator's this-run override of a select-list field: encoded by the same rules as a recorded default,
  so a confirmed run and an overridden run put the same shape on the wire.
- A run that is refused on its very first creation: the summary reports zero created, not the number of
  creations that were planned.
- A creation that Jira accepts and a subsequent identity stamp that fails: the ticket exists, so it counts
  as created; the stamping failure surfaces through its own existing diagnostic.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: When the bridge resolves a recorded field default (or a this-run answer) to the field it
  belongs to, it MUST derive the value's outgoing shape from the field's declared type as reported by
  discovery, rather than sending the recorded scalar unchanged.
- **FR-002**: A recorded text value on a field declared as a select list MUST be sent as a structured value
  naming the chosen option.
- **FR-003**: A recorded text value on a field declared as a named entity — priority, resolution, version,
  component, or group — MUST be sent as a structured value naming that entity by name.
- **FR-004**: A recorded text value on a field declared as a user MUST be sent exactly as recorded. No
  structured shape is derived for a user field. Jira accepts such a field only as an account identifier,
  and an account identifier may not be recorded: the team config is committable, and Principle IV forbids
  an accountId in any tracked file, test fixtures included. Deriving the shape without the identifier would
  put a display name under an account key, which Jira refuses exactly as it refuses the bare string today —
  so the derivation would buy nothing and cost a principle. Resolving a recorded name to an account is a
  separate capability requiring its own Jira lookup; it is specified as feature 016, which closes this gap
  by keeping the name in the committable config and the account in the gitignored local binding.
- **FR-005**: A recorded text value on any other declared type — free text, number, date, date-time,
  unconstrained, or a type the bridge has no rule for — MUST be sent exactly as recorded.
- **FR-006**: A recorded value that is not text MUST be sent exactly as recorded, with no shape derived and
  no wrapping applied, so that an operator who states a structured value by hand is obeyed literally.
- **FR-007**: A recorded value whose field or whose declared type cannot be determined MUST be sent exactly
  as recorded, and MUST continue to produce today's unresolved-entry and rejection diagnostics unchanged.
- **FR-008**: The encoding MUST be applied once, at a single point on the path from recorded value to
  creation payload, so that both creation paths — the hook-driven reconcile and the planned write — put the
  same shape on the wire for the same recorded value.
- **FR-009**: The consolidated confirmation question MUST present a field's recorded value as the plain
  value the operator recorded, never as the structure the bridge will send.
- **FR-010**: The confirmation question MUST continue to include exactly the fields it includes today — a
  field about to be sent, or a required field with nothing to send — with only the *rendering* of a value
  changed.
- **FR-011**: The run summary's created count MUST count only ticket creations Jira confirmed, never
  creations that were merely planned.
- **FR-012**: A `--dry-run` report MUST continue to predict exactly the action set the corresponding real
  run would attempt.
- **FR-013**: A fully successful run's summary MUST be byte-for-byte identical to today's, so that no
  consumer of the summary is disturbed by this change.
- **FR-014**: The configuration ceremony MUST refuse a recorded default whose value is absent from its
  field's enumerated allowed values, naming the field by its Jira label and the values the field accepts.
  The refusal MUST NOT echo the recorded value, in its message or in any structured output — a recorded
  value can carry a credential-shaped string, and Principle IV's suppression applies to this refusal as it
  already does to the equivalent refusal on the `--field-default` flag path. The operator is looking at the
  file that holds the value; naming the field and the accepted values locates it unambiguously.
- **FR-015**: The allowed-value check MUST apply only where discovery enumerated a non-empty list of allowed
  values for that field, and MUST NOT apply in the ceremony's degraded mode where no Jira read happened.
- **FR-016**: Both ports — Bash for macOS/Linux and PowerShell for Windows — MUST implement every requirement
  above and MUST produce byte-identical output, proven by the shared conformance corpus.
- **FR-017**: A regression test MUST cover one issue type carrying both a select-list default and a free-text
  default, asserting the exact shape of the resulting creation payload, and MUST fail against the current
  behaviour.
- **FR-018**: Every message this feature introduces MUST name a field by the label a human sees in Jira and
  never by its internal identifier.

### Key Entities

- **Defaultable field metadata**: what discovery already records for each field a default may be recorded for
  — the Jira label, the internal field identifier, whether Jira requires it, the field's declared type, and
  its enumerated allowed values. This feature consumes the declared type and the allowed values, both already
  present; it adds nothing to this record.
- **Resolved field default**: the join of a recorded label to a field identifier, per issue type, carrying the
  value to send and where it came from. After this feature the value it carries is the value **in the shape
  the field accepts**; its provenance record is unchanged.
- **Confirmation field**: one line of the consolidated question — the issue type, the field's label, the value
  recorded for it, whether Jira requires it, and its allowed values. The recorded value is now rendered back
  into the operator's own words.
- **Run summary**: the structured created / updated / skipped / warnings / errors tally. Its created member
  now reflects confirmed creations.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Unaffected. No new state is persisted anywhere. The recorded defaults keep living in the committable team config, the discovered metadata keeps living in the local binding; this feature only changes how an already-recorded value is spelled on the wire. Closing the defect is what lets the specification file's `creating` markers resolve to real ticket keys instead of stalling. |
| II | Zero-Churn Idempotency | FR-013 makes it a requirement: a fully successful run's summary is byte-for-byte unchanged, and FR-005 keeps every already-working field's payload identical. A second run over an unchanged project still rewrites nothing. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Preserved and strengthened. A value the bridge cannot encode is still sent as recorded and still fails closed with the existing diagnostic (FR-007); FR-014 moves one class of failure earlier, into the configuration ceremony, which refuses rather than writes. FR-011 makes the fail-closed outcome legible instead of reporting phantom creations. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected, and it is the principle that bounds the encoding table. No credential is read, written, logged, or newly exposed. FR-004 declines to derive an account shape for a user-typed field precisely because the only shape Jira accepts is an account identifier, and this principle forbids one in a tracked file — the committable team config and the test fixtures both. FR-014's refusal likewise names the field and the accepted values but never echoes the recorded value. |
| V | Separation of Team Config / Local Binding / Secrets | Respected: the recorded value stays in the committable team config in business language, the declared type and allowed values stay in the local binding as discovery results. The encoding happens in memory at the join of the two; neither file gains a key. |
| VI | macOS / Linux / Windows Portability | FR-016 requires both ports and byte-identical output proven by the shared conformance corpus. Acceptance scenario US1-8 is the cross-port assertion. No new tool, build step, or download is introduced. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | This principle is the reason the feature exists. The outgoing shape is derived from the type Jira itself reported for that field at discovery time — never from an assumed schema, a hard-coded field identifier, or a known type name. The rules keyed on declared type are Jira's own field-type vocabulary, not a guess about any project's configuration, and an unrecognised type falls through unchanged (FR-005). |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Every change lands in the Jira sink and in the command that assembles the summary. The engine gains no knowledge of field types, option shapes, or payload structure; the neutral interchange document is unchanged. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. No value newly crosses the privacy boundary: the same recorded values are sent, differently spelled, and the pre-write scan runs where it runs today. |
| X | Self-Healing Automatic Mirror | Directly served. Today the mirror cannot heal at all on an affected project — every run leaves the same unresolved markers. After this change the next ordinary run completes the mirror with no manual step. |
| XI | Universal Dry-Run and Auditability | FR-011 fixes an auditability defect this principle names explicitly: the structured summary must be usable by a human and by CI, and a created count that reports unattempted work is not. FR-012 preserves dry-run equivalence — the predicted action **set** is unchanged; only the post-run tally becomes confirmation-based. |
| XII | Quality and Catalog Publication | The fix is a patch-level behaviour correction on a shipped feature and will carry a CHANGELOG entry; the full suite, the conformance corpus, and the linters gate it on all three operating systems as usual. |
| XIII | TDD With a Minimum 80% Coverage | FR-017 mandates the failing-first regression test — one issue type, one select-list default and one free-text default, asserting the exact payload — and every user story above carries an independent test. Each test observes only state it created; none scans for anything by name pattern. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | The encoding is a lookup on a fact already in scope at the point of resolution: no new function signature, no new parameter threaded through callers, no new file, no abstraction layer. The alternative — propagating type metadata down to the payload builder — was rejected as strictly more plumbing for the same result. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Every rule shipped is demanded by an FR above and exercised by a test. The encoding table covers the declared types Jira actually reports for a single-value field and stops there; no rule is added for a shape no requirement names. User Story 4 is specified rather than assumed, and is the slice explicitly marked droppable. |
| XVI | Human Readable — Readable by a Human Above All | FR-009 keeps the operator's own words in the one question they read; FR-018 keeps every message on Jira labels rather than internal identifiers; FR-014's refusal names the problem, the field, and the accepted values — and deliberately not the recorded value, which Principle IV keeps out of messages and which the operator is already looking at in the file. The team config an operator edits is unchanged — they keep writing plain business values and never learn the wire shape exists. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A project whose specification-role and story-role issue types each require a single-select
  field goes from **zero** tickets creatable to a complete mirror created by one ordinary run, with no manual
  Jira work and no change to the recorded configuration.
- **SC-002**: 100% of recorded defaults on fields that already worked — free text, numbers, dates — produce a
  byte-identical creation payload before and after the change.
- **SC-003**: On a run where Jira refuses every creation, the summary reports zero tickets created; the count
  a reader or a CI job sees never exceeds the number of tickets that exist in Jira.
- **SC-004**: An operator confirming a creation sees, for every field, the exact value recorded in the team
  config — no operator-facing surface displays a machine shape.
- **SC-005**: A recorded value a field cannot accept is reported while the operator is configuring, not on the
  next hook that fires during someone's work.
- **SC-006**: The behaviour is identical on macOS, Linux, and Windows — the shared conformance corpus reports
  zero divergences on the scenarios this feature adds.

## Assumptions

- The declared type and the enumerated allowed values discovery already records per defaultable field are
  present and trustworthy for any project bound with credentials; this feature reads them and adds nothing to
  what discovery collects.
- The encoding rules cover the single-value field shapes Jira reports today. A declared type outside them is
  treated as "send as recorded", which is exactly today's behaviour — so an unforeseen type is no worse off
  than it is now, and the existing rejection diagnostic still explains any refusal.
- Recording a value as text is how operators express a default; a structured value in the team config is a
  deliberate expert escape hatch and is obeyed literally rather than corrected.
- A creation is "confirmed" when Jira accepts the create call and returns the ticket; a failure in any
  subsequent step for that ticket is reported through its own existing diagnostic and does not un-count the
  ticket, which exists.
- Feature 011's configuration ceremony, its consolidated confirmation question, and its rejection diagnostic
  all remain in place; this feature changes what they carry, never whether they fire.
- The example that surfaced the defect is treated as a shape, not as data: no consumer project key, field
  label, option value, or ticket key from the report appears in this spec or in the tests it demands.

## Out of Scope

- Any change to which fields discovery marks defaultable, or to the reason it gives for a field it does not.
- Support for recording a default on an array-shaped field (multi-select, checkbox group, labels) or an issue
  link — still non-defaultable, still reported with a readable reason.
- Resolving a recorded option to its internal option identifier by an extra lookup against Jira; the recorded
  value is used as the name it already is.
- Any structured shape for a user-typed field. Jira accepts one only as an account identifier, which
  Principle IV forbids in the committable team config, so a user field keeps sending its recorded value
  unchanged (FR-004). Resolving a recorded name to an account needs its own Jira lookup and its own spec —
  written as feature 016, `specs/016-jira-user-field-defaults/`.
- Retrying a refused creation with a different shape after Jira rejects one. The bridge sends the shape the
  field's declared type calls for, once; a refusal remains a refusal, reported by the existing diagnostic.
- Any change to the updated / skipped / recognised / assigned tallies, which are outside this defect.
- Backfilling or repairing tickets from earlier failed runs.
