# Feature Specification: The Local Binding Survives Names the Jira Instance Actually Uses

**Feature Branch**: `fix/config-issues`

**Created**: 2026-07-30

**Status**: Draft

**Input**: User description: "Bug report: a Jira name containing any character outside a narrow ASCII set silently destroys the entire local binding file."

## Context

The extension discovers a Jira project's issue types, priorities and statuses and records
the resolved identifiers in the gitignored local binding file (`.specify/jira/config.local.yml`,
Constitution V). Those keys are names chosen by the Jira administrator, in the language and
the punctuation of the instance: `Récit`, `Élevée`, `À faire`, `Terminé`, `完了`, `Приоритет`,
`Größe`, and equally in an English-only instance `Done (QA)` or `high/low`.

The file the extension writes is correct. The file it reads back is not. The reader accepts a
key only if every one of its characters belongs to a short enumerated set — letters, digits,
underscore, dot, apostrophe, space, hyphen — and stops parsing the moment a line fails that
test, returning what it had gathered so far. Because keys are emitted in sorted order, the
first non-conforming key truncates everything after it: in the reported reproduction a binding
holding four issue types, three priorities, four statuses and the project style read back as a
single empty issue-type map. Nothing was reported. No warning, no error, exit code zero.

Two consequences follow, and both are serious. The first is data loss that looks like
absence: reconcile receives a binding that says the project is unbound or half-bound, and
behaves accordingly. The second is that the loss is invisible — the operator has no signal
distinguishing "this project was never configured" from "your configuration was discarded
while being read".

The defect is present identically in both implementations, which is why the conformance suite
never saw it: that suite proves the two ports agree with each other, and here they agree on
being wrong. Detecting a shared defect requires a fixture that asserts against expected
content, not against the other port.

This feature makes the binding file survive the names a real Jira instance produces, and
makes any line the reader genuinely cannot interpret fail loudly instead of vanishing.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A binding written in the instance's own language reads back whole (Priority: P1)

As a developer whose Jira instance names its issue types, priorities and statuses in French,
German, Russian, Japanese — or in English with parentheses and slashes — I configure the
project once and every later command sees the complete binding I configured.

**Why this priority**: This is the reported defect and it silently disables the extension for
any instance that is not narrowly ASCII-and-plain. It also disables English-only instances,
because `Done (QA)` and `high/low` are ordinary Jira status names. Nothing else in this
feature matters until a written binding can be read back.

**Independent Test**: Write a binding containing keys in several scripts and with common
punctuation, read it back, and assert the parsed result is identical to what was written —
every project, every issue type, every priority, every status, every scalar.

**Acceptance Scenarios**:

1. **Given** a binding whose issue-type map contains both `Récit` and `Story`, **When** the
   configuration is read, **Then** both entries are present with their recorded identifiers,
   and no entry that follows them in the file is missing.
2. **Given** a binding whose status map contains `Terminé`, `Won't Do`, `À faire` and `完了`,
   **When** the configuration is read, **Then** all four statuses are present with their
   recorded identifiers.
3. **Given** a binding whose status map contains `Done (QA)` and whose priority map contains
   `high/low`, **When** the configuration is read, **Then** both are present — an English-only
   instance is not a special case.
4. **Given** a binding containing `resolved_ids`, `priorities`, `statuses` and `style` for a
   project, **When** the configuration is read, **Then** all four sections are present; no
   sibling key is lost because an earlier sibling's name was unusual.
5. **Given** a configuration value that is a bare URL such as `https://example.atlassian.net`,
   **When** the configuration is read, **Then** it is still read as a scalar value and never
   mistaken for a mapping key — the behaviour the original restriction existed to protect is
   preserved.

---

### User Story 2 - A line the reader cannot interpret is reported, never discarded (Priority: P1)

As a developer, if the binding file contains something the extension genuinely cannot
interpret, I am told which file and which line, in terms I can act on. I never receive a
silently shortened configuration.

**Why this priority**: Equal in priority to the first story and inseparable from it. The
character-set restriction is the cause of this specific data loss, but the discarding
behaviour is what made it undiagnosable, and it would hide the next parser gap just as
completely. Fixing the character set without fixing the silence leaves the failure mode in
place.

**Independent Test**: Feed the reader a file containing a line it cannot interpret at a
mapping level; assert the operation fails with a non-zero exit code, that the message names
the file, the line number and the offending content, and that no partial configuration is
handed to any caller.

**Acceptance Scenarios**:

1. **Given** a binding file containing an uninterpretable line, **When** any command reads the
   configuration, **Then** the command fails with a documented non-zero exit code and no
   caller receives a partially parsed configuration.
2. **Given** the same file, **When** the failure is reported, **Then** the message names the
   file path, the line number, the offending line content, and a copy-pasteable remediation.
3. **Given** the same file, **When** a command that would write to Jira reads it, **Then** zero
   Jira writes are attempted (Constitution III).
4. **Given** the same file, **When** the configuration is read from within an `after_*`
   lifecycle hook, **Then** the host spec-kit command still succeeds and the failure surfaces
   as a single actionable warning (Constitution III).

---

### User Story 3 - The conformance suite can catch a defect both ports share (Priority: P2)

As a maintainer, I need the shared test suite to fail when both implementations are wrong in
the same way, not only when they disagree.

**Why this priority**: This is what let the defect ship and what would let its recurrence ship
again. It is P2 only because the two P1 stories restore correct behaviour on their own; this
story protects it.

**Independent Test**: Apply the fix to one implementation only and run the shared suite;
assert it fails. Apply it to both; assert it passes.

**Acceptance Scenarios**:

1. **Given** a shared fixture whose keys include non-ASCII characters and common punctuation,
   **When** the suite runs, **Then** each implementation is asserted against the fixture's
   expected content, not merely against the other implementation's output.
2. **Given** the fix applied to only one implementation, **When** the shared suite runs on both,
   **Then** the suite fails.

---

### Edge Cases

- A key that itself contains a colon followed by a space, such as `Blocked: waiting on QA` —
  a legal Jira status name. It must round-trip, or the writer must emit it in a form the
  reader restores exactly.
- A key containing a space followed by `#`, such as `Sprint # 2` — the reader strips inline
  comments and must not amputate such a key.
- A key that begins with `- `, which would otherwise read as the start of a block sequence.
- A key whose name is entirely non-Latin, so that no character in it belongs to the previously
  enumerated set.
- An empty key (a line beginning with `:`), and a key that is only whitespace — these are
  malformed and must take the fail-closed path of User Story 2, not be silently accepted.
- A bare scalar such as a URL, which must remain a scalar (User Story 1, scenario 5).
- The same key appearing twice at the same mapping level — ambiguous, and therefore reported
  rather than silently resolved (FR-016).
- A file written with CRLF line endings, which the reader already tolerates and must continue
  to tolerate for every key form (Constitution VI).
- A binding whose keys sort such that the unusual key is the very first entry of the file, and
  one where it is the very last — truncation must be impossible at either position.

## Requirements *(mandatory)*

### Functional Requirements

**Reading and writing keys**

- **FR-001**: The configuration reader MUST accept a mapping key containing any character a
  Jira instance can place in an issue-type, priority or status name — including letters of
  any script, accented characters, and punctuation such as parentheses, slashes, apostrophes,
  ampersands and colons.
- **FR-002**: The reader MUST distinguish a mapping entry from a bare scalar by the structure
  of the line — what delimits the key — and MUST NOT decide by enumerating which characters a
  key may contain. An enumeration cannot express the set of characters Jira permits.
- **FR-003**: A bare scalar line that is not a mapping entry (for example a URL value on its
  own line) MUST continue to be read as a scalar and MUST NOT be interpreted as a key.
- **FR-004**: Any configuration the extension writes MUST read back identically: same keys with
  the same exact text, same values, same nesting, same ordering semantics, with nothing added
  and nothing dropped. This round trip is the acceptance condition for every key form named in
  User Story 1 and the Edge Cases.
- **FR-005**: The writer's key emission and the reader's key interpretation MUST remain a
  matched pair. Any change to how a key is emitted MUST be accompanied, in the same change, by
  the corresponding change to how a key is read back. A key form the writer can produce and
  the reader cannot restore is a defect of the same class as the one being fixed.
- **FR-006**: The written binding file MUST remain readable by a human reviewer without
  consulting documentation (Constitution XVI). Quoting is applied by one uniform rule rather
  than per key: "every key is quoted, as every string value already is" is a rule a reviewer can
  state in a sentence, where "quoted when the key would not survive bare" is a predicate a
  reviewer must evaluate line by line. Escaping, and any decoration beyond what that single rule
  requires, remain prohibited.

**Failing loudly**

- **FR-007**: When the reader encounters a line it cannot interpret at the current mapping
  level, it MUST fail closed: the read operation fails, and no caller receives a partially
  parsed configuration. Silently ending the parse and returning what was gathered so far is
  prohibited.
- **FR-008**: A read failure MUST exit non-zero with a documented error code, and that code
  MUST be documented alongside the extension's other error codes.
- **FR-009**: The failure message MUST name the configuration file path, the line number, the
  offending line content, and a copy-pasteable remediation (Constitution XVI). It MUST NOT be
  a bare code, and it MUST NOT print the value of any credential-shaped content.
- **FR-010**: When a configuration read fails, zero Jira writes MUST be attempted for the
  affected specification (Constitution III).
- **FR-011**: When the read failure occurs inside an `after_*` lifecycle hook, the host
  spec-kit command's exit code MUST be unaffected; the failure surfaces as a single actionable
  warning (Constitution III).
- **FR-012**: No code path may end a mapping parse other than by reaching a genuine structural
  boundary (a dedent, a sequence marker, or end of input) or by raising the FR-007 failure.
- **FR-016**: A key appearing twice at the same mapping level MUST take the FR-007 fail-closed
  path, and the failure MUST name both line numbers. A configuration in which two entries claim
  the same name is ambiguous, and resolving it silently in favour of one of them is the same
  class of invisible loss this feature exists to close. The same name at two different mapping
  levels is legal and unaffected.

**Both implementations, proven together**

- **FR-013**: Both the Bash and the PowerShell implementations MUST receive the change in the
  same commit and MUST produce identical results — identical parsed content, identical exit
  codes, identical messages (Constitution VI).
- **FR-014**: The shared conformance suite MUST gain a fixture whose keys include non-ASCII
  characters from more than one script and the punctuated ASCII forms named in User Story 1,
  and MUST assert each implementation against that fixture's expected content — not only
  against the other implementation's output.
- **FR-015**: The regression tests for this defect MUST be written first and observed to fail
  before any fix is applied (Constitution XIII and the repository's bug-fix policy).

### Key Entities

- **Local binding file** — the gitignored per-developer record of a project's resolved Jira
  identifiers (`.specify/jira/config.local.yml`). Its keys are names owned by the Jira
  administrator, not by the extension.
- **Mapping key** — the text naming an entry in the binding: a project key, an issue-type
  name, a priority name, a status name, or a structural key such as `resolved_ids` or `style`.
  Its character content is unconstrained in practice.
- **Malformed-line report** — the named failure raised when a line cannot be interpreted:
  carries the file, the line number, the line content, and a remediation.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Unaffected. This feature changes only how a local file is read and written; it introduces no Jira read, write, delete or adoption path. |
| II | Zero-Churn Idempotency | Reinforced. A truncated binding makes reconcile treat a bound project as unbound, which is precisely how zero-churn is lost; restoring the full binding restores the conditions idempotency depends on. No new write kind is introduced. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Directly implemented by FR-007, FR-008, FR-010 (fail closed, documented exit code, zero writes) and FR-011 (a hook still returns success to the host with one actionable warning). |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Preserved. Fixtures use issue-type, priority and status names only — no token, no auth email, no real site URL, no accountId. FR-009 forbids printing credential-shaped content in the failure message. |
| V | Separation of Team Config / Local Binding / Secrets | Preserved. The three layers are unchanged; this feature fixes the reading of layer 2 (and of layer 1, which shares the reader) and moves no configuration into the extension folder. |
| VI | macOS / Linux / Windows Portability | FR-013 requires both implementations to change in the same commit with identical behaviour; FR-014 strengthens the conformance suite so a defect shared by both ports is detectable. The CRLF edge case keeps Windows-written files readable. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Directly served. Enumerating permitted key characters was a hard-coded assumption about how a company names its statuses; FR-002 removes it. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Unaffected. The configuration reader is neutral infrastructure; no Jira identifier or Atlassian-specific term enters engine code as a result of this change. Fixture names are data, not code. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected. No change to the pre-write scan or its tiers. |
| X | Self-Healing Automatic Mirror | Improved indirectly: hook health reads the hook registry through this same parser, so a registry entry with unusual characters can no longer truncate it. No change to hook registration or to the permanence of an operator-disabled hook. |
| XI | Universal Dry-Run and Auditability | Unaffected for dry-run; served for auditability, since FR-007 to FR-009 turn a silent loss into a reported one that appears in the run summary. |
| XII | Quality and Catalog Publication | Served by a CHANGELOG entry, a green three-OS matrix, and the strengthened conformance fixture. The fix must be dogfooded against the real Jira instance whose names exposed it. |
| XIII | TDD With a Minimum 80% Coverage | FR-015 requires the regression tests first, observed red. New tests identify their fixtures by paths they themselves create, never by a machine-wide scan, so the suites stay green under parallel execution. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Serving FR-002 by structure rather than by enumeration is the simpler rule as well as the correct one; it removes a special case rather than adding one. No new dependency and no new abstraction. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Scope is limited to what these requirements demand. No general-purpose YAML support, no configuration option to select a parsing mode, no migration path — the out-of-scope list below is explicit. |
| XVI | Human Readable — Readable by a Human Above All | FR-006 keeps the written file reviewable under a single stateable rule; FR-009 requires the failure message to name the file, the line, the content and the remediation rather than a bare code, with credential-shaped content redacted (Constitution IV). |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A binding containing issue types, priorities and statuses named in French, German,
  Russian and Japanese, plus the punctuated English names `Done (QA)` and `high/low`, reads back
  with 100% of its entries — zero lost keys, zero lost sections, zero altered key text.
- **SC-002**: Zero silent truncations remain: every input line the reader cannot interpret
  produces a reported failure. No input exists for which a read returns a shortened
  configuration and a zero exit code.
- **SC-003**: An operator seeing the failure message can identify the offending file and line
  and correct it without opening the extension's source or its documentation.
- **SC-004**: A configuration read failure results in zero Jira writes, and inside a lifecycle
  hook leaves the host command's exit code unchanged.
- **SC-005**: Applying the fix to only one implementation leaves the shared suite failing; the
  suite passes only when both implementations carry it.
- **SC-006**: The regression tests are observed failing before the fix and passing after it, on
  all three operating systems in the CI matrix.
- **SC-007**: Statement coverage stays at or above the 80% gate for both implementations after
  the change.

## Assumptions

- The gitignored local binding file and the committable team config are read by the same
  configuration reader, so fixing the reader fixes both layers; the requirements are written to
  apply to any file that reader consumes, including the hook registry.
- The configuration files this reader consumes are UTF-8 encoded. Byte sequences that are not
  valid UTF-8 are treated as malformed input under FR-007, not as a supported case.
- The choice between quoting keys on write and leaving them bare is a design decision left to
  the plan; the specification constrains only the outcome (FR-004 round-trip fidelity, FR-005
  reader and writer changed together, FR-006 human readability).
- Documented error codes escalate monotonically, so the code chosen for an unreadable
  configuration slots into the existing scheme rather than reordering it (Constitution III).
- The reproduction quoted in the bug report was verified by execution and is treated as
  authoritative for the current behaviour; the fix is validated against it directly.
- Reading the file is the only thing at fault. The discovery step that produces the binding and
  the writer that serialises it are correct today, and this feature changes the writer only if
  round-trip fidelity requires it.

## Out of Scope

- Backward compatibility with binding files written by the current code, migration of existing
  `.specify/jira/config.local.yml` files, and any deprecation path. The extension has a single
  tester and no users; an operator whose binding was written before this change re-runs the
  configuration command.
- Becoming a general-purpose YAML parser. The reader's documented subset is unchanged apart
  from the key rule: multi-line scalars, anchors, aliases, tags, non-empty flow collections and
  complex keys remain out of scope.
- Any change to what is discovered from Jira, to how identifiers are resolved, or to what the
  reconcile engine does with the binding once it has been read correctly.
- Normalising, transliterating or case-folding key text. A key is preserved exactly as written;
  matching keys against Jira names is existing behaviour and is not revisited here.
- A configuration option governing parser strictness. Fail-closed is the decided behaviour, not
  a preference.
