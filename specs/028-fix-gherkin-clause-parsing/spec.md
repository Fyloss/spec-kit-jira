# Feature Specification: A Scenario Written the Template's Way Reaches the Ticket Intact

**Feature Branch**: `fix/duplicate-acceptance-criteria-2`

**Created**: 2026-08-16

**Status**: Draft

**Input**: User description: "There is currently a bug when a new Story is created by this extension on Jira: in the Acceptance Criteria part, we observe that each leading Gherkin word (Given, When, Then) is duplicated — the first one in normal text, the second one right next to it in bold. Example: Given Given a user arrives on the Homepage, ... The second bug is that each acceptance criterion is duplicated 3 times per Story."

**Clarified scope** (reporter, 2026-08-16): "No need to handle the migration of old Stories on Jira that
carry the bug — for the moment I am the only user of this extension." Repairing an existing estate is
therefore not wanted, and there is no installed base to protect. Stories already carrying a corrupted panel
are the reporter's own; whether the next ordinary run happens to repair them is a welcome side effect of the
mirror's normal behaviour, never a requirement this feature must satisfy or test.

## The reported defect

A newly created story shows an Acceptance Criteria panel in which every clause is wrong in two visible
ways at once:

1. **The keyword is doubled.** Each clause reads `Given **Given** a user arrives on the Homepage, …` —
   the keyword once in plain text, immediately followed by the same keyword in bold.
2. **Each criterion appears three times.** One acceptance scenario produces three clauses, and all three
   carry the same complete sentence, differing only in the plain keyword prefixed to them.

Both are the same defect seen from two angles, and the ticket is unreadable: a scenario meant to read
"Given a user arrives, When they click Login, Then the form appears" instead reads as three near-identical
paragraphs, each beginning with a stuttered keyword.

**This is not the feature 019 defect.** 019 addressed a *duplicate acceptance-criteria section* on a
re-run — the mirror re-rendering its own region beneath itself on an update. This one strikes a **newly
created** story on its **first** write, needs no re-run at all, and multiplies each *clause* rather than
each *section*. 019's fix is correct and stays; this is an independent defect in how a scenario line is
read out of `spec.md`.

**Where the defect actually lives — measured, not assumed.** The specification template ships acceptance
scenarios in exactly this form, on one line:

```
1. **Given** [initial state], **When** [action], **Then** [expected outcome]
```

The keyword-emphasis wrapper is recognised *after* a keyword but not *before* it. On the one-clause-per-line
reading path both sides are handled and the clause is extracted correctly; on the single-line
three-clause reading path only the trailing side is handled. A line written the template's own way
therefore fails to split, and the whole line — bold markup and all — is assigned to the Given bucket, the
When bucket and the Then bucket alike. The renderer then prefixes each bucket with its plain keyword. Three
buckets holding one sentence, each stuttered: both reported symptoms, one cause.

Measured on the two reported inputs:

| Input | macOS/Linux port | Windows port |
| --- | --- | --- |
| `1. **Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.` | one scenario whose Given, When and Then each carry the entire line, bold keywords included | **no scenario at all** |
| `1. Given a user arrives on the Homepage, When they click Login, Then the login form appears.` | correct | correct |

The second column is a **cross-port divergence on the template's own output**: one port writes a triplicated
stuttered panel, the other writes an empty one. Neither is right, and the shared conformance corpus does not
currently carry this input, which is why both went unnoticed.

**A third face of the same cause.** A scenario wrapped across several lines — the form most specifications in
this repository actually use — loses its clause boundaries the same way and yields **no acceptance criteria
at all** on both ports. Measured across `specs/*/spec.md`: 900 indented continuation lines follow a scenario
opener, and 800 of them continue the sentence in plain text. Those 800 are addressed here. The remaining 100
wrap at a clause boundary, so the continuation line itself opens with a keyword; that shape is genuinely
ambiguous with the indented one-clause-per-line form and is **out of scope** — see FR-022 and "Out of Scope"
below. The reporter did not name any of this because their specifications keep each scenario on one line, but
it is the identical recognition weakness on the identical input vocabulary, it silently empties the panel
rather than corrupting it, and a fix that left the common shape standing would be reported back within a
release. It is therefore in scope, and marked as such below so the reporter can strike it if they prefer a
narrower change.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A scenario written the template's way reaches the ticket as three distinct clauses (Priority: P1)

A developer writes acceptance scenarios in the form the specification template hands them — one line, three emphasised keywords — and runs reconcile. The new story's Acceptance Criteria panel shows three clauses: a Given carrying only the initial state, a When carrying only the action, a Then carrying only the outcome. Each keyword appears once.

**Why this priority**: This is the reported defect in the reporter's own words, on the path that creates every new story, using the exact form the tool's own template produces. Every scenario in every specification is affected, so the command's primary output is unreadable for its primary input.

**Independent Test**: Take one single-line scenario with emphasised keywords, run reconcile against a new story, and assert the panel carries exactly three clauses whose texts are disjoint and none of which repeats its keyword. Fails before the change on both ports — differently on each — and passes after.

**Acceptance Scenarios**:

1. **Given** a specification whose acceptance scenario is a single line with emphasised Given/When/Then keywords, **When** reconcile creates the story, **Then** the panel carries exactly three clauses whose combined text reproduces the scenario once and no clause begins with a repeated keyword.
2. **Given** the same scenario, **When** the panel is read, **Then** no clause contains the text of another clause.
3. **Given** a scenario whose keywords carry no emphasis at all, **When** reconcile creates the story, **Then** the result is unchanged from today — the currently correct path stays correct.
4. **Given** a scenario using any emphasis style the parser already accepts elsewhere, **When** reconcile creates the story, **Then** it is read exactly as the bold form is.
5. **Given** a scenario clause whose own body contains an emphasised word, **When** reconcile creates the story, **Then** that emphasis survives into the clause and is not mistaken for a keyword.

---

### User Story 2 - The emphasis around a keyword never reaches the reader (Priority: P1)

A reader opens the story in the tracker. Each clause begins with its keyword, rendered once, in the panel's own styling. The bold markup the author typed around the keyword in the specification is a source-file convention and never appears as a second word.

**Why this priority**: This is the reporter's first named symptom, stated separately because it is what a reader actually sees and because it must hold for every clause the panel can produce — not only for the single-line form of User Story 1. It ships with User Story 1 and is verified independently of it.

**Independent Test**: For every accepted way of writing a scenario, assert that no rendered clause's text begins with its own keyword.

**Acceptance Scenarios**:

1. **Given** any scenario whose keyword the author emphasised, **When** reconcile creates the story, **Then** the rendered clause names its keyword exactly once and the author's emphasis appears nowhere in the clause body.
2. **Given** a scenario using an And or But continuation whose keyword is emphasised, **When** reconcile creates the story, **Then** that continuation joins the preceding clause and does not repeat any keyword.
3. **Given** a clause whose body legitimately contains the word "when" or "then" in prose, **When** reconcile creates the story, **Then** the clause is not split at that word and its text survives whole.

---

### User Story 3 - Both ports produce the same panel from the same specification (Priority: P1)

A team split across macOS, Linux and Windows runs reconcile from the same specification. Every member sees the same Acceptance Criteria panel on the same ticket, and a re-run from a different operating system writes nothing.

**Why this priority**: The two ports currently disagree on the template's own output — one triplicates, the other silently produces nothing. That is a Principle VI violation shipping today, and it means an operator on one platform can quietly erase a panel an operator on the other just wrote. It ranks P1 with the stories above and ships with them, never after.

**Independent Test**: Run every scenario form introduced here through the shared conformance corpus and assert byte-identical output from both ports.

**Acceptance Scenarios**:

1. **Given** any scenario form this feature accepts, **When** both ports render it, **Then** their output is byte-identical.
2. **Given** a story written by one port, **When** reconcile is re-run by the other port from the same unchanged specification, **Then** zero tickets are updated.
3. **Given** a scenario form neither port can read as a scenario, **When** both ports process it, **Then** both produce the same outcome for it rather than one dropping it and the other inventing content.

---

### User Story 4 - A scenario wrapped across several lines is read whole (Priority: P2, in scope by extension)

A developer writes a scenario that does not fit one line and wraps it the way every specification in this repository is written. Reconcile reads it as one scenario and the panel shows its three clauses.

**Why this priority**: Not named by the reporter, and included deliberately — see "A third face of the same cause" above. It is the same recognition weakness on the same input vocabulary, its failure mode is a silently empty panel rather than a visibly wrong one, and it is what this project's own specifications would hit. It ranks P2 because the reported symptom is P1 and this must not delay it; it is separable and may be struck without affecting User Stories 1–3.

**Independent Test**: Take one scenario wrapped across three lines with emphasised keywords, run reconcile, and assert the panel carries three clauses reproducing the whole scenario. Fails before the change on both ports — with an empty panel — and passes after.

**Acceptance Scenarios**:

1. **Given** a scenario whose text wraps across several lines, **When** reconcile creates the story, **Then** the panel carries its three clauses and their combined text reproduces the whole scenario including the wrapped remainder.
2. **Given** a scenario wrapped inside a clause, **When** the panel is read, **Then** no clause is truncated at the point where the source line wrapped.
3. **Given** two wrapped scenarios in sequence, **When** reconcile creates the story, **Then** they remain two scenarios and no clause of one is joined to the other.
4. **Given** a scenario wrapped exactly at a clause boundary, so its continuation line opens with a keyword, **When** reconcile creates the story, **Then** both ports produce the same outcome and no truncated or mis-assigned clause reaches the panel.

---

### User Story 5 - Text that is not a scenario is still not turned into one (Priority: P2)

A developer writes ordinary prose, a heading, or a bullet list that happens to contain the words "given", "when" or "then" somewhere in a sentence. None of it becomes an acceptance criterion.

**Why this priority**: Loosening keyword recognition is exactly the change that could start reading prose as scenarios. This story is the boundary condition on the four above and ships with them — a panel filled with sentences that are not criteria is no better than the stuttered one being fixed here.

**Independent Test**: Run a specification containing prose using those words mid-sentence, assert the panel contains only the intended scenarios and nothing else.

**Acceptance Scenarios**:

1. **Given** a paragraph of prose containing "given", "when" or "then" mid-sentence, **When** reconcile creates the story, **Then** no clause is produced from that paragraph.
2. **Given** a specification whose acceptance-scenario section is empty, **When** reconcile creates the story, **Then** the outcome is unchanged from today — no panel content invented, no warning added.
3. **Given** an incomplete scenario that never reaches a Then, **When** reconcile creates the story, **Then** it is handled exactly as today and no partial clause is emitted.

---

### Edge Cases

- **A keyword emphasised on one side only** — the author wrote the opening marker and not the closing one, or the reverse. Read as a keyword, with the stray marker never surfacing as a second word.
- **A clause body containing an emphasised word.** The emphasis belongs to the reader's text and survives; only the wrapper immediately around the keyword is consumed.
- **A clause whose own prose contains "when" or "then".** Not a split point. The existing preference for an explicit clause boundary over a bare keyword governs, and this feature must not weaken it.
- **A scenario mixing forms** — an emphasised Given and a bare When on the same line. Read as one scenario, both clauses correct.
- **A continuation keyword (And, But) that is emphasised.** Joins the clause it follows; never starts a new scenario and never repeats a keyword.
- **A line carrying the three keywords but no separators at all.** Whatever the two ports do here today, they must do the same thing as each other after this change, and it must never be "assign the whole line to all three clauses".
- **A wrapped scenario whose continuation line itself begins with an emphasised keyword.** Belongs to the same scenario, not a new one.
- **A story whose specification yields no readable scenario.** Unchanged from today: no panel content, no invented clause, and identical on both ports.

## Requirements *(mandatory)*

### Functional Requirements

**Reading a scenario**

- **FR-001**: A Given/When/Then keyword MUST be recognised whether or not the author emphasised it, and the recognition MUST be symmetric — a wrapper before the keyword MUST be accepted wherever a wrapper after it already is.
- **FR-002**: Recognition MUST be identical on the single-line three-clause form and on the one-clause-per-line form. No form the tool's own specification template produces may be read by a weaker path than any other.
- **FR-003**: The emphasis wrapper immediately surrounding a keyword MUST be consumed as part of the keyword and MUST NOT appear in the clause's text. Every other markup in the clause MUST reach the reader intact.
- **FR-004**: A single scenario MUST produce clauses whose texts are disjoint. No branch may assign the same source text to more than one of the Given, When and Then clauses.
- **FR-005**: A line the parser cannot split into distinct clauses MUST NOT be emitted as a scenario at all. Emitting one whose clauses all carry the unsplit line is forbidden outright.
- **FR-006**: An emphasised And or But continuation MUST join the preceding clause exactly as its unadorned form does.
- **FR-007**: The existing preference for an explicit clause boundary over a bare keyword MUST be preserved, so a clause whose prose contains "when" or "then" is not split at that word.
- **FR-008** *(User Story 4, in scope by extension)*: A scenario whose text wraps across several source lines **at a point inside a clause** MUST be read as one scenario carrying its full text, with no clause truncated at the wrap point and no two scenarios merged. A wrap falling exactly on a clause boundary — where the continuation line itself opens with a keyword — is outside this requirement and is governed by FR-022.
- **FR-022**: A scenario wrapped at a clause boundary MUST behave identically on both ports and MUST NOT emit a truncated or mis-assigned clause. It is not required to be read as one scenario; the current outcome — no scenario emitted — is acceptable and MUST be pinned by a test so it is a recorded decision rather than an accident.

**What the reader sees**

- **FR-009**: Each rendered clause MUST name its keyword exactly once.
- **FR-010**: The Acceptance Criteria panel MUST carry exactly one clause per clause the author wrote — no scenario may be multiplied, and User Story 1's reported threefold repetition MUST NOT occur by any route.
- **FR-011**: Each clause MUST carry the author's text for that clause whole — nothing truncated at either end, nothing added. The keywords and the `,`/`;` that separate clauses belong to the scenario's grammar and are consumed by recognition; every other character the author wrote MUST reach the reader in exactly one clause.

**Not inventing criteria**

- **FR-012**: Prose, headings and list items that merely contain the words "given", "when" or "then" MUST NOT produce clauses.
- **FR-013**: A scenario that never reaches a Then MUST be handled exactly as today, and no partial clause may be emitted.
- **FR-014**: An absent or empty acceptance-scenario section MUST produce the outcome it produces today — no panel content, no warning added.

**Cross-port**

- **FR-015**: Both ports MUST read every scenario form identically, proven byte-for-byte by the shared conformance corpus. The corpus MUST carry the emphasised single-line form, the emphasised wrapped form and the unadorned form explicitly, since the absence of the first is why the current divergence shipped.
- **FR-016**: The current divergence — one port triplicating a clause where the other emits none — MUST be eliminated on every input, including inputs neither port can read as a scenario.

**Cross-cutting**

- **FR-017**: A run over an unchanged specification and an already-settled ticket MUST produce zero writes, including across a change of operating system.
- **FR-018**: Every outcome MUST be reported through the existing counts and summary vocabulary. No new command, flag, configuration key, or output surface is introduced.
- **FR-019**: `--dry-run` MUST predict every payload this feature can produce, and write nothing.
- **FR-020**: Scenario recognition MUST stay in the neutral engine and the keyword-to-panel rendering in the sink; no tracker vocabulary may cross into the engine to satisfy this fix.
- **FR-021**: No loop introduced or altered here may spawn an external process per scenario, per clause, or per line.

### Key Entities

- **Acceptance scenario**: One Given/When/Then statement as the author wrote it in the specification. May occupy one source line or wrap across several.
- **Clause**: One of the three parts of a scenario. Carries the author's text for that part and nothing belonging to another part.
- **Keyword**: The word Given, When, Then, And or But opening a clause. Belongs to the scenario's grammar, not to its text — however the author chose to emphasise it in the source.
- **Emphasis wrapper**: The markdown markers an author may put around a keyword. A source-file convention that must be consumed with the keyword and must never reach the reader as a second word.
- **Acceptance Criteria panel**: The part of a ticket's managed region carrying the rendered clauses. The surface where both reported symptoms are visible.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Directly served. The specification is the source of truth and the ticket currently contradicts it — three clauses where the author wrote one, keywords the author wrote once appearing twice. FR-004, FR-010 and FR-011 make the ticket say what the file says. No new exception; no ticket or region is written that is not written today. |
| II | Zero-Churn Idempotency | FR-017 states it, and extends it across a change of operating system, which FR-015 and FR-016 make achievable. Nothing here keys on an operator-editable display name. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-005 is the fail-closed rule of this feature: a line that cannot be split into distinct clauses yields nothing rather than a guess spread across all three. FR-012, FR-013 and FR-014 refuse to invent content. No blocking behaviour is added. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. No credential is read, written, recorded, or reported. |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected, and FR-018 forbids a configuration key: how a scenario is read is behaviour, not an option. Nothing is added to the committable config, the local binding, or the secrets layer. |
| VI | macOS / Linux / Windows Portability | The principle this feature repairs. The two ports today disagree on the tool's own template output — measured, and recorded in the table above. FR-015 and FR-016 require byte-identical behaviour and require the corpus to carry the inputs whose absence let the divergence ship. Windows behaviour is proven on the real runner, not by emulation. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. No status, transition, screen, or field configuration is read or assumed. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | FR-020 states it. Recognising a scenario is engine work on plain markdown; naming the keyword in the rendered panel stays in the sink. The fix touches only the engine's reading and does not move the boundary. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. No new text is composed and no scanned surface changes — this feature writes strictly less than today, and the guard-then-write ordering is untouched. |
| X | Self-Healing Automatic Mirror | Unaffected as an obligation, and not leaned on. A story created before this fix carries a corrupted panel inside the mirror's own region, so the ordinary re-render would clear it — but the reporter has declined migration and is the extension's only user, so no requirement here depends on that happening and no scenario tests it. The principle is not weakened: nothing in this feature stops the mirror healing its own region. |
| XI | Universal Dry-Run and Auditability | FR-019 requires `--dry-run` to predict every payload while writing nothing. FR-018 keeps every outcome in the existing run summary. No destructive operation is added. |
| XII | Quality and Catalog Publication | A defect fix on shipped behaviour, carrying a CHANGELOG entry and gated by the full suite, the conformance corpus, and the linters on all three operating systems. |
| XIII | TDD With a Minimum 80% Coverage | Every user story states an independent test. The reproduction — the reporter's own single-line emphasised scenario, asserted to produce three disjoint unstuttered clauses — is written first and fails without the change on both ports. Per the project's bug-fix policy, the failing test precedes the fix. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Nothing is invented. The emphasis wrapper, the keyword vocabulary, the clause buckets and the boundary preference all exist. One asymmetry is removed: a wrapper is accepted before a keyword wherever it is already accepted after one. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Scope is the reported defect plus the one extension named and justified above. A general markdown parser, a Gherkin dialect, configurable keywords, localisation of keywords, and repairing already-written tickets are named out of scope and are not built. |
| XVI | Human Readable — Readable by a Human Above All | The point of the feature. A ticket that reads "Given a user arrives on the Homepage" instead of "Given **Given** a user arrives on the Homepage, When they click Login, Then the form appears" repeated three times. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 0% of rendered clauses begin with a repetition of their own keyword — measured across an estate whose specifications use the template's emphasised form throughout.
- **SC-002**: The number of clauses in a story's panel equals the number of clauses its author wrote, for 100% of stories.
- **SC-003**: No source substring is assigned to more than one clause of the same scenario — 0 overlapping clauses across the estate.
- **SC-004**: 100% of scenarios written in the specification template's own default form are present in the panel. The current figure is 0% on both ports: one renders them corrupted, the other renders nothing.
- **SC-005**: 100% of scenarios wrapped **inside a clause** are present in the panel, with no clause truncated at the wrap point. The current figure is 0%. Scenarios wrapped at a clause boundary — 100 of the 900 continuation lines measured in this repository — are excluded by FR-022 and remain absent, identically on both ports.
- **SC-006**: Both ports produce byte-identical output for every scenario form covered here, proven by the shared conformance corpus, including for inputs that yield no scenario.
- **SC-007**: A re-run over an unchanged specification reports zero created and zero updated, including when the two runs come from different operating systems.
- **SC-008**: 0 clauses are produced from prose that merely contains the words "given", "when" or "then".

## Assumptions

- The reporter's specifications keep each acceptance scenario on a single line, which is why they saw the triplicated panel rather than the empty one. Both faces are addressed.
- The reporter is on a macOS or Linux host. The Windows port's behaviour on the same input was measured separately and is worse, not better.
- The emphasised form is the form the tool's own specification template produces, so it is the normal input and not an unusual one. Requirements treat it as the default case rather than an accommodation.
- The unadorned form works correctly today; it was measured, not assumed, and is protected here by regression scenarios rather than changed.
- There is no installed base. The reporter is the extension's only user, stated 2026-08-16, and has declined any handling of stories already carrying the bug. Every requirement here is therefore about what the *next* run writes, never about what an earlier one left behind.
- Stories already carrying a corrupted panel sit inside the region the mirror re-renders from the specification, so an ordinary run would clear them. That is a side effect, not a promise: it is neither required, specified, nor tested, and the reporter cleans or recreates such stories by hand if they prefer.
- The existing run-summary counts are sufficient to report every outcome here; no warning vocabulary is added.

## Out of Scope

- **A general markdown or Gherkin parser.** The fix removes one recognition asymmetry; it does not adopt a dialect, a grammar, or a third-party parsing model.
- **Configurable, localised, or author-defined keywords.** Given/When/Then/And/But in English stay the vocabulary.
- **Repairing, migrating, or detecting stories already carrying the bug.** Explicitly declined by the reporter, who is the extension's only user: there is no installed base. No repair command, flag, migration mode, or detection pass is built, and no acceptance scenario asserts anything about a pre-existing corrupted panel.
- **Re-opening feature 019's section-level duplication.** That defect is distinct, its fix is correct, and it is protected here by regression scenarios only.
- **Changing how the Acceptance Criteria panel looks** — its heading, its ordering, its panel type, or the styling of the keyword.
- **Reading ticket text back into the specification.**
- **Mirroring any content the mirror does not already mirror today.**
- **Reading a scenario wrapped exactly at a clause boundary.** The continuation line opens with a keyword and is indistinguishable from an indented one-clause-per-line scenario without guessing. Both ports agree on dropping it (FR-022), and a specification that wants it read moves the wrap one word earlier.
