# Contract: The Story Marker Line

The one durable artifact this feature writes into a user-owned file. Its grammar,
its placement, the rules for reading it, and the rules for writing it. Both ports
implement this contract identically; the conformance suite asserts byte equality of
the resulting `spec.md`.

---

## Grammar

```ebnf
marker      = "<!--" WS "speckit-jira" WS "story=" identifier
              [ WS ( "ticket=" issuekey | "creating" ) ] WS "-->"
identifier  = 16 * ( "0".."9" | "a".."f" )
issuekey    = uppercase-alpha , { uppercase-alpha | digit | "_" } , "-" , nonzero-digit , { digit }
WS          = 1 * " "
```

Exactly one space between tokens when the bridge writes the line. When reading, one or
more spaces are accepted so a reformatting editor does not orphan a ticket.

**Valid**

```markdown
<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->
<!-- speckit-jira story=7f3a9c1e40b2d85a -->
<!-- speckit-jira story=7f3a9c1e40b2d85a creating -->
```

The three forms are three states, and the difference between the first two is what keeps
an interrupted run from either duplicating a ticket or deadlocking a story:

| Form | Meaning | What the next run does |
| --- | --- | --- |
| `story=<id>` | assigned, no creation has ever been attempted | creates the ticket |
| `story=<id> creating` | a creation was attempted, its outcome is unknown | fails closed, `key-unrecorded` |
| `story=<id> ticket=<KEY>` | bound | recognises it, then updates or skips |

**Not a marker** — ignored entirely, the story reads as unassigned:

```markdown
<!-- speckit-jira story=NOTHEX -->            identifier fails the shape
<!-- speckit_jira story=7f3a9c1e40b2d85a -->  wrong prefix
<!-- speckit-jira ticket=PROJ-142 -->         no identifier to bind
```

**Malformed** — the story is *blocked*, not treated as unassigned, because silently
re-creating its ticket is the defect this feature removes:

```markdown
<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=proj-142 -->   key fails the shape
<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-0 -->     key fails the shape
```

## Placement

| Specification shape | Marker goes |
| --- | --- |
| Has `^#{2,4}\s+User Story` headings | On the line immediately following each story's heading line |
| Has no such heading (the implicit single story) | On the line immediately following the document's first H1 |
| Has neither heading nor H1 | On the first line of the file |

One marker per story. A story section containing two or more marker lines is malformed
(blocked, warning names every line number, as `managed_section_splice` already does for
the README block).

A marker line found anywhere other than its story's first line after the heading is read
normally — position is not part of identity — but the bridge rewrites nothing to move it.

## Reading rules — parser (`engine/parse.sh`, `Parse.psm1`)

1. `parse_spec` associates each marker with the story section it falls inside; a marker
   before the first story heading belongs to the implicit-story case only.
2. **The marker line is excluded from every content extraction.** `parse_title`,
   `parse_description_blocks`, `parse_acceptance_criteria`, `parse_design`,
   `parse_priority`, and `parse_estimation` all skip it. Without this the comment lands
   in the Jira description of every ticket — `parse_description_blocks` treats any
   non-empty, non-heading line as prose.
3. `stories[].local_id` is the marker's identifier when present, and empty when absent.
   An empty `local_id` never reaches the interchange schema: assignment fills it first.
4. Reading is total — no input is a parse failure. Every malformed case produces a
   blocked story and a warning, never a non-zero exit from the parser.

## Writing rules — splice (`engine/story_marker.sh`, `StoryMarker.psm1`)

The engine module is generic in the same way `managed_section.sh` is: it receives
already-formatted marker lines as parameters and knows nothing about Jira.

1. **Byte preservation.** Every byte outside the marker lines is preserved exactly:
   surrounding prose, blank lines, indentation, trailing whitespace, and a missing final
   newline.
2. **Line endings.** A written or rewritten marker line adopts the file's dominant line
   ending, decided by the existing `managed_section_line_ending` (CRLF if the file has
   more CRLF than bare-LF terminators, else LF). The file never becomes mixed-ending.
3. **Idempotence.** If every marker line the run would write already reads exactly as it
   would be written, the file is **not opened for writing at all**. Not "written with
   identical content" — not written, so the mtime is untouched and `git status` stays
   clean.
4. **Insert vs replace.** A story with no marker gets one inserted on the line after its
   heading. A story whose marker exists is replaced in place, keeping its column position
   at the start of the line.
5. **Atomicity.** The file is written through a temporary file in the same directory and
   renamed over the original, so an interrupted write can never leave a truncated
   `spec.md`.
6. **Refusal.** A malformed marker configuration produces a located error and zero
   output, and the run makes no Jira write for the affected stories.

## Interaction with the specification's own lifecycle

- `/speckit-specify` regenerating a `spec.md` from the template discards markers along
  with everything else; the stories then read as unassigned and are mirrored as new
  tickets. The previous tickets are not surfaced — no marker line names them any more,
  so nothing reads them. They are left intact in Jira for a human to close. This is the
  documented consequence of rewriting a specification, not a defect.
- Editing a story's title, priority, prose, or acceptance criteria never touches its
  marker.
- A merge conflict on a marker line is resolved like any other line; two stories left
  with one identifier are caught by the duplicate-claim rule and fail closed.

## Worked example

Before the first run:

```markdown
### User Story 1 - A second run creates no duplicates (Priority: P1)

As a developer …
```

After the first run:

```markdown
### User Story 1 - A second run creates no duplicates (Priority: P1)
<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->

As a developer …
```

After the story is retitled and moved below another story: the marker travels with it,
byte-identical, and the ticket is recognised and updated — never re-created.
