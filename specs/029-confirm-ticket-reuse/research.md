# Phase 0 — Research

**Feature**: 029 | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

Every decision below was taken by reading the shipped code, not by inference. File
and line references are to the tree at the time of writing.

---

## R1 — How the answer travels back

**Decision**: one new flag, `--reuse <yes|no>`, parsed by `lib/cli.sh` and its
PowerShell mirror. Absent means unanswered, which is what makes the question
appear.

**Rationale**: it mirrors `--use-team <id>` exactly — the flag that already answers
this command's other closed question (`feature.sh:521-529`). A closed question with
two answers maps to a flag with two accepted values; anything else invents a second
convention for the same job.

`--reuse yes` is load-bearing even though an assistant could skip straight to
supplying designators. Without it, FR-029's follow-up question ("which issues?")
would have to be improvised by the assistant rather than returned by the bridge,
and an improvised question is neither deterministic, nor testable, nor identical
across ports. The flag is what makes the follow-up a *bridge* behaviour.

**Alternatives considered**:

- A boolean pair (`--reuse` / `--no-reuse`): cannot distinguish "answered no" from
  "not asked yet", which is precisely the distinction FR-011 depends on.
- `--answer <value>`: opaque at the call site. Principle XVI wants a reader to
  understand an invocation without the documentation.
- Recording the answer in a state file: rejected outright. FR-004 and FR-030 forbid
  state, and a persisted answer would resurface on an unrelated later run.

---

## R2 — What counts as naming a ticket (the consequential one)

**Decision**: the **leading positional only**, in either form — a bare issue key
(today's shape) or a browser URL reduced by the rules `sink/jira/designator.sh`
already applies (`selectedIssue=`, the segment after `/browse/`, else the final path
segment). A key or URL appearing anywhere else in the description is **not** a
mention.

**Rationale**: `feature.sh:474` matches `^[A-Z][A-Z0-9_]+-[0-9]+$` against
`words[0]` and nothing else. Extending that one test to accept a reduced URL is a
contained change on a well-defined position. Scanning the whole description is not:
the description is the slug source (`naming_slug`), so a key found mid-sentence
would silently change the computed folder and branch names, and a description that
merely *cites* a related ticket would be read as naming this feature's ticket.
Precision beats recall here for the same reason Principle IX gives at the BLOCK
tier — a control with false positives gets disabled.

**Known consequence, stated plainly**: the reported incident's exact keystrokes were
`/speckit.specify "ticket https://…/browse/IJT-2241"`. The leading positional there
is the word `ticket`, not the URL — so under this decision that invocation still
produces no question. What made the incident work at all was the assistant
extracting the key by hand before calling the bridge. This decision fixes
`/speckit.specify https://…/browse/IJT-2241 migrate to node 22` and leaves the
prose-prefixed form to the agent ceremony, which `commands/speckit.jira.feature.md`
must state explicitly: pass the ticket as the leading positional.

**This is the one decision in the plan that a maintainer may reasonably overturn.**
Overturning it means accepting a whole-description scan and its two costs above.

> **OVERTURNED, 2026-08-17 — see [R10](#r10--the-question-became-a-proposal-overturning-r2).**
> The maintainer took the decision this section invited. R2's *gate* survives intact and
> is now the whole of its contribution: a request whose leading positional is not a key
> still names nothing. What changed is what happens once that gate is open. R2's two
> costs are answered rather than accepted — the slug still comes from the leading
> positional alone, and a false positive is now shown to the operator as a line to
> decline instead of acted on silently.

**Alternatives considered**:

- **Whole-description scan**: fixes the reported keystrokes exactly, at the price of
  silent renaming and false positives. Rejected, with the maintainer flagged.
- **A `--ticket <designator>` flag**: unambiguous, but it is a third way to name a
  ticket alongside the positional and the designators. Principle XIV.
- **Strip a leading noise word** (`ticket`, `issue`, `jira`) before testing
  `words[0]`: a heuristic word list is exactly the "no hard-coded assumptions"
  smell, and it would be English-only.

---

## R3 — Declaring a run unattended

**Decision**: reuse the existing `--accept-defaults`. No new flag.

**Rationale**: `lib/cli.sh:201` already parses it and `reconcile.sh:791` already
uses it to mean "do not ask; take the safe default". The spec's own assumption calls
for one silencing mechanism in the project rather than two. The safe default here is
`no` — today's behaviour — which is what FR-013 requires.

**Rejected**: TTY detection. The bridge runs inside a lifecycle hook and never has a
terminal, so a TTY probe would suppress the question **always**, silently reducing
this feature to a no-op. This is the single most likely way to ship something that
passes review and does nothing.

---

## R4 — Where the decision point sits, and what has to move

**Decision**: detect the mention (R2) at the top of `cmd_feature`, before the four
early pass-through exits; keep every one of those exits emitting exactly what it
emits today when nothing was mentioned.

**Rationale**: `cmd_feature` returns bare `{"active":false}` at four sites, all
before `words[0]` is ever examined:

1. no `config.yml` at all,
2. `config_load` failure,
3. `team_count == 0`,
4. no personal selection and no `--use-team` (`feature.sh:449-452`).

FR-026 owes a message at these sites, but only to an operator who named something —
so the mention must be known first. Detection is a pure string operation needing no
configuration, so it can move up without dragging anything with it.

**The risk this creates, and the test that pins it**: every repository that does not
use this extension travels one of these four exits on every `/speckit.specify`. If
the message escapes to a run that mentioned nothing, SC-004 fails for the entire
installed base. The conformance scenario `us3-feature-no-team.json` already covers
exit 4 with no mention; it must stay byte-identical and be joined by siblings for
exits 1-3.

---

## R5 — Two missing-configuration cases, two remediations

**Decision**: FR-026's report distinguishes the committable layer from the personal
one.

- Exits 1-3 (no `config.yml`, unreadable, or an empty `teams:` catalogue) name
  `.specify/jira/config.yml` and direct the operator to `/speckit.jira.config`.
- Exit 4 (a catalogue exists but the operator has selected no team) names
  `.specify/jira/personal.yml` and states that the selection is the operator's own
  and is never written by any script.

**Rationale**: Principle V makes these different layers with different owners, and
Principle XVI requires a *copy-pasteable* remediation. Sending an operator to
`/speckit.jira.config` when their real problem is an unselected team would be a
remediation that cannot work — worse than silence, because it costs a round trip
before failing the same way.

**Note for `/speckit-tasks`**: this is two message classes, so it is two tests.

---

## R6 — Ordering the two questions

**Decision**: the cross-team question keeps its position (`feature.sh:521-529`); the
reuse question is evaluated immediately after it, before naming.

**Rationale**: FR-025 fixes the order, and the code already places the cross-team
question after `ticket_validate` and before naming — the reuse question needs the
same two facts (the ticket resolved, the team settled) and therefore the same slot,
one step later. No restructuring is required for this requirement; it falls out of
where the existing question already lives.

---

## R7 — Test and conformance surface

**Decision**: extend, never replace.

- **bats**: `tests/bash/commands/test_feature.bats` gains the question, both
  answers, the unattended suppression, and the two configuration messages;
  `test_feature_designators.bats` gains the URL mention and the
  reuse-without-issues follow-up.
- **Conformance**: the existing `us3-feature-*.json` scenarios must run unmodified
  and byte-identical — they are the regression proof for FR-008/FR-010/FR-028. New
  scenarios are added beside them for each new path.
- **Pester**: mirrors the bats additions in `Feature.psm1`'s suite.

**Two hazards recorded from the repository's own catalogue**:

- The URL reduction is glob-matching territory. `docs/10-windows-portability.md`
  forbids `$'\r\n'` inside a glob pattern — the MSYS matcher bends it onto a bare
  LF. The reduction being reused is already Windows-proven; a new pattern written
  beside it is not.
- Every new multi-line output must go through `lib/output.sh`, never a direct `jq`
  call, because the Windows `jq` build emits CRLF on multi-line output.

**Rejected**: rewriting the existing feature scenarios to carry the new flag. They
exist to prove nothing changed; editing them destroys the evidence.

---

## R8 — Where the question's facts come from (added after `/speckit-analyze`)

**Decision**: widen the mentioned-key read's field set to
`project,summary,issuetype,status`, **conditionally** — only when the run has already
established it is about to ask.

**Rationale**: FR-003 requires summary, type and status. `ticket_validate`
(`sink/jira/ticket.sh:46`) issues `GET /issue/{key}?fields=project` and returns
`{key, project}` — the three facts do not exist anywhere in the process. FR-017's
original wording ("composed from what the read already returned") described a state of
the code that has never held. All four conditions that decide to ask — mention
present, no designator, no `--reuse`, no `--accept-defaults` — are known from argv and
the loaded configuration *before* the read, so the field set can be chosen at the call
site. Request count is unchanged either way, which is what FR-017 actually protects.

**The measurement that makes this non-trivial**: both conformance mocks branch on the
exact query string. `curl-shim.sh:620` matches `fields=project` anchored on `&` or
end-of-string, synthesises `{key, fields:{project}}` from the key prefix, and returns
`404` when the project is unknown to the run's config. A wider query does not fail —
it falls through to `_shim_issue_get`, which for an issue absent from the run store
serves `fixtures/issue-mentioned.json`: key `MENT-1`, **no `project`**, **no
`issuetype`**. So an unconditional widening turns `us3-feature-attach` into a
cross-team question (project resolves to null) and removes the `404` the fail-closed
scenario depends on — both silently, both looking like a port bug. The fixture and
both mocks move with the ports or not at all.

**Alternatives considered**:

- **Widen unconditionally**: one line instead of a branch, at the cost of the
  recorded request of every mentioned-key run — FR-010's regression proof.
- **A second request just for display**: forbidden outright by FR-017 and SC-007.
- **Show only the key**: satisfiable today with no code change, and it guts the
  feature — the question exists so the operator can recognise their ticket.

---

## R9 — Status and multiplicity (added after `/speckit-analyze`)

**Decision**: the wider read's `status` is compared against the routed project's
configured halted list (`_feat_halted_csv_for`, already read for the designator path)
and the question says that "reuse" would be refused when it matches (FR-033). Extra
issue-shaped tokens are reported but never recognised, and **only when the leading
positional is itself a mention** (FR-034).

**Rationale**: `adoption_evaluate` already refuses `REF-TERMINAL` — "issue X is in the
terminal status Y — reopen it, or name a different one" (`adoption.sh:158`) — but only
*after* the operator has answered "reuse" and re-invoked. Asking a question whose
likely answer the next step will reject is the same defect FR-007 avoids for
unreadable keys; the fix costs one comparison against a list already in memory.

**Rejected for FR-034**: reporting issue-shaped tokens in a run whose leading
positional is not a mention. The shape `^[A-Z][A-Z0-9_]+-[0-9]+$` matches `COVID-19`,
so that reading would emit Jira guidance into repositories that have never installed
this extension — a control with false positives, which Principle IX's own reasoning
says ends up disabled. The prose-prefixed shape stays the ceremony's job (R2).

---

## R10 — The question became a proposal, overturning R2

**Decision**: once the leading positional is a key, **every** further token that reduces
to a key is detected, and the question proposes each one in the role the routed
project's hierarchy declares for its type. Accepting the proposal is the whole answer.

**Rationale**: R2 was written before the read was widened. It reasoned about a run that
knew a key and nothing else — no summary, no type — so recognising more keys could only
mean *guessing* what to do with them, and guessing is what its two costs describe. R8
changed the premise: the type is now in hand, and the role mapping was already in the
loaded configuration. A run that knows the type does not guess, it **proposes** — and a
proposal is confirmed before it binds anything.

That inverts R2's calculus on both costs:

- **Silent renaming** — answered structurally, not by restraint. The slug, branch and
  folder short name derive from the leading positional alone, so a second detected key
  cannot move them however the description is reordered.
- **False positives** — answered by the feature's own philosophy. `IJT-40 see IJT-99 for
  background` puts `IJT-99` in the list; the operator declines it by naming what they
  meant. A false positive costs one line in a list they are already reading. Under R2's
  design the same request cost nothing *and taught them nothing*, which is the defect
  this feature exists to end.

**What R2 keeps**: the gate. A leading positional that is not a key means nothing is
examined at all, and that is what protects every repository which never installed this
extension. `COVID-19` in an ordinary description is still, and permanently, silence.

**Measured consequence**: the ordinary path drops from two round-trips to one, because
FR-029's "which issues?" follow-up now has nothing to ask in every case where a
hierarchy is declared. The follow-up survives only for a project that declares none.

**Alternatives considered**:

- **Keep R2 and report the extras without recognising them** (the previous draft): the
  operator is told three tickets were seen and then has to retype two of them as
  designators. Told, but not helped.
- **Detect every key anywhere, ungated**: reinstates the `COVID-19` false positive in
  repositories that named nothing. Rejected outright — the gate is R2's real
  contribution and it survives untouched.

---

## R11 — Unmapped is not misplaced

**Decision**: an issue whose type matches **neither** declared role is proposed in the
story role and confirmed by the operator (FR-036). An issue whose type matches the
**other** role refuses (FR-022). Two different situations, two different outcomes.

**Rationale**: `adoption_evaluate` (`adoption.sh:139`) emits one `REF-ROLE` for both,
and `_feat_declared_type_for` returns a single declared type per role — so a Bug in a
project declaring Epic and Story matches nothing and is refused today. But a Bug is not
a mistake: Jira places it at the same hierarchy level as a Story, and the project simply
declared no role for it. Refusing is the same silence this feature exists to end, one
type further along.

**Why the proposal is story-role and not something cleverer**: the specification role is
the container, and a type the hierarchy does not name is by construction not the
container. Proposing it as content is the only placement that can be right, and it is
proposed — never applied — so Principle VII is honoured: the run asserts nothing about
the workflow, it asks.

**And it needs no parent.** Accepting an unmapped issue with no specification-role issue
named keeps the established meaning already recorded in the spec's Assumptions: nothing
is created above it, nothing is re-parented. Requiring an Epic for a Bug would be this
feature inventing a workflow rule.

**Rejected**: a configuration key listing additional types per role. It would be
hand-edited, named in no template or install document, and therefore undiscoverable —
the failure mode already recorded for `phase_status_map`. The operator who hits this
case is precisely the one who does not know the key exists.
