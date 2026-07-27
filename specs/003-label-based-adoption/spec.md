# Feature Specification: Label-Based Adoption of Pre-Existing Jira Tickets

**Feature Branch**: `003-label-based-adoption`

**Created**: 2026-07-27

**Status**: Draft

**Input**: User description: "Label-based adoption of pre-existing Jira tickets — let an operator bind an existing, unmarked Jira hierarchy to the repository's existing spec artifacts, once, deliberately, and without overwriting a single character a human wrote, so that every subsequent run is an ordinary zero-churn reconcile."

## Overview

The bridge works end to end only for greenfield work today: the feature ceremony
creates the ticket, the lifecycle hooks reconcile it, and every ticket the bridge
owns carries a per-issue identity marker recording origin `bridge_created`. The
two existing adoption paths are both single-ticket and key-driven — the feature
ceremony validates one operator-mentioned key before naming, and the mention
command adopts exactly one human-authored ticket whose key the developer types,
stamping the marker with origin `human`.

A team installing the bridge on an existing repository has none of that: the
Product Owner already created an Epic and a set of Stories in Jira, nobody knows
the keys, and the identity marker — an entity property — cannot be searched.
Today the bridge either duplicates that backlog or refuses.

Constitution Principle I already reserves label-based adoption as the second
controlled exception to "the filesystem is the source of truth", and feature 001
listed it as out of scope to be built later. This feature builds it: an operator
declares an adoption label in the committable team configuration, labels the
existing tickets so each label **names** the spec it belongs to, and runs a
deliberate, confirmed, one-time adoption that stamps identity and writes nothing
else. From then on every run is an ordinary zero-churn reconcile.

### Target Users

- **Operator / tech lead** — installs the bridge on a repository that already has
  spec artifacts and an already-populated Jira backlog, and needs the two bound
  without duplication and without hand-editing tickets.
- **Product Owner** — wrote the descriptions in Jira by hand and must be certain
  that not one character of them is rewritten by the bridge, ever.
- **Developer** — after adoption, works exactly as on a greenfield repository:
  lifecycle hooks reconcile, nothing duplicates, nothing churns.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Adopt a hierarchy discovered by label (Priority: P1)

An operator enables adoption in the committable team configuration, declares the
adoption label there, and places a label naming the target spec on each existing
Jira ticket. Running adoption then lists every accessible ticket carrying one of
those labels in the projects the specs route to, prints the resulting plan — one
line per spec folder with the candidate it would bind — and writes nothing until
the operator confirms. On confirmation the only write performed is the identity
marker, with origin `human`, one stamp per adopted ticket. Nothing is created,
nothing is deleted, no description, summary, status, or label is touched.

**Why this priority**: This is the feature. Without it, a repository with an
existing backlog cannot use the bridge at all — reconcile either duplicates the
backlog or refuses.

**Independent Test**: Can be fully tested with a mocked Jira double holding an
Epic and two Stories carrying spec-naming labels, and three spec folders on disk:
run adoption, assert the printed plan lists three bindings before any write,
confirm, and assert exactly three identity writes and zero writes of every other
kind.

**Acceptance Scenarios**:

1. **Given** adoption enabled in the committable configuration, a declared
   adoption label, and three tickets each carrying a label naming a distinct spec
   folder, **When** the operator runs adoption, **Then** the run first prints a
   plan listing each spec folder with its candidate issue key and the reason
   (label match), having performed zero writes.
2. **Given** that plan, **When** the operator confirms, **Then** the bridge
   stamps the identity marker with origin `human` on each of the three tickets
   and performs no create, delete, transition, comment, link, relabel,
   description, or summary write.
3. **Given** the same corpus, **When** the operator declines the confirmation,
   **Then** the run ends with zero writes and reports that adoption was
   cancelled.
4. **Given** adoption left disabled in the committable configuration (the
   default), **When** the operator runs adoption on a fully labelled backlog,
   **Then** the run refuses with a configuration error naming the configuration
   key to enable and performs zero writes.
5. **Given** a ticket carrying a bare adoption label that names no spec (the
   prefix alone, or an unknown spec folder), **When** adoption runs, **Then**
   that ticket is never adopted and the bridge never guesses which spec it
   belongs to.

---

### User Story 2 - Adoption is fail-closed on ambiguity (Priority: P1)

A spec folder that matches zero candidates, more than one candidate, or a
candidate already claimed by another spec stops the adoption of **that binding**
with a message naming the spec folder, the candidate issue keys involved, and a
copy-pasteable remediation. Ambiguity is never resolved by guessing, by title
similarity, by recency, or by taking the first result — the same posture as the
three-valued project-style detection of feature 002, where an ambiguous signal
fails closed with zero writes. Bindings that are unambiguous still apply; the run
reports the refusals and exits with the configuration-refusal code.

**Why this priority**: Adoption writes identity onto tickets a human owns. A
wrong binding silently attaches a Product Owner's ticket to the wrong spec and is
expensive to unpick — the bridge must refuse rather than guess.

**Independent Test**: Can be fully tested with one fixture per refusal class
(zero candidates, two candidates, candidate already claimed, candidate in the
wrong project, child bound without its parent) plus one valid binding: assert the
valid binding applies, each refused binding leaves zero writes, each message
names the spec and the keys, and the run exits with the configuration-refusal
code.

**Acceptance Scenarios**:

1. **Given** a spec folder whose adoption label appears on no accessible ticket,
   **When** adoption runs, **Then** that binding is refused with a message naming
   the spec folder, the exact label searched for, and the remediation (apply the
   label, or pin the key explicitly), with zero writes for that binding.
2. **Given** two accessible tickets carrying the same spec-naming label, **When**
   adoption runs, **Then** the binding is refused with a message naming the spec
   folder and both issue keys, and neither ticket is written to.
3. **Given** a candidate already carrying another spec's identity marker, **When**
   adoption runs, **Then** the binding is refused with a message naming the spec
   folder, the candidate, and the spec that already claims it, with zero writes.
4. **Given** a mix of valid and refused bindings, **When** the operator confirms,
   **Then** only the valid bindings are stamped, every refusal is listed in the
   summary with its reason and remediation, and the run exits with the
   configuration-refusal code.
5. **Given** two candidates whose titles closely match the spec's title, **When**
   adoption runs, **Then** the tie is not broken by similarity, order, or
   recency — the binding is refused.
6. **Given** an unreliable read while discovering candidates (network failure,
   404, authentication failure, exhausted rate-limit retries), **When** adoption
   runs, **Then** the entire run aborts before any write with the corresponding
   documented exit code and zero writes overall.

---

### User Story 3 - Adopt without destroying human content (Priority: P1)

Every adopted ticket is recorded with origin `human`, permanently. The first
reconcile after adoption therefore treats its description as human-authored: the
managed panel is spliced in as an addition below the existing prose, every
human-written line survives byte-for-byte, and the run reports which tickets were
adopted and what was added to each. Re-running adoption on a corpus that is
already adopted produces zero writes of every kind.

**Why this priority**: This is the promise that makes adoption acceptable to the
Product Owner who wrote the tickets. Without a byte-preservation guarantee, no
team enables adoption on a live backlog.

**Independent Test**: Capture each adopted ticket's description before adoption;
run adoption, then reconcile; assert every pre-existing byte is present unchanged
outside the managed panel, that the panel was added below it, and that a second
reconcile writes nothing. Re-run adoption and assert zero writes.

**Acceptance Scenarios**:

1. **Given** an adopted ticket with a hand-written description, **When** the
   first reconcile after adoption runs, **Then** the managed panel is added and
   every pre-existing line is preserved verbatim above it.
2. **Given** that same ticket, **When** the reconcile immediately following the
   first one runs on an unchanged corpus, **Then** it performs zero writes of
   every kind.
3. **Given** an adopted ticket, **When** any later run evaluates its description
   for idempotency, **Then** the diff is computed on the managed panel alone and
   the human prose above it is never part of any write payload.
4. **Given** an already-adopted corpus, **When** adoption is run again, **Then**
   it performs zero writes of every kind and exits successfully.
5. **Given** an adopted ticket, **When** any destructive operation is later
   attempted against it, **Then** it is never hard-deleted — the most that may
   happen is detaching the bridge identity, leaving the ticket, its comments, and
   its links intact.

---

### User Story 4 - Explicit binding override (Priority: P2)

When label discovery is ambiguous, or the label was never applied to a ticket,
the operator can pin a spec folder to a specific issue key on the command line.
The pinned binding replaces label discovery for that spec folder and is validated
exactly like a discovered candidate — same project check, same claim check, same
hierarchy check, same refusals — so a partially labelled backlog is adoptable
without hand-editing tickets in Jira.

**Why this priority**: It removes the only remaining reason to hand-edit Jira
before adopting, and it is the documented remediation printed by every ambiguity
refusal of US2. It depends on the discovery and validation machinery of US1/US2.

**Independent Test**: Run adoption on a corpus where one spec has two candidates
and another has none, pinning both spec folders to explicit keys; assert both
bind, the summary records the reason as an explicit binding, and an explicit
binding to a claimed or wrong-project ticket is refused exactly as a discovered
candidate would be.

**Acceptance Scenarios**:

1. **Given** a spec folder with two labelled candidates, **When** the operator
   pins that spec folder to one of the two keys, **Then** the binding applies and
   the summary records the reason as an explicit binding.
2. **Given** a spec folder whose ticket carries no adoption label, **When** the
   operator pins it to that ticket's key, **Then** the binding applies without
   any label being added to the ticket.
3. **Given** an explicit binding to a ticket already claimed by another spec, or
   to a ticket in a project the spec does not route to, **When** adoption runs,
   **Then** the binding is refused with the same message and exit code as the
   equivalent discovered candidate.
4. **Given** an explicit binding naming a spec folder that does not exist on
   disk, **When** adoption runs, **Then** the run stops as a usage error naming
   the unknown folder, with zero writes.
5. **Given** an explicit binding for a spec folder that also has exactly one
   labelled candidate pointing elsewhere, **When** adoption runs, **Then** the
   explicit binding wins, and the plan states both the pinned key and the
   discovered key that was overridden.

---

### User Story 5 - Adoption dry-run and audit trail (Priority: P2)

Adoption has a dry-run twin whose report predicts the real run exactly. The real
run's summary lists every applied binding as spec folder → issue key with the
reason it was chosen (label match or explicit binding), and every binding that
was refused with its reason and remediation, so an adoption can be reviewed after
the fact and reproduced.

**Why this priority**: The constitution requires a dry-run twin and a structured
summary for every write operation. It is P2 rather than P1 only because the plan
printed before confirmation (US1) already gives the operator a preview; the
dry-run twin makes that preview scriptable and auditable.

**Independent Test**: Run adoption with the dry-run flag and then for real
against the same state; assert the two action sets are identical, that the
dry-run performed zero writes, and that both summaries validate against the
run-summary schema in prose and in the opt-in machine-readable form.

**Acceptance Scenarios**:

1. **Given** any adoption scenario, **When** the dry-run twin runs, **Then** its
   reported action set is identical to the real run's on the same state, and it
   performs zero writes.
2. **Given** a completed adoption, **When** the summary is read, **Then** it
   lists every applied binding as spec folder → issue key with the reason
   (label match or explicit binding) and every refused binding with its reason
   and remediation.
3. **Given** any adoption run, **When** the machine-readable output form is
   requested, **Then** the summary conforms to the run-summary schema and is
   byte-identical between the two ports for identical inputs; the default output
   remains human-readable prose.
4. **Given** any adoption output, **When** it is inspected, **Then** it contains
   no credential and no site host — issue keys, project keys, and spec folder
   names only.

---

### User Story 6 - Partial and resumable adoption (Priority: P3)

An operator can restrict adoption to a subset of spec folders, leaving the rest
untouched and reported as out of scope. An adoption interrupted after N bindings
can simply be re-run: tickets already carrying this spec's identity are
recognised and skipped rather than re-stamped, so the total number of writes over
one interrupted plus one completing run equals one stamp per adopted ticket.

**Why this priority**: A convenience and resilience refinement over the P1 flow.
Adoption is already re-runnable by the zero-write rule of US3; this story makes
partial scoping explicit and proves resumability.

**Independent Test**: Adopt a two-spec subset of a five-spec repository and
assert the other three are untouched and reported as out of scope; then interrupt
a run after the first stamp, re-run it, and assert the already-stamped ticket is
skipped and the total stamp count per ticket is exactly one.

**Acceptance Scenarios**:

1. **Given** a repository with five spec folders, **When** the operator scopes
   adoption to two of them, **Then** only those two are discovered and bound, and
   the other three are reported as out of scope with zero reads or writes against
   their tickets.
2. **Given** an adoption interrupted after some bindings were stamped, **When**
   the operator re-runs the same adoption, **Then** the already-stamped tickets
   are recognised and skipped, the remaining bindings are applied, and no ticket
   is stamped twice.
3. **Given** a scope restricted to a spec folder that does not exist, **When**
   adoption runs, **Then** the run stops as a usage error naming the unknown
   folder, with zero writes.

### Edge Cases

- **Adoption label declared but empty, or containing whitespace or characters
  Jira rejects in a label** — refused at configuration validation with a located
  error; nothing is searched and nothing is written.
- **A candidate already carries this spec's own identity with origin `human`** —
  recognised as already adopted, skipped, counted as skipped, not an error (the
  resumability path of US6).
- **A candidate carries this spec's identity with origin `bridge_created`** — the
  spec already owns a bridge-created ticket, so Principle I's collision-free
  condition fails: the binding is refused, naming both tickets, with zero writes.
- **The parent is labelled but the children are not** — the parent is adopted;
  the missing children are created by the ordinary reconcile as bridge-created
  tickets under it, which destroys nothing.
- **A child is labelled but its spec's feature-level ticket is neither already
  bound nor bound in the same run** — refused, because the following reconcile
  would otherwise create a second parent and the adopted child would hang under
  the wrong one.
- **A labelled candidate whose Jira parent is not the spec's bound feature-level
  ticket** — refused; adoption never re-parents a human-created ticket.
- **The spec's routed project and the candidate's project disagree** — refused,
  naming both projects; adoption never adopts across the routing boundary and
  never migrates a ticket.
- **Two spec folders share the same numbering component while a short-form label
  names only that number** — ambiguous; refused, naming both folders.
- **The operator's credentials cannot see a candidate's project** — the candidate
  is simply not accessible and the spec reports zero candidates, never a partial
  or unauthorised read.
- **Rate limiting mid-discovery** — bounded retry with backoff; exhaustion aborts
  the whole run before any write, never a partially applied plan.
- **The tracked tree leaks a known coordinate** — the pre-write guard blocks with
  its dedicated exit code and zero writes, exactly as for any other write
  operation; adoption is not exempt.
- **A run interrupted between the plan and the confirmation** — nothing was
  written, so the next run recomputes the same plan.
- **Adoption run on a repository with no spec folders, or with adoption enabled
  and no ticket labelled** — completes successfully with zero bindings, zero
  writes, and a summary stating that nothing was found.

## Requirements *(mandatory)*

### Functional Requirements

**Enablement, label declaration, and routing (US1)**

- **FR-001**: Adoption MUST be opt-in in the committable team configuration and
  disabled by default. With adoption disabled, a labelled ticket MUST NEVER be
  written to; the adoption run MUST refuse with the configuration-refusal exit
  code, name the configuration key that enables it, and perform zero writes.
- **FR-002**: The adoption label MUST be declared in the committable team
  configuration as a single label prefix, self-documented in the configuration
  template. Its declared value MUST be validated (non-empty, no whitespace of
  any kind, and a total length within Jira's 255-character label limit once the
  longest implied suffix is appended) and refused with a located error otherwise.
- **FR-003**: An adoption label MUST name the target spec. The bridge MUST
  recognise exactly three label forms: `<prefix><spec-folder-name>` binding the
  spec's feature-level ticket, `<prefix><spec-folder-name>:us<N>` binding the
  ticket of user story N of that spec, and the short form `<prefix><NNN>` (the
  spec folder's numbering component alone) binding the feature-level ticket of
  the single spec folder carrying that number. A label carrying the prefix alone,
  or naming a spec folder that does not exist on disk, MUST NEVER trigger
  adoption — the bridge MUST NEVER infer which spec an unnamed ticket belongs to.
- **FR-004**: Candidate discovery for a spec folder MUST be scoped to the Jira
  project that spec routes to under the existing routing rules (folder prefix,
  spec-declared label, or configured default — including the folder prefix
  contributed by a team catalogue entry). A ticket carrying a valid adoption
  label in any other project MUST NOT be adopted by that spec.
- **FR-005**: When the spec's routed project and a candidate's project disagree —
  reachable only through an explicit binding (FR-020) — the binding MUST be
  refused with the configuration-refusal exit code, naming the spec folder, both
  project keys, and the remediation. Adoption MUST NEVER migrate a ticket between
  projects.

**Plan, confirmation, and the single write (US1)**

- **FR-006**: An adoption run MUST be strictly two-phase: a read-only discovery
  phase that produces a plan, and an apply phase that runs only after explicit
  operator confirmation. The plan MUST be presented before any write and MUST
  list, per spec folder, the candidate issue key and the reason it was chosen, or
  the refusal and its reason. Declining the confirmation MUST end the run with
  zero writes. A pre-confirmation flag MUST exist so the confirmation can be
  given non-interactively for scripted and conformance runs; when that flag is
  absent and no terminal is available, the run MUST behave exactly as its
  dry-run twin and name the flag as the way to proceed.
- **FR-007**: On confirmation, the only write adoption performs MUST be the
  identity marker stamp, one per adopted ticket, recording origin `human`.
  Adoption MUST NOT create, delete, transition, comment on, link, or relabel any
  ticket, and MUST NOT modify any description, summary, or any other field.
- **FR-008**: Any unreliable read during the discovery phase (network error, 404,
  authentication failure, exhausted rate-limit retries) MUST abort the whole run
  before any write with the corresponding documented exit code and leave zero
  writes.

**Fail-closed ambiguity (US2)**

- **FR-009**: A spec folder matching zero accessible candidates MUST have its
  binding refused with a message naming the spec folder, the exact label searched
  for, and a copy-pasteable remediation; zero writes for that binding.
- **FR-010**: A spec folder matching more than one accessible candidate MUST have
  its binding refused with a message naming the spec folder and every candidate
  issue key; zero writes for that binding.
- **FR-011**: A candidate already carrying another spec's identity marker, or a
  spec that already owns a bridge-created ticket, MUST have its binding refused
  with a message naming the spec folder and both tickets; zero writes for that
  binding.
- **FR-012**: Ambiguity MUST NEVER be resolved by title or summary similarity, by
  result order, by recency, by issue type, or by any other heuristic. No fallback
  selection strategy may exist in any code path.
- **FR-013**: Refusals under FR-005, FR-009, FR-010, FR-011, FR-014, and FR-015,
  together with the ambiguous short-form label refusal (two spec folders in scope
  sharing the numbering component a short-form label names),
  MUST be per-binding: unambiguous bindings in the same run still apply, each
  refused binding leaves zero writes, and the run exits with the
  configuration-refusal code. Whole-run aborts (usage, unreliable read,
  authentication, prerequisite, privacy block) MUST leave zero writes overall.
  When more than one failure class occurs in a run, the highest applicable exit
  code MUST be returned.
- **FR-014**: Each ticket MUST be adopted independently through its own label;
  adoption MUST NEVER be inherited from a parent to a child or from a child to a
  parent. A user-story binding whose spec's feature-level ticket is neither
  already bound nor bound in the same run MUST be refused. A labelled
  feature-level ticket whose children are unlabelled MUST be adopted, leaving the
  ordinary reconcile to create the missing children as bridge-created tickets
  under it.
- **FR-015**: A candidate whose Jira parent is a ticket other than the spec's
  bound feature-level ticket MUST have its binding refused; adoption MUST NEVER
  re-parent an existing ticket.

**Human content preservation (US3)**

- **FR-016**: Every adopted ticket's identity marker MUST record origin `human`,
  and that origin MUST NEVER be rewritten by any later run. Every subsequent
  reconcile of that ticket MUST therefore treat its description as
  human-authored: content is written only inside the managed panel, every
  pre-existing human line is preserved byte-for-byte, and the description
  idempotency diff is computed on the managed panel alone.
- **FR-017**: An adopted ticket MUST be permanently excluded from hard deletion
  by any destructive operation; the most destructive action permitted on it is
  detaching the bridge identity, leaving the ticket, its comments, and its links
  intact.
- **FR-018**: The first reconcile after an adoption MUST report, per adopted
  ticket, that the ticket was adopted and what was added to it, and MUST add
  nothing outside the managed panel.
- **FR-019**: Re-running adoption on an already-adopted corpus MUST produce zero
  Jira writes of every kind (create, update, transition, comment, link, label,
  identity stamp) and exit successfully.

**Explicit binding override (US4)**

- **FR-020**: The operator MUST be able to pin a spec folder to a specific issue
  key from the command line, repeatably. A pinned binding MUST replace label
  discovery for that spec folder and MUST be validated exactly like a discovered
  candidate (routed-project match, claim check, hierarchy checks), producing the
  same refusals and the same exit codes.
- **FR-021**: A pinned binding naming a spec folder that does not exist on disk
  MUST stop the run as a usage error naming the unknown folder, with zero writes.
- **FR-022**: When a pinned binding and a discovered candidate disagree for the
  same spec folder, the pinned binding MUST win and the plan MUST state both the
  pinned key and the discovered key it overrode.

**Dry-run and audit trail (US5)**

- **FR-023**: Adoption MUST have a dry-run twin whose reported action set is
  identical to the real run's on the same state, and which performs zero writes.
- **FR-024**: The run summary MUST list every applied binding as spec folder →
  issue key with the reason it was chosen (label match or explicit binding), and
  every refused binding with its reason and its remediation. It MUST conform to
  the existing run-summary schema, be human-readable prose by default, and be
  available in the opt-in machine-readable form, byte-identical between ports for
  identical inputs.
- **FR-025**: No adoption output — plan, summary, warning, or error, at any
  verbosity — may contain a credential or a site host; issue keys, project keys,
  and spec folder names only.

**Partial and resumable adoption (US6)**

- **FR-026**: The operator MUST be able to restrict an adoption run to an
  explicit subset of spec folders, repeatably. Spec folders outside the scope
  MUST be reported as out of scope, with no read and no write against their
  tickets. A scope naming a spec folder that does not exist MUST stop the run as
  a usage error, with zero writes.
- **FR-027**: A ticket already carrying this spec's identity marker with origin
  `human` MUST be recognised as already adopted, skipped rather than re-stamped,
  and counted as skipped, so an interrupted adoption completes on re-run with
  exactly one stamp per adopted ticket.

**Safety, surface, and parity (all stories)**

- **FR-028**: The pre-write privacy guard MUST run before any adoption write,
  unchanged: a BLOCK-tier match produces zero writes and the dedicated privacy
  exit code. Adoption MUST NOT write any content fetched from Jira into the
  repository tree.
- **FR-029**: Adoption MUST be a dedicated command, reachable identically on both
  ports, and MUST NEVER be registered as, or fired by, a lifecycle hook — it
  requires operator confirmation and is a one-time deliberate transition, whereas
  hooks are automatic and non-blocking.
- **FR-030**: Adoption MUST reuse the existing exit-code ladder without inventing
  new codes: success including a zero-binding run (0); usage error — bad flag,
  unknown spec folder (1); fail-closed read (2); authentication failure (3);
  configuration/claim refusal — adoption disabled, invalid label declaration,
  every per-binding refusal (4); prerequisite failure (5); privacy block (9).
- **FR-031**: Every configuration key and command-line flag introduced by this
  feature MUST be traceable to a functional requirement above and MUST be
  exercised by at least one automated test; no unused key, flag, or schema field
  may ship.

### Non-Functional Requirements

- **NFR-1 (Twin-port parity)**: The adoption command MUST ship a Bash and a
  PowerShell implementation with identical observable behaviour — same plan, same
  action set, same exit codes, same summary content — proven by the shared,
  language-agnostic conformance corpus. A divergence is a failing test, not a
  documented quirk.
- **NFR-2 (No new runtime dependency)**: Adoption MUST introduce no runtime
  dependency beyond each port's already-declared prerequisites (Bash: bash, curl,
  jq, git; PowerShell: pwsh 7+, git).
- **NFR-3 (Credential security)**: Credential resolution and the token-exclusion
  rules are unchanged and apply to every request adoption makes; the token MUST
  NEVER appear in a process argument list, log, error, or trace at any verbosity.
- **NFR-4 (Observability)**: Every adoption run MUST produce the structured
  summary of FR-024 — prose by default, machine-readable on opt-in — including
  counts of adopted, skipped, and refused bindings.
- **NFR-5 (Testability)**: Adoption MUST be verifiable against the shared mocked
  Jira double, with fixtures covering label discovery (zero, one, several
  candidates), claimed candidates, hierarchy cases, both project styles, and the
  existing fault injections (authentication, network, 404, exhausted rate limit).
- **NFR-6 (Bounded discovery)**: Discovery MUST be bounded by the spec folders in
  scope — the bridge searches for the exact label values those spec folders imply
  rather than enumerating a backlog — and MUST paginate results so a large
  project cannot truncate a candidate list silently.

### Key Entities

- **Adoption label**: The operator-declared label prefix in the committable team
  configuration plus the spec-naming suffix carried by each ticket. The only
  discovery signal, and the only thing that binds a ticket to a spec folder.
- **Adoption plan**: The read-only result of the discovery phase — one entry per
  spec folder in scope holding the candidate key and the reason, or the refusal
  and its reason. Presented before any write; identical to the dry-run report.
- **Binding**: The applied association of one spec artifact (a spec's
  feature-level ticket, or one of its user stories) to one existing Jira issue
  key, with the reason it was chosen (label match or explicit binding).
- **Binding refusal**: A named, per-binding rejection carrying the spec folder,
  the candidate keys involved, the reason class (no candidate, several
  candidates, already claimed, wrong project, unbound parent, wrong parent), and
  a copy-pasteable remediation.
- **Adoption scope**: The subset of spec folders an adoption run considers;
  everything outside it is reported untouched.
- **Ticket identity marker**: The existing per-issue marker. Adoption writes it
  with origin `human`, which permanently governs the managed-panel behaviour and
  the human-origin deletion protection for the rest of the ticket's life.

## Constitution Check *(mandatory)*

Each of the sixteen ratified principles (constitution v1.0.1) is addressed below
with this feature's proof of compliance.

- **I. Filesystem is the source of truth, with two controlled exceptions** — This
  feature *is* the second controlled exception, built to its three conditions:
  config opt-in disabled by default (FR-001), a spec-naming label that never
  triggers adoption when it names no spec (FR-003), and a collision-free rule
  refusing any spec that already owns a bridge-created ticket and any candidate
  claimed by another spec (FR-011). Adoption is a one-time transition logged in
  the run summary (FR-024) that stamps identity and records human origin (FR-007,
  FR-016); human-origin protection against hard deletion is restated in FR-017.
- **II. Zero-churn idempotency** — Re-running adoption on an adopted corpus
  produces zero writes of every kind (FR-019, SC-004); already-stamped tickets
  are recognised and skipped (FR-027); binding never depends on a title or
  summary — FR-012 forbids any similarity-based matching outright.
- **III. Fail-closed on writes, non-blocking on hooks** — Unreliable reads abort
  the whole run before any write with the documented escalating code (FR-008,
  FR-030); every ambiguity fails closed per binding with zero writes (FR-009 to
  FR-015). Adoption is never fired by a hook (FR-029), so the non-blocking hook
  rule is untouched by this feature.
- **IV. Credential security — zero tokens in the tree** — Credential resolution
  and token exclusion are unchanged (NFR-3); the pre-write guard's BLOCK tier
  runs before every adoption write with zero exemption (FR-028); no output at any
  verbosity carries a credential or a site host (FR-025).
- **V. Separation of team config / local binding / secrets** — The two new keys
  (adoption enablement and label prefix) live in the committable team
  configuration, are credential-free, use business language, and are
  self-documented in the template (FR-001, FR-002). Nothing is written into the
  extension folder or Spec Kit core's directories.
- **VI. macOS / Linux / Windows portability** — Two native ports with identical
  observable behaviour, proven by the shared conformance corpus (NFR-1); no build
  or download step; no new runtime dependency (NFR-2); plans and machine-readable
  summaries are byte-identical between ports (FR-024, SC-008).
- **VII. No hard-coded assumptions about the Jira workflow** — Adoption reads and
  stamps identity only; it asserts nothing about issue types, statuses,
  transitions, or fields, and works over both project styles (NFR-5). The label
  prefix is operator-declared, never a literal compiled into a script (FR-002).
- **VIII. Neutral engine / Jira sink, separated by an interface** — Binding
  decisions (label derivation, ambiguity classification, hierarchy rules, scope)
  are engine concerns, expressed here without Jira mechanics; candidate search
  and the identity stamp are sink concerns behind the existing interface. The
  plan MUST realise this separation against the constitution's grep-based
  enforcement.
- **IX. Two-tier privacy guard, with an allowlist** — The guard applies to
  adoption unchanged, BLOCK tier included, with its dedicated exit code and zero
  writes (FR-028, FR-030); no new tier, no new exemption, no change to allowlist
  semantics.
- **X. Self-healing automatic mirror** — Unaffected: adoption registers no hook
  and disables none (FR-029); hook health reporting on every run is unchanged.
- **XI. Universal dry-run and auditability** — Adoption has a dry-run twin
  predicting the real run exactly (FR-023, SC-003) and produces a structured
  summary listing every applied and refused binding (FR-024). The guarded re-mode
  destructive prune remains out of scope; FR-017 restates that an adopted ticket
  can never be hard-deleted by it.
- **XII. Quality and catalog publication** — Adoption ships with mocked unit
  coverage and conformance scenarios on the three-OS matrix (NFR-1, NFR-5), a
  CHANGELOG entry, and a dogfood run against a real instance before release;
  versioning stays single-sourced.
- **XIII. TDD with minimum 80% coverage** — Every requirement above is testable
  against the shared mocked double (NFR-5), and the plan MUST order every test
  task before its implementation task. The critical paths here — ambiguity
  refusal, the zero-write guarantee, human-content preservation, and the privacy
  guard — target coverage close to 100%.
- **XIV. KISS** — Adoption adds one command, two configuration keys, and a small
  flag set. It reuses the existing identity marker with no new field, the
  existing exit-code ladder with no new code (FR-030), and the existing
  run-summary schema. There is no matching heuristic to tune and no new
  abstraction.
- **XV. YAGNI** — Every key and flag is tied to a requirement above and exercised
  by a test (FR-031); everything anticipated but not required — the destructive
  prune, ticket creation or deletion during adoption, project migration, claim
  release, cross-repository bulk adoption, task-level adoption, CI and headless
  execution — is listed in Out of Scope, never built as a dead branch.
- **XVI. Human readable** — The plan and the summary are prose by default
  (FR-024); every refusal names the spec folder, the tickets involved, and a
  copy-pasteable remediation (FR-009 to FR-011, FR-013); the two configuration
  keys are self-documenting in the template (FR-002).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A repository holding an existing labelled Jira backlog (one Epic
  and at least two Stories) and matching spec artifacts is fully bound in one
  operator-confirmed adoption run, with 0 tickets created and 0 tickets deleted.
- **SC-002**: Across the adoption run and the first reconcile that follows it,
  0 bytes of pre-existing human-authored description text are modified anywhere,
  verified by comparing every adopted ticket's description before and after,
  outside the managed panel.
- **SC-003**: For every adoption scenario in the corpus, the dry-run report and
  the real run's action set are identical, and the dry-run performs 0 writes.
- **SC-004**: Re-running adoption on an already-adopted corpus produces 0 writes
  of every kind and exits successfully.
- **SC-005**: Every per-binding refusal class (no candidate, several candidates,
  already claimed, spec already owns a bridge-created ticket, wrong project,
  unbound parent, wrong parent, ambiguous short-form number) is reproducible from
  a fixture, leaves 0 writes for the affected binding, and produces a message
  naming the spec folder, the candidate keys, and a copy-pasteable remediation.
  The two whole-run configuration refusals — adoption disabled and invalid label
  declaration — are each reproducible from a fixture and leave 0 writes overall.
- **SC-006**: The first reconcile after adoption performs 0 creations,
  0 deletions, and 0 transitions on adopted tickets — only the additive managed
  panel — and the reconcile immediately following it performs 0 writes of every
  kind.
- **SC-007**: An adoption interrupted after N of M bindings and then re-run
  results in exactly one identity stamp per adopted ticket, never two, and M
  bound tickets in total.
- **SC-008**: The same repository state adopted on macOS/Linux (Bash) and on
  Windows (PowerShell) produces byte-identical plans, byte-identical
  machine-readable summaries, and identical exit codes.
- **SC-009**: With adoption disabled in the committable configuration, a fully
  labelled backlog produces 0 reads against candidate tickets and 0 writes of
  every kind.

## Out of Scope

- The guarded re-mode destructive prune (adoption only restates that an adopted
  ticket can never be hard-deleted by it).
- Creating or deleting any Jira ticket during adoption.
- Migrating tickets between projects, and re-parenting an existing ticket.
- Releasing or transferring a claim (unbinding an adopted ticket, detaching an
  identity marker) — a later feature.
- Bulk adoption across several repositories in one run.
- Task-level adoption: sub-tasks and task-level linked Stories are not bound by
  this feature; the ordinary reconcile creates them under adopted Stories as
  bridge-created tickets.
- Applying, editing, or removing adoption labels in Jira — the bridge reads them,
  the operator applies them.
- Inventorying labelled tickets whose label names no existing spec folder
  (discovery is bounded by the spec folders in scope, NFR-6); the plan reports
  spec folders with zero candidates instead.
- CI and headless execution, which stays a later feature; adoption requires an
  operator confirmation at a terminal.

## Assumptions

- Adoption enablement and the adoption label prefix belong in the committable
  team-configuration layer (PR-reviewable, one decision per repository), per the
  established three-layer separation of team config / local binding / secrets and
  Principle I's config opt-in condition.
- The default label prefix shipped in the configuration template is
  `speckit-adopt:`, matching the example named in Principle I; the operator may
  change it, and the value is validated against Jira's label constraints.
- Discovery searches for the exact label values implied by the spec folders in
  scope, one query per routed project, rather than enumerating a backlog. This
  keeps discovery bounded and deterministic, and is why a label naming a
  non-existent spec folder is undiscoverable rather than reported (Out of Scope).
- The operator's own credentials determine what is accessible; no elevated
  permission is assumed, and a ticket the credentials cannot see is simply not a
  candidate.
- Confirmation is an explicit operator act at a terminal. A pre-confirmation flag
  exists so the conformance corpus and the dry-run twin can exercise the apply
  phase deterministically; it is not a headless-execution mode (see Out of Scope).
- The success criterion "the immediately following reconcile writes nothing" is
  read as: adoption itself writes only identity stamps, the first reconcile after
  adoption adds only the managed panel (an addition, never a rewrite — US3), and
  the reconcile after that is fully zero-write. Both guarantees are captured
  separately by SC-006 so neither can silently weaken.
- The spec artifacts to bind already exist on disk; adoption creates no spec
  folder and drafts no spec content from an adopted ticket.
- The user-story number used in the `:us<N>` label form is the ordinal of the
  user story as the bridge already identifies it in `spec.md`.
- Both project styles (company-managed and team-managed) are supported without
  distinction, because adoption touches no style-dependent field.
