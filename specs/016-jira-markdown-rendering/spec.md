# Feature Specification: Markdown Rendering in Jira Descriptions

**Feature Branch**: `feat/convert-md-to-jira`

**Created**: 2026-08-04

**Status**: Draft

**Input**: User description: "The description of Jira tickets, which comes from Spec Kit's Markdown files, is displayed in the tickets but is badly formatted — Jira users currently see the Markdown tags in plain text. I want formatting to be applied when writing to a Jira ticket, so that it renders properly."

## User Scenarios & Testing *(mandatory)*

The people affected here are **Jira readers** — product owners, testers, and
developers who never open the repository and know the feature only through the
ticket the bridge writes. Today the ticket shows them the raw punctuation of a
Markdown file. Every story below is measured on what that reader sees in Jira,
not on what the bridge computes.

### User Story 1 - Emphasis and links read as formatting, not as punctuation (Priority: P1)

A spec file says `- **FR-012**: the system MUST reject an expired token` and
`see the [setup guide](https://example.invalid/setup)`. A Jira reader opening
the synced ticket sees **FR-012** in bold and a clickable *setup guide* link.
They never see `**`, backticks, or `[...](...)` punctuation in the ticket body.

**Why this priority**: This is the reported defect. Raw markup is the single
most visible failure — it makes every synced description look broken, and it
degrades the most important text (requirement identifiers, emphasised MUST/MUST
NOT clauses) precisely because that text is the text authors emphasise. Fixing
inline markup alone already turns an unreadable ticket into a readable one.

**Independent Test**: Sync a spec whose description prose contains bold, italic,
inline code, a Markdown link, and strikethrough; open the ticket and confirm each
one renders as native Jira formatting and that no Markdown delimiter character
survives in the visible text.

**Acceptance Scenarios**:

1. **Given** a spec whose overview paragraph contains `**bold**`, **When** the
   ticket is written, **Then** the reader sees the word in bold and no asterisks.
2. **Given** a spec paragraph containing `` `reconcile --dry-run` ``, **When**
   the ticket is written, **Then** the reader sees monospaced inline code and no
   backticks.
3. **Given** a spec paragraph containing `[setup guide](https://example.invalid/setup)`,
   **When** the ticket is written, **Then** the reader sees a clickable link
   labelled "setup guide" pointing at that address, and no bracket syntax.
4. **Given** a spec paragraph containing `*emphasis*`, `_emphasis_`, and
   `~~withdrawn~~`, **When** the ticket is written, **Then** the reader sees
   italic, italic, and struck-through text respectively.
5. **Given** a spec paragraph containing an escaped literal such as `\*not bold\*`
   or a lone asterisk used as arithmetic, **When** the ticket is written, **Then**
   the reader sees the literal characters as plain text and no accidental
   emphasis is applied.
6. **Given** a spec paragraph containing nested markup such as
   `**bold with `code` inside**`, **When** the ticket is written, **Then** both
   the bold and the code formatting are applied to the appropriate spans.
7. **Given** any spec file at all, **When** the ticket is written from it,
   **Then** every byte of that file other than the bridge's own ticket-identifier
   marker lines is identical to what it was before the run — the formatting
   travels to Jira and never back into the source.

---

### User Story 2 - Document structure survives the crossing (Priority: P2)

A spec's overview uses a bullet list and a fenced code block. Today those arrive
in Jira as one run-on paragraph. After this change the reader sees a real bulleted
list and a real code block, matching the shape the author wrote.

**Why this priority**: Structure loss is a genuine readability defect but a
quieter one than P1 — nothing looks *broken*, it just reads worse. A ticket that
fixes only P1 is already shippable and already solves the complaint as reported.

**Independent Test**: Sync a spec whose description prose contains a bullet list,
an ordered list, and a fenced code block; confirm the ticket shows three distinct
rendered blocks rather than merged prose.

**Acceptance Scenarios**:

1. **Given** a spec overview containing consecutive `- ` lines, **When** the
   ticket is written, **Then** the reader sees a bulleted list with one item per
   source line, not a single merged paragraph.
2. **Given** a spec overview containing consecutive `1.` / `2.` lines, **When**
   the ticket is written, **Then** the reader sees a numbered list preserving the
   source order.
3. **Given** a spec overview containing a fenced code block, **When** the ticket
   is written, **Then** the reader sees a code block whose content is reproduced
   verbatim, with no Markdown interpretation applied inside it and no fence
   characters visible.
4. **Given** a spec section heading inside the synced region, **When** the ticket
   is written, **Then** the reader sees a heading, not a line starting with `#`.

---

### User Story 3 - Already-synced tickets self-heal, then stay quiet (Priority: P3)

A team has dozens of tickets already carrying badly formatted descriptions. The
next reconcile rewrites each one with correct formatting. Every reconcile after
that leaves them untouched.

**Why this priority**: Without this, the fix only reaches new tickets and the
existing backlog stays ugly. It ranks below the rendering itself because it is
worthless until P1 works, and it carries the churn risk that Principle II exists
to prevent.

**Independent Test**: Run reconcile twice against tickets written by the previous
behaviour; the first run updates their descriptions, the second reports no change.

**Acceptance Scenarios**:

1. **Given** a ticket whose description was written by the previous behaviour,
   **When** reconcile runs, **Then** its description is rewritten with correct
   formatting and the change is reported as an update.
2. **Given** that same ticket immediately after, **When** reconcile runs again
   with the spec unchanged, **Then** no write is issued and no change is reported.
3. **Given** a human-origin ticket with human-authored text above the managed
   delimiter, **When** reconcile rewrites the managed region, **Then** the
   human-authored text above the delimiter is preserved byte-for-byte.
4. **Given** any of the above, **When** reconcile runs in dry-run mode, **Then**
   the preview shows the description change without writing anything.

---

### Edge Cases

- **Unsupported construct**: a table, image, footnote, or raw HTML tag appears in
  synced prose. The reader must never see its raw syntax; it degrades to readable
  plain text (an image becomes its alt text or its label).
- **Unbalanced delimiters**: a paragraph contains a single `**` with no closing
  pair, or a `[label](` with no closing parenthesis. The reader sees the
  characters as literal text; the bridge does not guess a span, and does not fail.
- **Markup inside a code span or code block**: `` `**not bold**` `` renders as
  monospaced literal `**not bold**`.
- **Link with an unsafe or relative target**: a Markdown link whose target is not
  an absolute `http`/`https` address (a relative path, a `mailto:`, a `javascript:`
  scheme) must not become a live link; the reader sees the label and the target as
  readable text.
- **Very long or pathological input**: a paragraph with hundreds of markup spans,
  or delimiters nested many levels deep, must render without truncating content
  and without a noticeable delay in the reconcile run.
- **Non-ASCII content**: accented characters, CJK, and emoji inside a formatted
  span survive unchanged.
- **Windows line endings**: a spec file saved with CRLF produces exactly the same
  rendered description as the same file saved with LF.
- **Author reformats a spec after a sync**: a spec file whose prose has been
  rewritten (markup added, removed, or restyled) syncs the new rendering to the
  ticket, and its prose is still exactly as the author left it afterwards.
- **Spec file that renders imperfectly**: a construct the bridge cannot render
  natively is never "fixed" in the source by rewriting the author's Markdown into
  a construct the bridge prefers; the file is left alone and the degradation rule
  applies on the Jira side only.

## Requirements *(mandatory)*

### Functional Requirements

**Direction of the transformation — spec files are read-only**

- **FR-000**: Formatting conversion MUST happen only on the path from a spec file
  to a Jira ticket. Rendering MUST contribute **no write of any kind** to a Spec
  Kit source file: no reformatting, no normalising, no rewriting of the author's
  Markdown, whatever markup the file contains and whatever the bridge does or
  does not know how to render.
- **FR-000a**: The bridge's existing, separate ability to record a ticket
  identifier in a spec file (the marker lines it already owns) is unchanged and
  out of this feature's scope. After a reconcile, every byte of a spec file
  **other than those marker lines** MUST be identical to what it was before —
  in particular, not one character of author prose is ever rewritten.

**Inline formatting (US1)**

- **FR-001**: The bridge MUST convert Markdown inline markup found in synced spec
  text into native Jira rich-text formatting, covering at minimum: bold, italic,
  inline code, strikethrough, and links.
- **FR-002**: The bridge MUST NOT leave any Markdown delimiter of a converted
  construct visible in the text a Jira reader sees.
- **FR-003**: The bridge MUST honour Markdown backslash escapes, emitting the
  escaped character as literal text with no formatting applied and no backslash
  shown.
- **FR-004**: The bridge MUST apply formatting to nested spans, so that markup
  inside an already-formatted span renders with both effects.
- **FR-005**: The bridge MUST treat an unbalanced or malformed delimiter as
  literal text, never dropping the characters and never failing the reconcile.
- **FR-006**: The bridge MUST render a Markdown link as a live link only when its
  target is an absolute `http` or `https` address; any other target MUST be
  rendered as readable plain text carrying both the label and the target.
- **FR-007**: The bridge MUST NOT interpret Markdown inside inline code spans or
  code blocks; their content is reproduced verbatim.

**Block structure (US2)**

- **FR-008**: The bridge MUST preserve the block structure of synced prose,
  covering at minimum: paragraphs, headings, bulleted lists, numbered lists, and
  fenced code blocks — one rendered block per source block, in source order.
- **FR-009**: The bridge MUST NOT merge distinct source blocks into a single
  rendered paragraph.

**Graceful degradation**

- **FR-010**: For any Markdown construct the bridge does not render natively, it
  MUST emit the construct's human-meaningful text (label, alt text, or content)
  as plain text, and MUST NOT emit its syntax characters.

**Existing tickets and idempotency (US3)**

- **FR-011**: On the first reconcile after this change, the bridge MUST rewrite
  the descriptions of already-synced tickets so they carry the corrected
  formatting.
- **FR-012**: Every subsequent reconcile against an unchanged spec MUST issue no
  description write and report no change.
- **FR-013**: On a human-origin ticket, the bridge MUST preserve the human-authored
  content above the managed delimiter byte-for-byte while rewriting the managed
  region.
- **FR-014**: The rendered description MUST be visible in the dry-run preview
  before any write occurs.

**Equivalence and safety**

- **FR-015**: Both supported ports MUST produce byte-identical rendered
  descriptions for the same input spec, on macOS, Linux, and Windows, and
  regardless of whether the source file uses LF or CRLF line endings.
- **FR-016**: The privacy guard MUST evaluate the text of a rendered description
  as it does today; converting markup MUST NOT allow content to bypass a block or
  warn that the same text would have triggered before.

### Key Entities

- **Spec source text**: the Markdown prose the bridge reads from a Spec Kit
  feature file — the only input to rendering.
- **Rendered description**: what a Jira reader sees in the ticket body; the
  observable output every requirement above is measured against.
- **Formatted span**: a run of text carrying one or more formatting effects
  (bold, italic, code, strikethrough, link target) — the unit that inline
  conversion produces.
- **Managed region**: the part of a description the bridge owns and rewrites;
  on a human-origin ticket it sits below the delimiter, and everything above it
  belongs to the human.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | FR-000 states the direction explicitly: rendering reads spec files and never writes them, so the file stays the sole source and the ticket body stays a projection of it. SC-000 measures this as zero source files touched per run. |
| II | Zero-Churn Idempotency | FR-012 makes the no-change reconcile a functional requirement; FR-011 bounds the correction to a single one-off rewrite, so the migration is a finite event, not recurring churn. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-005 forbids failing on malformed markup, and rendering is a pure transformation before the write; a rendering that cannot be produced blocks its own write rather than sending degraded content, and hook behaviour is unchanged. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected: this feature reads spec prose and writes ticket bodies; it touches no credential, and adds no new stored value of any kind. |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected: no new configuration key is introduced. The supported construct set is fixed by FR-001/FR-008, not made configurable (Principle XV). |
| VI | macOS / Linux / Windows Portability | FR-015 makes byte-identical output across both ports and all three platforms a functional requirement, including the CRLF case, and the cross-port conformance corpus is the test that proves it. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected: rendering concerns the description body only. No status, transition, field id, or issue-type assumption is added or relied upon. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | The requirements are written entirely in reader-visible terms ("bold", "link", "code block") — no Jira or Atlassian identifier appears in this spec. The neutral/sink split of the formatting vocabulary is a design decision the plan must make and justify against this principle. |
| IX | Two-Tier Privacy Guard, With an Allowlist | FR-016 requires the guard to see the same text it sees today, so no BLOCK or WARN can be evaded by wrapping content in markup; FR-006 additionally prevents a non-http target from becoming a live link. |
| X | Self-Healing Automatic Mirror | FR-011 is exactly this principle applied to the defect: tickets written by the broken behaviour heal themselves on the next reconcile with no operator action. |
| XI | Universal Dry-Run and Auditability | FR-014 requires the rendered description to appear in the dry-run preview before any write, so the one-off corrective rewrite of FR-011 is fully previewable. |
| XII | Quality and Catalog Publication | Unaffected by the requirements themselves; the change ships through the existing release and catalog process with no new published surface. |
| XIII | TDD With a Minimum 80% Coverage | Every FR is stated as an observable property of the rendered description, so each has a failing test that can be written first; the acceptance scenarios and edge cases enumerate the fixture set. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | The supported construct set is deliberately closed (FR-001, FR-008) with a single degradation rule (FR-010) instead of open-ended Markdown coverage; anything richer must be justified in the plan's Complexity Tracking. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Tables, images, footnotes, raw HTML, and any configurability of the construct set are listed under Out of Scope and are covered only by the degradation rule; each supported construct traces to an acceptance scenario. |
| XVI | Human Readable — Readable by a Human Above All | This feature is that principle applied to the one surface where it was violated: the reader-facing ticket body. Every success criterion is measured on what a human sees. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-000**: Across the full conformance corpus, the only difference in any
  Spec Kit source file before and after a reconcile is the bridge's own
  ticket-identifier marker lines — zero prose bytes changed, in dry-run and in
  real runs alike.
- **SC-001**: Zero Markdown delimiter characters from a converted construct
  appear in the visible text of any synced ticket description, across the full
  conformance corpus.
- **SC-002**: 100% of the supported constructs (bold, italic, inline code,
  strikethrough, link, heading, bulleted list, numbered list, code block) render
  as their native equivalent in Jira, verified fixture by fixture.
- **SC-003**: A Jira reader who has never opened the repository can read a synced
  description end to end without encountering a character sequence that looks
  like source-file punctuation.
- **SC-004**: Running reconcile twice in a row against unchanged specs produces
  exactly one description write per already-synced ticket on the first run and
  zero on the second.
- **SC-005**: Both ports produce byte-identical descriptions for every corpus
  fixture on macOS, Linux, and Windows, with LF and CRLF sources alike.
- **SC-006**: No malformed, unbalanced, or unsupported markup in any fixture
  causes a reconcile to fail or to lose content.
- **SC-007**: Reconcile wall-clock time on the existing corpus does not regress
  measurably (within run-to-run noise) once rendering is in place.

## Out of Scope

- Tables, images, footnotes, definition lists, task-list checkboxes, and raw HTML
  as *natively rendered* constructs — they are covered only by the degradation
  rule (FR-010).
- Making the supported construct set configurable per team or per project.
- Rendering anything other than the description body (comments, summaries, custom
  fields).
- **Any modification of Spec Kit source files.** This feature is strictly
  one-directional, file to ticket. Specifically excluded: reading formatting back
  from Jira into the spec; rewriting an author's Markdown into a construct the
  bridge renders better; normalising, linting, or reformatting spec files;
  annotating them with rendering metadata; and any "fix the source so it renders"
  behaviour. Spec files are input only (FR-000).
- Changing which prose the bridge selects for the description; this feature
  changes only how the selected prose is rendered.

## Assumptions

- The complaint concerns the description body of bridge-written tickets; other
  ticket fields are not reported as affected and are excluded above.
- Spec files are authored in the CommonMark-ish Markdown that Spec Kit templates
  produce; exotic Markdown dialect extensions are not expected and fall under the
  degradation rule.
- Correcting already-synced tickets is desirable rather than intrusive: teams
  want the backlog fixed, and FR-014's dry-run preview lets an operator inspect
  the one-off rewrite before it happens.
- The existing managed-section delimiter behaviour on human-origin tickets is
  correct and is preserved as-is; this feature changes what is rendered inside
  the managed region, never where the region starts.
- The acceptance-criteria and design sections of a ticket are rendered from the
  same source prose and are therefore in scope for the same inline conversion.
