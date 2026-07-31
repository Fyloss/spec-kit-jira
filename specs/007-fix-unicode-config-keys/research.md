# Phase 0 Research: The Local Binding Survives Names the Jira Instance Actually Uses

**Feature**: 007-fix-unicode-config-keys | **Date**: 2026-07-31

This document resolves every unknown the specification left to the plan. Each section states
the decision, why it was chosen, and what was rejected. Line references are to the code as it
stands on `fix/config-issues` at the time of writing.

---

## R1 — How a mapping entry is recognised

**Unknown**: FR-002 requires recognition by line structure rather than by an enumeration of
permitted characters, and FR-003 requires a bare URL to stay a scalar. What exact rule
satisfies both?

**Decision**: A line is a mapping entry when a *delimiter colon* can be located in it. The
delimiter colon is found by one of two mutually exclusive paths, chosen by the line's first
character:

- **Quoted key** — the line begins with `"` or `'`. The key is the scalar terminated by the
  next occurrence of that same quote character. The character immediately after the closing
  quote must be `:`, and that colon must be followed by whitespace or end of line. That colon
  is the delimiter; the key is the text between the quotes.
- **Bare key** — the line begins with anything else. The delimiter is the first `:` in the
  line that is followed by whitespace or end of line, scanned **without** any quote awareness.
  The key is everything before it, right-trimmed. The key must be non-empty.

A line in which no delimiter colon can be located is not a mapping entry.

**Rationale**:

- It is an inversion, not a wider enumeration. Nothing is said about which characters a key may
  contain, so `Élevée`, `完了`, `Приоритет`, `Done (QA)` and `high/low` all pass without being
  anticipated. This is the property the specification demands: Unicode cannot be enumerated.
- `https://example.atlassian.net` is still rejected, which was the original restriction's only
  real purpose: its colon is followed by `/`, not by whitespace or end of line.
- Byte-wise it is safe in UTF-8. No continuation byte of a multi-byte sequence can equal `0x3A`
  (`:`), `0x22` (`"`) or `0x27` (`'`) — every continuation byte is in `0x80`–`0xBF`. A byte-wise
  scan in Bash and a UTF-16 character scan in PowerShell therefore reach the same conclusion on
  the same input, which is what Constitution VI requires.

**Why the bare-key scan is deliberately *not* quote-aware**: `Won't Do` is a real Jira status
name and it parses correctly today. A quote-aware scan would open a single-quote region at the
apostrophe and never find the delimiter, so the status that motivated the apostrophe's presence
in the old character set would regress. Deciding quoted-versus-bare from the *first character*
of the line removes the ambiguity entirely: a key whose text needs quoting is quoted from
column one, and a key that is not quoted is scanned literally. This mirrors how
`_cfg_scalar_json` (config.sh:160) already decides whether a *value* is quoted.

**Alternatives considered**:

- *Widen the character class* (add parentheses, slashes, accented ranges). Rejected: it is the
  same defect with a longer list. The next Jira instance names a status something not on it,
  and the failure is identical.
- *Match a Unicode property class* (e.g. `\p{L}`). Rejected: Bash 3.2's `[[ =~ ]]` has no
  Unicode property support, so the two ports could not be made to agree — a direct Constitution
  VI failure. It also still enumerates, merely at a higher level: `Done (QA)` remains excluded.
- *One quote-aware scan for both forms*. Rejected: regresses `Won't Do`, as above.

---

## R2 — Whether the writer must quote keys, and which ones

**Unknown**: The specification (FR-004, FR-005, Assumptions) left the quoting decision to the
plan, constraining only the outcome.

**Decision**: **`config_to_yaml` / `ConvertTo-JiraConfigYaml` quote every key**, using the same
double-quote form already used for every string value. `Story: "10005"` becomes
`"Story": "10005"`. The reader accepts both quoted and bare keys (R1), so files this extension
does not write keep parsing unchanged.

**Rationale**:

- Several key forms cannot round-trip bare, and each of them is a name Jira can legitimately
  produce or a file an operator can legitimately hand-edit:

  | Bare key | What breaks it |
  | --- | --- |
  | `Blocked: waiting on QA` | the embedded `: ` becomes the delimiter; key and value both wrong |
  | `Sprint # 2` | `_cfg_strip_inline_comment` (config.sh:110) removes ` #…` before parsing |
  | `- pending` | read as the start of a block sequence, not as a key |
  | ` padded ` | leading/trailing whitespace is trimmed away and silently lost |

  Quoting neutralises all four at once. The inline-comment stripper is already quote-aware
  (config.sh:114-118), so a `#` inside a quoted key is protected with no change to that
  function. The sequence check (`content == "- "*`) can never match a line whose first
  character is `"`.
- One rule instead of a predicate. The alternative — quote only when necessary — needs a
  "would this key survive bare?" predicate implemented identically in two languages, while
  still requiring the reader to handle both forms. Quoting unconditionally deletes that
  predicate and its divergence risk. This is the Constitution XIV reading: the simplest change
  that satisfies the requirement.
- Constitution XVI is served, not harmed. Values in this file are already double-quoted, so
  `"Élevée": "1"` is *more* internally consistent than `Élevée: "1"`, and the file this writer
  produces is machine-owned (the resolved-id table filled by discovery) rather than the
  self-documenting team template a tech lead reviews.

**Consequence to accept**: the bytes of `config.local.yml` change. Backward compatibility and
migration are explicitly out of scope (spec, Out of Scope), so no reader-side compatibility
shim is written — the reader accepts bare keys because hand-written and PyYAML-written files
need it, not to read old output. Existing tests that assert written bytes are updated as part
of the change.

**Alternatives considered**:

- *Quote only keys that need it*. Rejected as above: more code, two ports to keep in step, no
  behavioural gain.
- *Leave the writer untouched and only fix the reader*. Rejected: it leaves the round trip open
  for `Blocked: waiting on QA` and `Sprint # 2`, which FR-004 forbids, and the bug report
  itself warns against fixing one side alone.

---

## R3 — Keys and values the writer cannot represent

**Unknown**: The current writer documents an unchecked assumption (config.sh:307-308) that no
key or value contains `"` or `\`. Quoting keys does not by itself make that true.

**Decision**: The writer **fails closed** when a key or a string value contains `"` or `\`:
a named error naming the offending path, and `EXIT_CONFIG` (4). No escaping is implemented.

**Rationale**: The reader strips quotes verbatim and performs no unescaping, so emitting such a
value would produce a file that reads back wrong — the same silent-corruption class this feature
exists to close. Refusing is a few lines in each port; implementing YAML escape sequences is a
reader change, a writer change and a new set of edge cases in both languages, for a character
that does not appear in Jira issue-type, priority or status names in practice. Constitution XV:
nothing is built before a requirement demands it, and refusing loudly is the honest way to not
build it.

**Alternatives considered**: *implement `\"` and `\\` escaping* — deferred, recorded as a known
limitation. *Say nothing and hope* — this is the status quo and is exactly the failure mode
under repair.

---

## R4 — How a malformed line fails, and how the failure travels

**Unknown**: FR-007 to FR-012 require fail-closed behaviour with a located, actionable message.
The parsers are mutually recursive Bash functions, where `return` does not unwind the stack.

**Decision**:

1. **Locate the line.** `_cfg_prep` (config.sh:130) currently retains two parallel arrays,
   `_cfg_indents` and `_cfg_lines`. A third, `_cfg_linenos`, records each retained line's
   1-based number in the source file. PowerShell's `Read-CfgPrep` gains `$script:CfgLineNos`.
   Without it no message can name a line, because blank lines and comments have been dropped.
2. **Raise, don't break.** In `_cfg_parse_mapping` (config.sh:210) the
   `_cfg_is_map_entry … || break` becomes a raise. At that point the loop has already broken out
   for both legitimate ends of a mapping — a change of indent (line 207) and a sequence marker
   (line 209) — so a line reaching the map-entry test and failing it is malformed, not a
   boundary. The same applies at Config.psm1:205.
3. **Propagate by flag.** A global `_CFG_ERR` (mirrored by `$script:CfgErr`) carries the message.
   Every parser loop returns immediately when it is set; `config_yaml_to_json` /
   `ConvertFrom-JiraConfigYaml` prints it to stderr and returns `EXIT_CONFIG`. A flag rather than
   PowerShell's `throw` because the two ports must have the same control flow and produce the
   same bytes (Constitution VI); a `throw` on one side and a global on the other is exactly the
   asymmetry that hides divergence.

**The one place that must NOT become an error**: `_cfg_parse_sequence` calls `_cfg_is_map_entry`
at config.sh:264 (Config.psm1:258) to decide whether `- something` opens a mapping or is a plain
scalar item. That is a *dispatch*, not a validity gate — `- jira` is a legal sequence of strings
and must keep falling through to the scalar branch. Only the mapping-level test becomes fatal.

**Message format** (identical in both ports, contract in `contracts/parse-failure.md`):

```
config: <file>:<line>: cannot parse this line as a mapping entry: <content>
config: a key must be followed by ": " — quote the key if it contains a colon, e.g. "Blocked: waiting": "10001"
config: re-run /speckit.jira.config to regenerate <file> from the Jira instance.
```

It names the file, the line number and the content (FR-009), and it ends with a copy-pasteable
remediation. The offending line's *content* is printed; if a credential-shaped value ever
appeared on it the existing credential scan refuses the file separately, and the parse error is
raised before any value is interpreted, so no token is ever formatted into this message.

---

## R5 — The callers that currently swallow the failure

**Unknown**: Making the parser return non-zero is not sufficient. Which call sites discard it?

**Decision**: Four sites change. Located by grep for `config_yaml_to_json` and `_cfg_local_json`;
each has a PowerShell twin that changes identically.

| Site | Today | After |
| --- | --- | --- |
| `_cfg_local_json` (config.sh:522) | `config_yaml_to_json … 2>/dev/null \|\| printf '{}'`; the comment promises "Never fails" | absent file still yields `{}`; a **present but unparseable** file propagates the message and `EXIT_CONFIG`. The comment is rewritten — the promise it makes is the defect. |
| `config_hooks_disabled_read` (config.sh:534) | consumes `_cfg_local_json` unconditionally | propagates the failure. Constitution X requires an operator-disabled hook to be respected forever; a binding we cannot read is not evidence that nothing is disabled. |
| `_reconcile_local_binding_for` (reconcile.sh:190) | `\| jq … 2>/dev/null`, so an unreadable binding is indistinguishable from an unbound project | propagates, so reconcile fails closed with zero Jira writes (FR-010, Constitution III) instead of behaving as if the project were unbound — the reported downstream symptom. |
| `config_personal_load` (config.sh:664) | `2>/dev/null` then a generic "not valid personal YAML" | lets the located message through, then returns `EXIT_CONFIG` as it already does. |

`register_hooks_health` (register_hooks.sh:271) keeps its own behaviour: it already returns
`EXIT_CONFIG` and reports the registry unreadable, which is fail-closed. It gains only the
located message in place of the generic one.

**FR-011 needs no new mechanism.** The hook-mode downgrade already exists — reconcile.sh:632-648
converts a non-zero exit into a single `WARNING:` line and returns success to the host command.
A configuration read failure travels that path like any other fault, so the host spec-kit
command's exit code is unaffected. This is verified by test, not assumed.

---

## R6 — Making the conformance suite able to see a shared defect

**Unknown**: FR-014. The harness (`tests/conformance/run-scenario.sh`) captures stdout, exit
code, the API call log and the post-run tree for each port, and the tests `diff` the two
captures. A defect both ports share produces two identical wrong captures and passes.

**Decision**: Use the pattern the suite already contains rather than adding a golden-capture
mechanism to the harness. `tests/bash/conformance/test_us1_style.bats` (lines 33-57) already
runs *one* port and asserts on the content of its capture, alongside the parity `diff`. The new
scenario follows it:

- **Fixture** `tests/conformance/fixtures/repo-with-unicode-binding/` — a repository whose
  `.specify/jira/config.local.yml` carries the bug report's reproduction: `Récit` and `Story`
  side by side, `Élevée`, `À faire`, `Terminé`, `完了`, `Won't Do`, `Done (QA)`, `high/low`, and
  the `style` scalar that the truncation ate.
- **Scenario** `tests/conformance/scenarios/us1-unicode-binding.json` pointing at it.
- **Assertions**, in both `tests/bash/conformance/` and `tests/powershell/conformance/`: the
  captured parse contains every expected key with every expected id — an assertion against
  *expected content*, which fails on both ports today — plus the usual byte-parity `diff`
  between the two captures.

Fixing one port only then leaves the suite red twice over: the unfixed port fails the content
assertion, and the pair fails the parity diff. That is SC-005.

**Alternatives considered**: *add an `expect` block to the scenario schema* and teach the
harness golden comparison. Rejected under Constitution XIV — it is a new harness capability
serving one scenario, when the suite already has an established way to assert content.

---

## R7 — Test inventory, written first

**Decision**: The regression tests below are written and observed failing before any source
change (FR-015, Constitution XIII). Each has a Bash (bats) and a PowerShell (Pester) form in the
existing files `tests/bash/lib/test_config.bats` and `tests/powershell/lib/Config.Tests.ps1`,
except the conformance ones.

| # | Test | Fails today because |
| --- | --- | --- |
| 1 | the bug report's exact document round-trips whole | the parser stops at `Récit` and returns `{"resolved_ids":{"JET":{"issue_types":{}}}}` |
| 2 | a key in each of four scripts (Latin-accented, Cyrillic, CJK, ASCII-punctuated) reads back | same |
| 3 | `Done (QA)` and `high/low` read back | the old class excludes `(`, `)`, `/` |
| 4 | `Won't Do` still reads back | guards R1's non-quote-aware bare scan against regression |
| 5 | a bare URL value is still a scalar, not a key | guards FR-003 |
| 6 | `Blocked: waiting on QA`, `Sprint # 2`, `- pending` and a padded key survive the round trip | the writer emits them bare today |
| 7 | a malformed line fails with `EXIT_CONFIG`, naming file, line number and content | today it is discarded silently with exit 0 |
| 8 | a truncating parse is impossible: no input yields a short read and exit 0 | the defect itself |
| 9 | an unreadable binding makes reconcile perform zero Jira writes | `_reconcile_local_binding_for` reports "not bound" instead |
| 10 | an unreadable binding inside an `after_*` hook leaves the host exit code 0 with one WARNING | must be proven, not assumed |
| 11 | a key or value containing `"` is refused on write with a named error | the writer emits it and corrupts the file |
| 12 | conformance: the unicode fixture's expected content, per port, plus port parity | both ports truncate identically |
| 13 | a malformed line carrying a credential-shaped value is reported with the value redacted | today nothing is printed at all; the located message would print the line verbatim |
| 14 | a key repeated at the same mapping level fails, naming both lines; the same key at two levels stays legal | today the duplicate silently wins through jq |

Cases that must keep passing unchanged: the empty-collection fixed point (test_config.bats:432),
the quoted-`[]`-is-a-string rule (:449), the PyYAML flat-sequence registry parse (:455) and the
two-indentation equivalence (:490). All four exercise the parser at the same seam.

---

## Open questions

None. Every unknown the specification deferred to the plan is decided above.
