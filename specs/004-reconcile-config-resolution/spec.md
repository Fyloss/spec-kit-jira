# Feature Specification: Reconcile Resolves Its Own Routing and Plan Context From Config

**Feature Branch**: `004-reconcile-config-resolution`

**Created**: 2026-07-28

**Status**: Draft

**Input**: User description: "Bugs reported by a downstream project consuming this Spec Kit extension. Problem 1 — routing is never applied by the dispatcher: `reconcile` reads the project key from an environment variable and falls back to the placeholder `PROJ`, but neither the dispatcher nor the shim ever reads config.yml to populate it. Problem 2 — the plan context (issue type, priorities) is never injected automatically: without `SPEC_KIT_JIRA_PLAN_CONTEXT` the payload sent to Jira carries no issue type and no priority, even though those values exist in config.local.yml. Symptom: `spec-kit-jira reconcile` errors as if the `project` field were missing from the Jira payload, which the Jira API requires for `/rest/api/3/issue`."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A bound repository mirrors to the right project without any environment setup (Priority: P1)

A developer has run the binding ceremony on their repository: the committed team config declares the projects and the routing rules, and the machine-owned local layer holds the binding discovered from Jira. They finish a spec and a lifecycle hook fires the mirror. The mirror must send the work to the project the routing rules designate for that spec — with no environment variable, no manual export, and no shell wrapper on their part.

**Why this priority**: This is the reported defect and it is total. Today every run of a correctly configured repository either targets the literal placeholder `PROJ` — a project that does not exist on the customer's site — or is rejected outright. Nothing the extension writes reaches its destination, so no other capability of the mirror is observable until this is fixed. Fixing it alone restores the product's core promise.

**Independent Test**: Configure a repository with a routing rule and a default project, invoke the mirror on a spec folder with no extension environment variables set at all, and confirm the planned write set names the project the rules designate — and never the placeholder.

**Acceptance Scenarios**:

1. **Given** a bound repository whose team config declares a routing rule matching the spec folder's prefix, and no mirror-related environment variables set, **When** the mirror runs on a spec in that folder, **Then** every planned write targets the project named by that rule.
2. **Given** a bound repository whose team config declares only a default project (no rule matches the spec folder), **When** the mirror runs, **Then** every planned write targets the default project.
3. **Given** a bound repository whose team config declares neither a matching rule nor a default project, **When** the mirror runs, **Then** no write is attempted, and the operator is told that routing could not be resolved and which config key would resolve it.
4. **Given** a repository whose team config still carries the shipped placeholder project key, **When** the mirror runs, **Then** no write is attempted and the operator is told the binding is still a placeholder and how to complete it.
5. **Given** a bound repository, **When** the mirror runs in prediction mode, **Then** the predicted write set names exactly the same project as a real run against the same inputs.
6. **Given** a bound repository with a resolved project, **When** the mirror plans the creation of a work item, **Then** the creation payload itself declares that project — verifiable by inspecting the planned payload, without contacting Jira.

---

### User Story 2 - Created work items carry the issue type and priority the binding already discovered (Priority: P1)

The same developer's mirror now reaches the right project, but Jira refuses to create anything because the payload declares no issue type. The binding ceremony already asked Jira for the project's issue types, priorities and estimation field and persisted them in the machine-owned local layer. The mirror must read that persisted table for the project it just resolved and build the creation payload from it — again with no manual injection.

**Why this priority**: Equal in severity to routing, and inseparable from it in practice: a run that resolves the right project but omits the issue type is still rejected by Jira, so the developer sees the same failed mirror. Both must land for a single run to succeed end to end. It is listed second only because it consumes the project key that story 1 produces.

**Independent Test**: With a project resolved and a persisted binding present, run the mirror in prediction mode and confirm each planned creation declares the issue type mapped to the extension's Story concept and the priority mapped from the spec's declared priority — with no plan-context environment variable set.

**Acceptance Scenarios**:

1. **Given** a resolved project whose persisted binding maps the Story concept to an issue type identifier, **When** the mirror plans a creation, **Then** the planned creation declares that identifier as its issue type.
2. **Given** a spec that declares a priority, and a team config that maps that priority level to a logical Jira priority whose identifier the binding resolved, **When** the mirror plans a creation, **Then** the planned creation declares that priority identifier.
3. **Given** a resolved project whose persisted binding names an estimation field, **When** the mirror plans a creation, **Then** the declared estimation is written on creation only and is never re-sent on a later update.
4. **Given** a resolved project for which no persisted binding exists yet, **When** the mirror runs, **Then** no creation is attempted, and the operator is told the project has not been bound yet and which command binds it.
5. **Given** both a committed team-config value and a machine-owned discovered value for the same issue type, **When** the mirror builds the payload, **Then** the machine-owned discovered value is used.

---

### User Story 3 - A misconfiguration is reported in the operator's language, not as a Jira rejection (Priority: P2)

An operator whose repository is partly configured — a project renamed on the Jira site, a routing rule pointing at a project absent from the config, a binding never refreshed after a new project was added — runs a lifecycle command. Instead of an opaque API rejection mentioning a missing `project` field, they get one message naming the actual cause and the one command that fixes it. The lifecycle command they were actually running still completes normally.

**Why this priority**: It converts the class of failure this feature is about from silent and mystifying into self-service. It is P2 because a correct configuration never reaches it, but without it every future configuration mistake reproduces the original support burden.

**Independent Test**: Run the mirror against each incomplete-configuration state in turn and confirm each produces its own distinct, actionable message, attempts zero writes, and leaves the host lifecycle command's outcome untouched.

**Acceptance Scenarios**:

1. **Given** a routing rule naming a project that the team config does not declare, **When** the mirror runs, **Then** the operator is told which rule names which unknown project, and no write is attempted.
2. **Given** any resolution failure while the mirror is running as a lifecycle hook, **When** the run ends, **Then** the host lifecycle command reports success and exactly one warning is surfaced.
3. **Given** the same resolution failure while the mirror is invoked directly, **When** the run ends, **Then** the run fails with the configuration outcome and no write was attempted.
4. **Given** any resolution failure, **When** the message is emitted, **Then** it names no Jira site host and no credential.

---

### User Story 4 - A team-managed project mirrors as correctly as a company-managed one (Priority: P2)

A developer whose repository is bound to a team-managed project runs the mirror. The project is required in the payload exactly as it is for a company-managed project — that part does not vary. What does vary is everything around it: the project owns its own issue types rather than sharing a scheme, it may have priorities switched off entirely, and it names its estimation field differently. The mirror must build a payload the project actually accepts, in either style, without the operator being asked which style they are on.

**Why this priority**: The customer who reported the defect is on one style; the extension ships to both. A mirror that only assembles valid payloads for one style trades a total failure for a silent one — the run reports success while the destination rejects half the attributes, or the run fails on an attribute the project never supported. It is P2 rather than P1 because the reported failure reproduces in both styles and stories 1 and 2 remove it in both; this story stops the fix from being style-specific.

**Independent Test**: Bind the same specification to a company-managed project and to a team-managed one, plan the creations for each, and confirm each payload declares the project, declares an issue type belonging to that project, and declares no attribute the project does not accept.

**Acceptance Scenarios**:

1. **Given** a resolved team-managed project, **When** the mirror plans a creation, **Then** the payload declares the project, exactly as it does for a company-managed project — the project is not conditional on style.
2. **Given** two bound projects of different styles, **When** the mirror plans creations for each, **Then** each payload declares an issue type belonging to that project, and never one resolved for the other.
3. **Given** a resolved project on which priorities are unavailable, **When** the mirror plans a creation, **Then** no priority is declared and the run completes without error.
4. **Given** a resolved project whose estimation field is named differently from another bound project's, **When** the mirror plans a creation, **Then** the estimation is written to the field that project declares.
5. **Given** any resolved project, **When** the mirror decides which attributes to declare, **Then** the decision comes from what that project declares it accepts, not from a built-in rule keyed on the project's style.

---

### Edge Cases

- A spec folder matches several routing rules: the first declared match wins, deterministically, so two runs on the same inputs never disagree.
- A routing rule declares no condition at all (the shipped template's placeholder rule): it matches nothing rather than becoming a match-everything rule that shadows every later rule and the default.
- The spec declares a priority level the team config does not map, or maps to a logical priority the binding never resolved: the item is still created, without a priority, rather than the whole run failing.
- The machine-owned local layer is missing entirely (a fresh clone, never bound): treated as "not bound yet", one notice, zero writes, and the host command unaffected — not as a fault.
- The machine-owned local layer exists but holds no entry for the resolved project (a project added to the config after the last binding run): reported as that specific cause, distinctly from "never bound".
- The team config is unreadable or fails validation: the existing configuration outcome applies, and no partially-resolved payload is ever sent.
- The spec declares no labels: routing rules conditioned on a label simply do not match; folder-prefix rules, team routes and the default still resolve normally.
- An operator has set the mirror's project or plan-context environment variables deliberately: their values are honoured ahead of the config, so existing automated tests and advanced invocations keep working unchanged.
- The resolved project key is syntactically invalid or is the shipped placeholder: refused before any network call.
- A creation payload is assembled with a correctly resolved project that never reaches the payload: caught as an incomplete payload before dispatch, not discovered as a rejection from the destination service.
- The mirror path and the single-item creation path disagree on what a creation payload contains: treated as a defect in its own right, since only one of the two currently produces a valid creation.
- A repository binds two projects of different styles: each keeps its own issue-type, priority and estimation identifiers, and neither project's identifiers are ever used for the other.
- The resolved project's style could not be determined at binding time: payload assembly still succeeds, because it depends on what the project reports it accepts rather than on the style being known.
- Priorities are unavailable on the resolved project: creations are planned without a priority rather than the priority being sent and rejected, or the run failing.
- The persisted binding holds a priority identifier the resolved project does not actually offer: the priority is omitted rather than sent, since the project's own declaration outranks a site-wide list.

## Requirements *(mandatory)*

### Functional Requirements

#### Routing resolution

- **FR-001**: The mirror MUST resolve the target project itself, from the repository's committed team config and the spec file path it was given, without requiring any caller to pre-populate an environment variable.
- **FR-002**: Resolution MUST apply the team config's declared routing rules against the spec folder's name and the spec's declared labels, taking the first declared rule whose every declared condition holds.
- **FR-003**: When no routing rule matches, resolution MUST fall back to the team-declared default project.
- **FR-004**: A routing rule that declares no condition MUST NOT match any spec.
- **FR-005**: The mirror MUST NOT fall back to any built-in placeholder project key. A resolved key that is absent, syntactically invalid, or equal to the shipped placeholder MUST block every write for that run.
- **FR-006**: The mirror MUST resolve the epic strategy for the run from the resolved project's own declaration in the team config, rather than from a built-in default.

#### Plan context resolution

- **FR-007**: For the resolved project, the mirror MUST build the creation context — issue type identifier for the Story concept, priority identifiers per declared priority level, and estimation field identifier — from the persisted binding, without requiring any caller to inject it.
- **FR-008**: Priority resolution MUST follow the two declared steps: the team config maps a spec priority level to a logical Jira priority name, and the persisted binding maps that logical name to its identifier.
- **FR-009**: Where the same value exists in both the committed team config and the machine-owned persisted binding, the persisted binding MUST win.
- **FR-010**: When the resolved project has no persisted binding, the mirror MUST attempt no creation and MUST report that specific cause.
- **FR-011**: A priority that cannot be resolved MUST NOT block the run; the affected item is planned without a priority.
- **FR-012**: The declared estimation MUST continue to be written on creation only and never re-sent on update.

#### Precedence, diagnostics and safety

- **FR-013**: An explicitly set mirror environment variable for the project key or the creation context MUST take precedence over the config-derived value, so existing invocations and automated tests are unaffected.
- **FR-014**: Every resolution failure MUST be reported as its own distinct, named cause — unresolvable routing, placeholder binding, unknown project in a rule, project not bound yet — each naming the single command that remedies it.
- **FR-015**: A resolution failure occurring while the mirror runs as a lifecycle hook MUST leave the host lifecycle command's outcome untouched, surfacing exactly one warning.
- **FR-016**: A resolution failure occurring on a direct invocation MUST fail with the configuration outcome.
- **FR-017**: No resolution failure may result in a partial write: any run that cannot fully resolve its project and creation context MUST attempt zero writes.
- **FR-018**: Diagnostics emitted by resolution MUST contain no Jira site host and no credential.
- **FR-019**: Resolution MUST be performed before any network call to Jira.
- **FR-020**: Prediction mode MUST resolve routing and creation context by exactly the same path as a real run, so the predicted write set equals the real one for identical inputs.
- **FR-021**: Both supported script ports MUST resolve routing and creation context identically, producing byte-identical run summaries for identical inputs.

#### Creation payload completeness

- **FR-022**: Every planned creation MUST declare the target project in the payload itself. Resolving the project correctly is not sufficient — the resolved key MUST reach the outgoing creation request, because the destination service rejects any creation that omits it.
- **FR-023**: The project declared in a creation payload MUST be the project routing resolved for that spec, and MUST equal the project reported in the run summary and in the prediction report.
- **FR-024**: A creation payload that would be dispatched without a project, or without an issue type, MUST be refused before dispatch rather than sent and rejected by the destination service.
- **FR-025**: Payload completeness MUST hold on the mirror path exactly as it already does on the path that creates a single work item during the feature ceremony, so the two creation paths cannot disagree on what a valid creation contains.

#### Project style independence

- **FR-026**: The project MUST be declared in every creation payload regardless of the resolved project's style. This requirement is unconditional: no style, setting or configuration may make the project optional.
- **FR-027**: The issue type declared for a creation MUST be one the resolved project itself declares. An identifier resolved for one project MUST NOT be used for another, since a project may own its issue types privately rather than share them.
- **FR-028**: The mirror MUST determine which attributes a creation may declare from what the resolved project reports it accepts, rather than from a rule keyed on the project's style. Style is recorded for reporting and for hierarchy validation; it MUST NOT be the basis for deciding payload contents.
- **FR-029**: An attribute the resolved project does not accept — most commonly a priority on a project where priorities are unavailable — MUST be omitted from the payload rather than sent and rejected, and its omission MUST NOT fail the run.
- **FR-030**: Attributes whose identity differs between projects — notably the estimation field — MUST be resolved per project from that project's own declaration, never from a value shared across projects or discovered site-wide.
- **FR-031**: Where the persisted binding currently holds a value discovered site-wide that is in fact per-project, the binding MUST be corrected to record it per project, so a project that scopes that value privately is not mirrored with another project's identifiers.

### Key Entities

- **Team config (committed)**: The credential-free, human-authored layer declaring the projects, their issue-type and priority mappings, their epic strategy, the routing rules and the default project.
- **Machine-owned local binding (not committed)**: The layer the binding ceremony writes, holding per project the identifiers discovered from Jira for issue types, priorities, statuses and the estimation field, plus operator overrides.
- **Spec reference**: The identity of the specification being mirrored — its folder, its slug, and the declared labels routing rules may test.
- **Routing decision**: The single project key a spec resolves to, plus the rule or default that produced it.
- **Creation context**: The resolved-identifier bundle a creation payload needs — issue type, priority per level, estimation field.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | This feature is the principle's enforcement: routing and creation identifiers are read from the repository's config layers, which become the sole source of the values the mirror sends. No new source of truth is introduced. |
| II | Zero-Churn Idempotency | Unaffected in mechanism, and required in outcome: FR-020 makes prediction and real runs resolve identically, and FR-012 keeps estimation create-only, so a second run on unchanged inputs still produces no write. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-017 makes every unresolved run write nothing; FR-016 fails a direct invocation closed; FR-015 keeps the host lifecycle command's outcome untouched under a hook. FR-024 extends fail-closed to payload assembly: an incomplete creation is refused before dispatch rather than left for the destination service to reject. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | No credential is read, written or resolved by this feature. FR-018 forbids any credential or site host in the new diagnostics. |
| V | Separation of Team Config / Local Binding / Secrets | The feature reads both non-secret layers in their declared roles and writes neither. FR-009 encodes the precedence the separation implies: discovered identifiers are machine-owned and authoritative over committed ones. |
| VI | macOS / Linux / Windows Portability | FR-021 requires identical resolution and byte-identical summaries across both supported script ports; both ports carry the same defects today and both are in scope, including the payload and style requirements. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | This feature removes the two hard-coded assumptions that caused the bug — the placeholder project key (FR-005) and the implicit empty creation context — replacing both with configured, discovered values. FR-028 forbids introducing a third: payload contents are decided from what the project reports it accepts, never from a rule keyed on its style. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Resolution feeds the existing interface rather than widening it: the engine still receives a neutral routing decision, and the sink still receives a creation context. FR-022 is satisfied on the sink side of the boundary — the routing decision the engine already carries is what the sink must render into the payload. No Jira-shaped value crosses into the engine. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. The guard remains the mandatory pre-write gate; resolution happens strictly before it and adds no bypass. |
| X | Self-Healing Automatic Mirror | Directly advanced: the mirror stops depending on a caller-supplied environment and configures itself from the repository, which is what makes it automatic for a developer who set nothing up beyond the binding ceremony. |
| XI | Universal Dry-Run and Auditability | FR-020 makes prediction traverse the same resolution path as a real run; the resolved project appears in the predicted write set, so an operator can audit routing without writing. |
| XII | Quality and Catalog Publication | Unaffected in scope; the change is a defect fix within existing commands and adds no catalog surface. |
| XIII | TDD With a Minimum 80% Coverage | The reported defect is reproducible without Jira: each acceptance scenario is expressible as a failing test on the planned write set before the fix, per the project's bug-fix policy. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | The feature wires existing, already-tested pieces — the routing resolver, the config loader, the persisted identifier table — into the one command that never called them. It introduces no new config key, no new file and no new format. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Scope is exactly the three defects on the reported failure path plus the diagnostics that make their recurrence self-service. No caching, no new routing condition, no config schema extension. |
| XVI | Human Readable — Readable by a Human Above All | The user-facing outcome is a readable cause instead of an API rejection (FR-014); each message names one cause and one remedy. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A developer who has completed the binding ceremony can mirror a spec successfully with zero environment variables set — the setup step count for a working mirror drops from "unknown and undocumented" to zero.
- **SC-002**: 100% of runs against a correctly configured repository send a real, configured project key; the placeholder key appears in zero outgoing payloads.
- **SC-003**: 100% of planned creations against a bound project declare an issue type, eliminating the reported rejection class entirely.
- **SC-004**: Every one of the four incomplete-configuration states produces a distinct message that names both the cause and the single remedying command; an operator can identify the cause from the message alone, without inspecting config files.
- **SC-005**: Zero writes occur on any run that cannot fully resolve its project and creation context.
- **SC-006**: A prediction run and a real run on identical inputs report the same project and the same action set, verified byte for byte.
- **SC-007**: Both supported script ports produce byte-identical run summaries for identical inputs.
- **SC-008**: No lifecycle command fails because of a mirror resolution failure, in any of the states above.
- **SC-009**: 100% of planned creations declare a project, verified by inspecting the planned payloads with no service contact; the reported "the project field is required" rejection is unreproducible against a bound repository.
- **SC-010**: The mirror path and the feature ceremony's creation path produce payloads carrying the same mandatory set of declared attributes, so a creation valid on one path is valid on the other.
- **SC-011**: The same specification mirrored against a company-managed project and a team-managed project produces a valid creation in both cases, with zero style-specific configuration asked of the operator.
- **SC-012**: Zero creation payloads declare an attribute the resolved project does not accept, so the "field cannot be set / not on the appropriate screen" class of rejection occurs zero times.
- **SC-013**: In a repository binding projects of different styles, zero payloads carry an identifier resolved for a different project.

## Assumptions

- **Three defects, not two, sit on the reported failure path.** The report named two causes (routing never resolved, creation context never built). Specification work found a third and independent one: the mirror's creation payload declares no project at all, so the resolved key would never reach the request even once the first two are fixed. This is precisely the reported symptom — "an error, as if the `project` field were missing from the payload" — and it is why the report's own proposed fix, taken alone, would not have made a single mirror run succeed. All three are in scope (FR-022 to FR-025); fixing any two of them still leaves the mirror broken. A fourth, latent one is covered by FR-031 (see the style entries below).
- **The project is required in both project styles; what surrounds it is not.** The declared project is unconditional — no style makes it optional, since it is what scopes the created item and its issue type. The style-sensitive parts are the ones around it: a project may own its issue types privately rather than share a scheme, may have priorities unavailable, and may name its estimation field differently. The spec therefore fixes the project as mandatory (FR-026) and makes everything else follow the project's own declaration rather than its style (FR-028).
- **Style is used for reporting and hierarchy validation, not for payload assembly.** The binding already records a per-project style and already refuses hierarchy levels a team-managed project cannot support. This spec deliberately does not extend style into payload decisions: branching payload contents on style would be exactly the hard-coded workflow assumption Principle VII forbids, and it would be wrong the first time a project is configured unusually for its style.
- **One binding value is currently discovered site-wide and must become per-project.** Issue types and estimation candidates are already discovered per project, so they are correct as they stand. Priorities are not: they are read from the site-wide priority list and then stored per project, which misrepresents any project that scopes priorities privately or has them unavailable. FR-030 and FR-031 cover the correction. This was found during specification, not reported.
- **Environment variables become overrides, not the mechanism.** The user's report asks for resolution "without depending on an external variable". This spec keeps the existing variables working as explicit overrides taking precedence over config (FR-013), rather than removing them: they are exercised by the existing test suite and by advanced invocations, and removing them would be a breaking change beyond the reported defects. The defect is fixed by making config the fallback in place of the placeholder, not by deleting the override path.
- **The binding ceremony is a prerequisite, not part of this feature.** A project with no persisted binding is reported, not discovered on the fly: resolution performs no Jira reads (FR-019), so the mirror never silently re-runs discovery.
- **"Never bound" stays a notice, not a failure.** A repository with no local binding layer at all remains the normal state of a fresh install and keeps its existing one-notice, exit-zero behaviour; only a *partially* configured repository produces the new named causes.
- **Labels are read from the spec as declared.** Label-conditioned routing rules are honoured on the labels the specification declares; where a spec declares none, such rules simply do not match. Extending what the parser extracts is out of scope.
- **Both script ports are in scope.** The defect was reported against one port but exists identically in both; portability (Principle VI) makes fixing only one port a violation.
- **No configuration format changes.** Every key this feature reads already exists in the shipped config schemas; no migration is required of any existing repository.
- **The mirror's write-time guards are unchanged.** The privacy guard, the drift handling and the lifecycle filtering keep their current behaviour; this feature only determines what the payload's project and creation context contain.
