# Contract — The pinning marker and its validation

**Feature**: 027 | **Module**: `engine/pin_marker.sh` · `engine/PinMarker.psm1`

Extends the story-marker contract of 005 and the parent-marker contract of 008
rather than replacing either. The framing comment, the byte-preserving splice,
the line-ending rule and the atomic write are inherited unchanged from
`marker_splice.sh`.

---

## §1 Placement — why the engine

This module handles an **opaque** ticket string, exactly as `story_marker.sh`
does with `ticket=`. It never validates a key's shape — that is
`sink/jira/designator.sh`'s job, upstream — so it carries no tracker vocabulary
and stays clean under Constitution VIII's boundary grep.

---

## §2 Written form

```
<!-- speckit-jira pin=KEY -->
```

Exactly one space between tokens, matching `story_marker_format`'s "written"
form. No durable identifier. No state token — a pinning marker has one state.

## §3 Grammar and non-collision

`pin_marker_parse_line <line>` returns canonical JSON:

| Result | Input |
| --- | --- |
| `{"kind":"none"}` | not a marker, **or** a `story=` body, **or** a `spec=` body, **or** a `task=` body |
| `{"kind":"valid","key":"…"}` | `pin=<non-empty, no whitespace>` |
| `{"kind":"malformed"}` | `pin=` with an empty or unrecognisable tail |

Reciprocally, `story_marker_parse_line`, `spec_marker_parse_line`, and
`task_marker_parse_line` MUST each return `none` for a `pin=` body. The four
bodies form a closed, mutually non-matching set — the discipline
`spec_marker.sh` already documents for `story=`.

## §4 Placement rule

One marker at most per user story, immediately after its heading — the position
`_smk_scan_anchors` already computes: `^#{2,4}\s+User Story`, falling back to the
document's first H1, falling back to "before line 1".

A user story with no named counterpart carries no marker (FR-018). That absence
is the definition of the create set, not a defect.

---

## §5 The validation (FR-058)

`pin_marker_validate <spec-path> <ordered-designator-keys>` reads **the pinning
markers and nothing else**: not headings, not titles, not prose, not section
order except as given by the markers' relative positions.

Four properties, all four checked, all four reported together:

| # | Property | Violation |
| --- | --- | --- |
| P1 | Every designated story-role key carries exactly one marker | key dropped |
| P2 | Every marker names a designated story-role key | orphan marker |
| P3 | No key appears in two markers; no user story carries two markers | split / merge |
| P4 | Markers appear in the same relative order as the designator order | reorder |

Output is canonical JSON listing every violation with its key and line number —
never a bare pass/fail, because FR-019 and FR-035 require the message to name
what went wrong and how to fix it.

### One pass, no per-key spawn

The implementation collects marker lines and line numbers in a **single pass**
over the file, then compares against the designator array in memory (research
R10). One grep per key is forbidden by `docs/11-process-budget.md`.

### Two callers, two refusal classes

The same validation, the same four properties, two different classes because the
cause and the remediation differ:

| Caller | Class | Remediation |
| --- | --- | --- |
| First run, on the file as drafted | `REF-DECOMP` | Accept the human decomposition, or re-invoke with a different designator set |
| Resume, on the file as it now stands (FR-063) | `REF-DRAFT-EDIT` | Restore the named marker to its position, or start over |

An edit that leaves all four properties intact passes silently — rewriting prose,
adding scenarios, renaming a heading, adding a whole new unpinned user story
(FR-018). This is the line C5 asked for, and §5 is where it is drawn: the
validation cannot see prose, so prose cannot break it.

---

## §6 Consumption at binding (FR-057)

After the confirmation gate, for each bound story the script replaces the pinning
marker **in place** with the story marker:

```
<!-- speckit-jira pin=PROJ-142 -->
        ↓ (one line-replacement via marker_splice.sh)
<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->
```

Ordering is the existing fail-closed one (FR-028, `docs/08-safety-model.md`): the
identifier is written to disk **before** the Jira write, and each key is stamped
and recorded immediately, per ticket, never batched.

Consequence: pinning markers and identity markers never coexist. A specification
carrying pins and no identity is seeded-not-bound; one carrying identity and no
pins is bound.

---

## §7 Windows

Inherited from `marker_splice.sh` unchanged: the line-ending of the replaced line
is preserved, the write is atomic, and no glob pattern in this module contains
`$'\r\n'`. Multi-line output goes through `lib/output.sh`.

---

## §8 Test obligations

| # | Assertion | Requirement |
| --- | --- | --- |
| P-1 | `pin=` parses as `none` in the story, spec, and task parsers, and vice versa | §3 |
| P-2 | Marker spliced at the anchor for `###`, `##`, `####` headings and the H1 fallback | §4 |
| P-3 | Each of P1–P4 fails independently, with the offending key and line named | FR-019, FR-058 |
| P-4 | All four violations at once are reported together, not one at a time | FR-019 |
| P-5 | Prose rewrite, scenario addition, heading rename, new unpinned story → all pass | FR-063 |
| P-6 | Deleted pinned story / duplicated marker / moved marker → `REF-DRAFT-EDIT` on resume, `REF-DECOMP` on first run | FR-019, FR-063 |
| P-7 | Consumption replaces in place, preserving every other byte and the line ending | FR-057 |
| P-8 | Interrupted consumption leaves exactly the completed replacements | FR-028 |
| P-9 | Validation of 100 markers spawns no process per marker | R10 |
