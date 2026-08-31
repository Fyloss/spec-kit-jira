# Contract: The announcing comment body

**Feature**: `036-attach-feature-artifacts` | **Binds**: FR-004, FR-008,
FR-013, FR-022, Principle XVI

One comment per run that publishes anything. **Zero comments** when a run
publishes nothing. This file is the single source both ports copy: the literals
below are pinned, not composed from a shared helper, because a body assembled
differently in the two ports diverges in ways a conformance failure cannot
easily attribute — and because piping to a native command in PowerShell appends
a newline, which has silently diverged a stdin-fed digest in this codebase
before.

---

## B1. Shape

An ADF document built from the existing `sink/jira/adf.sh` / `Adf.psm1`
primitives. Two nodes:

1. one `paragraph`;
2. one `bulletList`, one `listItem` per published artifact, in the artifact
   set's sort order (by `path`, byte-wise).

No `media` node, no `inlineCard`, no link mark. The artifacts are reached
through the ticket's own attachment panel.

## B2. The paragraph

Exactly one of these two sentences, chosen by whether any artifact in this run
classified `revised`:

- all first publications:

  ```text
  Spec Kit published these feature artifacts after `<event>`. They are attached to this ticket.
  ```

- at least one revision:

  ```text
  Spec Kit published these feature artifacts after `<event>`. Revised files are attached again; earlier versions are kept.
  ```

`<event>` is the lifecycle event name verbatim — `after_plan`, `after_tasks`,
`after_converge`, … — rendered as ADF `code` marked text. It is never
translated, prettified, or abbreviated: it is the name the operator sees in
`extension.yml` and in `phase_status_map`.

## B3. The list items

One `listItem` per published artifact, each a single `paragraph`:

- first publication:

  ```text
  `<path>` — new
  ```

- revision:

  ```text
  `<path>` — revised
  ```

`<path>` is the path **relative to the feature directory**, `/`-separated on
every host, rendered as ADF `code` marked text. Never an absolute path — it
would leak the operator's home directory into a Jira comment and break byte
equivalence between ports and between machines.

The attachment name is **not** in the comment. For a top-level artifact it is
identical to the path and would be noise; for a nested one the reader finds it
in the attachment panel next to the file. Putting both in every line serves the
bookkeeping, not the reader.

## B4. Withheld artifacts are not in the comment

An artifact withheld for a name collision, for size, or by a site setting is
**absent** from the comment: the comment announces what a reader can now
download, and naming a file that is not there is worse than silence. Withheld
artifacts are reported in the **run summary**, where the operator — who can act
on them — will see them (FR-021).

---

## B5. Worked example

Feature directory holding `spec.md` (revised), `plan.md`, `research.md`,
`contracts/api.md`, `checklists/requirements.md` (unchanged, already published)
and `assets/demo.mov` (42 MB, oversized), published by `after_plan`:

> Spec Kit published these feature artifacts after `after_plan`. Revised files
> are attached again; earlier versions are kept.
>
> - `spec.md` — revised
> - `plan.md` — new
> - `research.md` — new
> - `contracts/api.md` — new

`checklists/requirements.md` is absent because it was unchanged; `assets/demo.mov`
is absent because it was withheld. Both appear in the run summary.

---

## B6. Equivalence assertions

The conformance corpus asserts, for the same feature directory:

| # | Assertion |
|---|-----------|
| B6.1 | The ADF document sent by both ports is **byte-identical**, including key order. |
| B6.2 | Exactly one `POST /issue/{key}/comment` per run that publishes; zero otherwise. |
| B6.3 | List item order equals the artifact set's sort order, identically on both ports. |
| B6.4 | No trailing newline is introduced into any string by either port's composition path. |

B6.4 is not paranoia: it is the measured PowerShell pipe-to-native behaviour,
which conformance caught only because a literal was pinned. Pin the literal.
