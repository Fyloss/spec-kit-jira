# Phase 1 — Data model

**Feature**: 029 | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

This feature persists nothing. Every entity below lives for the duration of one
invocation and is either returned to the caller or discarded. That is a design
constraint (FR-004, FR-030), not an accident of scale: a persisted answer would
resurface on an unrelated later run, and a persisted question would need a recovery
path that this feature exists to make unnecessary.

---

## Mention

What the operator named, as recognised from the leading positional.

| Field | Values | Notes |
| --- | --- | --- |
| `form` | `key` · `url` · `absent` | of the **leading** positional; `absent` is the ordinary case and suppresses everything in this feature |
| `raw` | the leading positional verbatim | used for reduction only; messages carry `key`, never `raw` |
| `key` | reduced issue key | for `url`, the result of the designator grammar's reduction; for `key`, the value itself |
| `others` | every further positional reducing to a key, in argv order | detected **only** when `form` is not `absent` (FR-034) |

**Validation**: the leading positional is a gate, not a limit. It either reduces to a
key shape — in which case every further positional is examined too — or the mention is
`absent` and nothing else is looked at
([contracts/mention-grammar.md](./contracts/mention-grammar.md)). There is no partial
state.

**`key` alone computes the name.** `others` can change no slug, no branch and no folder
short name, so reordering a request's words cannot rename its branch. That is the
structural half of what makes detecting more than one issue safe; the other half is that
detection only ever *proposes*.

---

## Resolved issue facts

What the single mentioned-key read returns, and therefore everything the question is
allowed to say about the issue.

| Field | Narrow read (every non-asking path) | Wide read (the question path) |
| --- | --- | --- |
| `key` | ✔ | ✔ |
| `project` | ✔ | ✔ |
| `summary` | — | ✔ |
| `type` | — | ✔ |
| `status` | — | ✔ |

**One request either way.** The field set is chosen from argv and the loaded
configuration before the read, never after (FR-017,
[contracts/feature-question-contract.md §7](./contracts/feature-question-contract.md)).
`project` keeps its position and meaning in both shapes, so the cross-team decision
that consumes it is untouched.

**Lifecycle**: read once — one request for all detected issues — held for the duration
of the invocation, never persisted. `status` is compared against the routed project's
configured halted list to decide whether the question carries the FR-033 warning;
nothing else interprets it.

---

## Proposed placement

What the question offers for one detected issue. Derived, never read: computed by
matching the issue's `type` against the routed project's declared hierarchy, which the
run has already loaded.

| Value of `role` | When | Question says |
| --- | --- | --- |
| `specification` | type equals the declared specification type | attach as the Epic of this specification |
| `story` | type equals the declared story type | attach as a Story beneath it |
| `story`, with `unmapped: true` | type matches **neither** role | proposed as a Story, type named as declared for no role, needs no parent (FR-036) |
| — refuses instead | type equals the **other** role's declared type | misplaced, not unmapped: refuses at the question (FR-022) |
| `null` | the project declares no hierarchy | no placement proposed; the question asks for explicit designators (FR-035) |

**The distinction between the third and fourth rows is the whole of FR-036.** They look
identical from inside `adoption_evaluate`, which emits one `REF-ROLE` for both, and they
must not share an outcome: one is an operator's mix-up, the other is a type the
configuration never mapped.

**Validation**: a proposal binds nothing. It is confirmed by the answer, overridden
issue by issue by an explicit designator, or discarded whole by declining.

**Lifecycle**: computed once, at the top of the command, before any configuration is
read. It is the only entity that exists before the four early exits.

---

## Reuse answer

The operator's response, supplied as `--reuse <yes|no>`.

| State | Meaning | Effect |
| --- | --- | --- |
| absent | not yet asked, or asked and unanswered | the question is returned |
| `no` | create new issues alongside the mentioned ticket | today's path, byte for byte |
| `yes` | reuse existing issues | designators expected; their absence returns the follow-up question |
| anything else | — | usage error naming both accepted values (FR-016) |

**Validation**: an answer supplied with no mention is a usage error (FR-015), not a
silent no-op — a mis-scripted invocation must be visible.

**Lifecycle**: an input, never an output. It is not recorded, so two answered
invocations are independent runs and neither can observe the other's answer.

---

## Pending question

What the command returns instead of a name. Two variants, one shape.

| Field | Reuse variant | Which-issues variant |
| --- | --- | --- |
| payload key | `reuse_required` | `reuse_issues_required` |
| trigger | mention resolved, no designator, no answer | answer `yes`, no designator |
| identifies | the mentioned issue: key, summary, type, status | the same issue, plus what is still missing |
| answers offered | reuse · create new | the designators to supply |
| halted warning | present iff the status is in the configured halted list (FR-033) | same |
| further issues | one additional line per issue detected beyond the leading positional (FR-034) | same |
| drafted note | present iff at least one issue is proposed in the story role (FR-040) | same |
| branch name | **omitted** | **omitted** |
| folder short name | **omitted** | **omitted** |

**The omission is the entity's most important field.** It is what makes the question
unskippable: a caller with no name cannot create the branch or the spec folder, so
answering stops depending on the caller's diligence (FR-031). Every other guarantee
in this feature assumes a caller that follows instructions; this one holds when it
does not. The omission is total — the keys are absent, never present holding `null`,
which a careless caller could read as "compute it yourself".

**Each question is its own key**, never a shared one with a type field: the shipped
cross-team question keeps `confirmation_required` untouched, because a discriminator
added inside it would change that question's own bytes and break the scenario that
proves it unchanged ([contracts/feature-question-contract.md §3.1](./contracts/feature-question-contract.md)).

**Lifecycle**: returned, never stored. Repeating the same incomplete input returns
the same question and accumulates nothing.

---

## Configuration gap

Why no team applies, and therefore what to tell an operator who named a ticket.

| Variant | Detected at | Names | Remediation |
| --- | --- | --- | --- |
| catalogue absent, unreadable, or empty | the first three early exits | `.specify/jira/config.yml` | run the configuration command |
| no selection | the fourth early exit | `.specify/jira/personal.yml` | choose a team; the file is the operator's own and no script writes it |

**Validation**: reported **only** when a mention is present. With no mention, all
four exits keep today's exact output — this is the boundary that protects every
repository not using the extension (FR-028).

---

## What is deliberately absent

- **No seed record.** That belongs to 027 and is written only once designators
  exist.
- **No run state.** Nothing here survives the invocation.
- **No configuration key.** The trigger is the mention; the spec records why an
  opt-in key was rejected.
