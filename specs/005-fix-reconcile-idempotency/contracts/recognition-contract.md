# Contract: Recognition

What the recognition step reads, what it decides, what it returns, and every
diagnostic it can emit. This is the contract the reconcile command layer honours
and the conformance suite asserts on, on both ports.

---

## Position in the run

```text
parse spec.md
  └─▶ 1. ASSIGN     identifiers for stories without one → write spec.md   (no Jira contact)
      2. RECOGNISE  one read per recorded key → verify marker            (reads only)
      3. PLAN       plan_writes + plan_lifecycle → privacy guard         (no writes yet)
      4. FLAG       mark every planned creation `creating` in spec.md    (one splice)
      5. APPLY      creates and updates
      6. RECORD     stamp marker on each created ticket → replace `creating`
                    with its key in spec.md, per ticket
```

Step 1 before step 5 is what makes a ticket-without-a-recorded-identifier impossible
(spec FR-012). Step 6's stamp before its record is what makes a recorded key always
verifiable (research R5). Step 4 sits *after* the privacy guard deliberately: a guard
BLOCK, a rejected credential, or any other failure before step 5 leaves every story at a
plain `story=<id>`, which the next run creates normally. Only the narrow window between
the first create response and its recorded key leaves a story `creating`.

## Inputs

| Input | Source | Notes |
| --- | --- | --- |
| Stories with markers | `parse_spec` | `local_id` empty ⇒ unassigned |
| `spec_ref` | `{repo, spec_slug, folder}` | already built by `cmd_reconcile` |
| Project key | routing resolution (004) | scopes recognition (FR-019) |
| Base URL, credentials | environment / binding | existing transport |
| Lifecycle event | `_reconcile_hook_event` | supplies `target`; empty outside a hook |

## The read

One request per story carrying a recorded key:

```http
GET /rest/api/3/issue/{key}?properties=spec-kit-jira&fields=summary,description,priority,status,issuelinks,{flagged_field_id}
```

Immediately consistent — no search index is involved (research R2). `404` is a normal
outcome, not a failure. Every other non-2xx maps through the existing table and fails the
run closed with zero writes.

| Transport outcome | Exit | Recognition result |
| --- | --- | --- |
| 2xx | — | ticket state built, marker verified below |
| 404 | — | ticket gone: story returns to `assigned`, re-created, summary notes it |
| 401 / 403 | 3 | **zero writes for the whole specification** |
| 429 exhausted / 5xx / network | 2 | **zero writes for the whole specification** |

A read failure is never downgraded to "no existing ticket". That downgrade is the
defect (FR-004).

## Marker verification — decision table

Applied per story, against the marker returned with the ticket. `S` is the story's
recorded identifier; `R` is the run's repo.

**Implementation note (Phase 5, US3 durability audit):** `claimed-by-other` keys on
`repo` alone, not `repo` **and** `spec_slug`. `spec_slug` defaults to the specification
folder's basename, which a rename changes (quickstart Step 6); gating on it would make
`claimed-by-other` fire on every renamed specification's own tickets, failing FR-017/
FR-018. The durable `story` identifier — unique per specification by construction (16
random hex characters) — is what protects against cross-specification collision, and it
does so without breaking on a rename.

| Marker state | Decision | Effect |
| --- | --- | --- |
| `repo=R`, `story=S` | **bound** | update or skip as unchanged |
| `story` present but ≠ `S` | **blocked** — `marker-mismatch` | zero writes for this story, warning |
| `story` present, ≠ `S`, and matching no story of the specification | **blocked** — `orphan` | zero writes for this story, ticket left untouched, warning |
| `repo` names another repository | **blocked** — `claimed-by-other` | zero writes for this story, warning (FR-021) |
| Recorded key belongs to a project other than the routed one | **new** — `re-routed` | former ticket untouched, story mirrored into the routed project, notice (FR-019) |
| `story` absent (feature-ceremony or mentioned ticket) | **blocked** — `marker-mismatch` | zero writes for this story, warning |
| No marker at all on the ticket | **blocked** — `marker-mismatch` | zero writes for this story, warning |
| Two stories recording one identifier | **blocked** — `duplicate-claim`, both stories | zero writes for both, one warning naming both |
| Two recorded keys resolving to one ticket | **blocked** — `duplicate-claim`, both stories | zero writes for both, one warning naming both |
| `story=<id>` alone, no ticket read to verify | **new** | created in this run, key recorded at step 6 |
| `story=<id> creating` | **blocked** — `key-unrecorded` | zero writes for this story, warning (research R8) |

A ticket whose marker is absent is deliberately **not** adopted. The bridge never guesses
that a ticket a human pointed it at is the right one; adoption is the opt-in, label-gated
flow of Constitution I and this feature does not widen it.

**A blocked story never blocks its siblings.** The rest of the specification plans and
applies normally, and the run's exit code is unaffected by a block — the warning carries
it (FR-011, FR-016).

## Output

```jsonc
{
  "bound":   { "<identifier>": { "key", "origin", "current", "status", "category", "flagged", "blockers" } },
  "new":     [ "<identifier>", … ],
  "blocked": [ { "story": "<identifier>", "reason": "<reason>", "detail": "<human text>" }, … ]
}
```

Consumed as: `bound` → the plan context's three maps and the lifecycle context's
`tickets`; `new` → creations; `blocked` → excluded from the document handed to
`plan_writes`, and one warning each.

## Diagnostics catalogue

Every message names the story, the file or ticket, and a copy-pasteable remedy
(Constitution XVI). None contains the site host, a token, or an account id
(Constitution IV). `<spec>` is the repository-relative path to `spec.md`.

| Reason | Message |
| --- | --- |
| `key-unrecorded` | `Story <id> in <spec> is marked \`creating\`: a previous run was interrupted after creating its ticket and before recording the key, so whether a ticket exists cannot be determined. Check the project for a ticket carrying that identifier and record it as \`<!-- speckit-jira story=<id> ticket=<KEY> -->\`, or replace \`creating\` with nothing to mirror the story as a new ticket.` |
| `marker-mismatch` | `Ticket <KEY> recorded for story <id> in <spec> does not carry that story's identity marker; nothing was written to it. Correct the ticket= value in <spec>, or delete the marker line to mirror the story as a new ticket.` |
| `claimed-by-other` | `Ticket <KEY> recorded for story <id> in <spec> is claimed by specification <other-slug>; nothing was written to it. Correct the ticket= value in <spec>, or reconcile that specification instead.` |
| `duplicate-claim` | `Story identifier <id> appears on <n> user stories in <spec> (lines <l1>, <l2>); nothing was written for any of them. Give each story its own marker line, or delete the duplicates to have them mirrored as new tickets.` |
| `re-routed` | `Story <id> in <spec> was previously mirrored as <KEY> in project <OLD>, which is no longer the project this specification routes to; <KEY> was left untouched and the story was mirrored into <NEW> as <NEWKEY>. Nothing was moved or deleted.` |
| ticket gone | `Ticket <KEY> recorded for story <id> in <spec> no longer exists in Jira; the story was mirrored again as <NEWKEY> and <spec> was updated.` |
| orphan | `Ticket <KEY> recorded in <spec> carries story identifier <id>, which no user story in <spec> claims; nothing was written to it. Restore <id> as that story's identifier with \`<!-- speckit-jira story=<id> ticket=<KEY> -->\`, or delete the marker line to mirror the story as a new ticket and close <KEY> in Jira.` |
| marker malformed | `<spec> line <n>: malformed speckit-jira marker; nothing was written for that story. Expected \`<!-- speckit-jira story=<16 hex> ticket=<KEY> -->\`.` |

## Exit codes

Unchanged and monotonic (Constitution III). Recognition adds no new code.

| Code | Cause reachable from recognition |
| --- | --- |
| `0` | success, including any number of blocked stories (their warnings carry them) |
| `2` | a ticket read failed closed — network, 5xx, exhausted 429 |
| `3` | Jira rejected the credentials during a ticket read |
| `4` | `spec.md` could not be written, so no ticket may be created (FR-012) |
| `9` | the privacy guard blocked a payload — unchanged, still before every write |

In hook context every one of these is downgraded to `0` after a single warning, by the
existing `SPEC_KIT_JIRA_HOOK_CONTEXT` path (FR-022).

## Run summary additions

```jsonc
"counts": { "recognised": 3, "assigned": 0, "created": 0, "updated": 0, "skipped": 3, "warnings": 0, "errors": 0 }
```

The unchanged-re-run signature is `created: 0, updated: 0` with `recognised` equal to the
story count and `skipped` equal to it as well. That line is what SC-001 asserts.

## Dry run

`--dry-run` performs steps 1 and 2 as **reads only**: it recognises, it reports the
identifiers it *would* assign, and it writes neither `spec.md` nor Jira. The predicted
action set equals the real run's for every scenario in the specification (FR-016).

One consequence worth stating: a dry run against a specification with unassigned stories
predicts creations for them, and a subsequent real run assigns identifiers and performs
exactly those creations. The two action sets match; only the identifiers differ, because
they are generated at assignment time.
