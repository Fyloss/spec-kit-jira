# Contract: Mapping-Key Grammar of the Configuration YAML Subset

**Feature**: 007-fix-unicode-config-keys | **Date**: 2026-07-31

This is the contract between the two implementations, and between the writer and the reader.
Both ports MUST implement it identically; any divergence is a Constitution VI failure.

Scope: the key half of a mapping entry. Values, sequences, indentation, comments, and the
supported scalar forms are unchanged by this feature and are not restated here.

---

## 1. Reader — recognising a mapping entry

Given a retained line (leading whitespace removed, inline comment already stripped), the reader
locates a **delimiter colon**. The path is chosen by the line's first character.

### 1.1 Quoted key

**When**: the first character is `"` or `'`.

1. Let `q` be that character. Find the next occurrence of `q`. If there is none, the line is
   **not a mapping entry**.
2. The character immediately following the closing `q` MUST be `:`.
3. That `:` MUST be followed by a whitespace character or by end of line.
4. If 2 or 3 fails, the line is **not a mapping entry**.
5. The **key** is the text strictly between the two `q` characters, taken verbatim: not trimmed,
   not unescaped. The **value text** is everything after the delimiter colon, left-trimmed.

No escape sequences are interpreted. A key therefore cannot contain its own quote character;
see §2.3.

### 1.2 Bare key

**When**: the first character is anything else.

1. Scan left to right for the first `:` that is followed by a whitespace character or by end of
   line. The scan is **not** quote-aware: quote characters inside the line are ordinary
   characters. (This is deliberate — `Won't Do: "10004"` must parse. See research R1.)
2. If there is no such `:`, the line is **not a mapping entry**.
3. The **key** is everything before that `:`, right-trimmed. The **value text** is everything
   after it, left-trimmed.
4. If the key is empty after trimming, the line is **malformed** — this is a parse failure
   (`parse-failure.md`), not simply "not a mapping entry".

### 1.3 Consequences, normative

| Line | Result |
| --- | --- |
| `Élevée: "1"` | mapping entry, key `Élevée` |
| `完了: "10003"` | mapping entry, key `完了` |
| `Won't Do: "10004"` | mapping entry, key `Won't Do` |
| `Done (QA): "10004"` | mapping entry, key `Done (QA)` |
| `high/low: "4"` | mapping entry, key `high/low` |
| `"Blocked: waiting": "5"` | mapping entry, key `Blocked: waiting` |
| `Blocked: waiting: "5"` | mapping entry, key `Blocked`, value text `waiting: "5"` |
| `style:` | mapping entry, key `style`, empty value text |
| `https://example.atlassian.net` | **not** a mapping entry — the colon is followed by `/` |
| `- jira` | not reached; the sequence check precedes the key test |
| `: "1"` | malformed — empty key |

### 1.4 Where a non-mapping-entry line is fatal, and where it is not

| Caller | Line is not a mapping entry |
| --- | --- |
| mapping parser, at the mapping's own indent | **parse failure** (`parse-failure.md`). The two legitimate ends of a mapping — a change of indent, and a sequence marker — are tested before the key test is reached, so nothing that arrives here is a boundary. |
| sequence parser, deciding whether `- x` opens a mapping | **not** a failure. The item is a plain scalar. `- jira` is legal. |

### 1.5 A key repeated at the same mapping level

A key already seen at the mapping level being parsed is **malformed** — a parse failure
(`parse-failure.md` §1), not a last-wins overwrite.

Today the duplicate silently wins: `_cfg_parse_mapping` appends both entries to `parts` and the
emitted `{"k":…,"k":…}` is resolved by jq in favour of the last. That is the same invisible loss
this feature exists to close, which is why the fail-closed path applies (FR-016).

Each mapping frame keeps its own set of seen keys. The set is scoped to the frame, so the same
name at two different levels — `"statuses"` under two different project keys — is legal and
common. Comparison is over the exact key text: no normalisation, no case folding (spec, Out of
Scope).

---

## 2. Writer — emitting a mapping entry

### 2.1 Every key is quoted

The writer emits `"<key>": <value>`, always, with the double-quote character. There is no
condition under which it emits a bare key.

Keys are emitted in ordinal-sorted order, and the document is otherwise byte-identical to what
the writer produces today. Determinism is unchanged: the same input JSON yields the same bytes.

### 2.2 Round-trip guarantee

For every JSON object the writer accepts, reading back the YAML it produced yields that same
JSON object. This holds in particular for keys containing:

- characters of any script, accented or not;
- `(`, `)`, `/`, `&`, `'`;
- `:` and `: `;
- ` #`;
- a leading `- `;
- leading or trailing whitespace.

### 2.3 What the writer refuses — SUPERSEDED

**Superseded by** `specs/013-fix-yaml-string-escaping/contracts/yaml-string-escaping.md` §1.1 and
§1.4. `"` and `\` are now representable via an escape the reader undoes (§1.1 there); the writer's
refusal narrows to a value containing a line break (§1.4 there). The rest of this document — §1,
§2.1, §2.2 and §3 — remains in force.

The paragraph below is retained for history only and no longer describes the writer's behaviour:

~~A key or a string value containing `"` (U+0022) or `\` (U+005C) **cannot** be represented,
because the reader performs no unescaping. The writer MUST refuse it: a named error identifying
the path at which it occurred, and exit `EXIT_CONFIG` (4). It MUST NOT emit the value.~~

The error names the path, never the value — the value may be credential-shaped
(Constitution IV, NFR-3). This rule is unchanged by the supersession.

---

## 3. Byte-level equivalence between the ports

The rules above are stated over characters. Both ports MUST reach the same verdict on the same
input file.

- **UTF-8 safety**: `:` (`0x3A`), `"` (`0x22`) and `'` (`0x27`) cannot occur as any byte of a
  multi-byte UTF-8 sequence, whose continuation bytes are all in `0x80`–`0xBF`. Bash's byte-wise
  scanning and PowerShell's UTF-16 character scanning therefore agree.
- **Whitespace** means space (`0x20`) or tab (`0x09`) for the purpose of §1.1 step 3 and §1.2
  step 1, matching the existing subset's treatment elsewhere.
- **Line endings**: a trailing `\r` is stripped before any of this applies, as today
  (config.sh:137).
- Input that is not valid UTF-8 is malformed input under `parse-failure.md`; it is not a
  supported case (spec, Assumptions).
