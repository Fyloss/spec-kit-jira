# Feature Specification: A pass-through says which state produced it

**Feature Branch**: `fix/diagnose-inactive-team-selection`
**Created**: 2026-08-24
**Status**: Draft
**Input**: A feature-naming run that resolves to no team is indistinguishable from every other reason it could have resolved that way. The goal is that an inactive resolution becomes diagnosable without breaking the deliberate silence FR-017 of spec 002 requires.

## Context — five states, one output

`speckit.jira.feature` names a feature by the developer's team convention, or
passes through unchanged. The pass-through carries a single fact — `active:
false` — and **five** distinct states produce it. With no ticket mentioned, all
five are byte-identical and say nothing at all:

| # | State | Today, no mention | Today, ticket mentioned |
| --- | --- | --- | --- |
| A | No `config.yml` at the consulted path | silent | names the file, names the command |
| B | `config.yml` present but unloadable — malformed YAML, schema violation, credential-shaped value | **silent, diagnostic discarded** | names the file, names the command |
| C | `config.yml` valid, `teams:` declares zero entries | silent | names the file, names the command |
| D | No `personal.yml` | silent | names the file, names the selection |
| E | `personal.yml` present, no `team` key | silent | names the file, names the selection |

Two properties of that table are the defect.

**State B destroys a diagnosis it already computed.** The configuration loader
produces a located error for a malformed file — the line, the key, the reason.
The feature command discards that error stream and reports the same nothing it
reports for a repository that never adopted the extension. An operator who
wrote a `config.yml` and made a typo is told, in effect, that they never wrote
one.

**State A cannot be observed at all.** The consulted path is relative, so it is
resolved against whatever working directory the process happened to start in. A
hook invoked from anywhere but the workspace root consults a path that does not
exist and takes state A. Nothing distinguishes that from a repository that
genuinely has no configuration — not the output, not the exit code, not the
filesystem, because the file the operator is looking at is real and correct.
This is what a reporting workspace hit: a developer with a valid, freshly saved
selection was named without their prefix, found the file intact afterwards, and
concluded their editor had raced the hook. It had not.

The silence is not accidental. FR-017 of spec 002 requires that a repository
with no team selected behave exactly as it did before the extension existed —
no prefix, no prompt, no warning — and FR-028 of spec 029 extends that to a run
that mentions nothing, on the stated ground that *"the guidance of FR-026 is
owed only to an operator who named something."* Two conformance scenarios pin
it. This specification does not weaken that principle; it applies it.

**Writing a configuration file is naming something.** A file that exists and
fails is an operator statement that did not work, and it is owed an answer. A
file that does not exist is not a statement at all, and is owed silence. That
distinction is the whole feature.

## Clarifications

### Session 2026-08-24

- Q: Should repository-root resolution replace working-directory resolution, or
  be a fallback consulted only when the working-directory path finds nothing?
  → A: Replace it. An explicitly set `JIRA_CONFIG_DIR` remains authoritative,
  so a deliberately nested configuration stays reachable by explicit opt-in
  rather than by accident of starting directory.
- Q: A personal file that exists and cannot be loaded currently fails the run
  with exit 4. Should that remain, or become a report plus pass-through?
  → A: Report plus pass-through, exit 0 — the same treatment FR-001 gives the
  team configuration. Both files behave alike and feature creation is never
  blocked.
- Q: Is a valid configuration declaring zero teams a supported reconcile-only
  setup that must stay silent, or a configuration owed a report?
  → A: Supported, and silent. It is the single-project setup, which works
  end to end: with no team prefix on the folder no routing rule and no implicit
  team route match, and `routing_default` carries every specification to the
  one project. An operator who did intend naming is already told loudly.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A broken configuration announces itself (Priority: P1)

A developer edits `.specify/jira/config.yml` — adds a team, fixes an id, pastes
a block — and introduces a syntax error or a schema violation. They run the
feature command. Today the run passes through in silence and their feature is
named without the prefix; the loader's located error was computed and thrown
away. They now see that error: the file, the reason, and the fact that naming
fell back to the host's default.

**Why priority**: it is the only state in the table that is unambiguously a
misconfiguration, the only one whose diagnosis already exists and is discarded,
and the only one where silence actively misleads — it reports "not configured"
about a repository that is configured, badly.

**Independent Test**: place a `config.yml` with a known malformed line in a
repository with no personal selection, run the feature command naming no
ticket, and observe the located error and the pass-through. Delivers value
alone: no other story needs to ship.

**Acceptance Scenarios**:

1. **Given** a repository whose `config.yml` contains a YAML syntax error and
   no ticket is mentioned, **When** the feature command runs, **Then** it
   reports the file and the reason the file could not be read, names the
   default naming it fell back to, and exits successfully without contacting
   Jira.
2. **Given** a repository whose `config.yml` parses but violates the schema
   (an unknown key, a team with no `id`), **When** the feature command runs,
   **Then** the report names the offending key or entry rather than stating
   only that the file is invalid.
3. **Given** a repository with **no** `config.yml` at all and no ticket
   mentioned, **When** the feature command runs, **Then** the output is
   byte-identical to the current release — no report, no prefix, no prompt.
4. **Given** a repository with a valid `config.yml` and no personal selection,
   **When** the feature command runs naming no ticket, **Then** the output is
   byte-identical to the current release.
5. **Given** a repository whose `personal.yml` exists and cannot be loaded,
   **When** the feature command runs, **Then** it reports the file and the
   located reason, names the default naming it fell back to, and exits
   successfully — where today it exits with a configuration error code.

---

### User Story 2 - The configuration is found from the repository, not the shell (Priority: P2)

A developer works in a multi-repository workspace, or a tool invokes the hook
with a working directory that is not the workspace root. Their configuration is
present and valid, but the run consults a path that does not exist and passes
through as though nothing were configured. They now get the same result
wherever the process starts.

**Why priority**: it removes the one state an operator cannot observe by any
means, and it is what turns state A from "ambiguous" into "genuinely absent" —
without which User Story 1's silence-for-absent-file rule rests on a path that
may simply be wrong.

**Independent Test**: place a valid configuration and personal selection at the
repository root, invoke the feature command from a subdirectory, and observe
the same naming as from the root.

**Acceptance Scenarios**:

1. **Given** a valid configuration and a personal selection naming team `ijt`
   at the repository root, **When** the feature command runs from a
   subdirectory of that repository, **Then** the feature is named by the `ijt`
   convention exactly as it is when run from the root.
2. **Given** the same repository, **When** the feature command runs from the
   root, **Then** the result is unchanged from the current release.
3. **Given** a directory that is not inside any repository, **When** the
   feature command runs, **Then** it reports that it could not locate a
   repository to read configuration from, rather than passing through in
   silence.

---

### User Story 3 - An operator can ask which state produced a pass-through (Priority: P3)

A developer whose feature was named without their prefix wants to know why,
without changing what anyone else sees. They re-run with the existing verbose
diagnostic and are told which state applied, and what would change it.

**Why priority**: it makes every remaining state diagnosable on demand while
leaving all default output — the output two conformance scenarios pin — exactly
as it is. It is the cheapest possible answer to "which one was it", and it is
opt-in by construction. Its value is not confined to naming: in a repository
mirroring to several projects, an unnoticed pass-through is followed by a
default routing that is equally silent, so being able to ask why no team
applied is what surfaces both.

**Independent Test**: run the feature command with the verbose diagnostic in a
repository in each state and confirm each is named distinctly.

**Acceptance Scenarios**:

1. **Given** any resolution state, **When** the feature command runs with the
   verbose diagnostic requested, **Then** the state is named explicitly along
   with the file consulted and the resolved path it was consulted at.
2. **Given** any resolution state, **When** the verbose diagnostic is **not**
   requested, **Then** the default and machine-readable outputs are unchanged
   from what User Stories 1 and 2 define.

---

### Edge Cases

- A `config.yml` that is present but empty parses to an empty document. This is
  a normal state, not a malformed file, and must not be reported as one.
- A `personal.yml` that is present but empty is likewise normal — the
  configuration ceremony writes a file whose `team:` line is left commented.
- A repository whose `config.yml` is valid and declares a `routing:` table but
  no `teams:` uses the extension for reconciliation without team naming. That
  is a supported configuration, not a misconfiguration (state C).
- A file that exists but cannot be read for permission reasons is a failure to
  read, not an absent file, and belongs with state B.
- Two configuration directories — one at the repository root, one in the
  working directory — must resolve deterministically, and the run must be able
  to say which one it used.
- A repository root that cannot be determined (no repository, or a detached
  environment) must not silently fall back to a path that happens to exist.
- A repository mirroring to **several** Jira projects with no team selected has
  no team prefix on its folders, so no routing rule and no implicit team route
  match and every specification is carried to `routing_default` — silently, and
  into one project regardless of which team the work belongs to. Observed, and
  deliberately **out of scope**: that silence belongs to the reconcile step, not
  to naming, and repairing it is a separate specification. It is recorded here
  because it is the same defect class one step downstream, and because it is
  what makes the diagnostic of FR-010 worth more than a naming convenience.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A configuration file that exists and cannot be loaded MUST be
  reported, naming the file and the reason it could not be loaded, whether or
  not a ticket was mentioned.
- **FR-002**: That report MUST carry the located detail the loader already
  produces — the offending key, entry, or line — and MUST NOT be reduced to a
  statement that the file is invalid.
- **FR-003**: That report MUST NOT block feature creation: naming falls back to
  the host's default, the run exits successfully, and no Jira request is made.
- **FR-004**: A configuration file that does not exist MUST remain silent when
  no ticket is mentioned, byte-identical to the current release.
- **FR-005**: A valid configuration with no team selected in the personal file
  MUST remain silent when no ticket is mentioned, byte-identical to the current
  release — whether the personal file is absent or present without a `team`
  key.
- **FR-006**: A configuration file that is present and empty MUST be treated as
  a normal, unconfigured state and MUST NOT be reported as unloadable.
- **FR-007**: The configuration directory MUST be resolved relative to the
  repository the run belongs to, not to the process working directory, so that
  the same repository state yields the same result from any starting directory.
- **FR-008**: When no repository can be determined, the run MUST say so rather
  than pass through in silence.
- **FR-009**: Every report introduced by this feature MUST name the path it
  actually consulted, resolved, not the relative form it was written as.
- **FR-010**: When the verbose diagnostic is requested, a pass-through MUST
  name which resolution state produced it, and what would change it. The
  states are the set enumerated in the design's data model, which is wider
  than the Context table above: that table describes today, where an unloadable
  file is indistinguishable from an absent one and a missing repository is not
  distinguishable at all.
- **FR-011**: When the verbose diagnostic is not requested, the default and
  machine-readable outputs of every state MUST be exactly what FR-001 through
  FR-008 define, with no additional field or line.
- **FR-012**: The behaviour of every requirement here MUST be identical on both
  supported platforms, with identical exit codes and byte-identical output for
  identical inputs.
- **FR-013**: A personal file that exists and cannot be loaded MUST receive the
  same treatment FR-001 through FR-003 give the team configuration: a report
  naming the file and the located reason, naming fallback to the host's
  default, a successful exit, and no Jira request. It MUST NOT fail the run.
  This replaces the current behaviour, which exits with a configuration error
  code — the inverse of the asymmetry this feature exists to remove, and a
  contradiction of the requirement that this step never blocks feature
  creation.
- **FR-014**: The repository-root resolution of FR-007 MUST REPLACE
  working-directory resolution rather than supplement it. A fallback order
  would leave two possible answers for one repository and would still select a
  nested directory that merely happens to exist, which is the defect FR-007
  exists to remove.
- **FR-015**: An explicitly set `JIRA_CONFIG_DIR` MUST continue to take
  precedence over the resolution of FR-014, so a deliberately nested
  configuration remains reachable by explicit opt-in rather than by accident of
  starting directory.
- **FR-016**: The resolution of FR-014 governs the whole configuration
  directory, including the run-state it holds alongside the two configuration
  files. A run whose state was previously written under a working-directory
  path MUST NOT be treated as a recognition failure when that state is no
  longer found: recognition is re-derived, and no duplicate is created.
- **FR-017**: A valid configuration declaring zero teams (state C) MUST remain
  silent. It is a supported setup, not a misconfiguration: a repository that
  mirrors specifications to a single project needs no team catalogue, and
  reporting it would make a correctly configured repository complain on every
  feature. The operator who did intend naming is already told loudly — a
  personal file selecting a team absent from the catalogue fails with a located
  error listing the valid ids, and that behaviour is unchanged.

### Key Entities

- **Resolution state**: which condition produced a pass-through. Every
  pass-through has exactly one, and it is what today's output omits. The
  Context table lists the five reachable today; the design's data model
  enumerates the full set, since this feature makes two more distinguishable.
- **Consulted path**: the absolute location the run actually read
  configuration from, as distinct from the relative form it is written as.
- **Load failure**: a file that exists and could not be turned into usable
  configuration, carrying the located detail of why — distinct both from an
  absent file and from a valid file that declares nothing.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth | Unaffected. This feature reads configuration and writes nothing to Jira; FR-003 makes every new report cost zero Jira requests, so no ticket is read, edited, or created on any path it introduces. |
| II | Zero-Churn Idempotency | Unaffected in Jira terms, and strengthened locally: FR-007 makes the same repository state produce the same result from any working directory, which is idempotency across invocation context rather than across runs. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-003 keeps the reporting path non-blocking — a report, the host's default naming, a successful exit. FR-013 repairs the one place where the shipped code already violates this principle: an unloadable personal file currently fails the run, which this feature replaces with the same report-and-continue treatment. No path introduced here can fail a host command. |
| IV | Credential Security | A credential-shaped value in a configuration file is one of the load failures FR-001 reports. FR-002 requires the located detail the loader produces, which refuses such values without echoing them; nothing this feature adds may print a value. |
| V | Separation of Team Config / Local Binding / Secrets | Preserved exactly. FR-004 and FR-005 keep the committed catalogue and the human-owned personal selection in their existing roles, and no requirement here writes either file. |
| VI | macOS / Linux / Windows Portability | FR-012 states it. FR-007 and FR-009 are the portability risk of this feature — repository-root resolution and absolute-path spelling are exactly where the two hosts diverge — so both are named as byte-identical obligations rather than left implicit. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. Nothing here reads a Jira workflow, status, type, or field. |
| VIII | Neutral Engine / Jira Sink | Unaffected. Configuration resolution and reporting are neither engine nor sink; no requirement moves Jira knowledge into the engine or configuration knowledge into the sink. |
| IX | Two-Tier Privacy Guard | Unaffected on the write path — this feature performs no write. FR-002's located detail must not become a channel for echoing a scanned value, which IV covers. |
| X | Self-Healing Automatic Mirror | Unaffected. Nothing changes what reconcile recognises or repairs. |
| XI | Universal Dry-Run and Auditability | FR-010's diagnostic is an auditability improvement: it makes an outcome explicable after the fact. The dry-run path gains no new effect, because this feature adds no effect. |
| XII | Quality and Catalog Publication | Unaffected. No manifest, packaging, or published-surface change is required. |
| XIII | TDD With a Minimum 80% Coverage | Each acceptance scenario is a failing test first. The four scenarios of User Story 1 are the regression pair — two that must newly speak, two that must stay byte-identical — and the byte-identical pair is what proves FR-004 and FR-005 were not broken in the process. |
| XIV | KISS | The feature adds no new configuration key, no new file, and no new flag: it reports a diagnosis that is already computed, resolves a path that is already read, and reuses the verbose diagnostic that already exists. |
| XV | YAGNI | Every requirement traces to an observed defect: FR-001/FR-002 to a discarded diagnosis, FR-007 to a misdiagnosed report from a real workspace, FR-010 to the inability to tell one pass-through state from another. Nothing is added for a state that has not been observed to mislead. |
| XVI | Human Readable | FR-002 and FR-009 are this principle applied: name the file, name the reason, name the resolved path — never a bare code, never a relative form the operator has to resolve themselves. |

## Success Criteria *(mandatory)*

- **SC-001**: A developer who introduces an error into their team configuration
  learns of it on the next feature run, without having to run any other
  command.
- **SC-002**: A developer with a valid configuration gets the same feature name
  from any directory inside their repository, in 100% of runs.
- **SC-003**: Every pass-through state is distinguishable from the others by an
  operator who asks, and indistinguishable by default output in exactly the
  cases the existing conformance corpus pins.
- **SC-004**: A repository that has never adopted the extension sees no output
  change of any kind — zero new lines, zero new fields.
- **SC-005**: Both supported platforms produce identical output and identical
  exit codes for each resolution state.
- **SC-006**: No run introduced by this feature issues a network request.

## Assumptions

- The verbose diagnostic named in FR-010 is the one that already exists; this
  feature does not introduce a flag. If that proves unworkable the requirement
  is unchanged — the diagnosis must be reachable on request without altering
  default output.
- "Byte-identical to the current release" is measured against the released
  behaviour of the two existing conformance scenarios covering the silent
  path, which remain the arbiter of FR-004 and FR-005.
- A repository is whatever the host already treats as the workspace root for
  locating specifications; this feature adopts that definition rather than
  introducing a second one.
- The reporting workspace's own conclusion — that an editor save raced the
  hook's read — is treated as incorrect. The relative-path resolution of state
  A explains the same observation without a race, and no evidence of a race was
  produced. FR-007 addresses the explanation that is demonstrable.
