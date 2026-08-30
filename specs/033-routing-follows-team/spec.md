# Feature Specification: The routing fallback follows the developer's team

**Feature Branch**: `033-routing-follows-team`

**Created**: 2026-08-30

**Status**: Draft

**Input**: User description: "In a multi-team, company-managed Jira, `routing_default` is a required key of the committed `config.yml` and it imposes one project on everyone. The team selected in the gitignored `personal.yml` influences naming only — it has no effect on routing at all. Make the developer's own team the fallback, ahead of the committed default, and make that default optional. Do not add a `routing_default` key to `personal.yml`: `team:` already carries that information."

## Context — the fallback belongs to nobody

A specification reconciles against exactly ONE Jira project. Today that project is
resolved in three steps:

1. the committed `routing:` rules — first rule whose `folder_prefix` and/or
   `spec_label` conditions all hold;
2. the **team route** — the flat spec-folder name, stripped of its numeric
   prefix, tested against each `teams[].folder_prefix` of the committed
   catalogue;
3. `routing_default` — a **required** key of the committed `config.yml`. A
   configuration that omits it, or spells it as anything but a project key, is
   refused outright.

Two facts about that chain motivate this feature.

**The developer's own team is absent from it.** `personal.yml` carries a `team:`
selection — the catalogue id the operator works under — and it governs the
folder prefix and branch pattern the naming ceremony applies. It governs nothing
else. Step 2 does route by team, but it infers the team from the *folder name*,
which only works for folders the naming ceremony itself produced. Any spec folder
that predates the catalogue, or that was created without the naming step, falls
straight past it.

**And step 3 has no legitimate owner in a shared repository.** `routing_default`
is committed, so a single value is imposed on every developer of every team. In a
repository shared by several teams there is no value that is correct for all of
them; whichever team wins the key, the others inherit a default that silently
mirrors their work into somebody else's project. The key is not merely
inconvenient there — it is unanswerable, and it is mandatory.

There is already an escape hatch, and it is the wrong one:
`config.local.yml` accepts `overrides.routing_default`, so a developer *can*
override the imposed value in a gitignored layer. It is undiscoverable, it is
documented nowhere an operator would look, and it restates in a second key what
`team:` already says. Adding a `routing_default` key to `personal.yml` would
repeat that mistake in a third place. One fact, one key.

The correction is to insert the developer's selected team into the chain, ahead
of the committed default, and to relieve that default of being mandatory:

| Rank | Source | Evidence it rests on |
| --- | --- | --- |
| 1 | committed `routing:` rule | the specification's own folder name / labels |
| 2 | team route (`teams[].folder_prefix`) | the specification's own folder name |
| 3 | **the operator's selected team** *(new)* | who is running the command |
| 4 | committed `routing_default` *(now optional)* | the repository's stated last resort |
| 5 | refusal, exit 4 | — |

The order is not arbitrary. Ranks 1 and 2 are evidence about the *specification*;
rank 3 is evidence about the *person*. A specification that says where it belongs
must outrank the person who happens to be reconciling it — otherwise a developer's
personal selection would hijack a spec the committed rules already place
elsewhere, which is precisely the imposition this feature removes, pointed the
other way.

### The hazard this creates, and where it stops

Making routing depend on a gitignored file means two developers can resolve the
same specification differently. Left unbounded that produces ping-pong: developer
A reconciles a spec into project ALPHA, developer B reconciles the same spec into
BETA, and the mirror creates a second set of tickets in BETA while the ALPHA set
is reported as "left untouched". Both sets then persist.

The stopping condition already exists in the filesystem: once a story carries a
bound marker, the specification itself records which project it lives in. Rank 3
must therefore apply only where nothing is bound yet — the first resolution
decides, and the markers pin it from then on. Ranks 1, 2 and 4 keep their current
behaviour on an already-bound spec, because they are committed values every
developer reads identically.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A developer in a multi-team repository mirrors into their own project (Priority: P1)

A developer works in a repository shared by several teams. They have selected
their team in `personal.yml`. They reconcile a specification whose folder name
matches no committed routing rule and carries no team prefix — an older folder,
or one created outside the naming ceremony. The mirror creates the tickets in
**their team's** project, not in the project the committed `routing_default`
names for somebody else.

**Why this priority**: it is the whole defect. Until this holds, a multi-team
repository silently mirrors one team's work into another team's project, and the
only remedy is an undocumented key in a gitignored file.

**Independent Test**: fully testable on its own — a repository with a `teams:`
catalogue, a `routing_default` naming project X, a `personal.yml` selecting a
team whose project is Y, and a spec folder matching no rule. Assert the tickets
are created in Y. Delivers the entire value of the feature without US2 or US3.

**Acceptance Scenarios**:

1. **Given** a committed configuration declaring a `teams:` catalogue and
   `routing_default: X`, and a `personal.yml` selecting a team whose project is
   `Y`, **When** a specification matching no routing rule and carrying no team
   folder prefix is reconciled, **Then** it resolves to `Y`.
2. **Given** the same configuration, **When** a specification whose folder name
   matches a committed `routing:` rule naming `Z` is reconciled, **Then** it
   resolves to `Z` — the committed rule outranks the personal selection.
3. **Given** the same configuration, **When** a specification whose flat folder
   name carries the `folder_prefix` of a catalogue team whose project is `W` is
   reconciled, **Then** it resolves to `W` — the team route outranks the
   personal selection.
4. **Given** a specification whose stories already carry bound markers naming
   project `X`, **When** an operator whose personal team's project is `Y`
   reconciles it, **Then** it resolves to `X` and no ticket is created in `Y`.
5. **Given** no `personal.yml`, or one selecting no team, **When** a
   specification matching nothing is reconciled, **Then** resolution falls
   through to `routing_default` exactly as it does today.

---

### User Story 2 - A repository can decline to name a shared default (Priority: P2)

A maintainer setting up a multi-team repository omits `routing_default` from the
committed `config.yml` entirely, because no single value is correct for the teams
sharing it. The configuration is accepted. Every developer routes by their own
team; a specification that matches nothing and belongs to nobody is refused
rather than silently sent somewhere.

**Why this priority**: US1 removes the *effect* of the imposed key; this removes
the obligation to declare it at all. Valuable on its own, but a repository that
keeps declaring the key is already correctly served by US1.

**Independent Test**: validate a committed configuration with no
`routing_default` key and assert it is accepted, then assert an existing
configuration that declares one still validates and still behaves identically.

**Acceptance Scenarios**:

1. **Given** a committed `config.yml` with no `routing_default` key, **When** the
   configuration is loaded, **Then** it is accepted with no error.
2. **Given** a committed `config.yml` declaring `routing_default` as something
   other than a valid project key, **When** the configuration is loaded, **Then**
   it is still refused with the located error it produces today — optional means
   "may be absent", never "may be malformed".
3. **Given** an existing single-team repository declaring `routing_default` and
   no `teams:` catalogue and no `personal.yml`, **When** any specification is
   reconciled, **Then** every resolution is byte-identical to the behaviour
   before this feature.

---

### User Story 3 - A refusal names which state produced it (Priority: P3)

An operator's specification resolves to no project at all. Instead of a single
sentence naming one missing key, they are told which of the four ranks was
consulted, what each found, and the one action that would change the outcome for
their situation.

**Why this priority**: it converts the failure this feature makes newly reachable
— a repository that legitimately declares no default — from a dead end into a
diagnosis. It follows the precedent set for team resolution in feature 031.

**Independent Test**: construct a repository in each distinguishable refusal
state and assert each produces a message that names that state and no other.

**Acceptance Scenarios**:

1. **Given** a repository with routing rules that matched nothing, no catalogue
   team matching the folder, no personal team selected, and no
   `routing_default`, **When** a specification is reconciled, **Then** the
   refusal names all four findings and exits 4 with zero writes.
2. **Given** a repository whose only missing element is the personal team
   selection, **When** a specification is reconciled, **Then** the refusal says
   so specifically and names selecting a team as the remedy.
3. **Given** any refusal state, **When** the message is emitted, **Then** every
   command literal it contains is runnable exactly as spelled.

---

### Edge Cases

- **The selected team's project is not declared in `projects[]`.** The catalogue
  entry is internally consistent but names a project the configuration never
  declares. This is the existing unknown-project refusal and must stay reachable
  through the new rank — it is not a routing failure, and must not be reported as
  one.
- **`personal.yml` is present but malformed.** Routing is a write path. A file
  that cannot be read is an operator statement that did not work; the run refuses
  fail-closed rather than falling through to rank 4 on a file it failed to
  understand. An *absent* file, or one selecting no team, is not a statement at
  all and falls through silently.
- **The selected team id is not in the catalogue.** Already a located error
  listing the valid ids; this feature must not weaken it into a silent
  fall-through.
- **A specification with some stories bound and some not.** The spec's bound
  markers are what pin the project; the unbound stories join the project the
  bound ones already name, not the reconciling operator's team.
- **The catalogue declares no `teams:` at all**, but `personal.yml` selects a
  team. Already a located error today; unchanged.
- **Two catalogue teams declare the same project.** Legitimate — several teams
  may share one Jira project. Rank 3 resolves through the selected team's own
  entry and needs no uniqueness beyond what the catalogue already enforces.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Routing resolution MUST consult four ranked sources in this order
  and stop at the first that yields a project key: committed `routing:` rules,
  the committed team route by folder prefix, the team selected in the operator's
  `personal.yml`, and the committed `routing_default`.
- **FR-002**: The project contributed by rank 3 MUST be the `project` of the
  catalogue entry whose `id` equals the `team` value in `personal.yml`. No new
  key is introduced in `personal.yml` for this purpose.
- **FR-003**: `routing_default` MUST become optional in the committed
  configuration schema: its absence MUST be accepted, and its presence with any
  value that is not a valid project key MUST remain refused with the located
  error it produces today.
- **FR-004**: Rank 3 MUST apply only to a specification none of whose stories
  carries a bound marker. Where any story is bound, resolution MUST skip rank 3
  and fall from rank 2 to rank 4.
- **FR-005**: Where the operator's `personal.yml` exists but cannot be read or
  validated, a routing resolution that would reach rank 3 MUST refuse
  fail-closed with exit 4 and zero writes, rather than falling through to rank 4.
- **FR-006**: Where `personal.yml` is absent, or is present and selects no team,
  resolution MUST fall through from rank 3 to rank 4 silently, producing no
  warning and no diagnostic on the ordinary path.
- **FR-007**: Where all four ranks yield nothing, the run MUST refuse with exit 4
  and zero writes, and the refusal MUST name what each of the four ranks found
  or failed to find.
- **FR-008**: Every command literal appearing in a message this feature adds or
  changes MUST be runnable exactly as spelled.
- **FR-009**: A repository that declares `routing_default`, declares no `teams:`
  catalogue, and has no `personal.yml` MUST resolve every specification exactly
  as it does today, with no observable change of any kind.
- **FR-010**: The shipped configuration template MUST present `routing_default`
  as optional and MUST state, where the key is introduced, that a developer's
  selected team takes precedence over it.
- **FR-011**: The documented configuration surface MUST describe the four-rank
  chain, including which rank the personal team occupies and the bound-marker
  condition that bounds it.
- **FR-012**: Both language ports MUST produce byte-identical resolutions and
  byte-identical refusal messages for every state this feature defines.

### Key Entities

- **Routing resolution chain**: the ordered set of four sources consulted to
  place one specification in one project, plus the refusal that follows all four.
- **Catalogue team entry**: a committed record binding a team id to a project
  key, a flat folder prefix, and a branch pattern. This feature adds a second
  consumer of its `project` field; it changes no field.
- **Personal team selection**: the operator's `team` value in the gitignored
  per-operator file. This feature adds routing to what it governs; it introduces
  no new key and no new file.
- **Bound marker**: the record, in the specification itself, that a story already
  exists as a named ticket in a named project. This feature makes it the
  condition that bounds rank 3.

## Constitution Check *(mandatory)*

Assessed against constitution **4.0.0** (amended 2026-08-30). That amendment
rewrote Principle X and touched nothing else; it is orthogonal to this feature,
which neither reads nor reports the hook registry. No amendment is required by
this specification and none is sought.

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Strengthened. FR-004 makes the specification's own bound markers the authority that overrides a per-operator preference; no new state store is introduced and no registry is consulted. |
| II | Zero-Churn Idempotency | FR-004 is what preserves it. Without the bound-marker condition, two operators would reroute the same spec back and forth on every run; with it, a resolved spec is stable for every operator forever. FR-009 keeps existing repositories churn-free. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-005 and FR-007 both refuse with exit 4 and zero writes. Neither adds a failure mode to hook context: the existing hook-context downgrade continues to convert both into a single warning. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. No key this feature reads or writes can hold a credential, and the credential scan over both YAML layers is untouched. |
| V | Separation of Team Config / Local Binding / Secrets | Central, and respected. The per-operator layer gains influence over routing through the key it already owns; no new key is added to it, nothing moves out of the committed layer, and the committed layer keeps the ability to state a default. Rank order guarantees the committed layers still outrank the per-operator one. |
| VI | macOS / Linux / Windows Portability | FR-012 requires byte-identical behaviour from both ports; the conformance corpus gains scenarios for each rank and each refusal state. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. Routing resolves a project key; it asserts nothing about statuses, types, or transitions. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Resolution stays a pure function of configuration and specification content, with no Jira read or write. The one new input — the operator's team selection — is configuration, and reaches the resolver as data. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. No specification content is transmitted by this feature; project keys are already public within the organisation. |
| X | Self-Healing Automatic Mirror, Within Its Own Boundary | Unaffected. This feature neither reads nor reports the hook registry — which the principle, as amended in constitution 4.0.0, now forbids outright rather than merely leaving unaddressed. |
| XI | Universal Dry-Run and Auditability | The resolved project already appears in the run summary and under `--dry-run`; FR-007's refusal is reported through the existing structured summary. |
| XII | Quality and Catalog Publication | Version bump and CHANGELOG entry accompany the change; FR-003 is a schema relaxation, which is backward-compatible and needs no major bump. |
| XIII | TDD With a Minimum 80% Coverage | Each rank, each refusal state, and the FR-004 bound-marker condition gets a failing test before its implementation, in both ports, plus conformance scenarios for cross-port equivalence. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | One rank inserted into an existing chain, one required key made optional, zero new keys, zero new files, zero new state. The rejected alternative — a `routing_default` key in the per-operator file — was strictly more machinery for strictly less. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Every requirement traces to a defect observed in a real multi-team company-managed Jira. The bound-marker condition (FR-004) is not speculative: it is the ping-pong this feature would otherwise introduce. |
| XVI | Human Readable — Readable by a Human Above All | FR-007 requires the refusal to name what each rank found rather than state a single missing key; FR-010 and FR-011 put the rank order where an operator reads it. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a repository shared by two teams, with no committed rule
  matching, two operators selecting different teams each mirror the same kind of
  new specification into their own team's project, with no configuration edit by
  either of them.
- **SC-002**: A repository can be configured for multi-team use without any
  developer editing a gitignored file to correct a value imposed by a committed
  one.
- **SC-003**: 100% of existing configurations that declare `routing_default`
  resolve every specification to the same project as before this change.
- **SC-004**: Every distinguishable refusal state produces a message that names
  that state and no other, verified by one scenario per state.
- **SC-005**: A specification whose stories are already bound resolves to the
  same project for every operator, regardless of which team each has selected —
  zero tickets created outside the bound project.
- **SC-006**: Both ports produce identical output for every scenario above.

## Assumptions

- The developer's selected team outranks the committed `routing_default` but is
  outranked by both committed sources that reason from the specification itself.
  Recorded as a decision in Context rather than deferred: the opposite order
  would let a personal file override a team's committed routing rules.
- `routing_default` is retained as an optional last resort rather than removed
  from the schema. Removing it would break every repository that declares no
  `teams:` catalogue and would require a major version bump; retaining it as
  optional achieves the operator-visible goal with no breakage. Sequencing this
  way keeps the removal available later as a strictly smaller change.
- The bound-marker condition (FR-004) is scoped to rank 3 only. Ranks 1, 2 and 4
  read committed values that every operator resolves identically, so they carry
  no ping-pong risk and keep their present behaviour on bound specifications.
- No migration is provided and none is needed: every existing configuration
  remains valid, and the new rank is inert wherever no team is selected.
- The existing `config.local.yml` `overrides.routing_default` path is left in
  place. It is a general override mechanism over the whole committed config, not
  a routing feature, and narrowing it is out of scope here.
