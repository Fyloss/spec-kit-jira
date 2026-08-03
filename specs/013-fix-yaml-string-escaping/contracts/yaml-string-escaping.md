# Contract: String Escaping in the Configuration YAML Subset

**Feature**: 013-fix-yaml-string-escaping | **Date**: 2026-08-03

This is the contract between the two implementations, and between the writer and the reader. Both
ports MUST implement it identically; any divergence is a Constitution VI failure.

**Supersedes** `specs/007-fix-unicode-config-keys/contracts/yaml-key-grammar.md` **§2.3** ("What the
writer refuses"). Every other section of that document — the key grammar of §1, the
quote-every-key rule of §2.1, the round-trip guarantee of §2.2, and the byte-equivalence notes of
§3 — remains in force and is extended, not replaced, by what follows.

Scope: the **content** of a double-quoted scalar. Indentation, sequences, comments, the supported
scalar forms, and the key grammar are unchanged.

---

## 1. Writer — encoding a string

### 1.1 The escape set

Inside the double quotes it already emits, the writer replaces exactly two characters:

| Character | Emitted as |
| --- | --- |
| `\` (U+005C) | `\\` |
| `"` (U+0022) | `\"` |

Applied in that order — backslash first, then quote. Reversing the order double-escapes the
backslash the first replacement introduces.

**No other character is altered.** In particular:

- A TAB (U+0009) is emitted **literally**, not as `\t`. It is a legal character in a double-quoted
  scalar and round-trips correctly; encoding it would produce a sequence §2 does not decode.
- Non-ASCII text is emitted as raw UTF-8, never `\u`-escaped, preserving `yaml-key-grammar.md` §3.

### 1.2 Where it applies

To every string the writer emits inside double quotes: mapping **keys** (which §2.1 of the
superseded contract already quotes unconditionally), string **values**, and string **sequence
items**.

### 1.3 Consequences, normative

| Logical text | Emitted scalar |
| --- | --- |
| `Platform "legacy"` | `"Platform \"legacy\""` |
| `Delivery\Platform` | `"Delivery\\Platform"` |
| `Group "A\B"` | `"Group \"A\\B\""` |
| `trailing\` | `"trailing\\"` |
| `\"` (two characters) | `"\\\""` |
| `Élevée 完了` | `"Élevée 完了"` |
| `clean` | `"clean"` |

The last row is the compatibility anchor: for any string containing neither character, the emitted
bytes are identical to those the writer produced before this feature.

### 1.4 What the writer refuses

A key, string value, or sequence item containing **LF (U+000A) or CR (U+000D)** cannot be
represented on a single line. The writer MUST refuse it: a named error identifying the path at which
it occurred, and exit `EXIT_CONFIG` (4). It MUST NOT emit a partial document.

The error names the path, **never the value** — the value may be credential-shaped (Constitution IV,
NFR-3).

This replaces the superseded §2.3 rule, which refused `"` and `\`. Those two are now representable
by §1.1. The line-break case is not a narrowing of that rule but a hole it was incidentally
covering: before this feature a value carrying a line break and neither of the two characters was
written raw, producing a file the reader cannot parse.

When several paths are unrepresentable, the writer MUST report **every** one, deduplicated, before
exiting — not merely the first.

---

## 2. Reader — decoding a string

### 2.1 The decode walk

Given the body of a **double-quoted** scalar (delimiters already removed), the reader walks it left
to right:

1. On `\` followed by `"` — emit `"`, advance two.
2. On `\` followed by `\` — emit `\`, advance two.
3. On `\` followed by anything else, **or by end of body** — emit `\`, advance one.
4. On any other character — emit it, advance one.

Rule 3 is normative, not a fallback: a backslash forming no recognised escape is **kept literally**
and is **not** a parse failure. It is reachable only in a hand-maintained file, since §1.1 never
emits one, and it is what keeps `path: "C:\Users\shared"` loading unchanged.

### 2.2 Where it does not apply

No escape sequence is interpreted in:

- an **unquoted** scalar;
- a **single-quoted** scalar;
- a **bare** mapping key.

These forms are unchanged by this feature. The writer emits none of them for a string.

### 2.3 Escape-aware line scanning

Two scans that precede the decode MUST also honour §2.1, or the scalar is mangled before it reaches
the decoder.

**Inline-comment stripping.** While inside a double-quoted region, a `\` consumes the following
character without changing quote state. Therefore `key: "say \"hi\" # not a comment"` retains its
`#`: the region is still open when the `#` is reached.

**Quoted-key closing scan** (`yaml-key-grammar.md` §1.1 step 1). When the opening quote is `"`, the
closing quote is the next `"` **not preceded by an escaping backslash**. The key of
`"say \"x\"": v` is therefore `say \"x\"` before decoding, `say "x"` after.

Both exclusions of §2.2 apply here too. In particular the **bare-key** scan
(`yaml-key-grammar.md` §1.2) stays non-quote-aware and non-escape-aware, so `Won't Do: "10004"`
keeps parsing (007 research R1).

### 2.4 Consequences, normative

| Line | Decoded result |
| --- | --- |
| `- "Platform \"legacy\""` | sequence item `Platform "legacy"` |
| `- "Delivery\\Platform"` | sequence item `Delivery\Platform` |
| `k: "trailing\\"` | value `trailing\` |
| `k: "\\\""` | value `\"` |
| `k: "C:\Users\shared"` | value `C:\Users\shared` (rule 3, no failure) |
| `k: "say \"hi\" # x"` | value `say "hi" # x` — the `#` is inside the string |
| `"say \"x\"": v` | key `say "x"`, value `v` |
| `k: 'a\"b'` | value `a\"b` — single-quoted, no decoding (§2.2) |
| `Won't Do: "10004"` | key `Won't Do`, value `10004` |

---

## 3. Round-trip guarantee

For every document the writer accepts, reading back what it produced yields that same document.
Extending `yaml-key-grammar.md` §2.2, this now holds for keys, values, and sequence items
containing:

- `"` and `\`, in any position and any quantity, including adjacent to a delimiter and at the end of
  the text;
- the two-character text `\"`, which MUST remain distinct from an escaped quote;
- any run of consecutive backslashes, preserved in count.

Two logical texts differing only by these characters MUST remain distinct values. No normalisation,
stripping, or folding may be used to satisfy any rule in this contract.

---

## 4. Byte-level equivalence between the ports

The rules above are stated over characters. Both ports MUST reach the same verdict and emit the same
bytes for the same input.

- **UTF-8 safety**: `"` (`0x22`) and `\` (`0x5C`) cannot occur as any byte of a multi-byte UTF-8
  sequence, whose continuation bytes are all in `0x80`–`0xBF`. Bash's byte-wise scanning and
  PowerShell's UTF-16 character scanning therefore agree, by the same argument
  `yaml-key-grammar.md` §3 makes for `:` and `'`.
- **Line endings**: a trailing `\r` is stripped before any of this applies, as today. A `\r` that is
  not a line terminator falls under §1.4.
- **Refusal output**: both ports print the same lines, in the same order, for the same
  unrepresentable document — see §1.4's last paragraph.
