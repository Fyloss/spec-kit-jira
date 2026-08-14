# 8. The safety model

Everything in this document exists to answer one question: *how does an
automatic, unattended mirror avoid making a mess of a team's Jira?*

## The story marker — durable identity on disk

Immediately after each `### User Story` heading (or after the document title,
for a specification with no such headings), reconcile writes exactly one HTML
comment line:

```markdown
<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->
```

The identifier is 16 lowercase hex characters — 8 bytes of cryptographic
randomness — assigned **once** and never recomputed. It survives a retitle, a
reorder, and a specification-folder rename.

```mermaid
stateDiagram-v2
    [*] --> absent: a story with no marker at all
    absent --> assigned: story=ID — the identifier is spliced into spec.md
    assigned --> creating: story=ID creating — written BEFORE the POST
    creating --> bound: story=ID ticket=KEY — stamped immediately after the create
    bound --> bound: every later run recognises the ticket and updates or skips it

    creating --> key_unrecorded: the run died between the marker and the response
    key_unrecorded --> [*]: blocked, reported, never duplicated blindly

    assigned --> malformed: a valid identifier with an unreadable tail
    malformed --> [*]: blocked, reported

    note right of creating
        The creating state is the fail-closed window.
        A ticket may never exist for a story
        whose identifier was never recorded.
    end note
```

Two ordering rules make this safe:

1. **Assignment is written before any Jira write.** If `spec.md` cannot be
   written, the run fails closed with zero Jira writes — no ticket may exist for
   a story whose identifier was never recorded.
2. **Each created key is stamped and recorded immediately, per ticket — never
   batched.** A run interrupted after three creations has three recorded keys.

A dry run computes the *same* assignment and never writes it, so the dry-run
report predicts the exact identifiers a following real run would use.

## Recognition — reading the ticket back before deciding anything

Recognition reads each recorded ticket **by key**, never by search: Jira's
search index is eventually consistent, and that consistency window is exactly
where the original duplicate-ticket defect lived.

```mermaid
flowchart TD
    Story["A story with a marker"] --> Read["GET the recorded key,<br/>folding in the identity property"]

    Read -->|"transport failure"| Closed(["FAIL CLOSED for the WHOLE specification<br/>a read failure is NEVER downgraded to 'no ticket exists'"])
    Read -->|"404"| Gone["The ticket no longer exists — not a failure<br/>the story is treated as new"]
    Read -->|"200"| Marker{"Identity marker"}

    Marker -->|"matches this spec and this story"| Bound(["BOUND — update, or skip if nothing changed"])
    Marker -->|"names another specification"| Claimed(["BLOCKED — claimed-by-other"])
    Marker -->|"names another story id"| Orphan(["BLOCKED — orphan"])
    Marker -->|"missing or mismatched"| Mismatch(["BLOCKED — marker-mismatch"])

    Story -->|"two stories record the same key or id"| Dup(["BLOCKED — duplicate-claim"])
    Story -->|"key belongs to a project this spec no longer routes to"| Reroute["RE-ROUTED — mirror into the routed project,<br/>leave the former ticket untouched, report it"]
```

The asymmetry is deliberate:

- An **inconclusive read** fails the whole specification closed. Guessing here
  would create a duplicate of every ticket.
- A **marker problem** blocks only the story it names. A blocked story is
  excluded from the write plan; its siblings reconcile normally and it never
  blocks them.

Nothing is ever moved or deleted on a re-route. The former ticket is left
exactly as it was, and the run summary says so in prose.

## Idempotency — zero churn, by construction

```mermaid
flowchart LR
    Desired["Desired field set"] --> Cmp{"Deep structural comparison<br/>key-order independent"}
    Current["The ticket's current fields"] --> Cmp
    Cmp -->|"every desired key already equal"| Drop(["Drop the action — it never reaches Jira"])
    Cmp -->|"any difference"| Keep(["Keep the write"])

    Splice["Managed-section splice result"] --> Cmp2{"Byte comparison against the host"}
    Host["Current host bytes"] --> Cmp2
    Cmp2 -->|"identical"| Drop
    Cmp2 -->|"different"| Keep
```

A re-run against an unchanged corpus must produce **zero** writes of every
kind: 0 created, 0 updated, 0 transitioned, 0 commented, 0 linked, 0 labeled.
The dropped-as-no-op count surfaces as `skipped` in the run summary. Identity
never keys on a mutable field — a title, a summary, or any operator-editable
display name — only on a server-side entity property and the on-disk marker.

## Ownership — what the mirror writes, and what it never touches (018)

A description is not one field the mirror owns outright; it is two regions
separated by a single boundary marker. Everything below the marker — the
story body, the acceptance panel, the Design section, and a `plan.md` section
when one exists — is the mirror's own content, rewritten in full on every
update. Everything above it is never the mirror's to change: a human's prose
pasted directly into the tracker is preserved byte-for-byte, forever, on
every reconcile that follows.

The same rule protects a summary. The mirror keeps its own record of the
title it last sent, in the identity property — never in the summary field
itself, which is operator-editable and therefore never a place identity can
live (Constitution II). A summary that no longer matches that record is a
human's rename, not drift to correct: it is left alone by default and
reported, and it is only overwritten when an operator explicitly asks for it
with `--on-drift=proceed`.

A ticket a previous release wrote — no marker yet — is not an exception to
either rule. It gains the boundary on its next ordinary write, and the same
loss guarantee applies to the transition itself: nothing the mirror cannot
positively identify as its own former output is ever discarded, even when
that means the mirror's own prior output ends up preserved twice, above a
fresh boundary, with a warning naming the ticket.

## Drift — never silently overwriting Jira-side progress

Drift classification is pure engine code: zero Jira reads, zero writes. It
takes the ticket's current status, that status's category, the disk-inferred
target status, the operator's phase-ordered status sequence, and the
`--on-drift` mode, and returns one decision.

```mermaid
flowchart TD
    Start["A recognised ticket"] --> Cat{"Status category"}

    Cat -->|"halted — an operator-designated hold"| Halt["HALT<br/>all writes to this ticket stop<br/>two remediations offered: archive the spec, or reopen the ticket"]
    Cat -->|"unknown — not in any declared map"| With1["WITHHOLD the transition<br/>name the drift, suggest classifying the status<br/>content still reconciles"]
    Cat -->|"post-scope — Jira's own done category"| Post{"Did the disk phase regress?"}
    Cat -->|"mapped — a declared phase target"| Mapped{"Has the ticket advanced<br/>beyond the target Jira-side?"}

    Post -->|"no"| Trans["TRANSITION<br/>the move itself is resolved by sink/jira/transitions.sh (023)<br/>against the ticket's real available moves, never guessed"]
    Post -->|"yes"| Abort["Backward transition aborts by default<br/>requires --on-drift=proceed"]

    Mapped -->|"yes"| With2["WITHHOLD and warn<br/>--on-drift=proceed pulls it back"]
    Mapped -->|"no"| Trans

    Flagged["The Jira Flagged field is set"] --> HaltLike["Treated like a halted ticket:<br/>surfaced, write withheld, the flag itself never touched"]
```

Three decisions, and what each means for content:

| Decision | Transition | Content writes |
|---|---|---|
| `transition` | emitted | yes |
| `withhold` | suppressed | **yes** — a withheld transition is not a suppressed update |
| `halt` | suppressed | **no** — the orphaned spec is surfaced for a human |

`transition | emitted` becomes true at the specification and story tiers for
the first time in 023 — every earlier release reached this decision but
issued no request for it there (only the task tier's own, unrelated,
category-based done/not-done transition ever moved anything). 023's own
resolution is a separate rule (`transitions.sh`'s `transitions_resolve`,
contracts/transition-resolution.md): the declared step is matched against
the ticket's actual available moves by destination NAME, and a move is
issued only when exactly one candidate lands on it — ambiguous, gated, and
unreachable candidates each withhold instead, with their own named warning,
never inventing a preference.

None of this machinery has a default table. `phase_status_map` and
`halted_statuses` are optional, hand-edited keys under a project entry in
`config.yml`: an operator's configured workflow is authoritative, and omitting
both keeps drift evaluation completely inert.

## The privacy guard — two tiers, precision over recall

Every content payload is scanned **before** any write. This is not a filter
applied to output; it is a gate placed in front of the write path.

```mermaid
flowchart TD
    Payload["Action body"] --> Allow{"Covered by the allowlist?<br/>.extensionignore entries + config privacy.allowlist"}
    Allow -->|"yes, this exact match"| Silent(["Neither a block NOR a warn"])
    Allow -->|"no"| Tier{"What shape matched?"}

    Tier -->|"ATATT token prefix"| Block
    Tier -->|"a real *.atlassian.net host"| Block
    Tier -->|"a known site or project coordinate"| Block
    Tier -->|"email address"| Warn
    Tier -->|"UUID"| Warn

    Block["BLOCK — exit 9, ZERO writes<br/>the whole apply aborts<br/>the offending value is NEVER echoed"]
    Warn["WARN — surfaced, never gating"]
```

The tiering is a design decision with a history: the original extension raised
BLOCK-tier false positives on ordinary Confluence links, and **a blocking
control with false positives ends up disabled**. So low-confidence shapes only
warn, and the allowlist exemption is evaluated **per match** — the payload is
never rewritten, so a broad or overlapping allowlist entry can only neutralise
the exact text it covers and can never disable detection of unrelated tokens.

**The scan is narrowed to what the mirror composes (018, research R4).** A
description's preserved human prefix is real content read back from Jira and
written to that same ticket — Jira → Jira, never repository → Jira — so it
cannot leak a coordinate the destination does not already hold. Scanning it
anyway is a false-positive generator by construction: a human linking one
Jira ticket from another, an entirely ordinary thing to do, would otherwise
block every future run until the link is deleted by hand. The guard's own
directional concern (Constitution IV: no tracked-repository coordinate may
leak outward) is unaffected — every field the mirror composes is still
scanned exactly as before, and only the verbatim preserved prefix is exempt,
and only because it is verbatim.

## Exit codes — monotonically escalating

```mermaid
flowchart LR
    E0["0<br/>success, inert run,<br/>or reported degraded state"]
    E1["1<br/>usage — a missing or unreadable<br/>argument, OR a rejected target (017):<br/>two causes, one code; the message<br/>distinguishes them, not the code"]
    E2["2<br/>fail-closed read<br/>Jira unreachable"]
    E3["3<br/>auth rejected"]
    E4["4<br/>config refusal"]
    E5["5<br/>prerequisite missing"]
    E9["9<br/>privacy BLOCK"]

    E0 --> E1 --> E2 --> E3 --> E4 --> E5 --> E9
```

The table lives in one place (`lib/cli.sh` and its PowerShell twin) and is
asserted byte-identically across ports. A more severe failure never maps to a
lower code.

**And none of these ever becomes the host command's exit code.** Inside a hook,
a non-zero result is downgraded to `0` after a single actionable `WARNING`:

```mermaid
sequenceDiagram
    participant Host as Spec Kit command
    participant Bridge as reconcile
    participant Jira

    Host->>Bridge: after_plan fires
    Bridge->>Jira: read
    Jira--xBridge: 401
    Bridge->>Bridge: map to exit 3, zero writes
    Bridge-->>Host: WARNING: Jira mirror not completed — Jira rejected the credentials (exit 3).<br/>This spec-kit command completed normally.
    Note over Bridge,Host: returned exit code: 0
    Host-->>Host: /speckit.plan completes normally
```

## Dry run — a prediction, not an approximation

Every write operation has a `--dry-run` whose report predicts **exactly** the
actions of the real run. The lifecycle filtering, the zero-churn dropping, and
the identifier assignment all run identically in both modes; only the HTTP
calls and the on-disk marker write are suppressed. A test for each write
operation runs `--dry-run` and then the real run against the same state and
asserts the two action sets are identical.
