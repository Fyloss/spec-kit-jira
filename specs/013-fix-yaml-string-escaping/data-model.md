# Phase 1 Data Model: Survive Jira Labels Containing Quotes and Backslashes

**Feature**: 013-fix-yaml-string-escaping | **Date**: 2026-08-03

This feature introduces no new entity and no new configuration key. What it defines is the set of
**representations a single string scalar takes along its path**, and the transitions between them.
Every requirement in the spec is a property of one transition.

---

## 1. The four representations

A Jira label is one logical value with four spellings. Only the second is new.

| # | Representation | Where it lives | The reported label |
| --- | --- | --- | --- |
| 1 | **Logical text** | In memory, in the API payload, in a prompt, in a comparison | `Platform "legacy"` |
| 2 | **Escaped body** | Between the delimiters of a double-quoted scalar on disk | `Platform \"legacy\"` |
| 3 | **Delimited scalar** | One field of a line in the file | `"Platform \"legacy\""` |
| 4 | **Line** | A full line, with indent, key or `- ` marker, and any trailing comment | `  - "Platform \"legacy\""` |

Representation 1 is authoritative. Representations 2–4 exist only to store it, and the whole
contract is that the trip 1 → 4 → 1 is the identity function.

---

## 2. Transitions

```text
                    encode (R2)              wrap                  emit
  logical text ───────────────▶ escaped body ─────▶ delimited ──────────▶ line
       ▲                                                                    │
       │                                                                    │ read
       │              decode (R3)             unwrap            isolate     ▼
       └──────────────────────────────────────────────────────────────── line
```

| Transition | Owner | Rule |
| --- | --- | --- |
| **encode** | Writer | Replace `\` with `\\`, **then** `"` with `\"`. Order is load-bearing (research R2). Every other byte — tab, non-ASCII — passes through untouched. |
| **wrap** | Writer | Surround with `"`. Unchanged from today, and applied to every key unconditionally (yaml-key-grammar §2.1). |
| **isolate** | Reader | Strip the indent, strip any trailing comment, split key from value, or strip the `- ` marker. **Escape-aware** for the first two (research R4). |
| **unwrap** | Reader | Remove the outer `"`. Unchanged from today. |
| **decode** | Reader | Left-to-right walk: `\"` → `"`, `\\` → `\`, any other `\x` → `\x` verbatim. |

### 2.1 Invariants

- **I1 — Round trip**: `decode(encode(v)) == v` for every logical text `v` the writer accepts.
  Verified in research R3 across seven cases including `\"literal` and `trailing\`.
- **I2 — Fixed point**: `read(write(d)) == d` for every document `d` the writer accepts (FR-018).
- **I3 — Determinism**: `encode` is a pure function of the value; equal inputs give equal bytes
  (FR-017).
- **I4 — Backward identity**: for any `v` containing neither `"` nor `\`, `encode(v) == v`, so the
  file is byte-identical to what today's writer produces (FR-017, FR-022).
- **I5 — Distinctness**: `encode` is injective. `Platform "legacy"` and `Platform legacy` have
  different escaped bodies and never collapse (FR-006).

---

## 3. Which characters may appear in which representation

| Character class | Logical text | On disk | Rule |
| --- | --- | --- | --- |
| Ordinary text, any script | yes | verbatim | Non-ASCII is never `\u`-escaped — 007's unicode keys stay byte-identical (research R2) |
| `"` (U+0022) | yes | `\"` | FR-014 |
| `\` (U+005C) | yes | `\\` | FR-015 |
| TAB (U+0009) | yes | verbatim | Legal literal in a double-quoted scalar; round-trips today and must keep doing so (research R2) |
| LF (U+000A), CR (U+000D) | **no** | — | **Refused**, `EXIT_CONFIG`, path named, value never printed (FR-020) |

The refusal predicate changes from `test("[\"\\\\]")` — the two characters this feature makes
representable — to a test for a line break, and only that. Nothing else moves in or out of the
refused set.

---

## 4. Reader states (the isolate step)

The comment stripper and quoted-key scan walk a line as a small state machine. Escape-awareness is a
transition that exists in exactly one state.

| State | Entered by | `\` behaviour | Why |
| --- | --- | --- | --- |
| `PLAIN` | start of line | ordinary character | Bare scalars carry no escapes (FR-013) |
| `IN_DOUBLE` | `"` while `PLAIN` | **consume the next character** | The escaped form lives here |
| `IN_SINGLE` | `'` while `PLAIN` | ordinary character | Single-quoted scalars unchanged (FR-013) |

The **bare-key** scan (`config.sh:265`) is outside this machine entirely and stays that way: feature
007 research R1 requires `Won't Do: "10004"` to parse, which a quote-aware scan would break.

---

## 5. Entity mapping to the spec

The spec's Key Entities are not new data structures; they are places representation 1 must hold.

| Spec entity | Stored as | Requirement it carries |
| --- | --- | --- |
| Introspected label | Logical text, from `discovery.sh:217` | FR-002 — preserved character-for-character along the whole path |
| Allowed-value list | Sequence of delimited scalars, `- "…"` | FR-003 displayed as logical text; FR-004 matched as logical text |
| Resolved-id table | Mapping whose **keys** are labels | FR-010 — the quoted-key scan must find the right delimiter colon |
| Recorded field default | Delimited scalar in the committable config | FR-021 — same rules, shared serialiser |
| Refusal | Not stored; a path plus a reason on stderr | FR-020 — value never printed (Constitution IV) |

The resolved-id table is the reason FR-010 exists as a separate requirement: labels appear there as
mapping **keys**, not only as values, and the key path has its own scan with its own bug.
