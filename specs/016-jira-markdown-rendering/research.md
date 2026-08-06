# Phase 0 — Research: Markdown Rendering in Jira Descriptions

Five decisions. The first three resolve the AT RISK gates in the Constitution
Check; §4 resolves the NEEDS RESEARCH item; §5 removes a migration that turned
out not to exist.

Every claim below was checked against the code as committed, not recalled.

---

## §1 — Where does Markdown parsing live?

**Decision**: in the **engine**, as a new neutral module (`engine/markdown.sh`,
`engine/Markdown.psm1`). The neutral interchange document carries a *semantic*
block tree with marked spans; the sink maps neutral marks to ADF marks.

**Rationale**

The current interchange promises more than it delivers. Its own schema says:

> `content_blocks`: "A neutral, Jira-agnostic block tree. The sink renders it to
> ADF. NO ADF node names appear here."
> — `specs/001-jira-reconcile-engine/contracts/neutral-interchange.schema.json`

But `text` is a plain string, and `parse_description_blocks`
(`scripts/bash/engine/parse.sh:136`) fills it with raw Markdown lines — only
whitespace-trimmed and stripped of a leading list marker. So the "neutral block
tree" has always carried source syntax. `_adf_blocks_to_nodes`
(`scripts/bash/sink/jira/adf.sh:31`) faithfully wraps that syntax in one
unmarked text node, which is precisely the reported defect. **The renderer is not
wrong; the interface is under-specified.**

Markdown is *source-format* knowledge, not Jira knowledge. Constitution VIII
puts source knowledge in the engine and vendor knowledge in the sink, so the
parse belongs beside `parse.sh`, which already reads these files.

**Alternatives considered**

| Alternative | Why rejected |
|---|---|
| **Parse Markdown in the sink**, leaving the interchange carrying raw text | Inverts Principle VIII: the interchange would permanently carry a source-format detail, and every future sink would re-implement a Markdown parser. It also puts a *non-Jira* concern in the layer defined as "all Jira knowledge" |
| **A shared `lib/` Markdown module the sink calls**, interchange unchanged | Tempting — zero schema churn — but it leaves the neutral document describing syntax rather than meaning, so the schema keeps lying. Also makes the interchange un-validatable for rendering intent: `interchange_validate` could never tell a well-formed description from a malformed one |
| **Keep `text` and add a parallel `spans` field** | Two representations of the same content means two code paths in four modules, and an ambiguity about which wins. Fails KISS for the sake of avoiding a schema edit to an in-memory document |

**Boundary consequence.** The neutral mark names must not be ADF's:

| Neutral (engine) | ADF (sink) |
|---|---|
| `bold` | `strong` |
| `italic` | `em` |
| `monospace` | `code` |
| `strikethrough` | `strike` |
| `link` | `link` |

Four of five are lexically distinct. `link` collides, but it is an ordinary
English word rather than an Atlassian identifier — the same reasoning that lets
the engine already use `code` and `heading`.

To make this enforced rather than merely intended, Gate #2 of
`.github/workflows/boundary.yml` gains four ADF node names: `bulletList`,
`codeBlock`, `listItem`, `panelType`. All four were verified absent from both
engine layers before proposing them, so the gate goes green on the tree as
committed:

```
bulletList: 0    codeBlock: 0    listItem: 0    panelType: 0
```

ADF's `strong` and `em` are deliberately *not* added: `em` matches "them",
"system", "item" and would be pure noise. The neutral vocabulary is chosen to be
lexically distinct instead — a design that does not need a grep to hold.

---

## §2 — Which Markdown, exactly?

**Decision**: a **closed subset**, written down as an executable contract in
[contracts/markdown-subset.md](./contracts/markdown-subset.md), with one uniform
fallback for everything outside it.

**Rationale**

FR-015 requires two independently written parsers to agree byte-for-byte on all
three platforms. That constraint — not authorial taste — sets the size of the
grammar. CommonMark's emphasis resolution ("left-flanking / right-flanking
delimiter runs", with rules for how `*` and `_` differ around punctuation) is the
hardest part of the format to reimplement identically, and it is the part a
naive implementation gets subtly wrong in ways only a corpus reveals.

So the subset drops exactly the constructs whose *ambiguity* is the problem, not
merely the constructs that are rare:

- **No delimiter-run flanking analysis.** An opener must be followed by
  non-whitespace, a closer preceded by non-whitespace; the nearest valid closer
  wins. One rule, two implementations, no disagreement.
- **No reference links, no lazy continuation, no setext headings, no indented
  code blocks.** Each is a second syntax for something the subset already covers.
- **Underscore emphasis requires word boundaries.** This is not cosmetic: this
  repository's prose is full of `bullet_list`, `parse_description_blocks`,
  `schema_version`, `customfield_10011`. Treating intraword `_` as emphasis would
  mangle identifiers in nearly every spec. CommonMark agrees, and here the rule
  is stated directly rather than falling out of the flanking algorithm.

**One fallback, not many.** FR-010 requires unsupported constructs to degrade to
readable text. Rather than a handler per construct, the contract defines a single
rule — *strip the syntax, keep the human-meaningful text* — with three named
exceptions where "the text" is ambiguous (image → alt text; autolink → the URL as
both label and target; table row → cells joined, delimiter row dropped). Three
named rules, each traceable to a spec edge case, is the YAGNI-compatible floor.

**Alternatives considered**

| Alternative | Why rejected |
|---|---|
| **Full CommonMark** | ~600 lines of spec, hundreds of edge cases, two hand-written implementations. Wildly beyond FR-001/FR-008 and the opposite of KISS |
| **Regex substitution per construct** | Cannot express nesting (FR-004), cannot protect code-span interiors (FR-007), and cannot distinguish `snake_case` from emphasis without lookaround that Bash's ERE lacks |
| **Whatever the two ports happen to do, reconciled by fixtures** | This is how twin ports drift. The corpus proves equality; it cannot *specify* it |

---

## §3 — How do the two ports stay byte-identical?

**Decision**: one written algorithm (the precedence ladder in the contract),
implemented natively in each port, with the corpus proving equality per rule.

**Rationale**

Three specific hazards, each with a countermeasure drawn from
`docs/10-windows-portability.md` and this repository's scar tissue:

1. **CRLF.** The tokenizer must never see a `\r`. Line splitting already strips
   it (`line="${line%$'\r'}"`, `parse.sh:143` and throughout), and the contract
   requires the same normalisation at the module boundary. Critically, no glob
   pattern may contain `$'\r\n'` — the MSYS matcher bends such a pattern onto a
   bare LF, which is the documented root cause of a previous 15-divergence
   incident. The tokenizer works on already-split lines, so it needs no
   line-ending pattern at all.

2. **`jq` on Windows emits CRLF on multi-line output.** The Bash port must not
   call `jq` directly; all serialisation goes through `lib/output.sh`
   (`json_canonical`), exactly as `adf.sh` and `interchange.sh` already do.

3. **Serialisation order.** Marks are emitted in a fixed canonical order
   (alphabetical by kind) and `marks` is always present — even when empty — so
   neither port can differ by an omitted key. `json_canonical` then sorts object
   keys on both sides.

**Performance note, which is also a correctness note.** The obvious Bash
implementation — one `jq` call per span to append to an array — would spawn a
process per emphasis run. On a spec with a hundred marked spans that is a hundred
forks, and SC-007 forbids the regression. The contract therefore requires spans
to be accumulated in-process (a Bash array of pre-escaped JSON fragments; a
`List[object]` in PowerShell) and serialised **once per block**, which is the
single `jq` call the block already costs today. This is a hard budget, listed in
Technical Context, not an optimisation to consider later.

---

## §4 — Can markup smuggle content past the privacy guard?

**Decision**: no change to the guard is required. The hazard is real but is
already closed by FR-006.

**Rationale**

`privacy_guard_scan` (`scripts/bash/sink/jira/privacy_guard.sh:126`) scans the
outgoing **payload**, not the source file. Under the new model a link target
moves from inline text (`[label](https://internal.example/x)`) into a structured
JSON field (`{"kind":"link","href":"https://internal.example/x"}`) — but it is
still in the serialised payload the guard scans, so a BLOCK-tier host or a known
coordinate is caught exactly as before.

The one way content *could* vanish from the scan is a degradation path that drops
a target instead of keeping it. FR-006 already forbids that: a non-`http(s)`
target must be rendered as readable text carrying "both the label and the
target". So no construct in the subset can remove text from the payload — the
transformation only ever re-shapes it.

**Test obligation**: the corpus already has BLOCK/WARN fixtures
(`tests/bash/sink/test_privacy_block.bats`, `test_privacy_warn.bats`). This
feature adds one case — a blockable host inside a Markdown link — proving the
guard still blocks when the host is carried as a mark attribute rather than as
inline text. Without that case the change would be an untested privacy
regression risk.

---

## §5 — Does the block-model change need a migration?

**Decision**: no. `schema_version` stays `"1.0"`.

**Rationale**

The neutral interchange document looked like a persisted artifact worth
versioning. It is not. `interchange_build` is called at
`scripts/bash/commands/reconcile.sh:638`, its result is consumed in-process, and
a search for a write path found none — no state file, no cache, nothing under
`.specify/jira/` holding a serialised document. The `schema_version` fields that
do get written belong to the *run summary* (`lib/output.sh:123`) and the command
outputs, which this feature does not touch.

So the block model is an in-process contract between two layers of the same
invocation. Bumping the version would mean editing the validator's hard equality
check (`interchange.sh:25`) plus its tests in both ports, for zero functional
gain and a guaranteed conformance churn.

**What does change**: the canonical schema file
(`specs/001-jira-reconcile-engine/contracts/neutral-interchange.schema.json`)
gains the inline model and the `ordered_list` block kind, and the validator's
rules in `interchange.sh` / `Interchange.psm1` are updated to match. The schema
file is the living contract for a shipped feature, so it is edited in place
rather than forked; the delta is recorded in
[contracts/inline-model.schema.json](./contracts/inline-model.schema.json).

**One behavioural consequence to carry into tasks.** Headings inside the selected
prose region are currently *dropped* — they act only as paragraph separators
(`parse.sh:149-155`). US2 acceptance scenario 4 requires them to render as
headings, so they become blocks. That interacts with the existing "keep at most
the first two paragraphs" cap (`parse.sh:167-173`): if a heading consumed cap
budget, a spec that opens with a heading would lose its actual prose. The cap
therefore counts **content blocks only** (paragraph, list, code); headings ride
along free, and a trailing heading with no following content is dropped. This
keeps the *selection* rule intact — which the spec's Out of Scope section
requires — while satisfying FR-008. Recorded in
[data-model.md](./data-model.md) §4.
