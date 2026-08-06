# Phase 1 — Data Model: neutral blocks and inline spans

The one structure this feature changes: the `content_blocks` value that crosses
the engine→sink interface. Everything else in the neutral document is untouched.

## §1 — The change in one line

`text: "…"` (a string of raw Markdown) becomes `spans: [ … ]` (an array of
semantically marked runs). Nothing about *which* prose is selected changes.

**Before** — what the sink receives today:

```json
{"type":"paragraph","text":"The **FR-012** rule, see [guide](https://ex.invalid)."}
```

**After**:

```json
{"type":"paragraph","spans":[
  {"text":"The ","marks":[]},
  {"text":"FR-012","marks":[{"kind":"bold"}]},
  {"text":" rule, see ","marks":[]},
  {"text":"guide","marks":[{"kind":"link","href":"https://ex.invalid"}]},
  {"text":".","marks":[]}
]}
```

## §2 — Entities

### `inline` — a sequence of marked runs

An array of `span`. Empty array = empty text. The unit that every text-bearing
position now holds.

### `span`

| Field | Type | Rules |
|---|---|---|
| `text` | string | The literal characters a reader sees. Never contains Markdown syntax of a *converted* construct. May be empty only if the whole `inline` is empty |
| `marks` | array of `mark` | **Always present**, `[]` when unmarked. Always emitted so neither port can differ by an omitted key (research §3) |

**Invariant — no adjacent duplicates**: two consecutive spans never carry an
equal `marks` array; the tokenizer merges them. Without this rule the same input
could produce two different-but-equivalent span lists, and byte equality across
ports (FR-015) would be unprovable.

**Invariant — mark order**: `marks` is sorted by `kind`, alphabetically
(`bold` < `italic` < `link` < `monospace` < `strikethrough`). Canonical, so
nesting order in the source cannot leak into the output.

### `mark`

| Field | Type | Rules |
|---|---|---|
| `kind` | enum | `bold` \| `italic` \| `monospace` \| `strikethrough` \| `link` |
| `href` | string | **Required iff** `kind == "link"`, forbidden otherwise. Always an absolute `http`/`https` URL — FR-006 guarantees no other scheme reaches this field |

Neutral names, deliberately not ADF's (`strong`/`em`/`code`/`strike`) — see
research §1 for the map and the CI gate that keeps it honest.

### `block`

| `type` | Carries | Notes |
|---|---|---|
| `heading` | `level` (1–6), `inline` | New: headings in the selected region are now emitted instead of dropped (§4) |
| `paragraph` | `inline` | |
| `bullet_list` | `items`: array of `inline` | Was array of string |
| `ordered_list` | `items`: array of `inline` | **New block kind** — FR-008 |
| `code` | `text` (plain string) | Deliberately *not* `inline`: FR-007 forbids interpreting markup inside code |
| `panel_ref` | `ref` | Unchanged; the sink places a panel here |

`code` keeping a plain `text` field is the one asymmetry in the model, and it is
load-bearing: it makes "no markup inside code" a property of the *schema* rather
than a rule the tokenizer must remember.

## §3 — Where the model applies

Every text-bearing position that carries author prose becomes `inline`:

| Position | Source | Rationale |
|---|---|---|
| `epic.description.blocks[]`, `stories[].description.blocks[]` | Overview prose | FR-001, FR-008 — the reported defect |
| `stories[].acceptance_criteria[].{given,when,then}[]` | Given/When/Then clauses | Spec Assumptions: AC is synced prose. Note this replaces the crude `t="${t//\*\*/}"` global asterisk strip at `parse.sh:199`, which is today's partial workaround |
| `stories[].design[].value` where `kind == "guidance"` | Design guidance lines | Same reasoning |
| `stories[].tasks[].description.blocks[]` | A task line's own text in `tasks.md` | FR-017 — feature 012's sub-task tier. Task text is as full of backtick-quoted paths as spec prose is, so the same defect applies to it verbatim |

**Not** converted: `design[].value` where `kind == "figma_link"` (a URL, not
prose), `title` fields (rendered as the Jira summary, a plain-text field — no
rich text is possible there), `code` block bodies, and the metadata lines
feature 012 appends to a sub-task description — `Identifier:`, `Phase:`,
`Attribution:`, `Parallel-safe:`, `Files:`, `Depends on:` (FR-018). Those are
composed by the bridge, not written by an author, so there is no markup in them
to honour; `Files:` in particular carries paths the task parser already
extracted from *inside* their backticks.

## §4 — The selection rule, restated

Unchanged in what it selects; adjusted only in what it counts.

Today (`parse.sh:136-175`): collect prose preceding the first
`Acceptance|Design|Task|Scenario|Requirement|Success|Edge` heading; merge
consecutive lines into paragraphs; **keep the first two paragraphs**.

After: the same region, segmented into real blocks, keeping the first two
**content** blocks — where headings do not consume budget and a trailing heading
with no following content is dropped.

Why the exception exists: headings used to be separators and vanished. Now they
are blocks (US2 AS-4). If a heading spent cap budget, a spec opening with a
heading would ship a ticket containing a heading and nothing else — a regression
introduced by a feature meant to improve readability. Counting only content
blocks preserves the existing selection semantics exactly.

**Worked example** — the same source under both rules:

```markdown
## Overview
Some intro prose.
- item a
- item b
```

| | Blocks emitted |
|---|---|
| Today | 1 paragraph: `"Some intro prose. item a item b"` |
| After | `heading("Overview")` + `paragraph("Some intro prose.")` + `bullet_list(["item a","item b"])` — 2 content blocks, cap satisfied |

## §5 — Validation rules

`interchange_validate` (`engine/interchange.sh:23`) and its PowerShell mirror
gain, alongside the existing non-empty-blocks check:

1. Every block's `type` is in the enum (now including `ordered_list`).
2. `heading` / `paragraph` carry `spans`; `bullet_list` / `ordered_list` carry
   `items`; `code` carries `text`; `panel_ref` carries `ref`.
3. Every `span` has `text` (string) and `marks` (array).
4. Every `mark` has a `kind` in the enum, and `href` present iff
   `kind == "link"`.
5. `href` matches `^https?://`.

Rule 5 is the schema-level backstop for FR-006: even if the tokenizer had a bug,
a non-http target could not reach Jira as a live link — validation fails and,
per Constitution VIII, a validation failure blocks **every** downstream write.

## §6 — State transitions

None. The model is a pure value produced fresh on each run from the spec file and
discarded after the write (research §5). There is no persisted state, no
migration, and no path by which a rendered description can flow back to disk —
which is FR-000 expressed as a property of the data model rather than as a rule
someone has to follow.

The bridge's separate marker-line write (`reconcile.sh:625`, `:878`) touches the
spec file but never this model: it splices a `<!-- speckit-jira … -->` line and
reads nothing from the rendered description. FR-000a keeps the two paths
distinct, and quickstart §8 tests them apart.
