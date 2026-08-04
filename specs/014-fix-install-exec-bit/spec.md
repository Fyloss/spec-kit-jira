# Feature Specification: A Fresh Install Runs Immediately — No Permission Step, Ever

**Feature Branch**: `worktree-fix+chmod-scripts`

**Created**: 2026-08-03

**Status**: Draft

**Input**: User description: "When I install the extension on a consumer project, I get an error about the
scripts' permissions — they are not delivered in an executable state; I believe the fix people apply is
`chmod 755`. Make it so a consumer of the extension never has to change permissions and everything is
directly functional at install."

## Context — the defect this feature closes

A consumer installs the extension into their repository and the very first documented step fails.

The extension's Bash entry point needs an executable bit to be invoked the way every one of our
documents spells it — by repository-relative path. Whether that bit survives the trip into the
consumer's repository is not ours to decide: it depends on the host's delivery route and on the host
version. The archive route drops file modes outright, and the host only began restoring them on its
own from a version that is *newer than the minimum this extension declares support for*. So a
perfectly ordinary, fully supported install lands the entry point non-executable, and the consumer's
first invocation dies with a bare "permission denied" from the operating system before any of our
code runs.

The consumer then reaches for the obvious workaround — hand the file to the interpreter instead of
executing it — and our own prerequisite gate refuses that too. The gate treats "not executable" as
proof that the install is incomplete, stops the run, and offers a remedy — re-install with `--force`
— that reproduces exactly the state the consumer is already in. A survivable condition has been
converted into a hard failure, and the one escape route has been closed by us.

What is left is `chmod` by hand, on files the extension itself installed, repeated after every
re-install and every upgrade. That is the step this feature removes.

The durable fix is not to detect the bit, repair the bit, or demand a host version that sets the bit.
It is to stop needing it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Install, then run — nothing in between (Priority: P1)

A developer adds the extension to their project through their host's normal install command and
immediately follows the verification step the install documentation gives them. The bridge answers.
They did not inspect a file's permissions, did not run a permission command, and were not told to.
This holds on every host version the extension declares support for and by either route the host
offers to deliver the files.

**Why this priority**: This is the reported defect and the whole promise of the feature. Every other
story is worthless if the first command a consumer types still fails.

**Independent Test**: Install the extension onto a clean consumer repository by the route that
strips file modes, on the oldest supported host, change nothing, and run the documented verification
command. It succeeds.

**Acceptance Scenarios**:

1. **Given** a freshly installed extension whose entry points carry no executable bit, **When** the
   operator runs the verification command exactly as the install documentation spells it, **Then**
   the bridge runs and reports normally.
2. **Given** the same tree, **When** the operator runs the configuration ceremony, **Then** it
   completes with its usual outcome and never mentions file permissions.
3. **Given** a tree whose entry points *do* carry the executable bit, **When** the same commands are
   run, **Then** the outcome and the output are identical to the case above.

---

### User Story 2 - The lifecycle hooks mirror on a permission-stripped tree (Priority: P1)

A developer on that same freshly installed project runs a normal spec-kit lifecycle command. The
hook fires, the bridge is invoked on their behalf, and the mirror happens. The developer never sees
the extension's entry point, never types its path, and never learns that a file mode was involved.

**Why this priority**: The hooks are how the extension is actually used. An entry point that only a
human can work around is still broken for the automated path, which is the path that matters — and a
mirror blocked by a file mode contradicts the non-blocking guarantee the bridge is built on.

**Independent Test**: On a permission-stripped install, run a lifecycle command that carries a
registered hook and confirm the mirror completes with its normal run summary.

**Acceptance Scenarios**:

1. **Given** a permission-stripped install with the hooks registered, **When** a lifecycle event
   fires, **Then** the mirror completes and the run summary counts the writes it made.
2. **Given** the same tree, **When** a lifecycle event fires twice with nothing changed in between,
   **Then** the second run writes nothing — the permission state changed no behaviour at all.

---

### User Story 3 - An already-broken install heals by upgrading, and nothing else (Priority: P2)

A consumer who hit this defect and has been working around it with a manual permission command
upgrades the extension. From that moment the workaround is unnecessary: they never run the
permission command again, including after future re-installs and upgrades.

**Why this priority**: The population that reported the defect is already in the broken state. A fix
that only helps repositories created after it lands leaves them exactly where they were.

**Independent Test**: Take a tree in the broken state, upgrade the extension through the host's
normal update path, and run every documented command with no permission step before or after.

**Acceptance Scenarios**:

1. **Given** an extension tree installed before this feature and left non-executable, **When** the
   consumer upgrades the extension and runs the documented verification, **Then** it succeeds with
   no intervening command.
2. **Given** that upgraded tree, **When** the consumer re-installs the extension again later,
   **Then** no permission step is needed after the re-install either.

---

### User Story 4 - Diagnostics stay honest (Priority: P2)

An entry point really is absent — a partial copy, a deleted file, a half-finished install. The
operator still gets a named cause telling them which file is missing and a remedy that restores it.
The message no longer speaks about permissions, because permissions are no longer a cause.

**Why this priority**: Removing the permission clause must not blunt the detection of a genuinely
broken install. The gate has to keep earning its place — and its message has to stop describing a
failure mode that can no longer occur.

**Independent Test**: Delete one port's entry point, run the bridge, and confirm the reported cause
names that file and offers a remedy that works.

**Acceptance Scenarios**:

1. **Given** a tree with one port's entry point removed, **When** any command runs, **Then** the
   missing file is named as its own degraded cause, the spec-kit command it was attached to still
   completes normally, and nothing is mirrored.
2. **Given** any tree, **When** any of the extension's messages, command documents or installation
   documents are read end to end, **Then** none of them instructs the reader to change a file's
   permissions in order to make the bridge runnable.

---

### Edge Cases

- **The entry point is executable anyway** (the developer install route, or a host new enough to
  restore modes). Behaviour, exit codes and output must be indistinguishable from the stripped case
  — otherwise the extension has two behaviours and only one of them is tested.
- **One port present, the other missing.** Still a named degraded cause naming the absent file; the
  present port keeps running.
- **The consumer invokes by bare path from an old copy of the readme** on a stripped tree. The
  operating system refuses before any of our code is reached, so nothing we ship can intercept it —
  which is precisely why the shipped documents must no longer lead a reader there.
- **A checkout mounted read-only, or with execution disabled at the mount level.** The extension
  must not depend on being able to change a mode it might not be permitted to change.
- **The Windows port**, where the concept does not exist. It must not gain a permission notion, and
  its messages must change in step with the Bash port's so the two ports keep producing identical
  output.
- **A re-install or upgrade landing on top of a working tree.** Whatever mode the host writes, the
  next command works.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A consumer MUST be able to complete every documented post-install step on a freshly
  installed extension without changing any file's permissions, on every host version the extension
  declares support for and by either install route the host provides.
- **FR-002**: Every invocation form the extension publishes — command documents, message literals in
  run summaries and warnings, and the installation and readme documents — MUST be spelled identically
  in all of them. (That each of those forms *runs* on a permission-stripped tree is FR-009's
  obligation; this requirement carries only the identical-spelling half, so the two are testable
  separately.)
- **FR-003**: The prerequisite gate MUST NOT stop a run, and MUST NOT report an incomplete install,
  on the sole ground that an entry point is not executable.
- **FR-004**: The bridge MUST continue to detect a genuinely absent entry point of either port,
  report it as its own named degraded cause, and name a remedy that restores it.
- **FR-005**: No message, command document, or installation document the extension ships may
  instruct a consumer to change a file's permissions in order to make the bridge runnable. The
  existing instruction to restrict the local credentials file to its owner is explicitly out of this
  prohibition: it is a secrecy control, not a runnability one.
- **FR-006**: The Bash and PowerShell ports MUST keep producing byte-identical output for the same
  command, message literals included, after this change.
- **FR-007**: An extension tree already installed in the non-executable state MUST become fully
  functional through the host's normal extension upgrade alone, with no manual step before or after
  it.
- **FR-008**: The extension MUST NOT change the permissions of any file in the consumer's repository
  in order to satisfy the requirements above.
- **FR-009**: For a given command and a given repository state, the outcome, exit code and output
  MUST be identical whether or not the entry points carry the executable bit.
- **FR-010**: The extension MUST NOT satisfy this feature by raising the minimum host version it
  declares support for.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Unaffected in substance. The feature changes how the bridge is invoked and what it reports, never what it reads or writes. It introduces no third exception, and FR-008 forbids it from so much as changing a file's mode. |
| II | Zero-Churn Idempotency | No new writes of any kind. FR-009 demands byte-identical output between a permission-stripped tree and a normal one, and User Story 2's second scenario re-asserts the zero-write second run on the stripped tree. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Restores the principle where it is currently violated: today a lost file mode blocks a hook that must never block. FR-003 removes the blockage; FR-004 keeps a genuinely absent entry point a named, non-blocking degraded cause with the spec-kit command completing normally. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected. No credential path, storage or lookup changes. The one permission instruction that survives — restricting the local credentials file to its owner — is a control under this principle, and FR-005 exempts it by name. |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected. No configuration file, key, location or precedence rule changes. |
| VI | macOS / Linux / Windows Portability | Central to the feature. The executable bit is a POSIX-only notion the Windows port never had; removing the dependency makes the two ports structurally alike instead of accidentally divergent. FR-006 holds the message literals byte-equivalent so the conformance corpus proves it rather than asserting it. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. No Jira interaction, field, type or transition is touched. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Unaffected. The change lives entirely in the entry, prerequisite and message layers of each port. No engine decision and no sink call moves, and no Jira knowledge enters the port infrastructure. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. The feature emits no new content into the tracked tree or into Jira, so there is nothing new for the guard to classify. |
| X | Self-Healing Automatic Mirror | Restores it where a file mode currently defeats it: a mirror that cannot start is not self-healing. The healing is achieved by removing the dependency, not by mutating the consumer's tree — FR-008 keeps the principle from being read as a licence to write outside the mirror. |
| XI | Universal Dry-Run and Auditability | Unaffected. Every command keeps its dry-run and its run summary, and FR-009 requires both to be unchanged by the permission state. |
| XII | Quality and Catalog Publication | Ships with a CHANGELOG entry, a green three-OS matrix, clean lint on both ports, and a dogfood install onto a real consumer project by the mode-stripping route on a host below the version that restores modes — the exact combination that produced the defect. |
| XIII | TDD With a Minimum 80% Coverage | The failing test comes first, in both ports: a conformance case that installs the tree with the executable bit cleared and asserts a successful run and unchanged output. The existing invocation-literal, agent-document and bridge-runnable tests are updated inside the same change, never afterwards. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Not depending on a bit we cannot guarantee is simpler than detecting it, repairing it, or negotiating a host version that sets it. FR-008 and FR-010 record the two more complicated alternatives as forbidden, and the Assumptions say why each was rejected. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Scope is exactly the reported defect. No permission repair, no host-version negotiation, no PATH installation, no new command. `docs/VISION.md` contains no item this feature satisfies and gains none from it. |
| XVI | Human Readable — Readable by a Human Above All | The change is subtractive where it can be: one gate clause disappears, one invocation form is spelled the same way everywhere it appears. Messages keep naming the actual file a human would go and look at, so a broken install stays diagnosable by reading. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A consumer following the documented install and verification runs the bridge
  successfully on the first attempt, with zero permission commands, on every cell of the supported
  matrix: install route `{--dev copytree, --from zip}` × host version `{the declared floor, current}`.
  The zip × floor cell is the one that produced the defect and is proven by the dogfood step; if no
  host at the floor version is available, that cell is recorded as not reproducible rather than as a
  pass.
- **SC-002**: Zero occurrences remain, anywhere in the shipped tree, of an instruction to change a
  file's permissions in order to run the bridge.
- **SC-003**: For every command in the suite, a permission-stripped tree and a normal tree produce
  byte-identical output and the same exit code.
- **SC-004**: A repository already stuck in the broken state becomes fully functional in exactly one
  step — the extension upgrade — with no manual command before or after it.
- **SC-005**: A genuinely missing entry point is still reported as a named cause on the first run
  that touches it, and the remedy that cause names restores service.
- **SC-006**: Install-time support reports attributable to file permissions fall to zero after the
  release.

## Assumptions

- The consumer's machine can run the port's interpreter; the defect is about a file's mode, never
  about a missing runtime. The existing prerequisite checks continue to cover the runtime.
- The host's delivery of extension files is outside this project's control and may change again in
  either direction. The feature's durability comes from not depending on it, which is why raising
  the declared minimum host version (FR-010) is rejected: it would help only hosts no consumer is on
  yet while leaving every already-installed tree broken.
- Repairing the mode from inside the extension is rejected for three reasons: it makes the extension
  write to the consumer's tree for a reason unrelated to the mirror, it can fail silently on
  read-only or execution-disabled checkouts, and it would have to run again after every re-install.
  FR-008 states this as a requirement rather than leaving it a preference.
- The repository's own version-control index may keep recording the entry point as executable. That
  is harmless and is left alone: after this feature nothing reads the bit, so its value carries no
  meaning either way.
- The Windows port does not exhibit the defect — it is invoked through its interpreter — but its
  message literals change in lockstep with the Bash port's, because the conformance corpus requires
  the two ports to emit identical text.
- Consumers upgrade through the host's normal extension update path. No migration of previously
  mirrored tickets, configuration or hooks is involved; this feature changes nothing a consumer has
  already written.
- "Supported host version" means the range the extension manifest declares today, unchanged by this
  feature.
