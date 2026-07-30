# Phase 0 Research: Reconcile Recognises the Tickets It Already Created

Nine decisions this design rests on. Each records what was chosen, why, and what
was rejected. R2 and R3 are the two findings that shape everything else.

---

## R1 — Where the durable identifier lives in the specification file

**Decision**: one HTML comment line, immediately after the user story's heading:

```markdown
### User Story 1 - A second run creates no duplicates (Priority: P1)
<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->
```

For a specification with no `User Story` heading at all (the implicit single story
`parse_spec` already synthesises), the line goes immediately after the document's H1.

**Rationale**: the anchor has to be something the parser can find deterministically and
a human can recognise on sight (FR-008). The story heading is the only structure
`parse_spec` already keys on (`^#{2,4}\s+User Story`), so no new document convention is
invented. An HTML comment renders invisibly, so the specification a stakeholder reads is
unchanged, while a developer reading the source sees `speckit-jira` and two
self-describing keys — no documentation lookup needed (Constitution XVI). Keeping it to
a single line keeps the byte-splice trivially reversible and diff-friendly.

**Alternatives rejected**:

- *A visible line (`**Jira**: PROJ-142`)* — reads well, but it becomes part of the
  specification's prose, would be swept into the ticket description by
  `parse_description_blocks`, and invites hand-editing of a value the bridge owns.
- *A front-matter block or a single table at the top of the file* — one region for all
  stories, splicable with the existing `managed_section_splice`. Rejected because it
  divorces the identifier from the story it names: reordering stories would leave the
  table's meaning ambiguous, which is the exact failure mode FR-006 exists to prevent.
- *A sidecar file (`spec.jira.json`)* — no parser change at all. Rejected under
  Constitution I and XVI: the binding belongs to the specification a human reads, and a
  sidecar is one more file to keep in sync and to lose in a merge.

**Consequence**: `parse.sh` must skip this line. `parse_description_blocks` treats every
non-empty non-heading line as prose, so without the change the comment would land in the
Jira description of every ticket. That is a required, test-first parser change on both
ports, not an optional cleanup.

---

## R2 — How a ticket is found again: recorded key, not search

**Decision**: recognition reads the issue key recorded beside the story and issues a
direct `GET /rest/api/3/issue/{key}?properties=spec-kit-jira` per recorded ticket. The
identity marker returned by that read is what *proves* the binding; the recorded key is
only how the candidate is located. No JQL, no search endpoint.

**Rationale**: this is the decisive constraint. The reported defect happens between two
lifecycle commands seconds apart — `/speckit.specify` then `/speckit.plan`. Jira's
search index is eventually consistent, so **any** search-based recognition returns an
empty result for a ticket created seconds earlier and re-creates it: the bug would
survive the fix in exactly the scenario that reported it. A direct read by key is
immediately consistent and has no such window. It also makes the spec's "Jira has not
yet indexed a ticket created moments earlier" edge case structurally unreachable rather
than something to detect.

Keying the *proof* on the entity-property marker (never on the recorded key alone)
keeps FR-002 satisfied: a hand-edited key that points at the wrong ticket fails the
marker check and fails closed (FR-011), rather than writing over a stranger's ticket.

**Alternatives rejected**:

- *JQL on the entity property* (`issue.property[spec-kit-jira].story = "…"`) — the
  natural query, and it is what the marker is for. Rejected because Jira Cloud only
  indexes entity properties declared by a Connect or Forge app descriptor
  (`jiraEntityProperties`); a script bridge authenticating as a user sets properties
  that are readable per issue but not searchable. The extension ships no app and
  Constitution VI forbids adding a deployment step to acquire one. **This assumption is
  load-bearing and must be confirmed against the live instance during implementation**
  (see the verification task in `quickstart.md`); if property JQL did work, it would
  still lose to the index-lag argument above.
- *A searchable label carrying the identifier* (`labels = "speckit-7f3a9c1e"`) —
  natively JQL-searchable with no app, and Constitution II explicitly sanctions labels
  for identity. Rejected as the *primary* path for the index-lag reason, and rejected as
  a permanent addition under YAGNI: it puts bridge bookkeeping into a field the whole
  team sees and can strip. It remains the natural recovery mechanism if R8's fail-closed
  window ever proves too harsh in practice — a follow-up feature, not this one.
- *Bulk `key IN (…)` search to collapse N reads into one* — same index dependency,
  same lag. Rejected.

---

## R3 — Recognition is one read per recorded ticket

**Decision**: one `GET` per story that has a recorded key, requesting the fields the run
needs and the identity property in the same request: current `summary`, `description`,
`priority`, `status`, the Flagged field, and issue links.

**Rationale**: the issue GET already returns everything three separate consumers need —
the churn comparison (FR-013, current field values), the drift rules (FR-020, status and
its category), and the human-origin panel split (FR-014, the existing description). One
request serves all three; `?properties=` folds the marker read into it instead of the
second round-trip `identity_read` performs today.

**Cost**: a specification with N mirrored stories issues N reads per lifecycle command,
where today it issues zero. For the specifications this extension targets (this
repository's own largest spec has 12 stories) that is a small, bounded cost paid once
per command, and it is the minimum price of not duplicating tickets. No batching is
introduced: it would reintroduce the index dependency R2 rejects.

**Alternatives rejected**: keeping `identity_read`'s separate property call (one extra
round-trip per ticket for nothing); reading only the property and fetching fields lazily
(two round-trips whenever anything changed, which is the common case).

---

## R4 — Generating the identifier, and how conformance stays byte-identical

**Decision**: 16 lowercase hex characters from 8 bytes of cryptographic randomness —
`/dev/urandom` on the Bash port, `RandomNumberGenerator` on the PowerShell port —
behind a single injectable seam, `SPEC_KIT_JIRA_ID_SOURCE`, which the conformance suite
and both unit suites set to a fixed sequence.

**Rationale**: FR-007 requires an identifier derived from neither position nor text, so
it cannot be a hash of anything in the document — that rules out every deterministic
scheme and makes randomness mandatory. But Constitution VI requires the two ports to
produce byte-identical output for identical inputs, and a random value is by
construction not reproducible. The seam is what reconciles the two: in production the
identifier is random; under test both ports read the same fixed sequence and emit
identical bytes. Without it, the conformance suite could not assert on any specification
file this feature touches.

The seam is a test affordance, which Principle XV scrutinises. It is justified because
it is the *only* way to keep the portability gate meaningful over a non-deterministic
value, and it is exercised by every conformance scenario in this feature — not dormant
code.

**Alternatives rejected**: `uuidgen` (not guaranteed present on either platform, and
Constitution VI forbids a new runtime prerequisite); `$RANDOM` (16 bits, and seeded
per-process — collisions are plausible across a repository's lifetime); a monotonic
counter persisted in the repository (a second source of truth to keep in sync, and it
re-derives from position in spirit); the timestamp (collides within a single run, which
creates all of a specification's identifiers in the same second).

---

## R5 — Ordering within a run: identifier first, key last

**Decision**: the run performs, strictly in this order, per specification:

1. assign identifiers to unassigned stories and write them into `spec.md` (one file
   write, only if the bytes changed);
2. recognise: read each recorded ticket, verify its marker;
3. plan and guard the Jira writes;
4. mark every story the plan will create as `creating` in `spec.md` (one file write);
5. apply the Jira writes;
6. for each ticket created, stamp its identity marker, then replace its `creating` with
   the recorded key in `spec.md`.

**Rationale**: this is what makes FR-012 achievable. Step 1 precedes any Jira write, so
a ticket can never exist for a story whose identifier was never recorded — the crash
that would otherwise orphan a ticket beyond recovery. Step 6 stamps before recording so
that a key present in `spec.md` always points at a ticket whose marker can be verified;
the reverse order would leave a recorded key pointing at an unmarked ticket, which
FR-011 would then have to fail closed on for no reason.

Step 4 exists so that "assigned but never sent to Jira" and "created but not yet
recorded" are two distinguishable states on disk rather than one. It sits after the
guard, not with step 1, so that a privacy-guard BLOCK or any other pre-write failure
leaves every story plainly assigned and freely creatable by the next run; see R8.

Step 6 records **per created ticket, immediately** — not once at the end of the run. A
batched write would widen the crash window from one ticket to all of them.

**Alternatives rejected**: stamping the marker inside the create payload via the
`properties` field (Jira Cloud does accept it, and it would make create-and-stamp
atomic). Rejected for this feature under KISS: `ticket.sh` already establishes
create-then-stamp, `apply_writes` applies an opaque pre-planned action set that has no
place to hang a follow-up call, and folding a second concern into the create payload
would change the shape every existing conformance scenario asserts on. It is the obvious
first optimisation if the R8 window ever bites.

---

## R6 — Who owns what, across the engine/sink boundary

**Decision**:

| Concern | Layer | Why |
| --- | --- | --- |
| Assigning an identifier | engine | Opaque value generation; no Jira vocabulary. |
| Reading identifiers out of `spec.md` | engine (`parse.sh`) | Text parsing, already the engine's job. |
| Splicing identifiers and keys into `spec.md` bytes | engine (new `story_marker.sh`) | Byte manipulation of a neutral document, exactly what `managed_section.sh` already does. |
| Deciding create vs update from a binding table | engine-supplied, sink-consumed | `plan_writes` already takes the table as plan context; nothing new crosses. |
| Reading tickets, verifying markers, stamping | sink | Every Jira coordinate stays here. |
| Sequencing the four steps of R5 | command layer | The only layer permitted to source both sides, as in 004. |

**Rationale**: Principle VIII's CI greps fail the build if any engine file names a
Jira identifier, so the identifier the engine assigns must be Jira-agnostic — it is, it
is a random hex string. The *key* the engine splices into `spec.md` is opaque text to
it: `story_marker.sh` takes an already-formatted marker line as a parameter, exactly as
`managed_section_splice` takes its markers as parameters rather than knowing about
READMEs.

**Alternatives rejected**: putting the whole write-back in the sink (it would drag
Markdown parsing into the Jira layer); putting the ticket read in the engine (a direct
Principle VIII violation).

---

## R7 — `local_id` becomes the durable identifier

**Decision**: the neutral document's `stories[].local_id` carries the durable identifier
instead of today's positional `s1`, `s2`, …. Stories with no identifier yet receive
theirs in step 1 of R5, so by the time the neutral document is assembled every
`local_id` is durable.

**Rationale**: `plan_writes` already indexes its `tickets`, `ticket_origins`, and
`ticket_descriptions` maps by `local_id`, and `plan_lifecycle` already correlates its
per-ticket facts by the same key. Making `local_id` durable makes every one of those
maps durable for free, with no new field and no second identity concept to keep aligned
— the KISS reading. Carrying both a positional `local_id` and a separate `story_key`
would mean two ids in the schema, two things for a reader to distinguish, and a
conversion at every seam.

**Cost**: every conformance scenario and unit fixture that asserts on `local_id` changes
in the same commit. That is a mechanical, one-time edit, and R4's seam makes the new
values deterministic under test.

---

## R8 — The one window that fails closed, and what it says

**Decision**: a story marked `creating` — a creation was attempted and its outcome was
never recorded, so the run cannot tell whether a ticket exists — fails closed for that
story alone: zero writes for it, the rest of the specification reconciles normally, and
the run reports

> `Story <identifier> in <spec path> is marked `creating`: a previous run was interrupted
> after creating its ticket and before recording the key, so whether a ticket exists
> cannot be determined. Check the project for a ticket carrying that identifier and
> record it as `<!-- speckit-jira story=<identifier> ticket=<KEY> -->`, or replace
> `creating` with nothing to mirror the story as a new ticket.`

**Rationale**: the `creating` marker form exists to make this state reachable *only* by a
run interrupted between the create response (R5 step 5) and the recorded key (R5 step 6)
— one file write after one HTTP response — or by a hand-edit that removed the key but
kept the identifier. Without that third form, every failure after identifier assignment
and before creation (a privacy-guard BLOCK, a rejected credential, an exhausted 429, an
interrupt) would leave the same indistinguishable state, and a first run that tripped the
guard would block the whole specification until a human deleted every identifier line by
hand.
Constitution III makes the choice for us: the alternative to failing closed is guessing
that no ticket exists, and guessing wrong is precisely the duplicate this feature exists
to eliminate. The message names the story, the file, both remedies, and the exact line
to paste (Constitution XVI).

**Note**: a story with *neither* identifier nor key is not this case, and neither is a
story carrying a plain `story=<id>` with no `creating` and no key. Both are simply new
(FR-010) and are created. Only `creating` fails closed.

**Alternatives rejected**: recovering automatically via a label search (R2 — index lag
makes it unreliable in exactly the recent-creation case that produces this state, so it
would sometimes duplicate anyway, which is worse than an honest refusal); prompting
interactively (a hook-fired run has no terminal).

---

## R9 — The drift rules engage; status transitions stay out

**Decision**: recognition supplies `plan_lifecycle` with everything the *protective*
rules need — current fields, `status`, its `category`, `origin`, `flagged`, `blockers`,
and a `target` status derived from the lifecycle event the run was dispatched for — but
does **not** supply `transition_id`. The consequence, read off `plan_apply.sh:213-248`:
drift is evaluated and its warnings are emitted, a backward-drifting ticket has its
content write suppressed, a Flagged ticket is surfaced and withheld, blocker notes are
produced — and no status-transition request is ever emitted, exactly as today.

**Rationale**: FR-020 requires the drift, Flagged, and blocker rules to *evaluate*
recognised tickets and forbids a silent overwrite or regression. Those rules all sit
before the transition emission, and every one of them fires on `target` alone. Fetching
transition ids would mean a second `GET /issue/{key}/transitions` per ticket to enable a
capability the specification never asks for — the definition of a YAGNI violation. Not
emitting transitions also satisfies "MUST NOT silently regress" in the strongest
possible way: the run cannot move a ticket's status at all.

The `target` itself costs nothing extra: the lifecycle event is already read by
`_reconcile_hook_event`, and the phase→status map is already loaded and resolved by
`config_phase_status_targets`. A run invoked directly, outside any hook, infers no phase,
supplies no `target`, and therefore evaluates no drift — the same inert behaviour it has
today.

**Alternatives rejected**: fetching transitions and advancing tickets (out of scope, one
extra call per ticket, and it turns a bug fix into a feature); supplying no `target` at
all (cheapest, but it leaves the drift and Flagged rules inert and fails FR-020).
