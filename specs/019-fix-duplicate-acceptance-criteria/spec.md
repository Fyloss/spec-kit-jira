# Feature Specification: A Ticket the Mirror Created Is the Mirror's to Replace

**Feature Branch**: `fix/duplicate-acceptance-criteria`

**Created**: 2026-08-06

**Status**: Draft

**Input**: User description: "there is a bug when re-running the Jira reconcile command to update existing specs, the updated Jira tickets end up with a duplication of the Acceptance Criteria in Gherkin. Fix this"

**Clarified scope**: The reporter takes a feature through `spec.md`, `plan.md` and `tasks.md`, then re-runs
the host's specify command to change the specification — "Hello World" becomes "Hello Universe" — and
re-runs reconcile. Their expectation, which this specification adopts as the requirement: an updated
`spec.md` replaces the mirror's content on the parent and its stories; an updated `plan.md` replaces the
mirror's content on the parent; an edited task in `tasks.md` replaces that sub-task's content. Repairing or
migrating an estate already damaged is explicitly **not** wanted — there is no installed base to protect.

## The reported defect

Re-running reconcile against updated specifications produces tickets carrying **two** Acceptance Criteria
sections: the scenario list a previous run wrote, then a boundary line, then the same list re-rendered from
the current specification. `Hello World` and `Hello Universe` sit one above the other and a reader cannot
tell which the team is meant to build. The duplication is permanent — once written, the stale copy sits
above the boundary, where every later run classifies it as text a human typed and preserves it verbatim.

**Where the defect actually lives.** Every mirrored description carries a boundary: human text above it, the
mirror's region below it. When the boundary is present, the update path is already correct — measured, not
assumed: an edited specification replaces the region in full, exactly one acceptance-criteria section
results, and the run after it writes nothing. The defect is confined to descriptions carrying **no**
boundary. There, the mirror asks a single question — "does this description end with exactly what I would
render right now?" — and treats any answer but yes as proof the text belongs to a human. An edited
specification is by construction a "no". So a description the mirror wrote in full is reclassified as
someone else's writing, preserved, and re-rendered beneath itself.

**The evidence the mirror already has and does not use.** Every ticket carries a stored identity record
naming its origin: created by the mirror, or created by a human and adopted. That record is read on every
run and is already carried into the write decision for other purposes. A ticket whose recorded origin is the
mirror's own has no human text to protect — the mirror wrote every byte of it. Deciding ownership by
guessing at the content, while an authoritative record of authorship sits unread beside it, is the whole of
this defect.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An updated spec.md replaces what the mirror wrote on the parent and its stories (Priority: P1)

A developer changes an acceptance criterion in `spec.md` — the button now says "Hello Universe" — and
re-runs reconcile. The parent and every affected story show the new wording, once. Nothing stale remains
above it, and no warning tells them to go and tidy a ticket by hand.

**Why this priority**: This is the reported defect in the reporter's own words and circumstance. It strikes
the command's primary purpose: a mirror whose ordinary update path corrupts the ticket it updates cannot be
used, and the corruption compounds silently across every story in the feature.

**Independent Test**: Mirror a specification, produce a description carrying no boundary on a ticket whose
recorded origin is the mirror's, edit one acceptance-criteria clause, run reconcile, and assert the resulting
description carries exactly one acceptance-criteria section carrying the edited clause. Fails before the
change, passes after, on both ports.

**Acceptance Scenarios**:

1. **Given** a story ticket whose recorded origin is the mirror's own and whose description carries no
   boundary, **When** the specification's acceptance criteria are edited and reconcile is run, **Then** the
   resulting description contains exactly one acceptance-criteria section, carrying the edited clauses and
   not the previous ones.
2. **Given** the same ticket and a specification unchanged since the previous run, but a release whose
   rendering has changed in between, **When** reconcile is run, **Then** the description still contains
   exactly one acceptance-criteria section and no warning is reported for that ticket.
3. **Given** a parent ticket in the same condition, **When** reconcile is run, **Then** it behaves
   identically to the story — the tier makes no difference.
4. **Given** any ticket already carrying the boundary, **When** the specification is edited and reconcile is
   run, **Then** the region below the boundary is replaced in full and exactly one acceptance-criteria
   section results — today's correct behaviour, unchanged.
5. **Given** any of the above, **When** reconcile is run again with nothing changed, **Then** zero tickets
   are updated.

---

### User Story 2 - An updated plan.md replaces what the mirror wrote on the parent (Priority: P2)

A developer regenerates `plan.md` and re-runs reconcile. The parent shows the new plan summary, once. The
previous summary is gone rather than pushed above a boundary to sit there forever.

**Why this priority**: The same mechanism as User Story 1, on the artefact whose content the parent alone
carries. It ranks below P1 because the parent is one ticket per feature where the stories are many, so the
damage is narrower — but it is the reporter's stated second expectation and ships in the same change.

**Independent Test**: Mirror a feature whose `plan.md` has a summary, change that summary, run reconcile on
a parent whose description carries no boundary, and assert the parent carries the new summary once and the
old one nowhere.

**Acceptance Scenarios**:

1. **Given** a parent whose recorded origin is the mirror's own and whose description carries no boundary,
   **When** `plan.md`'s summary changes and reconcile is run, **Then** the parent's description carries the
   new summary exactly once and no part of the previous one.
2. **Given** a feature with no `plan.md`, or one with no summary section, **When** reconcile is run,
   **Then** the outcome is unchanged from today — no plan content, no warning.
3. **Given** the plan summary and the specification both changed in the same run, **When** reconcile is run,
   **Then** one write settles both, and the run after it writes nothing.

---

### User Story 3 - An edited task replaces that sub-task's content (Priority: P2)

A developer edits an existing task in `tasks.md` and re-runs reconcile. The corresponding sub-task in the
tracker shows the edited text, once.

**Why this priority**: The third artefact the reporter named, and the tier most likely to be edited
repeatedly during implementation. Same mechanism, third surface; it must not be left behind, because a tier
that still duplicates makes the fix untrustworthy as a whole.

**Independent Test**: Mirror a `tasks.md`, edit the text of one existing task, run reconcile against a
sub-task whose description carries no boundary, and assert its description carries the edited text once.

**Acceptance Scenarios**:

1. **Given** a sub-task whose recorded origin is the mirror's own and whose description carries no boundary,
   **When** its task text is edited in `tasks.md` and reconcile is run, **Then** the sub-task's description
   carries the edited text once and no superseded copy.
2. **Given** a task whose text is unchanged, **When** reconcile is run, **Then** that sub-task is not
   written to.
3. **Given** a task's metadata alone changes — its phase, its files, its dependencies — **When** reconcile
   is run, **Then** the sub-task's description carries one copy of that metadata, updated.

---

### User Story 4 - Text a human wrote is still never touched (Priority: P1)

A product owner writes context and background into a ticket they created and handed to the mirror. The
mirror updates that ticket repeatedly. Their words are still there, unchanged, every time.

**Why this priority**: Deciding ownership by recorded origin is exactly the change that could make the
mirror delete someone's writing if the record were trusted where it does not apply. This story is the
boundary condition on the three above and ships with them, never after — an irrecoverable loss of a human's
text is a strictly worse defect than the visible duplicate being removed here.

**Independent Test**: Run every scenario above against tickets whose recorded origin is a human's, and
against tickets carrying human prose above the boundary, asserting every human-authored character survives
each run.

**Acceptance Scenarios**:

1. **Given** a ticket a human created and handed to the mirror, whose description carries no boundary,
   **When** reconcile is run, **Then** every character of the existing description is preserved above a
   newly established boundary and nothing is removed.
2. **Given** a ticket carrying human prose above an existing boundary, **When** reconcile is run, **Then**
   that prose is preserved verbatim and only the region below the boundary is replaced.
3. **Given** a ticket whose recorded origin cannot be determined at all, **When** reconcile is run, **Then**
   the existing content is preserved in full and one named warning identifies the ticket — the safe
   fallback, not the normal path.
4. **Given** a description carrying more than one boundary, **When** reconcile is run, **Then** nothing is
   written to that ticket and the existing malformed-boundary warning names it — unchanged from today.

---

### Edge Cases

- **A human deleted the boundary** from a ticket the mirror created. The recorded origin still names the
  mirror, so the region is restored — which is what Principle X requires of damage to the mirror's own
  region. Any human text typed into such a ticket while the boundary was missing is lost; the record says
  the ticket is the mirror's, and the mirror cannot distinguish an addition from its own prose. This is
  accepted deliberately and is stated in the Assumptions.
- **A human duplicated the boundary**, or pasted one mirrored description into another. Unchanged from
  today: nothing is written and the ticket is named in a warning.
- **A ticket a human created, adopted and written to for the first time.** No boundary, human origin — the
  description is preserved in full. The case the origin record exists to distinguish.
- **A specification whose acceptance criteria were removed entirely.** The re-rendered region has no
  acceptance-criteria section, and the previous one must not survive as a phantom above the boundary.
- **A description the tracker re-serialised** between runs — reordered attributes, normalised formatting.
  The decision must not depend on the stored document being byte-stable across a round trip.
- **A ticket whose recorded origin predates the record existing.** Treated as undeterminable: preserved and
  named, never guessed at.

## Requirements *(mandatory)*

### Functional Requirements

**Deciding whose text a description is**

- **FR-001**: Where a description carries no boundary, the mirror MUST decide whether the existing content
  is its own by the ticket's **recorded origin**, not by comparing the content against what it would render
  now.
- **FR-002**: A recorded origin naming the mirror MUST be treated as authoritative: the whole existing
  description is the mirror's region, it is replaced in full, and no part of it is retained as human text.
- **FR-003**: A recorded origin naming a human MUST preserve the entire existing description as human text
  and establish the boundary below it — today's behaviour, unchanged.
- **FR-004**: An origin that cannot be determined MUST resolve as FR-003 does, and MUST report one named
  warning identifying the ticket.
- **FR-005**: The decision MUST NOT depend on the content being byte-stable across a round trip through the
  tracker, nor on it being unique, non-empty, or of any particular length.

**Never writing a second copy**

- **FR-006**: After any run, a mirrored description MUST contain **at most one** acceptance-criteria section
  and at most one of every other section the mirror composes.
- **FR-007**: A run that updates a ticket MUST replace the mirror's region rather than adding beside it. No
  branch of the update may leave a superseded copy of the mirror's own content in the description.
- **FR-008**: FR-006 and FR-007 MUST hold identically on the parent, the story and the sub-task tiers.

**What each artefact updates**

- **FR-009**: An updated `spec.md` MUST replace the mirror's region on the parent and on every story it
  describes.
- **FR-010**: An updated `plan.md` MUST replace the mirror's region on the parent, carrying the new summary
  and no part of the previous one.
- **FR-011**: An edited existing task in `tasks.md` MUST replace that sub-task's own region. A task whose
  text and metadata are unchanged MUST NOT be written to.

**Never losing a human's text**

- **FR-012**: No branch introduced here may discard text on a ticket whose recorded origin is a human's.
- **FR-013**: Where the origin is undeterminable, the mirror MUST preserve and warn rather than choose —
  retained as the fallback, not as the normal path.
- **FR-014**: A description carrying an ambiguous boundary MUST continue to be left unwritten and named in a
  warning, exactly as today.

**Reporting**

- **FR-015**: Every outcome introduced here MUST be reported through the existing counts and summary
  vocabulary. No new command, flag, configuration key, or output surface is introduced.
- **FR-016**: Every warning introduced or retained here MUST be non-blocking: the lifecycle command
  completes successfully and the remaining tickets are still processed.
- **FR-017**: `--dry-run` MUST predict every payload and every warning this feature can produce, and write
  nothing.

**Cross-cutting**

- **FR-018**: A run over an unchanged specification and an already-settled ticket MUST produce zero writes.
- **FR-019**: Both ports MUST implement this identically, proven byte-for-byte by the shared conformance
  corpus.
- **FR-020**: The ownership decision MUST stay in the neutral engine, taking the origin as an opaque
  parameter; the boundary's wording and the tracker's document format MUST stay in the sink.

### Key Entities

- **Description**: The text of a mirrored ticket — an optional human-authored part and the mirror's own
  region, separated by the boundary.
- **Boundary**: The visible line declaring where the mirror's region begins. Its absence is the sole
  condition under which this feature's decision is reached.
- **Recorded origin**: The stored statement of who created a ticket — the mirror, or a human who handed it
  over. Already written on creation and already read on every run; this feature makes it the authority on
  who owns an unbounded description.
- **Managed region**: Everything the mirror composes for one ticket — for a story, the description body, the
  acceptance-criteria section and the design section; the equivalent on the other tiers. The unit replaced
  on every update, which must never exist twice.
- **Acceptance-criteria section**: The part of the managed region carrying the Given/When/Then scenarios.
  The visible symptom of the defect and the thing most often edited between runs.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Directly served. The specification is the source of truth for the mirror's region; today a superseded copy of that region survives on the ticket, so the ticket contradicts the file it mirrors. FR-002, FR-007 and FR-009..FR-011 remove the contradiction. No new exception: the mirror writes to no ticket and no region it did not already write to. |
| II | Zero-Churn Idempotency | FR-018 states it, and FR-011 states it for the task tier specifically. The decision is keyed on the stored identity record, never on a summary, title, or any operator-editable display name. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-004, FR-013 and FR-014 fail closed on an undeterminable origin or an ambiguous boundary — preserved and named, never guessed at. FR-016 keeps every warning non-blocking. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. No credential is read, written, recorded, or reported. |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected, and FR-015 forbids a configuration key: ownership is behaviour, not an option. Nothing is added to the committable config, the local binding, or the secrets layer. |
| VI | macOS / Linux / Windows Portability | FR-019 requires both ports and byte-identical output proven by the shared conformance corpus. This is the boundary splice, where line-ending divergence has bitten this project before, so the corpus carries the new cases explicitly. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | No status, transition, screen, or field configuration is assumed. FR-005 goes further and requires tolerating whatever the tracker does to a stored document between runs. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | FR-020 states it. The engine takes the origin as an opaque parameter exactly as it already takes the boundary markers; no tracker vocabulary crosses into it. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. No new text is composed and no scanned surface changes — this feature writes strictly less than today, and the guard-then-write ordering is untouched. |
| X | Self-Healing Automatic Mirror | Directly served, and made precise. The mirror restores its own region whenever it is damaged — including when a human removed the boundary from a ticket the mirror created. The principle has never claimed text the mirror did not write, and FR-003 and FR-012 keep it from doing so. |
| XI | Universal Dry-Run and Auditability | FR-017 requires `--dry-run` to predict every payload and warning while writing nothing. FR-015 keeps every outcome in the run summary. No destructive operation is added. |
| XII | Quality and Catalog Publication | A defect fix on shipped behaviour, carrying a CHANGELOG entry and gated by the full suite, the conformance corpus, and the linters on all three operating systems. Its effect on an existing estate is documented for consumers. |
| XIII | TDD With a Minimum 80% Coverage | Every user story states an independent test. The reproduction — a bridge-origin description carrying no boundary, an edited specification, a run, and an assertion of exactly one acceptance-criteria section — is written first and fails without the change. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Nothing is invented. The boundary, the splice, the warning vocabulary and the origin record all exist and are all already read on every run. One decision changes: which of two signals answers "whose text is this". |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Scope is the reported defect on the update path. Repairing already-damaged tickets, a repair command, a migration mode, a content-shape heuristic, a configurable boundary, and reading ticket text back into the specification are named out of scope and are not built. |
| XVI | Human Readable — Readable by a Human Above All | The point of the feature: a ticket that states its acceptance criteria once, so a reader knows whether to build "Hello World" or "Hello Universe". Every warning keeps naming the ticket and what a human can do about it. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After any run, 100% of mirrored tickets carry exactly one acceptance-criteria section —
  measured across an estate covering the parent, story and sub-task tiers.
- **SC-002**: Editing one acceptance-criteria clause and re-running reconcile changes exactly that clause on
  the ticket: the number of sections, headings and scenarios is otherwise identical before and after.
- **SC-003**: Exactly one plan summary exists on the parent after any number of plan regenerations.
- **SC-004**: Editing one task in `tasks.md` writes to exactly one sub-task, and the tasks left untouched
  are not written to at all.
- **SC-005**: The run following any update reports zero created and zero updated.
- **SC-006**: 0% of tickets whose recorded origin is the mirror's own produce the "previous output could not
  be identified" warning — that warning becomes exceptional rather than universal.
- **SC-007**: Across a full lifecycle on a human-origin ticket, 100% of the characters that human typed are
  present, unchanged, at the end.
- **SC-008**: Both ports produce byte-identical output for every scenario introduced here, proven by the
  shared conformance corpus.

## Assumptions

- The reported symptom — duplicated Gherkin acceptance criteria — is the most visible instance of a general
  duplication of the mirror's whole region. The requirements address the region; the acceptance-criteria
  section is how the defect is measured, not the limit of what is fixed.
- The update path on a ticket that already carries the boundary is correct today. It was measured, not
  assumed, and is protected here by regression scenarios rather than changed.
- The recorded origin is trustworthy. It is written when a ticket is created or adopted and is not
  operator-editable in the ordinary course; a ticket whose origin cannot be read falls to the preserve-and-warn
  fallback rather than to a guess.
- On a ticket whose recorded origin is the mirror's own, any text a human typed after the boundary was
  removed is lost when the region is restored. This is accepted: the alternative is the duplication being
  fixed here, and the record says the ticket is the mirror's.
- Both ports carry the defect identically, since they share the design. Both are fixed in the same change.
- The existing warning vocabulary and run-summary counts are sufficient to report every outcome here.

## Out of Scope

- **Repairing or migrating tickets already carrying a duplicate.** Explicitly declined by the reporter:
  there is no installed base, and a duplicate already written sits above a boundary where it is
  indistinguishable from human text. Such tickets are cleaned by hand or recreated.
- A dedicated repair or migration command, a flag, or a configuration key of any kind.
- Identifying the mirror's previous output by the shape of its content — the origin record makes the
  heuristic unnecessary.
- Making the boundary's wording configurable or operator-authored.
- Reading human-authored ticket text back into the specification.
- Mirroring any content the mirror does not already mirror today.
- Exposing `mention` as an agent command (tracked separately in `docs/VISION.md`).
