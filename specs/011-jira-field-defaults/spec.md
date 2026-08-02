# Feature Specification: Recorded Field Defaults So a Mandatory Field Never Blocks a Mirror

**Feature Branch**: `feat/jira-field-defaults`

**Created**: 2026-08-02

**Status**: Draft

**Input**: User description: "Make it possible to record, in this extension's YAML config file for the
consumer project, the default answer for custom fields — mandatory or not — for the creation of any
ticket type, at the moment the config command is run. Then, when the hooks fire, whenever a field is
mandatory, ask the operator through the assistant whether they want to supply the value for that
mandatory field or keep the default value previously defined in their YAML config file. The goal is
to guarantee that creating a Jira ticket never blocks a consumer of this extension."

## Context — the defect this feature closes

A consuming project configures a Jira project whose written issue types require custom fields the
bridge has no way to invent: `Business Owner`, `Program Increment`, a team picker, a mandatory
single-select. Today the reconcile refuses the whole mirror before it starts: zero writes, a named
refusal listing the fields, and two remedies that are both outside the operator's reach in the
moment — *"make these fields optional in the project's field configuration"* (a Jira administrator's
job) or *"create the parent and its stories by hand"* (which defeats the extension). The operator is
blocked by a correct message with nothing to do about it.

The missing piece is not a new Jira capability. It is a place to write down, once, the answer the
operator would have typed anyway — and a moment to be asked for it.

## Clarifications

### Session 2026-08-02

- Q: Which fields does the configuration ceremony ask a question about — required only, or every
  defaultable field? → A: Required only. A field Jira does not require is never asked about; its
  default is recorded either through the `--field-default` flag or by writing the entry by hand into
  the committable team config, which the ceremony then carries forward.
- Q: What does "the operator declines to answer" the consolidated creation-time question mean
  mechanically, given that the bridge never blocks on input? → A: The assistant re-invokes the run
  with the accept-recorded-values flag. A decline and an acceptance are therefore the same act as far
  as the bridge is concerned, and the summary names that one reason; no separate decline flag exists.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Record the answers once, during the config ceremony (Priority: P1)

An operator runs the configuration ceremony on a repository bound to a Jira project whose written
issue types require custom fields. The ceremony already discovers, per issue type, exactly which
fields Jira demands. Instead of only reporting them, it now asks the operator — one field at a
time, naming each field by the label a human sees in Jira — for the value to use whenever the
bridge creates a ticket of that type. Each answer is written into the committable team config file
in business language, alongside the priority map the operator already maintains there, so the whole
team inherits it through a normal pull-request review.

The operator can also record a default for a field Jira does **not** demand — a team picker, a
component, a program increment the team always sets by hand — so that every mirrored ticket lands
already filled in. The ceremony never *asks* about such a field: a project's written types carry
dozens of optional fields, and turning each into a question would make the ceremony unusable. An
optional field's default is stated deliberately instead, either by naming it on the command line or
by writing the entry straight into the committable team config, and the ceremony carries it forward
untouched from then on.

The ceremony asks about the two issue types the bridge actually writes, and stops there: a project
with a dozen types does not become a dozen rounds of questions. A team that wants to prepare a type
the bridge does not write yet can still record defaults for it, but only by asking for it
explicitly — and the ceremony then says plainly that the entry is recorded and not yet used.

**Why this priority**: this is the whole feature's foundation. Without a recorded answer there is
nothing for a hook to fall back on, and the blocking refusal stands. It also delivers value on its
own: an operator who runs only the ceremony has already converted a hard refusal into a working
mirror.

**Independent Test**: run the configuration ceremony against a project whose written types require
fields the bridge cannot supply, answer the questions, and confirm the team config file now carries
those answers, that a second ceremony run over an unchanged project rewrites the file identically,
and that the previously refused reconcile now creates its tickets.

**Acceptance Scenarios**:

1. **Given** a bound project whose specification-role issue type requires two custom fields the
   bridge cannot supply, **When** the configuration ceremony runs, **Then** it asks for a value for
   each of those two fields, naming each by its Jira label and never by its internal field
   identifier, and records both answers in the committable team config under that project and that
   issue type.
2. **Given** a field whose allowed values Jira enumerates (a single-select, a priority-shaped
   field), **When** the ceremony asks for its default, **Then** the question is a closed question
   over the values Jira reported, and a value outside that list is refused with a message naming
   the accepted values.
3. **Given** a team config that already records a default for a field, **When** the ceremony runs
   again against an unchanged project, **Then** the existing answer is shown as the current value,
   keeping it requires no retyping, and the resulting config file is byte-for-byte unchanged.
4. **Given** an operator who wants a default on a field Jira does not require, **When** they record
   one — by naming it on the command line, or by writing the entry into the team config by hand —
   **Then** it is accepted, validated exactly as a mandatory field's default is, and applied on
   creation exactly like one; **And** the ceremony asks no question about that field, before or
   after.
5. **Given** a run in the ceremony's degraded mode (no credentials, no Jira read), **When** the
   ceremony runs, **Then** it asks no field questions at all and records nothing — the list of
   required fields is a discovery result, never a guess.
6. **Given** a project offering a dozen issue types of which two carry the mirror, **When** the
   ceremony runs without any opt-in, **Then** it asks about those two types only.
7. **Given** an operator who explicitly opts in for a third, discovered issue type, **When** they
   record a default for it, **Then** it is accepted and stored, and the ceremony reports it as
   recorded but not yet consumed, naming the type; **And** naming a type the project does not offer
   is refused with a message listing the discovered types.

---

### User Story 2 - A hook creation asks before it commits to a default (Priority: P1)

A developer runs an ordinary spec-kit command. The `after_*` hook fires and the bridge is about to
create a ticket whose issue type carries mandatory fields. Rather than sending the recorded defaults
silently, the assistant asks the developer once, in a single consolidated question: here are the
mandatory fields, here is the value recorded in the team config for each — keep them, or supply a
different value for this run? The developer answers, the tickets are created, and the run summary
states, field by field, which value came from the team config and which the developer supplied.

**Why this priority**: this is the interaction the request centres on, and it is what makes a
recorded default safe rather than merely convenient. A default applied without a word is a value
nobody reviewed landing on a real ticket; a default the developer confirms at creation time is a
deliberate act. It ships as P1 alongside User Story 1 because a recorded default the developer
cannot override at the moment of creation would push them straight back into editing YAML mid-task.

**Independent Test**: with defaults already recorded, trigger a hook that creates a ticket, confirm
the assistant asks exactly one consolidated question naming every mandatory field and its recorded
value, answer it both ways (keep, and override), and confirm the created ticket carries the answered
values and the summary attributes each value to its source.

**Acceptance Scenarios**:

1. **Given** recorded defaults for every mandatory field of a type about to be created, **When** the
   hook runs interactively, **Then** the operator is asked exactly one consolidated question listing
   each field with its recorded value, and answering "keep" creates the tickets with those values.
2. **Given** the same state, **When** the operator overrides one field's value in their answer,
   **Then** the ticket carries the overridden value, the team config file is not modified by the
   hook, and the summary names the overridden field and its source.
3. **Given** a hook run where the reconcile turns out to create nothing (everything is already
   mirrored), **When** the hook runs, **Then** no question is asked at all — the question is a
   consequence of a pending creation, never of the hook firing.
4. **Given** a project configured not to be asked (the team has settled its defaults), **When** a
   creation carries mandatory fields with recorded defaults, **Then** the defaults are applied
   without a question and the summary still names each field and its source.
5. **Given** a hook run in a non-interactive context (continuous integration, or any run where the
   operator cannot be reached), **When** a creation carries mandatory fields with recorded defaults,
   **Then** the defaults are applied without a question, the run completes, and the summary records
   that the question was skipped because the run was non-interactive.
6. **Given** any failure while asking or applying a default, **When** the hook run ends, **Then** the
   host spec-kit command still completes normally and the developer sees at most one warning line.

---

### User Story 3 - Nothing recorded: a refusal that hands back a remedy (Priority: P2)

A developer hits the blocking case on a repository where nobody has recorded anything yet: a
mandatory field, no default, and the operator is not reachable. The run must still refuse — inventing
a value for a field nobody described would put fiction on a real ticket. But the refusal now names
the exact command that fixes it forever, and when the operator *is* reachable, the assistant asks for
the missing value on the spot rather than refusing at all.

**Why this priority**: it closes the loop on the original defect for the population that has not yet
run the new ceremony, and it turns the surviving refusal into a one-step remedy. It is P2 because a
repository that has run User Story 1's ceremony never reaches this path.

**Independent Test**: on a repository with no recorded defaults, trigger a creation requiring a
mandatory field, once with the operator reachable (the assistant asks, the value is supplied, the
tickets are created) and once without (the run refuses with zero writes and prints the remedy
command).

**Acceptance Scenarios**:

1. **Given** a mandatory field with no recorded default and a reachable operator, **When** a creation
   is pending, **Then** the assistant asks for the value, and supplying it creates the tickets.
2. **Given** a mandatory field with no recorded default and no reachable operator, **When** a
   creation is pending, **Then** the run refuses that specification with zero writes, keeps its
   documented exit code, and its message names the field by its Jira label and includes a
   copy-pasteable command that records a default for it.
3. **Given** a mandatory field whose shape the bridge cannot express as a recorded value at all,
   **When** the ceremony or a creation encounters it, **Then** the operator is told plainly that
   this field cannot be defaulted and why, and the pre-existing refusal path applies unchanged.

---

### Edge Cases

- **The recorded value stops being valid.** A single-select default names an option an administrator
  has since deleted. The creation is rejected by Jira. The run must report the rejected field by its
  label, the value it tried, and the fact that the value no longer exists — never a raw API error
  body — and must not retry with a substituted value.
- **A recorded value is credential-shaped or identity-shaped.** An operator types a personal email or
  a user identifier as a default into the committable team config. The existing pre-write guard must
  treat it exactly as it treats any other tracked content, and the operator must be told where such
  a value belongs instead.
- **A field is mandatory on one issue type and absent from another.** The default is scoped to the
  issue type it was recorded for; it is never carried over to a type that did not ask for it.
- **The default changes after tickets already exist.** Editing a recorded default in the team config
  changes what *future* creations carry. Already-created tickets are left exactly as they are — no
  retro-fill, no update, no churn.
- **A human edits the field in Jira after creation.** That is drift, handled by the pre-existing
  drift path: reported, never silently overwritten by the recorded default.
- **Two specifications are mirrored in one run and both need the same missing value.** The operator
  is asked once, and the answer applies to every creation in that run.
- **The operator declines to answer** the consolidated question, or the interaction is interrupted.
  The assistant resumes the run as if the recorded values had been kept, and the outcome is exactly
  the non-interactive one: recorded defaults apply; a field with no default refuses with zero writes
  for that specification. Because the bridge is told only "proceed with what is recorded", a decline
  and an acceptance reach it as the same act — it must not try to tell them apart, and the summary
  gives the one reason it can honestly give.
- **The team config records a default for a field the project no longer has.** The ceremony reports
  the orphaned entry so it can be removed; it is never silently sent on a creation.
- **A default is recorded for an issue type the bridge does not write yet.** It is stored, reported
  as not yet consumed, and changes nothing. If that type later becomes one the bridge writes, the
  entry starts being applied with no further action — but until then it must never be mistaken for a
  setting that is doing something.
- **The role mapping moves.** A team re-maps the story role from one issue type to another. Defaults
  are recorded against the issue type, not the role, so the previous type's entries become
  not-yet-consumed rather than silently following the role onto a type they were never reviewed for.
- **A team records nothing at all.** The overwhelmingly common case, and the one a solo developer on
  a three-type project lands in: the ceremony asks nothing it did not already ask, and every output
  of every command is unchanged. The feature has to be invisible to the teams that do not need it. A
  team the bridge refuses to serve today is the one exception, and it is not a team the feature is
  invisible to — it is the team the feature exists for.
- **A team removes a default it had recorded.** Future creations stop carrying that field
  immediately. If the field is mandatory, the pre-existing refusal returns — which is the correct
  outcome, and the reason removal is the off switch rather than a separate one.
- **A default value is an empty string.** An empty answer is not a value: it is refused at recording
  time, so a mandatory field can never be defaulted to nothing.

## Requirements *(mandatory)*

### Functional Requirements

**Recording defaults (configuration ceremony)**

- **FR-001**: The configuration ceremony MUST, for each project it binds, enumerate the fields Jira
  requires for each issue type in scope, using only what the Jira metadata read reports — never a
  compiled-in field name or identifier.
- **FR-002**: For every required field the bridge cannot supply on its own, the ceremony MUST ask the
  operator for a default value, presenting the field by the label a human sees in Jira and never by
  its internal identifier.
- **FR-003**: When Jira enumerates a field's allowed values, the ceremony MUST ask a closed question
  over those values and MUST refuse an answer outside them, naming the accepted values in the
  refusal.
- **FR-004**: The operator MUST be able to record a default for a field Jira does not require, for
  any issue type in scope, and the ceremony MUST NOT ask a question about such a field. The two ways
  to state one are the recording flag of FR-006 and a hand-written entry inside the team configuration
  file's managed region; both produce the same entry, are validated identically (FR-003, FR-008), and
  are carried forward unchanged by every later ceremony run.
- **FR-005**: Recorded defaults MUST be persisted in the committable team configuration file, scoped
  by project and by issue type, keyed by the field's human label, in the same business-language style
  as the existing configuration keys, with an explanatory comment.
- **FR-006**: The ceremony MUST accept the same answers non-interactively through a repeatable
  command flag, so an operator can record every default in one scripted invocation.
- **FR-007**: Re-running the ceremony against an unchanged project with unchanged answers MUST leave
  the team configuration file byte-for-byte identical, and MUST present each already-recorded value
  as the current answer so keeping it requires no retyping.
- **FR-008**: The ceremony MUST refuse an empty default value and MUST report any recorded default
  whose field or issue type no longer exists in the project.
- **FR-009**: In the ceremony's degraded mode (no credentials, no Jira read) the ceremony MUST ask no
  field-default question and record no field default.
- **FR-010**: A field whose shape the bridge cannot express as a recorded value MUST be reported as
  such, by label, with the reason — and MUST NOT be offered as a defaultable field.

**Applying defaults (hooks and reconcile)**

- **FR-011**: Before a creation that would carry a value the team recorded, or that requires a field
  the bridge cannot supply on its own, the operator MUST be asked exactly one consolidated question
  per run, listing every such field with its recorded default where one exists, offering to keep the
  recorded values or to supply different ones for this run. A field the bridge merely *could* default
  — nothing recorded for it, and Jira does not require it — MUST NOT trigger the question. The
  question follows what the run would send, never what the issue type happens to offer, because a
  project full of optional custom fields must stay as quiet as one with none (FR-028).
- **FR-012**: An answer supplied at creation time MUST apply to every creation in that run and MUST
  take precedence over the recorded default for that run only.
- **FR-013**: The question MUST be asked only when a creation carrying such a field is actually
  pending; a run that creates nothing MUST ask nothing.
- **FR-014**: A team MUST be able to turn the question off per project, in the committable team
  config, after which recorded defaults are applied without a question.
- **FR-015**: In a non-interactive run, or when the operator declines or the interaction is
  interrupted, recorded defaults MUST be applied without a question and the summary MUST state that
  the question was skipped and why. A decline and an interruption are expressed by the caller
  resuming the run with the same instruction an acceptance carries — "proceed with the recorded
  values" — so the bridge MUST NOT offer a separate decline signal, MUST NOT attempt to distinguish
  the two, and MUST report the single reason it was actually given. Whether an operator can be
  reached MUST be stated by the caller and MUST NEVER be inferred by the bridge: a caller that cannot
  reach one — a continuous-integration pipeline, an unattended run — declares it on its first
  invocation, and a run fired by a hook is not such a caller, because the assistant that fired it is
  there to conduct the conversation.
- **FR-016**: When a required field has no recorded default and no answer can be obtained, the run
  MUST refuse for the affected specification with zero writes and its pre-existing documented exit
  code, and its message MUST name each such field by label and include a copy-pasteable command that
  records a default for it.
- **FR-017**: Recorded defaults MUST apply to creations only. An existing ticket MUST NEVER be
  retro-filled or updated because a recorded default was added or changed.
- **FR-018**: A default MUST apply only to the issue type it was recorded for, in the project it was
  recorded for.
- **FR-019**: When Jira rejects a write because a defaulted value is no longer valid, the run MUST
  report the field by label, the value that was sent, and the rejection in human terms, MUST NOT
  substitute another value, and MUST NOT retry.
- **FR-020**: A hook that asks, applies, or fails over field defaults MUST NEVER change the host
  spec-kit command's outcome, and MUST surface at most one warning line to the developer.
- **FR-021**: A hook MUST NOT modify the team configuration file, ever. A value the operator supplies
  at creation time applies to that run only; the run summary MUST print the copy-pasteable
  configuration command that would record it permanently, so adopting it stays a deliberate,
  reviewable team decision made through the configuration ceremony.

**Reporting, preview, and safety**

- **FR-022**: The run summary MUST name every field the run filled and attribute each value to its
  source — recorded team default, operator answer for this run, or bridge-supplied — without printing
  the raw payload sent to Jira.
- **FR-023**: The preview (`--dry-run`) MUST predict exactly the field values a real run would send,
  including which come from recorded defaults, and MUST ask no question and write nothing.
- **FR-024**: Recorded default values MUST be subject to the existing pre-write privacy guard exactly
  as any other tracked content, and a value the guard blocks MUST produce zero Jira writes with a
  message naming where such a value belongs instead.

**Scope of issue types**

- **FR-025**: The ceremony MUST ask its field-default questions for the issue types the bridge
  actually writes — the types carrying the specification and story roles — and for no others, so the
  default ceremony stays as short as the mirror is wide.
- **FR-026**: The operator MUST additionally be able to record defaults for any other issue type the
  project discovery reported, through an explicit opt-in — never through a question added to the
  default ceremony. The named type MUST be validated against the discovered type list, and an unknown
  name MUST be refused with a message naming the types the project actually offers.
- **FR-027**: A recorded default for an issue type the bridge does not write today MUST be reported
  by the ceremony as recorded but not yet consumed, naming the type, so no configuration entry is
  ever silently inert. Such an entry MUST NOT change any write the bridge performs.

**Inertness — the mechanism is off until a team turns it on**

- **FR-028**: The whole mechanism MUST be inert for every repository the pre-existing behaviour
  already served. A repository that records no default and whose written issue types require nothing
  the bridge cannot supply MUST behave exactly as it does today, byte for byte, on every surface: no
  new question, no new summary line, no field the bridge did not already send. The single admitted
  change is to a repository the bridge refuses to mirror today: there, and only there, a run may stop
  to ask for a value nobody has recorded (FR-011), because a repository that produces zero tickets has
  no working behaviour to preserve. A written type carrying optional fields the bridge cannot supply
  is NOT such a repository and MUST stay silent — the question follows what the run would send, never
  what the type offers.
- **FR-029**: Removing a recorded default from the team configuration MUST be the way to stop the
  bridge sending that field on future creations, and MUST take effect with no other action. No
  default is ever supplied on a team's behalf, and no field is ever written because the bridge
  decided it should be.

### Key Entities

- **Field default**: an operator-recorded answer for one field of one issue type of one project.
  Identified by the field's human label; carries the value to send, and the knowledge of whether Jira
  requires the field. Lives in the committable team configuration.
- **Required-field set**: per project and issue type, the fields Jira demands on creation, as
  reported by the metadata read. Discovered, never assumed; the input to every question this feature
  asks.
- **Creation intent**: a pending ticket creation, its issue type, and the field values assembled for
  it — each value tagged with where it came from. The unit the consolidated question covers and the
  unit the summary reports.
- **Answer scope**: whether a value applies to this run only (an operator answer at creation time) or
  to every run (a recorded team default). Governs precedence and what may be written where.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Defaults are read from the tracked team config and applied only when the bridge creates a ticket it owns. No new read or write of any ticket the bridge does not already touch; no new delete path. A field a human edits in Jira after creation stays drift — reported by the existing path, never silently overwritten (FR-017). |
| II | Zero-Churn Idempotency | Defaults enter creation payloads only; FR-017 forbids retro-filling an existing ticket when a default is added or changed, so a re-run over an unchanged state still issues zero writes of every kind. FR-007 extends the same guarantee to the config file itself: an unchanged re-run rewrites it byte-for-byte. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-016 keeps the fail-closed refusal — zero writes, the pre-existing documented exit code — whenever no answer exists; the feature makes the refusal rarer and remediable, never softer. FR-020 keeps every hook non-blocking and capped at one warning line, including when the question is interrupted. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | A default is a business value, never a credential. FR-024 subjects every recorded value to the pre-write guard, which already blocks a known coordinate in a tracked file; the message names where an identity-shaped value belongs instead. No token, email, site URL, or account identifier is introduced by any requirement here. |
| V | Separation of Team Config / Local Binding / Secrets | Recorded defaults are a team decision and live in the committable team config (FR-005), reviewable in a pull request. FR-021 keeps the writing of that file to the configuration ceremony alone: a hook reads it and never edits it, so a lifecycle command can never mutate a tracked team decision behind the developer's back. Nothing is written inside the extension folder, so a reinstall cannot destroy them. Discovered required-field metadata stays where it already lives, in the gitignored local binding. |
| VI | macOS / Linux / Windows Portability | Both native ports implement the ceremony question, the consolidated creation question, the config keys, and the summary lines identically; the shared conformance corpus gains scenarios for a recorded default, an overridden default, a missing default, and a non-interactive run, asserting byte-identical output and identical call sequences on all three runners. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | FR-001 sources the required-field set exclusively from the metadata read; FR-003 sources allowed values from what Jira reports. No field name, field identifier, issue-type name, or allowed value is compiled into either port. Defaults are keyed by human label and scoped per project and issue type (FR-018). |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Field identity, required-field metadata, allowed values, and payload assembly are Jira knowledge and stay in the sink. The engine learns only that a creation is pending and, for the summary, that named values were filled from named sources — no field identifier and no Atlassian vocabulary cross the interface, and the neutral document stays schema-validated before any write. |
| IX | Two-Tier Privacy Guard, With an Allowlist | FR-024 routes recorded values through the existing two-tier guard unchanged: a known coordinate blocks, a generic shape warns, allowlisted content passes silently. The feature adds content to the tracked tree, not a new guard or an exemption from it. |
| X | Self-Healing Automatic Mirror | Hook registration, health reporting, and repair are untouched. A hook the operator disabled stays silent — the consolidated question is a consequence of a pending creation inside a run that was dispatched, so a disabled event still exits silently before any of it. |
| XI | Universal Dry-Run and Auditability | FR-023 requires the preview to predict exactly the values a real run would send, with their sources, asking nothing and writing nothing. FR-022 puts every filled field and its provenance in the structured summary. No destructive operation is added or altered. |
| XII | Quality and Catalog Publication | Ships as a MINOR version bump with a CHANGELOG entry, green three-OS matrix, clean lint, and a dogfood run against a real Jira project whose written types carry mandatory custom fields — the exact instance shape that produced the defect. |
| XIII | TDD With a Minimum 80% Coverage | Every requirement here is a failing test first: the existing mandatory-field conformance fixture gains the green counterpart it never had, plus scenarios for the closed allowed-values question, the override, the non-interactive path, the invalid-value rejection, and the surviving refusal. The original blocking defect ships with its regression test written before the fix. Tests identify their own state by recorded identity and stay green in parallel. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | One config section, one ceremony question per field, one consolidated question per run, one flag to record answers non-interactively, one switch to stop asking. A recorded default is a literal value: no template syntax, no expression language, no computed or conditional defaults. No new dependency. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Every key and flag traces to a requirement above: the defaults map (FR-005), the record-non-interactively flag (FR-006), the stop-asking switch (FR-014), the other-types opt-in (FR-026). FR-028 and FR-029 make the whole mechanism inert until a team records something — for every repository the bridge serves today — and dead again the moment they remove it, so nothing here is a capability a team carries without asking for it. The opt-in cannot decay into orphaned configuration: FR-026 validates the type against discovery so no entry can name something that does not exist, and FR-027 makes the ceremony report any not-yet-consumed entry by name — the same "recorded, not yet mirrored" contract the `task` hierarchy role already ships under. Deliberately excluded as unrequired: retro-fill, wildcard issue types, per-developer default overrides, defaults on update-only writes, and any default the bridge computes for itself. |
| XVI | Human Readable — Readable by a Human Above All | Every field is named by the label a human sees in Jira, never by an internal identifier (FR-002, FR-016, FR-019, FR-022). The config section is self-documenting with a comment explaining its role. The consolidated question is one readable list, the summary is prose naming field and source, and a rejected value is explained in human terms rather than relayed as a raw API error. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A project whose written issue types require custom fields the bridge cannot supply goes
  from zero mirrored tickets to a complete mirror without any Jira administration change and without
  any ticket created by hand.
- **SC-002**: An operator records every needed default in a single configuration ceremony run,
  answering one question per required field, with no manual editing of the configuration file.
- **SC-003**: After the defaults are recorded, one hundred percent of subsequent mirror runs on that
  repository complete without a mandatory-field refusal.
- **SC-004**: A developer confronted with the consolidated question at creation time can keep every
  recorded value with a single answer.
- **SC-005**: Re-running the configuration ceremony against an unchanged project produces a
  byte-for-byte identical configuration file, and re-running the mirror over an unchanged state
  produces zero writes of every kind.
- **SC-006**: The preview and the real run agree exactly on the value sent for every field, in every
  scenario of the conformance corpus.
- **SC-007**: Every message a blocked or rejected run prints names the field the way it appears in
  Jira and states one action the operator can take without leaving their terminal.
- **SC-008**: No hook run changes the outcome of the spec-kit command that fired it, and no hook run
  emits more than one warning line, in any scenario of this feature.
- **SC-009**: The number of questions the ceremony asks depends only on the *required* fields of the
  two issue types the mirror writes — a project offering a dozen issue types is asked about two of
  them, and a written type carrying twenty optional fields adds no question at all — and no hook run
  modifies any tracked file.
- **SC-010**: A repository that records no default and is mirroring successfully today sees no change
  whatsoever: every command's output is byte-identical to the release before this feature, and the
  conformance corpus proves it — including for a repository whose written types carry optional custom
  fields the bridge cannot supply.

## Assumptions

- The set of fields Jira requires for an issue type is already discovered and persisted by the
  configuration ceremony; this feature consumes that discovery rather than adding a new one.
- The fields the bridge can already supply on its own (summary, description, issue type, project,
  priority, reporter, and the parent link where the project offers one) keep supplying themselves and
  are never offered as defaultable.
- A recorded default is a literal value in the config file's own vocabulary. Fields whose value is a
  simple scalar or one of an enumerated set of options are in scope; a field requiring a structure the
  configuration file cannot express readably in one line is reported as non-defaultable (FR-010)
  rather than partially supported.
- A person-shaped value (an account identifier, a user email) is not recordable in the committable
  team config, because tracked files must stay free of such coordinates; the guard blocks it and the
  message points to the gitignored local layer. Whether the local layer is extended to carry such a
  default is out of scope here.
- "Asking the operator" means the coding agent asks in the session it is already running in. The
  bridge itself stays non-interactive on both ports: it reports what it needs, and the agent conducts
  the conversation and re-invokes it with the answer — the mechanism the ceremony already uses for
  the project key and the project style. That re-invocation is also what closes a conversation that
  ends without an answer: the agent resumes with the recorded values rather than leaving the run
  half-finished, which is why a decline needs no signal of its own.
- Defaults apply to writes that create a ticket. A field required only on an edit screen, and the
  writes that would then need it, are out of scope.
- "The issue types the bridge writes" means the types carrying the specification and story roles,
  because those are the only ones the reconcile creates today. Recording a default for another
  discovered type is permitted on request and follows the contract the `task` hierarchy role already
  ships under: declaring it records it, and nothing more, until a later release consumes it.
- A default is recorded against an issue type, not against a mirror role. Re-mapping a role to a
  different type therefore does not move the defaults with it.
- An answer given at creation time is deliberately transient. Making it permanent is a separate,
  explicit act through the configuration ceremony, because the team config is a tracked file whose
  changes belong in a pull request rather than in whatever diff a developer happened to have open.
- A recorded default is a **constant** for an issue type — the same value on every ticket of that
  type. A value that varies per user story is not a default and is out of scope here; nothing in this
  feature is a general-purpose "write this computed value to that field" mechanism.
- Defaults follow the create-only convention the estimation field already ships under: written when
  a ticket is created, never re-sent on update, so a human's later refinement in Jira is never
  overwritten. This feature adopts that rule rather than introducing a second one.
- The consuming project's Jira instance may use any hierarchy, any type names, and any field
  configuration; nothing in this feature assumes an Atlassian default.
