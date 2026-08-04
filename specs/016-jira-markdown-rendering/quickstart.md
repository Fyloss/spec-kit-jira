# Phase 1 — Quickstart: validating Markdown rendering

How to prove this feature works, in the order the proofs get cheap. Nothing here
is implementation code — that belongs in `tasks.md`.

## Prerequisites

- `bats` and `jq` (the Bash suite needs nothing else)
- PowerShell 7+ and `pwsh` on PATH (PowerShell suite and conformance only)
- Run everything from the worktree root

---

## 1. Inner loop — the tokenizer alone (seconds)

The tokenizer is a pure function, so it is testable without Jira, without
config, and without the reconcile pipeline. This is where nearly all the
iteration happens.

```bash
tests/run-bash.sh --since HEAD          # change-scoped, ≤60s on a single-module diff
bats -r tests/bash/engine/test_markdown_inline.bats   # one rule at a time
```

Every worked example in
[contracts/markdown-subset.md](./contracts/markdown-subset.md) Part E is a test
case, named for its rule (`E7 — 2 * 3 * 4 stays literal`). A failing rule names
itself.

**Write these first** (Constitution XIII). The highest-value failing tests, in
order:

| Test | Proves | Rule |
|---|---|---|
| `**FR-012**` → one bold span | The reported defect is fixed | C7 |
| `parse_description_blocks` → no italics | The corpus is not mangled | C9.3 |
| `` `**x**` `` → monospace, literal asterisks | Code is protected | C2, FR-007 |
| `[g](../local.md)` → `g (../local.md)`, no link | Unsafe targets stay visible | C5, FR-006 |
| `**unclosed` → literal | Malformed input cannot fail a run | C9.4, FR-005 |
| Adjacent equal-mark spans merge | Byte equality is provable at all | D1 |

## 2. Block segmentation (seconds)

```bash
bats -r tests/bash/engine/test_markdown_blocks.bats
```

The case most likely to regress silently is the selection cap
([data-model.md](./data-model.md) §4): a spec opening with a heading must still
ship its prose, because headings do not consume cap budget. Assert the worked
example in §4 verbatim.

## 3. The rendered ticket (seconds)

```bash
bats -r tests/bash/sink/test_adf_marks.bats
```

Asserts the neutral→ADF mark map (`bold`→`strong`, `italic`→`em`,
`monospace`→`code`, `strikethrough`→`strike`) and that `ordered_list` renders as
an ordered list. This is the only place the ADF names may appear.

## 4. Full Bash suite (~190s)

```bash
tests/run-bash.sh
```

Expect churn in existing description assertions — `test_parse_title_desc.bats`,
`test_plan_apply_content.bats`, `test_adf.bats` and the epic-block tests encode
today's plain-string blocks. **Each such update is a review decision, not a
formality**: an assertion that changes from "raw markup passes through" to
"markup renders" is the fix being proven; an assertion that changes because the
selected *prose* moved is a scope violation (spec Out of Scope) and means
something went wrong.

## 5. Cross-port byte equality (FR-015)

```bash
bash tests/conformance/ci-conformance.sh
```

Success is silent: exit 0 and zero `conformance divergence` lines. There is no
pass banner, and temp-path noise in the output is the harness, not a failure.

The new fixture `repo-with-markdown-prose` carries a spec exercising every Part E
example, so a divergence points at a numbered rule rather than at "the ports
disagree somewhere".

**Windows is not covered by this run.** A Windows-only divergence is diagnosed by
measurement on the real runner — push to `ci/windows-probe` (~11 min, results
arrive as check-run annotations), never by emulation. The hazards this feature
must clear there: no `$'\r\n'` inside any glob, and no direct `jq` call in the
Bash port.

**The Windows baseline is red, not green.** `Unit suites (windows-latest)` fails
on `main` today with two pre-existing divergences from feature 015
(`us2-field-defaults-*`, a `C:\…` vs `/…` path-spelling signature). Judge this
branch by diffing its annotations against the same check-run on `main` — only a
*new* annotation is yours. Chasing "all green" here means chasing someone else's
defect.

## 6. Constitutional gates

```bash
shellcheck scripts/bash/**/*.sh
actionlint
bats -r tests/bash/ci/test_boundary_gate_neutral_tokens.bats
```

The boundary test must stay green **after** Gate #2 gains `bulletList`,
`codeBlock`, `listItem` and `panelType`. Those four were verified absent from
both engine layers at plan time; if the gate goes red, an ADF name has leaked
into the engine and the fix is to rename it, not to relax the gate.

---

## 7. End-to-end, against the mock

The harness takes a scenario **file** and a port, and captures the post-run
repository tree into an outdir:

```bash
# run-scenario.sh <scenario.json> <bash|powershell> [outdir]
bash tests/conformance/run-scenario.sh \
  tests/conformance/scenarios/us1-markdown-rendering.json bash /tmp/out-bash
```

The scenario's `fixture` is copied into a scratch workdir, so the fixture on disk
is never the thing under test — assertions must read the captured tree.

Proves the three user stories as a reader experiences them:

- **US1/US2** — the rendered description carries marks and blocks, and no
  Markdown delimiter of a converted construct survives in any text node.
- **US3** — run reconcile twice: exactly one description update on the first
  run, **zero writes** on the second (`idempotency_field_status` → `unchanged`).
  A second-run write means the renderer is not deterministic, and Principle II
  is broken.

## 8. FR-000 — rendering writes nothing to the source

**Read this before writing the test.** The bridge legitimately *does* modify spec
files: `marker_splice_write_file` (`commands/reconcile.sh:625`, `:878`) inserts
its ticket-identifier marker lines, e.g.

```html
<!-- speckit-jira story=a1b2c3d4e5f60718 ticket=... -->
```

That is a pre-existing, separate behaviour and one of Principle I's controlled
exceptions — FR-000a puts it explicitly outside this feature. So a naive
"nothing changed" assertion is **wrong and will fail for the right reason**. The
correct assertion is that *prose* is untouched: compare the fixture against the
captured post-run tree, ignoring marker lines.

```bash
# Compare the pristine fixture with the post-run tree the harness captured,
# ignoring the bridge's own marker lines.
diff -r \
  <(grep -rvh 'speckit-jira ' tests/conformance/fixtures/repo-with-markdown-prose) \
  <(grep -rvh 'speckit-jira ' /tmp/out-bash/workdir) \
  || echo "FR-000 VIOLATED: rendering rewrote author prose"
```

This belongs in the suite as a permanent assertion (SC-000), covering both
dry-run and real runs.

**A passing test here is weaker than it looks.** FR-000 is a claim about a whole
class of behaviour — the absence of a write path — and one scenario cannot prove
absence. Pair it with a review check that `engine/markdown.sh` and `Markdown.psm1`
open no file for writing at all, which is a property of the module rather than of
one run.

---

## What "done" looks like

| Spec item | Proof |
|---|---|
| FR-000, FR-000a, SC-000 | §8 — prose byte-identical after a run, marker lines excluded |
| FR-001…FR-007, SC-001…SC-003 | §1 — every Part E example |
| FR-008, FR-009 | §2 — block segmentation and the cap |
| FR-010 | §1 — images, HTML, table rows |
| FR-011…FR-014, SC-004 | §7 — one write then zero |
| FR-015, SC-005 | §5 + a green `ci/windows-probe` run |
| FR-016 | A BLOCK-tier host inside a Markdown link still blocks (research §4) |
| SC-006 | §1 — malformed input renders literally and never fails |
| SC-007 | Budget held by construction: no subprocess per span (contract D5) |
