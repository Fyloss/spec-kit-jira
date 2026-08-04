# Feature Specification: Markdown Prose Showcase

We need every Markdown pattern the bridge renders to survive round-tripping
through both ports identically.

### User Story 1 - Renders formatted prose (Priority: P1)

**FR-012** applies, and so does running `reconcile --dry-run`. See the
[guide](https://ex.invalid/s) for background — *emphasis*, _also emphasis_,
and ~~strikethrough~~ all render, but \*escaped asterisks\* stay literal.

- see the [local guide](../local.md) and note that 2 * 3 * 4 stays literal too
- `parse_description_blocks` never gets marked, but **bold with `code` inside** carries both marks
- an image like ![diagram](x.png) degrades to its alt text
- an autolink like <https://ex.invalid> becomes a link
- raw HTML like <b>text</b> keeps only its inner text
- this final item is **unclosed and stays literal

1. first ordered step, with `` `**not bold**` `` staying monospace only
2. second ordered step

```text
a fenced code block, rendered verbatim — **not bold**, [not](a-link)
```

| a | b |
|---|---|
| left | right |

- **Given** a signed-in user
- **When** they open the board
- **Then** the widgets load
