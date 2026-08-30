# Feature Specification: Retire the hook registry report

**Feature Branch**: `034-retire-hook-report`

**Created**: 2026-08-30

**Status**: Draft

**Input**: User description: "I no longer want the extension to verify that the hooks are registered by Spec Kit, since that is Spec Kit's responsibility from the moment the user runs `specify extension add`."

## Context — an audit of somebody else's work

`.specify/extensions.yml` has exactly one writer, and it is the host. `specify
extension add` builds it from this extension's manifest; feature 003 removed our
own writer, and `register_hooks.sh` says so in its first paragraph — *"exactly
ONE writer and it is not us"*.

What survived 003 was the **reader**. On every configuration ceremony and every
reconcile, the extension opens that file, classifies all seven declared lifecycle
events into present / missing / disabled / duplicated / unreadable, and reports
the verdict with a repair hint. It can act on none of it. It cannot register a
missing event, cannot re-enable a disabled one, cannot remove a duplicate — the
hint for the last one says as much, and asks the operator to edit the file by
hand.

The verdict is also wrong in the field. In a real multi-team consumer repository
the ceremony reported all seven events missing while the registry demonstrably
carried them. The most plausible mechanism is the 0.22.0 rename: recognition
requires **both** `extension: jira-mirror` **and** the current command names, so
every entry written by an earlier install became invisible in one step, and the
repair the report offered — reinstall — did not change the verdict. An operator
who follows correct advice and sees nothing change learns to ignore the report;
an operator who believes it goes looking for a fault that does not exist.

So the report is an assertion about a fact the extension cannot repair, drawn
from a classification that a rename can silently invert. Constitution 4.0.0
withdrew the obligation that required it and replaced it with the opposite rule:
the extension MUST NOT read, write, verify or report that registry. This feature
carries out that withdrawal in the code.

**What is not in scope, and must not be weakened:** the hooks themselves keep
firing exactly as they do today, the manifest keeps declaring all seven events,
and a bridge failure inside a hook keeps surfacing one actionable warning without
failing the host command. Nothing about how the mirror *runs* changes. Only the
extension's commentary on the registry goes.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The configuration ceremony stops reporting on the registry (Priority: P1)

An operator runs the configuration ceremony in a correctly installed repository.
The run summary reports what the ceremony actually did — discovery, the managed
README block, the ignore rule, the per-operator file — and says nothing about
lifecycle hooks, because it no longer looks at them.

**Why this priority**: this is where the false verdict was seen, and where an
operator is most likely to act on it. Delivered alone it removes the misleading
report entirely.

**Independent Test**: run the ceremony against a repository whose registry is
correct, one whose registry is absent, and one whose registry is malformed;
assert the three summaries are identical in their hook-related content, namely
that they contain none.

**Acceptance Scenarios**:

1. **Given** a repository with a complete, correct registry, **When** the
   configuration ceremony runs, **Then** the run summary contains no hooks
   effect and no hook health of any kind.
2. **Given** a repository with no `.specify/extensions.yml` at all, **When** the
   ceremony runs, **Then** it succeeds exactly as in scenario 1, with no
   warning, no missing-hook claim, and no difference in exit code.
3. **Given** a repository whose registry is malformed beyond parsing, **When**
   the ceremony runs, **Then** it succeeds exactly as in scenario 1 — an
   unreadable file the extension never opens cannot affect it.
4. **Given** any of the above, **When** the ceremony's other effects are
   inspected, **Then** discovery, the managed README block, the ignore rule and
   the per-operator file are unchanged in behaviour and in reported shape.

---

### User Story 2 - Reconcile stops carrying a hook verdict (Priority: P1)

A developer reconciles a specification. The run summary reports the mirror's own
work — counts, actions, warnings, notes — and carries no hook health object.

**Why this priority**: equal to US1 and inseparable from it in value. A verdict
that is wrong in the ceremony is equally wrong on every reconcile, which runs far
more often; removing it in one place and keeping it in the other would leave the
defect in the busier path.

**Independent Test**: reconcile against the same three registry states as US1 and
assert the summaries are identical in hook-related content.

**Acceptance Scenarios**:

1. **Given** any registry state, **When** reconcile runs, **Then** its run
   summary carries no hook health object and no hook-derived warning.
2. **Given** a bridge failure inside hook context, **When** reconcile runs,
   **Then** it still surfaces exactly one actionable warning and still returns
   success to the host command, unchanged.

---

### User Story 3 - The release flag and its record are withdrawn (Priority: P2)

The flag that released a withheld lifecycle event, and the local record of the
operator's disable decision that it acted on, are both removed. Nothing produces
that record and nothing consumes it.

**Why this priority**: it is the remainder. The flag exists only to clear entries
in a record written only by the classification US1 and US2 delete; leaving it
would ship a flag that can do nothing, which is precisely the class of claim this
feature exists to remove.

**Independent Test**: invoke the configuration command with the withdrawn flag
and assert the documented refusal; validate a local binding file carrying the
withdrawn key and assert the documented refusal.

**Acceptance Scenarios**:

1. **Given** the configuration command, **When** it is invoked with the
   withdrawn release flag, **Then** it refuses with the exit code it already
   uses for an unknown flag, naming the flag.
2. **Given** a local binding file carrying the withdrawn disable record, **When**
   any command loads the configuration, **Then** it is refused with exit 4 and
   the schema's existing located unknown-key error, naming the key and the file.
3. **Given** a local binding file carrying none of the withdrawn keys, **When**
   any command loads the configuration, **Then** it validates exactly as before.

---

### Edge Cases

- **A repository whose registry is genuinely missing our entries.** The hooks do
  not fire, the mirror never runs, and the extension is silent — by design. The
  operator's signal is that nothing happens, and the remedy is the host's install
  command, documented where installation is documented. This is the protection
  the amendment knowingly gives up; it must be stated in the documentation rather
  than left to be discovered.
- **A hook the operator disabled by hand is re-enabled by a reinstall.** The
  extension neither prevents nor reports it. Also knowingly given up, and also to
  be stated where the operator reads about disabling a hook.
- **A checkout still carrying a disable record written by a previous version.**
  It falls to the existing unknown-key refusal, which names the key and the file;
  deleting the two lines is the whole remedy. No population needs sparing: the
  extension has one operator, who is the author of this specification.
- **The manifest still declares seven events.** It must — that is what the host
  registers from. Removing the reader must not touch the manifest, and the
  existing build-time check that the manifest's event set matches the port's must
  be retired or re-pointed rather than left asserting against a deleted set.
- **Reconcile's structured summary is a published contract.** Removing a field
  from it is an observable change for any consumer parsing that JSON.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The extension MUST NOT open `.specify/extensions.yml` for reading
  or for writing, in any command, in any state.
- **FR-002**: The configuration ceremony's run summary MUST NOT contain a hooks
  effect, a hook health object, a hook repair hint, or any other statement about
  the registry.
- **FR-003**: Reconcile's run summary MUST NOT contain a hook health object or
  any other statement about the registry.
- **FR-004**: The configuration command MUST no longer accept the flag that
  released a withheld lifecycle event; supplying it MUST be refused as an unknown
  flag, through the existing unknown-flag path.
- **FR-005**: The local binding schema MUST no longer accept the operator disable
  record. No dedicated retired-key rule and no bespoke message are added for it:
  a file still declaring the key falls to the schema's existing unknown-key
  refusal, which already exits 4 and already names both the key and the file.
- **FR-006**: The lifecycle hooks MUST keep firing exactly as they do today: the
  manifest MUST keep declaring all seven events, and no change may alter which
  events the host registers or the commands they name.
- **FR-007**: A bridge failure in hook context MUST keep surfacing exactly one
  actionable warning and MUST keep returning success to the host command.
- **FR-008**: Every remaining consumer of the run summaries MUST tolerate the
  removed fields' absence; the published summary contract MUST be updated to
  remove them rather than mark them optional.
- **FR-009**: The build-time check asserting that the manifest's declared event
  set matches the port's own declaration MUST be retired or re-pointed at the
  manifest alone, and MUST NOT be left asserting against a deleted declaration.
- **FR-010**: The existing guard proving the extension never writes the registry
  MUST be widened to prove it never reads it either, and MUST be demonstrated red
  against the pre-change code before it is accepted.
- **FR-011**: Documentation MUST state what the extension no longer does and what
  follows from it: that hook registration and its survival across reinstalls
  belong to the host, that a repository whose hooks are absent will simply see
  nothing happen, and that a hand-disabled hook may be re-enabled by a reinstall
  without warning.
- **FR-012**: Both language ports MUST produce byte-identical output for every
  scenario this feature defines.

### Key Entities

- **Hook registry**: the host-owned `.specify/extensions.yml`. After this feature
  it is not an input to the extension in any form.
- **Run summary**: the structured report each command emits. Loses one effect in
  the ceremony and one object in reconcile; every other field is untouched.
- **Operator disable record**: the entry in the gitignored local binding that
  preserved an operator's `enabled: false` decision across reinstalls. Retired,
  with a located refusal on encounter.

## Constitution Check *(mandatory)*

Assessed against constitution **4.0.0**. This feature is the implementation of
that amendment; it is not permitted by an exception to Principle X but required
by its current text.

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Unaffected. This feature removes a reader of a host-owned file; no source of truth about specifications or tickets changes. |
| II | Zero-Churn Idempotency | Improved. The ceremony no longer writes the disable record, removing a write that fired on encountering an `enabled: false` entry. Remaining writes are unchanged. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-007 preserves the non-blocking half explicitly. No write path gains or loses a failure mode; FR-005's refusal is a configuration refusal on the existing exit 4 path. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. No credential is read, written, or reported by anything this feature touches. |
| V | Separation of Team Config / Local Binding / Secrets | The local binding layer loses one key (FR-005). Its stated purpose is unchanged, and the clause requiring configuration to survive a reinstall is untouched — it constrains where configuration lives, not who verifies the registry. |
| VI | macOS / Linux / Windows Portability | FR-012 requires byte-identical output from both ports. The conformance scenario built on the install/hook report is retired with the behaviour it covered. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Improved. The hooks layer's registry-reading module is removed entirely, leaving one less non-engine, non-sink concern in the tree. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. |
| X | Self-Healing Automatic Mirror, Within Its Own Boundary | This feature IS the principle's implementation. FR-001 is its central prohibition; FR-010 is its enforcement test; FR-006 and FR-007 preserve the self-healing behaviour the amended principle retains. |
| XI | Universal Dry-Run and Auditability | Both run summaries remain structured and complete for the work each command actually performs. FR-008 updates the published contract rather than leaving a field that never appears. |
| XII | Quality and Catalog Publication | The removed fields are observable output, so the release is breaking: a version bump in the leftmost position a `0.x` line can move, and a CHANGELOG entry naming the removed flag, the removed key, the removed summary fields, the removed effect-status values and the removed dispatch hold. The principle's remaining release gates bind this feature like any other and are NOT waived by it being a deletion: a green live-integration run on the release commit, and a dogfood record against a real Jira instance. The dogfood gate is load-bearing here rather than ceremonial — the false verdict this feature removes was found by dogfooding and by nothing else, and the mocked suites had been green throughout. |
| XIII | TDD With a Minimum 80% Coverage | FR-010 requires the widened guard to be proven red against the pre-change code before acceptance. Every retired test is either deleted with its behaviour or re-pointed, never left passing vacuously. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | This is a net deletion: one module, one flag, one schema key, two summary fields. The rejected alternative — teaching the classifier the pre-rename names — is recorded in the constitution's own amendment report. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Nothing is built at all. FR-005 is a deletion from a list of accepted keys, and the refusal it produces already exists; the dedicated retired-key rule first drafted for it was withdrawn once the installed base it protected turned out to be empty. |
| XVI | Human Readable — Readable by a Human Above All | FR-005 requires the refusal to say who wrote the key and what to do; FR-011 requires the documentation to state the two protections deliberately given up, rather than leaving them to be found in a diff. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a repository with a correct registry, an absent registry, and a
  malformed registry, the three configuration-ceremony summaries are identical in
  hook-related content — all three contain none.
- **SC-002**: No command opens `.specify/extensions.yml`, proven by a guard that
  is demonstrated red against the pre-change code.
- **SC-003**: The lifecycle hooks fire, and the mirror runs, exactly as before —
  verified by the existing end-to-end hook scenarios passing unmodified.
- **SC-004**: A local binding file still declaring the retired record is refused
  with a message naming both the key and the file, produced entirely by the
  pre-existing unknown-key path — zero lines of code are added to obtain it.
- **SC-005**: Both ports produce identical output for every scenario above.
- **SC-006**: Zero occurrences remain, anywhere in shipped code or documentation,
  of a claim about whether the hooks are registered.

## Assumptions

- **No migration, and no bespoke message either.** The extension has exactly one
  operator today. There is no installed base to spare an upgrade friction, so the
  question of softening that friction does not arise: the key leaves the accepted
  set and the schema's existing unknown-key refusal handles whatever remains,
  naming the key and the file without a line of new code. Both alternatives
  considered — a dedicated retired-key rule with a message acknowledging our own
  authorship of the key, and accepting-and-ignoring it — were machinery whose
  entire justification was a population that does not exist. Should the extension
  acquire users before this ships, the question reopens; it does not reopen for
  any other reason.
- Removing fields from the two run summaries is a breaking change to a published
  contract and is released as such, rather than being softened by emitting empty
  objects. An empty object asserting nothing is the same defect in a quieter form.
- The manifest is untouched. It is the host's input, not ours, and the seven
  declared events are what make the mirror automatic.
- The two protections withdrawn by constitution 4.0.0 — a warning when the hooks
  are not registered, and the permanence of a hand-disabled hook — are not
  replaced by anything. They are documented as belonging to the host.
- No `--repair` or re-registration capability is added in their place. The
  extension has no writer for that file and constitution 4.0.0 forbids giving it
  one.

## Dependencies

- **Constitution 4.0.0** (amended 2026-08-30). Under 3.0.0 this feature was
  forbidden: Principle X mandated the very check it removes. The amendment is a
  hard prerequisite, not a parallel activity.
- Independent of feature 033. The two share a branch and a reporting session but
  no code path: 033 changes routing resolution, 034 removes a registry reader.
  Either may ship first.
