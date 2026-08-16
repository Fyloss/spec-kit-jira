# Data Model: Acceptance-Scenario Clause Recognition

**Feature**: 028-fix-gherkin-clause-parsing | **Date**: 2026-08-16

**The output schema does not change.** This feature alters which values fill it, never its shape. No field
is added, removed, renamed or retyped; no caller, validator or renderer sees a new form. What follows
documents the existing shape and pins the invariants this feature makes true of it.

---

## §1 The emitted structure (unchanged)

`parse_acceptance_criteria` / `Get-JiraParsedAcceptance` emit a canonical JSON **array of scenarios**, or
`[]`.

```
Scenario := { "given": [Clause], "when": [Clause], "then": [Clause] }
Clause   := [Span]                       # an inline sequence — feature 016
Span     := { "text": string, "marks": [Mark] }
```

| Field | Type | Notes |
| --- | --- | --- |
| `given` | array of Clause | one entry per Given (and per `And`/`But` continuation attached to it) |
| `when` | array of Clause | same |
| `then` | array of Clause | same; a scenario with an empty `then` is **never emitted** |

Each Clause is an array of Spans, never a bare string and never a bare Span object — the single-span case
must still be a one-element array. On the PowerShell side this is why every tokenizer call site is wrapped
in `@(...)` at the call site rather than inside the scriptblock; that existing constraint is unchanged and
still binding.

`Span`/`Mark` are owned by feature 016 (`specs/016-jira-markdown-rendering/contracts/`). This feature does
not touch them.

---

## §2 Entities

### Acceptance scenario

One Given/When/Then statement as the author wrote it. May occupy one source line or wrap across several
(§3). Emitted only once it reaches a Then.

### Clause

One part of a scenario, carrying the author's text for that part **and nothing belonging to another part**.
This is the invariant the defect broke: today a line the recogniser cannot split yields three clauses that
are all the same unsplit source text.

### Keyword

`Given`, `When`, `Then`, `And`, `But`. Belongs to the scenario's grammar, not to any clause's text. The
keyword is **not** stored — the renderer supplies it — which is why a keyword left in a clause body appears
to the reader as a duplicate.

### Emphasis wrapper

`**`, `__`, `*` or `_` around a keyword. A source-file convention, not content. Consumed with the keyword;
never stored in a Span. Emphasis **inside** a clause body is content and is preserved as `marks`.

### Logical line

The unit classification operates on: one source line, plus any indented continuation lines joined to it
(contract §3). Introduced by this feature; not persisted or emitted.

---

## §3 Validation rules

| # | Rule | Source |
| --- | --- | --- |
| V1 | No Clause's Span text begins with a keyword, with or without a wrapper | FR-003, FR-009 |
| V2 | Within one Scenario, no source substring appears in more than one of `given`, `when`, `then` | FR-004 |
| V3 | A logical line that cannot be split into three distinct clauses emits **no** Scenario | FR-005 |
| V4 | A Scenario with an empty `then` is never emitted | FR-013 |
| V5 | Every Clause is an array of one or more Spans | feature 016, unchanged |
| V6 | Emphasis inside a clause body survives as `marks`; emphasis around a keyword does not appear at all | FR-003 |
| V7 | Both ports emit byte-identical JSON for the same input, including the empty `[]` case | FR-015, FR-016 |

---

## §4 State transitions

The recogniser carries one open scenario as it walks the logical lines. This is existing behaviour; only
the classification feeding it changes.

```
             ┌──────────── T0 triple (T1/T2 match) ────────────┐
             │           flush → emit → flush                  │
             ▼                                                 │
   [ no open scenario ] ──L1 Given──▶ [ open ] ──L3 Then──▶ [ open, has Then ]
             ▲                          │  ▲                     │
             │                          └──┘                     │
             │                       L2/L4 append                │
             └────────── L1 Given, when a Then is open ──────────┘
                                    (flush first)
```

- **T3** (triple detected, neither pattern matched) transitions nowhere and emits nothing.
- **End of input** flushes: an open scenario that has a Then is emitted, one without is discarded.
- A **blank line** ends the current logical line (contract §3) but does not by itself flush the scenario —
  this is unchanged, and is what lets the one-clause-per-line form span blank-separated lines.

---

## §5 What is deliberately absent

- No persisted state. Nothing is written to run state, entity properties, or config.
- No new field carrying "how this scenario was recognised". The rule that matched is a parsing detail; the
  emitted document must stay identical whichever rule produced it, or FR-015 becomes untestable.
- No representation of an unrecognised line. V3 makes it absent, not recorded — there is no "rejected
  scenario" entity and no warning attached to one (FR-014, FR-018).
