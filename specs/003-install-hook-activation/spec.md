# Feature Specification: Hooks Active From Installation

**Feature Branch**: `003-install-hook-activation`

**Created**: 2026-07-28

**Status**: Draft

**Input**: User description: "When installing the extension on a consumer project, I noticed that by default the hooks are not implemented by the extension's official installation command. Fix that, and make the hooks non-optional and enabled. Also, when I tested the extension I got an error: `Jira hooks skipped: spec-kit-jira CLI not installed - Jira ticket creation and reconcile are non-blocking; re-run /speckit-jira-conifg after installing the CLI.`"

> The quoted error is reproduced verbatim as reported, including the misspelt
> command name (`/speckit-jira-conifg`) — that typo is itself part of the
> reported defect (see User Story 5 and FR-018).

## Overview

Installing the extension into a consuming repository with the official install
command currently produces a repository where **no lifecycle hook is
registered at all**. The bridge only becomes wired up if — and when — the
operator additionally runs the configuration ceremony, and even then the
registered hooks are declared as *suggestions* the assistant may skip rather
than steps it performs. A developer who installed the extension and started
working therefore gets a spec-kit lifecycle that never touches Jira, with no
signal that anything is missing, or — as reported — a confusing skip notice
naming a bridge executable the install never made runnable and a repair
command whose name is spelled wrong.

This feature makes the mirror **active on arrival**: the official install
registers every lifecycle hook, the hooks are enabled and performed rather
than offered, the bridge entry point is runnable straight after install with
no manual step, and every remaining degraded case produces one accurate,
correctly-named, actionable message instead of an error.

Two properties are deliberately kept apart throughout this specification,
because the reported problem conflates them:

- **Dispatch** — whether the assistant *performs* a registered hook or merely
  *offers* it. This feature makes dispatch mandatory.
- **Outcome propagation** — whether a hook failure fails the host spec-kit
  command. This stays **non-blocking**, exactly as today (Constitution III).

A mandatory hook is one that always runs; it is not one that is allowed to
break the developer's workflow.

A third property is settled here and applies throughout:

- **Registry ownership** — who may write the consuming repository's hook
  registry. Exactly one component may: the official Spec Kit install command.
  This extension reads that file and reports on it, and never writes to it —
  not to register, not to repair, not to realign. The registry is shared with
  the host, with other extensions and with the operator, who keeps comments and
  ordering in it; a co-owner that rewrites it is a co-owner that eventually
  destroys someone else's work.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - The mirror is wired up by the official install (Priority: P1)

A developer adds the extension to their repository with the official Spec Kit
install command and nothing else. When they next run any spec-kit lifecycle
step, the Jira bridge participates: the lifecycle hook registration is already
present in the repository's extension hook registry, enabled, and attributed
to this extension.

**Why this priority**: This is the reported defect and the entry point to
every other value the extension delivers. Without registration at install
time the extension is inert and the developer has no way to know it.

**Independent Test**: Can be fully tested by performing the official install
into a clean consuming repository and inspecting the repository's hook
registry: every lifecycle event this extension declares is present, enabled,
and attributed to the extension — with no configuration ceremony having been
run.

**Acceptance Scenarios**:

1. **Given** a consuming repository with no prior extension hook registry,
   **When** the developer performs the official install, **Then** a hook
   registry is created containing one entry from this extension for each
   declared lifecycle event, each marked enabled.
2. **Given** a consuming repository whose hook registry already contains
   entries from other extensions, **When** the developer performs the official
   install, **Then** this extension's entries are added and every pre-existing
   entry is preserved unchanged.
3. **Given** a repository where the install already registered the hooks,
   **When** the developer performs the install a second time (reinstall or
   upgrade), **Then** the registry contains exactly one entry per event from
   this extension — no duplicates and no stripped entries.
4. **Given** a freshly installed repository, **When** the developer inspects
   the install output, **Then** it states that the lifecycle hooks were
   registered and names the remaining step required before mirroring can
   reach Jira.

---

### User Story 2 - Registered hooks are performed, not merely offered (Priority: P1)

A developer runs a spec-kit lifecycle step in a repository where the extension
is installed and configured. The assistant performs the bridge step as part of
that lifecycle command — it does not present it as an optional suggestion the
developer must remember to trigger, and it does not silently skip it.

**Why this priority**: A registered-but-offered hook is functionally identical
to no hook at all for the majority of runs. Automatic mirroring — the core
promise of the extension — depends on the hook actually firing.

**Independent Test**: Can be fully tested by running each covered lifecycle
step in a configured repository and verifying the bridge step was performed
in every run, without the developer confirming or invoking anything.

**Acceptance Scenarios**:

1. **Given** an installed and configured repository, **When** any covered
   lifecycle step runs, **Then** the corresponding bridge step is performed as
   part of that run without developer confirmation.
2. **Given** the same repository, **When** the bridge step fails for any
   reason (unreachable Jira, refused write, missing prerequisite), **Then**
   the host lifecycle command still completes successfully and reports exactly
   one actionable warning.
3. **Given** an operator who has explicitly disabled one of this extension's
   hook entries, **When** any later install, upgrade or configuration ceremony
   runs, **Then** no bridge step is performed for that event afterwards —
   whatever the registry's `enabled` field says at that moment — and only an
   explicit operator action can restore it.
4. **Given** an operator who disabled an entry, **When** the corresponding
   lifecycle step runs, **Then** no bridge step is performed for that event
   and no warning is emitted about it.
5. **Given** an install that has re-enabled a disabled entry in the registry
   while the extension still holds it disabled, **When** the configuration
   ceremony runs, **Then** it reports the divergence, names the event and names
   the command that releases it — and does not edit the registry to resolve it.

---

### User Story 3 - Every registered hook resolves to a real command (Priority: P1)

Every lifecycle event registered by the install points at a command the
assistant can actually find and run in the consuming repository. No registered
event references a command that does not exist.

**Why this priority**: Registering hooks that reference a non-existent command
converts a silent no-op into a visible failure on every lifecycle step. It
must land together with User Story 1, not after it.

**Independent Test**: Can be fully tested by listing the commands the install
makes available in the consuming repository and cross-checking that every
registered hook entry names one of them.

**Acceptance Scenarios**:

1. **Given** a freshly installed repository, **When** the set of registered
   hook entries is compared with the set of installed commands, **Then** every
   registered entry names an installed command.
2. **Given** a freshly installed repository, **When** a covered lifecycle step
   fires its hook, **Then** the named command is found and executed — no
   "unknown command" outcome occurs.

---

### User Story 4 - The bridge runs straight after install (Priority: P1)

A developer whose machine satisfies the documented prerequisites installs the
extension and runs a lifecycle step. The bridge entry point is invoked
successfully with no manual installation, no path configuration, and no
environment setup beyond the credentials already documented.

**Why this priority**: This is the second half of the reported defect. Hooks
that fire but cannot reach a runnable bridge produce the exact skip notice the
developer saw, and leave the extension just as inert as unregistered hooks.

**Independent Test**: Can be fully tested by installing into a clean
repository on a machine that satisfies the prerequisites, running a lifecycle
step, and verifying the bridge entry point executed — with no step performed
between install and run.

**Acceptance Scenarios**:

1. **Given** a machine satisfying the documented prerequisites and a freshly
   installed repository, **When** a hook invokes the bridge, **Then** the
   bridge runs and reports its outcome, on both the Bash and PowerShell ports.
2. **Given** a machine missing a documented prerequisite, **When** a hook
   invokes the bridge, **Then** the host command still succeeds and exactly
   one warning names the missing prerequisite and how to satisfy it.
3. **Given** an install into a consuming repository, **When** the installed
   files are audited, **Then** nothing outside the repository — no
   machine-wide executable, no shell profile, no global search path — has been
   modified.

---

### User Story 5 - Degraded runs say something true and actionable (Priority: P2)

When the bridge genuinely cannot do its work — installed but not yet
configured, credentials absent, prerequisite missing — the developer gets one
short message that correctly states the cause and names the exact command that
resolves it, spelled correctly.

**Why this priority**: The reported message failed on all three counts: it
blamed a missing bridge executable that the install was responsible for, it
described the situation as an error when it was a normal not-yet-configured
state, and it named a repair command that does not exist because the name was
misspelled. Wrong guidance costs more support time than no guidance.

**Independent Test**: Can be fully tested by running a lifecycle step in each
degraded state and verifying, for each, that exactly one message is emitted,
that it names the true cause, and that every command name it contains matches
a command the assistant can run.

**Acceptance Scenarios**:

1. **Given** an installed but not-yet-configured repository, **When** a
   covered lifecycle step runs, **Then** the host command succeeds and at most
   one notice is emitted, describing the repository as not yet configured and
   naming the configuration command.
2. **Given** any message emitted by the bridge that names a command, **When**
   that name is compared against the commands the install registers, **Then**
   it matches one of them exactly.
3. **Given** an installed but not-yet-configured repository, **When** several
   lifecycle steps run in succession, **Then** the not-yet-configured notice is
   emitted at most once per host command run, and is at most three lines long.
4. **Given** a repository where the bridge entry point is absent or not
   executable, **When** a covered lifecycle step runs, **Then** the message the
   developer sees is the one the procedure prescribes word for word — naming the
   missing path, stating that the host command completed normally, and naming
   the reinstall command — and not a description the assistant composed itself.

---

### User Story 6 - The configuration ceremony verifies and reports, and never writes the registry (Priority: P2)

An operator runs the configuration ceremony in a repository where the install
already registered the hooks. The ceremony reads the registry, reports what it
found, and leaves the file exactly as it was — byte for byte, comments
included. If an entry is missing, disabled, held disabled, or left over from an
earlier version of this extension, the ceremony says so precisely and names
what the operator should run or edit. It never does it for them.

**Why this priority**: the registry is a shared file. The host install writes
it, other extensions have entries in it, and the operator keeps comments and an
ordering in it. Two components writing one file is the churn defect this
feature exists to end; the durable fix is not "write less often" but "do not
write at all". With registration owned by the install, the extension has no
remaining reason to hold a pen.

**Independent Test**: Can be fully tested by taking a checksum of the hook
registry, running every command the extension offers in every documented state
— healthy, missing entries, disabled entries, legacy entries, unreadable file,
not configured — and verifying the checksum is unchanged after each one, while
each state produces its own accurate report.

**Acceptance Scenarios**:

1. **Given** a repository whose hooks were registered by the install, **When**
   the configuration ceremony runs, **Then** the hook registry is byte-identical
   afterwards and the ceremony reports every declared event as present.
2. **Given** a repository where one of this extension's hook entries was
   deleted, **When** the ceremony runs, **Then** the registry is still
   byte-identical afterwards, the report names the missing event, and it names
   the single official install command that restores it.
3. **Given** a repository where an entry was disabled by the operator,
   **When** the ceremony runs, **Then** the entry is reported as disabled — not
   as missing — the registry is unchanged, and the report names the command
   that would release it.
4. **Given** a repository whose registry the extension cannot read, **When** the
   ceremony runs, **Then** it reports the file as unreadable, names the
   construct that defeated the reader where it can determine it, does not claim
   the hooks are missing, and leaves the file untouched.
5. **Given** a registry carrying an entry written by an earlier version of this
   extension — the same command, with no owning extension recorded — **When**
   the ceremony runs, **Then** it names the affected events, explains that the
   official install cannot purge an entry it does not recognise and will
   therefore add a second one, and gives a copy-pasteable manual instruction to
   remove the leftover.
6. **Given** any repository state whatsoever, **When** any command of this
   extension runs, any number of times, **Then** the hook registry's checksum
   is identical before and after every run.

---

### Edge Cases

- **Unreadable hook registry**: the registry file exists but the extension
  cannot read it as configuration. It is reported as unreadable, named as the
  cause, and left untouched. It is never reported as "hooks missing", because
  the extension has no evidence either way.
- **Registry valid but outside the reader's supported subset**: the file is
  legitimate YAML that this extension's restricted reader does not cover — an
  anchor, a flow collection, a block scalar, written by another extension or by
  the operator. The report distinguishes this from a genuinely broken file,
  names the construct where it can, and still leaves the file untouched. It
  never presents a valid registry to the operator as corrupt.
- **Partial registration**: some of this extension's events are registered and
  others are missing (an interrupted install, a hand-edited file). The health
  report lists exactly the missing events and names the official install
  command that registers them.
- **Entry present but shaped differently**: an entry for one of this
  extension's commands exists but was written by a version of this extension
  that predates manifest-declared hooks, and carries no owning-extension field.
  The official install cannot recognise it as ours and will therefore leave it
  in place and add a second entry for the same event. The health report names
  every affected event and gives a copy-pasteable manual instruction to remove
  the leftover. This is the one repair the extension cannot perform itself,
  because performing it would mean writing the registry.
- **Install into a repository that is not a spec-kit project**: the install
  reports the missing project structure rather than creating a stray registry.
- **Uninstall**: removing the extension removes this extension's hook entries
  and leaves every other extension's entries intact.
- **Lifecycle step run outside a repository, or before any feature exists**:
  the hook is inert and the host command is unaffected.
- **Credentials present but rejected by Jira**: the host command still
  succeeds and the warning distinguishes an authentication failure from a
  not-yet-configured repository.
- **Both ports on the same repository**: a repository configured on one
  platform and used on the other produces the same registered entries; no
  platform-specific entry is written.

## Requirements _(mandatory)_

### Functional Requirements

> Identifiers are stable and never reused. FR-028 and FR-029 were added after
> FR-026 and FR-027 already existed, and are grouped by subject rather than by
> number.

#### Registration at install time

- **FR-001**: The extension manifest MUST declare every lifecycle event the
  bridge participates in, so that the official Spec Kit install command
  registers them into the consuming repository without any further action.
- **FR-002**: The declared lifecycle events MUST cover feature creation
  (`before_specify`) and the six mirroring events (`after_specify`,
  `after_clarify`, `after_plan`, `after_tasks`, `after_implement`,
  `after_analyze`).
- **FR-003**: Each entry the install registers MUST be enabled at the moment of
  registration. A later `enabled: false` is the operator's decision, honoured
  per FR-007; the extension never edits that field, in either direction.
- **FR-004**: Each registered entry MUST be declared as non-optional, meaning
  the assistant performs it as part of the host lifecycle command rather than
  offering it as a suggestion.
- **FR-005**: Registration MUST be idempotent across repeated installs and
  upgrades: exactly one entry per event per command, no duplicates, no
  stripped entries.
- **FR-006**: Registration MUST preserve every hook entry belonging to another
  extension or placed by the operator.
- **FR-007**: Once the operator has explicitly disabled one of this extension's
  hook entries, no bridge step MUST be performed for that event across any
  later install, upgrade or configuration ceremony — whatever the registry's
  `enabled` field says at that moment — until the operator explicitly releases
  it. The guarantee is on the *effect*, not on the field: the official install
  rewrites `enabled: true` unconditionally and the extension may not correct it
  (FR-022), so the extension records the decision outside the registry and
  honours it when the hook fires.
- **FR-008**: The install MUST NOT modify anything outside the consuming
  repository.

#### Commands referenced by hooks

- **FR-009**: Every command referenced by a registered hook entry MUST be a
  command the extension installs and the assistant can invoke in the consuming
  repository.
- **FR-010**: The reconcile step fired by the `after_*` events MUST be exposed
  as an installed, assistant-invocable command with a documented, ordered
  procedure — matching how the configuration and feature-naming steps are
  already exposed.
- **FR-011**: The manifest MUST list every such command, so the install
  registers the command and the hook reference resolves.

#### Runnable bridge

- **FR-012**: After the official install, on a machine satisfying the
  documented prerequisites, the bridge entry point MUST be invocable by the
  assistant with no additional installation, path configuration, or
  environment setup beyond the documented credentials.
- **FR-013**: FR-012 MUST hold identically on the Bash port (macOS/Linux) and
  the PowerShell port (Windows), with the correct port selected automatically.
- **FR-014**: The documented procedures the assistant follows MUST invoke the
  bridge in a way that is valid in a freshly installed consuming repository —
  no invocation may depend on a machine-wide executable the install does not
  provide.

#### Behaviour when the bridge cannot complete

- **FR-015**: A hook failure of any kind MUST NOT fail the host spec-kit
  command; the host command completes with its normal outcome.
- **FR-016**: A hook that cannot complete MUST emit at most one warning per
  host command run.
- **FR-017**: A warning MUST name the true cause, distinguishing at minimum:
  not yet configured, credentials absent, credentials rejected, prerequisite
  missing, Jira unreachable, and the bridge entry point being absent or not
  executable.
- **FR-030**: The state in which the bridge entry point cannot be found or run
  is the one state the bridge cannot report on, because it never starts —
  everything the developer sees then is composed by the assistant. For that
  state alone, the documented procedures MUST carry the message text verbatim
  and MUST instruct the assistant to emit it exactly as written rather than
  describe the situation in its own words. The text MUST name the true cause,
  state that the host command completed normally, and contain only literals
  that are runnable as written.
- **FR-018**: Every command literal appearing in any message MUST be runnable
  as written. Three classes exist and all three are covered:
  1. an assistant command of this extension — MUST exactly match a command the
     extension registers;
  2. an invocation of the bridge — MUST be given in the repository-relative,
     per-port form of FR-014, never as a bare executable name;
  3. a host command such as the official install — MUST be given in the form
     the operator actually runs.

  No message may name a command that does not exist or that cannot be run as
  spelled.
- **FR-019**: In a repository that is installed but not yet configured, the
  lifecycle steps MUST behave exactly as they would without the extension,
  apart from the single notice of FR-016.
- **FR-020**: A hook MUST NOT emit a warning for an event whose entry the
  operator disabled.

#### Verification and reporting

The hook registry has exactly one writer: the official Spec Kit install
command. This extension is a reader of that file and a reporter on it. The
requirements below are written from that premise, and FR-022 states it as a
hard constraint rather than a default.

- **FR-021**: The configuration ceremony MUST report hook health for every
  event declared in the manifest, classifying each as present, missing,
  disabled, held disabled, or duplicated by a leftover entry.
- **FR-022**: No command, hook, script or code path of this extension may
  create, modify, truncate, reformat, reorder or delete the consuming
  repository's hook registry, in any circumstance — including first run,
  repair, and realigning an entry the extension believes to be wrong.
- **FR-023**: Every run of every command of this extension MUST leave the hook
  registry byte-identical, including comments, key order, indentation and
  trailing whitespace.
- **FR-024**: A hook registry the extension cannot read MUST be reported as
  unreadable, naming the file and — where determinable — the construct that
  defeated the reader. It MUST NOT be reported as missing hooks, and MUST NOT
  cause the extension to write anything.
- **FR-025**: When a declared event has no entry of this extension, the health
  report MUST name that event and name the single official install command that
  registers it. The extension MUST NOT register it itself.
- **FR-028**: When the registry carries an entry of this extension in the shape
  a pre-manifest version wrote — this extension's command, with no owning
  extension recorded — the health report MUST name every affected event,
  explain that the official install will add a second entry rather than replace
  it, and give a copy-pasteable manual instruction to remove the leftover.
- **FR-029**: The operator's disable decision MUST be recorded outside the hook
  registry, in a location that survives a reinstall or upgrade of the extension,
  and MUST be removable only by an explicit operator action.

#### Documentation

- **FR-026**: The installation documentation MUST state that hooks are
  registered and active from install, that they are performed rather than
  offered, that a hook failure never fails a spec-kit command, and that the
  extension never modifies the hook registry itself.
- **FR-027**: The managed README block and the install instructions MUST
  reflect the corrected sequence: install registers and activates the hooks;
  the configuration ceremony binds the project and verifies the registration.

### Key Entities

- **Lifecycle event**: a named point in the spec-kit workflow at which the
  bridge participates (one before feature creation, six after artifact-
  producing steps).
- **Hook entry**: the record in the consuming repository's hook registry that
  binds one lifecycle event to one extension command, carrying at least the
  owning extension, the command, whether it is enabled, and whether it is
  optional.
- **Hook registry**: the consuming repository's file listing all extensions'
  hook entries, shared with other extensions and editable by the operator.
  Written by exactly one component — the official install — and read-only to
  this extension.
- **Operator disable record**: the extension's own record of the events the
  operator disabled, kept outside the hook registry so that it survives a
  reinstall, and consulted every time a hook fires.
- **Bridge entry point**: the single executable seam the assistant drives to
  perform configuration, feature naming, and reconciliation.
- **Extension command**: an assistant-invocable command the install registers
  in the consuming repository; a hook entry may only reference one of these.
- **Hook health**: the classification of every declared event as present,
  missing, disabled, held disabled, or duplicated by a leftover entry, plus the
  guidance shown when anything is not present.

## Constitution Check

Per Governance, every principle with its proof of compliance at the
specification level.

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | Filesystem is source of truth | No requirement changes what is mirrored or which tickets may be touched. This feature governs only *when* the bridge runs. |
| II | Zero-churn idempotency | FR-022, FR-023, SC-004 and SC-007 are this principle applied to the hook registry, and strengthened: the extension writes it zero times rather than rarely. |
| III | Fail-closed on writes, non-blocking on hooks | FR-015 restates it verbatim. The Overview separates dispatch from outcome propagation precisely so that FR-004 cannot be read as weakening it. |
| IV | Zero tokens in the tree | No requirement introduces a credential path; hook entries carry no credential-shaped value. |
| V | Team config / local binding / secrets separated | FR-029 requires the operator's disable decision to live outside the extension folder so that it survives reinstall — which is exactly the local-binding layer this principle defines. |
| VI | macOS / Linux / Windows portability | FR-013 requires FR-012 to hold identically on both ports; the "Both ports on the same repository" edge case requires identical registered entries; SC-011 is verified on both ports. |
| VII | No hard-coded Jira workflow assumptions | No issue type, status or field id appears in any requirement. |
| VIII | Neutral engine / Jira sink | Every requirement lands in the hooks, commands or documentation layer; none touches the engine or the sink. |
| IX | Two-tier privacy guard | Unaffected — no requirement changes the pre-write scan. |
| X | Self-healing automatic mirror | FR-005 (idempotent registration by the install), FR-007 (disabled respected forever), FR-021 and FR-025 (health reported on every run, with the repair command named). One deviation is recorded and justified in the plan's Complexity Tracking: with FR-022 forbidding registry writes, the leftover-entry case of FR-028 is repaired by a spelled-out manual edit rather than by one command. |
| XI | Universal dry-run and auditability | FR-021 puts hook health in the run summary on every run. FR-022 removes the only registry write there was, so no registry action needs a dry-run prediction; the disable record remains the extension's own file and its writes are predicted by the existing dry-run. |
| XII | Quality and catalog publication | SC-010 is the dogfood criterion; FR-026 and FR-027 keep the documented install path accurate. |
| XIII | TDD, 80% coverage | Every requirement above is stated so it can be exercised by at least one automated scenario; SC-007, SC-011 and SC-012 are mechanical checks, and the reported defect is covered by FR-018 and SC-009. |
| XIV | KISS | The feature adopts the host's existing manifest hook mechanism rather than inventing a parallel one, and removes a component — the registrar's writer — rather than adding one. |
| XV | YAGNI | FR-002 fixes the event set at exactly the seven already covered; Out of Scope forbids both new events and any future registry write. |
| XVI | Human readable | FR-017, FR-018, FR-024, FR-025 and FR-028 together require every message to name a true cause and a command or edit the operator can actually perform; FR-023 and SC-012 protect the readability of a file a human maintains by hand. |

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: After the official install alone — with zero additional
  operator actions — 100% of declared lifecycle events are registered and
  enabled in the consuming repository.
- **SC-002**: 100% of registered hook entries reference a command the install
  makes available; zero unresolvable references.
- **SC-003**: In a configured repository, 100% of covered lifecycle steps
  perform the bridge step without developer confirmation.
- **SC-004**: Across 10 consecutive installs, upgrades and configuration
  ceremonies in any order, starting from a registry with no leftover entry, the
  number of this extension's entries per event never exceeds one, and no entry
  is ever lost.
- **SC-005**: After the operator disables an event, 100% of subsequent
  lifecycle steps for that event perform no bridge step and emit no warning,
  across any number of intervening installs, upgrades and ceremonies, until the
  operator explicitly releases it.
- **SC-006**: Zero spec-kit lifecycle commands fail because of a bridge
  failure, across the full fault matrix (not configured, credentials absent,
  credentials rejected, prerequisite missing, Jira unreachable, bridge entry
  point absent or not executable, unreadable registry).
- **SC-007**: Across every command the extension offers, run in every
  documented registry state — healthy, entries missing, entries disabled,
  leftover entries present, file unreadable, repository not configured — the
  hook registry's checksum is identical before and after every run. Zero
  writes, unconditionally, with no exempted state.
- **SC-008**: On a machine satisfying the documented prerequisites, the time
  between finishing the official install and the first successful bridge
  invocation contains zero manual steps, on both ports.
- **SC-009**: Every command name appearing in any message the extension emits
  resolves to a registered command — verified mechanically, with zero
  mismatches.
- **SC-010**: A developer installing the extension for the first time reaches
  a working mirrored feature using only the install command and the
  configuration command, with no troubleshooting step.
- **SC-011**: The extension's source tree contains zero code paths that open
  the hook registry for writing, appending, truncating, moving or deleting —
  verified mechanically on both ports, with zero occurrences.
- **SC-012**: An operator's comments in the hook registry survive 100% of runs
  of every command the extension offers, in every registry state.

## Assumptions

- The official Spec Kit install command supports declaring lifecycle hooks in
  the extension manifest and registering them into the consuming repository's
  hook registry; this feature adopts that mechanism rather than inventing a
  parallel one.
- "Non-optional" is interpreted as a **dispatch** property — the assistant
  performs the hook instead of offering it — and explicitly not as permission
  to fail the host command. Non-blocking outcome propagation is preserved
  unchanged, per the project constitution.
- The bridge is made runnable **from inside the consuming repository**. The
  extension does not install a machine-wide executable, modify the operator's
  search path, or touch any shell profile; an install whose only side effects
  are inside the repository is treated as a hard constraint.
- Credentials remain the operator's responsibility and stay outside the scope
  of the install; a repository installed without credentials is a normal
  not-yet-configured state, not an error.
- The configuration ceremony keeps its existing role for project binding and
  discovery. This feature narrows its hook responsibility to reading and
  reporting: it no longer registers, repairs or realigns anything in the hook
  registry.
- The hook registry is treated as a **read-only** resource by this extension,
  as a deliberate constraint rather than a consequence. The alternative —
  writing only when the extension believes the file is wrong — was rejected: it
  requires the extension's restricted YAML reader to round-trip a file it does
  not own, which silently discards operator comments and any construct outside
  the reader's supported subset. A shared file with two writers eventually
  loses someone's work; a shared file with one writer cannot.
- The cost of that constraint is accepted and stated: the extension can no
  longer repair a registry itself. Where the official install can repair (a
  missing entry), the report names it. Where it cannot — a leftover entry from a
  pre-manifest version, which the install does not recognise as ours — the
  repair is a manual edit the report spells out (FR-028).
- Reinstall, upgrade and uninstall semantics follow the official install
  command's behaviour for manifest-declared hooks; this feature verifies that
  behaviour rather than reimplementing it.
- The operator's disable decision can only be observed when the extension reads
  the registry. An operator who sets `enabled: false` and reinstalls before the
  extension has read the file once has not been observed, and the reinstall's
  `enabled: true` stands. Running the configuration ceremony after disabling an
  event is therefore the documented way to make the decision durable.
- The reported message text is treated as a symptom, not a specification: this
  feature does not preserve its wording, only the requirement that any
  remaining degraded message be accurate, single, and correctly named.

## Dependencies

- The consuming repository is an initialised Spec Kit project with a version
  satisfying the extension's declared minimum.
- The official Spec Kit install command is the only supported installation
  path; manual copying of the extension tree is out of scope.
- The documented prerequisites (Bash ≥ 4 or PowerShell 7+, plus `curl`, `jq`
  and `git` where the port requires them) remain the operator's
  responsibility; this feature changes how their absence is reported, not
  whether they are required.

## Out of Scope

- Changing what the bridge mirrors into Jira, or how reconciliation computes
  its plan.
- Changing project discovery, style detection, team naming, or any other
  behaviour owned by feature 002.
- Distributing the bridge through a package manager or any machine-wide
  installation channel.
- Adding new lifecycle events beyond the seven already covered.
- Changing credential resolution or the privacy guard.
- Any writing of the consuming repository's hook registry by this extension —
  including behind a flag, an opt-in setting, or an interactive confirmation.
  FR-022 admits no exception, and adding one later requires a new spec.
