# Feature Specification: The Operator Declares Which Issue Types Carry the Mirror

**Feature Branch**: `feat/handle-multiple-epics`

**Created**: 2026-08-02

**Status**: Draft

**Input**: User description: "I tested the extension on a consumer project. Its Jira has three
hierarchy levels: level 1 holds `Epic` and `Service Category`; level 0 holds `Tâche`, `Story`,
`Defect`, `Improvement Action`, `Test`, `Test Set`, `Test Execution`, `Precondition`, `Release`,
`Incident SNOW`, `Objective`, `Service`, `Problem SNOW`; level -1 holds `Sous-tâche` and
`Sub Test Execution`. Find a way for the extension to work against this kind of instance, with
several levels and many types per level. I pictured the config command proposing a mapping —
level 1 is `Epic`, level 0 is `Story`, level -1 is `Sous-tâche` — persisted in the YAML config the
extension owns. A better proposal is welcome. As things stand the consumer is blocked."

## Context

A real consumer instance now refuses to configure, and the refusal is the one feature 008 wrote
down in advance as the event that would make this work necessary.

The instance reports three hierarchy levels and seventeen issue types:

| Level | Types reported by the project |
| --- | --- |
| 1 | `Epic`, `Service Category` |
| 0 | `Tâche`, `Story`, `Defect`, `Improvement Action`, `Test`, `Test Set`, `Test Execution`, `Precondition`, `Release`, `Incident SNOW`, `Objective`, `Service`, `Problem SNOW` |
| -1 | `Sous-tâche`, `Sub Test Execution` (sub-task types) |

The bridge derives the story tier as the lowest level occupied by a non-sub-task type, and the
specification tier as the lowest level strictly above it. On this instance both derivations are
ambiguous:

- **Thirteen candidates at level 0.** This case already has an answer channel — the operator
  passes the child type once and it is recorded in the gitignored local binding. It works, but the
  answer is per-developer and invisible to the rest of the team.
- **Two candidates at level 1.** This case has **no answer channel at all**. The configuration
  ceremony exits `4` with `parent-level-ambiguous`, names both candidates, and stops. There is no
  flag, no configuration key, and no question that lets the operator say "`Epic`, not
  `Service Category`". The consumer cannot get past configuration, so nothing is ever mirrored.

Feature 008 predicted both of these and deferred them deliberately, each with a written trigger:

- The parent-type key was deferred "until the FR-006 ambiguity refusal fires at a real consumer".
  **It has now fired.**
- The committable child-type switch was deferred to "the release immediately before rollout to a
  second team", because the local binding is gitignored, so each developer answers the
  child-type question independently and two developers can mirror into the same project as
  different issue types. **Rollout to a consumer project is now under way.**

Both triggers have fired at once, so both are settled here, by one mechanism rather than two.

### Why roles, not level numbers

The user's proposal — map level 1, level 0 and level -1 to types — is the right shape with the
wrong key. Level numbers are an internal Jira coordinate: they differ between instances, they are
invisible in the Jira UI, they shift when an administrator inserts a tier, and they mean nothing
to the person editing the committed configuration. Worse, a mapping keyed by level cannot express
the only question the bridge actually has to answer, which is *which artifact of the repository
lands on which issue type*.

So the mapping declares **roles**, and the role names are the repository's own vocabulary:

| Role | What the repository puts there | Today |
| --- | --- | --- |
| `specification` | One artifact per `spec.md` — the feature itself | Mirrored |
| `story` | One issue per user story inside that specification | Mirrored |
| `task` | One issue per task inside a user story | Not mirrored today; opt-in here |

The level is not discarded — it is what the mapping is *validated against*. Declaring
`specification: Epic` and `story: Story` is accepted because the project reports `Epic` strictly
above `Story`; declaring the reverse is refused at configuration time, naming both levels. The
operator answers in the vocabulary they can see in Jira (a type name) and in the vocabulary they
can see in the repository (a role), and the bridge does the level arithmetic.

This also removes an ambiguity the level-keyed form cannot express: on the consumer instance,
level 0 holds thirteen types and a team may legitimately want `Story` for user stories while
another repository routed to the same project wants `Defect`. A role-keyed mapping states that
directly.

### Where it lives

The mapping is a **team decision expressed in type names**, so it belongs in the committed
`config.yml` next to `priority_map`, which is the exact same shape of decision. The resolved
identifiers and levels stay in the gitignored local binding, where every resolved identifier
already lives. Nothing about this feature puts an identifier in the committed layer or a team
preference in the gitignored one.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A project with several types per level can be configured and mirrored (Priority: P1)

An operator runs the configuration ceremony against a project whose hierarchy is ambiguous at the
specification tier, the story tier, or both. They declare which issue type carries specifications
and which carries user stories. Configuration completes, and a subsequent reconcile mirrors a
specification as a parent of that declared type with its user stories beneath it.

**Why this priority**: This is the whole blockage. Without it the consumer instance cannot be
configured at all, so no other behaviour of the extension is reachable there.

**Independent Test**: Configure against a fixture whose specification level holds two types and
whose story level holds thirteen, with both roles declared; the ceremony exits `0` and the local
binding records both types. Reconcile a two-story specification and observe one parent of the
declared specification type and two children of the declared story type.

**Acceptance Scenarios**:

1. **Given** a project reporting two non-sub-task types at the level above the story level, **When**
   the configuration declares one of them for the `specification` role, **Then** the ceremony
   completes successfully and records that type, and the previously emitted
   `parent-level-ambiguous` refusal does not occur.
2. **Given** a project reporting thirteen non-sub-task types at the story level, **When** the
   configuration declares one of them for the `story` role, **Then** the ceremony completes
   successfully and records that type.
3. **Given** both roles declared, **When** a specification with two user stories is reconciled,
   **Then** exactly one issue of the declared specification type and two issues of the declared
   story type are created, and each story names the parent.
4. **Given** a project where a level holds exactly one non-sub-task type and nothing is declared
   for that role, **When** the ceremony runs, **Then** the type is derived exactly as it is today
   and the run completes without asking anything — an unambiguous project is not made to answer a
   question it does not have.
5. **Given** a declaration naming a type the project does not report, **When** the ceremony runs,
   **Then** it refuses with the configuration exit code, names the declared value and lists the
   types the project actually reports for that role's level, and writes nothing.

---

### User Story 2 - The ceremony asks instead of failing (Priority: P1)

The operator has not declared anything yet. Rather than exiting with a refusal and leaving them to
discover which flag or key to write, the configuration ceremony enumerates the candidates the
project itself reported and names, for each, the exact declaration and the exact flag that would
resolve it. The agent driving the ceremony puts that closed question to the operator and re-invokes
with their answer, which is then recorded with its provenance. The bridge itself never prompts: an
interactive read would hang the machine-readable summary and every lifecycle hook.

**Why this priority**: The declaration surface of User Story 1 is unusable without a way to
discover it. An operator meeting `parent-level-ambiguous` today has no path forward from the
message alone; that is precisely how the consumer got stuck.

**Independent Test**: Run the ceremony against the ambiguous fixture with nothing declared and no
flag passed; one refusal enumerates both specification-tier candidates and all thirteen story-tier
candidates, naming the declaration and the flag for each. Re-invoke with those answers supplied and
the ceremony completes.

**Acceptance Scenarios**:

1. **Given** an ambiguous specification tier and no declaration, **When** the ceremony runs, **Then**
   it emits a closed, enumerated question listing every candidate at that level by the name the
   project reports, and offers no option outside that list.
2. **Given** an ambiguous story tier and no declaration, **When** the ceremony runs, **Then** it
   emits the same shape of closed question for that tier.
3. **Given** the operator's answers supplied to a subsequent invocation, **When** the ceremony runs
   again, **Then** each answer is persisted with its provenance recorded as an operator answer,
   distinct from a derived value.
4. **Given** a completed run, **When** the ceremony is re-run against an unchanged project with
   the mapping already recorded, **Then** it asks nothing, writes the same bytes, and reports the
   discovery effect as unchanged.
5. **Given** a non-interactive run (no operator available to answer), **When** the tier is
   ambiguous and nothing is declared, **Then** the run refuses with the configuration exit code
   and its message names every candidate and the exact declaration that would resolve it —
   the current fail-closed behaviour is preserved, never replaced by a guess.

---

### User Story 3 - The whole team mirrors into the same issue types (Priority: P2)

Two developers work on the same repository, routed to the same Jira project. Whatever one of them
answered at configuration time, the other mirrors specifications into the same issue types,
because the decision is committed to the repository rather than answered privately on each
machine.

**Why this priority**: This is the divergence risk feature 008 recorded and dated to this
release. Nothing breaks without it — each machine stays internally consistent and idempotent — but
the shared backlog silently acquires two different issue types for the same kind of artifact, and
the inconsistency is invisible until someone reads the types.

**Independent Test**: Record a mapping in the committed configuration, delete the local binding,
re-run configuration on a second machine with no operator answers available, and observe the same
issue types resolved without a question being asked.

**Acceptance Scenarios**:

1. **Given** a mapping declared in the committed configuration, **When** a developer with no local
   binding configures the project, **Then** the declared types are used, no question is asked, and
   the resolved identifiers are written to that developer's local binding.
2. **Given** a mapping declared in the committed configuration and a *different* answer already
   recorded in a developer's local binding, **When** they re-run configuration, **Then** the
   committed declaration wins, the local binding is updated to match it, and the run reports that
   the local answer was superseded, naming both types.
3. **Given** no mapping in the committed configuration, **When** an operator answers the closed
   question, **Then** the run completes and additionally reports, without failing, the exact
   declaration to commit so the rest of the team shares the answer.
4. **Given** a committed mapping, **When** it is inspected in a diff or code review, **Then** it
   reads as role-to-type-name pairs and contains no identifier, no level number and no site host.

---

### User Story 4 - A mapping that no longer matches the project refuses cleanly (Priority: P2)

A Jira administrator renames, removes, or re-levels an issue type after the mapping was recorded.
The next run says so, in terms naming the role, the recorded type, and what the project reports
now — and writes nothing to Jira.

**Why this priority**: A stale mapping is the predictable failure mode of any recorded answer, and
this one sits directly on the write path. Detected late, it produces issues of the wrong type
under a parent that cannot hold them; detected at configuration time it costs one message.

**Independent Test**: Record a valid mapping, mutate the fixture so the specification-role type
sits at or below the story-role type's level, and run reconcile; the run refuses, names both roles
and both levels, and issues zero writes.

**Acceptance Scenarios**:

1. **Given** a recorded mapping whose specification-role type no longer exists in the project,
   **When** configuration or reconcile runs, **Then** the run refuses with the configuration exit
   code, names the role and the missing type, and writes nothing to Jira.
2. **Given** a recorded mapping whose specification-role type is not strictly above the story-role
   type in the project's reported hierarchy, **When** the mapping is validated, **Then** the run
   refuses, naming both roles, both types and both levels, and writes nothing to Jira.
3. **Given** a mapping declaring a sub-task type for the `specification` or `story` role, **When**
   the mapping is validated, **Then** the run refuses, naming the role and the type, and writes
   nothing to Jira.
4. **Given** a mapping whose story-role type does not accept a parent reference, **When** the
   mapping is validated, **Then** the existing parent-link refusal fires at configuration time
   rather than at the first write.
5. **Given** any of these refusals, **When** it occurs inside a lifecycle hook, **Then** it is
   reported as one warning and the host command still succeeds.

---

### User Story 5 - A team that works in sub-tasks can mirror its task list (Priority: P3)

A team whose Jira has a sub-task tier declares a `task` role. From then on, the tasks recorded
against a user story are mirrored as sub-tasks of that story's issue. A team that declares no
`task` role sees exactly today's two-tier mirror, unchanged.

**Why this priority**: This is the third tier the consumer described, and it is additive value
rather than a blockage — the consumer is unblocked by User Stories 1 and 2 alone. It is also the
largest piece of work here, because it introduces a document tier the mirror does not carry today,
with its own durable identifiers, recognition and drift handling. It is specified last and can
ship separately without invalidating anything above it.

**Independent Test**: Declare a `task` role against a fixture with a sub-task type, reconcile a
specification whose stories carry tasks, and observe one sub-task per task under the correct
story; re-run and observe zero writes.

**Acceptance Scenarios**:

1. **Given** a declared `task` role naming a sub-task type, **When** a specification whose user
   stories carry tasks is reconciled, **Then** each task is created as a sub-task of its own
   story's issue.
2. **Given** the same specification, **When** it is reconciled a second time unchanged, **Then**
   zero writes of every kind are issued, sub-tasks included.
3. **Given** no `task` role declared, **When** any specification is reconciled, **Then** no
   sub-task is created and the mirror is byte-for-byte what it is today.
4. **Given** a `task` role naming a type that is not a sub-task type in the project, **When** the
   mapping is validated, **Then** the run refuses, names the role and the type, and writes nothing.
5. **Given** a declared `task` role and a story that carries no tasks, **When** it is reconciled,
   **Then** the story is created normally and no empty sub-task is invented.

---

### Edge Cases

- **A level holds one candidate and a declaration names it anyway.** Accepted, not refused — an
  explicit declaration that agrees with the derivation is redundant, not wrong, and refusing it
  would punish a team for being explicit. Provenance records it as declared.
- **A level holds one candidate and a declaration names a different one at another level.**
  Accepted if the resulting ordering is valid, because a project offering `Capability`, `Feature`
  and `Story` may legitimately hang specifications from `Feature` rather than the level
  immediately above `Story`. Refused otherwise, per User Story 4.
- **Two type names differ only by case or surrounding whitespace.** The declared name is matched
  against the reported name as opaque text, exactly as type names are treated today — no
  normalisation, no case folding, no translation. A name that does not match exactly is reported
  as unknown with the candidate list, so the operator sees the difference rather than a silent
  near-match.
- **Two types at the same level share a name.** The project reports the identifier that
  disambiguates them; the run refuses rather than picking one, and names the level.
- **The project reports no level above the story tier at all.** Unchanged: the existing
  `no-parent-level` refusal stands. A declaration cannot invent a tier the project does not have.
- **The project reports no sub-task type but a `task` role is declared.** Refused as an unknown
  type for that role, with the candidate list empty and stated as empty.
- **No `task` role is declared at all.** The role is *absent*, not unresolved: nothing is recorded
  for it, no question is asked about it, and no refusal mentions it. It is never derived, so
  treating an undeclared `task` as an unanswered question would refuse every project that does not
  want a task tier — which is every project configuring successfully today.
- **Different repositories route to the same Jira project with different mappings.** Permitted —
  the mapping is per project *entry* in a repository's configuration, and two repositories are
  free to mirror into different types of the same project.
- **Two projects in one repository, one ambiguous and one not.** Only the ambiguous project's
  roles are asked about; the unambiguous project keeps deriving silently.
- **A recorded mapping from a previous release is absent entirely.** The existing derivation runs
  unchanged, so every project that configures successfully today keeps configuring successfully
  with no edit to any committed file.
- **A hierarchy declaration appears under a retired key name.** Refused with the existing
  retired-key rule rather than partially honoured.

## Requirements *(mandatory)*

### Functional Requirements

#### The mapping surface

- **FR-001**: The committed team configuration MUST accept, per project entry, an optional
  hierarchy mapping expressed as role-to-issue-type-name pairs, where the roles are
  `specification`, `story` and `task`.
- **FR-002**: Each role in the mapping MUST be independently optional. A mapping declaring only
  `specification` is valid, and the undeclared roles fall back to derivation exactly as today.
- **FR-003**: The mapping MUST carry issue type **names only**, and MUST NOT become a second home
  for a credential or a site coordinate. A credential-shaped or host-shaped value MUST be refused
  with the configuration exit code and MUST NEVER be echoed, through the existing credential scan.
  A value that is instead an identifier or a level number MUST NOT be refused on its shape: a
  digits-rejecting rule would be a compiled-in assumption about how a Jira administrator may name a
  type, and `10701` is a legal issue type name. Such a value is refused structurally instead — the
  bridge matches reported names only, so it falls into the unknown-type refusal with the candidate
  list attached, where echoing the offending value is what makes the message useful.
- **FR-004**: A project entry with no mapping at all MUST behave exactly as it does today. No
  existing committed configuration may require an edit as a result of this feature.
- **FR-005**: The mapping MUST be documented in the shipped configuration template, in the same
  business vocabulary as the surrounding keys, with the consumer's own three-level shape as the
  worked example.
- **FR-030**: An unknown role name inside the mapping MUST be refused with the configuration exit
  code, naming the offending role and listing the three roles the mapping accepts.

#### Resolution and precedence

- **FR-006**: For each role, the issue type MUST be resolved in this order, and the order MUST be
  reported in the run summary as the value's provenance: (1) the committed declaration; (2) the
  operator's answer recorded in the local binding; (3) derivation from the project's reported
  hierarchy when exactly one candidate exists.
- **FR-007**: When a committed declaration and a recorded local answer disagree, the committed
  declaration MUST win, the local binding MUST be updated to match, and the run MUST report the
  supersession naming both types.
- **FR-008**: When a role is ambiguous and unresolved by (1) or (2), the ceremony MUST emit a
  closed, enumerated question over exactly the candidates the project reported for that role's
  level, offering no option outside that list and no default. The bridge emits the question; it
  MUST NOT read from standard input on any path. The agent driving the ceremony is what puts the
  question to the operator and re-invokes with the answer.
- **FR-009**: When no operator answer is obtainable, the run MUST refuse with the configuration
  exit code and MUST NOT choose a candidate. The refusal MUST name every candidate and the exact
  declaration that would resolve it.
- **FR-010**: An operator's answer MUST be persisted in the gitignored local binding with its
  provenance, alongside the existing style provenance record.
- **FR-011**: When a run resolves a role from an operator answer rather than a committed
  declaration, it MUST report — without failing — the declaration to commit so the team shares
  the answer.
- **FR-012**: The specification role's type MUST NOT be required to sit at the level immediately
  above the story role's type. Any level strictly above is permitted.

#### Validation — refusing the impossible before any write

- **FR-013**: A declared or answered type that the project does not report MUST be refused with
  the configuration exit code, naming the role, the declared value, and the types the project
  reports for that role's level.
- **FR-014**: A `specification` role whose type does not sit strictly above the `story` role's
  type MUST be refused, naming both roles, both types and both levels.
- **FR-015**: A `specification` or `story` role naming a sub-task type MUST be refused, naming the
  role and the type.
- **FR-016**: A `task` role naming a type that is not a sub-task type MUST be refused, naming the
  role and the type.
- **FR-017**: A `story` role whose type does not accept a parent reference MUST be refused at
  configuration time through the existing parent-link refusal, before any ticket exists.
- **FR-018**: The existing mandatory-field gate MUST run over every type the mapping selects,
  including a declared type that derivation would never have chosen.
- **FR-019**: A level holding two types with the same reported name MUST be refused rather than
  disambiguated silently, naming the level.
- **FR-020**: Every refusal in this section MUST issue zero writes to Jira, and MUST be downgraded
  to a single warning with a successful return when it occurs inside a lifecycle hook.
- **FR-021**: A validation refusal MUST be raised at configuration time whenever the information
  to raise it is available at configuration time. Reconcile MUST re-validate against the binding
  it reads and refuse identically if the recorded mapping has gone stale.

#### Behaviour of the mirror

- **FR-022**: A specification MUST be mirrored as one issue of the resolved `specification` type,
  with one child issue of the resolved `story` type per user story, exactly as today — only the
  type resolution changes.
- **FR-023**: When a `task` role is resolved, each task recorded against a user story MUST be
  mirrored as one sub-task of that story's issue.
- **FR-024**: When no `task` role is resolved, no sub-task MUST be created, and the mirror MUST be
  identical to today's output.
- **FR-025**: A second reconcile against an unchanged specification MUST issue zero writes of
  every kind, at every tier the mapping selects.
- **FR-026**: A dry run MUST predict the resolved type of every issue it would create, at every
  tier, and MUST predict every refusal of this specification exactly.

#### Reporting

- **FR-027**: The configuration run summary MUST report, per project, the resolved type of each
  role together with its provenance.
- **FR-028**: Every message introduced here MUST name issue types by the name the project reports,
  never by an identifier, and MUST name roles by the role vocabulary the configuration uses.
- **FR-029**: Both ports MUST implement this feature in the same change and produce byte-identical
  output for it, including messages that interpolate non-ASCII type names such as `Tâche`,
  `Sous-tâche` and `Récit`.

### Key Entities

- **Role**: The part an artifact of the repository plays in the mirror — `specification`, `story`
  or `task`. Repository vocabulary; contains nothing Jira-specific.
- **Hierarchy mapping**: A per-project set of role-to-issue-type-name pairs, declared in the
  committed team configuration. Names only, no identifiers, no levels.
- **Resolved role binding**: The outcome of resolving a role for one project — the issue type
  name, its identifier, its reported hierarchy level, its sub-task flag, and the provenance of the
  resolution (declared, operator-answered, or derived). Machine-owned; lives in the gitignored
  local binding.
- **Candidate set**: The issue types the project reports at the level relevant to a role. Supplied
  by the project, never assembled from a compiled-in list, and used as the sole option list for
  every closed question and every refusal message.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | The mapping is a declaration on disk in the committed configuration; the resolved identifiers it produces are a derived mirror of the project's own metadata and are re-derivable at any time by deleting the local binding and re-running. No ticket is adopted, converted or deleted as a result of a mapping change: a changed mapping affects issues created after it, and existing recorded tickets keep being recognised by their recorded identifiers. |
| II | Zero-Churn Idempotency | FR-025 requires zero writes on a second unchanged reconcile at every tier the mapping selects, sub-tasks included. User Story 2 scenario 4 requires the configuration ceremony to rewrite the local binding byte-for-byte identically on an unchanged re-run and to ask nothing. FR-007's supersession is a one-time convergence of the local binding onto the committed declaration, after which re-runs are unchanged. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-009 refuses rather than choosing a candidate; FR-013 to FR-019 each refuse a distinct impossible mapping; FR-020 requires zero Jira writes on every one of them and the standard downgrade to one warning with a successful return under hook context. FR-021 pulls each refusal as early as the information allows, so an impossible mapping is refused before a ticket exists rather than after a partial hierarchy has been built. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | No credential is introduced, read or persisted. FR-003 extends the existing credential-shaped-value refusal to the new keys and forbids echoing a credential-shaped value; an identifier-shaped value is refused structurally by the name match instead, since a digits-rejecting rule would violate Principle VII. Fixtures use the consumer's reported type names, which are type names and not secrets, plus invented identifiers. |
| V | Separation of Team Config / Local Binding / Secrets | This is the principle the feature is organised around. The mapping is a team decision stated in names, so it sits in the committed layer beside `priority_map`; the resolved identifiers, levels and sub-task flags it produces stay in the gitignored, machine-owned binding. FR-003 forbids an identifier in the committed layer; FR-010 keeps the operator's private answer in the local layer until FR-011 invites its promotion. Nothing moves inside the extension folder. |
| VI | macOS / Linux / Windows Portability | FR-029 requires both ports in the same change with byte-identical output, and names the specific hazard: the consumer's own type names are non-ASCII (`Tâche`, `Sous-tâche`), so the messages this feature adds interpolate non-ASCII text on the Windows path as well. That is the same class of divergence feature 007 hit with unicode configuration keys, so a Windows conformance probe is part of proving this feature rather than an afterthought. No new dependency is introduced. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | The feature exists to widen this principle's reach, not to narrow it. Every candidate list, every question and every refusal message is built from the project's own reported metadata; no Atlassian default name (`Epic`, `Story`, `Sub-task`) is compiled in anywhere, including in the template's worked example, which is documentation rather than a fallback. The declared name is opaque text, matched exactly, never parsed, translated, case-folded or normalised. Level arithmetic uses the levels the project reports, and FR-012 refuses to assume the specification tier is adjacent to the story tier. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Roles are neutral repository vocabulary and belong to the engine; issue types, levels, sub-task flags, parent references and create metadata are Jira facts and stay in the sink. The neutral document gains no Jira identifier — a task tier, if built, adds neutral task content to the document and the sink alone decides it becomes a sub-task of a given type. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unchanged in behaviour, extended in reach: every payload the task tier would add is scanned on the same terms as a story payload before any write, so the guard still sees every byte that leaves the machine. |
| X | Self-Healing Automatic Mirror | Preserved. FR-020's downgrade keeps every new refusal non-blocking inside a lifecycle hook, so a stale or impossible mapping can never fail a host command. A project that configures successfully today keeps doing so (FR-004), so no installed mirror is disturbed by the upgrade. |
| XI | Universal Dry-Run and Auditability | FR-026 requires a dry run to predict the resolved type of every issue at every tier and to predict every refusal exactly. FR-027 requires the run summary to report each role's resolved type with its provenance, so an operator can audit *why* a type was chosen, not merely which one. |
| XII | Quality and Catalog Publication | The feature ships with a CHANGELOG entry and a version bump, runs the full suite on all three operating systems, and is dogfooded against the real consumer instance whose refusal motivated it — which is also the only place the seventeen-type hierarchy can be proven end to end. |
| XIII | TDD With a Minimum 80% Coverage | Tests come first. The consumer's hierarchy becomes a fixture in its own right — two types at the specification level, thirteen at the story level, two sub-task types — and the `parent-level-ambiguous` refusal it currently produces is written as a failing test before the fix, per the repository's bug-fix policy. Each refusal of FR-013 to FR-019 gets its own test, as does the FR-004 no-mapping regression that proves existing installations are undisturbed. Resolution precedence (FR-006) and idempotency (FR-025) sit on the critical path and target coverage close to 100%. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | One mechanism settles both of feature 008's deferred keys instead of two separate ones. The mapping reuses the existing committed-configuration layer, the existing local binding, the existing closed-question pattern, the existing provenance pattern established by `style` / `style_source`, and the existing refusal and hook-downgrade paths. No new abstraction and no new dependency is introduced; the derivation that works today is kept and the declaration merely takes precedence over it. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Both keys added here were explicitly deferred by feature 008 with written triggers, and both triggers have now fired: the ambiguity refusal has occurred at a real consumer, and rollout beyond a single machine is under way. The `task` role is the one part not yet demanded by a blockage; it is therefore separated into the lowest-priority user story, made opt-in, and specified so that its absence leaves today's output byte-for-byte unchanged (FR-024). No key is added for anything else the consumer's instance suggests — routing a specification to a *different* type per specification, and supplying values for mandatory custom fields, are both recorded in Out of Scope. |
| XVI | Human Readable — Readable by a Human Above All | The mapping is keyed by repository vocabulary rather than by Jira level numbers precisely so the committed file reads as a sentence a product owner can check in review (User Story 3 scenario 4). Every refusal names the role, the type, the level and the candidates, and FR-009 requires it to name the exact declaration that would resolve it — the reader is never left to guess the remedy, which is the failure the current `parent-level-ambiguous` message embodies. FR-028 forbids naming a type by an identifier in any message. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The consumer instance described in the input — two types at the specification level,
  thirteen at the story level, two sub-task types — configures successfully and mirrors a
  specification end to end, where today it cannot complete configuration at all.
- **SC-002**: An operator who has never read the documentation can resolve an ambiguous hierarchy
  using only what the failing run prints, without opening the source or the schema.
- **SC-003**: Configuration of an ambiguous project requires at most one answer per ambiguous
  role, and an unambiguous project requires none.
- **SC-004**: Two developers on the same repository, with independent local bindings, mirror new
  specifications into identical issue types once the mapping is committed — verified by deleting
  one binding, re-configuring, and comparing resolved types.
- **SC-005**: Every project that configures successfully before this change still configures
  successfully after it, with no edit to any committed file.
- **SC-006**: Every impossible mapping this specification enumerates is refused before any issue
  is created, with zero Jira writes on every one of them.
- **SC-007**: A second reconcile of an unchanged specification issues zero writes at every tier the
  mapping selects.

## Assumptions

- The consumer is unblocked by User Stories 1 and 2 alone. User Story 5 (the task tier) is
  additive and may ship in a later release without invalidating anything above it; it is specified
  here because the input asked for the third level explicitly.
- Roles are a closed set of three (`specification`, `story`, `task`). No mechanism for
  user-defined roles is introduced, and an unknown role name in the mapping is refused (FR-030).
- A repository declares at most one mapping per project entry. Two repositories routed to the same
  Jira project may declare different mappings; that is a feature of the per-repository
  configuration, not a conflict to detect.
- The tasks that would feed the `task` role are those recorded against a user story in the
  repository's own task artifact. The precise parsing of that artifact is a planning concern, not
  a specification one.
- Jira's own acceptance of a parent reference between two arbitrary levels is authoritative. Where
  a declared pairing is structurally valid by level but rejected by Jira, FR-017's parent-link
  check is the mechanism that surfaces it, at configuration time.
- The closed questions this feature adds are asked by the command layer that already asks the
  project-key, style, estimation-field and status-classification questions, on the same terms.

## Out of Scope

- **Routing different specifications to different issue types within one project.** The consumer's
  level 1 holds `Epic` and `Service Category`; a repository declares one of them. Choosing per
  specification — so that some features mirror as `Service Category` — is a routing feature, not a
  hierarchy-mapping one, and no consumer has asked for it.
- **Mapping the remaining eleven story-level types to anything.** `Test`, `Test Set`,
  `Test Execution`, `Precondition`, `Release`, `Incident SNOW`, `Objective`, `Service`,
  `Problem SNOW` and the rest are types the repository has no artifact for. They appear in the
  candidate list because the project reports them; the bridge does not acquire a meaning for them.
- **Supplying values for mandatory custom fields.** Unchanged from feature 008: this feature runs
  the existing gate over the newly reachable types (FR-018) and refuses cleanly. The configuration
  surface for field values remains a separate feature.
- **Migrating issues already created under a previous mapping.** A changed mapping applies to
  issues created after it. Existing recorded tickets are recognised by their recorded identifiers
  and are neither re-typed, re-parented, nor reported as drift on the basis of their type.
- **Retiring or cancelling issues for artifacts removed from the repository.** Unchanged.
- **A general unknown-key check inside project entries.** Still the separate change feature 008
  identified; this feature refuses unknown *role* names within its own mapping (FR-030), which is
  narrower.
