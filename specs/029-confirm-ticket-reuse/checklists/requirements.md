# Specification Quality Checklist: Ask once whether an existing ticket should be reused

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-17
**Updated**: 2026-08-17 — clarifications encoded
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

All items pass. The specification is ready for `/speckit-plan`.

### Clarifications resolved (3)

Recorded in the spec's Clarifications section, session 2026-08-17.

1. **Role mismatch on "reuse"** — refuse with zero writes, naming the issue, the
   type found, and the type the role declares, and state both ways forward
   including the one needing no pre-existing parent (supply a title, the parent is
   created). FR-022 to FR-024, User Story 3 AC3/AC4.
2. **Two questions pending at once** — fixed order, team question first, two
   round-trips, never merged. FR-025, and the reasoning is recorded in Edge Cases:
   routing decides which hierarchy the reuse answer is measured against.
3. **No team configuration applies** — replace today's silent pass-through with a
   report naming the file and the command, but only when the operator named a
   ticket. FR-026 to FR-028, User Story 6.

### Second review pass, 2026-08-17

Three findings from a re-read, all resolved in the spec:

1. **Incomplete "reuse" answer was undefined** — the likeliest caller slip, and the
   spec was silent. Now FR-029/FR-030: ask which issues, zero writes, repeatable
   without state.
2. **The anti-skip property was buried** — the omission of the branch and folder
   names was written as naming hygiene. It is the only requirement that holds
   against a caller which ignores instructions. Now FR-031, cited from User Story 1
   AC2 and measured by SC-012.
3. **A pasted link is not recognised today** — `commands/feature.sh` matches only a
   bare key shape on the mention path; URL reduction lives solely in the designator
   grammar. The reported incident therefore depended on the assistant extracting the
   key by hand. Now FR-032, measured by SC-011. This is the finding most likely to
   surprise the plan: it is new behaviour on the oldest path in the command.

### Scope decision, 2026-08-17

User Story 6 (the missing-configuration message) repairs a defect distinct from the
reuse question and could have shipped alone. It **stays in this specification** by
the maintainer's decision, recorded with its reasoning in the spec's Clarifications
section. A reviewer should not re-open it; the accepted risk — a partial
implementation shipping the question without the message — is why User Story 6 is
written to be verifiable with no Jira double at all.

### Third review pass, 2026-08-17 — after `/speckit-analyze`

Three findings, all resolved in the spec, the contracts and the plan:

1. **FR-003 was unbuildable.** The question must name the issue's summary, type and
   status; the shipped mentioned-key read asks Jira for the project alone and returns
   nothing else, and FR-017 asserted the opposite. Resolved by widening that one
   request **only on the path that is about to ask** — contract §7 pins the two field
   sets, the five files involved (both ports, both conformance mocks, one fixture),
   and why an unconditional widening silently breaks `us3-feature-attach`.
2. **A finished ticket invited an answer that would be refused.** `adoption_evaluate`
   already refuses `REF-TERMINAL` for an issue in a configured halted status — but only
   after the operator answered "reuse" and re-invoked. Now FR-033: the question says so
   up front, from the status the wider read brings back. No status is halted by
   default; the configured list is the only source.
3. **Several tickets in one request went unmentioned.** Nothing covered
   `IJT-1 IJT-2 make exports faster`. Now FR-034: the extras are named back with a
   pointer to the designator route, **only** when the leading positional is itself a
   mention — because the key shape also matches `COVID-19`, and guidance emitted into
   repositories that named nothing is a control that gets disabled.

### Fourth pass, 2026-08-17 — the five gaps that had no test at all

Found by the same analysis, fixed after the three above:

1. **FR-025 (question order) had zero coverage** — only a documentation task. Now
   T097–T099, including a two-round conformance pair, because a single-round scenario
   cannot express a *sequence*.
2. **FR-021 (never waits) had no task.** Now T100: stdin closed and stdin held open,
   both ports. A `Read-Host` on this path hangs a lifecycle hook, the one failure
   Principle IV forbids by name.
3. **FR-018 (message shape) belonged to no story.** Now T101, enumerating all eleven
   message classes by name so a twelfth fails the assertion instead of slipping past.
4. **FR-015 contradicted contract §2 row 3.** Resolved by splitting it in two: an answer
   with neither mention nor designator is an error, `--reuse no` *with* designators is a
   contradiction and an error, and `--reuse yes` with designators is redundant and
   accepted in silence. §2 now states first-match evaluation, which it always relied on
   but never said.
5. **The two questions had no discriminator.** `confirmation_required` is a single key
   and the shipped prose renderer branches on its presence — so a reuse question reusing
   it would have printed the cross-team text. Now §3.1: one payload key per question,
   `confirmation_required` untouched (adding a `kind` field inside it would change the
   bytes of the very scenario that proves it unchanged).

### Fifth pass, 2026-08-17 — the two success criteria

1. **SC-002 had no automated witness.** The feature's headline outcome — zero duplicate
   parents in the reported scenario — was verified only by the manual dogfood. It is now
   a three-run conformance scenario (T105) plus its `--reuse no` mirror (T106), which is
   also the first test US2 AC3 has ever had. No harness work was needed:
   `tests/conformance/run-scenario.sh:188-235` already supports `runs[]`,
   `runs[].before.write` for placing the drafted `spec.md` between runs, and
   `calls.log.N` for the last run's own request slice.
2. **SC-003 was self-contradictory.** "Exactly one re-invocation" is false whenever the
   cross-team question applies (FR-025) or "reuse" arrives without issues (FR-029).
   Restated as a bound plus an invariant: at most three round-trips, and **every**
   re-invocation is preceded by a question the operator was shown — a silent retry is
   what the criterion now forbids, which is what it was reaching for all along (T108).

### Sixth pass, 2026-08-17 — the question becomes a proposal

A maintainer decision, not an analysis finding. The question stops being an abstract
choice and becomes a concrete proposal — and it is only affordable because the read was
widened three passes earlier. 38 requirements, 118 tasks.

1. **One line per detected issue, each with its proposed role** (FR-002, FR-003,
   FR-035). The type comes from the widened read, the role mapping from configuration
   already loaded: no extra request. The question states what accepting routes into
   (the issues' content is the specification's source material) and what declining
   creates, in the project's own type names — never `specification`/`story`.
2. **Every token is detected once the gate is open** (FR-034, R10). Research R2's
   leading-positional-only *recognition* rule is overturned; R2's *gate* survives whole
   and is what keeps `COVID-19` silent in repositories that named nothing. The slug
   still derives from the leading positional alone, so no reordering can rename a
   branch. A ticket cited for context appears and is declined — costing a glance, where
   R2's design cost silence.
3. **Unmapped is not misplaced** (FR-036, R11). A `Bug` where the project declares Epic
   and Story is *proposed* as a Story, never refused, and **needs no Epic** — accepted
   alone it creates nothing above itself. `adoption_evaluate` collapses both cases into
   one `REF-ROLE`, so T118 is explicitly told not to delegate this distinction to it.
   A configuration key listing extra types per role was rejected as undiscoverable, the
   failure already recorded for `phase_status_map`.
4. **No refusal is a dead end** (FR-037). Every class reachable on the reuse path states
   the escape that always exists: decline, and the extension creates the Epic and one
   Story per drafted user story. T119 appends it once in the aggregator — five copies of
   one sentence is how the fifth ends up different.
5. **One round-trip is now the ordinary case** (FR-029, FR-038, SC-016). "Which issues?"
   survives only for a project that declares no hierarchy, and a story-only proposal
   carries its parent routes in its own answers instead of posing a second question.

### Seventh pass, 2026-08-17 — the documentation surface

Found by the maintainer asking whether the README was covered. It was not: only
`commands/speckit.jira.feature.md` and `docs/06-feature-naming.md` had tasks, and this
feature changes what an operator *types*.

`README.md`'s seeding section states outright that `--parent`/`--story` is *"the one way
to tell the bridge this is an existing issue"* — a sentence this feature makes false, in
the document a consumer reads first. Four more describe behaviour that stops being true:
`commands/speckit.jira.seed.md` (now reached through the question), `docs/08-safety-model.md`
(a reachable state missing from its diagram), `docs/03-lifecycle-hooks.md`
(`before_specify` may now exit 0 with no name), and whatever a grep for `mentioned` /
`attached` / `designator` turns up elsewhere. Now T123–T127, with Phase 10 restated:
documentation is a gate here, not polish.

**The pattern worth remembering**: the task generator covered the documents the *code*
touches, not the documents the *behaviour* contradicts. Those are different sets, and
only the second one is visible to a consumer.

### Eighth pass, 2026-08-17 — two scenarios the maintainer asked about

One was already covered; one was not. Worth recording both, because the covered one
looked like a gap and the uncovered one looked like a detail.

1. **The agent drafts more user stories than were named — already specified, in 027.**
   Its SC-002 fixes the arithmetic exactly: *story-role issues created = drafted user
   stories − named story-role issues*, no off-by-one, no duplicate; a parent created
   from free text is counted separately. 027 even handles a user story added *after* the
   write plan was shown — the plan is recomputed from the file on disk and the delta
   disclosed before confirmation. Nothing to build. What was missing is that the
   operator learns none of this **before answering**, which is now FR-040's `Drafted:`
   line: someone who thinks the specification will be capped at the issues they named
   declines a proposal that would have served them.
2. **A named Bug that turns out to be the whole feature — a real gap** (FR-039). It
   starts with a Jira fact: a Bug sits at the same hierarchy level as a story, so it
   cannot hold stories, and this feature never changes an issue's type. The shape the
   operator wants is nevertheless one answer away —
   `--reuse yes --parent "<title>" --story <bug key>` creates the parent and places the
   Bug beneath it, with the drafted user stories beside it. Reachable today,
   **undiscoverable**: designating the Bug as the parent refuses with a message about
   declared types and never names the route. The refusal now carries it.

### Ninth pass, 2026-08-17 — the stories were rewritten to fit the feature

Six stories written for a 32-requirement feature were carrying 41. The symptom was
diagnostic: **User Story 1 had become a sack.** Titled "the operator is asked before
anything is created", it also owned multi-issue detection, role derivation, unmapped
types, the Bug route, and the drafted-stories line — and FR-041 belonged to no story at
all, which is the state in which a requirement quietly ships as nobody's.

Now nine, with US1–US6 keeping their numbers so none of the 131 task labels had to move:

- **US7 — the question shows, per ticket, what it will do** (P1). US1 keeps *that* the
  question is asked and that it costs nothing; US7 owns *what it says*. They ship
  together because a question with no content cannot be evaluated.
- **US8 — a ticket that does not fit is redirected, never dead-ended** (P2). Every
  refusal and its route, including the unmapped type that is proposed rather than
  refused.
- **US9 — every message says what the run already knows** (P2). Gives FR-018 an owner
  and FR-041 a home, and states the reported incident's defect class as an outcome
  rather than a checklist item.

A requirement→story table now sits in `spec.md`; it partitions all 41 exactly once and
records the single deliberate exception. **FR-019 (cross-port byte equality) belongs to
no story on purpose** — it is a constraint on every path, not an increment anyone can
ship — and saying so is what stops it from reading as an oversight at the next review.

Phases stayed as they were and are explicitly **not** one-to-one with stories: Phase 3
delivers US1 + US7 + US9, Phase 6 delivers US3 + US8. Execution grouping and value
grouping are different questions, and pretending otherwise would have meant splitting a
single function across three phases.

### Points a reviewer should check hardest

- **The byte-equality boundary.** Three requirements guarantee an unchanged run
  (FR-008, FR-010, FR-028) and one adds a new message (FR-026). They meet at a
  single condition: whether a ticket was mentioned. If the implementation reports
  the missing configuration before establishing that a ticket was mentioned, SC-004
  fails for every repository that does not use this extension. Today's code makes
  exactly that ordering mistake available: the pass-through returns before the
  mentioned key is parsed.
- **FR-024 adds no machinery.** Creating a missing parent from a title already
  ships. If the plan proposes new creation logic for it, the plan has misread the
  requirement — what is new is the refusal *naming* that route.
- **FR-025's order is load-bearing, not cosmetic.** Asking the reuse question first
  would measure the answer against a hierarchy the team answer may then change.
