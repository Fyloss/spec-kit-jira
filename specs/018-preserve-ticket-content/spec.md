# Feature Specification: The Mirror Adds to a Ticket, and Never Overwrites What It Did Not Write

**Feature Branch**: `worktree-fix+protect-ticket-override`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "Bug found while dogfooding: going from `specify` to `plan` to `tasks`, each
`after_*` hook fires the extension's reconcile, and every time the previously mirrored tickets have their
title and their description overwritten. When `plan.md` is generated the Epic and the existing Stories are
completely renamed; generating `tasks.md` overwrites the Epic's and the Stories' information again. What I
want is for `plan.md`'s content to be **added**, once it is created, to the Epic's **existing** description."

## Clarifications

### Session 2026-08-05

- Q: FR-023 and the Edge Cases section both say a ticket suppressed by halted status, an operator flag, or
  unresolved drift "is not written to at all". Feature 015/016's own `drift.sh` and its tested contract
  (FR-035/FR-036) only ever suppress the *transition* for a flagged ticket or an unresolved (`withhold`)
  drift decision — content-only updates are explicitly documented and tested to keep reconciling for those
  two causes. Does FR-023 mean to reverse that shipped, tested behaviour, or does it describe the `halted`
  case only? → A: `halted` only. FR-035/FR-036 are unchanged: a flagged ticket and an unresolved-drift
  ticket keep reconciling their content, including the boundary, exactly as before this feature — only
  their *transition* is withheld. `halted` is the one category whose `content_writes:false` already
  withholds the whole write, and that is what FR-023 protects: the new unconditional boundary (T026) MUST
  NOT bypass it. FR-023's "operator flag" and "unresolved drift" clauses are satisfied by nothing changing
  for them — the boundary follows whatever content write already happens (or does not) for that ticket, and
  never becomes a licence to write where the ticket was withheld only from a status transition.

## Context — the defect this feature closes

Six lifecycle events fire the same reconcile over the same target, and feature 017 has just made that
literal: the mirror now refuses any target whose file name is not `spec.md`, so the calling agent can no
longer hand it the artifact the host command has just produced. That closes the *renaming* half of the
report. The Epic and its Stories were being renamed because `plan.md` was being parsed as if it were a
specification — its `# Implementation Plan: …` heading became the Epic's title, its own headings became
stories, and the next event did the same thing again with `tasks.md`. With the target guard in place, every
one of the six events reconciles the feature's `spec.md`, and a title only ever comes from the
specification.

What the report also describes, and what 017 deliberately did not touch, is still true: **the mirror owns
every byte of a ticket it created, and rewrites all of them on every run.**

- **The description is regenerated, never extended.** Each run recomputes the whole description from the
  specification — and, for the parent, from the plan's summary — and sends the result as a replacement.
  Anything a human typed into that description in the tracker's own UI is gone on the next lifecycle
  command. There is no boundary on the ticket saying *this part is the mirror's and that part is yours*.
- **The plan is folded into that regeneration rather than added to what is there.** The plan's summary is
  already read and rendered into the parent's description — but as one more block of a description the
  mirror recomputes wholesale. From the operator's chair the outcome is indistinguishable from an
  overwrite, because it is one: the description they were looking at is replaced by a new description that
  happens to contain the plan.
- **The summary is rewritten from the specification with no memory of what was last sent.** The mirror
  compares the ticket's current summary against the one it wants and writes when they differ. It cannot
  tell a human who renamed the ticket from a specification whose title changed, because it never recorded
  what it last wrote. A deliberate rename in the tracker is therefore reverted silently, on the next hook,
  with nothing in the run summary naming it.

A ticket that a human cannot safely annotate is a ticket a human stops annotating. This feature draws the
missing boundary. A managed section already exists for exactly this purpose — it is what protects a ticket
*adopted* from a human author, whose prose above the section survives every reconcile — and it is confined
today to that one origin. This feature extends the same boundary to the tickets the mirror created itself,
gives the plan its own named place *below* that boundary so a plan lands as an addition rather than a
replacement, and gives the mirror a memory of the summary it last wrote so that a human's rename is named
and kept instead of silently undone.

The self-healing guarantee is not weakened by any of that; it is made precise. The mirror restores what
**it** owns — the managed section, in full, on every run. It has never owned the text a human wrote, and
from here on it stops behaving as though it did.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The plan is added to the Epic's description, not substituted for it (Priority: P1)

A developer has run `/speckit.specify`; the parent ticket exists and carries the specification's content. A
Product Owner opens it in the tracker and types two paragraphs of business context at the top of the
description. The developer then runs `/speckit.plan`. The `after_plan` hook fires the mirror against the
feature's `spec.md`, the mirror reads the freshly written `plan.md` alongside it, and the parent's
description afterwards holds — in this order — the Product Owner's two paragraphs, unchanged to the byte,
then everything the mirror manages, ending with a clearly named implementation-plan section carrying the
plan's content. Nothing was removed. The developer re-runs `/speckit.plan` after editing the plan: the
implementation-plan section is refreshed in place, the two paragraphs above it are still there, and no
second copy of anything appears.

**Why this priority**: This is the operator's explicit request, stated in their own words. It is also the
one behaviour that turns the mirror from something that broadcasts into something two people can share a
ticket over.

**Independent Test**: Can be fully tested against a Jira double: mirror a specification, seed the returned
parent description with human prose above the managed section, produce a `plan.md`, run the mirror again,
and assert the resulting description payload preserves the prose verbatim and carries the plan section
below the managed boundary; then change the plan and re-run, asserting the section is replaced in place and
the prose is still byte-identical.

**Acceptance Scenarios**:

1. **Given** a parent ticket the mirror created and a human has since prefixed with their own prose,
   **When** a feature folder gains a `plan.md` and the mirror runs, **Then** the description sent to the
   tracker preserves that prose byte-for-byte and carries the plan's content in a named section inside the
   mirror's managed region, below it.
2. **Given** the same ticket, **When** `plan.md` changes and the mirror runs again, **Then** the plan
   section is replaced in place — exactly one plan section exists afterwards — and the human prose is
   untouched.
3. **Given** a feature folder with no `plan.md`, or a `plan.md` with nothing to contribute, **When** the
   mirror runs, **Then** the description carries no plan section, no placeholder, and no warning — as it
   does today.
4. **Given** a feature folder whose `plan.md` is deleted after having been mirrored, **When** the mirror
   runs, **Then** the plan section is removed from the managed region and everything else — the human
   prose and the specification-derived content — is preserved.
5. **Given** a settled parent whose plan section already matches `plan.md`, **When** the mirror runs again
   with nothing changed, **Then** it reports zero updates for that ticket.
6. **Given** any of the above, **When** `--dry-run` is used, **Then** the predicted description payload is
   byte-identical to the one the real run would send.

---

### User Story 2 - What a human writes on a mirrored ticket survives every reconcile (Priority: P1)

A QA engineer adds a paragraph of test notes to a Story the mirror created. A tech lead adds a link and a
sentence to the parent. A developer adds a reproduction note to a mirrored sub-task. The next four
lifecycle commands fire the mirror four times. All three additions are still there afterwards, exactly as
typed, and everything the mirror owns has been refreshed underneath them as usual — including a
specification edit made in between, which is reflected in the mirror's own region and nowhere else.

**Why this priority**: This is the general rule of which User Story 1 is one application, and it is the
half of the report that survives feature 017. It applies to every managed tier, not only the parent, and
without it User Story 1's guarantee would hold on one ticket and nowhere else.

**Independent Test**: Can be fully tested against a Jira double: mirror a specification with two user
stories and a task tier, seed each returned ticket's description with human prose above the managed
boundary, edit the specification, re-run, and assert every payload preserves its prose verbatim while the
managed region reflects the edit.

**Acceptance Scenarios**:

1. **Given** a parent, a Story, or a sub-task the mirror created and a human has since added text to,
   **When** the mirror runs, **Then** that text is preserved verbatim in the description the mirror sends,
   and only the mirror's own region is rewritten.
2. **Given** the same ticket, **When** the specification changes, **Then** the change appears inside the
   mirror's region and the human text is unaffected.
3. **Given** a ticket whose managed region a human deleted or damaged, **When** the mirror runs, **Then**
   the region is restored in full — self-healing applies to the mirror's own content — and any human text
   outside it is preserved. Where the damage leaves the mirror unable to identify its own former output,
   the run reports the named warning of FR-020b rather than guessing.
4. **Given** a ticket whose description holds only human text and no managed region yet, **When** the
   mirror runs, **Then** the managed region is added once, below that text, and the text is not moved,
   reformatted, or duplicated — and, because the mirror cannot confirm that none of that text is its own
   former output, the run reports the named warning of FR-020b.
5. **Given** a ticket whose description the mirror owns entirely and nothing has changed, **When** the
   mirror runs, **Then** it reports zero updates — the boundary MUST NOT become a source of churn.
6. **Given** a ticket a human edited only *outside* the mirror's region, **When** the mirror runs,
   **Then** it reports zero updates for that ticket: a human edit alone is never a reason to write.

---

### User Story 3 - A human's rename is reported and kept, never silently undone (Priority: P2)

A Product Owner renames a mirrored Story in the tracker to wording their stakeholders recognise. The
developer runs the next lifecycle command. The mirror notices that the ticket's current summary is not the
one it last wrote, leaves the human's wording in place, and reports one named warning identifying the
ticket and the summary field. When the operator decides the specification should win, they re-run with the
existing drift override and the specification's title is restored — the same escape hatch, spelled the
same way, that already governs a drifted status.

**Why this priority**: It answers the "overwritten title" half of the report for the case feature 017 does
not cover — a deliberate human rename rather than a mistaken target. It is P2 rather than P1 because, with
017 in place, no title is renamed *by accident* any more; this covers the remaining, rarer, deliberate
case.

**Independent Test**: Can be fully tested against a Jira double: mirror a specification, change the
returned ticket's summary on the double, re-run, and assert no summary write is sent, one named warning
identifies the ticket and the field, and a run with the drift override sends exactly one summary write
restoring the specification's title.

**Acceptance Scenarios**:

1. **Given** a mirrored ticket whose summary a human changed after the mirror last wrote it, **When** the
   mirror runs, **Then** it sends no summary change, keeps the human's wording, and reports one named
   warning identifying the ticket and the summary field.
2. **Given** that same ticket, **When** the mirror runs with the drift override, **Then** it sends exactly
   one summary write restoring the specification's title and reports the overwrite.
3. **Given** a ticket whose summary is exactly what the mirror last wrote, **When** the specification's
   title changes, **Then** the mirror updates the summary with no warning — an ordinary retitle is not
   drift.
4. **Given** a settled ticket with an untouched summary, **When** the mirror runs, **Then** it reports zero
   updates and no warning.
5. **Given** a warned summary, **When** the run ends, **Then** the host lifecycle command still completes
   successfully and every other field of that ticket reconciles exactly as it does today.
6. **Given** any of the above, **When** `--dry-run` is used, **Then** the predicted writes and warnings
   match the real run's exactly.

---

### User Story 4 - An existing installation gains the boundary without losing or duplicating a word (Priority: P3)

A team that has been mirroring specifications for months upgrades. On the next ordinary run every one of
their tickets acquires the boundary: descriptions the mirror wrote become the mirror's managed region,
descriptions a human has since extended keep the human's part outside it, and no ticket ends up with two
copies of anything. The run reports what it did as ordinary counts, and the run after that reports zero.

**Why this priority**: The feature is worthless if adopting it costs a team the annotations it is meant to
protect. It is P3 because it is a one-time transition that only an existing installation reaches, and
because the three stories above are demonstrable on a fresh specification without it.

**Independent Test**: Can be fully tested against a Jira double seeded with tickets in the pre-release
shape — no boundary, a mirror-written description, and a variant with human text appended — running the
mirror once and asserting no human text is lost, no content is duplicated, and a second run reports zero
writes.

**Acceptance Scenarios**:

1. **Given** a ticket written by a previous release, carrying no boundary and a description the mirror
   authored, **When** the mirror runs, **Then** that description becomes the mirror's managed region, with
   no content duplicated and nothing above it.
2. **Given** a ticket written by a previous release whose description a human has since extended, **When**
   the mirror runs, **Then** the human's text is preserved and the mirror's region is established without
   duplicating any content.
3. **Given** either ticket, **When** the mirror runs a second time with nothing changed, **Then** it
   reports zero writes.
4. **Given** a ticket the mirror has never written a summary record for, **When** the mirror runs,
   **Then** the summary reconciles exactly as it does today and the record is established for subsequent
   runs — the first run after the upgrade never warns about a rename it cannot have observed.
5. **Given** a ticket written by a previous release whose description the mirror can no longer identify as
   its own — because the specification changed in the same run, or a human edited inside the mirror's
   former region — **When** the mirror runs, **Then** nothing is lost, the mirror's previous output may
   appear above the boundary as well as inside it, and one named warning identifies the ticket.

---

### Edge Cases

- **The second half of the report, after 017.** With the target guard in place, the `after_tasks` run
  reconciles `spec.md`, finds the plan section already settled, and writes nothing to the parent or its
  Stories. That half of the reported symptom is closed by feature 017 plus zero-churn idempotency, and this
  feature must not reintroduce a write there.
- **A human wrote *below* the mirror's region**, not above it. The boundary has a top; text a human places
  after the mirror's content sits inside the region the mirror replaces. The behaviour must be defined and
  documented rather than left to chance.
- **A human deleted the boundary marker but kept the content.** The mirror cannot tell its own former
  output from a human's prose; the outcome must be non-destructive and stated.
- **Two boundary markers**, or a marker in a ticket the mirror does not manage, or a malformed region.
- **A description a human replaced entirely with their own text**, leaving nothing of the mirror's.
- **A description the tracker rejects** because the combined human text and managed region exceed a field
  limit.
- **A ticket whose writes are suppressed** — halted status, operator flag, unresolved drift. It is not
  written to at all, so it gains no boundary and no summary record on that run, and acquires them on the
  first run that is allowed to write.
- **A summary a human changed to exactly the specification's title**, and a summary that differs from the
  last-written record only by surrounding whitespace or by the tracker's own normalisation.
- **A ticket adopted from a human author**, already protected by the existing managed section: its
  behaviour must not change, and it must not end up with two boundaries.
- **A `plan.md` that exists but yields nothing to mirror**, and a `plan.md` that appears and later
  disappears.
- **A dry run** must predict every payload above without establishing a boundary or a summary record.

## Requirements *(mandatory)*

### Functional Requirements

**The plan is an addition to the parent's description (User Story 1)**

- **FR-001**: The parent's plan content MUST be rendered as its own named section inside the mirror's
  managed region of the description, placed after the specification-derived content, so that a plan
  produced later lands as an addition to the description that already exists rather than as a
  recomputation of it.
- **FR-002**: A subsequent run whose plan content differs MUST replace that section in place, leaving
  exactly one plan section on the ticket and every other part of the description — managed or human —
  unchanged.
- **FR-003**: When the feature folder holds no plan, or the plan yields no content to mirror, the
  description MUST carry no plan section, no placeholder, and no warning.
- **FR-004**: When a previously mirrored plan yields nothing to mirror on a later run, the plan section
  MUST be removed from the managed region, and no other part of the description may change.
- **FR-005**: A run whose plan content is unchanged MUST produce zero writes for that ticket.

**The boundary between the mirror's content and a human's (User Story 2)**

- **FR-006**: Every ticket the mirror manages — the specification-role parent, every story-role child, and
  every task-role sub-task — MUST carry, in its description, a boundary distinguishing the region the
  mirror owns from text it does not own.
- **FR-007**: The mirror MUST replace only the region it owns. Text outside that region MUST be preserved
  byte-for-byte in the description the mirror sends, on every run and on every tier.
- **FR-008**: The mirror MUST restore its own region in full when it is missing, incomplete, or altered —
  the self-healing guarantee applies to the mirror's content and to nothing else.
- **FR-009**: The presence of human text outside the mirror's region MUST NOT by itself cause a write:
  churn MUST be decided on the mirror's own region alone.
- **FR-010**: Establishing the boundary on a ticket that does not yet carry one MUST NOT move, reformat,
  reorder, or duplicate any existing content.
- **FR-011**: The mirror MUST NOT delete, truncate, or relocate text it does not own under any
  circumstance, including when the resulting description is rejected by the tracker; such a rejection MUST
  be reported as a named warning against that ticket and MUST NOT cause the mirror to drop the human's
  text to make room.
- **FR-012**: A malformed or duplicated boundary MUST be reported as a named warning identifying the
  ticket, and MUST leave that ticket's description unwritten rather than guessing which region is the
  mirror's.
- **FR-013**: A ticket already protected by the existing adopted-ticket managed section MUST behave exactly
  as it does today and MUST NOT acquire a second boundary.

**A human's rename is named and kept (User Story 3)**

- **FR-014**: The mirror MUST record, per managed ticket, the summary it last wrote, in the same durable,
  non-user-editable place its identity already lives — never in a user-editable field.
- **FR-015**: When a ticket's current summary differs from the recorded last-written summary, the mirror
  MUST treat it as human-authored drift: it MUST NOT overwrite the summary, MUST keep the human's wording,
  and MUST report one named warning identifying the ticket and the summary field.
- **FR-016**: The existing drift override MUST resolve that state by restoring the specification's title,
  reported as an ordinary update — no new flag, no new vocabulary.
- **FR-017**: When a ticket's current summary equals the recorded last-written summary, a change in the
  specification's title MUST update the summary silently, with no warning — an ordinary retitle is not
  drift.
- **FR-018**: A ticket carrying no summary record MUST reconcile its summary exactly as it does today and
  MUST acquire the record on that run, so the first run after the upgrade never warns about a rename it
  could not have observed.
- **FR-019**: The summary record MUST NOT itself become a source of churn: once established and unchanged,
  a subsequent run MUST report zero writes.

**The upgrade (User Story 4)**

- **FR-020**: A ticket written by a previous release MUST acquire the boundary on its next ordinary write
  **without losing any text, under any circumstance** — no branch of the transition may discard content it
  cannot classify.
- **FR-020a**: Where the mirror can identify its own previous output unambiguously, the transition MUST
  duplicate nothing: the identified output becomes the managed region and everything above it becomes
  human text.
- **FR-020b**: Where it cannot, the mirror MUST preserve the entire existing description as human text and
  establish its region below it — accepting that its own previous output then appears twice — and MUST
  report one named warning identifying the ticket so a human can trim the duplicate. Preserving with a
  visible, recoverable duplication is always preferred to a silent, irrecoverable loss.
- **FR-021**: The transition MUST be reported through the existing counts and summary vocabulary, and the
  run following it MUST report zero writes.
- **FR-022**: No manual step, no command of its own, and no configuration key may be required to complete
  the transition.

**Across every tier and both ports**

- **FR-023**: A ticket whose content writes are suppressed — halted status, operator flag, unresolved
  drift — MUST NOT be written to for any reason introduced here: it gains no boundary, no plan section, and
  no summary record until a run is allowed to write to it.
- **FR-024**: Every value the mirror *composes* — the summary, the boundary itself, every part of the
  managed region, the summary record, and every other outbound field — MUST pass through the existing
  pre-write privacy scan exactly as it does today, blocking with the same exit code and zero writes.
- **FR-024a**: The preserved human text MUST NOT be scanned. It is read from a ticket and written back
  verbatim to that same ticket, so it can carry nothing into the tracker that the tracker does not already
  hold; scanning it would let one ordinary tracker link a human pastes into a description refuse every
  subsequent run until a human deletes it. The exemption is structural and confined to the preserved region
  — it is not an allowlist entry, cannot be configured, and cannot be widened by a consumer.
- **FR-025**: The boundary and the ownership decision MUST be expressed neutrally by the engine; the
  rendering of the boundary and of the plan section in the tracker's own document format MUST exist only in
  the sink.
- **FR-026**: `--dry-run` MUST predict every description payload, every warning, and every recorded value
  exactly as the real run produces them, and MUST establish nothing.
- **FR-027**: Every behaviour above MUST be implemented in both ports and produce byte-identical output,
  proven by the shared conformance corpus.

### Key Entities

- **Managed region**: the part of a ticket's description the mirror owns, delimited by a boundary the
  mirror writes and recognises. It is rewritten in full on every write and is the only part of a
  description the mirror ever replaces.
- **Human text**: everything in a description outside the managed region. The mirror reads it only to
  preserve it, never to parse it, and never writes it.
- **Plan section**: the named section, inside the managed region, carrying the feature plan's content —
  present only while the plan has something to contribute.
- **Last-written summary record**: the summary the mirror most recently sent for a ticket, kept beside the
  ticket's existing identity, and the only evidence that distinguishes a human's rename from a
  specification's retitle.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Directly served. The principle's own words — never silently regress a ticket, and report a named warning identifying the ticket and the divergent field before any overwrite decision — are today satisfied for status and not for content. FR-007 removes the silent regression of a description; FR-015 supplies the named warning for a summary. No third controlled exception is created: the mirror still writes only to tickets it already manages, and it writes strictly less than before. |
| II | Zero-Churn Idempotency | FR-005, FR-009, FR-019 and FR-021 each state it: a settled mirror, a human edit outside the region, an established summary record, and the run after the upgrade all produce zero writes. FR-014 keeps identity and the new record in a non-user-editable place, so no lookup is keyed on an operator-editable display name. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-012 fails closed on an ambiguous boundary — the ticket is not written rather than guessed at — and FR-011 refuses to buy a successful write with a human's text. Every warning introduced here is non-blocking: the host lifecycle command completes successfully, as User Story 3's fifth scenario asserts. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. No credential is read, written, recorded, or reported by anything specified here. |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected. FR-022 forbids a configuration key: the boundary and the summary record are behaviour, not options, and nothing is added to the committable config, the local binding, or the secrets layer. |
| VI | macOS / Linux / Windows Portability | FR-027 requires both ports and byte-identical output proven by the shared conformance corpus. The splice that preserves bytes around a boundary is precisely where a line-ending divergence has bitten this project before, so the corpus carries that case explicitly. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | No status, transition, screen, or field configuration is assumed. FR-023 keeps an operator's hold authoritative, and FR-011 treats a field-length rejection as a reportable property of the site rather than a licence to truncate. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | FR-025 states it: the engine decides ownership and emits neutral content; the boundary's rendering and the tracker's document format exist only in the sink. This reuses the neutral splice that already serves the adopted-ticket case. |
| IX | Two-Tier Privacy Guard, With an Allowlist | FR-024 keeps every byte the mirror composes under the same pre-write scan, at the same tier, with the same exit code; the guard-then-write ordering is unchanged. FR-024a exempts only the text the mirror round-trips verbatim back to the ticket it read it from. This *serves* the principle's own stated rationale — "a blocking control with false positives ends up disabled: precision wins over recall at the BLOCK tier" — rather than diluting it: scanning round-tripped remote content is a false-positive generator by construction. The narrowing is argued in the plan's Complexity Tracking and closes the same latent defect that already exists on adopted tickets. |
| X | Self-Healing Automatic Mirror | Preserved and made precise. FR-008 restores the mirror's own region in full whenever it is damaged — the guarantee is unchanged for everything the mirror authored. The principle has never claimed ownership of text the mirror did not write, and FR-007 stops the mirror behaving as though it did. FR-020 and FR-022 make the upgrade itself self-healing: one ordinary run, no manual step. |
| XI | Universal Dry-Run and Auditability | FR-026 requires `--dry-run` to predict every payload, warning, and recorded value while establishing nothing. FR-012, FR-015, FR-011 and FR-021 each put their outcome in the run summary. No destructive operation is added; the guarded re-mode is untouched. |
| XII | Quality and Catalog Publication | A defect fix on shipped behaviour, carrying a CHANGELOG entry and gated by the full suite, the conformance corpus, and the linters on all three operating systems. Its user-visible effect on an existing estate — the one-time transition of FR-020 — is documented for consumers as feature 017's back-fill was. |
| XIII | TDD With a Minimum 80% Coverage | Every user story states an independent test. The reproduction of the reported defect — human text on a mirrored ticket, then a lifecycle run, asserting the text is still in the payload — is written before any of this exists and fails without it. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | No new mechanism is invented: the boundary is the managed-section splice that already protects an adopted ticket, applied to one more origin, and the drift override is the flag that already exists. The one genuinely new thing is a single recorded value beside an identity record the mirror already writes. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Scope is held to the reported defect. A configurable boundary, an operator-authored template, a bidirectional sync of human text back into the specification, mirroring more of the plan than is mirrored today, and comment-based annotation are all named out of scope below and are not built here. |
| XVI | Human Readable — Readable by a Human Above All | This is the feature's whole point: a ticket becomes a document two people can share. The boundary reads as an explanation of what it delimits rather than as an opaque token, the plan section carries a named heading, and every warning names the ticket, the field, and what the operator can do about it. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Across a complete six-event lifecycle on one feature, 100% of the text a human typed into a
  mirrored ticket's description before the first event is still present, unchanged, after the last.
- **SC-002**: After a plan is produced on a parent that already carries the boundary, the parent's
  description contains the plan's content and every character it contained beforehand — measured as: the
  pre-run description is a contiguous subsequence of the post-run description. The contiguity claim is
  scoped to a parent that already carries the boundary: the one-time transition of FR-020 inserts the
  boundary *between* the preserved text and the managed region, so on that single run the pre-run
  description is present in full but not contiguously. SC-006 is what measures that run.
- **SC-003**: Exactly one plan section exists on the parent after any number of plan regenerations.
- **SC-004**: A second, unchanged run over a ticket carrying human text reports zero created and zero
  updated.
- **SC-005**: 100% of human-authored summary renames are reported by name — ticket and field — and 0% are
  reverted without the operator passing the drift override.
- **SC-006**: An existing installation completes the transition in one ordinary run with **zero words of
  human text lost across its whole estate**, zero content duplicated on every ticket whose transition is
  unambiguous, one named warning per ticket whose transition is not, and zero writes on the run after it.
- **SC-007**: Every warning introduced here leaves the host lifecycle command successful, with exactly one
  line reported to the developer.
- **SC-008**: Both ports produce byte-identical output for every scenario introduced here, proven by the
  shared conformance corpus.

## Assumptions

- **The plan content mirrored into the parent is the content mirrored today** — the plan's summary section,
  rendered as prose. This feature changes *where* that content lands and the fact that it is added rather
  than substituted; it does not widen what is extracted from the plan. Principle XVI is the reason: a Jira
  description is written for a Product Owner and a QA engineer, and a verbatim dump of a plan's technical
  context, directory trees, and gate tables is a raw markdown dump, which that principle forbids. Widening
  the extraction is named out of scope below and is a separate decision.
- **The boundary is the existing adopted-ticket managed section**, applied to one more origin. It is not
  configurable, not templatable, and not operator-authored; the mirror writes it and the mirror recognises
  it.
- **Human text sits above the mirror's region.** The boundary has a top and no bottom: text a human places
  after the mirror's content is inside the region the mirror replaces. This matches the existing
  adopted-ticket behaviour exactly rather than introducing a second convention, and it is stated in the
  ticket content itself so a human reading the description knows where to type.
- **The summary record lives beside the identity the mirror already stores** on each ticket — a durable,
  server-side, non-user-editable place. No new storage location is introduced.
- **The drift override is the existing one.** A human-renamed summary is resolved with the flag that
  already resolves a drifted status; no second override, no new spelling.
- **A ticket the mirror is not allowed to write to gains nothing.** The boundary, the plan section, and the
  summary record all follow the write; none of them is an exception to an operator's hold.

## Out of Scope

- **Widening what is extracted from the plan** beyond what is mirrored today. Named in Assumptions above as
  a separate decision.
- **Mirroring human text back into the specification.** The flow is one-way; text a human adds to a ticket
  stays on the ticket, and the mirror only preserves it.
- **A configurable, templatable, or operator-authored boundary**, and any option to disable the boundary
  and restore full-description ownership.
- **Protecting fields other than the description and the summary.** Priority, estimation, labels, status,
  and every other field keep exactly the behaviour they have today.
- **Comment-based annotation** — writing the mirror's content as a comment rather than into the
  description, or reading a human's comments.
- **Repairing an estate already damaged by the reported defect.** Descriptions a previous release
  overwrote are gone; this feature stops the next overwrite and does not attempt to recover a past one.
- **Mirroring `plan.md` or `tasks.md` as tickets of their own.** Feature 017 settled the target rule and
  feature 012 settled the task tier; neither is reopened here.
