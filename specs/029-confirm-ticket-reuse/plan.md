# Implementation Plan: Ask once whether an existing ticket should be reused

**Branch**: `fix/attached-jira-ticket` | **Feature id**: `029-confirm-ticket-reuse` |
**Date**: 2026-08-17 | **Spec**: [spec.md](./spec.md)

> The branch name and the feature id differ here, deliberately recorded rather than
> quietly reconciled: the work started as a fix for the reported incident and the folder
> was numbered afterwards. `.specify/feature.json` points at the folder, which is what
> every script reads; the branch name is only a human label.

**Input**: Feature specification from `/specs/029-confirm-ticket-reuse/spec.md`

## Summary

`speckit.jira.feature` learns one closed question. When it resolves a mentioned
ticket and was given no designator, it returns that question instead of naming the
feature, and it withholds the branch and folder names so the caller cannot proceed
without an answer. The answer arrives as a flag on a second invocation: `no` runs
today's path byte for byte, `yes` routes into 027's designator path — or, when no
issue was named alongside it, returns a second question asking which.

Two smaller repairs ride along the same trigger. A pasted browser URL becomes a
recognised mention (today only a bare key is), and a run that names a ticket in a
repository with no applicable team configuration says so instead of returning
silently inactive.

The bulk of the machinery already exists: the `confirmation_required` shape
(`feature.sh:525`), the designator path (`_feat_seed_from_designators`), URL
reduction (`designator_reduce_url_candidate`), and the unattended declaration
(`cli.sh:201`, `accept_defaults`). What this feature adds is one decision point,
one flag, four message classes, and two changes that carry the whole risk of the
work: a control-flow reordering, and a conditional field set on the mentioned-key
read.

That read is the part the first plan got wrong. `ticket_validate` asks Jira for
`fields=project` and returns `{key, project}` — so the summary, type and status the
question must display are not available at all. They arrive by widening that one
request **only on the path that is about to ask**, which keeps every other path's
request identical to the current release, query string included. Contract §7 pins the
two field sets and the five files the widening touches, two of them conformance mocks
that key on the exact query string.

The wider read then changes the question's own nature. Knowing each issue's type, and
holding the project's declared hierarchy already, the question stops being an abstract
choice and becomes a **proposal**: one line per detected issue, each with the role it
would be attached in, plus what accepting routes into and what declining creates
instead (FR-002, FR-035). Every token that reduces to a key is detected once the leading
positional is itself one — the gate research R2 built survives, the recognition rule it
imposed does not (R10). Two consequences fall out: the ordinary path costs one
round-trip rather than two, and a type the hierarchy maps to no role is *proposed as a
Story* rather than refused (FR-036, R11) — an unmapped issue is not a misplaced one, and
it needs no Epic.

Two smaller behaviours ride on the same facts: an issue in a configured halted status is
flagged in the question rather than refused a round-trip later (FR-033), and every
refusal reachable here states the escape that always exists — decline, and the extension
creates the Epic and one Story per drafted user story (FR-037).

## Technical Context

**Language/Version**: Bash 4.0+ (macOS/Linux) and PowerShell 7+ (Windows) — two
native ports, no shared runtime.

**Primary Dependencies**: `jq` (via `lib/output.sh` only — never called directly in
the Bash port), `curl`. No new dependency.

**Storage**: None. The pending question is returned, never persisted — no seed
record, no run state, no file of any kind (FR-004, FR-030).

**Testing**: `bats` for the Bash port (`tests/bash/commands/test_feature.bats`,
`test_feature_designators.bats`), Pester for PowerShell, and the shared conformance
corpus (`tests/conformance/scenarios/us3-feature-*.json`) for cross-port byte
equality.

**Target Platform**: macOS, Linux, Windows — three-OS CI matrix is a merge gate.

**Project Type**: CLI bridge invoked from spec-kit lifecycle hooks.

**Performance Goals**: No additional Jira request on the question path (FR-017), and
no additional process spawn per invocation. This feature adds no loop, so the
process budget of `docs/11-process-budget.md` is not engaged.

**Constraints**: Byte-identical output between ports (FR-019). Byte-identical
output against the current release on every path where nothing is mentioned
(FR-008, FR-028) and from the answered invocation onward when the answer is `no`
(FR-010). The script must never prompt or wait (FR-021).

**Scale/Scope**: Two command modules (`commands/feature.sh`, `commands/Feature.psm1`),
one CLI parser per port, **one sink module per port** (`sink/jira/ticket.sh`,
`sink/jira/Ticket.psm1` — the mentioned-key read's field set, contract §7), **both
conformance mocks and one fixture**, one agent-facing command document, and the
conformance corpus. No engine module is touched.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Principle | Gate verdict |
| --- | --- | --- |
| I | Filesystem source of truth, two controlled exceptions | **PASS.** This feature operates the first controlled exception exactly as written — a mentioned key licenses reading and editing *that* ticket. It widens nothing: the `yes` answer routes into 027's designator path, whose adoption is already logged. |
| II | Zero-churn idempotency | **PASS.** No new write kind. The question performs zero writes; repeating an incomplete answer is idempotent by construction (FR-030). |
| III | Fail-closed on writes, non-blocking on hooks | **PASS.** An unreadable mentioned key keeps its fail-closed exit (FR-007). Returning a question exits 0 (FR-005). The unattended path guarantees no stall (FR-013). |
| IV | Credential security | **PASS.** No credential path is touched. The no-prompt-in-a-hook rule is honoured literally: the script returns and exits, never waits (FR-021). |
| V | Config / local binding / secrets separation | **PASS.** No configuration key is added. FR-026 only *reads* the committable layer to report that it declares no applicable team. |
| VI | macOS / Linux / Windows portability | **PASS, and this is the expensive gate.** Every new message crosses platforms and must be byte-identical; the URL reduction of FR-032 is a glob-matching surface, which is where `docs/10-windows-portability.md` records the MSYS CRLF hazard. Conformance scenarios are extended, not replaced. |
| VII | No hard-coded Jira workflow assumptions | **PASS, and it is the gate FR-036 is written against.** FR-022's refusal quotes the *configured* hierarchy's declared type, never an Atlassian default. FR-033 likewise: which statuses end a workflow comes from the project's configured halted list — no status name is compiled in, `Cancelled`, `Done` and `Terminé` are data. FR-036 is the sharpest case: an unmapped type is **proposed** in the story role and confirmed by the operator, never placed there by assumption, and requiring a parent for it was explicitly rejected as this feature inventing a workflow rule. The role names the operator sees are the project's own configured type names; `specification` and `story` never surface. |
| VIII | Neutral engine / Jira sink | **PASS.** All work lands in `commands/` and reads from `sink/jira/designator.sh`, which `commands/feature.sh` already sources (line 30). No engine module learns about tickets or questions. |
| IX | Two-tier privacy guard | **PASS.** The question repeats issue facts an existing read already returned and the current release already displays. No new content class, and no write to guard. |
| X | Self-healing automatic mirror | **PASS.** Hook registration untouched; no event added or removed. |
| XI | Universal dry-run and auditability | **PASS.** `--dry-run` predicts the question without performing it (FR-020); every outcome including a suppressed question is reported (FR-014). |
| XII | Quality and catalog publication | **PASS, with obligations.** Version bump, CHANGELOG, three-OS green, and a dogfood run against a real instance. The dogfood must replay the reported scenario, since that scenario is why this exists. |
| XIII | TDD with ≥80% coverage | **PASS, with a named ordering.** Every requirement is an observable outcome. The regression test — a mentioned key with no designator must not reach a silent naming — is written first and observed to fail. |
| XIV | KISS | **PASS, re-argued — the earlier verdict was written for a smaller feature and no longer held.** It read "one decision point, one flag with two values, no new mechanism", which stopped being true once the question became a proposal. What is now added: a conditional field set on one existing read, a role derivation that is two string comparisons against configuration already in memory, a token scan that reuses the shipped URL reduction, and one split (unmapped vs misplaced) inside an existing branch. No new module, no new configuration key, no new flag beyond `--reuse`, no new state. Each addition *removes* a round-trip or a dead end rather than adding a capability — which is the KISS test that matters here, since the alternative to each was another question to the operator. |
| XV | YAGNI | **PASS.** Each artifact traces to a requirement, and every requirement traces to a scenario the maintainer named. FR-024, FR-038 and FR-040 require *naming* existing capabilities rather than building them. See Complexity Tracking for the two items to watch. |
| XVI | Human readable | **PASS, and it is the principle this feature turned out to be about.** Every message names the problem, the issue, and a copy-pasteable next step (FR-018, FR-023, FR-026, FR-037, FR-039). FR-041 goes further and removes a message that promised the opposite of what happens. A message audit run against the whole bridge found eight more sites of the same shape outside this feature's scope; they are recorded for a follow-up, not smuggled in here. |

**Post-Phase-1 re-check**: unchanged. The design introduced no abstraction, no
dependency, and no configuration key. The single complexity item is recorded below.

## Project Structure

### Documentation (this feature)

```text
specs/029-confirm-ticket-reuse/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── mention-grammar.md          # What counts as naming a ticket
│   └── feature-question-contract.md # The question, the answer, the exits
├── checklists/
│   └── requirements.md  # Written by /speckit-specify
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

The golden "before" captures of Phase 1 live at `/.baseline/029/` — **outside this
folder and git-ignored**. They are regenerated deterministically from `main` (T003), so
nothing is lost by discarding them, and a committed baseline would stop being the
independent "before" picture the byte-equality requirements rest on.

### Source Code (repository root)

```text
scripts/bash/
├── commands/feature.sh          # the decision point, both new message classes
├── lib/cli.sh                   # the --reuse flag; accept_defaults already exists
├── sink/jira/ticket.sh          # the mentioned-key read's field set (contract §7)
└── sink/jira/designator.sh      # read-only: URL reduction reused, not modified

scripts/powershell/
├── commands/Feature.psm1        # mirror of feature.sh
├── lib/Cli.psm1                 # mirror of cli.sh
├── sink/jira/Ticket.psm1        # mirror of ticket.sh
└── sink/jira/Designator.psm1    # read-only

tests/conformance/mock-jira/
├── curl-shim.sh                 # must recognise the wider field set (contract §7)
├── mock-server.ps1, Mock.psm1   # the mirror
└── fixtures/issue-mentioned.json# gains project + issuetype

commands/
└── speckit.jira.feature.md      # the agent ceremony: how the question is asked

tests/bash/commands/
├── test_feature.bats            # extended: question, answers, config guidance
└── test_feature_designators.bats# extended: URL mention, reuse-without-issues

tests/conformance/scenarios/
└── us3-feature-*.json           # extended with the new paths; existing ones unmodified

docs/
├── 06-feature-naming.md         # the ceremony diagram gains the question
├── 08-safety-model.md           # the state diagram gains the question state
└── 03-lifecycle-hooks.md        # before_specify may now exit 0 with no name

README.md                        # the seeding section currently states the opposite
commands/speckit.jira.seed.md    # reached through the question, not only by flags
```

**Structure Decision**: No new module, in either port. The feature is a decision
point inside an existing command plus a flag in an existing parser. Creating a
module for one question would be an abstraction with a single implementation, which
Principle XIV forbids.

## Complexity Tracking

> Filled because one item deserves a written justification, not because a gate failed.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Reordering `cmd_feature`'s four early pass-through exits so mention detection precedes them | FR-026 owes a message to an operator who named a ticket, and today all four exits fire before the arguments are ever parsed | Leaving the order alone and emitting the message from each exit site would duplicate the message four times and still not know whether a ticket was mentioned. Moving one pure string operation earlier is smaller — but it is the only change in this feature that can break the byte-identical guarantee of FR-028 for repositories that do not use the extension at all, so it is recorded here rather than treated as routine. |
| A **conditional** field set on the mentioned-key read (`fields=project` vs `fields=project,summary,issuetype,status`) | FR-003 needs summary, type and status; the shipped read asks for the project alone and returns nothing else, so the question literally cannot be composed today. Making the widening conditional on "about to ask" is what keeps FR-008/FR-010/FR-028 provable | Widening unconditionally is one line instead of a branch — and it changes the recorded request of **every** run that mentions a ticket, destroying the regression proof FR-010 rests on. It also silently defeats both conformance mocks: `curl-shim.sh:620` matches the query string `fields=project` exactly, synthesises the project from the key prefix, and `404`s an unknown project; a wider query falls through to the generic handler, which serves the `issue-mentioned` fixture — different key, no project, no issuetype. `us3-feature-attach` would quietly become a cross-team question and the `404` fail-closed path would vanish. Two mocks and one fixture must move with the ports, which is why this row exists rather than a one-line diff. |
