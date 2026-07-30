# Feature Specification: Reconcile Recognises the Tickets It Already Created

**Feature Branch**: `fix/idempotent-reconcile`

**Created**: 2026-07-29

**Status**: Draft

**Input**: User description: "I have just tested the extension on a consuming project; the idempotent part of the reconcile command apparently does not work, because it creates duplicate tickets in Jira when the command is re-run."

## Context

Reconcile is specified (001 FR-030) and governed (Constitution II) to produce zero Jira
writes when re-run against an unchanged specification. In a consuming repository it does
the opposite: every run mirrors the same specification as if Jira were empty, so a
developer who runs `/speckit.plan` after `/speckit.specify` ends up with two tickets for
every user story, three after the next lifecycle command, and so on.

The reconcile run has no step that asks Jira "which tickets already belong to this
specification?". The write planner decides *create* versus *update* from a set of known
ticket references that only an explicit caller-supplied override ever fills; on a normal
run that set is empty, so every story is planned as a creation. Symmetrically, the
tickets reconcile creates are never stamped with the bridge's identity marker, so even a
lookup would find nothing to recognise. The marker itself, as recorded today, names the
repository and the specification but nothing that distinguishes one user story's ticket
from another's within the same specification.

This feature closes that loop: the bridge gives each user story a durable identifier
recorded in the specification file, stamps it on the ticket it creates, and uses it to
recognise that ticket on every later run — updating it instead of duplicating it, and
writing nothing at all when nothing changed.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A second run creates no duplicates (Priority: P1)

As a developer using the extension in my own repository, I run a spec-kit lifecycle
command a second time — or simply run reconcile twice — and Jira still holds exactly one
ticket per user story. The tickets created by the first run are recognised and updated
in place; nothing is created again.

**Why this priority**: This is the reported defect and it makes the extension unusable
in practice: every lifecycle command multiplies the team's backlog. Nothing else in this
feature matters until re-running is safe.

**Independent Test**: Reconcile a specification with three user stories against a Jira
project, then reconcile it again unchanged; assert the project holds three tickets, not
six, and that the second run's summary reports zero creations.

**Acceptance Scenarios**:

1. **Given** a specification already mirrored into an empty Jira project, **When**
   reconcile runs again on the same unchanged specification, **Then** no ticket is
   created and the run summary reports `created: 0`.
2. **Given** a specification already mirrored, **When** reconcile runs again after one
   user story's content changed, **Then** the ticket for that story is updated and no
   ticket is created.
3. **Given** a specification already mirrored, **When** a new user story is added and
   reconcile runs, **Then** exactly one ticket is created — for the new story — and the
   pre-existing stories' tickets are not duplicated.
4. **Given** a first reconcile run that creates tickets, **When** the run completes,
   **Then** every created ticket carries the bridge's identity marker naming this
   repository, this specification, and the durable identifier of the user story it
   mirrors, and that same identifier is recorded in the specification file.
5. **Given** a specification already mirrored, **When** its user stories are reordered
   or one is inserted between two others and reconcile runs, **Then** every ticket stays
   bound to the story it has always mirrored, no two stories exchange their tickets, and
   no ticket is created for a story that already had one.
6. **Given** a run whose recognition step cannot complete reliably (rejected
   credentials, unreachable Jira, exhausted retries), **When** reconcile runs, **Then**
   it performs zero writes, creates zero tickets, and reports the named cause with its
   remediation — never falling back to "assume nothing exists" and creating duplicates.

---

### User Story 2 - An unchanged re-run writes nothing at all (Priority: P2)

As an operator, when I re-run reconcile against a corpus that has not changed, the run
reports zero creations *and* zero updates, and my specification file is left untouched.
Recognising a ticket is not enough: rewriting the same content onto it is churn — it
floods the ticket's history, spams watchers, and breaks the "nothing happened because
nothing changed" guarantee.

**Why this priority**: Story 1 stops the backlog from growing; this story stops the
noise. It is the letter of Constitution II and of 001 FR-030, and it is what makes the
mirror safe to fire from every lifecycle hook.

**Independent Test**: Reconcile twice with no change in between and assert the second
run's summary reports `created: 0` and `updated: 0`, with an empty action set and a
byte-identical specification file.

**Acceptance Scenarios**:

1. **Given** a specification already mirrored and unchanged, **When** reconcile runs
   again, **Then** the run summary reports `created: 0` and `updated: 0` and no write
   request of any kind is issued.
2. **Given** a specification whose durable identifiers are already recorded, **When**
   reconcile runs again, **Then** the specification file is byte-identical afterwards —
   including its line endings and trailing whitespace.
3. **Given** a specification whose second user story alone changed, **When** reconcile
   runs, **Then** exactly one ticket is written and the other tickets receive no write.
4. **Given** a ticket of human origin carrying prose above the managed panel, **When**
   reconcile re-runs unchanged, **Then** the ticket receives no write and the human
   prose is untouched.
5. **Given** any of the scenarios above, **When** the same run is performed with
   `--dry-run`, **Then** the predicted action set is identical to the real run's and
   neither Jira nor the specification file is written.

---

### User Story 3 - Recognition survives a rename, a fresh clone, and a colleague (Priority: P3)

As a member of a team, I get the same result whether I am the developer who first
mirrored the specification or a colleague who just cloned the repository, and renaming a
specification folder does not orphan its tickets.

**Why this priority**: Recognition that depends on state left behind on one machine
re-introduces the duplication defect for everyone else, which is precisely the failure
mode reported. 001 already commits to this ("identity resolves from the stored marker,
not the path"; "two developers reconciling the same instance concurrently — idempotency
converges to zero duplicate tickets").

**Independent Test**: Mirror a specification, commit it, then reconcile the same
specification from a second clone that has never run the bridge, and assert zero
creations.

**Acceptance Scenarios**:

1. **Given** a specification mirrored from one working copy and committed, **When**
   reconcile runs from a different clone with no local run history, **Then** no ticket
   is created and no identifier is reassigned.
2. **Given** a specification whose folder has been renamed after its tickets exist,
   **When** reconcile runs, **Then** the existing tickets are recognised and updated,
   and no ticket is created.
3. **Given** two working copies reconciling the same specification one after the other,
   **When** both runs complete, **Then** Jira holds exactly one ticket per user story.

---

### User Story 4 - Recognition feeds the safety rules that protect Jira-side work (Priority: P3)

As a Product Owner, when the bridge updates a ticket my team has already advanced or
flagged, the run tells me about it and does not silently pull the ticket backwards.

**Why this priority**: Once reconcile updates real tickets rather than only creating new
ones, Constitution I forbids an unwarned overwrite and 001 FR-031/034/035/036 govern
what the run may do. These rules already exist but are inert on a real run, because they
consume the same current-Jira facts that are never fetched. Delivering updates without
them would trade a duplication defect for a regression defect.

**Independent Test**: Advance a mirrored ticket in Jira, re-run reconcile, and assert a
named drift warning identifying the ticket and the divergent field, with no silent
backward transition.

**Acceptance Scenarios**:

1. **Given** a mirrored ticket advanced beyond the phase inferred from disk, **When**
   reconcile runs, **Then** the run emits a named drift warning identifying the ticket
   and does not silently regress it.
2. **Given** a mirrored ticket carrying Jira's Flagged marker, **When** reconcile runs,
   **Then** its transition is withheld, the flag is surfaced in the summary, and the
   bridge neither sets nor removes the flag.
3. **Given** a run in hook context where the recognition step fails, **When** the host
   spec-kit command completes, **Then** the host command still succeeds and the failure
   is surfaced as a single actionable warning.

---

### Edge Cases

- **A recognised ticket was deleted in Jira** — the specification is the source of
  truth: the story keeps its identifier, is mirrored again as a new ticket, and the run
  summary states that a previously mirrored ticket no longer exists.
- **A ticket carries another specification's identity** — it is never adopted or
  written to; the run reports the conflict naming both the ticket and the claiming
  specification, exactly as the mentioned-ticket flow already does.
- **Two tickets claim the same user story identifier** — the run fails closed for that
  story: zero writes, a named warning identifying both tickets, and a human resolves it.
- **A user story is duplicated by copy-paste, carrying its identifier with it** — two
  stories claiming one identifier is a fail-closed conflict for both, named in the
  summary; the bridge never guesses which story is the original.
- **A recorded identifier is edited by hand** — the ticket the marker line still names is
  read, its stamped identifier matches no story, and it is surfaced as an orphan and left
  untouched. The story itself fails closed until a human resolves it; the bridge does not
  create a replacement ticket, because guessing is what produces duplicates.
- **A whole marker line is deleted by hand** — the story is treated as new: it receives a
  fresh identifier and a new ticket. The ticket left behind is named by no line of the
  specification, so the run cannot see it: it is neither written to nor deleted, and it
  is not surfaced.
- **A user story is removed from the specification** — its marker line goes with it, so
  its ticket is likewise invisible to the run: untouched, never deleted, not surfaced.
- **A user story is retitled, reordered, or rewritten** — its identifier is unchanged,
  so its ticket is recognised and updated, never duplicated.
- **The specification file cannot be written** (read-only, permission denied, no space)
  — the run fails closed before creating anything in Jira: creating a ticket whose
  identifier could not be recorded is exactly what produces a duplicate on the next run.
- **A run interrupted between creating a ticket and finishing** — the next run
  recognises whatever was created and creates no duplicate.
- **The specification has no user story section at all** — the single implicit story
  receives an identifier and is recognised on re-run like any other.
- **Jira has not yet indexed a ticket created moments earlier** — a run that cannot
  positively confirm the absence of an existing ticket does not create one; it fails
  closed rather than risking a duplicate.
- **The specification is re-routed to a different Jira project** — tickets in the
  former project are not recognised, not moved, and not deleted; the run reports the
  re-routing and mirrors into the new project.
- **A run that mirrors nothing** — an inert run (no active feature, disabled event,
  repository not yet bound) performs no recognition read, writes no identifier, and
  reports nothing new.

## Requirements *(mandatory)*

### Functional Requirements

**Recognition before planning (US1)**

- **FR-001**: Before planning any write, a reconcile run MUST determine which Jira
  tickets already mirror the user stories of the specification being reconciled, and
  MUST plan an update — never a creation — for every story so recognised.
- **FR-002**: Recognition MUST key exclusively on the bridge's own stable identity
  marker. It MUST NOT key on a ticket's summary, title, description, folder path, or
  any other operator-editable value.
- **FR-003**: Every ticket a reconcile run creates MUST carry the bridge's identity
  marker before the run reports success, so that the immediately following run
  recognises it. A created ticket left unmarked is a failed run, not a partial success.
- **FR-004**: If recognition cannot complete reliably — rejected credentials,
  unreachable Jira, a failed read, exhausted retries — the run MUST perform zero writes
  for the affected specification and MUST exit with the documented code for that cause.
  Treating an inconclusive recognition as "no existing ticket" is forbidden: it is the
  behaviour that produces duplicates.
- **FR-005**: The identity marker MUST record enough to answer "which repository, which
  specification, and which user story does this ticket mirror?", and the marker written
  by both implementations MUST be byte-identical for identical inputs.
- **FR-006**: One recognised ticket MUST be bound to one user story by a **durable
  identifier the bridge assigns to that story once**, records in the specification file
  beside the story, and stamps into the ticket's identity marker at creation. Binding
  MUST use that identifier alone — never the story's position in the file, its title, or
  any other text a person may edit — so that reordering, inserting, retitling, or
  rewriting user stories never causes two stories to exchange their tickets.

**The durable story identifier (US1, US3)**

- **FR-007**: The identifier MUST be assigned by the bridge and MUST be derived from
  neither the story's position nor any of its text, so that no edit to the specification
  can change it. Once assigned, it is never reassigned or recomputed.
- **FR-008**: The identifier MUST be recorded in the specification file, beside the user
  story it names, in a form a human reader can recognise and associate with that story
  without consulting the documentation (Constitution XVI). Being part of the
  specification, it is committed, so it reaches every clone and every colleague.
- **FR-009**: Recording an identifier MUST preserve every other byte of the
  specification file exactly — surrounding text, blank lines, trailing whitespace, and
  the file's dominant line-ending convention — and MUST be idempotent: a run over a
  specification whose identifiers are already recorded rewrites nothing and reports no
  change.
- **FR-010**: A user story carrying no recorded identifier MUST be treated as new: the
  bridge assigns one, records it, and mirrors the story as a new ticket. Among the
  tickets a run reads — those a marker line in the specification still names — one whose
  stamped identifier matches no story of the specification MUST be surfaced as an orphan
  and MUST NOT be written to or deleted. A ticket no marker line names is outside the
  run's reach and is covered under Out of Scope.
- **FR-011**: The identifier recorded in the specification and the identifier stamped on
  the ticket MUST agree. A disagreement, two tickets stamped with one identifier, or two
  stories carrying one identifier MUST each fail closed for the story concerned — zero
  writes — naming both conflicting values so a human can resolve it.
- **FR-012**: A run interrupted at any point MUST NOT cause the next run to create a
  duplicate. In particular, a ticket MUST NOT be created for a story whose identifier
  could not first be recorded in the specification file, and a created ticket MUST be
  recognisable by the next run even if the run that created it did not finish.

**Zero churn on an unchanged corpus (US2)**

- **FR-013**: A reconcile run MUST compare each recognised ticket's current state
  against the state the run would write, and MUST drop any write whose effect would be
  no change. A re-run on an unchanged corpus produces zero writes of any kind (001
  FR-030).
- **FR-014**: The churn comparison for a ticket of human origin MUST be computed on the
  managed section alone, so that human prose above the managed panel neither counts as
  a change nor is ever rewritten (001 FR-038/FR-039).
- **FR-015**: A partially changed specification MUST produce writes only for the stories
  that changed; unchanged stories receive no write in the same run.
- **FR-016**: The `--dry-run` report MUST list exactly the actions the real run
  performs, in every scenario of this specification, including recognition-driven
  updates, identifiers that would be assigned, and dropped no-op writes. A dry run MUST
  write neither Jira nor the specification file (001 FR-033).

**Durability of recognition (US3)**

- **FR-017**: Recognition MUST succeed from any working copy of the repository,
  including one that has never run the bridge before, without depending on state
  produced by a previous local run.
- **FR-018**: Recognition MUST survive a rename of the specification folder: the tickets
  are resolved from the stored marker and the recorded identifier, not from the path
  (001 edge case).
- **FR-019**: Recognition MUST be scoped to the Jira project the specification routes
  to, so that two specifications mirrored into different projects never recognise each
  other's tickets.

**Safety of the updates recognition unlocks (US4)**

- **FR-020**: A run that updates recognised tickets MUST evaluate them against the
  existing drift, Flagged, and blocker rules (001 FR-031, FR-034 – FR-037), using the
  ticket state read during recognition, and MUST NOT silently overwrite or regress a
  ticket that diverges.
- **FR-021**: A ticket whose identity marker names a different specification MUST NOT be
  written to, adopted, or counted as recognised; the conflict MUST be reported naming
  both the ticket and the claiming specification.
- **FR-022**: In hook context, no failure introduced by recognition or by identifier
  recording may fail the host spec-kit command; at worst the run emits a single
  actionable warning and returns success to the host (001 FR-046, Constitution III).

**Reporting (US1, US2)**

- **FR-023**: The run summary MUST let a reader tell recognition apart from creation: it
  MUST report how many stories were recognised as already mirrored, how many identifiers
  were newly assigned, how many tickets were created, and how many were updated, with
  the skipped-as-unchanged tickets visible rather than silently absent.
- **FR-024**: Every message this feature adds MUST name the ticket, story, or
  specification involved and a copy-pasteable remediation (Constitution XVI).
- **FR-025**: The regression this feature fixes MUST be covered by a test that
  reproduces the duplicate-creation behaviour and fails before the fix, on both
  implementations, and by a live double-run assertion against a real Jira instance
  (Constitution II, XIII).

### Key Entities

- **Durable story identifier**: the value the bridge assigns to a user story once and
  never recomputes, recorded in the specification file beside that story and stamped
  onto the ticket mirroring it. It is what makes a story recognisable after it is
  retitled, reordered, or rewritten.
- **Identity marker**: the bridge's own record, stored on the Jira ticket itself, of
  which repository, which specification, and which user story identifier the ticket
  mirrors, plus whether the bridge created the ticket or adopted a human-created one.
  It is the only thing recognition is allowed to trust on the Jira side.
- **Story-to-ticket binding**: the run-time association between one user story and the
  one Jira ticket that mirrors it, established by matching the identifier recorded in
  the specification against the identifier stamped on the ticket. It is derived afresh
  on every run, never assumed from a previous run.
- **Recognised ticket state**: the ticket facts a run reads while recognising it —
  current field values, status and its classification, Flagged marker, open blockers —
  and which the churn comparison and the drift rules both consume.
- **Run summary counts**: the recognised / assigned / created / updated / skipped /
  warnings / errors tallies a human and CI read to confirm that an unchanged re-run did
  nothing.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | The identifier lives in the specification file, which makes the filesystem authoritative about what exists — the mirror is derived from it, not from Jira-side state. No deletion is introduced: a removed story's ticket is left intact — surfaced as an orphan when a marker line still names it, and simply untouched when none does (FR-010, Out of Scope) — and a deleted ticket is re-mirrored from disk. FR-020 keeps every overwrite behind the existing named drift warning; FR-021 keeps a ticket claimed by another specification untouched. The bridge writes only its own identifier into the specification and preserves every other byte (FR-009), exactly as the managed README block already treats a user-owned file. |
| II | Zero-Churn Idempotency | This feature exists to make the principle true in practice. FR-013 – FR-015 require zero writes on an unchanged corpus and FR-009 extends that to the specification file itself. FR-006/FR-007 satisfy the principle's identity rule literally: binding keys on a bridge-assigned identifier and an entity-property marker, never on a title, summary, or any operator-editable display name. FR-025 requires the double-run assertion against a real Jira instance, as the principle demands mocks alone are not sufficient. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-004 makes an inconclusive recognition a zero-write failure with the documented escalating code, explicitly forbidding the "assume nothing exists" fallback; FR-012 refuses to create a ticket whose identifier could not be recorded; FR-011 fails closed on every identifier conflict; FR-022 keeps all of it non-blocking for the host spec-kit command. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | No new credential surface: recognition reads Jira through the bridge's existing authenticated transport. The identifier written into the tracked specification file is a bridge-assigned value carrying no token, no site URL, no account identifier and no Jira coordinate, and the pre-write privacy guard still runs before every write. |
| V | Separation of Team Config / Local Binding / Secrets | No ticket reference, site coordinate, or account identifier enters the committable team config. FR-017 forbids recognition from depending on machine-local state, so no new local layer becomes load-bearing; the identifier belongs to the specification, not to any configuration layer. |
| VI | macOS / Linux / Windows Portability | FR-005 requires byte-identical markers from both implementations and FR-009 requires the specification write to honour the file's dominant line-ending convention, the same CRLF-safety rule 001 already imposes on the README block. FR-025 requires the regression coverage on both ports, and the behaviour joins the shared conformance suite, so a divergence fails CI. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Recognition keys on the bridge's own marker and identifier (FR-002, FR-006), not on issue-type names, status names, or field ids. FR-020 reuses the configured, discovered mappings the drift rules already consume. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Reading Jira for recognition and stamping the marker are sink responsibilities; assigning the identifier, recording it in the specification, and deciding churn are engine concerns over neutral data. The engine gains no Jira knowledge and the two continue to communicate only through the validated neutral document. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unchanged and still mandatory: every write this feature plans passes the same pre-write BLOCK/WARN guard, and no write can bypass it. |
| X | Self-Healing Automatic Mirror | Unchanged: hook registration, hook-health reporting, and the permanence of an operator-disabled hook are untouched. FR-022 preserves the non-blocking contract the automatic mirror depends on. |
| XI | Universal Dry-Run and Auditability | FR-016 requires the dry-run report to equal the real action set in every scenario here and forbids a dry run from touching Jira or the specification file; FR-023 requires the summary to distinguish recognised, assigned, created, updated, and skipped. No destructive operation is added. |
| XII | Quality and Catalog Publication | The fix ships with a CHANGELOG entry and a version bump, is gated by the three-OS matrix and lint, and is dogfooded against a real Jira instance — the same consuming-project scenario that reported the defect. |
| XIII | TDD With a Minimum 80% Coverage | FR-025 requires the failing regression test first, on both implementations, before the fix. Recognition, idempotency, and the fail-closed path are named critical paths in the principle and are targeted near 100%. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | The feature adds one recognition step and one identifier to a flow that already plans, guards, and applies writes, and reuses the existing marker, churn comparison, drift rules, and managed-block file-writing discipline. It introduces no new abstraction layer, no cache tier, and no new configuration surface. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Every requirement here answers the reported defect or a constitutional obligation it triggers. Nothing is added for anticipated needs; the deliberate exclusions are listed under Out of Scope rather than built as dormant code. |
| XVI | Human Readable — Readable by a Human Above All | FR-008 requires the identifier to be recognisable in the specification without consulting the documentation; FR-024 requires every added message to name the story or ticket and a copy-pasteable remedy; FR-023 keeps the default summary readable prose in which a human can see that an unchanged re-run did nothing. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Reconciling an unchanged specification twice leaves exactly one ticket per
  user story — the second run reports 0 created and 0 updated and issues no write.
- **SC-002**: Ten consecutive reconcile runs over an unchanged specification produce the
  same ticket count as one run: zero duplicates across all ten.
- **SC-003**: 100% of tickets created by a run are recognised by the next run, including
  a run started from a fresh clone that has never mirrored anything.
- **SC-004**: When one user story out of ten changes, exactly one ticket is written and
  the other nine receive no write.
- **SC-005**: Reordering, inserting, retitling, and rewriting user stories produce 0 new
  tickets for the stories that already had one, and 0 tickets bound to the wrong story.
- **SC-006**: A re-run over a specification whose identifiers are already recorded leaves
  the specification file byte-identical, including line endings.
- **SC-007**: Every run in which recognition cannot complete reliably, or in which the
  specification file cannot be written, creates zero tickets and reports a named cause
  with a remediation — 0 duplicates under failure, in 100% of the injected-fault cases
  (rejected credentials, unreachable service, failed read, exhausted retries, read-only
  specification file, interruption mid-run).
- **SC-008**: Renaming a specification folder and re-running produces 0 new tickets.
- **SC-009**: The dry-run report and the real run's actions are identical in 100% of the
  scenarios above, and 0 dry runs modify the specification file.
- **SC-010**: A bridge failure introduced anywhere in this feature never changes the
  host spec-kit command's outcome: 100% of fault-injected hook runs leave the host
  command successful.
- **SC-011**: The duplicate-creation defect is reproduced by a test that fails before
  the fix and passes after it, on both implementations, and the double-run assertion
  passes against a real Jira instance.

## Assumptions

- The reported defect is the one diagnosed here — a missing recognition step, unmarked
  created tickets, and a marker that cannot tell one story's ticket from another's — and
  not a misconfiguration of the consuming repository. The regression test of FR-025 is
  what proves this.
- The specification file is writable by the developer running the command and is
  committed to version control. That is what carries the identifiers to colleagues and
  fresh clones (FR-017); a repository that does not commit its specifications is outside
  the workflow the extension mirrors.
- Recognition is a read against Jira on every run. The specification file says which
  stories exist and what identifies them; Jira's stamped marker says which ticket already
  mirrors which identifier. No per-machine record is trusted, because one re-introduces
  duplication for every other clone (FR-017).
- The existing identity marker, the churn comparison, the drift rules, the managed panel,
  and the byte-preserving block-writing discipline built for the README are reused as
  they stand; this feature supplies the facts they were designed to consume rather than
  replacing them.
- One Jira ticket mirrors one user story, as the current mirror already assumes. Epics
  and sub-tasks are governed by the epic strategy already configured and are not
  redefined here.
- A ticket a human created and the team deliberately adopted keeps its recorded human
  origin through recognition; adoption itself remains opt-in and unchanged.
- The consuming repository is already bound to a Jira project. An unbound repository
  keeps producing the existing "not yet configured" notice and mirrors nothing.

## Out of Scope

- Deleting, closing, or archiving the ticket of a user story removed from a
  specification — reconcile never deletes.
- Detecting a ticket that no marker line in the specification names. Recognition reads
  only by recorded key, so a removed story, a deleted marker line, or a regenerated
  `spec.md` takes the ticket's key with it. Such a ticket is never written to and never
  deleted, but the run cannot report its existence either. Finding these would require
  the search index this feature deliberately does not use, and is a separate feature.
- Moving tickets between projects when a specification's routing changes.
- Migrating or back-filling identifiers and markers onto tickets created by earlier
  versions of the extension before this fix; those tickets are unrecognisable by design,
  and reconciling their specification mirrors it afresh. A one-off adoption path for
  them, if wanted, is a separate feature.
- Recording identifiers in artifacts other than the specification file (`plan.md`,
  `tasks.md`); this feature covers the user stories reconcile mirrors today.
- Any change to the two controlled exceptions of Constitution I — the operator-mentioned
  issue key flow and label-based adoption — beyond reusing their existing conflict
  reporting.
- The guarded destructive re-mode of Constitution XI.
- Performance optimisation of the recognition read (batching, caching, incremental
  lookups) beyond what SC-001 – SC-011 require.
