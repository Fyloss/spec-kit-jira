# Feature Specification: Publish every feature artifact on the specification ticket

**Feature Branch**: `036-attach-feature-artifacts`

**Created**: 2026-08-31

**Status**: Draft

**Input**: User description (translated from French): "On every Spec Kit command
(specify, plan, tasks, analyze, converge, …) I want you to attach, to the
specification-level ticket of the hierarchy, every artifact (file, media, …)
generated or added in the feature folder — for example `spec.md`, `plan.md`,
`tasks.md`, `research.md`, in a folder such as `specs/001-feature-test`. Each
time an artifact is added, attach it through a new comment on that ticket, so
that any Jira user with access to the tickets can read back everything Spec Kit
produced."

## Context — Jira currently shows a summary, not the work

The mirror is good at the two documents it was built for. `spec.md` becomes the
specification ticket's managed description panel and one story per user story;
`plan.md` is spliced onto the parent; `tasks.md` becomes the checklist. Those
three are the only files of the feature folder Jira ever sees.

A Spec Kit feature folder holds considerably more. `/speckit-plan` alone writes
`research.md`, `data-model.md`, `quickstart.md` and a `contracts/` directory;
`/speckit-checklist` writes into `checklists/`; an operator drops diagrams,
exports and screenshots beside them. None of it reaches Jira. A Product Owner
who has Jira and no repository checkout can read what the feature is *for* and
never read the research that decided it, the data model it assumes, or the
contracts a QA engineer would test against.

The repository's own vision document has anticipated both halves of the answer —
"Automatic comments for the complementary artefacts" among the envisioned
capabilities, "Attachment and screenshot upload" in the longer backlog — and
authorised neither. This specification is that authorisation, and it takes the
two together: the artifact travels as an attachment on the specification ticket,
and a comment announces it, so the ticket's activity stream reads as the
feature's own history.

Two constraints the vision named are load-bearing here rather than decorative.
**Idempotency** (Principle II): a re-run over an unchanged folder must add
nothing at all — the comment stream grows only when the folder does. **The
privacy guard** (Principle IX): these files were written for a repository, not
for a Jira site, and they now become payloads; the guard applies to them exactly
as it applies to a description.

A third constraint is this repository's own, and it is the one most easily
missed. The reconcile short-circuit records a hash of `spec.md`, `plan.md` and
`tasks.md`, and a run whose three hashes match the recorded ones does no work.
The moment `research.md` becomes publishable, that input set is incomplete: a
run triggered after `research.md` changed — and nothing else — would short-
circuit and never publish it. The change-detection inputs and the publishable
set are the same set, or the feature silently loses artifacts.

**What is not in scope, and must not be weakened:** the managed description
panel, the story tier, the checklist and the transitions all keep working
exactly as they do. Nothing about how the mirror decides *what a ticket says*
changes. This feature adds one new kind of output beside them.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A Jira reader can read everything Spec Kit produced (Priority: P1)

A Product Owner opens the specification ticket for a feature. Attached to it are
the feature folder's artifacts — `spec.md`, `plan.md`, `tasks.md`, `research.md`,
`data-model.md`, the contracts, the checklists, the diagrams an engineer dropped
in. The ticket's comment stream tells them which artifact arrived when. They
download the ones they care about and read them, without a checkout, without
repository access, without asking anyone.

**Why this priority**: this is the whole point of the request. Delivered alone —
first publication only, nothing else — it already turns the ticket from a summary
into the readable record the user asked for.

**Independent Test**: run the mirror on a feature folder holding more than the
three mirrored documents, then, from Jira alone, open the specification ticket
and confirm every file of that folder is downloadable and that a comment names
each one.

**Acceptance Scenarios**:

1. **Given** a feature folder holding `spec.md`, `plan.md`, `tasks.md`,
   `research.md`, `data-model.md`, `quickstart.md`, `contracts/api.md` and
   `checklists/requirements.md`, and a specification ticket that carries none of
   them, **When** a lifecycle event fires the mirror, **Then** all eight
   artifacts are attached to that specification ticket and the run summary
   reports them as published.
2. **Given** the same run, **When** a Jira user reads the ticket's comments,
   **Then** exactly one comment was posted by that run, it names all eight
   artifacts by their paths relative to the feature folder, it identifies the
   lifecycle event that produced them, and it reads as prose a non-engineer can
   follow.
3. **Given** a feature folder containing a binary file (a PNG diagram),
   **When** the mirror runs, **Then** that file is attached unmodified and is
   downloadable byte-for-byte identical to the file on disk.
4. **Given** a feature whose specification ticket does not exist yet, **When**
   the mirror runs and creates it, **Then** the artifacts are published onto the
   ticket created in that same run, not deferred to the next one.
5. **Given** artifacts in nested directories (`contracts/api.md` and
   `checklists/api.md`), **When** both are published, **Then** each is
   distinguishable in Jira's attachment list — one never displaces or shadows
   the other.
6. **Given** a feature folder whose only change is a new `checklists/ux.md`
   written by `/speckit-checklist` — `spec.md`, `plan.md` and `tasks.md` all
   untouched — **When** that command completes, **Then** the mirror runs and
   publishes `checklists/ux.md`, rather than waiting for a later command.

---

### User Story 2 - Re-running changes nothing (Priority: P1)

A developer runs two Spec Kit commands in a row without the feature folder
changing between them — or simply re-runs the same one. The second run adds no
attachment and no comment. The ticket does not accumulate noise, and the
activity stream stays a record of real events.

**Why this priority**: P1 alongside publication, not below it. Principle II is
not a quality bar this feature aims at, it is the condition under which the
feature is allowed to exist at all — the vision document says so explicitly, and
an append-only comment stream is exactly the design it rules out. A publication
path without this is not a smaller version of the feature; it is a defect.

**Independent Test**: run the mirror twice over an unchanged feature folder and
assert the second run's summary reports zero attachments and zero comments, and
that the ticket's attachment and comment counts are identical before and after.

**Acceptance Scenarios**:

1. **Given** a specification ticket already carrying every artifact of an
   unchanged feature folder, **When** the mirror runs again, **Then** it
   publishes zero artifacts, posts zero comments, and the summary says the
   artifacts are unchanged.
2. **Given** an unchanged folder, **When** the mirror runs a third and fourth
   time, **Then** the ticket's attachment count and comment count are the same
   as after the first run.
3. **Given** a folder where exactly one artifact changed, **When** the mirror
   runs, **Then** exactly that one artifact is published and exactly the
   comments announcing it are posted — the unchanged artifacts produce no write
   of any kind.
4. **Given** a change confined to an artifact that is *not* `spec.md`,
   `plan.md` or `tasks.md` — `research.md`, say — **When** the mirror runs,
   **Then** the run does not short-circuit, and that artifact is published.

---

### User Story 3 - A revised artifact is republished, and the earlier one survives (Priority: P2)

`/speckit-clarify` rewrites `spec.md`; `/speckit-converge` appends to `tasks.md`.
On the next lifecycle event the revised artifact is published again, and a new
comment announces the revision. The version published before it is still there:
a reader can see what the plan said before the clarification, and nothing the
bridge ever put on the ticket is taken away.

**Why this priority**: the record is only trustworthy if it follows the folder.
It ships after publication because a folder whose artifacts never change is
already fully served by US1 — but a feature lives through several commands, so
this is what makes the record hold up past the first one.

**Independent Test**: publish a folder, modify one artifact, re-run, and assert
the ticket carries both the earlier and the revised copy, with a comment for
each and the later comment identifying the revision as such.

**Acceptance Scenarios**:

1. **Given** a specification ticket carrying a published `spec.md`, **When**
   `spec.md` changes and the mirror runs, **Then** the revised content is
   published and announced by a new comment.
2. **Given** that same ticket after the revision, **When** a reader lists its
   attachments, **Then** the previously published copy is still present and
   still downloadable — no bridge operation removed, replaced or truncated it.
3. **Given** a ticket carrying several published versions of one artifact,
   **When** a reader reads the comment stream, **Then** the order of publication
   is unambiguous and the most recent version of each artifact is identifiable
   without opening the files.
4. **Given** an artifact deleted from the feature folder, **When** the mirror
   runs, **Then** its published copy remains on the ticket and no delete is
   issued against Jira.

---

### User Story 4 - The operator can predict and audit the publication (Priority: P2)

Before a first publication onto a ticket a whole team watches, a developer runs
the mirror in dry-run. The report names every artifact that would be published
and every comment that would be posted. The real run then does exactly that,
and its summary is a record of what was published, what was skipped, and why.

**Why this priority**: this is the constitutional cost of admitting a new write
kind. It ships after publication itself because it has nothing to predict until
publication exists — but it ships in the same feature, because a write operation
without a dry-run and without a summary line is not permitted to exist.

**Independent Test**: run dry-run then the real run against the same state, and
assert the predicted artifact set and comment set match the actual ones exactly.

**Acceptance Scenarios**:

1. **Given** a feature folder with unpublished artifacts, **When** the mirror
   runs in dry-run, **Then** it names every artifact it would publish and every
   comment it would post, and issues zero writes.
2. **Given** the same state, **When** the real run follows, **Then** the set of
   artifacts published and comments posted is exactly the set the dry-run
   predicted.
3. **Given** a run in which some artifacts were skipped, **When** the operator
   reads the summary, **Then** each skipped artifact is named together with the
   reason it was skipped, in a form the operator can act on.
4. **Given** any of these runs, **When** the mirror was fired by a lifecycle
   hook and publication failed, **Then** the host Spec Kit command still
   succeeds and one actionable warning is surfaced.

---

### Edge Cases

- **An artifact carries a BLOCK-tier coordinate.** `research.md` quotes a live
  `*.atlassian.net` host or an Atlassian token prefix. These files were written
  for a repository and were never scanned before; publication makes them
  payloads. The run refuses on the established path — zero writes of any kind
  for the whole run, the documented exit code, the offending value never echoed.
- **An artifact exceeds what the Jira site accepts.** The per-attachment size
  limit is a site setting, not a constant the bridge can assume. The oversized
  artifact is skipped, named in the summary with its size and the limit, and the
  rest of the run proceeds.
- **Two artifacts share a base name in different subdirectories.**
  `contracts/api.md` and `checklists/api.md` both flatten to `api.md` in Jira's
  attachment list. Publication must keep them distinguishable.
- **A file the repository ignores sits in the folder** — an editor backup, a
  `.DS_Store`, a local scratch export. It is not part of what Spec Kit produced
  and is not published.
- **The specification ticket was created by a human and adopted.** Publication
  is additive and permitted; the human-origin protection concerns deletion and
  overwrite, and neither happens here.
- **The feature has no specification ticket** — routing refused, or the run
  failed before creation. Nothing is published, nothing is half-published, and
  the next successful run publishes the folder as it then stands.
- **The folder holds many artifacts.** A first publication onto a mature feature
  can face several dozen files at once. The run stays within the repository's
  process budget: no external process is spawned per artifact, and no payload is
  passed through a command-line argument that grows with the number or the size
  of the artifacts.
- **The same artifact is unchanged but its earlier publication failed midway.**
  The next run completes the publication rather than concluding, from a
  recorded success, that there is nothing to do.

## Requirements *(mandatory)*

### Functional Requirements

**Publication**

- **FR-001**: The mirror MUST publish, onto the feature's specification-level
  ticket, every artifact held in the feature directory, including artifacts in
  nested subdirectories, at whatever depth.
- **FR-002**: An artifact MUST be published as an attachment on that ticket,
  carrying its exact on-disk bytes — text and binary alike, unmodified.
- **FR-003**: The specification-level ticket is the only publication target.
  Artifacts MUST NOT be published onto story-level or task-level tickets.
- **FR-004**: Every published artifact MUST be announced on the same ticket's
  comment stream. The announcement MUST name the artifact by its path relative
  to the feature directory, and MUST identify the lifecycle event and the run
  that published it.
- **FR-005**: An attachment MUST be identifiable, in Jira, by a name that
  distinguishes artifacts sharing a base name in different subdirectories, and
  that a human reader can map back to a path in the feature directory without
  consulting documentation.
- **FR-006**: When the mirror creates the specification ticket in the same run,
  publication MUST happen onto that ticket within that run.
- **FR-007**: Files excluded by the repository's own ignore rules MUST NOT be
  published.
- **FR-008**: A run MUST post exactly ONE comment for the artifacts it publishes,
  however many they are, listing every one of them — each on its own line, named
  by its path relative to the feature directory and marked as a first
  publication or as a revision. A run that publishes nothing MUST post nothing.

**Idempotency**

- **FR-009**: A run over a feature directory whose artifacts are all already
  published in their current content MUST publish zero artifacts and post zero
  comments.
- **FR-010**: A run in which some artifacts changed MUST publish exactly the
  changed and newly added ones, and post exactly the comments announcing those.
- **FR-011**: The mirror's change detection MUST treat every publishable
  artifact as an input, so that a change confined to an artifact outside
  `spec.md`, `plan.md` and `tasks.md` prevents the run from short-circuiting.
- **FR-012**: The mirror MUST record what it has published, per artifact and per
  content, so that FR-009 holds across runs, machines and interrupted runs, and
  MUST re-derive that record rather than trusting it blindly when Jira contradicts
  it.
- **FR-013**: An artifact whose content changed MUST be published again, and
  announced as a revision rather than as a first publication.

**Preservation**

- **FR-014**: The mirror MUST NEVER delete, replace or truncate an attachment or
  a comment it previously published. A superseded version stays on the ticket.
- **FR-015**: An artifact removed from the feature directory MUST leave its
  published copies on the ticket, and MUST produce no Jira write.

**Safety**

- **FR-016**: Every artifact MUST pass the pre-write privacy guard before
  publication, on the same two tiers and with the same allowlist as any other
  payload. A BLOCK-tier finding MUST refuse the run with zero writes, the
  documented exit code, and a message naming the artifact and the shape found —
  never the offending value.
- **FR-017**: An artifact the Jira site will not accept — over its
  per-attachment size limit — MUST be skipped with a named warning stating the
  artifact, its size and the limit, and MUST NOT prevent the remaining artifacts
  from publishing.
- **FR-018**: A publication failure inside a lifecycle hook MUST NOT fail the
  host Spec Kit command; it MUST surface one actionable warning.

**Coverage and reporting**

- **FR-019**: The extension MUST declare, and the mirror MUST run on, every host
  lifecycle event whose command writes into the feature directory: the six
  already declared — `after_specify`, `after_clarify`, `after_plan`,
  `after_tasks`, `after_implement`, `after_analyze` — plus `after_converge` and
  `after_checklist`. `after_constitution` and `after_taskstoissues` MUST NOT be
  declared (see Assumptions).
- **FR-020**: Dry-run MUST report the exact set of artifacts that would be
  published and comments that would be posted, and issue zero writes.
- **FR-021**: The run summary MUST report, per artifact, whether it was
  published, unchanged, or skipped, and for a skip, the reason.
- **FR-022**: Both ports MUST produce byte-identical comment bodies, attachment
  names and run-summary output, and identical Jira API call sequences, for the
  same feature directory.
- **FR-023**: Publication MUST NOT spawn an external process per artifact, and
  MUST NOT pass a payload that grows with the artifact set through a single
  command-line argument.

### Key Entities *(include if data involved)*

- **Feature artifact**: a file held in the feature directory, at any depth, that
  the repository's ignore rules do not exclude. Identified by its path relative
  to that directory; its content is its bytes on disk.
- **Publication record**: the bridge's memory of what it has already put on the
  ticket — which artifact, at which content, in which run. It is what makes
  FR-009 true on the second run and what FR-013 compares against.
- **Specification ticket**: the ticket playing the `specification` role for the
  feature in the configured hierarchy. It is the sole target; the feature adds
  no new way of finding it.
- **Artifact comment**: the human-facing announcement on the ticket's activity
  stream. It carries the artifact's identity, the run that published it, and
  whether it is a first publication or a revision.

## Constitution Check *(mandatory)*

Assessed against constitution **4.0.0**.

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Publication flows one way only: the folder is the source, Jira the mirror. FR-014 and FR-015 forbid the mirror from deleting or replacing anything it published, which is the principle's central prohibition applied to a new artifact kind. No new read-and-edit path over a ticket the bridge did not create is introduced, so neither controlled exception is invoked or widened. Publication onto an adopted, human-origin ticket is additive and touches nothing a human wrote. |
| II | Zero-Churn Idempotency | FR-009 is the principle stated for this write kind, and US2 carries it at P1 for that reason. FR-012 supplies the recorded identity it needs; FR-011 keeps the short-circuit from hiding an unpublished artifact behind a stale hash. The live idempotency suite's exhaustive write-kind assertion list must gain the new kinds — attachment and comment — in the same change that adds them to the sink, as the principle's enforcement test requires. Identity is keyed on artifact path and content, never on a display name. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-016 refuses the run with zero writes on a BLOCK finding, on the established exit code. FR-018 keeps the hook half: a publication failure warns and returns success to the host. FR-017's skip is a per-artifact refusal to attempt an impossible write, not a swallowed error — it is named in the summary. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected as a tree rule: no credential is read or recorded by publication. FR-016 is the outbound counterpart — an artifact carrying a token prefix or a live coordinate never leaves the machine. |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected. This feature adds no configuration key to any layer; the publication record is run state, not configuration, and lives where run state already lives. |
| VI | macOS / Linux / Windows Portability | FR-022 requires byte-identical output and identical call sequences from both ports, proven by the conformance corpus. Two known Windows hazards bind directly: uploading file content must not route the payload through a command line (`docs/11-process-budget.md`; the binding cap is the Windows one), and any multi-line output crossing the guard must not acquire CRLF (`docs/10-windows-portability.md`). FR-023 encodes the first. A divergence found on Windows alone is diagnosed on the real runner, never emulated. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | The publication target is the ticket playing the configured `specification` role, resolved through the existing hierarchy mapping — never a literal issue type. FR-017 treats the attachment size limit as a site fact to be honoured and reported, not a constant to be assumed. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Enumerating the feature directory, deciding what changed, and holding the publication record are engine concerns and contain no Jira knowledge. Attachments and comments are Jira concepts and belong entirely to the sink, reached through the neutral interchange document, which gains the artifact set as a schema-validated field. |
| IX | Two-Tier Privacy Guard, With an Allowlist | FR-016 applies the existing guard unchanged — both tiers, the same allowlist, the offending value never echoed. This is the principle's surface materially widening: `research.md`, `data-model.md`, `contracts/` and `checklists/` become payloads for the first time. Precision matters more here than anywhere, because a BLOCK false positive on a research log would refuse whole runs; the allowlist is the designed answer and must be exercised against artifact content. |
| X | Self-Healing Automatic Mirror, Within Its Own Boundary | Publication is inside the boundary: it mirrors what the extension owns. FR-012's "re-derive rather than trust blindly" is the self-healing clause for the interrupted-run case, and the last edge case is its test. Nothing here reads, writes or reports `.specify/extensions.yml`. FR-019 changes what the *manifest declares* — the host then writes the registry from it, and the install's purge of events the manifest no longer declares keeps that block self-cleaning. The extension still never inspects the result. |
| XI | Universal Dry-Run and Auditability | FR-020 gives the new write kind its dry-run, FR-021 its summary lines. Publication is never destructive, so it stays outside the guarded re-mode entirely — FR-014 makes that structural rather than incidental. |
| XII | Quality and Catalog Publication | A new observable output and a widened manifest are user-visible: a version bump and a CHANGELOG entry naming the new attachments, the new comments and any added lifecycle events. The three-OS matrix, the linting gate and the coverage gate bind as usual. The dogfood gate is load-bearing here: attachment upload against a real site is where an unsupported content type, a site size limit or a permission the token lacks will actually appear, and no mock will show it. |
| XIII | TDD With a Minimum 80% Coverage | Every requirement above is written to be falsifiable, and its test precedes its implementation in `tasks.md`. Idempotency (FR-009…FR-013), fail-closed (FR-016) and the privacy guard are critical paths and target near-100%. Cross-port equivalence (FR-022) is proven by conformance scenarios, not by twin unit tests. Tests identify the state they observe — the fixture folders they create, the tickets they record — never by machine-wide scan. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | No new abstraction layer: attachments and comments are two more operations behind the existing sink interface. No configuration key, no opt-in flag — the request is unconditional and the privacy guard, not a switch, is the control. No new dependency is anticipated; the plan justifies one if the upload path proves to need it, and FR-023 is the constraint any such choice must satisfy. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | The vision document lists both halves of this feature as envisioned and authorises neither; this specification is the authorisation, and it is bounded by the requirements above. FR-019 is the manifest's own "an eighth event requires a spec" clause being exercised, and it stops at the two events that carry a requirement: `after_constitution` writes outside the feature directory and `after_taskstoissues` writes nothing publishable, so declaring either would ship a lifecycle event no requirement demands. Deliberately excluded and left in the backlog: publishing onto story or task tickets, rendering artifact content into the ticket body, removing superseded attachments, and any per-team configuration of what gets published. |
| XVI | Human Readable — Readable by a Human Above All | FR-004, FR-005 and FR-008 exist for this principle: one comment per run, in prose, naming every artifact it published and the event that produced it, and an attachment name that maps to a path a human recognises. The rejected alternative — one comment per artifact — would put six or more notifications on a watcher for a single `/speckit-plan`, and an activity stream a reader gives up on serves nobody. FR-017's warning names the artifact, its size and the limit; FR-016's names the artifact and the shape. The whole feature's purpose is a human reading Jira and understanding the work without a checkout. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A reader with Jira access and no repository checkout can obtain
  every current artifact of a mirrored feature directory from the specification
  ticket alone — 100% of the folder's publishable files, none missing.
- **SC-002**: A second mirror run over an unchanged feature directory adds
  exactly 0 attachments and 0 comments, verified against a real Jira instance,
  and repeats that on every subsequent run.
- **SC-003**: A run in which exactly one artifact changed publishes exactly one
  artifact — no unchanged artifact is republished.
- **SC-004**: A mirror run that publishes N artifacts, for any N ≥ 1, posts
  exactly 1 comment, and that comment names all N; a run that publishes 0
  artifacts posts 0 comments.
- **SC-005**: A `/speckit-checklist` run whose only output is a new file under
  `checklists/` results in that file being readable from the specification
  ticket, without any further Spec Kit command being run.
- **SC-006**: A dry-run's predicted publication set matches the following real
  run's actual publication set exactly, in 100% of tested states.
- **SC-007**: 100% of artifacts carrying a BLOCK-tier coordinate result in a run
  with zero Jira writes and the documented exit code; 0% of allowlisted
  corporate or Confluence content in an artifact produces a block or a warning.
- **SC-008**: For the same feature directory, both ports produce byte-identical
  comment bodies, attachment names and summary output, and identical Jira API
  call sequences.
- **SC-009**: A first publication of a feature directory holding 20 artifacts
  totalling under 5 MB completes within a single mirror run, in under 60 seconds
  on a developer machine, and spawns no external process per artifact.
- **SC-010**: After a mirror run that failed partway through publication, the
  next run leaves the ticket carrying every current artifact — no artifact is
  permanently lost to a partial run.
- **SC-011**: A publication failure never changes the exit status of the host
  Spec Kit command that fired the hook, in 100% of injected-failure cases.

## Assumptions

- **Every file counts.** "Artifact" is read literally: every regular file in the
  feature directory at any depth, text or binary, whether Spec Kit generated it
  or a human dropped it there. Files the repository's own ignore rules exclude
  are not part of what Spec Kit produced (FR-007).
- **Revisions publish; nothing is withdrawn.** The user's description says "each
  time an artifact is added". A feature folder's files are also *revised* —
  `/speckit-clarify` rewrites `spec.md` — and a record that stopped at the first
  version would not let a reader "read back everything Spec Kit produced". So a
  changed artifact publishes again (FR-013). That the earlier copy survives is
  not a preference: Principle I forbids the mirror from deleting a Jira artifact,
  so accumulation is the compliant behaviour, and FR-014 states it as such.
- **One comment per run, not one per artifact.** Your description says "each
  time an artifact is added ... a new comment", and FR-008 departs from the
  letter of that in favour of its stated purpose. A single `/speckit-plan`
  publishes six or more artifacts; per-artifact comments would put six
  notifications on every watcher, and across a feature's eight lifecycle events
  the epic accumulates thirty to fifty. The unit a Product Owner reads is the
  step, not the file. The consolidated comment keeps the granularity where it
  matters — one line per artifact, each marked first publication or revision.
- **Two lifecycle events are added, two are refused.** `after_converge` because
  you named it; `after_checklist` because `/speckit-checklist` writes only into
  `checklists/`, so with the six current events and the run-state short-circuit
  its output could stay unpublished indefinitely. `after_constitution` writes to
  `.specify/memory/`, outside the feature directory — declaring it would fire
  runs that can publish nothing. `after_taskstoissues` produces GitHub issues;
  where it also touches `tasks.md`, the next declared event catches it.
- **The specification ticket is the one the hierarchy already defines.** This
  feature adds no new way of locating it and no new binding; it publishes onto
  whatever the existing routing and recognition resolve.
- **Publication is unconditional.** No configuration key gates it, per Principle
  XV — the request is unconditional, and adding an opt-in switch would be
  speculative. The privacy guard and the ignore rules are the controls.
- **The site's attachment size limit is discovered or reported, never assumed.**
  It is a per-site setting; Principle VII forbids baking in a default.
- **The publication record lives with the existing run state**, alongside the
  hashes the short-circuit already keeps, rather than in a new store.
- **The Jira token used by the mirror can create attachments and comments on the
  specification ticket.** Where it cannot, the failure is a permission error to
  be reported in the operator's own terms, not a new capability to negotiate.

## Out of Scope

- Publishing artifacts onto story-level or task-level tickets.
- Rendering artifact content into a ticket description or a comment body — the
  artifact travels as a file, and the description panel is unchanged.
- Removing, replacing or pruning superseded attachments, including under the
  guarded re-mode.
- Any per-team configuration of which artifacts are published.
- Publishing artifacts held outside the feature directory.
- Reading artifacts back *from* Jira into the repository.
