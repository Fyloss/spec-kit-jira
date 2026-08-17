# Phase 0 Research: A Scenario Written the Template's Way Reaches the Ticket Intact

**Feature**: 028-fix-gherkin-clause-parsing | **Date**: 2026-08-16

The Technical Context carries no `NEEDS CLARIFICATION`: the language, dependencies, test harnesses and
platform targets are the project's own and unchanged. What needed research was the *design* — and because
this is a cross-port defect on a project whose Constitution VI has been broken by exactly this kind of
"looks equivalent" reasoning before, every decision below was **prototyped and measured on both ports
before it was written down**, never inferred from reading the code.

---

## R1 — Where the defect actually is, measured on both ports

**Decision**: The defect is one asymmetry in the single-line three-clause recogniser: the emphasis wrapper
is optional *after* each keyword and absent *before* it. The one-clause-per-line recogniser already accepts
both sides. Nothing else is wrong, and the renderer is correct.

**Measurement** — the reporter's own line, run through each port's acceptance parser directly:

| Input | bash `parse_acceptance_criteria` | pwsh `Get-JiraParsedAcceptance` |
| --- | --- | --- |
| `1. **Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.` | one scenario; `given`, `when` **and** `then` each hold the entire line, bold keywords included | `[]` |
| `1. Given a user arrives on the Homepage, When they click Login, Then the login form appears.` | correct, three disjoint clauses | correct, three disjoint clauses |
| the same scenario wrapped over three source lines | `[]` | `[]` |

**Why the two symptoms are one defect.** With the split failed, the bash port's delimiter-free fallback
uses glob prefix/suffix removal (`${t#*Given }`, `${t%%When *}`), which cannot fail — the patterns require a
*space* after the keyword and the text has `Given**`, so every strip is a no-op and all three buckets
receive the untouched line. That is the reported "each criterion duplicated 3 times". The renderer then
prefixes the plain keyword to a body that still opens with the bold one, which is the reported
`Given **Given** …`. One cause, two faces.

**Why the ports differ.** The PowerShell fallback is a regex (`[Gg]iven\s+(.*?)…`), not a glob, and it
requires the same missing space — so it matches nothing, no clause is added, and the scenario is dropped.
A regex that fails is silent; a glob strip that fails returns its input. That asymmetry, not a difference of
intent, is the whole of the divergence.

**Alternatives considered**: none — this is a measurement, not a choice. It is recorded because the
plausible reading ("the renderer bolds the keyword twice") is wrong and would have produced a sink-side fix
that could not work.

---

## R2 — The shape of the fix

**Decision**: Two changes to the single-line recogniser, identical in both ports:

1. Make the emphasis wrapper optional on **both** sides of each of Given/When/Then, matching what the
   per-line recogniser already does.
2. Replace the delimiter-free fallback with a regex of the same shape and **fail closed**: a line that
   matches neither the delimited nor the delimiter-free form yields **no scenario**. The glob strips go.

**Rationale**: It is the smallest change that satisfies FR-001..FR-005, it removes an inconsistency rather
than adding a mechanism (Constitution XIV), and change 2 is what makes FR-005 structurally true rather than
merely likely — a fallback that cannot fail will always eventually guess.

**Alternatives considered and rejected**:

- *Normalise the line first — strip all emphasis markers around keywords in a pre-pass, then run today's
  recogniser.* Rejected: this is what feature 016 explicitly removed ("the crude global asterisk strip that
  used to sit here as a partial workaround"). Re-introducing a strip pass, even a narrowed one, would
  either damage emphasis inside clause bodies or need to know where the keywords are — which is the problem
  it was supposed to avoid.
- *Split the line on the keywords with a tokenizer instead of a regex.* Rejected: a second parsing model
  next to the existing one, for a defect that is a missing `?` group. Constitution XIV and XV.
- *Fix bash only and let PowerShell keep dropping the scenario.* Rejected outright: FR-015/FR-016, and the
  two ports currently disagree on the template's own output, which is a live Constitution VI violation.

---

## R3 — The regex design, validated on nine inputs across both ports

**Decision**: two patterns per port, tried in order, sharing one wrapper token `(\*\*|__|\*|_)?`:

- **T1, delimited** — the clause boundary is an explicit `,` or `;` before the next keyword. Tried first, so
  a Given clause containing the word "when" survives (FR-007).
- **T2, delimiter-free** — whitespace-separated keywords, greedy.
- **Neither → no scenario** (FR-005).

**Measurement**: both ports were run against the same nine inputs before the design was accepted. Full
grammar and the table live in [`contracts/clause-recognition.md`](./contracts/clause-recognition.md) §4;
the outcome is that **all nine agree, byte for byte**, including the two inputs that are existing
regression tests (`Given a user When they click Then it opens` and `Given the user logs in when prompted,
When they click, Then it opens`) and the deliberately ambiguous `Given a When b When c Then d`.

**One deliberate behaviour change on the PowerShell side**: its delimiter-free fallback is lazy today
(`(.*?)`); POSIX ERE, which bash uses, has no lazy quantifier. Rather than emulate laziness in bash, both
ports use the greedy form. Measured consequence: on `Given a When b When c Then d` both ports now split at
the **last** `When` (`g=[a When b]`), where the PowerShell port alone used to split at the first. The ports
agree, which they did not before; no test asserts the old lazy behaviour; and the input is pathological.

**Alternatives considered**: emulating lazy matching in bash by iterating candidate split points — rejected,
it introduces a loop over positions inside a per-line loop for a pathological input, and would have to be
mirrored exactly in .NET to stay byte-identical. Constitution XIV.

---

## R4 — The renderer is not touched

**Decision**: `sink/jira/adf.sh` `_adf_gherkin_panel` and its PowerShell twin stay exactly as they are.

**Rationale**: The panel builder prepends a plain `"Given "` / `"When "` / `"Then "` text node ahead of the
clause's own spans. That is correct and is the mechanism FR-009 depends on. The stutter is not the
renderer prefixing twice; it is the parser handing it a body that still begins with the keyword. Fix the
parser and the stutter disappears with no sink change — which also keeps the fix on the engine side of
Constitution VIII, where recognising a scenario belongs.

**Verified**: the panel builder was read and its behaviour traced against the measured parser output in R1.
Removing the plain prefix instead would have deleted the keyword from every correctly-parsed clause.

---

## R5 — Continuation joining for wrapped scenarios (User Story 4)

**Decision**: a pre-pass over the lines, before clause recognition, that appends an **indented
continuation** line to the logical line above it. A raw line is a continuation exactly when all of:

1. the previous logical line was itself recognised as opening with a keyword;
2. the raw line is indented (has leading whitespace);
3. it is non-empty after trimming;
4. it does not itself open with a keyword (with or without a wrapper);
5. it does not open a new list item (`-`, `*`, `N.`) or a heading (`#`).

A blank line always ends the scenario. Joining uses a single space.

**Rationale**: Conditions 1 and 2 together are what keep FR-012 safe. Requiring the *previous* line to be a
scenario opener means prose is never joined to prose; requiring indentation is the markdown convention for a
wrapped list item and is exactly the shape every specification in this repository — and the spec-kit
template — actually produces. Condition 4 preserves the one-clause-per-line form untouched.

**Measurement**: prototyped in pure bash against three inputs — a 019-style three-line wrapped scenario
followed by a second scenario, the existing per-line fixture, and a scenario followed immediately by
unindented prose with no blank line. The wrapped scenario joins into one logical line, the per-line fixture
passes through unchanged, and the prose is **not** joined.

**Alternatives considered and rejected**:

- *Join any non-keyword, non-blank line regardless of indentation.* Rejected: the acceptance parser is
  handed the **whole story section**, not just its Acceptance Scenarios subsection, so unindented prose sits
  next to scenarios routinely. FR-012 is a hard requirement and User Story 4 is P2; the P2 story does not get
  to endanger the P1 boundary condition.
- *Extract the "Acceptance Scenarios" subsection first and parse only that.* Rejected as a larger change
  with its own heading-matching failure modes, and it would alter behaviour for specifications that place
  scenarios elsewhere — a regression risk far wider than the defect.
- *Treat an indented line opening with a keyword as a continuation too.* Rejected: it makes an indented
  per-line form unparseable, and the input it would help (`**Given** x,` / `**When** y, **Then** z`) is
  genuinely ambiguous. It is recorded as an edge case in the contract instead.

---

## R6 — Test strategy, and why the corpus is where this shipped from

**Decision**: failing tests first, in both ports, at two levels.

1. **Unit** — `tests/bash/engine/test_parse_title_desc.bats` and
   `tests/powershell/engine/Parse.TitleDesc.Tests.ps1`: the reporter's exact line asserted to yield three
   **disjoint** clauses none of which begins with its keyword; the wrapped form; the fail-closed form; and
   the existing cross-port parity test extended to the emphasised inputs.
2. **Conformance** — a new fixture repo and scenario carrying both the emphasised single-line form and the
   emphasised wrapped form, so the two ports are pinned byte-for-byte.

**Rationale, and the finding that drives it**: every acceptance-criteria line in **every** existing
conformance fixture uses the one-clause-per-line form `- **Given** …`. Not one uses the single-line
emphasised triple — which is the spec-kit template's own default. The corpus has no opinion about the most
common input in the wild, which is precisely why two ports could diverge this far unnoticed. Adding the
fixture is not test hygiene here; it is FR-015's stated requirement and the reason the defect was invisible.

**Regression guards whose assertions must keep their values**: the two spawn-budget assertions in
`test_parse_spawn_budget.bats`, the four existing Gherkin unit tests in each port, and the existing
cross-port parity test. If any expected value has to change to make them green, the design is wrong, not the
test. Adding an input is a different act: the parity test's specification is deliberately extended with the
emphasised single-line form (contract §6 invariant 4), and its assertions still hold unchanged.

---

## R7 — Spawn budget (FR-021)

**Decision**: no new external process, and no new `$( )` in a per-line position that could become one.

**Rationale, verified by reading the measurement harness**: `tests/bash/helpers/spawn_count.bash` counts
**external** processes via PATH shims. Everything this feature adds is a bash ERE match or a string append,
and `markdown_tokenize_inline` — the only function clause bodies reach — is pure bash with no external call.
The continuation pre-pass adds one loop over lines with no command substitution at all.

**Consequence**: the two existing assertions ("same count regardless of clause count within one scenario",
"bounded, non-growing count as scenario count doubles") hold by construction and must pass **unmodified**.
The 024 rule's second half — never route a batched payload through a single command-line argument — is not
reached: this feature produces no batched payload and adds no call.
