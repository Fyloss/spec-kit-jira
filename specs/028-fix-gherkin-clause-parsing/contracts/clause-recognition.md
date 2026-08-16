# Contract: Acceptance-Scenario Clause Recognition

**Feature**: 028-fix-gherkin-clause-parsing | **Date**: 2026-08-16

Two ports, one behaviour, proven byte-for-byte by `tests/conformance/ci-conformance.sh`. No signature
changes: `parse_acceptance_criteria` (stdin → canonical JSON array) and
`Get-JiraParsedAcceptance -Text <string>` keep the shape every caller already uses. The output schema is
unchanged — see [`data-model.md`](../data-model.md).

---

## §1 The wrapper token

```
kw := ( "**" | "__" | "*" | "_" )?
```

`kw` is optional and MUST be accepted **before and after** every keyword, in every recogniser. This
symmetry is the whole of the defect: today it is honoured on the per-line path and only half-honoured on
the single-line path.

`kw` is consumed as part of the keyword and MUST NOT reach the clause body (FR-003). Every other markdown
token in the body — including a `**bold**` word further along — MUST reach the tokenizer untouched.

---

## §2 Line classification

Each logical line (after §3's joining, CR strip, list-marker strip and trim) is classified by the first
rule that matches. `continue` means "this line produces nothing".

| # | Rule | Condition | Effect |
| --- | --- | --- | --- |
| T0 | Triple detected | the line contains `Given`, `When` and `Then`, each followed by `kw` and whitespace | flush the open scenario, then evaluate T1→T3; `continue` regardless of outcome |
| T1 | Delimited triple | `kw Given kw \s+ (g) [,;] \s* kw When kw \s+ (w) [,;] \s* kw Then kw \s+ (t) $` | emit one scenario from `g`, `w`, `t` |
| T2 | Delimiter-free triple | `kw Given kw \s+ (g) \s+ kw When kw \s+ (w) \s+ kw Then kw \s+ (t) $` | emit one scenario from `g`, `w`, `t` |
| T3 | **Neither matched** | T0 held but T1 and T2 both failed | **emit nothing** — FR-005 |
| L1 | Given opener | `^ kw Given kw \s+ (rest) $` | flush if a Then is open; append `rest` to `given` |
| L2 | When opener | `^ kw When kw \s+ (rest) $` | append `rest` to `when` |
| L3 | Then opener | `^ kw Then kw \s+ (rest) $` | append `rest` to `then` |
| L4 | Continuation keyword | `^ kw (And\|But) kw \s+ (rest) $` | append `rest` to the last-touched bucket |
| X | anything else | — | ignored (FR-012) |

**T1 before T2 is normative.** It is what keeps a Given clause containing the word "when" intact (FR-007),
and it is an existing tested behaviour.

**T3 is the fail-closed rule and is normative.** The bash port MUST NOT reach T3 through glob prefix/suffix
removal (`${t#*Given }` and friends): a glob strip that does not match returns its input unchanged, which is
how the whole line ends up in all three buckets. T3 MUST be reached by a regex that either matches or does
not.

**A scenario is emitted only when it reaches a Then** — unchanged from today (FR-013).

---

## §3 Continuation joining (User Story 4, FR-008)

Applied to the raw lines **before** classification. A raw line is a continuation of the logical line above
it exactly when **all** of:

1. the previous logical line opened with a keyword (matched T0, L1, L2, L3 or L4);
2. the raw line has leading whitespace;
3. it is non-empty after trimming;
4. it does **not** itself open with a keyword — `^ kw (Given|When|Then|And|But) kw \s`, evaluated after any
   list marker is stripped;
5. it does **not** open a list item (`-`, `*`, `N.`) or a heading (`#`).

A continuation is appended to the logical line above with **one space**. A blank line always terminates the
current logical line.

**Invariant**: on input containing no continuation lines, §3 is the identity function. The
one-clause-per-line form and the single-line form both pass through byte-identically.

---

## §4 The conformance table

These nine inputs were run through both ports' patterns before the design was accepted, and **all nine
agree**. They are normative: any implementation that disagrees with a row is wrong.

| # | Input | Rule | `given` | `when` | `then` |
| --- | --- | --- | --- | --- | --- |
| 1 | `**Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.` | T1 | `a user arrives on the Homepage` | `they click Login` | `the login form appears.` |
| 2 | `Given a user arrives on the Homepage, When they click Login, Then the login form appears.` | T1 | `a user arrives on the Homepage` | `they click Login` | `the login form appears.` |
| 3 | `Given a user When they click Then it opens` | T2 | `a user` | `they click` | `it opens` |
| 4 | `Given the user logs in when prompted, When they click, Then it opens` | T1 | `the user logs in when prompted` | `they click` | `it opens` |
| 5 | `**Given** a user **When** they click **Then** it opens` | T2 | `a user` | `they click` | `it opens` |
| 6 | `__Given__ a **bold** thing, __When__ x, __Then__ y` | T1 | `a **bold** thing` | `x` | `y` |
| 7 | `just prose here` | X | — | — | — |
| 8 | `Given only a given and a when here` | X | — | — | — |
| 9 | `Given a When b When c Then d` | T2 | `a When b` | `c` | `d` |

Rows 3 and 4 are **existing** unit tests and MUST keep their current values. Row 6 proves FR-003: the
wrapper around the keyword is gone, the wrapper inside the body survives. Row 9 pins the greedy split that
makes the two ports agree — see research §R3.

---

## §5 Edge cases the grammar decides

| Input shape | Outcome |
| --- | --- |
| keyword emphasised on one side only (`**Given` or `Given**`) | recognised; the stray marker never reaches the body |
| mixed forms on one line (`**Given** x, When y, **Then** z`) | T1, one scenario, all three clauses correct |
| emphasised `And`/`But` continuation | L4; joins the previous bucket; no keyword repeated |
| indented continuation line that itself opens with a keyword | **not** a continuation (§3 rule 4); classified on its own by §2. Consequence, deliberate and pinned by test: a `**When** … **Then** …` continuation matches L2 and its `Then` text lands in the `when` bucket, so the scenario never reaches a Then and **nothing is emitted**. Ambiguous input with the indented per-line form; not guessed at (FR-022, research §R5) |
| line with the three keywords but no separators the grammar accepts | T3 — nothing emitted, on both ports |
| scenario that never reaches a Then | not emitted; unchanged from today |
| absent or empty acceptance-scenario section | `[]`; no warning; unchanged from today |

---

## §6 Invariants a reviewer can check mechanically

1. **Disjointness (FR-004)**: for every emitted scenario, no clause's source text overlaps another's. No
   code path may assign one source substring to more than one bucket.
2. **No stutter (FR-009)**: no clause body matches `^ kw (Given|When|Then|And|But) kw \s`.
3. **Fail closed (FR-005)**: T3 emits nothing. There is no branch in which an unsplit line becomes a
   scenario.
4. **Identity on today's good inputs**: for every input in the existing corpus and unit tests, the output is
   byte-identical to the pre-feature implementation. Existing **assertions keep their values**; if a
   pre-feature expected value has to change to make the suite green, the design is wrong, not the test.
   Adding a new input to an existing fixture is not covered by this invariant — T017 deliberately extends the
   cross-port parity test's specification with the emphasised single-line form, and its existing assertions
   still hold unchanged.
5. **Cross-port equality (FR-015/FR-016)**: both ports agree on every row of §4 **and** on every input that
   emits nothing — one port dropping a scenario where the other invents one is the defect, not a detail.
6. **Spawn budget (FR-021)**: no external process is added. §3 and §2 are regex matches and string appends;
   `test_parse_spawn_budget.bats` passes unmodified.

---

## §7 Neutrality obligations (Constitution VI and VIII)

- The fix lives entirely in `engine/`. `sink/jira/adf.sh` and `Adf.psm1` are **not** touched — the panel
  builder's plain `"Given "` prefix is correct and is what FR-009 relies on.
- Zero Jira identifiers, zero tracker vocabulary in the engine.
- No `jq` invocation outside `lib/output.sh` in the bash port; this feature adds none.
- No `$'\r\n'` inside any glob pattern. Line splitting keeps the existing CR strip (`${line%$'\r'}`), which
  is a suffix removal of a **bare CR**, not a CRLF glob.
