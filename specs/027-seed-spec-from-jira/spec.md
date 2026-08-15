# Feature Specification: Seed a Specification From Existing Jira Issues

**Feature Branch**: `feat/brownfield-support-2`

**Created**: 2026-08-15

**Status**: Draft

**Input**: User description: "Seed a new specification from existing, human-authored Jira issues, and bind them to the spec-kit workflow."

## Overview

The bridge is ticket-first but greenfield-only. The feature ceremony resolves a
ticket before naming anything, and it already accepts **one** issue key in its
leading positional — but that key only supplies a number for the branch and the
folder. Everything a human wrote in that ticket is discarded, the operator
retypes the intent as a feature description, and the reconcile that follows
opens a fresh ticket for every user story the drafted specification produces.

In an enterprise the work item exists before the specification. A Product Owner
writes a parent-level issue, or a handful of feature-level issues, by hand —
with the real business context in the description. Today that team ends up with
two parallel sets of issues for one piece of work, and the human's original
wording is stranded in the half nobody reconciles.

This feature closes that gap at the only moment it can be closed cleanly: at
feature creation, in one pass. The operator names the issues that already
exist; the ceremony reads them **once**, uses their content as the primary
source material for `spec.md`, binds each one to the specification it seeded,
resolves the parent, and creates issues only for the user stories that have no
human counterpart.

Constitution Principle I already reserves this as its **first** controlled
exception — "when the operator explicitly mentions an existing Jira issue key
in a command, the extension MAY read and edit THAT specific ticket — never any
other". This specification widens that exception from one issue to a
deliberately named set, and keeps every guard the exception was granted under.

### What this is not

It is not the second controlled exception. There is no label sweep, no JQL scan
over a project, no classification pass over candidates. Every issue this feature
ever touches was typed by the operator into the invocation that created the
specification folder. Label-based adoption remains a separate, unspecified
capability.

### Target users

- **Operator / tech lead** — installs the bridge on a repository whose Jira
  backlog is already populated, and needs the backlog and the specification
  bound without duplication.
- **Product Owner** — wrote the descriptions by hand and must be certain that
  the specification reflects *their* decomposition, not one the drafting agent
  preferred, and that not one character of their prose is rewritten.
- **Developer** — after seeding, works exactly as on a greenfield repository:
  the lifecycle hooks reconcile, nothing duplicates, nothing churns.

### Vocabulary

The two levels are **roles**, not type names. `config.yml`'s `hierarchy` block
already declares them per project — `specification` and `story` — and maps each
to whatever the project actually calls it (Epic/Story under Scrum,
Capability/Feature under SAFe, anything at all under a custom scheme). This
document says **the specification role** for what the user description calls
the parent level, and **the story role** for the feature level. No requirement
below may be satisfied by a literal type name, and every requirement holds for
team-managed and company-managed projects alike.

- **Designator** — one string the operator typed to name one issue.
- **Named issue** — an issue a designator resolved to.
- **Seeding** — deriving `spec.md` content from named issues.
- **Binding** — recording the correspondence between a named issue and the
  on-disk artifact it seeded, in both directions, so every later run recognises
  the issue instead of duplicating it.

## Clarifications

### Session 2026-08-15

- Q: How may a non-existent parent be named at all, given that a key resolving to nothing is a refusal and project-wide search is out of scope? (OD-7) → A: The specification-role designator accepts three forms — key, URL, or free text. Free text is never resolved against Jira; it is always the title of a parent to create. Only a key or URL can adopt an existing parent. `REF-PARENT-NAME` is therefore removed (14 refusal classes).
- Q: Is re-parenting an already-parented story-role issue refused, or allowed on explicit confirmation? (OD-1) → A: Allowed on explicit confirmation, as a line of the write plan. `REF-REPARENT` is therefore removed (13 refusal classes). This is **not** justified by `REF-CLAIMED`: that class only catches a story already marked by the bridge, whereas the risk case is an unmarked human story sitting under an active epic, which triggers no refusal at all. The safeguard is disclosure instead — every re-parenting line must name the current parent's key, summary, and status, state how many children that parent loses, and be visually distinct from adoption and creation lines, because re-parenting is the only write in this feature that modifies an artifact the operator did not name.
- Q: What are a newly created parent's summary and description derived from? (OD-3) → A: Summary from the operator's free text, body from the drafted overview. The free text is a **creation seed only**: it supplies the summary at create time, after which the mirror's own record of the title it last sent governs, so a human who renames the created parent afterwards keeps that rename across every later reconcile. FR-030 gains a named exception — "written once, at creation: a created parent's summary" — the "never written" line holding only for operator-named tickets. Free text that is empty or entirely whitespace refuses with `REF-DESIGNATOR`, never falling back to the `spec.md` title.
- Q: Are comments on the named issues read as source material, or ignored? (OD-6) → A: Ignored. The read never requests comment bodies at all, so the FR-043 cost ceiling holds unconditionally and no comment text ever passes through the privacy guard into a tracked file. The trade-off is documented for the operator: a decision that lives in the comment thread rather than the description will not reach `spec.md`, and the remediation is to carry it into the ticket's description before invoking the ceremony.
- Q: Does the operator confirm the drafted spec.md and the write plan before any mutation, and where does the gate sit? (OD-2) → A: Local artifacts are written freely; the gate stands before the first Jira mutation. A declined or interrupted run leaves an explicitly recorded **seeded, not bound** state — the folder and `spec.md` exist, the retained designator set is recorded, and no identity marker has been written on either side. That state is recorded, never inferred from the absence of markers. Re-invoking with the same designator set resumes at the confirmation gate without re-drafting `spec.md`, and `REF-EXISTS` does not apply to it; a different set still refuses with `REF-RESEED`. Constitution row I is restated as "confirmed before any Jira mutation", justified on the reversibility of a local write.

### Session 2026-08-15 (review pass)

A review of the clarified spec found gaps the first session left, or introduced. Applied directly, without a question:

- **FR-030** gains a field class "written once, at the first reconcile after binding — the managed boundary marker and the panel, appended below the human's existing description". A human-authored ticket carries no marker, so "above the managed boundary marker" (FR-030, US6 AC1) previously presumed something no requirement created.
- **FR-054** (new) fixes the order of story-role designators as the order typed, and requires it to survive URL reduction, normalisation, de-duplication, and the bulk read's arbitrary response order — FR-017 makes that order normative.
- **FR-055** (new) requires the input layer to distinguish an empty or blank specification-role designator from an omitted one: they yield `REF-DESIGNATOR` and the ordinary parent behaviour respectively, and nothing previously separated them.
- **SC-005** reworded to batch growth (`ceil(N / B)`, never `N`); "one hundred cost no more than one" contradicted FR-043.
- **SC-002** now states that a created parent is counted separately and never enters the created-issues arithmetic.
- **US7** acceptance scenarios renumbered — two were numbered 4.
- **US2 moved from P1 to P2**: it carries the only two irreversible writes in the feature (creating a parent, re-parenting a story off another team's epic). P1 is now US1, US3, US5, US6 — pure adoption under an operator-named existing parent, a shippable slice that validates pinning and content preservation before anything mutates an unnamed board.

Questions asked and answered in this pass:

- Q: Does the resume revalidate the decomposition against the current file, and what happens when the operator's edits broke it? (C5) → A: Yes — FR-063 re-runs the FR-058 validation against `spec.md` as it now stands on disk, and a break refuses with a **new class, `REF-DRAFT-EDIT`** (14 refusal classes), distinct from `REF-DECOMP` because the cause and the remediation differ: `REF-DECOMP` blames a drafting disagreement fixed by re-designating, `REF-DRAFT-EDIT` names the operator's own post-draft edit and is fixed by restoring the marker. FR-058 already draws the line the question asks for, since it reads pinning markers and nothing else: rewriting prose, adding scenarios, renaming a heading, or adding a new unpinned user story all pass; deleting, duplicating, or moving a pinned marker all fail. A file digest is deliberately rejected — it would refuse a typo fix and push the operator to work around the gate. FR-064 adds that a resume recomputes the write plan from the current file rather than replaying the first run's, and discloses the delta — lines added, lines gone — since a user story the operator added is legitimate under FR-018 but changes the number of creates, and confirming a stale prediction is what FR-034 and Principle XI forbid.
- Q: What is the documented exit from seeded-not-bound for an operator who will not confirm as-is? (C4) → A: Change the fact in Jira, then re-invoke — and the re-parenting disclosure carries that remediation line. For it to work, a resume **re-reads Jira** and recomputes the whole write plan rather than replaying the recorded one (FR-062). The re-read re-evaluates **every** refusal class, not only the re-parenting lines: a story closed, moved to another project, or claimed by another specification between the decline and the resume refuses normally. The resume never requests comment bodies (FR-020), and never re-drafts `spec.md` whatever the re-read returns — a refusal on resume leaves the seeded-not-bound state untouched. FR-043's ceiling is restated **per run**, with a resume explicitly counted as one, costing the same `ceil(N / B)` reads as a first run. This does not breach FR-009/FR-010: placement and status are re-read to compute a plan, never content to change a local artifact.
- Q: Does FR-025 apply to any resolved parent, or only to a parent the operator designated? (C3) → A: Only to an operator-designated parent, and FR-025 itself is reworded to say so rather than the edge case alone, so the contradiction cannot reform on a re-read. FR-026 is scoped the same way: re-parenting never fires in a run where the specification role was left undesignated. A run with no parent designator places nothing and re-parents nothing; instead FR-061 requires every named story still sitting under an existing parent to be disclosed — in the provenance report and the run summary, naming the story and its current parent, with the remediation "re-run designating a parent to group them". That disclosure is not a refusal: no write, no exit-code change, no blocking. Scattering is a legitimate state that the operator simply did not ask to change.
- Q: Which named issue supplies the slug, and what supplies it when the specification-role designator is free text and has no key? (C2) → A: The parent's key when the parent is designated by key or URL; otherwise the first story-role key, "first" fixed by FR-054; otherwise — free-text parent with no story designated — the ordinary description-derived naming, unchanged, which is not a refusal. Two further rules: the slug is computed **once** on the first run and recorded in the seeded-not-bound state beside the designator set, and a resume reads it rather than re-deriving it (FR-060) — otherwise an edit to the description between declining and resuming would point the run at a folder that does not exist. And the Assumptions record that the fifth shape is the only one whose folder carries no ticket key, deliberately.
- Q: Is `REF-DECOMP` raised by the drafting agent, or by a deterministic validation of the artifact after it is written to disk? (C1) → A: By a deterministic validation of the file. The agent drafts `spec.md` carrying explicit **pinning markers** (FR-056), and the script then validates the file (FR-058) on four mechanical properties — no key dropped, no orphan marker, no split or merge, no reorder — emitting `REF-DECOMP` from that validation alone. The validation reads the markers and nothing else: not headings, not prose, not section order except through marker positions. The pinning marker is written by the **agent** at drafting time and expresses an *intention*; the identity marker of FR-027 is written by the **script** after the confirmation gate and expresses a *binding*. A seeded-not-bound specification therefore carries pinning markers and no identity markers, which is what makes the two states mechanically distinguishable (FR-057). FR-015 is reclassified as a drafting instruction rather than a script-enforced requirement, since no deterministic check can judge prose quality; a testability table records which requirements the corpus can prove and where the rest live.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Story-role issues only, no parent named (Priority: P1)

The operator creates a feature and names three existing story-role issues —
some by key, some by pasted browser URL. The ceremony reads all three in a
single bulk read, uses their descriptions as the primary source material for
`spec.md`, produces exactly three pinned user stories in the order named, binds
each issue to the user story it seeded, and leaves parent resolution to the
ordinary behaviour.

**Why this priority**: This is the smallest complete slice of the feature. It
delivers seeding, pinning, and binding — the three mechanisms every other story
composes — and is on its own enough to stop a team's backlog from being
duplicated.

**Independent Test**: Can be fully tested against a mocked Jira double holding
three story-role issues with distinct human-written descriptions: invoke the
ceremony naming all three, assert `spec.md` contains exactly three user stories
whose narratives trace to those three issues in the order named, assert each
carries a durable binding to its issue key, and assert zero issues were created.

**Acceptance Scenarios**:

1. **Given** three existing story-role issues `PROJ-11`, `PROJ-12`, `PROJ-13`
   in the project the specification routes to, **When** the operator creates a
   feature naming `PROJ-11`, the browse URL of `PROJ-12`, and a board URL
   carrying `selectedIssue=PROJ-13`, **Then** the three designators reduce to
   the three keys, all three are read in one bulk read, and the ceremony
   proceeds with three named issues.
2. **Given** those three named issues, **When** the specification is drafted,
   **Then** `spec.md` contains exactly three user stories seeded from them, in
   the order the operator named them, each traceable to exactly one issue.
3. **Given** the drafted specification, **When** binding completes, **Then**
   each named issue carries the bridge identity marker recording origin
   `human` and this specification's slug, and the on-disk artifact records each
   issue's key against the user story it seeded.
4. **Given** the same three named issues, **When** the ceremony completes,
   **Then** zero issues have been created and the run summary lists three
   adoptions.
5. **Given** no parent-role designator was supplied, **When** the ceremony
   resolves the parent, **Then** the ordinary parent behaviour applies
   unchanged, and the ceremony neither invents a parent nor searches for one.

---

### User Story 2 - A parent that does not exist yet (Priority: P2)

The operator supplies a title for a parent that does not exist yet — free text
rather than a key or a URL — along with the story-role issues that belong under
it. Nothing is looked up: the ceremony creates the parent once,
places every named story-role issue under it, and places every freshly created
user-story issue under the same parent.

**Why this priority**: P2 rather than P1, deliberately. This story carries the
only two irreversible writes in the whole feature — creating a parent, and
re-parenting a story off an epic another team may be working. Everything that
makes the feature worth having is provable without either: pure adoption under
an operator-named existing parent (US1, US3, US5, US6) is a shippable slice on
its own, and it validates pinning, binding, and content preservation against a
real instance before anything mutates a board nobody named. Shipping US2 first
would put the riskiest writes in front of the evidence that the safe ones work.

**Independent Test**: Can be fully tested with a mocked double holding two
unparented story-role issues and no parent: invoke the ceremony naming a parent
and the two stories, assert exactly one parent-role issue is created, assert
both named issues are re-parented onto it, and assert a second identical
invocation creates nothing.

**Acceptance Scenarios**:

1. **Given** a specification-role designator supplied as free text — neither a
   key nor a URL — and two named story-role issues with no parent, **When** the
   ceremony runs, **Then** no lookup of any kind is issued to see whether such a
   parent already exists, and exactly one parent-role issue is created, in the
   project the specification routes to, with the type resolved from
   `hierarchy.specification`.
2. **Given** that created parent, **When** placement runs, **Then** both named
   story-role issues are placed under it, and no other field of either issue is
   written.
3. **Given** the drafted specification also contains two user stories with no
   named counterpart, **When** the following reconcile runs, **Then** exactly
   two issues are created, both under the same parent.
4. **Given** the created parent, **When** it is inspected, **Then** its summary
   is the operator's free text and its description body is the drafted
   overview.
5. **Given** a human renames that created parent in Jira after the ceremony,
   **When** the next reconcile runs, **Then** the rename survives — the free
   text is never re-applied — and the divergence from the mirror's title record
   is reported rather than reverted.
6. **Given** a specification-role designator that is empty or entirely
   whitespace, **When** the ceremony runs, **Then** it refuses with
   `REF-DESIGNATOR`, zero writes, and does not fall back to the `spec.md`
   title.
7. **Given** the parent creation succeeded but placement of the second story
   failed, **When** the run ends, **Then** the run reports precisely which
   issues were bound and which were not, and the recorded state is such that
   the documented resumption behaviour applies [NEEDS CLARIFICATION: OD-5].
8. **Given** the whole ceremony completed, **When** it is invoked a second time
   with the same designators, **Then** zero writes of every kind are issued.

---

### User Story 3 - A parent that already exists (Priority: P1)

The operator names an existing parent-role issue by key or URL. It is adopted
rather than created, the named story-role issues are bound under it, and the
specification's additional user stories become new issues under the same parent.

**Why this priority**: This is the commonest enterprise shape — the Product
Owner built the epic weeks ago. It shares every mechanism with US2 and differs
only in whether the parent is read or written.

**Independent Test**: Can be fully tested with a mocked double holding one
parent-role issue and two story-role issues: invoke naming all three, assert the
parent is read and never created, assert its identity marker records origin
`human`, and assert the created user-story issues land under it.

**Acceptance Scenarios**:

1. **Given** an existing parent-role issue `PROJ-1` whose type matches
   `hierarchy.specification`, **When** the operator names it as the parent,
   **Then** it is adopted, not created, and the run summary says so.
2. **Given** that adopted parent, **When** binding completes, **Then** it
   carries the identity marker with origin `human` and this specification's
   slug, and the specification records its key durably on disk.
3. **Given** the drafted specification contains four user stories of which two
   were seeded from named issues, **When** the following reconcile runs,
   **Then** exactly two issues are created, both under `PROJ-1`, and the two
   adopted issues are updated in place.
4. **Given** the named parent's type does not match `hierarchy.specification`,
   **When** the ceremony validates roles, **Then** it refuses with `REF-ROLE`,
   zero writes, naming the issue key, the type found, and the type the
   `hierarchy` block declares for that role.

---

### User Story 4 - A parent alone (Priority: P2)

The operator names only a parent-role issue. Its human-written content is the
sole source material for `spec.md`, and every user story the specification
produces is created beneath it.

**Why this priority**: It is the entry point for a team whose Product Owner
writes epics but not stories — common, and it exercises seeding with no pinning
constraint at all, which is a distinct code path from US1.

**Independent Test**: Can be fully tested with a mocked double holding one
parent-role issue carrying a substantial description: invoke naming only it,
assert `spec.md`'s overview and user stories are traceable to that description,
assert no user story is pinned, and assert the following reconcile creates one
issue per drafted user story, all under the named parent.

**Acceptance Scenarios**:

1. **Given** a single named parent-role issue with a non-empty description,
   **When** the specification is drafted, **Then** its content is the primary
   source material for `spec.md` and the provenance report attributes each
   drafted section to it.
2. **Given** no story-role designators were supplied, **When** the
   decomposition rule is evaluated, **Then** it imposes no constraint — the
   drafting agent chooses the number of user stories freely.
3. **Given** the drafted specification contains five user stories, **When** the
   following reconcile runs, **Then** five issues are created, all under the
   named parent, and the parent itself is not duplicated.

---

### User Story 5 - The ordinary run is untouched (Priority: P1)

The operator names nothing. Behaviour, output bytes, exit code, and the Jira
request sequence are identical to the current release.

**Why this priority**: Every existing consumer runs this path. A regression here
is a regression for everyone, and the guarantee must be asserted, not assumed.

**Independent Test**: Can be fully tested by running the existing feature-naming
conformance scenarios unchanged against the new implementation and asserting
byte-identical stdout, identical exit codes, and an identical recorded request
sequence.

**Acceptance Scenarios**:

1. **Given** an invocation with no designator of either role, **When** the
   ceremony runs, **Then** it issues zero Jira requests beyond those the current
   release issues, and its stdout is byte-identical to the current release's.
2. **Given** an invocation with no designator, **When** it completes, **Then**
   no provenance report, no write plan, and no confirmation prompt is emitted.
3. **Given** the existing leading-positional single-key form, **When** it is
   used exactly as documented today, **Then** its current behaviour is
   preserved — a key in that position continues to name a ticket for the naming
   engine, and this feature adds no new refusal to that path.

---

### User Story 6 - The human's content survives (Priority: P1)

The named issues carry descriptions, comments, attachments, assignees, sprints,
points, and hand-applied labels. After seeding, binding, and the next full
reconcile, exactly one class of content has changed and every other is
byte-preserved.

**Why this priority**: This is the promise the Product Owner is being asked to
trust. If it cannot be stated field by field and tested field by field, the
feature cannot be adopted by the team it exists for.

**Independent Test**: Can be fully tested by capturing every field of each named
issue before the ceremony, running the ceremony and a full reconcile, and
diffing: only the enumerated writable set may differ.

**Acceptance Scenarios**:

1. **Given** a named issue whose description is human prose, **When** the
   following reconcile writes to it, **Then** every byte above the managed
   boundary marker is preserved unchanged, and only the delimited managed panel
   below it is authored by the bridge — the origin `human` recorded at binding
   is what makes this so.
2. **Given** a named issue whose description a human edits *after* binding,
   **When** the next reconcile runs, **Then** the edited prose above the marker
   is still preserved byte-for-byte.
3. **Given** a named issue carrying comments, attachments, assignee, sprint,
   estimate, and hand-applied labels, **When** the ceremony and the following
   reconcile complete, **Then** none of them is removed, and the only label
   change permitted is the additive one the mirror already applies.
4. **Given** a named issue's summary, **When** the ceremony runs, **Then** the
   summary is not rewritten by the ceremony; the mirror's own record of the
   title it last sent governs every later run, exactly as it does for any
   adopted ticket.
5. **Given** the full field inventory, **When** this specification is reviewed,
   **Then** it names explicitly, field class by field class, what is preserved,
   what is overwritten, and what is appended — see FR-030.

---

### User Story 7 - Provenance before anything is written (Priority: P2)

Before any byte reaches disk or Jira, the operator can see which part of the
drafted `spec.md` came from which named issue, and what the ceremony intends to
write where.

**Why this priority**: The whole exception rests on the operator having declared
and confirmed the targets. A confirmation the operator cannot evaluate is not a
confirmation. It is P2 only because US1 through US4 can be demonstrated without
it; it is mandatory before release.

**Independent Test**: Can be fully tested by invoking the ceremony against a
mocked double and asserting that the provenance report and the write plan are
emitted before the first write of any kind, and that they list every named
issue, every drafted user story, and every intended write.

**Acceptance Scenarios**:

1. **Given** three named story-role issues and a drafted specification with five
   user stories, **When** the provenance report is emitted, **Then** it lists
   each drafted user story with its source — a named issue key, or `new` — and
   each named issue with the drafted section it seeded.
2. **Given** the same state, **When** the write plan is emitted, **Then** it
   lists every intended Jira mutation — issues to be created, issues to be
   adopted, issues to be re-parented — with zero Jira mutations performed at the
   moment it is emitted.
3. **Given** the report and the plan, **When** the operator declines, **Then**
   zero Jira mutations occur, the folder and `spec.md` remain on disk, no
   identity marker exists on either side, and the seeded-not-bound state is
   recorded explicitly with the retained designator set.
4. **Given** that recorded seeded-not-bound state, **When** the ceremony is
   re-invoked with the same designator set, **Then** it resumes at the
   confirmation gate, `spec.md` is not re-drafted and not one byte of it
   changes, and `REF-EXISTS` does not fire.
5. **Given** that same state, **When** the ceremony is re-invoked with a
   different designator set, **Then** it refuses with `REF-RESEED` and zero
   writes.
6. **Given** two named story-role issues currently parented under `PROJ-99`,
   **When** the write plan is emitted, **Then** it carries a re-parenting line,
   visually distinct from every adoption and creation line, naming `PROJ-99` by
   key, summary, and status, and stating that it loses two children.
7. **Given** a `--dry-run` invocation, **When** the ceremony runs, **Then** the
   predicted action set is identical to the action set a following real run
   performs, and zero writes occur.

---

### Edge Cases

- **A key whose issue moved projects.** Jira answers a read by an old key with
  the issue under its *new* key. The bound key MUST be the key the read
  returned, and the run MUST report the substitution rather than binding the
  key the operator typed.
- **The same issue named twice in different forms** — once as a bare key, once
  as a browse URL. Duplication is detected *after* reduction to keys, not on the
  raw designator strings.
- **A designator whose key is lower-case** (`proj-123`). Normalised to upper
  case before the grammar check, then treated as any other key.
- **A `selectedIssue` value that is percent-encoded.** Decoded before the
  grammar check.
- **A site base URL carrying a path prefix** (a Jira Data Center at
  `https://jira.example.com/jira/`). Host comparison MUST NOT be defeated by
  the prefix, and the browse-path reduction MUST tolerate it.
- **A named issue that already carries a story-role marker from a prior spec
  folder.** This is `REF-CLAIMED`, not an overwrite.
- **A named story-role issue that already has a parent, and the operator named
  no parent.** Nothing is re-parented; the existing parent is left alone and
  disclosed under FR-061 — in the provenance report and the run summary, with a
  remediation, at no cost to the exit code. FR-025 and FR-026 are both scoped to
  an operator-designated parent precisely so this case has one answer rather
  than three.
- **A named parent-role issue in a terminal status, with the named stories
  open.** The parent's terminal status refuses the whole run (`REF-TERMINAL`);
  a partially usable subset is never silently proceeded with.
- **More named issues than one bulk read holds.** The read count grows by whole
  batches, never by item.
- **The specification folder already exists for the resolved slug.**
  Retro-seeding is out of scope: `REF-EXISTS`, zero writes — unless the folder
  is in the recorded seeded-not-bound state with an unchanged designator set, in
  which case the run resumes at the confirmation gate.
- **A run crashed mid-draft, before the seeded-not-bound state was recorded.**
  It is *not* seeded-not-bound — that state is recorded, never inferred from the
  absence of markers — so `REF-EXISTS` fires, which is the correct fail-closed
  answer for a folder nobody can vouch for.
- **The drafting agent proposes merging two named issues into one user story.**
  `REF-DECOMP`, zero writes, with the proposed decomposition named in the
  message so the operator can act on it.
- **Jira unreachable while designators were supplied.** Unlike the current
  ceremony — where an unreachable Jira degrades to `active: false` plus one
  warning — a run that named issues MUST NOT degrade: it refuses, because
  proceeding would create the duplicates the feature exists to prevent.

## Requirements *(mandatory)*

### Functional Requirements

#### Input and designators

- **FR-001**: The ceremony MUST accept, in one invocation, an optional
  designator for the specification role and zero or more designators for the
  story role, with each designator's intended role declared by the operator —
  never inferred from the issue's type. A story-role designator MUST be either
  an issue key or an issue URL. A specification-role designator MUST accept a
  third form in addition to those two — free text — which is never resolved
  against Jira and is always the title of a parent to create (FR-023). Only a
  key or a URL can adopt an existing parent.
- **FR-054**: The **order** of the story-role designators is normative — FR-017
  pins the drafted user stories to it — so it MUST be established and preserved
  explicitly, never left to chance:
  - The order is the order in which the operator supplied the designators in the
    invocation, left to right, as typed.
  - That order MUST survive every transformation the ceremony applies: URL
    reduction (FR-004), upper-case normalisation (FR-002), and de-duplication
    (FR-008), which removes the later occurrence and keeps the position of the
    first.
  - The bulk read MUST NOT reorder them. Whatever order the response arrives in
    — and a bulk read makes no ordering promise — the designator order is what
    the ceremony carries forward.
  - The order MUST be recorded alongside the retained designator set in the
    seeded-not-bound record (FR-049), so a resume pins identically.
- **FR-055**: An **empty or whitespace-only** specification-role designator and
  **no specification-role designator at all** are different inputs with
  different outcomes — `REF-DESIGNATOR` (FR-053) versus the ordinary parent
  behaviour (FR-024) — and the input layer MUST distinguish them. Supplying the
  designator with an empty or blank value is *supplying* it: the operator
  reached for the parent and typed nothing, which is an error worth naming.
  Omitting it entirely is not an error. No normalisation step may collapse the
  first case into the second — in particular, a blank value MUST NOT be dropped
  as though it had never been supplied.

- **FR-059**: The **resolved slug** — which `REF-EXISTS`, `REF-RESEED`, FR-041,
  FR-049, and FR-050 all reason about — MUST be derived by this rule, which
  preserves the ticket-first naming the current release already delivers:
  - When the specification role is designated **by key or URL**, the slug
    derives from that parent's key. The parent is the artifact that outlives the
    specification and under which everything else is filed, so it is the right
    carrier whenever it exists.
  - Otherwise, when at least one story-role designator was supplied, the slug
    derives from the **first** story-role key, "first" being fixed
    deterministically by FR-054.
  - Otherwise — the specification role designated as **free text** with no
    story-role designator at all — no key exists in the invocation, and the
    **ordinary naming behaviour applies unchanged**: the slug derives from the
    description exactly as it does in a run that names nothing. This is not a
    refusal; nothing is ambiguous, and the operator has supplied both a feature
    description and a parent title.

  The rule therefore answers all five shapes: parent by key plus stories → the
  parent's key; parent as free text plus stories → the first story-role key;
  stories only → the first story-role key; parent only by key or URL → the
  parent's key; parent only as free text → the ordinary behaviour.
- **FR-060**: The slug MUST be computed **once**, on the first run, and recorded
  in the seeded-not-bound state alongside the retained designator set and its
  order (FR-049). A resume MUST read the recorded slug and MUST NEVER re-derive
  it. Without this, an operator who edits the feature description between
  declining and resuming would have the slug recomputed from the new text, and
  the resume would address a folder that does not exist.

  *(FR-054, FR-055, FR-059, and FR-060 were added by the second 2026-08-15
  clarification session; see the note under FR-050 on numbering.)*
- **FR-002**: A designator MUST be accepted as a bare issue key matching the
  grammar *one upper-case letter, followed by upper-case letters, digits, or
  underscores, followed by a hyphen and one or more digits*, compared after
  normalising the designator to upper case.
- **FR-003**: A designator MUST be accepted as an issue URL, interchangeably
  with the key form, in any mix, in one invocation.
- **FR-004**: A URL MUST be reduced to a key by this order, applied after
  discarding any fragment: (a) if a `selectedIssue` query parameter is present,
  its percent-decoded value is the candidate; (b) otherwise, if the path
  contains a `/browse/` segment, the segment immediately following it is the
  candidate; (c) otherwise, if the final path segment matches the key grammar,
  it is the candidate. The candidate MUST then satisfy FR-002 or the designator
  is refused.
- **FR-005**: The three recognised URL shapes — the browse path, a
  board-context URL carrying `selectedIssue`, and either form bearing a
  trailing query string or anchor — MUST each be covered by a conformance
  scenario in both ports.
- **FR-006**: A URL designator MUST be refused unless its scheme, host, and
  port equal those of the configured site base URL, compared case-insensitively
  on the host and after discarding one trailing dot. No request may be issued to
  a host the configuration does not name.
- **FR-007**: Pasted ticket text MUST NOT be an input. An issue that cannot be
  fetched MUST be a refusal, never a fallback to the literal text of the
  designator.
- **FR-008**: Designators MUST be de-duplicated after reduction to keys; naming
  one issue twice, or naming one issue as both the specification role and the
  story role, is a refusal.

#### The one-way read

- **FR-009**: Jira issue content MUST be read exactly once — during this
  ceremony — for the purpose of producing `spec.md`. From the moment the
  specification folder exists, the filesystem is the source of truth again.
- **FR-010**: No later command MUST re-read issue content to change a local
  artifact. This is testable as follows: given a seeded specification, when a
  human edits every named issue's description and summary in Jira, then a
  subsequent `plan`, `tasks`, and full `reconcile` MUST each leave `spec.md`
  byte-identical.
- **FR-011**: The reads a reconcile legitimately performs — recognition reading
  a recorded key to decide bound/blocked/gone, and drift detection reporting a
  divergence — are unaffected by FR-010 and MUST continue to work exactly as
  today. FR-010 forbids using what is read to rewrite a local artifact, not
  reading itself.

#### Roles and hierarchy

- **FR-012**: The specification role and the story role MUST be resolved from
  the effective `hierarchy` configuration for the project the specification
  routes to. No requirement may be satisfied by a hard-coded type name.
- **FR-013**: Every named issue's type MUST be validated against the role it was
  named as, using the type the read returned and the type the `hierarchy` block
  declares for that role. A mismatch is a refusal.
- **FR-014**: The behaviour MUST be identical for team-managed and
  company-managed projects; at least one conformance fixture MUST exercise a
  non-default hierarchy (renamed types, SAFe-shaped roles).

#### Seeding and decomposition

- **FR-015**: *(Drafting instruction, not a script-enforced requirement — see
  the testability table below.)* The human-authored content of the named issues
  is the primary source material for `spec.md` — its overview, its user-story
  narratives, and its stated intent — not decoration appended to a
  separately-invented draft.
- **FR-056**: The **pinning marker** is a first-class artifact of this feature,
  and is specified here rather than left to the drafting:
  - **Form** — one HTML comment line, `<!-- speckit-jira pin=KEY -->`, where
    `KEY` is the designated issue key exactly as resolved by FR-002 and FR-004.
  - **What it does not carry** — no durable identifier. It is deliberately *not*
    of the `story=<id>` or `spec=<id>` shape, and a parser for either of those
    MUST treat a `pin=` body as a different marker entirely, exactly as the
    existing `spec=` and `story=` grammars already treat each other.
  - **Position** — immediately adjacent to the heading of the user story it
    pins, in the same position the existing story marker occupies. One user
    story carries at most one pinning marker; a user story with no named
    counterpart (FR-018) carries none.
  - **Who writes it, and what it means** — the **agent** writes it while
    drafting, and it expresses an *intention*: "this user story was seeded from
    this issue". It is not a binding and confers no authority over Jira.
- **FR-057**: The pinning marker MUST be distinguishable from the identity
  marker of FR-027 at every point, because they mean different things and are
  written by different actors at different times:
  - **Pinning** — written by the agent, at drafting time, before the
    confirmation gate. Expresses intention.
  - **Identity** — written by the script, after the confirmation gate. Expresses
    a binding.
  - It follows that a seeded-not-bound specification (FR-049) carries pinning
    markers and **no** identity markers, on either side. That asymmetry is what
    makes the two states mechanically distinguishable, and it is the on-disk
    counterpart of FR-049's requirement that the state be recorded rather than
    inferred.
  - At binding, the script consumes each pinning marker: it is replaced in place
    by the story marker (`story=<id> ticket=KEY`) that FR-027 requires. A fully
    bound specification therefore carries story markers and no pinning markers,
    and the two states never overlap on disk.
- **FR-016**: Each named story-role issue MUST be pinned to exactly one user
  story in `spec.md`. The pinning MUST be a bijection between the named
  story-role issues and a subset of `spec.md`'s user stories, and it is
  established by the pinning markers of FR-056 — not by titles, not by prose,
  not by inference.
- **FR-017**: The specification MAY enrich a pinned user story — adding Gherkin
  acceptance scenarios, acceptance criteria, edge cases, priority, and an
  independent-test statement — and MUST NOT merge two named issues into one
  user story, split one named issue across several, drop one, or place the
  pinned user stories in an order other than the order the operator named them
  (FR-054).
- **FR-018**: New user stories with no named counterpart MAY be added alongside
  the pinned ones. They are exactly the set for which issues are created, and
  they are identified by the absence of a pinning marker.
- **FR-058**: After the agent has written `spec.md` and before any Jira
  mutation, the script MUST validate the file deterministically. The validation
  reads **the pinning markers and nothing else** — not headings, not titles, not
  prose, and not section order except as given by the markers' relative
  positions in the file. It asserts exactly four properties:
  1. Every designated story-role key carries exactly one pinning marker
     (no key dropped).
  2. Every pinning marker names a designated story-role key (no orphan marker).
  3. No key appears in two pinning markers (no split), and no user story carries
     two pinning markers (no merge).
  4. The pinning markers appear in the file in the same relative order as the
     designator order fixed by FR-054 (no reorder).
- **FR-019**: When the validation of FR-058 fails any of its four properties,
  the ceremony MUST refuse with `REF-DECOMP` and zero Jira mutations. The
  refusal MUST name each designated key with no marker, each marker naming no
  designated key, each duplicate, and each out-of-order pair, so the operator
  can either accept the human's decomposition or re-invoke with a different set
  of designators. Because `REF-DECOMP` is emitted by a file-reading validation
  rather than by a drafting judgement, it is computed identically by both ports
  and is exercisable by the conformance corpus (FR-039, FR-046).

**Which of these the conformance corpus can prove, and where the rest lives:**

| Requirement | Provable by the corpus? | If not, where it lives instead |
| --- | --- | --- |
| FR-015 — the human content is the *primary* source material | **No.** It is a judgement about prose quality, and no deterministic check distinguishes a well-seeded narrative from a plausible invention. | A drafting instruction in the command definition. It is made *inspectable* by the provenance report (FR-032), which lets a human see the attribution before confirming, and it is verified at dogfood against a real instance (Principle XII). |
| FR-016 — the bijection | **Yes**, over the pinning markers of the written file (FR-058 properties 1–3). | — |
| FR-017 — no merge, no split, no drop, no reorder | **Yes** for all four prohibitions (FR-058 properties 1–4). **No** for the permission to enrich, which is not an obligation and therefore has nothing to fail. | The permission stays descriptive. |
| FR-019 — `REF-DECOMP` | **Yes.** It is a script output computed from the file. | — |
| FR-056, FR-057, FR-058 | **Yes.** Marker grammar, marker/identity disjointness, and the validation itself are all mechanically checkable. | — |

  *(FR-056, FR-057, and FR-058 were added by the second 2026-08-15 clarification
  session; see the note under FR-050 on numbering.)*
- **FR-020**: Comments on named issues are NOT source material. The read MUST
  NEVER request comment bodies, so the cost ceiling of FR-043 holds
  unconditionally and no comment text can reach `spec.md`. The consequence MUST
  be documented where an operator will meet it: a decision recorded in the
  comment thread rather than in the description does not reach the
  specification, and the remediation is to carry that decision into the ticket's
  description before invoking the ceremony.
- **FR-021**: A named issue whose description contains no non-whitespace
  character MUST be refused as unseedable. Refusing is preferred to seeding from
  a summary alone, because a user story invented from a title is exactly the
  duplication of intent this feature exists to prevent.
- **FR-065**: Every byte seeded from a named issue MUST pass the existing
  two-tier pre-write privacy guard, at both tiers, with the committable
  allowlist honoured. This is **new scanned surface**: until this feature no
  content originating in the tracker was ever written into a tracked file, and a
  Product Owner's description is exactly where a site URL, an account
  identifier, or a token-shaped string gets pasted.
  - The scan runs during the ceremony, over the seed material, **before it is
    handed to the drafting agent** — poisoned content must never reach the
    draft, because once it is in `spec.md` the operator has already been shown
    it.
  - It runs again over `spec.md` before the first Jira mutation, exactly as the
    guard already runs before any other write.
  - A BLOCK-tier match refuses with the existing dedicated block exit code and
    zero writes of any kind, local or Jira. A WARN-tier match is reported and
    never blocks.
  - An allowlisted Confluence link or corporate domain MUST produce neither a
    block nor a warn — a blocking control with false positives ends up disabled,
    and precision wins over recall at the BLOCK tier.

  *(FR-065 was added by the 2026-08-15 cross-artifact analysis, which found the
  obligation asserted in the plan's Constitution Check but demanded by no
  requirement and covered by no task; it carries the next free number, per the
  note under FR-050.)*

#### Parent resolution and placement

- **FR-022**: When the operator names an existing specification-role issue, it
  MUST be adopted and MUST NOT be created.
- **FR-023**: A specification-role designator supplied as free text — neither a
  key nor a URL — MUST NOT be resolved against Jira by any means. It is always
  the title of a parent to create: exactly one specification-role issue is
  created, in the project the specification routes to, with the type resolved
  from `hierarchy.specification`. No lookup, no exact-summary match, and no
  search of any kind may be issued to decide whether such a parent already
  exists — an operator who wants an existing parent adopted names it by key or
  URL (FR-022). The created parent's **summary** is derived from that free text
  and its **description body** from the drafted overview — each source feeding
  what it is actually for.
- **FR-052**: The free text is a **creation seed only**. It supplies the summary
  at the moment of the create and has no authority afterwards: from then on the
  mirror's own record of the title it last sent governs, exactly as for any
  bridge-created ticket. A human who renames the created parent in Jira keeps
  that rename across every subsequent reconcile — the free text is never
  re-applied, and a summary that no longer matches the record is reported, never
  reverted.
- **FR-053**: A specification-role free-text designator that is empty or
  entirely whitespace MUST refuse with `REF-DESIGNATOR`. It MUST NOT fall back
  to the drafted `spec.md` title: an operator who typed nothing has not named a
  parent, and silently inventing one is precisely the guessing this feature
  forbids everywhere else.

  *(FR-052 and FR-053 were added by the 2026-08-15 clarification session; see
  the note under FR-050 on numbering.)*
- **FR-024**: When the operator names no specification-role designator, the
  ordinary parent behaviour MUST apply unchanged. The ceremony MUST NOT invent a
  parent and MUST NOT search for one.
- **FR-025**: Every named story-role issue MUST be placed under the parent the
  **operator designated**, and every issue created for a user story with no
  named counterpart MUST be created under that same designated parent. The
  wording is deliberate and load-bearing: placement is never driven by a parent
  the operator did not designate. A run in which the specification role was left
  undesignated places nothing and re-parents nothing, whatever the ordinary
  parent behaviour of FR-024 resolves or creates for its own purposes.
- **FR-061**: In a run with **no** specification-role designator, every named
  story-role issue that already sits under an existing parent MUST be reported —
  in the provenance report (FR-032) and again in the run summary — naming that
  story, naming its current parent by key, and carrying the remediation: re-run
  the ceremony designating a parent if the stories are to be grouped. This
  reporting is a **disclosure, not a refusal**: it performs no write, it does
  not change the exit code, and it never blocks the run. Scattering named
  stories across several parents is a legitimate state — the operator simply did
  not ask for them to be gathered — and the report exists so that state is
  visible rather than silent.
- **FR-026**: A named story-role issue already parented under a *different*
  specification-role issue MUST be re-parented onto the **operator-designated**
  parent, and only on the operator's explicit confirmation of the write plan
  line that discloses it (FR-051). Re-parenting MUST NEVER be silent, and it
  MUST NEVER fire in a run where the specification role was left undesignated —
  in that run the story stays where it is and is disclosed under FR-061.
- **FR-051**: Re-parenting is the only write in this feature that modifies an
  artifact the operator did not name — the story's *current* parent loses a
  child. Its write-plan line MUST therefore disclose, for each re-parented
  story: the current parent's key, its summary, and its status; and the number
  of children that parent will lose in this run, counting every named story
  being moved off it. That line MUST be visually distinct from the adoption and
  creation lines, so an operator scanning the plan cannot mistake the one write
  with off-target blast radius for the ones confined to what they named. The
  count MUST be stated even when it is one, and the disclosure MUST NOT be
  suppressed when the current parent is itself bridge-bound. "Visually distinct"
  MUST be a literal rendering, not a judgement: FR-046 requires the two ports to
  emit byte-identical output, which is unachievable if each port may satisfy the
  distinction its own way. The rendering MUST be capability-independent — no
  colour, no bold, no terminal-width detection — so that it is identical on every
  host.

  *(FR-051 was added by the 2026-08-15 clarification session; see the note under
  FR-050 on numbering.)*

#### Binding, and what later runs see

- **FR-027**: Binding MUST be recorded on both sides: the identity marker on the
  issue, recording origin `human` and this specification's slug; and the durable
  identifier on disk, recording the issue's key against the artifact it seeded —
  the specification's own marker for the parent, each user story's marker for
  its pinned issue.
- **FR-028**: The on-disk identifier MUST be written before the corresponding
  Jira write, and each key MUST be stamped and recorded immediately, per issue,
  never batched — the existing fail-closed ordering. A run interrupted after
  three bindings has three recorded keys.
- **FR-029**: After binding, every later reconcile MUST recognise each named
  issue by its recorded key and MUST NOT create a duplicate for the artifact it
  is bound to.
- **FR-030**: The specification MUST state, and the tests MUST assert, field
  class by field class, what a bound issue undergoes:
  - **Preserved forever** — every byte of the description above the managed
    boundary marker, including edits a human makes after binding; comments;
    attachments; assignee; reporter; sprint; estimate; priority; issue links;
    and every label the bridge did not itself add.
  - **Overwritten on every reconcile** — the delimited managed panel below the
    boundary marker, which is the bridge's own region and is rewritten in full.
  - **Written once, at binding** — the identity marker (origin `human`, this
    specification's slug) and the parent link when FR-025 or FR-026 applies.
  - **Appended, never removed** — the mirror's own additive label.
  - **Written once, at the first reconcile after binding** — the managed
    boundary marker and the panel beneath it, appended **below** the human's
    existing description. An issue a human authored carries no such marker: the
    ceremony binds it, and the first reconcile that follows is what introduces
    the boundary, placing every pre-existing byte above it. Without this class,
    "above the managed boundary marker" in the line above and in US6 AC1 would
    presume a marker that no requirement creates. That first append is the only
    time the marker is written; every later reconcile rewrites only the panel
    below it.
  - **Written once, at creation** — the summary of a parent the ceremony itself
    creates from a free-text designator (FR-023, FR-052). This is the one named
    exception to the line below, and it applies only to an issue the ceremony
    created; after that create, the mirror's title record governs and a human
    rename survives.
  - **Never written by this ceremony** — on every issue the operator **named**:
    the summary, the status, and every field not enumerated above.
- **FR-031**: Whether an adopted issue and a created issue are distinguishable
  after the fact is [NEEDS CLARIFICATION: OD-4]. The identity marker already
  records origin `human` versus `bridge_created`; the open question is whether
  that distinction must also be visible to a human reading Jira.

#### Provenance and confirmation

- **FR-032**: Before the first **Jira mutation**, the ceremony MUST emit a
  provenance report mapping each drafted user story to its source — a named
  issue key or `new` — and each named issue to the drafted section it seeded.
- **FR-033**: Before the first **Jira mutation**, the ceremony MUST emit a write
  plan enumerating every intended write — issues to create, issues to adopt,
  issues to re-parent — and MUST obtain the operator's confirmation. Local
  artifacts are not gated: the specification folder and `spec.md` are written
  freely, so the operator reads the draft in their editor rather than in a
  terminal, and a local write is reversible in a way a Jira mutation is not.
- **FR-049**: A run that reaches the confirmation gate and does not pass it —
  declined, interrupted, or aborted — MUST leave a state this specification
  calls **seeded, not bound**, with all three of these properties:
  - The specification folder and `spec.md` exist and are complete.
  - **No identity marker has been written on either side** — not on any Jira
    issue, and not on disk. No `spec=` or `story=` marker carries a key.
  - The state is **recorded explicitly**, naming the retained designator set,
    its order (FR-054), and the slug computed on the first run (FR-060), and
    stating that zero bindings were performed. It MUST NOT be inferred from the
    absence of markers: absence of markers is also what a crashed run looks like
    mid-draft, and the two must be distinguishable.
- **FR-050**: Re-invoking with the **same** designator set against a
  seeded-not-bound state MUST resume at the confirmation gate without
  re-drafting `spec.md`, and `REF-EXISTS` MUST NOT fire. Re-invoking with a
  **different** designator set against that state MUST refuse with
  `REF-RESEED`, exactly as against a fully bound specification. A resume
  **re-reads Jira** to recompute the write plan — see FR-062.
- **FR-062**: An operator who declines the plan because one line troubles them —
  characteristically a re-parenting line — has a documented way out, and it is
  the only one this feature provides: change the fact in Jira, then re-invoke.
  The remediation line accompanying a re-parenting disclosure (FR-051) MUST say
  so. For that to work, a resume MUST re-read Jira rather than replay the
  recorded plan:
  - **It recomputes the whole plan** from Jira as it now stands. A story the
    operator detached in the meantime no longer produces a re-parenting line.
  - **It re-evaluates every refusal class**, not merely the re-parenting lines.
    A named issue that has since been closed, moved to another project, or
    stamped with another specification's identity MUST refuse exactly as it
    would on a first run — `REF-TERMINAL`, `REF-ROUTING`, `REF-CLAIMED`, and the
    rest are all live on a resume.
  - **It never requests comment bodies** (FR-020), so the FR-043 ceiling holds
    for a resume exactly as for a first run.
  - **It never re-drafts `spec.md`**, whatever the re-read returns. A refusal on
    resume leaves the seeded-not-bound state exactly as it was — same folder,
    same `spec.md`, same recorded designator set, order, and slug — so the
    operator can fix the Jira-side cause and re-invoke again.
  - This does not violate FR-009 or FR-010. What a resume re-reads is *placement
    and status* in order to compute a plan, never *content* in order to change a
    local artifact — and FR-011 already draws that line.

- **FR-063**: A resume MUST re-run the FR-058 validation against `spec.md` **as
  it now stands on disk**, not against the file as first drafted. The whole case
  for gating only Jira mutations is that the operator reads the draft in their
  editor, and their next move is to edit it — so the file at the gate is not
  necessarily the file that left the drafting step.
  - An edit that leaves the four FR-058 properties intact is legitimate and
    passes silently. Rewriting prose, adding acceptance scenarios, renaming a
    heading, and adding a whole new unpinned user story (FR-018) all change no
    property, because FR-058 reads the pinning markers and nothing else.
  - An edit that breaks a property — a pinned user story deleted, a marker
    duplicated, a marker moved out of designator order — MUST refuse with
    `REF-DRAFT-EDIT`, a class distinct from `REF-DECOMP`. The two have different
    causes and therefore different remediations: `REF-DECOMP` says the drafted
    decomposition disagreed with the human's, and is fixed by re-invoking with a
    different designator set; `REF-DRAFT-EDIT` says the operator's own edit
    broke the pinning, and is fixed by restoring the marker or starting over.
    Reusing `REF-DECOMP` here would blame the agent for what the operator just
    did, which FR-035's copy-pasteable-remediation obligation forbids.
  - The refusal MUST name precisely which marker vanished, which is duplicated,
    and which moved, and MUST state how to restore it. A refusal on resume
    leaves the seeded-not-bound state untouched (FR-062).
- **FR-064**: A resume MUST recompute the write plan from the **current**
  `spec.md`, never replay the plan the first run displayed. A user story the
  operator added during their review is legitimate under FR-018 and passes
  FR-058, but it changes the number of issues to create — so the plan
  re-presented at the gate MUST reflect the file as it now is. The resume MUST
  additionally disclose the **delta** against the previously displayed plan:
  which lines were added, and which have disappeared. Without that, the operator
  would be confirming a stale prediction, which FR-034 and Principle XI both
  forbid — a plan that does not predict the run is not a plan.

  *(FR-061 through FR-064 were added by the second 2026-08-15 clarification
  session; see the note under FR-050 on numbering.)*

  *(FR-049 and FR-050 were added by the 2026-08-15 clarification session and
  carry the next free numbers rather than renumbering FR-034 onward, so every
  existing cross-reference stays valid.)*
- **FR-034**: `--dry-run` MUST predict exactly the action set of a following
  real run, including the identifiers that run would assign, with zero writes.

#### Refusals

- **FR-035**: Every refusal MUST perform zero writes of every kind, name the
  offending designator or issue key, and carry a copy-pasteable remediation
  line. The run MUST exit non-zero with a documented code, escalating
  monotonically.
- **FR-036**: The refusal classes are exactly these, each with its remediation:

  | Code | Condition | Remediation |
  | --- | --- | --- |
  | `REF-DESIGNATOR` | A **story-role** designator is neither a valid issue key nor a recognisable issue URL; or a **specification-role** designator is free text that is empty or entirely whitespace (FR-053). Non-blank free text in the specification role is a title, not a refusal (FR-023) | Paste the issue key or the browser URL of the issue; or, for a parent to create, type its title |
  | `REF-HOST` | A URL's scheme, host, or port is not the configured site base URL | Paste a URL from the configured site, or correct the site base URL in the configuration |
  | `REF-UNRESOLVED` | A named key is absent from the read — it does not exist, or the credentials cannot see it | Check the key, then check that the credentials can open it in a browser |
  | `REF-ROUTING` | A named issue's project is not the project this specification routes to | Route the specification to that project, or name issues from the routed project |
  | `REF-ROLE` | A named issue's type does not match the role it was named as | Name it as the other role, or correct the `hierarchy` block for this project |
  | `REF-CLAIMED` | A named issue carries an identity marker for another specification slug | Reopen that specification, or name a different issue |
  | `REF-TERMINAL` | A named issue is in a status the configuration declares terminal or halted | Reopen the issue, or name a different one |
  | `REF-MULTIPROJECT` | The named story-role issues span more than one project | Name issues from one project per specification |
  | `REF-DUPLICATE` | The same issue is named twice, or as both roles | Remove the duplicate designator |
  | `REF-THIN` | A named issue's description contains no non-whitespace character | Write the issue's description in Jira, or do not name it |
  | `REF-DECOMP` | The FR-058 validation fails on the file as first drafted — the drafted decomposition violates FR-016 or FR-017 | Accept the human decomposition, or re-invoke with a different set of designators |
  | `REF-DRAFT-EDIT` | The FR-058 validation fails **on resume**, because the operator's own edits to `spec.md` broke the pinning (FR-063) | Restore the named pinning marker to its position, or start over with a new specification |
  | `REF-RESEED` | The ceremony is re-invoked for the same slug with a different set of designators | Re-invoke with the recorded set, or create a new specification |
  | `REF-EXISTS` | The specification folder already exists for the resolved slug — **except** when it is in the seeded-not-bound state of FR-049 and the designator set is unchanged, which resumes instead (FR-050) | Retro-seeding is out of scope; create a new specification |

- **FR-037**: `REF-UNRESOLVED` MUST NOT claim to distinguish "does not exist"
  from "your credentials cannot see it". The bulk read does not report which,
  and a message that guesses would send the operator down the wrong path.
- **FR-038**: When designators were supplied and Jira cannot be read reliably,
  the ceremony MUST refuse. It MUST NOT degrade to the inactive-plus-warning
  behaviour that a designator-free run uses, because proceeding would create the
  duplicates this feature exists to prevent.
- **FR-039**: Every refusal class in FR-036 MUST be exercised by at least one
  test per port, and by one conformance scenario.

#### Idempotency and re-invocation

- **FR-040**: Re-invoking with the identical set of designators against a fully
  bound specification MUST write nothing the second time — zero created,
  updated, transitioned, commented, linked, labelled, and zero local bytes
  changed. Against a seeded-not-bound specification the same invocation resumes
  at the confirmation gate instead (FR-050), still changing zero local bytes.
- **FR-041**: Re-invoking with a *different* set of designators for the same
  slug MUST refuse with `REF-RESEED`, whether the specification is fully bound
  or seeded-not-bound.
- **FR-042**: A run that began binding and failed part-way — parent created, one
  adoption failed — MUST report exactly which bindings completed and which did
  not, and MUST leave a recorded state whose behaviour on the next invocation is
  [NEEDS CLARIFICATION: OD-5]. The neighbouring case — a run that performed
  **zero** bindings — is not open: it is the seeded-not-bound state of FR-049,
  resumed by FR-050.

#### Cost, ports, and safety

- **FR-043**: The cost ceiling is stated **per run**, not per specification, and
  a resume (FR-062) is a run: it pays the resolution cost again, by design,
  because it recomputes the write plan from Jira as it now stands. Per run, over
  and above what the current release issues, the ceiling MUST be:
  - *Designator resolution*: `ceil(N / B)` reads for `N` named issues, where `B`
    is the bulk-read batch size — one read for the whole set at the expected
    working range. Never one read per issue.
  - *Role and hierarchy validation*: 0 additional requests; the types come back
    in the resolution read.
  - *Parent resolution*: at most 1 create.
  - *Binding*: 1 identity write per named issue, and at most 1 parent-link write
    per named story-role issue — writes are per-issue by nature; reads are not.
  - *A run naming nothing*: exactly 0 additional requests.
  - *A resume*: the same `ceil(N / B)` reads as a first run, and no more. A
    resume never costs one read per issue, and never requests comment bodies
    (FR-020).
- **FR-044**: No loop introduced by this feature may spawn an external process
  per named issue; the work MUST be batched into a bounded number of calls for
  the whole set.
- **FR-045**: A batched payload MUST NOT travel through a single command-line
  argument that grows with the number of named issues; it MUST be routed through
  a temporary file.
- **FR-046**: The Bash and PowerShell ports MUST be behaviourally identical —
  identical outputs, identical exit codes, identical request sequences — proven
  by the shared conformance corpus.
- **FR-047**: Credentials MUST never reach argv, a log line, an error message,
  or a trace, at any verbosity, on any path this feature adds.
- **FR-048**: An invocation that names nothing MUST produce byte-identical
  output, the identical exit code, and the identical Jira request sequence to
  the current release.

### Key Entities

- **Designator** — one operator-typed string naming one issue, plus the role the
  operator declared for it. A story-role designator reduces to a key or is
  refused; a specification-role designator reduces to a key, or is free text and
  therefore the title of a parent to create.
- **Named issue** — the resolved issue behind a designator: key, type, project,
  status, parent, summary, description. The unit every refusal class is
  evaluated against.
- **Hierarchy role** — `specification` or `story`, resolved from the effective
  configuration to the project's own type name. Never a literal.
- **Pinning marker** — `<!-- speckit-jira pin=KEY -->`, written by the agent
  beside a user story heading at drafting time. Carries the designated key and
  no durable identifier. Expresses an intention, not a binding, and is consumed
  at binding (FR-056, FR-057).
- **Binding** — the two-sided correspondence between a named issue and the local
  artifact it seeded: identity marker on the issue, durable identifier on disk.
  Written by the script, after the confirmation gate.
- **Provenance record** — the mapping, per drafted user story, to its source
  (named issue key, or `new`), and per named issue, to the drafted section it
  seeded.
- **Write plan** — the enumerated set of intended Jira mutations, emitted and
  confirmed before the first one, and the thing `--dry-run` predicts.
- **Seeded-not-bound record** — the explicit record left by a run that did not
  pass the confirmation gate: the retained designator set, and the statement
  that zero bindings were performed. It is what distinguishes a declined run
  from a crashed one, and it is never inferred.
- **Seeding source** — the human-authored content of a named issue, read once,
  never re-read.

## Open Decisions *(to be settled by `/speckit-clarify`)*

Two decisions remain open after the 2026-08-15 clarification session, both
referenced from the requirement they govern. OD-1, OD-2, OD-3, OD-6, and OD-7
were settled in that session and are recorded under Clarifications. Neither
survivor blocks `/speckit-plan`: OD-4 changes only whether an existing
distinction is surfaced to a human, and OD-5's zero-binding case is already
settled by FR-049 and FR-050.

**OD-4 — Distinguishing adopted from created, after the fact.**
*Referenced by FR-031.*

| Option | Behaviour | Trade-off |
| --- | --- | --- |
| A | Machine-readable only — the existing origin field in the identity marker | Nothing new to build; already how human-origin protection works. Invisible to a Product Owner reading the board. |
| B | Also visible in Jira — a distinct additive label, or a line in the managed panel | Legible to a human. Adds a write to every adopted issue and a new thing the mirror must never remove. |

**OD-5 — A partially completed run.**
*Referenced by FR-042, US2 AC4. Narrowed by the OD-2 decision: the case where
**zero** bindings were performed is now settled — that is the seeded-not-bound
state of FR-049, resumed by FR-050. What remains open is only the case where
binding began and then failed part-way, leaving some issues stamped and others
not.*

| Option | Behaviour | Trade-off |
| --- | --- | --- |
| A | Roll back — delete the created parent, unstamp the adopted issues | Cleanest state. But the bridge never deletes a Jira artifact (Principle I), so this option is very likely unavailable. |
| B | Leave in place; the next invocation resumes from the recorded bindings | Consistent with the per-item stamp-and-record ordering the bridge already uses. Requires resumption to be idempotent per issue. |
| C | Leave in place and refuse the next invocation until the operator resolves it | Fail-closed and simple. Costs the operator manual work in exactly the situation they least want it. |

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | **This feature is the first controlled exception, widened from one issue to a named set — and it is justified on the four properties that exception was granted under.** *Operator-declared*: every issue is named by the operator in the invocation (FR-001); no discovery, no label sweep, no JQL scan (Scope §Out of scope). *Named explicitly*: a designator resolves to exactly one key or is refused (FR-002 to FR-008); the extension never guesses which issue is meant, and never touches an issue that was not named. *Read exactly once*: FR-009 and FR-010 make the one-way read a testable requirement — after seeding, no command re-reads issue content to change a local artifact. *Confirmed before any Jira mutation*: FR-032 and FR-033 put the provenance report and the write plan before the first Jira mutation, with `--dry-run` predicting the same set (FR-034). This is deliberately narrower than "before any write", and the narrowing is justified on reversibility: a local write is a file in the operator's own tree, readable in their editor and deletable by them, whereas a Jira mutation lands on a Product Owner's board and is what this principle exists to guard. Gating the local write would force the operator to judge a specification in a terminal, which is not a confirmation in any meaningful sense. The residual risk — a folder left behind by a declined run — is closed rather than tolerated: FR-049 makes that state explicit and marker-free, and FR-050 makes the next invocation resume it rather than refuse it. Beyond the exception: every adopted issue records origin `human`, which is what earns it the human-origin protection this principle requires — never hard-deleted, description preserved above the managed marker (FR-030). **One tension is named rather than glossed**: this principle's exception permits editing the named ticket "never any other", and re-parenting (FR-026) changes what a *different* issue — the story's current parent — holds as children. No request is ever issued against that parent: the write sets the child's parent field, and the old parent's child list changes as a consequence, not as a mutation. The exception therefore holds literally. But the effect is visible on someone else's board, so FR-051 requires the write plan to disclose that parent by key, summary, and status, with the number of children it loses, on a visually distinct line — the operator confirms the off-target effect knowingly or not at all. |
| II | Zero-Churn Idempotency | FR-040 requires a re-invocation with the identical designator set to write nothing of any kind. Identity is recorded in the server-side entity property and the on-disk marker (FR-027), never in a summary or any operator-editable display name. FR-041 makes a *changed* set a refusal rather than a silent rewrite. FR-052 keeps the free-text designator out of the churn loop entirely: it seeds the summary at create time and is never re-applied, so a human rename of the created parent neither reverts nor produces a write on any later run. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Every refusal in FR-036 performs zero writes and exits non-zero with a documented, monotonically escalating code (FR-035). FR-038 is the sharp edge: a run that named issues refuses on an unreliable read rather than degrading, because degrading here manufactures duplicates. The hook contract is untouched — this feature changes the feature-creation ceremony, which is not an `after_*` hook, and adds no failure path to one. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | FR-047 forbids credentials in argv, logs, errors, and traces on every path this feature adds. FR-006 additionally forbids issuing a request to any host the configuration does not name — a cross-site fetch would send the configured credential to an unconfigured host. No fixture may carry a real key, site, or accountId. |
| V | Separation of Team Config / Local Binding / Secrets | The hierarchy roles, the routed project, and the site base URL are all read from the existing three-layer configuration (FR-006, FR-012). This feature adds no configuration inside the extension folder and introduces no new secret-bearing layer. |
| VI | macOS / Linux / Windows Portability | FR-046 requires both ports to be behaviourally identical, proven by the shared conformance corpus. URL reduction and key normalisation are string operations and therefore prime candidates for a port divergence — FR-005 requires each recognised URL shape to be a conformance scenario in both ports, not merely a unit test in one. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | FR-012 forbids satisfying any requirement with a literal type name; the two roles are resolved from the effective `hierarchy` configuration. FR-014 requires a non-default hierarchy fixture, and requires the behaviour to hold for team-managed and company-managed projects alike. `REF-TERMINAL` is evaluated against the configuration's declared statuses, never against a default Atlassian status name. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Designator parsing, URL reduction, role validation, pinning, and the decomposition rule are all tracker-agnostic and belong on the neutral side; the reads, the creates, the parent link, and the identity stamp belong to the sink. No engine module may acquire an issue-key pattern, a site host, or an issue-type name as a literal — the existing boundary greps apply unchanged to everything this feature adds. |
| IX | Two-Tier Privacy Guard, With an Allowlist | **FR-065** is the requirement, not merely this row: content seeded from Jira lands in `spec.md`, a tracked file, so every seeded byte passes the existing pre-write privacy guard at both tiers with the existing allowlist honoured. FR-065 also fixes *when* — over the seed material before the drafting agent sees it, not only over the finished file. The surface is deliberately kept as small as it can be: FR-020 means the read never asks for comment bodies, so the likeliest place for a pasted coordinate — the comment thread — cannot reach a tracked file through this feature at all. |
| X | Self-Healing Automatic Mirror | Unaffected. This feature adds no hook, changes no hook registration, and cannot re-enable a hook the operator disabled. |
| XI | Universal Dry-Run and Auditability | FR-034 requires `--dry-run` to predict exactly the action set of a following real run, including assigned identifiers. FR-033's write plan is that prediction made mandatory even outside dry-run. Every adoption and every create appears in the structured run summary (US1 AC4, US3 AC1). No destructive operation is introduced; adopted issues carry origin `human` and are therefore already excluded from hard deletion by the guarded re-mode. |
| XII | Quality and Catalog Publication | The usual gates apply: SemVer bump, CHANGELOG entry, green three-OS matrix, lint clean, and a dogfood run against a real instance before release. This feature in particular cannot be released on mocks alone — the URL shapes, the bulk read's treatment of an invisible issue, and the parent link on a company-managed project are all things a mock can be made to agree with while the real instance disagrees. |
| XIII | TDD With a Minimum 80% Coverage | Every requirement here is written to be failed first. FR-039 requires each of the fourteen refusal classes to have a test per port and a conformance scenario. The C1 decision is what makes that promise keepable: `REF-DECOMP` and `REF-DRAFT-EDIT` are emitted by a deterministic file validation (FR-058) rather than by a drafting judgement, so both ports compute them identically and the corpus can exercise them. FR-015, which no deterministic check can prove, is reclassified as a drafting instruction rather than left as an untestable requirement — the testability table under FR-019 records that split explicitly. FR-010's test — edit the issues in Jira, assert `spec.md` is byte-identical — is a regression test written before the behaviour exists. No implementation task may be planned without its test task preceding it. Tests identify state by identifiers they themselves recorded: the mocked double's port, the fixture paths, and the keys the test itself seeded — never a machine-wide scan. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | The simplest solution reuses what already ships: the bulk read, the identity marker with its origin field, the specification and story markers on disk, the managed-panel splice, and the hierarchy configuration. This feature adds designator parsing, the pinning rule, and the parent resolution — nothing else. No new abstraction, no new configuration format, no new dependency is required by this specification; the plan must justify any it introduces. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Every element traces to a requirement above. Deliberately excluded, and listed here so they are not smuggled in: label-based discovery, any search of any kind — FR-023 closes the one place a search could have crept in, by never resolving a free-text parent designator — retro-seeding an existing specification folder, continuous two-way sync of ticket content, reading attachments, **reading comments** (FR-020 — the read never asks for them), and any behaviour change to a run that names nothing (FR-048). |
| XVI | Human Readable — Readable by a Human Above All | The provenance report (FR-032) exists solely so a human can see where the draft came from. Every refusal names the offending designator and carries a copy-pasteable remediation (FR-035, FR-036) — never a bare code. The write plan is structured prose, and FR-051 makes its most consequential line typographically distinguishable rather than buried in a uniform list — a plan whose riskiest entry reads like its safest is unreadable in the only sense that matters here. And the point of the whole feature is that the Product Owner's own sentences reach the specification instead of being paraphrased by an agent that never read them. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator with one existing parent-level issue and three
  existing feature-level issues obtains, in one invocation, a specification
  whose user stories correspond one-to-one to those three issues, with zero
  duplicate issues created.
- **SC-002**: After seeding and the next full reconcile, the number of
  **story-role** issues created equals the number of drafted user stories minus
  the number of named story-role issues — exactly, with no off-by-one and no
  duplicate. A parent created from a free-text designator (FR-023) is counted
  separately and is never part of that arithmetic: it is at most one, it is
  reported on its own line of the run summary, and it is zero whenever the
  parent was adopted or none was designated.
- **SC-003**: A second invocation with the identical designator set produces
  zero writes of every kind and zero changed local bytes.
- **SC-004**: An invocation that names nothing is byte-identical in output, exit
  code, and request sequence to the current release, measured by the existing
  conformance scenarios running unchanged.
- **SC-005**: Issue reads grow by whole batches and never per issue: naming any
  number of issues up to the batch size `B` costs exactly one read, and naming
  `N` costs `ceil(N / B)` — never `N`. Naming any number of issues spawns no
  process per issue.
- **SC-006**: All fourteen refusal classes produce zero writes, name the
  offending designator or marker, and carry a remediation line — 14 of 14
  covered by a scenario in both ports.
- **SC-007**: A Product Owner comparing a named issue's description before the
  ceremony and after the next full reconcile finds every byte they wrote intact,
  including after they edit it again post-binding.
- **SC-008**: An operator can, before any Jira mutation occurs, read which part
  of the drafted specification came from which issue, and what the run intends
  to write where — and declining leaves a specification they can resume without
  re-drafting a single line.
- **SC-009**: Editing every named issue in Jira after seeding changes not one
  byte of `spec.md` across a subsequent plan, tasks, and reconcile.
- **SC-010**: The Bash and PowerShell ports diverge on zero conformance
  scenarios covering this feature.

## Assumptions

- **The two roles this feature manipulates are `specification` and `story`.**
  The task role is out of scope: a named issue is never a task-role issue, and
  `tasks.md` mirroring is unaffected.
- **The bulk read is key-addressed and therefore free of search-index lag**, and
  it reports a missing issue and a forbidden issue identically — hence FR-037.
- **A named issue's project routing is decided by the existing routing
  configuration**, not by the issue. A named issue outside the routed project is
  a refusal (`REF-ROUTING`), not a re-route.
- **"Terminal status" means a status the configuration already declares as
  halted or terminal for that project.** No default Atlassian status name is
  assumed.
- **The site base URL is the one the configuration already holds** for
  authenticating reads; no second URL is introduced for URL matching.
- **The specification folder does not exist when the ceremony runs.** This
  feature only ever seeds a new specification; `REF-EXISTS` covers the rest.
- **The existing single-key leading-positional form keeps working as documented**
  and is not redefined by this feature (US5 AC3). Whether the new designator
  surface subsumes it is a plan-level decision, not a specification-level one.
- **Attachments are never read or copied.** They are preserved on the issue and
  ignored as source material.
- **One shape, and only one, produces a folder carrying no ticket key**: a
  specification-role designator given as free text with no story-role designator
  alongside it (FR-059, fifth case). There is no key in that invocation to carry,
  so the ordinary description-derived naming applies. This is deliberate, not an
  oversight, and it is the single exception to the ticket-first folder naming
  every other shape preserves.
- **Comments are never read either** (FR-020). They are preserved on the issue
  and ignored as source material. The operator-facing consequence: a decision
  that lives in the comment thread will not reach `spec.md`. Carry it into the
  ticket's description before invoking the ceremony.
- **The privacy guard already in place is the one that applies to seeded
  content.** No new tier and no new allowlist mechanism is introduced.
