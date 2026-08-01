# Contract: The Parent Marker

The durable identifier by which a specification's parent artifact is recognised, written into the
specification file itself. This contract extends
[005's story-marker contract](../../005-fix-reconcile-idempotency/contracts/story-marker.md)
rather than replacing it: the framing comment, the identifier alphabet, the byte-preserving
splice, the line-ending rule and the atomic write are all inherited unchanged. What follows
records only what is new or different.

## Grammar

```text
marker      := "<!--" WS+ "speckit-jira" WS+ body WS* "-->"
body        := "spec=" id ( WS+ tail )?
id          := 16 lowercase hexadecimal characters
tail        := "creating" | "ticket=" issue-key
issue-key   := [A-Z][A-Z0-9_]*-[1-9][0-9]*
```

Written forms — exactly one space between tokens:

```markdown
<!-- speckit-jira spec=3f2a91c04b7e6d18 -->
<!-- speckit-jira spec=3f2a91c04b7e6d18 creating -->
<!-- speckit-jira spec=3f2a91c04b7e6d18 ticket=COMP-412 -->
```

## Non-collision with the story marker — normative

The two markers share the `<!-- speckit-jira … -->` frame and MUST remain mutually invisible.

- `story_marker_parse_line` MUST return `{"kind":"none"}` for any body that is not
  `story=<16 hex>[ tail]`. It does so today, by construction: the body is matched against
  `^story=([^\s]+)(\s+(.*))?$` and anything else falls through to `none`. This behaviour is now
  load-bearing and MUST be pinned by a test.
- `spec_marker_parse_line` MUST symmetrically return `{"kind":"none"}` for any body that is not
  `spec=<16 hex>[ tail]`.
- Consequently `_smk_section_has_marker` MUST NOT see a `spec=` line, and the parent-marker scan
  MUST NOT see a `story=` line.

**The case this protects.** A specification with an H1 and no `## User Story` headings anchors its
implicit single story on the H1 — the same line the parent marker is spliced under. If the parent
marker counted as a marker in that section, the implicit story would never be assigned an
identifier and would be silently dropped from every run. A regression test MUST cover exactly
this: H1, no user-story headings, a `spec=` marker present, and assignment must still insert a
`story=` marker.

**Forward compatibility falls out of the same property.** A bridge version predating this feature
reads a `spec=` line as an ordinary comment. It neither trips over it nor rewrites it.

## Placement

The parent marker is spliced on the line immediately after the document's first H1
(`^#\s`). When the document has no H1 it is spliced as the file's first line — the same
"anchor 0 means before line 1" convention `_smk_scan_anchors` already uses.

Exactly one parent marker per specification file. Two or more `spec=` lines anywhere in the file
is the `duplicate` state.

## Reading rules

1. A line matching the grammar is a marker. Everything else is content.
2. The marker line MUST be excluded from every extraction — title, description, success criteria,
   out-of-scope, acceptance criteria, design. `parse_spec` already strips marker lines before
   extraction (`_parse_strip_marker_lines`); that strip MUST cover `spec=` lines too.
3. A `speckit-jira`-framed line whose body starts `spec=` but does not match the grammar is
   `malformed`. It is never rewritten and never ignored: it blocks.
4. Whitespace inside the frame is tolerated on read and normalised on write.
5. Both CRLF and LF line endings are read; the file's dominant ending is preserved on write.

## States and transitions

| State | Meaning | Effect on the run |
| --- | --- | --- |
| `absent` | No marker | Assign one, then create the parent |
| `assigned` | Identifier recorded, no ticket yet | Create the parent |
| `creating` | A previous run was interrupted between the create request and the record | **Block the whole specification** |
| `bound` | Identifier recorded against an issue key | Read that key and verify |
| `malformed` | A `spec=` body that does not parse | **Block the whole specification** |
| `duplicate` | Two or more `spec=` lines | **Block the whole specification** |

```text
absent ──assign──▶ assigned ──plan a create──▶ creating ──create returns a key──▶ bound
                       ▲                                                            │
                       └──────────── the recorded key returns 404 ──────────────────┘
```

**A blocked parent blocks every story.** This is the one place the parent marker's rules diverge
from the story marker's, where "a blocked story never blocks its siblings". A parent has no
siblings, and FR-012 forbids creating a child without a verified parent.

## Writing rules

1. **Assignment** happens before any Jira call, in the same pass that assigns story identifiers.
   A dry run computes the assignment and does not write it, so it predicts the identifier a
   following real run would use.
2. **`creating`** is written in the same single splice that marks the stories, immediately after
   the privacy gate and before the first create.
3. **The recorded key** is written immediately after the parent's create response is read — per
   ticket, never batched. A run interrupted between the response and the record leaves the marker
   in `creating`, which the next run refuses rather than duplicating.
4. Every write is byte-preserving: only the marker line changes, and the file's mtime and
   `git status` are untouched when the bytes would be identical.
5. Every write is atomic: a temporary file in the same directory, renamed over the original.
6. An unwritable specification file fails closed **before** any Jira write. No parent may exist
   whose identifier was never recorded.

## Ordering within one run

```text
1. assign story identifiers        (existing)
2. assign the parent identifier    (new — same pass, same file, one splice)
3. derive the issue types          (sink)
4. gate on mandatory fields        (sink)
5. recognise the parent            (sink)  ── blocked ⇒ stop, zero writes
6. recognise the stories           (existing)
7. plan                            (parent + stories)
8. privacy gate over every payload (existing, one more payload)
9. mark parent + stories `creating` (one splice)
10. create/update the parent, stamp it, record its key
11. create/update each story with the parent's key, stamp it, record its key
```

Steps 3, 4 and 5 all precede step 8, so every refusal this feature adds happens before the first
byte is written.

## Diagnostics

Every message names the file, the line where relevant, and a copy-pasteable remedy. `<PATH>` is
the repository-relative path to the specification.

| Reason | Message |
| --- | --- |
| `parent-marker-malformed` | `<PATH> line N: malformed speckit-jira parent marker; nothing was written for this specification. Expected \`<!-- speckit-jira spec=<16 hex> ticket=<KEY> -->\`.` |
| `parent-marker-duplicate` | `<PATH> carries N speckit-jira parent markers (lines …); a specification has exactly one parent. Keep the line naming the parent that exists in Jira and delete the others.` |
| `parent-key-unrecorded` | `<PATH> marks its parent \`creating\`: a previous run was interrupted after creating the parent and before recording its key, so whether it exists cannot be determined. Find the issue carrying identifier <ID> in project <KEY> and record it as \`<!-- speckit-jira spec=<ID> ticket=<KEY> -->\`, or delete \`creating\` to mirror a new parent.` |
| `parent-claimed-by-other` | `<KEY> is recorded as the parent of <PATH> but its identity names specification <OTHER>; nothing was written. Correct the ticket= value, or clear it to create a new parent.` |
| `parent-identity-unverifiable` | `<KEY> is recorded as the parent of <PATH> but carries no spec-kit-jira parent identity; nothing was written. The bridge never adopts a ticket it did not create — clear the ticket= value to create a new parent, or restore the identity by hand.` |
| `parent-recreated` | *(a summary note, not a refusal)* `<KEY>, recorded as the parent of <PATH>, no longer exists in Jira; a new parent was created and the record updated.` |

## Exit codes

| Situation | Code |
| --- | --- |
| Marker malformed, duplicate, `creating`, claimed by another spec, unverifiable | `EXIT_CONFIG` (4) |
| Specification file unwritable | `EXIT_CONFIG` (4) |
| Parent read inconclusive (auth, network, exhausted retries) | the transport code, propagated unchanged |
| Payload blocked by the privacy guard | `EXIT_BLOCK` (9) |

Under `SPEC_KIT_JIRA_HOOK_CONTEXT` every one of these is emitted by `_reconcile_fault` as a single
`WARNING: … (exit N). This spec-kit command completed normally.` line and returns 0. No new code
implements that split.
