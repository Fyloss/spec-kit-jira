# Feature Specification: The Mirror's Region Declares Where It Ends, Not Only Where It Begins

**Feature Branch**: `feat/managed-region-end-marker-2`

**Created**: 2026-08-06

**Updated**: 2026-08-14 — revised against the features that shipped in the meantime (see _Dependencies_)

**Status**: Draft

**Input**: User description: "Add a closing marker to the descriptions Spec Kit generates through this Jira
extension, so that the beginning and the end of the generated content are both delimited."

## Why this is more than a delimiter

A mirrored description carries one marker today. It declares where the mirror's region _begins_, and the
region is then taken to run to the end of the description. Nothing declares where it stops, because nothing
is expected to follow it.

Something does follow it, whenever a human puts it there. Measured on the current tree: a note written
**below** the mirror's content is discarded on the next ordinary run, with no warning, no count, and no
trace. A note written **above** it survives, as the shipped boundary promises. The promise — the mirror
never overwrites what it did not write — holds on one side of its own region and fails silently on the
other.

The open-ended region is the cause. "Everything after my marker is mine" is an assumption the mirror makes
about text it has never seen, and it is wrong exactly when a human has been reading the ticket and replying
underneath, which is the ordinary way people use a tracker.

A closing marker turns that assumption into a declaration: the region is what lies between the two markers,
and everything outside it — above **or** below — belongs to whoever wrote it. The delimitation the reporter
asks for and the data-loss fix are the same change.

Two things have changed since this specification was first written, and both make the closing marker more
load-bearing rather than less:

- **The question of _whose_ text an undelimited description is has been answered** (shipped 0.12.1). A
  ticket's recorded origin, not a guess from its content, now decides. That decision reads the region from
  one marker to the end of the document; this feature narrows the same decision to the region between two,
  and must slot in ahead of the ownership question rather than beside it.
- **The region has grown, and no longer ends where the mirror's prose ends** (shipped 0.14.0). Under
  checklist mode a story's task list is appended as the region's _last_ section, and several code paths
  identify it as "everything from the `Tasks` heading to the end of the description". A closing marker
  changes what "the end" means for every one of them. Getting this wrong does not lose a human's words —
  it makes a settled ticket churn on every run, which the constitution forbids just as plainly.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - A note written below the generated content survives the next run (Priority: P1)

A developer reads a mirrored story, and adds a paragraph at the bottom of the description — a caveat, a
link to a decision, a question for the reviewer. The mirror runs again. Their paragraph is still there.

**Why this priority**: This is silent, irrecoverable data loss on the ordinary way a person uses a ticket,
and it contradicts the guarantee the boundary was built to make. Nothing else in this specification matters
if text still disappears.

**Independent Test**: Place human text below the mirror's region on a mirrored ticket, run reconcile, and
assert every character of it is present afterwards. Fails before the change, passes after, on both ports.

**Acceptance Scenarios**:

1. **Given** a mirrored description with human text below the mirror's region, **When** reconcile is run,
   **Then** that text is present, unchanged, after the run.
2. **Given** human text both above and below the region, **When** reconcile is run, **Then** both survive,
   each in its original position relative to the region.
3. **Given** human text below the region and an edited specification, **When** reconcile is run, **Then**
   the region between the markers is replaced and the text below it is untouched.
4. **Given** human text below the region and an unchanged specification, **When** reconcile is run, **Then**
   the ticket is not written to at all.
5. **Given** any of the above on a parent, a story, or a sub-task, **Then** the behaviour is identical —
   the tier makes no difference.
6. **Given** a story mirrored in checklist mode with human text below the region, **When** reconcile is
   run, **Then** the task list is refreshed inside the region and the text below the closing marker is
   untouched.

---

### User Story 2 - A reader can see where the generated content stops (Priority: P2)

Someone opening a mirrored ticket sees, without knowing anything about the extension, where the
specification-driven content starts and where it ends — and therefore where they may safely write.

**Why this priority**: The reporter's stated motivation, and the reason User Story 1's fix is discoverable
rather than merely true. A region that is safe to write below but gives no sign of it protects nobody,
because no one will risk writing there.

**Independent Test**: Render a description and assert a closing marker is present, is legible as a sentence
rather than an opaque token, and follows the last generated element.

**Acceptance Scenarios**:

1. **Given** any description the mirror writes, **When** it is read in the tracker, **Then** a closing
   marker follows the generated content and reads as an explanation of what it delimits.
2. **Given** a description whose generated content is empty of optional sections, **When** it is written,
   **Then** both markers are still present and adjacent — the region is declared even when it is small.
3. **Given** a ticket created by the mirror, **When** it is created, **Then** it carries both markers from
   its first byte — a creation never produces a half-delimited region.
4. **Given** a story mirrored in checklist mode, **When** its description is read, **Then** the closing
   marker follows the task list — the last thing the region carries — and nothing generated sits below it.

---

### User Story 3 - Existing tickets acquire the closing marker without anyone doing anything (Priority: P2)

A developer with tickets already mirrored runs reconcile as usual. Those tickets come back with the region
closed. No command, no flag, no manual edit.

**Why this priority**: The change is worthless if it only applies to tickets created after it. It ranks
below the loss it prevents because it is a one-time transition, and because until it happens the ticket
behaves exactly as it does today — no worse.

**Independent Test**: Take a description carrying an opening marker and no closing one, run reconcile, and
assert both markers are present afterwards, that the run reports it through the existing summary, and that
the run after it writes nothing.

**Acceptance Scenarios**:

1. **Given** a description with an opening marker and no closing one, **When** reconcile is run, **Then**
   the description afterwards carries both markers and the same generated content.
2. **Given** the same ticket, **When** reconcile is run again, **Then** zero tickets are updated.
3. **Given** human text above the region on such a ticket, **When** the transition runs, **Then** that text
   is preserved exactly as it is today.
4. **Given** a transition run performed with `--dry-run`, **When** it completes, **Then** the resulting
   description is predicted in full and nothing is written.
5. **Given** a story mirrored in checklist mode whose description predates this feature, **When** the
   transition runs, **Then** the closing marker lands below the existing task list and the run after it
   reports the checklist as unchanged.

---

### User Story 4 - A region the mirror cannot trust is refused, not guessed at (Priority: P1)

A human deletes one of the markers, or pastes one mirrored description into another. The mirror declines to
write to that ticket, names it, and carries on with the rest.

**Why this priority**: Two markers admit more ways to be wrong than one, and every one of them is a way to
delete someone's writing. This story is the boundary condition on the other three and ships with them.

**Independent Test**: Present each malformed arrangement — a closing marker with no opening one, either
marker duplicated, a closing marker above the opening one — and assert nothing is written and exactly one
named warning is reported for each, with the run still succeeding.

**Acceptance Scenarios**:

1. **Given** a description carrying a closing marker with no opening one, **When** reconcile is run,
   **Then** nothing is written to that ticket and one warning names it.
2. **Given** a description carrying either marker more than once, **When** reconcile is run, **Then**
   nothing is written to that ticket and one warning names it.
3. **Given** a description whose closing marker precedes its opening one, **When** reconcile is run,
   **Then** nothing is written to that ticket and one warning names it.
4. **Given** any of the above on one ticket among many, **When** the run completes, **Then** every other
   ticket is processed normally and the command exits successfully.
5. **Given** any of the above, **When** the run completes, **Then** the ticket's recorded origin has made
   no difference — an untrustworthy arrangement is refused before the question of ownership is asked.

---

### User Story 5 - A settled ticket stays settled once the region has two ends (Priority: P1)

A team with a mirrored estate runs reconcile on a schedule against an unchanged specification. Nothing is
written, run after run — including for the stories whose task list the mirror keeps embedded in the
description.

**Why this priority**: Every path that decides "is this ticket already correct?" reads the mirror's region
back out of the stored description. Narrowing that region on the write path and not on the comparison path
produces a ticket that is rewritten on every run for ever — no data is lost, but the estate becomes noise
and the constitution's zero-churn guarantee is broken as thoroughly as by any defect this feature fixes.

**Independent Test**: Reconcile a fixture twice with no specification change, in both task-mirror modes,
and assert the second run reports zero created and zero updated on every tier.

**Acceptance Scenarios**:

1. **Given** an estate whose tickets already carry both markers and an unchanged specification, **When**
   reconcile is run, **Then** zero tickets are created and zero updated.
2. **Given** a story in checklist mode whose task list is already current, **When** reconcile is run,
   **Then** the checklist is recognised as unchanged and the ticket is not written to.
3. **Given** a story whose task list has genuinely changed, **When** reconcile is run, **Then** the list is
   refreshed inside the region and the closing marker remains exactly one, immediately below it.
4. **Given** a story that carries an embedded task list and is then reconciled with task mirroring set back
   to sub-tasks, **When** reconcile is run, **Then** the existing list is still detected and reported as
   it is today — the closing marker does not hide it.

---

### Edge Cases

- **An opening marker with no closing one.** Indistinguishable from a description written before this
  feature, so it is treated as the transition of User Story 3: the closing marker is placed at the end of
  the existing content. A human who deleted the closing marker and then wrote below it loses that text once,
  exactly as they do today. Accepted deliberately, and stated in the Assumptions.
- **A human writes _between_ the two markers.** Inside the region, which the mirror owns and replaces. Not
  preserved — that is what the markers are for, and what they now say plainly.
- **The tracker re-serialises the description** between runs. Both markers must still be found; the decision
  must not depend on the stored document being byte-stable across a round trip.
- **A description that is nothing but the two markers and an empty region.** Valid, written, and idempotent.
- **A human moves the closing marker upward**, cutting the region in two. The part now below the closing
  marker becomes their text and is preserved; the mirror rewrites the region between the markers. No loss.
- **Both markers deleted.** No region at all — resolved by the shipped origin-based ownership rule, not by
  this feature. A description the mirror created is replaced in full; a description a human handed over
  keeps its prose. This feature changes neither.
- **A human writes below the region on a ticket whose origin is `human`.** The suffix belongs to them for
  the same reason their prefix does. The two-marker verdict is reached before origin is consulted, so the
  answer cannot differ by tier or by how the ticket came to be mirrored.
- **A story's embedded task list is the region's last section.** The closing marker goes below it, and every
  reader that identifies the list as "from the `Tasks` heading onward" must stop at the closing marker
  rather than at the end of the description — otherwise the marker is read as part of the list and the
  comparison that keeps a settled ticket quiet stops matching.

## Requirements _(mandatory)_

### Functional Requirements

**Declaring the region**

- **FR-001**: Every description the mirror writes MUST carry an opening marker and a closing marker, in that
  order, with the generated content between them.
- **FR-002**: The mirror's region MUST be defined as the content **between** the two markers. Content before
  the opening marker and content after the closing marker MUST both be treated as text the mirror does not
  own.
- **FR-003**: A ticket the mirror creates MUST carry both markers from its first write. No write may produce
  a description with one marker and not the other.
- **FR-004**: Both markers MUST read as legible sentences explaining what they delimit, not as opaque
  tokens, and MUST be visually distinguishable from the generated content. The closing marker MUST state
  that what follows it is preserved, so a reader learns where they may write without consulting
  documentation.

**Preserving what is outside it**

- **FR-005**: Text below the closing marker MUST be preserved verbatim across every run, exactly as text
  above the opening marker already is.
- **FR-006**: Text above the opening marker MUST continue to be preserved verbatim — the existing guarantee
  is unchanged.
- **FR-007**: No branch introduced here may discard text outside the region. Where the mirror cannot
  determine the region with confidence, it MUST write nothing to that ticket.

**Acquiring the closing marker**

- **FR-008**: A description carrying an opening marker and no closing one MUST acquire the closing marker on
  its next ordinary write, with its generated content unchanged and its human text preserved.
- **FR-009**: The transition MUST require no manual step, no command of its own, no flag, and no
  configuration key.
- **FR-010**: The transition MUST NOT become a source of churn: the run following it MUST report zero
  writes for that ticket.

**Refusing what cannot be trusted**

- **FR-011**: A closing marker with no opening one, either marker occurring more than once, or a closing
  marker preceding its opening one MUST result in **zero writes** to that ticket and one warning naming it.
- **FR-012**: Every such warning MUST be non-blocking: the remaining tickets are still processed and the
  lifecycle command completes successfully.
- **FR-013**: The marker verdict MUST be reached **before** the ticket's recorded origin is consulted. An
  untrustworthy arrangement is refused identically whether the mirror or a human created the ticket.

**Living with what the region already carries**

- **FR-014**: Every path that reads the mirror's region back out of a stored description — the write path
  and the change-detection path alike — MUST use the same definition of that region. No path may keep
  reading from the opening marker to the end of the document.
- **FR-015**: Where a story's task list is embedded in the description, it MUST remain the region's last
  section, with the closing marker immediately below it, and MUST be identified as the content from its
  heading to the closing marker — never to the end of the description.
- **FR-016**: A story whose embedded task list is already current MUST produce zero writes, and a story
  reconciled after task mirroring is switched away from the embedded list MUST still be detected and
  reported exactly as it is today.

**Cross-cutting**

- **FR-017**: FR-001..FR-016 MUST hold identically on the parent, the story and the sub-task tiers.
- **FR-018**: The region decision MUST NOT depend on the stored description being byte-stable across a round
  trip through the tracker.
- **FR-019**: A run over an unchanged specification and an already-delimited ticket MUST produce zero writes,
  in either task-mirroring mode.
- **FR-020**: Every outcome introduced here MUST be reported through the existing counts and summary
  vocabulary. No new command, flag, configuration key, or output surface is introduced.
- **FR-021**: `--dry-run` MUST predict every payload and every warning this feature can produce, and write
  nothing.
- **FR-022**: Both ports MUST implement this identically, proven byte-for-byte by the shared conformance
  corpus.
- **FR-023**: The region decision MUST stay in the neutral engine, taking both markers as opaque parameters;
  the markers' wording and the tracker's document format MUST stay in the sink.

**What it may cost**

- **FR-024**: Adding the second marker MUST NOT add any per-item external process to the reconcile path.
  The per-phase process-count assertions that guard that path MUST still hold, unchanged, after this
  feature.
- **FR-025**: No value this feature composes — a spliced description, a retained suffix, a task list — may
  be handed to a program through a single command-line argument when it can grow with the size of the
  specification.

### Key Entities

- **Opening marker**: The line declaring where the mirror's region begins. Exists today, and is the text
  every recognition path already matches on.
- **Closing marker**: The line declaring where it ends. Introduced here, and the reason content may follow
  the region at all.
- **Managed region**: The content between the two markers — everything the mirror composes for one ticket,
  including a story's embedded task list where that is enabled. The unit replaced on every write.
- **Human prefix**: Content above the opening marker. Preserved today, unchanged here.
- **Human suffix**: Content below the closing marker. Introduced here as a place a person may safely write;
  today the same position is silently destroyed.
- **Region verdict**: The conclusion one run reaches about a description — well-delimited, awaiting its
  closing marker, or untrustworthy — and the sole determinant of what is written. Reached before the
  ticket's origin is consulted.
- **Region readback**: Any use of the stored description to answer "what does the mirror currently have
  there?" — the write splice, the idempotency comparison, and the embedded-task-list lookup. One definition
  serves all of them.

## Constitution Check _(mandatory)_

| #    | Principle                                                             | Proof of compliance                                                                                                                                                                                                                                                                                                                                            |
| ---- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| I    | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Served. The specification remains the source of truth for the region between the markers, and the ticket becomes explicit about which part that is. FR-005 stops the mirror silently regressing a ticket in the one position where it still does. No new exception: the mirror writes to a strictly smaller region than before.                                 |
| II   | Zero-Churn Idempotency                                                | FR-010, FR-014, FR-016 and FR-019 state it: the run after the transition, the run over a settled ticket, and the run over a story whose embedded task list is already current all write nothing. FR-014 is the load-bearing one — a region narrowed on the write path and not on the comparison path churns for ever. Nothing is keyed on an editable display name. |
| III  | Fail-Closed on Writes, Non-Blocking on Hooks                          | FR-007, FR-011 and FR-013 fail closed on any untrustworthy arrangement, before origin is even consulted — the ticket is not written rather than guessed at. FR-012 keeps every warning non-blocking.                                                                                                                                                            |
| IV   | Credential Security — Zero Tokens in the Tree, Ever                   | Unaffected. No credential is read, written, recorded, or reported.                                                                                                                                                                                                                                                                                              |
| V    | Separation of Team Config / Local Binding / Secrets                   | Unaffected, and FR-009 and FR-020 forbid a configuration key: the markers are behaviour, not options. Nothing is added to the committable config, the local binding, or the secrets layer.                                                                                                                                                                      |
| VI   | macOS / Linux / Windows Portability                                   | FR-022 requires both ports and byte-identical output proven by the shared conformance corpus. A two-marker splice is precisely where line-ending and pattern-matching divergence has bitten this project before, so the corpus carries the malformed arrangements explicitly, not only the happy path. FR-025 closes the Linux-only oversized-argument failure that macOS cannot see. |
| VII  | No Hard-Coded Assumptions About the Jira Workflow                     | No status, transition, screen, or field configuration is assumed. FR-018 requires tolerating whatever the tracker does to a stored document between runs.                                                                                                                                                                                                       |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface                 | FR-023 states it, and this is the engine's existing shape: the neutral splice already takes a begin token and an end token as parameters for the version-marked README block and the recorded field defaults. This feature brings the description path onto that same two-marker contract rather than adding a second concept.                                  |
| IX   | Two-Tier Privacy Guard, With an Allowlist                             | Unaffected in kind. One marker's worth of text is added to what the mirror composes; the guard-then-write ordering, the tiers, and the exit codes are untouched.                                                                                                                                                                                                |
| X    | Self-Healing Automatic Mirror                                         | Preserved and made precise. The mirror still restores its own region in full whenever it is damaged; FR-002 states exactly which content that region is, so healing can no longer reach outside it. FR-008 and FR-009 make the transition itself self-healing: one ordinary run, no manual step.                                                                |
| XI   | Universal Dry-Run and Auditability                                    | FR-021 requires `--dry-run` to predict every payload and warning while writing nothing. FR-020 keeps every outcome in the run summary. No destructive operation is added.                                                                                                                                                                                       |
| XII  | Quality and Catalog Publication                                       | A change to shipped behaviour that closes a data-loss defect, carrying a CHANGELOG entry and gated by the full suite, the conformance corpus, the process-budget and argument-size guards, and the linters on all three operating systems. Its visible effect on an existing estate — the one-time transition of FR-008 — is documented for consumers.          |
| XIII | TDD With a Minimum 80% Coverage                                       | Every user story states an independent test. The reproduction — human text below the region, one run, assert it survives — is written first and fails without the change; it is the measurement that motivated the feature. The checklist-mode readback of FR-015 gets its own failing test before the region is narrowed.                                      |
| XIV  | KISS — The Simplest Solution That Satisfies the Spec                  | Nothing is invented. The neutral engine already implements a begin/end splice with this exact malformed-marker taxonomy and its zero-output refusal, and two config writers already use it; the description path is the only caller still using the one-marker variant. This removes a special case rather than adding one.                                     |
| XV   | YAGNI — Nothing Is Built Before a Spec Requires It                    | Scope is the closing marker and what it makes possible. Configurable marker wording, rewording the opening marker, multiple regions per description, reading the human suffix back into the specification, and repairing descriptions damaged before this ships are all named out of scope and are not built.                                                   |
| XVI  | Human Readable — Readable by a Human Above All                        | The reporter's own motivation, and FR-004 states it: a reader sees where generated content starts and stops, and therefore where they may write. The alternative on offer today is an unmarked edge that quietly eats what is written past it.                                                                                                                  |

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: 100% of the characters a human writes below the mirror's region are present, unchanged, after
  any number of subsequent runs. Today the figure is 0%.
- **SC-002**: 100% of descriptions the mirror writes carry exactly one opening marker and exactly one
  closing marker, in that order.
- **SC-003**: An existing estate acquires the closing marker in one ordinary run, with zero manual ticket
  edits and zero characters of human text lost.
- **SC-004**: The run following the transition, and the run over any settled ticket, report zero created and
  zero updated — in both task-mirroring modes.
- **SC-005**: 100% of untrustworthy marker arrangements produce zero writes to that ticket and exactly one
  warning naming it; 0% produce a partial write, and 0% vary by the ticket's recorded origin.
- **SC-006**: A reader shown a mirrored ticket, without documentation, can identify where the generated
  content ends and whether it is safe to write below it.
- **SC-007**: Both ports produce byte-identical output for every scenario introduced here — the happy path
  and every malformed arrangement — proven by the shared conformance corpus.
- **SC-008**: A story whose embedded task list is unchanged produces zero writes, and one whose list has
  changed produces exactly one write leaving exactly one closing marker below the list.
- **SC-009**: The number of external processes a reconcile run creates per ticket is unchanged by this
  feature: every per-phase process-count assertion passes with its existing figure.
- **SC-010**: No argument this feature causes any call site to build exceeds the 128 KiB single-argument
  limit on the largest reference specification, measured on every host.

## Assumptions

- The reporter's request is delimitation; the data loss below the region is the reason it is worth building
  now rather than later. Both are served by the same change, and the requirements are written so that the
  loss is what gets tested.
- A closing marker's wording follows the opening marker's: a plain sentence a reader understands without
  documentation, in the same visual treatment. It is not configurable.
- **The opening marker's wording is not changed by this feature**, even though it currently tells the reader
  not to edit below it — which the closing marker makes narrower than the truth. That text is the anchor
  every recognition path matches on; changing it would make every already-mirrored ticket unrecognisable in
  the same run that narrows the region, which is the one combination that could lose a human's words at
  scale. The closing marker carries the "you may write below this" statement instead, and being the nearer
  and more specific of the two, it is what a reader at that position acts on. Rewording the opening marker
  is a separate change with its own transition, listed out of scope.
- An opening marker with no closing one is read as a description written before this feature, never as
  tampering. A human who deletes the closing marker and writes below it therefore loses that text once, on
  the next run. The alternative — refusing to write to every ticket in an estate that predates the feature —
  is worse, and the transition happens once.
- Human text is preserved in position: what was above stays above, what was below stays below. No
  reordering, no merging into one block.
- Both ports carry the current behaviour identically and both are changed in the same commit.
- The existing warning vocabulary and run-summary counts are sufficient to report every outcome here.
- The description field is already fetched for every recognised ticket, so no additional read is needed to
  reach the second marker.

## Dependencies

- **Shipped, and this feature builds directly on it — `018-preserve-ticket-content` (0.11.2).** It
  introduced the boundary marker and the guarantee that content above it is preserved. This feature is the
  other half of that guarantee.
- **Shipped, and this feature must slot in ahead of it — `019-fix-duplicate-acceptance-criteria`
  (0.12.1).** It answers _whose_ text an undelimited description is, by the ticket's recorded origin. That
  question is now asked only when the marker count is not one; FR-013 keeps the marker verdict ahead of it
  so the two rules compose in a stated order instead of competing. The rebase this specification originally
  anticipated has happened — 019 is in `main`.
- **Shipped, and it put content inside the region that this feature must not cut off —
  `022-story-task-checklist` (0.14.0).** A story's task list is the region's last section under checklist
  mode, and is located as "from its heading onward". FR-015 and FR-016 are entirely owed to this feature
  landing first.
- **Shipped, and it constrains how this may be built — `024-reconcile-local-performance` (0.15.0) and
  `025-spawn-budget-guardrails` (0.16.0).** The process budget is now a documented, tested rule:
  `docs/11-process-budget.md`. FR-024 and FR-025 restate the two halves that apply here — a second marker
  must not become a second per-item process, and the values the splice composes must not travel through a
  single command-line argument.
- **Shipped, and it does not interact — `023-advance-board-position` (0.16.0).** It moves a ticket's board
  position and reads no description. Named here only so a reviewer does not go looking.

## Out of Scope

- Making either marker's wording configurable or operator-authored.
- Rewording the existing opening marker, and the re-recognition transition that would require.
- More than one managed region in a single description.
- Reading the human suffix back into the specification.
- Repairing descriptions already damaged — text lost below the region before this ships is not recoverable
  and no attempt is made to reconstruct it.
- Changing what the generated content itself contains.
- Applying markers to any tracker field other than the description.
- Reducing the process count of the reconcile path. FR-024 requires this feature not to make it worse; the
  two known argument-routing gaps recorded in `docs/11-process-budget.md` are not this feature's to close.
