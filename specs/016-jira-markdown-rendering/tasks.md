---

description: "Task list for feature 016 — Markdown rendering in Jira descriptions"
---

# Tasks: Markdown Rendering in Jira Descriptions

**Input**: Design documents from `/specs/016-jira-markdown-rendering/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: **MANDATORY**, not optional. Constitution XIII requires TDD with ≥80%
coverage, and every rule in
[contracts/markdown-subset.md](./contracts/markdown-subset.md) is normative — a
rule without a failing-first test is an unproven claim about twin-port equality.

**Organization**: grouped by user story. Phase 2 is a behaviour-preserving
migration that must leave the rendered output byte-identical; the visible fix
starts at Phase 3.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on incomplete work)
- **[Story]**: US1 / US2 / US3, mapping to the spec's user stories
- Every task names its exact file path

## Path Conventions

Twin native ports, mirrored module for module:

- Bash: `scripts/bash/{engine,sink/jira}/`, tests in `tests/bash/{engine,sink,commands}/`
- PowerShell: `scripts/powershell/{engine,sink/jira}/`, tests in `tests/powershell/{engine,sink,commands}/`
- Cross-port: `tests/conformance/{fixtures,scenarios}/`

**The mirror rule**: no Bash change merges without its PowerShell twin. A task
that names one port always has a sibling naming the other; they are separate
tasks only because they touch different files.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: the corpus and the guard rail, both of which protect every later phase.

- [X] T001 [P] Create the conformance fixture at `tests/conformance/fixtures/repo-with-markdown-prose/` — a spec whose overview prose exercises every worked example E1–E15 from `specs/016-jira-markdown-rendering/contracts/markdown-subset.md`, plus the minimal `.specify/jira/` config the other fixtures carry (copy the shape from `tests/conformance/fixtures/repo-with-mirrored-spec/`)
- [X] T002 [P] Create the scenario at `tests/conformance/scenarios/us1-markdown-rendering.json` pointing at that fixture, following the field contract documented in `tests/conformance/scenarios/README.md` (`name`, `mock`, `fixture`, `argv`, `env`)
- [X] T003 [P] Add failing gate cases for the four ADF node names (`bulletList`, `codeBlock`, `listItem`, `panelType`) to `tests/bash/ci/test_boundary_gate_neutral_tokens.bats`, using the existing `plant_engine` helper — each must FAIL now, because Gate #2 does not yet scan for them
- [X] T004 Extend the `patterns=(...)` array of Gate #2 in `.github/workflows/boundary.yml` with those four tokens, turning T003 green (all four were verified absent from both engine layers at plan time, so the gate stays green on the tree as committed)

**Checkpoint**: the corpus can describe the feature, and the boundary is enforced
before any code that could cross it exists.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: move the interchange from plain strings to marked spans **without
changing a single rendered byte**. Every text position becomes a one-span array
carrying no marks, which serialises to exactly the ADF produced today.

**⚠️ CRITICAL**: no user story work can begin until this phase is complete — US1
and US2 both write into the structure created here.

**Why this shape**: it makes the riskiest change (a schema migration touching six
modules and sixteen test files) provable by a corpus that must stay *green and
unchanged*. If conformance output shifts by one byte in this phase, the migration
is wrong and the failure is isolated from the rendering work.

- [X] T005 Merge the inline model into the canonical contract `specs/001-jira-reconcile-engine/contracts/neutral-interchange.schema.json`, applying `$defs.mark`, `$defs.span`, `$defs.inline`, the revised `$defs.content_blocks`, and the `ordered_list` enum member exactly as specified in `specs/016-jira-markdown-rendering/contracts/inline-model.schema.json`; keep `schema_version` at `"1.0"` (research §5 — the document is in-memory only)
- [X] T006 [P] Write failing tests for emission invariants D1 (adjacent equal-mark spans merge), D2 (`marks` always present, sorted by kind) and D3 (empty spans dropped unless the array would empty) in `tests/bash/engine/test_markdown_inline.bats`
- [X] T007 [P] Mirror those invariant tests in `tests/powershell/engine/Markdown.Inline.Tests.ps1`
- [X] T008 Create `scripts/bash/engine/markdown.sh` implementing Part A normalisation and Part D emission, exposing a `markdown_inline_plain <text>` entry point that returns a single unmarked span — no tokenization yet; serialise through `lib/output.sh`, never by calling `jq` directly
- [X] T009 Create `scripts/powershell/engine/Markdown.psm1` as the mirror of T008, importing `lib/Output.psm1` **without** `-Force` (a sink/lib dependency imported with `-Force` clobbers the caller's scope)
- [X] T010 [P] Write failing validator tests for data-model §5 rules 1–5 (block-type enum, per-type required field, span shape, mark shape, `href` matches `^https?://`) in `tests/bash/engine/test_interchange.bats`
- [X] T011 [P] Mirror those validator tests in `tests/powershell/engine/Interchange.Tests.ps1`
- [X] T012 Extend `_INTERCHANGE_ERRORS_JQ` in `scripts/bash/engine/interchange.sh` with data-model §5 rules 1–5, keeping the existing non-empty-blocks check intact
- [X] T013 Mirror the validation rules in `scripts/powershell/engine/Interchange.psm1`
- [X] T014 Convert `parse_description_blocks`, `_parse_epic_extra_blocks` and `parse_plan_summary` in `scripts/bash/engine/parse.sh` to emit `spans` (and `items` as arrays of inline) via `markdown_inline_plain`, leaving the selection logic untouched
- [X] T015 Mirror the conversion in `Get-JiraParsedDescription`, `Get-JiraParsedEpicExtraBlocks` and `Get-JiraParsedPlanSummary` in `scripts/powershell/engine/Parse.psm1`
- [X] T016 Convert `_adf_blocks_to_nodes` in `scripts/bash/sink/jira/adf.sh` to consume `spans`/inline `items`, emitting one ADF text node per span with no marks
- [X] T017 Mirror the conversion in `ConvertTo-JiraAdfBlockNode` in `scripts/powershell/sink/jira/Adf.psm1`
- [X] T018 Update the existing tests that encode the plain-string block shape across both ports: `tests/bash/engine/{test_parse_title_desc,test_parse_epic,test_parse_plan,test_parse_marker,test_managed_panel}.bats`, `tests/bash/sink/{test_adf,test_us7_plan_apply}.bats`, `tests/bash/commands/test_reconcile_zero_churn.bats`, and the eight PowerShell mirrors under `tests/powershell/{engine,sink,commands}/`
- [X] T019 Verify the migration changed nothing observable: `tests/run-bash.sh` green, `bash tests/conformance/ci-conformance.sh` exits 0 with zero `conformance divergence` lines, and the ADF bytes for an unchanged fixture are identical to the pre-migration output

**Checkpoint**: the interchange carries the new model, Jira sees exactly what it
saw before, and every later phase changes rendering rather than plumbing.

---

## Phase 3: User Story 1 - Emphasis and links read as formatting (Priority: P1) 🎯 MVP

**Goal**: bold, italic, inline code, strikethrough and links render as native Jira
formatting; no Markdown delimiter of a converted construct survives in the text a
reader sees.

**Independent Test**: sync a spec whose overview prose contains all five inline
constructs, then confirm each renders natively and that no `*`, `` ` ``, `~` or
`[…](…)` punctuation appears in the ticket body.

### Tests for User Story 1 ⚠️

> Write these FIRST and confirm they FAIL. Each names the contract rule it pins,
> so a failure points at a numbered rule rather than at "rendering is broken".

- [X] T020 [P] [US1] Write failing tests for worked examples E1–E15 in `tests/bash/engine/test_markdown_inline.bats`, one test per example, named for it (`E7 — 2 * 3 * 4 stays literal`)
- [X] T021 [P] [US1] Mirror the E1–E15 tests in `tests/powershell/engine/Markdown.Inline.Tests.ps1`
- [X] T022 [P] [US1] Write failing tests for the C9 delimiter rules in `tests/bash/engine/test_markdown_inline.bats`: C9.1 (opener followed by non-whitespace), C9.2 (nearest valid closer), C9.4 (no closer ⇒ literal), C9.6 (depth cap 8), and above all **C9.3** — `parse_description_blocks`, `schema_version` and `customfield_10011` must survive with zero marks
- [X] T023 [P] [US1] Mirror the C9 tests in `tests/powershell/engine/Markdown.Inline.Tests.ps1`
- [X] T024 [P] [US1] Write failing tests for the neutral→ADF mark map (`bold`→`strong`, `italic`→`em`, `monospace`→`code`, `strikethrough`→`strike`, `link`→`link` with `href`) in `tests/bash/sink/test_adf_marks.bats`
- [X] T025 [P] [US1] Mirror the mark-map tests in `tests/powershell/sink/Adf.Marks.Tests.ps1`
- [X] T026 [P] [US1] Write a failing test proving a BLOCK-tier host carried inside a Markdown link (`[docs](https://<blocked-host>/x)`) still blocks, in `tests/bash/sink/test_privacy_block.bats` — FR-016, and the one privacy regression this feature could plausibly introduce
- [X] T027 [P] [US1] Mirror the privacy test in `tests/powershell/sink/PrivacyBlock.Tests.ps1`

### Implementation for User Story 1

- [X] T028 [US1] Implement C1 (backslash escape over the A3 punctuation set) and C2 (N-backtick code span, literal interior, unmatched run stays literal) in `scripts/bash/engine/markdown.sh`
- [X] T029 [US1] Implement the C9 delimiter matcher in `scripts/bash/engine/markdown.sh` — including C9.3's underscore word-boundary rule and the C9.6 depth cap — then C6 (`~~`), C7 (`**`/`__`) and C8 (`*`/`_`) on top of it
- [X] T030 [US1] Implement C3 (autolink), C4 (image ⇒ alt text) and C5 (link) in `scripts/bash/engine/markdown.sh`, with the FR-006 target validation (`^https?://`, no whitespace) and the `label (target)` degradation for anything else
- [X] T031 [US1] Implement C10 (raw HTML tag discarded, inner text kept) and C11 (literal fallthrough) in `scripts/bash/engine/markdown.sh`, completing the precedence ladder
- [X] T032 [US1] Mirror C1, C2, C6–C9 in `scripts/powershell/engine/Markdown.psm1`
- [X] T033 [US1] Mirror C3, C4, C5, C10, C11 in `scripts/powershell/engine/Markdown.psm1`
- [X] T034 [US1] Replace the `markdown_inline_plain` call sites in `scripts/bash/engine/parse.sh` with the full tokenizer, so description prose is tokenized rather than wrapped
- [X] T035 [US1] Mirror the call-site change in `scripts/powershell/engine/Parse.psm1`
- [X] T036 [US1] Route acceptance-criteria clauses through the tokenizer in `parse_acceptance_criteria` in `scripts/bash/engine/parse.sh`, **deleting the `t="${t//\*\*/}"` global asterisk strip at line 199** — today's partial workaround, now subsumed
- [X] T037 [US1] Mirror the acceptance-criteria change in `Get-JiraParsedAcceptance` in `scripts/powershell/engine/Parse.psm1`
- [X] T038 [US1] Route `guidance` design values through the tokenizer in `parse_design` in `scripts/bash/engine/parse.sh`, leaving `figma_link` values as plain URL strings (data-model §3)
- [X] T039 [US1] Mirror the design change in `Get-JiraParsedDesign` in `scripts/powershell/engine/Parse.psm1`
- [X] T040 [US1] Map neutral marks onto ADF marks in `_adf_blocks_to_nodes` and the acceptance/design renderers in `scripts/bash/sink/jira/adf.sh` — the only file in the engine-facing path where ADF mark names may appear
- [X] T041 [US1] Mirror the mark map in `ConvertTo-JiraAdfBlockNode`, `New-JiraAdfGherkinPanel` and `New-JiraAdfDesignNode` in `scripts/powershell/sink/jira/Adf.psm1`
- [X] T042 [US1] Run `bash tests/conformance/ci-conformance.sh` and confirm the `us1-markdown-rendering` scenario diverges by zero bytes between ports

**Checkpoint**: US1 is shippable on its own. The reported defect is fixed; block
structure is still flattened as it is today.

---

## Phase 4: User Story 2 - Document structure survives the crossing (Priority: P2)

**Goal**: bullet lists, numbered lists, fenced code blocks and headings arrive as
real blocks instead of one run-on paragraph.

**Independent Test**: sync a spec whose overview contains a bullet list, an
ordered list and a fenced code block; confirm three distinct rendered blocks.

### Tests for User Story 2 ⚠️

- [X] T043 [P] [US2] Write failing tests for block rules B1–B8 in `tests/bash/engine/test_markdown_blocks.bats`: fenced code (including an unclosed fence), ATX headings, bullet items, ordered items, blockquote stripping, table rows with the delimiter row dropped, blank-line closing, and paragraph joining
- [X] T044 [P] [US2] Mirror the B1–B8 tests in `tests/powershell/engine/Markdown.Blocks.Tests.ps1`
- [X] T045 [P] [US2] Write a failing test for the B9 selection cap in `tests/bash/engine/test_markdown_blocks.bats`, asserting the data-model §4 worked example verbatim — a spec opening with a heading must still ship its prose, because headings consume no cap budget
- [X] T046 [P] [US2] Mirror the B9 cap test in `tests/powershell/engine/Markdown.Blocks.Tests.ps1`
- [X] T047 [P] [US2] Write failing tests for `ordered_list` rendering and for verbatim `code` bodies (no inline interpretation, FR-007) in `tests/bash/sink/test_adf_marks.bats`
- [X] T048 [P] [US2] Mirror the `ordered_list` and code-body tests in `tests/powershell/sink/Adf.Marks.Tests.ps1`

### Implementation for User Story 2

- [X] T049 [US2] Implement block segmentation B1–B8 in `scripts/bash/engine/markdown.sh`, emitting `heading`/`paragraph`/`bullet_list`/`ordered_list`/`code` blocks with inline-tokenized text — except `code` bodies, which stay plain (FR-007)
- [X] T050 [US2] Mirror block segmentation B1–B8 in `scripts/powershell/engine/Markdown.psm1`
- [X] T051 [US2] Replace the line-merging loop in `parse_description_blocks` in `scripts/bash/engine/parse.sh` with a call to block segmentation, applying the B9 cap (first two **content** blocks; headings free; a trailing content-less heading dropped)
- [X] T052 [US2] Mirror the segmentation and cap in `Get-JiraParsedDescription` in `scripts/powershell/engine/Parse.psm1`
- [X] T053 [US2] Render `ordered_list` as an ADF ordered list in `scripts/bash/sink/jira/adf.sh`
- [X] T054 [US2] Mirror `ordered_list` rendering in `scripts/powershell/sink/jira/Adf.psm1`
- [X] T055 [US2] Extend the fixture spec in `tests/conformance/fixtures/repo-with-markdown-prose/` with a bullet list, an ordered list and a fenced code block, then re-run `bash tests/conformance/ci-conformance.sh`

**Checkpoint**: US1 and US2 both work; a synced description now matches the shape
its author wrote.

---

## Phase 5: User Story 3 - Already-synced tickets self-heal, then stay quiet (Priority: P3)

**Goal**: the first reconcile after this change rewrites stale descriptions; every
reconcile after that writes nothing.

**Independent Test**: run reconcile twice against tickets written by the previous
behaviour — one description update on the first run, zero writes on the second.

**Note**: no new mechanism is built here. `idempotency_field_status` already
decides this; the phase exists because an undetermined renderer would break
Principle II silently, and only a two-run test catches that.

### Tests for User Story 3 ⚠️

- [X] T056 [P] [US3] Write a failing two-run test in `tests/bash/commands/test_reconcile_zero_churn.bats`: against a ticket carrying a pre-feature description, run 1 issues exactly one description update and run 2 issues zero writes (FR-011, FR-012, SC-004)
- [X] T057 [P] [US3] Mirror the two-run test in `tests/powershell/commands/Reconcile.ZeroChurn.Tests.ps1`
- [X] T058 [P] [US3] Write a failing test that a human-origin ticket's human-authored prefix above the managed delimiter survives the rewrite byte-for-byte, in `tests/bash/sink/test_us7_plan_apply.bats` (FR-013)
- [X] T059 [P] [US3] Mirror the human-prefix test in `tests/powershell/sink/PlanApply.HumanContent.Tests.ps1`
- [X] T060 [P] [US3] Write a failing test that the rendered description appears in the dry-run preview with no write issued, in `tests/bash/commands/test_reconcile_dry_run.bats` (FR-014)
- [X] T061 [P] [US3] Write the FR-000/FR-000a assertion in `tests/bash/commands/test_reconcile_durability.bats`: after a run, every byte of the fixture's spec files **other than `<!-- speckit-jira … -->` marker lines** is unchanged — the bridge's marker write (`commands/reconcile.sh:625`, `:878`) is a pre-existing controlled exception and must be excluded, or the test fails for the wrong reason

### Implementation for User Story 3

- [X] T062 [US3] Confirm T056–T061 pass with no production change; if any fails, the defect is renderer non-determinism (mark ordering, span merging, or map iteration order) — fix it in `scripts/bash/engine/markdown.sh` and its mirror, never by relaxing the test
- [X] T063 [US3] Add a two-run scenario at `tests/conformance/scenarios/us3-markdown-idempotent.json` and confirm both ports agree on the write counts

**Checkpoint**: all three stories work; the backlog heals once and then stays
quiet.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T064 Push to `ci/windows-probe` and confirm **no new divergence annotation relative to `origin/main`** on the real Windows runner (~11 min; results arrive as check-run annotations, not job logs). **Do not expect green**: `Unit suites (windows-latest)` is already red on `main` (commit `2a75c88`) with two pre-existing 015 divergences — `us2-field-defaults-option-question` and `us2-field-defaults-question`, both a `C:\…` vs `/…` path-spelling signature. Fetch the same check-run on `main` (`gh api repos/Fyloss/spec-kit-jira/commits/<sha>/check-runs`) and diff the annotation sets; only a *new* annotation belongs to this branch. FR-015 and SC-005 are unproven without this comparison
- [X] T065 [P] Verify no glob pattern in `scripts/bash/engine/markdown.sh` contains `$'\r\n'` and that no `jq` call bypasses `lib/output.sh`, per `docs/10-windows-portability.md`
- [X] T066 [P] Add `engine/markdown.sh` and `engine/Markdown.psm1` to the module map in `docs/02-module-architecture.md`, describing the layer boundary they sit on
- [X] T067 [P] Document the supported Markdown subset for spec authors in `docs/05-reconcile-flow.md`, linking to `specs/016-jira-markdown-rendering/contracts/markdown-subset.md` as the normative reference
- [X] T068 [P] Add the feature to `CHANGELOG.md` under the unreleased heading, naming the user-visible change (descriptions render formatted) and the one-off corrective rewrite of existing tickets
- [X] T069 Run `shellcheck` over the Bash port and `actionlint` over `.github/workflows/`, both clean
- [X] T070 Confirm coverage stays ≥80% (Constitution XIII) with the new module included — measure locally, since the `Bash coverage >= 80% (kcov)` check is **also red on `main`** for an unrelated reason (its kcov step is killed at the step timeout, and the fallback fails by design), so that check going red on this branch is not by itself evidence of a coverage regression
- [X] T071 Walk `specs/016-jira-markdown-rendering/quickstart.md` end to end and confirm every row of its "What done looks like" table

---

## Phase 7: The feature 012 overlap (FR-017/FR-018/FR-019)

Feature 012 (the `tasks.md` sub-task tier) merged to `main` while this branch was
in flight. It added a **fourth** prose-bearing position — a task line's own text —
and built its descriptions in the pre-016 block shape, so every backtick-quoted
path in a `tasks.md` line reached the Jira reader as literal punctuation. Neither
spec claimed the surface: 012 predates the rendering work, and 016's FRs said
"spec text". These tasks close it.

- [X] T072 [P] Write failing tests for the neutral reader: a task description block carries `spans`, a backtick path becomes a `monospace` span, bold/strikethrough/link marks arrive, an unbalanced delimiter degrades, CRLF matches LF, and `title` keeps its raw markup — `tests/bash/engine/test_tasks_parse_markdown.bats` and its Pester mirror `tests/powershell/engine/TasksParse.Markdown.Tests.ps1`
- [X] T073 [P] Write failing tests for the sink: the sub-task body renders `code`/`strong`/`link` ADF marks, reads `.description.blocks` rather than `.title`, renders multiple blocks in order, and leaves the bridge-composed metadata bullets unmarked — `tests/bash/sink/test_adf_task_markdown.bats` and its Pester mirror in `tests/powershell/sink/Adf.Task.Tests.ps1`
- [X] T074 [P] Write failing tests for FR-019 in `tests/bash/engine/test_interchange.bats` and `tests/powershell/engine/Interchange.Tests.ps1`: a task description paragraph in the old raw-string shape is refused, one with marked spans validates, an invalid mark kind is refused, and a non-http link target is refused
- [X] T075 Tokenize the task's own text in `scripts/bash/engine/tasks_parse.sh` and `scripts/powershell/engine/TasksParse.psm1`, emitting `{type:"paragraph", spans:[…]}`; leave `title` verbatim for the summary
- [X] T076 Render the sub-task body from `.description.blocks` through the shared block renderer in `scripts/bash/sink/jira/adf.sh` and `scripts/powershell/sink/jira/Adf.psm1`, keeping the metadata bullet list plain (FR-018)
- [X] T077 Add the task-description block rules to `scripts/bash/engine/interchange.sh` and `scripts/powershell/engine/Interchange.psm1` so no tier can reintroduce the raw-string shape (FR-019)
- [X] T078 [P] Migrate every remaining test fixture off the pre-016 `{type:"paragraph","text":…}` shape across both ports
- [X] T079 [P] Add the conformance fixture `tests/conformance/fixtures/repo-with-task-markdown/` (a `tasks.md` exercising backtick paths, bold, italic, strikethrough, a link, an unbalanced delimiter, a backslash escape, a non-http target and non-ASCII text) plus the scenario `us1-task-markdown-rendering.json`, and bump the recorded corpus count to 87
- [X] T080 [P] Update `$defs/task` in `specs/001-jira-reconcile-engine/contracts/neutral-interchange.schema.json` — it was still feature 001's never-implemented three-field shape, which 012's real task object would have failed
- [X] T081 [P] Record the overlap in `specs/016-jira-markdown-rendering/data-model.md` §3, `docs/05-reconcile-flow.md`, and `CHANGELOG.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately
- **Foundational (Phase 2)**: depends on Setup; **blocks all user stories**
- **US1 (Phase 3)**: depends on Phase 2
- **US2 (Phase 4)**: depends on Phase 2. Independent of US1 in principle, but both
  edit `markdown.sh`, `parse.sh` and `adf.sh` — see the conflict note below
- **US3 (Phase 5)**: depends on US1 (there is no rendering change to be idempotent
  about until US1 lands). This is a **genuine** cross-story dependency, not an
  incidental one
- **Polish (Phase 6)**: depends on all desired stories

### The one honest caveat about story independence

US1 and US2 are independently *testable* and independently *shippable*, but they
are not independently *stageable by two people without coordination*: both add
rules to the same two module files, one per port. Running them in parallel means
merge conflicts in `markdown.sh` / `Markdown.psm1`, not broken behaviour. With one
implementer, do US1 → US2 in priority order and the question does not arise.

### Within Each Story

- Tests are written first and must FAIL before implementation (Constitution XIII)
- Bash and PowerShell tasks for the same rule land together
- Engine before sink: the tokenizer produces the model the renderer consumes
- Conformance last within the phase — it proves what the unit tests already assert

---

## Parallel Opportunities

Setup (different files, no shared state):

```bash
T001  # conformance fixture
T002  # conformance scenario
T003  # boundary gate test cases
```

US1 test authoring — the whole block is parallel, and writing it all before any
implementation is the point:

```bash
T020 T021  # E1–E15, both ports
T022 T023  # C9 delimiter rules, both ports
T024 T025  # ADF mark map, both ports
T026 T027  # privacy guard, both ports
```

US1 implementation is **largely serial**: T028–T031 all edit
`scripts/bash/engine/markdown.sh`, and the precedence ladder means C1/C2 must
exist before C9 can defer to them. T032/T033 (the PowerShell mirror) can run in
parallel with each other once their Bash counterparts are done.

US3 is almost entirely parallel — six test tasks across six different files
(T056–T061), with T062 as the join.

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1 — Setup
2. Phase 2 — Foundational, ending at T019's proof that **nothing changed yet**
3. Phase 3 — US1
4. **STOP and VALIDATE**: a spec containing `**FR-012**` and a Markdown link
   renders as bold text and a clickable link, with no delimiters visible

That is the whole reported defect, fixed and shippable. US2 and US3 improve on it
but are not needed to close the complaint.

### Incremental Delivery

| Increment | Delivers | Risk if it stops here |
|---|---|---|
| Phase 2 | Nothing visible; new interchange model | None — output byte-identical |
| + US1 | Inline formatting renders | Lists still flatten into prose |
| + US2 | Structure preserved | None |
| + US3 | Existing tickets heal, proven quiet | Stale tickets keep old descriptions until their spec changes |

### Task Count

| Phase | Tasks | IDs |
|---|---|---|
| 1 — Setup | 4 | T001–T004 |
| 2 — Foundational | 15 | T005–T019 |
| 3 — US1 (P1) | 23 | T020–T042 |
| 4 — US2 (P2) | 13 | T043–T055 |
| 5 — US3 (P3) | 8 | T056–T063 |
| 6 — Polish | 8 | T064–T071 |
| 7 — The 012 overlap | 10 | T072–T081 |
| **Total** | **81** | |

Test tasks: 33 of 81. That ratio is the constitution's TDD requirement meeting a
normative grammar — every numbered rule in the contract owes a failing test in
both ports before it owes an implementation.

Phase 7 was not planned: it exists because feature 012 merged to `main` mid-flight
and created a prose-bearing position this feature's FRs had not been written to
cover. Its three test tasks came first and failed for the right reason — 14 red
across the two ports — before any of its implementation tasks were written.

---

## Notes

- `[P]` means different files and no dependency on incomplete work
- Verify each test fails before implementing against it
- Commit after each task or logical pair (a Bash task and its PowerShell mirror)
- The two failure modes to watch: **non-determinism** in the renderer (breaks
  Principle II, caught only by the two-run test) and **twin-port divergence**
  (caught only by conformance, and on Windows only by the probe)

---

## Phase 8: Convergence

Every task in Phases 1–7 is complete and the tree is green: `tests/run-bash.sh`
reports 1507 tests across 154 files with zero failures, and
`bash tests/conformance/ci-conformance.sh` exits 0 with zero divergence lines
over 87 scenarios; `shellcheck` and `actionlint` are clean. Nothing below is a
broken behaviour. Every item is a **proof** that the artifacts claim and the
tree does not carry — a requirement whose evidence is missing, one-ported, or
silently skipped. They matter because this feature's whole safety argument is
"two ports, proven equal by a corpus": an unexercised construct or an
unmirrored test is a divergence waiting to happen with nothing to catch it.

- [X] T082 Re-run the Windows probe against the current tree and confirm no new divergence annotation relative to `origin/main` per FR-015 (partial) — T064's proof does not cover HEAD: `origin/ci/windows-probe` sits at `fb387c0`, which carries no `scripts/bash/engine/markdown.sh` and is not an ancestor of `6e5f01a`. T064 was ticked in `dbc3ff0` ("71/71"), before Phase 7 landed `tasks_parse.sh` tokenization, the `.description.blocks` sub-task renderer, the FR-019 interchange rules and the `repo-with-task-markdown` fixture. Follow the T064 method: push, wait ~11 min, read check-run annotations (not job logs), and diff against the same check-run on `main` — the baseline is red with two pre-existing 015 `us2-field-defaults-*` path-spelling divergences, so only a *new* annotation belongs to this branch. **One retry maximum** if the run flakes
- [X] T083 Mirror the two T061 FR-000/FR-000a prose-durability tests in `tests/powershell/commands/Reconcile.Durability.Tests.ps1` per FR-000, SC-000 (partial) — the fixture `repo-with-markdown-prose` is referenced by zero PowerShell tests, so the spec's strictest requirement ("no write of any kind" to a source file) is asserted on one port only. Cover both the real run and the `--dry-run`, excluding `<!-- speckit-jira … -->` marker lines as the Bash twin does at `tests/bash/commands/test_reconcile_durability.bats:136,155`
- [X] T084 Extend the conformance corpus so `heading`, `ordered_list` and `code` blocks actually reach a rendered description per SC-002, SC-005 (partial) — `tests/conformance/fixtures/repo-with-markdown-prose/specs/001-markdown-prose/spec.md` contains an ordered list, a fenced code block and a table, but the B9 cap keeps only the first two content blocks, so `parse_description_blocks` on that fixture emits `paragraph` + `bullet_list` and nothing else. Three of the nine supported constructs are therefore proven by per-port unit tests alone and never byte-compared across ports. Either reorder the fixture prose so those blocks fall inside the cap, or add a second story section whose first two content blocks are an ordered list and a fenced code block, then re-run `bash tests/conformance/ci-conformance.sh`
- [X] T085 Add a non-ASCII-inside-a-formatted-span test to `tests/bash/engine/test_markdown_inline.bats` and its Pester mirror `tests/powershell/engine/Markdown.Inline.Tests.ps1` per spec Edge Cases "Non-ASCII content" (missing) — accented characters, CJK and emoji inside a bold/code/link span must survive byte-for-byte. Today the only non-ASCII payload in the whole 016 set is `café 日本語` at `tests/conformance/fixtures/repo-with-task-markdown/specs/001-widget/tasks.md:67`, and it sits outside every span; no emoji appears anywhere. Add the same content to a corpus fixture so FR-015 covers it cross-port too
- [X] T086 Add a CRLF-equals-LF test at the block layer in `tests/bash/engine/test_markdown_blocks.bats` and `tests/powershell/engine/Markdown.Blocks.Tests.ps1` per FR-015 and spec Edge Cases "Windows line endings" (partial) — CRLF equivalence is asserted only for the tasks tier (`tests/bash/engine/test_tasks_parse_markdown.bats:338` plus its Pester mirror). The spec-prose path has none, even though `_md_strip_cr` (`scripts/bash/engine/markdown.sh:467`, called at `:526`) is precisely the code a Windows regression would break, and the MSYS matcher hazard makes this the port's most fragile surface
- [X] T087 Mirror the T060 dry-run rendered-preview test in `tests/powershell/commands/Reconcile.DryRun.Tests.ps1` per FR-014, US3/AC4 (missing) — the Bash test lives at `tests/bash/commands/test_reconcile_dry_run.bats:135`; the PowerShell file carries nothing for 016. T060 shipped without the sibling task this file's own mirror rule requires ("no Bash change merges without its PowerShell twin"), so the gap is in `tasks.md` as much as in the tree
- [X] T088 Add a module-property guard asserting `scripts/bash/engine/markdown.sh` and `scripts/powershell/engine/Markdown.psm1` contain no file-write operation per FR-000 and quickstart §8 (partial) — §8 states plainly that a passing single-run assertion "is weaker than it looks", because FR-000 claims the *absence of a write path* and one scenario cannot prove absence. Both modules are clean today (verified: no redirect, `tee`, `Out-File`, `Set-Content`, `Add-Content` or `StreamWriter` in either), but nothing fails if a future edit adds one
