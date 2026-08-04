# Contract: the Markdown subset both ports implement

**Status**: normative. Where an implementation and this document disagree, this
document is right and the implementation is a bug.

This is the contract that makes FR-015 (byte-identical twin ports) provable. It
is deliberately *not* CommonMark: it is the smallest grammar satisfying FR-001
and FR-008 that two independently written parsers can implement without
consulting each other. Every rule is numbered so a test, a fixture, and a defect
report can all name the same thing.

**Totality**: every rule below either matches or falls through to the literal
rule. No input is an error, nothing is dropped except where a rule says so, and
the tokenizer has no failure mode (FR-005).

---

## Part A — Normalisation

**A1.** Input is a sequence of lines, already stripped of a trailing `\r` and of
speckit marker lines by the caller. The tokenizer never sees a line terminator
and therefore never pattern-matches one — no glob in either port may contain
`$'\r\n'` (`docs/10-windows-portability.md`).

**A2.** Tabs are not expanded. A tab counts as whitespace wherever "whitespace"
appears below.

**A3.** "ASCII punctuation" means `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`.

---

## Part B — Block segmentation

Lines are consumed top to bottom. Rules are tried in order; the first that
matches wins.

**B1 — Fenced code.** A line whose first non-space run is 3+ backticks opens a
fence; it closes at the next line whose first non-space run is 3+ backticks, or
at end of input. Emits `code` with `text` = the enclosed lines joined by `\n`,
**verbatim** — no inline tokenization (FR-007), no trimming. The info string
(`​```bash`) is discarded. An unclosed fence still emits its content.

**B2 — ATX heading.** `^#{1,6}[ \t]+(.*)$`. Emits `heading` with `level` = the
count of `#`, and `inline` = Part C applied to the remainder with any trailing
run of `#` and whitespace removed.

**B3 — Bullet item.** `^[ \t]*[-*+][ \t]+(.*)$`. Accumulates into a
`bullet_list`. Leading indentation is stripped: **nested lists flatten to one
level**, preserving order.

**B4 — Ordered item.** `^[ \t]*[0-9]{1,9}[.)][ \t]+(.*)$`. Accumulates into an
`ordered_list`. Source numbering is discarded — position determines the number.

**B5 — Blockquote.** `^[ \t]*>[ \t]?(.*)$`. The prefix is stripped and the
remainder re-enters block segmentation at B1. Quote nesting is not represented.

**B6 — Table row.** `^[ \t]*\|.*\|[ \t]*$`. Cells are split on unescaped `|`;
empty leading and trailing cells are dropped. A **delimiter row** — one whose
cells contain only `-`, `:` and whitespace, and at least one `-` — is discarded
entirely. Any other row emits a `paragraph` whose text is the cells joined by
` — ` (space, em dash, space), each cell tokenized by Part C.

**B7 — Blank line.** Closes the open block. Consecutive blanks collapse.

**B8 — Paragraph (fallthrough).** Any other line joins the open paragraph with a
single separating space, or opens one. A list ends at the first line that is not
a matching item — there is **no lazy continuation** (research §2).

### B9 — Selection cap

The caller keeps the first **two content blocks** — `paragraph`, `bullet_list`,
`ordered_list`, `code`. `heading` blocks do not consume budget and are carried
through in place; a `heading` with no content block after it is dropped. See
[data-model.md](../data-model.md) §4 for why.

---

## Part C — Inline tokenization

Scan left to right. At each position, try C1…C10 in order; the first match wins,
consumes its characters, and scanning resumes after it.

**C1 — Backslash escape.** `\` followed by an ASCII punctuation character (A3)
emits that character as literal text with no mark. `\` followed by anything else
emits both characters literally. *(FR-003)*

**C2 — Code span.** A run of N backticks opens; the span closes at the next run
of **exactly** N backticks. The enclosed text is literal — no escape processing,
no nested rules (FR-007) — and receives the `monospace` mark. An unclosed run
emits its backticks as literal text. *(FR-005, FR-007)*

**C3 — Autolink.** `<` + `http://` or `https://` + one or more characters that
are neither `>` nor whitespace + `>`. Emits one span whose `text` is the URL and
whose mark is `link` with that `href`.

**C4 — Image.** `![` alt `](` target `)`. Emits `alt` as literal text, or
`target` when `alt` is empty. The target is never rendered as a link. *(FR-010)*

**C5 — Link.** `[` label `]` `(` target `)`.
- The label ends at the first unescaped `]`; the target at the first unescaped `)`.
- The target is trimmed, then validated against `^https?://` **and** containing
  no whitespace. Link titles (`(url "title")`) are unsupported, so they fail this
  validation by construction.
- **Valid** → the label is tokenized by Part C (with C5 disabled — no nested
  links) and every resulting span gains a `link` mark carrying `href`.
- **Invalid** → degrades to the literal text `label (target)`, tokenized by Part
  C, with no link mark. Both the label and the target remain visible. *(FR-006)*

**C6 — Strikethrough.** `~~` … `~~` → `strikethrough`. A single `~` is literal.

**C7 — Strong.** `**` … `**` or `__` … `__` → `bold`.

**C8 — Emphasis.** `*` … `*` or `_` … `_` → `italic`.

### C9 — Delimiter matching (governs C6, C7, C8)

One rule, replacing CommonMark's flanking analysis:

1. The character immediately **after** the opening delimiter must exist and must
   not be whitespace.
2. The closer is the **nearest** later occurrence of the same delimiter whose
   immediately **preceding** character is not whitespace.
3. **Underscore only**: the character before the opener must be start-of-input,
   whitespace, or ASCII punctuation, **and** the character after the closer must
   be end-of-input, whitespace, or ASCII punctuation. This is what keeps
   `parse_description_blocks` and `customfield_10011` intact — see research §2.
4. No valid closer → every delimiter character is literal text. *(FR-005)*
5. The enclosed content is tokenized recursively with the new mark added to the
   inherited set. *(FR-004)*
6. **Depth cap: 8.** Beyond it, content is emitted as literal text with the
   marks accumulated so far. Bounds the pathological-nesting edge case
   deterministically in both ports.

**C10 — Raw HTML tag.** `<` followed by `/` or an ASCII letter, up to the next
`>` in the same text run, is **discarded**; inner text between tags survives via
normal scanning. A `<` that starts no such tag is literal. *(FR-010)*

**C11 — Literal (fallthrough).** The character is appended to the current text
run with the inherited marks.

---

## Part D — Emission

**D1.** Consecutive spans with equal `marks` are merged into one span. Non-
negotiable: without it the same input can yield two equivalent-but-different span
lists and FR-015 becomes unprovable.

**D2.** `marks` is sorted alphabetically by `kind` and is always emitted, `[]`
when empty.

**D3.** A span with empty `text` is dropped, unless dropping it would leave the
`inline` array empty — an empty array is the correct representation of empty
text.

**D4.** Serialisation goes through the shared canonical writer
(`lib/output.sh` / `Output.psm1`). The Bash port never calls `jq` directly.

**D5.** Spans are accumulated in-process and serialised **once per block** — no
subprocess per span (research §3, and the performance budget in the plan).

---

## Part E — Worked examples

These are normative: each becomes a conformance fixture.

| # | Input | Rendered text a reader sees | Marks |
|---|---|---|---|
| E1 | `**FR-012** applies` | `FR-012 applies` | `FR-012` bold |
| E2 | `run \`reconcile --dry-run\`` | `run reconcile --dry-run` | code monospace |
| E3 | `see [guide](https://ex.invalid/s)` | `see guide` | `guide` link |
| E4 | `see [guide](../local.md)` | `see guide (../local.md)` | none |
| E5 | `*a*, _b_, ~~c~~` | `a, b, c` | italic, italic, strikethrough |
| E6 | `\*not bold\*` | `*not bold*` | none |
| E7 | `2 * 3 * 4` | `2 * 3 * 4` | none (C9.1: space follows `*`) |
| E8 | `parse_description_blocks` | `parse_description_blocks` | none (C9.3) |
| E9 | `**bold with \`code\` inside**` | `bold with code inside` | all bold; `code` also monospace |
| E10 | `**unclosed` | `**unclosed` | none (C9.4) |
| E11 | `` `**not bold**` `` | `**not bold**` | monospace only (C2) |
| E12 | `![diagram](x.png)` | `diagram` | none |
| E13 | `<https://ex.invalid>` | `https://ex.invalid` | link |
| E14 | `<b>text</b>` | `text` | none (C10) |
| E15 | `a \| b` in a table row | `a — b` | none (B6) |
