# Feature Specification: Survive Jira Labels Containing Quotes and Backslashes

**Feature Branch**: `013-fix-yaml-string-escaping`

**Created**: 2026-08-03

**Status**: Draft

**Input**: User description: "Testing the extension against a consumer project surfaced a bug in the `config` command. The odd-looking value `"Platform \"legacy\""` comes from Jira, via introspection — it is an ordinary option label whose text contains double quotes. The YAML serialiser writes strings inside double quotes but never escapes the `"` and `\` characters, and the reader cannot decode them either, so it refused with exit 4 any value containing one, which made the resolved-id table impossible to write. The extension should be compatible with, and not break in, this kind of scenario."

## Context

The configuration ceremony introspects a Jira project — reading its issue types, its field schema,
and the values each field accepts — and records what it finds in the machine-owned local
configuration file: the allowed-value lists, and the resolved-id table mapping each human-readable
label to the identifier Jira assigned it.

**The labels are Jira's, not the bridge's.** A Jira administrator is free to name a select-list
option `Platform "legacy"` — an ordinary label carrying a quoted nickname — and introspection
returns it as-is. In the payload the bridge reads, such a value is spelled in escaped form, which
is why it looks unusual on first sight; the label itself is simply text containing two double-quote
characters. Nothing about it is malformed. The extension must carry it end to end: introspect it,
show it to the operator, record it, read it back, and match it against introspection on the next
run.

Today it cannot, because two components were built on the assumption that a string never contains a
double quote (`"`) or a backslash (`\`):

- The **writer** knows it cannot faithfully emit such a string, because the reader would not decode
  it. Rather than write a file that lies, it refuses the entire document with the
  configuration-error exit code, naming the path and never the value. One such label anywhere in
  the introspected metadata therefore blocks the whole file: not one entry is written — not the
  allowed-value lists, not the resolved-id table, nothing.
- The **reader** removes the outer quotes of a double-quoted scalar verbatim and interprets no
  escape sequence. Were such a value ever to reach the file, it would read back carrying literal
  backslashes it never had — `Platform \"legacy\"` instead of `Platform "legacy"` — with no error
  reported at all. That corrupted text now contains both forbidden characters, so any later write
  refuses in turn, and the configuration can never be rewritten.

The operator has no remedy. The value came from Jira, the file is machine-owned, and the only way
out available to them is to rename the option in Jira — which is not theirs to rename. Their
project simply cannot be configured.

The characters are not exotic. Quoted nicknames and parenthetical qualifiers are ordinary in
hand-maintained Jira option lists, and a backslash appears in any label carrying a path-like or
`DOMAIN\team` form. The class of value this bridge exists to record is exactly the class it
currently cannot record.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Configure a project whose introspection returns a quoted label (Priority: P1)

An operator runs the configuration ceremony against a Jira project where introspection returns a
select-list option labelled `Platform "legacy"`, appearing in the allowed values of several custom
fields. Today the ceremony refuses, writes nothing, and exits with the configuration-error code,
leaving the project unconfigurable. After this feature the ceremony completes normally: the
allowed-value lists and the resolved-id table are written with that label intact, and the operator
sees the ordinary success summary with no mention of an escaping concern.

**Why this priority**: This is the reported defect and the reason the feature exists. Without it the
bridge is unusable against any Jira instance that happens to use one of two ordinary punctuation
characters in a label — a total blocker with no operator-side workaround.

**Independent Test**: Run the configuration ceremony against introspection metadata containing a
label with an embedded double quote and one with an embedded backslash. Assert the command exits
successfully, the local configuration file exists, and it holds an entry for each label.

**Acceptance Scenarios**:

1. **Given** introspection returns an option labelled `Platform "legacy"`, **When** the operator
   runs the ceremony, **Then** it completes successfully and the value is recorded under its exact
   label.
2. **Given** introspection returns an option labelled `Delivery\Platform`, **When** the operator
   runs the ceremony, **Then** it completes successfully and the value is recorded under its exact
   label.
3. **Given** a label containing both characters, such as `Group "A\B"`, **When** the file is
   written, **Then** the ceremony completes successfully and the label is recorded whole.
4. **Given** the same quoted label appears in the allowed values of several fields, **When** the
   file is written, **Then** every occurrence is recorded and none of them refuses the document.
5. **Given** any such label, **When** the ceremony asks the operator a question listing the allowed
   values, **Then** the label is displayed as the text a human sees in Jira, with no stray
   backslash and no escape notation.

---

### User Story 2 - The label survives the whole round trip and matches on later runs (Priority: P1)

A label recorded during one ceremony must come back out of the file as the same text that went in,
must still be recognised as the same value when introspection reports it again on a later run, and
must be accepted when an operator records it as a field default. A re-run over an unchanged state
must rewrite the file byte-for-byte rather than drifting on each pass.

**Why this priority**: Equal to User Story 1. Writing the file is worthless if what is read back
differs from what was written — a label that reads back mangled no longer matches what introspection
reports, so identifier lookups miss, allowed-value checks reject values Jira accepts, and every run
looks like a change. This is what makes User Story 1 durable rather than a one-shot write.

**Independent Test**: Record a configuration containing labels with quotes and backslashes, read it
back, and compare with what introspection supplied; then re-run against unchanged introspection
results and compare the two files byte-for-byte.

**Acceptance Scenarios**:

1. **Given** a recorded label containing an embedded double quote, **When** any command loads the
   configuration, **Then** the label it sees is character-for-character the label introspection
   supplied.
2. **Given** a recorded label containing an embedded backslash, **When** the configuration is
   loaded, **Then** the backslash appears exactly once and no character is lost or doubled.
3. **Given** a label recorded in a previous run, **When** a later run introspects the same project,
   **Then** the label is recognised as the same value and its recorded identifier is reused rather
   than resolved afresh.
4. **Given** an operator records `Platform "legacy"` as a default for a field that accepts it,
   **When** the value is checked against the field's allowed values, **Then** it is accepted, not
   rejected as outside the allowed set.
5. **Given** a configuration written by the ceremony, **When** the ceremony re-runs against
   unchanged introspection results, **Then** the file is rewritten byte-for-byte identically and the
   run reports no change.
6. **Given** a mapping key — not only a value — containing a double quote, **When** the document is
   written and read back, **Then** the key round-trips unchanged and is not confused with the quotes
   delimiting it.

---

### User Story 3 - Read a file that already holds a value in escaped form (Priority: P2)

Should a configuration file already on disk contain a value written in escaped form — carried over
from an earlier attempt, produced by another tool, or written by hand — loading it must yield the
text that form denotes rather than text carrying literal backslashes.

**Why this priority**: Separable from the first two, and lower because the writer's refusal makes
such a file uncommon. But it is what keeps the fix honest: the reader and the writer must agree on
one spelling, and a file that decodes wrongly is a silent corruption that later refuses on every
write, wedging the configuration permanently.

**Independent Test**: Place a configuration file containing the line `- "Platform \"legacy\""` on
disk, load it, and assert the value read is `Platform "legacy"` with no backslash; then write it
back and assert success and byte-identical content.

**Acceptance Scenarios**:

1. **Given** a file whose allowed-value list contains the line `- "Platform \"legacy\""`, **When**
   any command loads the configuration, **Then** the value is `Platform "legacy"` and contains no
   backslash character.
2. **Given** that same file, **When** the ceremony rewrites it, **Then** the write succeeds instead
   of refusing, and the line is emitted in the form it was read from.
3. **Given** that file is loaded and written back with no other change, **When** the two files are
   compared, **Then** they are byte-identical.
4. **Given** a value in the escaped form appears both as a sequence item and as a mapping value,
   **When** the configuration is loaded, **Then** both decode identically.

---

### User Story 4 - A genuinely unrepresentable value still refuses, clearly and safely (Priority: P3)

Some values still cannot live on a single line of this file — a value carrying an embedded line
break, for instance. When one appears, the operator gets the same fail-closed behaviour they get
today: nothing written, a located error naming the path at which the value occurred, and never the
value itself printed.

**Why this priority**: The refusal is the safety net that made the original defect a blocked run
rather than a silently corrupted file. Narrowing what it refuses must not weaken how it refuses, and
a value that would corrupt the file must not slip through once the quote and backslash cases stop
reaching it.

**Independent Test**: Submit a document containing a string value with an embedded line break;
assert the write is refused with the configuration-error exit code, no file was created or modified,
and the error names a path without containing the value.

**Acceptance Scenarios**:

1. **Given** a value containing a line break, **When** the writer is asked to emit it, **Then** the
   whole document is refused with the configuration-error exit code and no partial file is left
   behind.
2. **Given** such a refusal, **When** the operator reads the error output, **Then** it names the
   path at which the value occurred and does not reproduce the value.
3. **Given** a value containing a double quote or a backslash and nothing else unrepresentable,
   **When** the writer is asked to emit it, **Then** it is written rather than refused — the refusal
   no longer fires for these two characters.

---

### Edge Cases

- **The reported label shape**, an option whose text is `Platform "legacy"`: recorded, read back,
  displayed, and matched identically at every step.
- **A backslash at the very end of a label** (`Group\`): the escape must not run past the closing
  delimiter and swallow it.
- **A run of consecutive backslashes** (`a\\\b`): each one is preserved and the count is unchanged
  after a round trip.
- **A label whose text is literally the two characters `\"`**: distinguishable from an escaped
  quote, and preserved through a round trip.
- **A quote adjacent to the delimiter**, the label `"quoted"` in its entirety: the outer delimiters
  stay distinguishable from the content's own quotes.
- **A trailing comment marker after an escaped quote** (`key: "say \"hi\" # not a comment"`): the
  comment stripper must not be fooled into truncating the value by miscounting the quote state.
- **A key containing an embedded quote followed by the delimiter colon** (`say "x": value`): the
  key/value split must land in the right place.
- **Two labels differing only in their quoting**, such as `Platform "legacy"` and `Platform legacy`:
  they stay distinct values and neither collapses onto the other.
- **A hand-maintained team configuration file** containing a double-quoted scalar with a backslash a
  human wrote literally, such as `path: "C:\Users\shared"`: must not become a parse failure.
- **Single-quoted and unquoted scalars** in a hand-maintained file: unchanged, no escape
  interpretation is introduced there.
- **A label that looks like an identifier**, such as `"10004"`: still reads back as text, not as a
  number.
- **A quote or backslash inside a value the privacy guard must redact**: redaction still fires on the
  value before any diagnostic line is printed.

## Requirements *(mandatory)*

### Functional Requirements

**End-to-end tolerance of introspected labels**

- **FR-001**: The configuration ceremony MUST complete and write its allowed-value lists and
  resolved-id table when introspection returns labels containing double quotes or backslashes,
  without asking the operator anything extra and without any warning specific to those characters.
- **FR-002**: A label MUST be preserved character-for-character along its whole path — from what
  introspection reports, through any question shown to the operator, into the recorded file, back
  out on the next load, and into any value sent to Jira. No step may add, drop, or alter a character.
- **FR-003**: When the ceremony displays a field's allowed values to the operator, each label MUST
  be shown as the text a human sees in Jira, with no escape notation and no stray backslash.
- **FR-004**: A value an operator records as a field default MUST be checked against the field's
  allowed values on the same terms, so a label containing these characters is accepted when Jira
  accepts it and rejected only when Jira would reject it.
- **FR-005**: Every command that reads the configuration MUST match a recorded label against its
  introspected counterpart, so that an identifier resolved during one ceremony is still found on a
  later run rather than re-resolved as if it were new.
- **FR-006**: Labels differing only by these characters MUST remain distinct values; no requirement
  here may be satisfied by stripping, normalising, or folding them away.

**Reading**

- **FR-007**: The configuration reader MUST decode an escaped double quote inside a double-quoted
  scalar, yielding the quote character as part of the value, wherever such a scalar may appear — a
  mapping value, a mapping key, or a sequence item.
- **FR-008**: The configuration reader MUST decode an escaped backslash inside a double-quoted
  scalar, yielding exactly one backslash character as part of the value.
- **FR-009**: A configuration file already on disk containing a value in escaped form MUST decode to
  the text that form represents. A file holding `- "Platform \"legacy\""` MUST load as
  `Platform "legacy"`, not as text carrying literal backslashes.
- **FR-010**: The reader MUST locate the end of a quoted key correctly when the key contains an
  escaped quote, so that the key/value split of the entry lands where the writer intended.
- **FR-011**: The reader MUST decide correctly whether a `#` begins a trailing comment when the line
  contains an escaped quote, so that a value is never truncated at a `#` belonging to it.
- **FR-012**: A backslash in a double-quoted scalar that does not form a recognised escape sequence
  MUST be kept literally and MUST NOT cause a parse failure. This case is reachable only in a
  hand-maintained file, since the writer never emits one.
- **FR-013**: The reader MUST keep accepting every form it accepts today — unquoted scalars,
  single-quoted scalars, unquoted keys, the empty collection forms, and the boolean and null
  spellings — with unchanged meaning. No escape interpretation is introduced for unquoted or
  single-quoted scalars.

**Writing**

- **FR-014**: The configuration writer MUST be able to emit any mapping key, string value, or string
  sequence item containing the double-quote character (`"`), and MUST NOT refuse a document on that
  ground.
- **FR-015**: The configuration writer MUST be able to emit any mapping key, string value, or string
  sequence item containing the backslash character (`\`), and MUST NOT refuse a document on that
  ground.
- **FR-016**: The written form MUST be unambiguous — a reader MUST be able to tell the delimiters of
  the text apart from quote characters belonging to the text itself, and a backslash belonging to
  the text apart from one introducing an escape.
- **FR-017**: The writer MUST remain deterministic: the same input yields the same bytes, with the
  same key ordering and the same layout as today for every document containing neither character.
- **FR-018**: The writer MUST remain a fixed point of the reader — reading back what it produced
  yields the document it was given, for every document it accepts.
- **FR-019**: A re-run of the ceremony over unchanged introspection results MUST rewrite the
  configuration file byte-for-byte identically, including when it holds labels with these
  characters.
- **FR-020**: The writer MUST still refuse, fail-closed and with no partial output, any key, value,
  or sequence item it cannot represent on a single line — a value carrying an embedded line break in
  particular. The refusal MUST use the pre-existing configuration-error exit code, MUST name the
  path at which the value occurred, and MUST NOT print the value.
- **FR-021**: Values recorded as defaults for mandatory fields MUST be subject to the same decoding,
  the same widened representation, and the same narrowed refusal, since they share the serialiser.

**Compatibility, equivalence, and safety**

- **FR-022**: Every configuration file that loads today MUST keep loading, with identical values,
  with the single intended exception of a double-quoted scalar containing a recognised escape
  sequence — which changes from corrupted text to the text it denotes (FR-009).
- **FR-023**: Both native ports MUST decode identically, produce byte-identical output for the same
  input, and reach the identical verdict — write or refuse — on every document, on all three
  supported operating systems.
- **FR-024**: The privacy guard MUST keep applying to values containing these characters: a
  credential-shaped value is redacted or blocked as it is today, and neither the new decoding nor
  the widened representation may create a path by which an unredacted value reaches an error message
  or a log line.
- **FR-025**: The written contract governing this file format MUST be updated to state the escape
  sequences, the decoding rule, the narrowed refusal, and the round-trip guarantee, so that the two
  ports are held to the same written rule rather than to each other's code.

### Key Entities *(include if feature involves data)*

- **Introspected label**: the human-readable name Jira reports for an issue type, a status, a
  priority, or a field option. Its characters are chosen by a Jira administrator and are not the
  bridge's to constrain. The subject of this feature.
- **Allowed-value list**: the set of labels a Jira field accepts, obtained by introspection and
  recorded so later runs can validate against it. The reported defect appeared here.
- **Resolved-id table**: the mapping from each introspected label to the identifier Jira assigned it,
  recorded so later runs need not resolve it again.
- **Recorded field default**: a value a team records for a mandatory Jira field, checked against the
  allowed-value list and stored through the same serialiser.
- **Refusal**: the fail-closed outcome for a document that cannot be faithfully represented —
  identified by a path, never by its content.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | The feature changes only how introspected values are spelled and decoded on disk, not which files exist or who owns them. No new read or write of any Jira ticket, no new delete path. FR-022 protects what is already on disk, and FR-009 restores a value the reader would otherwise silently damage — making the file a more truthful source, not less. |
| II | Zero-Churn Idempotency | FR-017 keeps the writer deterministic, FR-018 keeps it a fixed point of the reader, and FR-019 requires a re-run over unchanged introspection results to rewrite the file byte-for-byte. FR-005 stops a correctly recorded label from being re-resolved as if it were new, which is where churn would otherwise reappear. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-020 keeps the refusal intact for what remains unrepresentable — same exit code, no partial output, named path. The feature narrows *what* is refused; it does not soften *how*. FR-009 closes a silent-corruption path, which is the failure mode this principle exists to prevent. Hook dispatch is untouched. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | FR-020 keeps the rule that a refusal names the path and never the value; FR-024 requires the new decoding to open no route by which a raw value reaches a diagnostic. No credential is read, written, or newly stored. |
| V | Separation of Team Config / Local Binding / Secrets | The layer each value lives in is unchanged: allowed-value lists and the resolved-id table stay in the gitignored local binding, recorded defaults stay in the committable team configuration, secrets stay out of both. The feature is confined to the shared spelling of those files. |
| VI | macOS / Linux / Windows Portability | FR-023 requires identical decoding, byte-identical output, and an identical write-or-refuse verdict from both ports on all three runners; FR-025 puts the rule in the written contract so the ports are held to a specification rather than to one another. The shared conformance corpus gains the quoted label, the backslash label, the both-characters label, the escaped-form file, and the refused line break. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | This is the principle the defect violates, and the one the feature restores. The bridge assumed something about the characters a Jira administrator may use in a label; FR-001, FR-002, FR-014, and FR-015 remove that assumption, and FR-006 forbids satisfying any requirement by normalising a label into a shape the bridge finds easier. No label, option, field, or workflow name is compiled into either port. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Introspection and label semantics stay in the sink; the serialiser is shared infrastructure below both sides and knows nothing of Jira. Correcting what a string may contain crosses no interface and moves no Atlassian vocabulary into the engine. |
| IX | Two-Tier Privacy Guard, With an Allowlist | FR-024 keeps every value flowing through the existing two-tier guard unchanged — block, warn, or pass on the allowlist — including in the redaction applied before a parse-failure line is formatted. The feature adds no exemption and no new guard. |
| X | Self-Healing Automatic Mirror | Hook registration, health reporting, and repair are untouched. A configuration that could not previously be written now can, which lets the mirror operate where it was blocked — the mechanism itself is unchanged. |
| XI | Universal Dry-Run and Auditability | A preview of the ceremony must predict exactly the bytes a real run would write, refusals included, and continue to write nothing. FR-003 makes what the operator is shown match what would be recorded. No destructive operation is added or altered. |
| XII | Quality and Catalog Publication | Ships as a PATCH-level fix with a CHANGELOG entry, a green three-OS matrix, clean lint, and a dogfood run against the real consumer project whose quoted option label produced the defect. The CHANGELOG must state the one intended behaviour change of FR-022, since a value some deployments read with literal backslashes will start reading without them. |
| XIII | TDD With a Minimum 80% Coverage | Every requirement is a failing test first. The regression test is written before the fix and uses introspection metadata carrying a label whose text contains double quotes: today the ceremony exits with the configuration-error code and writes nothing, and it must complete and record the label afterwards. The reader's silent corruption (FR-009) and the refusal that survives (FR-020) each get their own test, so neither the bug nor the safety net can disappear unnoticed. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Two characters gain an escaped spelling, the reader learns to undo exactly those two, and the refusal list shrinks to what is genuinely unrepresentable. No new dependency, no new file, no new configuration key, no migration step, no normalisation layer, no general-purpose YAML implementation adopted. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Scope is the two characters the defect involves plus the line-break hole that closing them would otherwise expose (FR-020). Deliberately excluded as unrequired: escapes for tabs and other control characters, unicode escape sequences, multi-line and folded scalars, non-empty flow collections, anchors, aliases, tags, and any escape interpretation inside single-quoted or unquoted scalars (FR-013). FR-012 keeps an unrecognised escape literal rather than inventing a validation rule nothing asks for. |
| XVI | Human Readable — Readable by a Human Above All | FR-003 requires the operator to be shown the label as it appears in Jira, never in escape notation, so the odd-looking payload spelling stays an internal detail. The escaped spelling on disk must be the conventional one any standard tool would parse, so the local configuration stays inspectable by eye and a line like `- "Platform \"legacy\""` means what a reader assumes it means. The surviving refusal explains in plain language what cannot be represented and where, rather than relaying an internal encoding error. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can configure a Jira project whose introspection returns labels containing
  double quotes or backslashes in a single ceremony run, with zero manual edits to any configuration
  file and zero changes to the Jira instance.
- **SC-002**: 100% of introspected labels are preserved character-for-character from introspection
  through display, recording, and reload, verified over a corpus containing every arrangement listed
  under Edge Cases.
- **SC-003**: A label recorded in one run is matched to its introspected counterpart on the next run
  in 100% of cases, so zero identifiers are re-resolved and zero allowed-value checks reject a value
  Jira accepts.
- **SC-004**: A second ceremony run over unchanged introspection results produces a file
  byte-identical to the first, in 100% of runs, including for configurations holding these
  characters.
- **SC-005**: A configuration file already containing a value in escaped form loads with the value
  that form denotes, with zero backslashes introduced and zero manual edits required.
- **SC-006**: Both ports decode identically and produce byte-identical configuration files and
  identical refusal verdicts for every case in the shared conformance corpus, on all three supported
  operating systems.
- **SC-007**: Every configuration file that loads today loads with identical values afterwards,
  verified across the project's existing fixtures with zero regressions outside the single intended
  change of FR-022.
- **SC-008**: A value that genuinely cannot be represented is still refused with the pre-existing
  configuration-error exit code, leaving zero bytes written, and its error output contains the path
  and zero characters of the value, in 100% of cases.

## Assumptions

- The label originates in Jira and arrives by introspection. Its escaped appearance in the payload
  the bridge reads is a spelling of ordinary text, not a malformation: the label is
  `Platform "legacy"`, two double quotes and all. The bridge has no standing to reject it, and this
  specification treats accommodating it as the correct outcome rather than a tolerance for bad data.
- The observed exit code is the writer refusing. The reader is nonetheless in scope, because the two
  must agree on one spelling: a value the writer emits and the reader decodes differently is a
  silent corruption that refuses on every subsequent write, wedging the configuration permanently.
- The labels involved are ordinary single-line text differing only by these two characters. Line
  breaks are covered by FR-020 as a hole to close, not as a case observed in the field.
- The escaped spelling adopted on disk is the conventional one for double-quoted text, so a file
  written by this bridge remains readable by any standard YAML tool an operator might reach for, and
  a file written by such a tool is read as that tool intended.
- The supported scalar forms, the indentation style, sequences, comments, and the key grammar are
  otherwise unchanged; this feature touches the content of a double-quoted scalar and nothing else
  about the file format.
- Consumer-project specifics are deliberately generalised throughout: the labels used above
  (`Platform "legacy"`, `Delivery\Platform`, `Group "A\B"`) are illustrative placeholders, not the
  values observed in the reporting project.
