# Implementation Plan: Markdown Rendering in Jira Descriptions

**Branch**: `016-jira-markdown-rendering` | **Date**: 2026-08-04 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/016-jira-markdown-rendering/spec.md`

## Summary

Today the parse layer extracts Markdown *lines* and hands them to the sink as
plain strings; the sink wraps each string in a single unmarked text node. Every
`**`, backtick and `[…](…)` therefore survives all the way to the Jira reader.
The defect is not in the renderer — it is that the "neutral content block" the
two layers exchange has always carried **source syntax** where it promised
**semantic content**.

The fix closes that gap at the interface. A new neutral engine module parses the
restricted Markdown subset into a block tree whose text positions are *arrays of
marked spans* rather than strings; the sink maps those neutral marks onto rich
text. Spec files are read exclusively — the module is a pure function from bytes
to a neutral tree, with no write path of any kind (FR-000).

Both ports implement the same tokenizer natively. Because the two must agree
byte-for-byte, the grammar is not "whatever CommonMark does" but a written
contract ([contracts/markdown-subset.md](./contracts/markdown-subset.md)) small
enough that two independent implementations can be proven equal by the
conformance corpus.

## Technical Context

**Language/Version**: Bash ≥ 4 (enforced by `lib/prereq.sh:79`; macOS 3.2 is
rejected at the prereq gate) and PowerShell 7+

**Primary Dependencies**: `jq` (Bash port only, and never called directly —
always through `lib/output.sh`, per `docs/10-windows-portability.md`); no new
dependency is introduced by this feature

**Storage**: N/A. Spec files are read-only input (FR-000); the neutral
interchange document is built in memory at `commands/reconcile.sh:638` and never
persisted, so the block-model change needs no migration and no
`schema_version` bump — see [research.md](./research.md) §5

**Testing**: `bats-core` (`tests/bash/`), Pester (`tests/powershell/`), and the
cross-port byte-equivalence harness (`tests/conformance/`)

**Target Platform**: macOS, Linux, and Windows (MSYS bash + PowerShell 7)

**Project Type**: CLI bridge — twin native ports proven equivalent by a shared
conformance corpus

**Performance Goals**: rendering is O(n) in the bytes of the *selected* prose
(two content blocks per ticket, not the whole spec file). Hard budget: **zero
additional subprocess spawns per block** — spans are accumulated in-process and
serialised in the single `jq` call the block already costs. SC-007 (no measurable
regression) is met by construction, not by measurement after the fact

**Constraints**: byte-identical output across both ports and all three platforms
(FR-015); no `$'\r\n'` inside any glob pattern; no direct `jq` call in the Bash
port; the engine layer must stay free of Atlassian identifiers (Gate #2 of
`.github/workflows/boundary.yml`)

**Scale/Scope**: ~9 rendered constructs, 2 new modules (one per port), 6 modified
modules (three per port), 1 schema contract, 1 CI gate strengthened

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Initial evaluation (pre-research)

| # | Principle | Gate | Verdict |
|---|-----------|------|---------|
| I | Filesystem is the source of truth | Does any new code path write to a spec file? | **PASS** — the new module has no write path. Note the bridge *does* write marker lines to spec files today (`reconcile.sh:625`, `:878`), one of this principle's controlled exceptions; FR-000a puts it outside this feature, and the FR-000 test compares prose while ignoring marker lines (quickstart §8) |
| II | Zero-churn idempotency | Does a re-run over an unchanged spec write? | **PASS** — the description is a derived field compared by `idempotency_field_status`; a stable renderer yields "unchanged" on run 2 |
| III | Fail-closed on writes | What happens on malformed markup? | **PASS** — FR-005 makes malformed markup render as literal text; the renderer is total (no error return), so it cannot half-write |
| IV | Credential security | New secrets or storage? | **PASS** — none |
| V | Config layer separation | New config key? | **PASS** — none; the construct set is fixed, not configurable (spec Out of Scope) |
| VI | Portability | Two ports, three platforms, byte-identical? | **AT RISK** — a hand-written tokenizer implemented twice is exactly the shape that diverges. Mitigated by a written grammar contract + conformance fixtures; see Complexity Tracking |
| VII | No hard-coded Jira workflow | New status/field/type assumption? | **PASS** — none; the description body only |
| VIII | Neutral engine / Jira sink | Where does each half live? | **AT RISK** — the neutral mark vocabulary must not be ADF's. Resolved in research §1 by choosing lexically distinct names and extending the CI gate |
| IX | Privacy guard | Can markup smuggle content past the scan? | **NEEDS RESEARCH** — the guard scans the payload; a link's target becomes a structured field rather than inline text. See research §4 |
| X | Self-healing mirror | Do stale tickets heal? | **PASS** — FR-011 is the normal drift path, no new mechanism |
| XI | Dry-run and auditability | Is the rewrite previewable? | **PASS** — description changes already flow through the existing dry-run diff |
| XII | Quality and catalog | New published surface? | **PASS** — none |
| XIII | TDD ≥ 80% coverage | Failing test first? | **PASS** — every FR is an observable property of the rendered output; fixtures precede implementation |
| XIV | KISS | Simplest solution? | **AT RISK** — a Markdown parser is not trivially simple. Mitigated by a closed subset with one uniform fallback; see Complexity Tracking |
| XV | YAGNI | Anything built "for later"? | **PASS** — each supported construct traces to a spec acceptance scenario; unsupported ones share one fallback rule rather than getting speculative handlers |
| XVI | Human readable | Is the output for humans? | **PASS** — this feature *is* this principle applied to the ticket body |

**Gate result**: three AT RISK items and one NEEDS RESEARCH → proceed to Phase 0,
which must resolve all four. No unjustified violation blocks the plan.

### Re-evaluation (post-design)

| # | Item | Resolution |
|---|------|-----------|
| VI | Two implementations diverging | **RESOLVED** — [contracts/markdown-subset.md](./contracts/markdown-subset.md) specifies the tokenizer as an explicit precedence ladder with named, numbered rules, so both ports implement one written algorithm rather than two readings of CommonMark. Ambiguity is removed at the source: no delimiter-run flanking analysis, no reference links, no lazy continuation. The conformance corpus gains a fixture per rule |
| VIII | Neutral vocabulary vs ADF names | **RESOLVED** — neutral marks are `bold`/`italic`/`monospace`/`strikethrough`/`link`; ADF's are `strong`/`em`/`code`/`strike`/`link`. Four of five are lexically distinct, and the sink owns the map. Gate #2 gains `bulletList`, `codeBlock`, `listItem`, `panelType` (all verified absent from `engine/` today), making the boundary enforced rather than merely asserted |
| IX | Privacy guard | **RESOLVED** — research §4: the guard scans the serialised payload, and a link target serialised as a JSON field is still in that payload. The one real hazard is the *degradation* path silently dropping a target; FR-006 already requires the target to remain visible as text, so nothing disappears from the scan |
| XIV | KISS | **ACCEPTED WITH JUSTIFICATION** — see Complexity Tracking |

## Project Structure

### Documentation (this feature)

```text
specs/016-jira-markdown-rendering/
├── spec.md                       # Feature specification
├── plan.md                       # This file
├── research.md                   # Phase 0 — the five decisions
├── data-model.md                 # Phase 1 — neutral block/inline model
├── quickstart.md                 # Phase 1 — how to validate the feature
├── contracts/
│   ├── markdown-subset.md        # The tokenizer contract both ports implement
│   └── inline-model.schema.json  # Schema fragment to merge into the canonical contract
├── checklists/
│   └── requirements.md           # Spec quality checklist
└── tasks.md                      # Phase 2 — NOT created by /speckit-plan
```

### Source Code (repository root)

```text
scripts/bash/
├── engine/
│   ├── markdown.sh               # NEW — Markdown subset -> neutral blocks + spans
│   ├── parse.sh                  # MODIFIED — description/AC/design text goes through markdown.sh
│   └── interchange.sh            # MODIFIED — validation rules for the new block shape
└── sink/jira/
    └── adf.sh                    # MODIFIED — neutral spans/marks -> ADF text nodes + marks

scripts/powershell/
├── engine/
│   ├── Markdown.psm1             # NEW — mirror of markdown.sh
│   ├── Parse.psm1                # MODIFIED — mirror
│   └── Interchange.psm1          # MODIFIED — mirror
└── sink/jira/
    └── Adf.psm1                  # MODIFIED — mirror

tests/bash/engine/
├── test_markdown_inline.bats     # NEW — one test per inline rule + every edge case
└── test_markdown_blocks.bats     # NEW — block segmentation, cap, fences

tests/bash/sink/
└── test_adf_marks.bats           # NEW — neutral marks -> ADF marks

tests/powershell/engine/
├── Markdown.Inline.Tests.ps1     # NEW — mirror
└── Markdown.Blocks.Tests.ps1     # NEW — mirror

tests/powershell/sink/
└── Adf.Marks.Tests.ps1           # NEW — mirror

tests/conformance/
├── fixtures/repo-with-markdown-prose/    # NEW — a spec exercising every construct
└── scenarios/us1-markdown-rendering.json # NEW — cross-port byte equality

specs/001-jira-reconcile-engine/contracts/
└── neutral-interchange.schema.json       # MODIFIED — canonical contract, per the fragment here

.github/workflows/
└── boundary.yml                  # MODIFIED — Gate #2 gains four ADF node names
```

**Structure Decision**: the existing four-layer split is kept exactly as it is.
Markdown parsing is *source-format* knowledge, not Jira knowledge, so it belongs
in `engine/` beside the parser that already reads these files — placing it in
`sink/` would make every future sink re-parse Markdown and would leave the
interchange carrying raw syntax forever. The sink's job shrinks to what it should
always have been: mapping a neutral vocabulary onto Atlassian's. Rejected
alternatives are recorded in [research.md](./research.md) §1.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| A hand-written Markdown tokenizer, implemented twice (Principle XIV) | FR-001 and FR-008 require nine constructs to render natively; no Markdown parser exists in Bash, and PowerShell's `ConvertFrom-Markdown` emits HTML rather than an AST — the wrong output shape, and one more thing to keep identical across three platforms | **Adding a dependency** fails Principle XIV's "minimal external dependencies" and would have to exist for both ports on three platforms. **Regex-replace over the whole string** cannot express nesting (FR-004), cannot protect code spans (FR-007), and mis-fires on `snake_case` identifiers, which this corpus is full of. **A full CommonMark implementation** is far larger than the spec requires and is the opposite of KISS |
| A restricted subset rather than CommonMark (Principle XIV, deliberate) | Two independently-written parsers must agree byte-for-byte (FR-015). CommonMark's emphasis algorithm (left/right-flanking delimiter runs) is the single hardest part of the format to reimplement identically | Not a violation so much as the *mitigation*: the subset is what makes twin-port equality provable. Written down as a contract so the restriction is a decision, not an accident |

**Not tracked as complexity**: the inline span model is a schema *change*, not a
new abstraction layer — it replaces `string` with a structured value in the one
interface the constitution already blesses (Principle VIII's engine/sink
interface, the explicitly justified exception in Principle XIV).
