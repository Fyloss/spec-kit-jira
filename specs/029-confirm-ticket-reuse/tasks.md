---
description: "Task list for 029 — ask once whether an existing ticket should be reused"
---

# Tasks: Ask once whether an existing ticket should be reused

**Input**: Design documents from `/specs/029-confirm-ticket-reuse/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: **NOT optional here.** Constitution XIII governs this repository:
development is strictly Red-Green-Refactor, and "no implementation task may be
planned without its test task preceding it in `tasks.md`". Every test task below is
written to be observed FAILING before its implementation task is started.

**Traceability**: each task cites its contract section **and** its FR ids. Citing
only contract sections is this repository's habit and it defeats a requirement→task
sweep; both are given so coverage can be checked either way.

**Organization**: grouped by user story — **nine of them**, and the phases are not
one-to-one with them. Phases are execution groupings; stories are value groupings. Two
phases carry more than one story because the work lands in the same function of the same
file and is not separately testable (Phase 3 = US1 + US7 + US9, Phase 6 = US3 + US8).
Phase 9 exists because five constitutional obligations — and the two success criteria
that span more than one story — belong to no story and are otherwise dropped
systematically.

The requirement→story table in [spec.md](./spec.md) is the coverage proof, and it
records the one requirement (FR-019, cross-port byte equality) that deliberately belongs
to no story: it is a constraint on every path rather than an increment anyone can ship.

**Numbering**: T081–T132 were added after `/speckit-analyze` and the design revisions
that followed it, and T012/T013 were moved above T010/T011. Added tasks keep new ids but sit physically in the phase they belong
to, so the ids are **not monotonic in file order** — deliberately. What Constitution
XIII requires is that a test task precede its implementation task *in `tasks.md`*, and
that is file order, not id order. Read top to bottom, never by number.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable — different files, no dependency on an incomplete task
- **[Story]**: US1–US9 from spec.md; setup, foundational, cross-cutting and polish
  phases carry no story label

## Path Conventions

Two native ports, mirrored: `scripts/bash/…` and `scripts/powershell/…`, proven
equivalent by `tests/conformance/`. A task touching one port always has a twin.

---

## Phase 1: Setup (baseline capture)

**Purpose**: make byte-comparison possible at all. Three requirements (FR-008,
FR-010, FR-028) and two success criteria (SC-004, SC-005) are stated against "the
current release" — without a recorded baseline they are unfalsifiable.

- [ ] T001 Record the current-release output of every existing feature conformance scenario as a golden baseline under `/.baseline/029/` — **git-ignored, never committed**: a checked-in baseline stops being the "before" picture and quietly becomes the thing under test. Run `tests/conformance/scenarios/us3-feature-*.json` on the tree at `main`, before any change
- [ ] T002 [P] Record the current-release output of the four early pass-through exits with no mention (missing `config.yml`, unreadable `config.yml`, empty `teams:`, no selection) into the same baseline directory
- [ ] T003 [P] Confirm the baseline is reproducible: re-run T001 and T002 and assert zero differing bytes, so a later divergence is attributable to the change and not to harness noise. Reproducibility is also what makes discarding it safe — anyone can regenerate it from `main`
- [ ] T004 Verify `tests/run-bash.sh`, the Pester suite, `bash tests/conformance/ci-conformance.sh`, `shellcheck` and `actionlint` are green on the unmodified tree — a red baseline invalidates every assertion that follows
- [ ] T121 **Clear the tree before T001 runs.** The working tree carries an uncommitted stopgap — a warning callout in `commands/speckit.jira.feature.md` and a paragraph in `docs/06-feature-naming.md` describing the *pre-029* behaviour. Commit or stash it first, so the baseline is attributable to `main` and not to a half-applied state. T075 then **rewrites** that callout rather than re-adding it: once the question ships, its central claim — that a mentioned ticket cannot be bound — stops being true
- [ ] T122 [P] Assert `/.baseline/` is git-ignored and that `git status --porcelain` reports nothing under it, at the end of the work as well as at the start — a golden capture that reaches a commit is worse than none, because reviewers trust it

**Checkpoint**: the "before" picture exists and is stable.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: the mention grammar, the answer flag, and the facts the question is made
of. Every user story reads at least one. Nothing in Phase 3+ can start until this
phase is complete.

**⚠️ CRITICAL — two changes, not one**: T007/T008 reorder `cmd_feature`'s four early
exits, and T084/T085 change what the mentioned-key read asks Jira for. The first can
break every repository not using the extension; the second can break every run that
mentions a ticket, and it defeats both conformance mocks unless T086–T088 move with
it. Both are recorded in plan.md Complexity Tracking, and T014 gates them together.

### Tests first

- [X] T005 [P] Write failing bats tests for the mention grammar in `tests/bash/commands/test_feature.bats`: bare key recognised, `/browse/` URL recognised, `selectedIssue=` URL recognised, a URL reducing to nothing key-shaped NOT recognised, an ordinary word NOT recognised — **and the gate**: with the leading positional a key, every further positional key is detected in argv order, keys and links mixed freely; with the leading positional an ordinary word, **nothing at all** is detected however many keys follow; and in every case the slug derives from the leading positional alone, so reordering the words cannot rename the branch (contracts/mention-grammar.md §1–§3; FR-032, FR-034, research.md R10)
- [X] T006 [P] Write the Pester twin of T005 in `tests/powershell/commands/Feature.Tests.ps1`
- [X] T012 [P] Write failing bats tests for `--reuse` parsing in `tests/bash/commands/test_feature.bats`: `yes`, `no`, an invalid value (usage error, exit 1), and absence meaning unanswered (FR-009, FR-016)
- [X] T013 [P] Write the Pester twin of T012
- [X] T081 [P] Write the failing bats test for **the conditional field set**: with a mention, no designator, no `--reuse` and no `--accept-defaults`, the single mentioned-key request is `fields=project,summary,issuetype,status`; on every other path it is `fields=project`, character for character. Assert the request **count** is one in both cases — which is also the only place SC-007's "zero added Jira requests" is measured (contracts/feature-question-contract.md §7; FR-003, FR-017, SC-007, SC-015, research.md R8)
- [X] T082 [P] Write the Pester twin of T081
- [X] T083 [P] Write the guard — not a red test, a tripwire that must stay green: every pre-existing feature scenario's recorded mentioned-key request is still `?fields=project`. This is the single assertion that catches an unconditional widening, which is the mistake the first plan made (FR-010, SC-015)

### Implementation

- [X] T007 Extract mention detection into a single evaluation at the top of `cmd_feature` in `scripts/bash/commands/feature.sh`, before the four early pass-through exits, reusing `designator_reduce_url_candidate` from `scripts/bash/sink/jira/designator.sh` — never a second reduction implementation (contracts/mention-grammar.md §3; FR-032, research.md R2/R4)
- [X] T008 Mirror T007 in `scripts/powershell/commands/Feature.psm1`, reusing the PowerShell designator reduction
- [X] T009 [P] Assert no glob pattern added by T007/T008 contains `$'\r\n'` — `docs/10-windows-portability.md` records that the MSYS matcher bends such a pattern onto a bare LF
- [X] T010 Add `--reuse <yes|no>` to `scripts/bash/lib/cli.sh`, emitting `reuse=<value>` alongside the existing `use_team`/`accept_defaults` keys; an unrecognised value is a usage error naming both accepted values (contracts/feature-question-contract.md §1, §6; FR-009, FR-016)
- [X] T011 Mirror T010 in `scripts/powershell/lib/Cli.psm1`
- [X] T084 Widen `ticket_validate` **conditionally** in `scripts/bash/sink/jira/ticket.sh:46` — `fields=project,summary,issuetype,status` when the caller states it is about to ask, `fields=project` otherwise — and return the three new facts additively, leaving `project` where it is (contracts/feature-question-contract.md §7; FR-003, FR-017)
- [X] T085 Mirror T084 in `scripts/powershell/sink/jira/Ticket.psm1:42` (`Confirm-JiraTicket`)
- [X] T086 Teach the bash mock the wider field set **inside the existing synthetic branch** at `tests/conformance/mock-jira/curl-shim.sh:620`, preserving its `404` for a project absent from the run config. A wider query must never fall through to `_shim_issue_get` — that path serves the `issue-mentioned` fixture, whose key is `MENT-1` with no `project` and no `issuetype`, which would silently turn `us3-feature-attach` into a cross-team question (research.md R8)
- [X] T087 Mirror T086 in `tests/conformance/mock-jira/mock-server.ps1` and `Mock.psm1`
- [X] T088 [P] Add `project` and `issuetype` to `tests/conformance/mock-jira/fixtures/issue-mentioned.json` so the generic handler stops being a trap, and assert no existing scenario's output moves as a result
- [X] T014 Re-run T001–T003's baseline comparison after the reordering **and after the read widening** and assert zero differing bytes for every no-mention path, and an unchanged query string on every path that does not ask — this is the gate on Phase 2, not a formality (FR-028, SC-004, SC-015)

**Checkpoint**: a mention is recognised in both forms, an answer can be conveyed, and nothing that names nothing has moved.

---

## Phase 3: User Stories 1, 7 and 9 — the question, what it says, and saying it well (P1)

**Goal**: a mentioned ticket with no designator returns a closed question instead of
naming the feature (US1), that question is a per-ticket proposal the operator can act on
in one step (US7), and the message emitted when the ticket cannot be read stops promising
the opposite of what happens (US9).

**Why three stories in one phase**: phases are execution groupings, stories are value
groupings, and they are not required to be one-to-one. US1 and US7 touch the same
function in the same file and are not separately testable — a question with no content
cannot be evaluated, and content with no question has nowhere to appear. US9's two tasks
sit here because the message they fix lives beside the decision point.

**Independent test**: against a mock holding one resolvable issue, invoke the naming
step with that issue mentioned and no designator; assert a stated question, nothing
named, nothing created, nothing written, exit 0.

### Tests first

- [X] T015 [P] [US1] Write the failing regression test for the reported defect in `tests/bash/commands/test_feature.bats`: a mentioned key with no designator MUST NOT reach a silent naming (FR-001; Constitution XIII "every fixed bug ships with a regression test written before the fix")
- [X] T016 [P] [US1] Write failing bats tests for the question payload: names the issue by key, summary, type and status; offers exactly two answers; exit 0; zero Jira mutations; zero local writes (contracts/feature-question-contract.md §3; FR-002, FR-003, FR-004, FR-005)
- [X] T017 [P] [US1] Write the failing bats test for **the omission** — the result carries no branch name and no folder short name (contracts/feature-question-contract.md §3; FR-031, SC-012). Without this assertion the feature is unenforced: a caller can simply proceed
- [X] T131 [P] [US9] Write the failing bats + Pester test for **the fallback message that promises the opposite** (FR-041): assert the string "will attach it later" appears nowhere, that the message names which of the three causes occurred — credentials rejected, issue not found or not visible, Jira unreachable — and that it states new issues will be created and how to reuse the ticket instead. The old text told the operator not to worry about exactly the defect this feature fixes (`commands/feature.sh:595`)
- [X] T018 [P] [US1] Write failing bats tests for the suppression cases: unresolvable mentioned key keeps today's fail-closed exit with no question; a designator present suppresses the question (FR-006, FR-007)
- [X] T019 [P] [US1] Write the Pester twins of T016–T018 in `tests/powershell/commands/Feature.Tests.ps1`
- [X] T089 [P] [US7] Write failing bats tests for the **halted-status warning**: an issue whose status is in the routed project's configured halted list gets a question stating that "reuse" would be refused and naming the three ways on; the same issue in a status the configuration does not list gets the status and no warning; an empty configured list never warns (contracts/feature-question-contract.md §3; FR-033, SC-013, US1 AC7, research.md R9)
- [X] T090 [P] [US7] Write the Pester twin of T089
- [X] T091 [P] [US7] Write failing bats tests for **multi-issue detection**: three keys in one request produce three proposal lines in argv order, one answer settles all three, and the branch and folder short name are identical to the single-key run; a mix of keys and links behaves identically; a key cited for context (`IJT-40 see IJT-99 for background`) appears in the list and is dropped by naming explicit designators; and — the boundary that matters — a leading positional which is **not** a key produces no detection and output byte-identical to the current release, because the key shape also matches `COVID-19` (contracts/mention-grammar.md §1, §4; FR-034, FR-008, SC-014, US1 AC8)
- [X] T110 [P] [US7] Write failing bats tests for **role derivation** (FR-035): an issue whose type equals the declared specification type is proposed in the specification role, one matching the declared story type in the story role, and a project declaring **no** hierarchy yields no proposal at all — the plainer question, never a guess. Assert the operator-facing text uses the project's own type names and that `specification`/`story` never appear in output (contracts/feature-question-contract.md §3.1; FR-035, Principle VII)
- [X] T111 [P] [US7] Write the Pester twin of T110
- [X] T112 [P] [US8] Write failing bats tests for **unmapped vs misplaced** (FR-036) — the pair this feature turns on: a `Bug` where the project declares Epic and Story is proposed in the story role with its type named as mapped to no role, **does not refuse**, and when accepted alone creates nothing above it and re-parents nothing; an issue carrying the **other** role's declared type refuses instead, at the question, before any answer (FR-022). Assert the two produce different outcomes from the same `REF-ROLE`-shaped input (research.md R11; US1 AC10, AC12, SC-018)
- [X] T113 [P] [US8] Write the Pester twin of T112
- [X] T128 [P] [US7] Write the failing bats + Pester test for **the `Drafted:` line** (FR-040): whenever at least one issue is proposed in the story role, the question states that user stories drafted beyond the named ones become new story-role issues beneath the same parent; and it is absent when the proposal holds no story-role issue. Then assert the arithmetic it promises against 027's SC-002 — two named stories in a specification drafting five produce **three** creates, not five and not seven (SC-020)
- [X] T129 [P] [US8] Write the failing bats + Pester test for **the Bug-is-really-an-Epic route** (FR-039): designating an unmapped-type issue with `--parent` refuses; the refusal names the constraint — the specification role is the container and this feature never changes an issue's type — and carries `--reuse yes --parent "<title>" --story <key>` as a copy-pasteable step; and that step, run, creates the parent with the issue beneath it (SC-019)
- [X] T114 [P] [US7] Write the failing bats + Pester test for **no parent among them** (FR-038): a proposal of story-role issues only carries the three parent routes in its own answers and returns **no second question**; accepting as-is creates nothing above them; `--reuse yes --parent "A title"` in the same answer creates the parent and attaches them (FR-038, SC-016)
- [X] T092 [P] [US7] Write the Pester twin of T091
- [X] T095 [P] [US1] Write the failing bats + Pester test for the dry-run prediction **before** T023 exists: `--dry-run` states that the question would be asked and for which issue, performs it not at all, and issues no Jira write (FR-020; Constitution XIII — T023 was previously planned with no test at all)
- [X] T104 [P] [US1] Write the failing bats + Pester test for **the payload keys**: the reuse question emits `reuse_required`, the which-issues question emits `reuse_issues_required`, the shipped cross-team question still emits `confirmation_required` with its bytes unchanged, the three never co-occur, and neither new payload carries a `branch_name` or `short_name` key **even as `null`**. Assert the pinned prose lines literally, both ports (contracts/feature-question-contract.md §3.1; FR-031, FR-019, SC-012)
- [X] T097 [P] [US1] Write the failing bats test for **the question order**: with a mentioned ticket belonging to another team *and* no designator, the first invocation returns the cross-team question **only** — no `reuse_required` key, no reuse prose — and the invocation answering `--use-team` returns the reuse question. The two are never merged into one payload (contracts/feature-question-contract.md §4, §3.1; FR-025)
- [X] T098 [P] [US1] Write the Pester twin of T097
- [X] T100 [P] [US1] Write the failing test that the naming step **never waits**: run every question path with stdin closed and again with stdin held open by an unrelated writer, and assert identical output, exit 0, and no read of stdin in either port. A `read`/`Read-Host` reaching this path would hang a lifecycle hook, which is the one failure Principle IV forbids by name (FR-021)
- [X] T096 [P] [US1] Write the failing test that every message class added by this feature survives a CRLF-emitting `jq`: assert no `\r` reaches stdout for the question, the which-issues follow-up, the halted warning, the extras notice and both configuration reports (Constitution VI, `docs/10-windows-portability.md`; the guard for T022, which was also planned with no test)

### Implementation

- [X] T020 [US1] Implement the reuse question in `scripts/bash/commands/feature.sh`, evaluated immediately after the cross-team question and before naming, under its own `reuse_required` payload key and with the pinned prose lines, composing the payload from the resolution the run already performed (contracts/feature-question-contract.md §2–§4 and **§3.1**; FR-001 to FR-005, FR-017, FR-025, research.md R6)
- [X] T021 [US1] Mirror T020 in `scripts/powershell/commands/Feature.psm1`
- [X] T022 [US1] Route every multi-line message added by T020/T021 through `scripts/bash/lib/output.sh` and its PowerShell twin — never a bare `jq`, whose Windows build emits CRLF on multi-line output
- [X] T023 [P] [US1] Extend `--dry-run` to predict that the question would be asked and for which issue, without performing it, in both ports (contracts/feature-question-contract.md §3; FR-020)
- [X] T117 [US7] Implement **role derivation and proposal composition** in both ports: match each detected issue's type against `_feat_declared_type_for specification|story` for the routed project (already loaded — no request), emit one `issues[]` entry per detection carrying `role`, `unmapped` and `halted`, plus `declines_to` so the decline line can name the project's own types (contracts/feature-question-contract.md §3.1; FR-002, FR-003, FR-035)
- [X] T118 [US8] Implement the **unmapped/misplaced split** in both ports — the one behaviour that must not be delegated to `adoption_evaluate`, which collapses both into a single `REF-ROLE`: compare the type against **both** declared types before proposing, refuse at the question when it equals the other role's, propose in the story role when it equals neither, and carry FR-038's parent routes when no specification-role issue was detected (FR-022, FR-036, FR-038, research.md R11)
- [X] T130 [US1] Implement the `Drafted:` line and the FR-039 refusal in both ports. The refusal is composed **beside** the existing `REF-ROLE` message, not inside it: `adoption_evaluate` cannot distinguish an unmapped type from a misplaced one (research.md R11), so a route named from there would be offered to operators it cannot help (FR-039, FR-040)
- [X] T132 [US9] Replace `_feat_fallback`'s message in both ports (`commands/feature.sh:593-598` and its twin): drop the false parenthesis, carry the cause from the exit code the call already returned, and state the real outcome plus the designator route (FR-041)
- [X] T093 [US7] Implement the halted warning and the multi-issue detection in both ports, composing the first from the wide read's `status` against `_feat_halted_csv_for` (already in memory — no new read, no new configuration key) and the second from the argv scan of T007, gated on the leading positional being a mention (FR-033, FR-034)
- [X] T024 [P] [US1] Add conformance scenarios under `tests/conformance/scenarios/` for the question path in bare-key and URL forms, beside the existing `us3-feature-*.json` — never editing them (contracts/mention-grammar.md §4; FR-019)
- [X] T094 [P] [US1] Add conformance scenarios for the halted-status warning, for a mention with a second key in the description, and for the no-mention-with-a-key boundary that must stay silent (FR-019, FR-033, FR-034)
- [X] T099 [P] [US1] Add the conformance scenario pair for the two-question order: the cross-team question alone, then the reuse question on the `--use-team` invocation. Both rounds recorded, because the requirement is about the *sequence* and a single-round scenario cannot express it (FR-025, FR-019)

**Checkpoint**: US1 is independently demonstrable — this is the MVP.

---

## Phase 4: User Story 2 — Answering "create new" changes nothing but the asking (P1)

**Goal**: both answers are honoured; `no` restores today's bytes; `yes` without issues asks which.

**Independent test**: run the current release and the answered invocation against the
same mock and the same key; assert identical output bytes, exit code and request
sequence from the answered invocation onward.

### Tests first

- [X] T025 [P] [US2] Write the failing bats byte-comparison test for `--reuse no` against the Phase 1 baseline (contracts/feature-question-contract.md §2; FR-010, SC-005)
- [X] T026 [P] [US2] Write the failing bats test that an answered invocation never re-poses the question (FR-011)
- [X] T027 [P] [US2] Write failing bats tests for the which-issues follow-up: `--reuse yes` with no designator returns a question, writes nothing, records nothing (contracts/feature-question-contract.md §3; FR-029, FR-030)
- [X] T028 [P] [US2] Write the failing bats idempotence test: repeat the same incomplete `--reuse yes` invocation three times, assert three byte-identical results and an empty state directory (FR-030)
- [X] T029 [P] [US2] Write the failing bats test for FR-015's **first** clause: an answer supplied with neither a mention nor a designator is a usage error naming the conflict, exit 1, decided from argv before any Jira read (contracts/feature-question-contract.md §2 row 2; FR-015)
- [X] T102 [P] [US2] Write the failing bats test for FR-015's **second** clause and its exception: `--reuse no` alongside `--parent`/`--story` is a usage error naming both halves of the contradiction, while `--reuse yes` alongside designators is **accepted in silence** and routes into the designator path unchanged — redundancy is not an error (contracts/feature-question-contract.md §2 rows 3, 5, 7; FR-015, FR-006)
- [X] T030 [P] [US2] Write the Pester twins of T025–T029

### Implementation

- [X] T031 [US2] Implement the `no` branch in `scripts/bash/commands/feature.sh` so the run continues into today's naming path unchanged (FR-010, FR-011)
- [X] T032 [US2] Implement the which-issues question for `--reuse yes` with no designator, stateless and repeatable (FR-029, FR-030)
- [X] T103 [US2] Implement §2's three usage-error rows as a single argv-only gate at the top of `cmd_feature`, evaluated in row order so an invalid value never hides behind an unreadable key, and never reached by a redundant `--reuse yes` (FR-015, FR-016)
- [X] T033 [US2] Mirror T031, T032 and T103 in `scripts/powershell/commands/Feature.psm1`
- [X] T034 [P] [US2] Add conformance scenarios for `--reuse no`, `--reuse yes` without designators, and the answer-without-mention usage error (FR-019)

**Checkpoint**: the question has honoured answers — US1 + US2 is a shippable slice.

---

## Phase 5: User Story 6 — Told what to configure, instead of silence (P2)

**Goal**: naming a ticket in an unconfigured repository produces guidance, not silence.

**Independent test**: no Jira double required at all. Invoke with a mentioned key in
a repository whose configuration declares no applicable team; assert the report names
the file and the command.

**Why here**: it is the story most likely to be dropped by a partial implementation,
and it is verifiable without a mock — so it is scheduled early rather than last.

### Tests first

- [X] T035 [P] [US6] Write failing bats tests for the committable-layer gap in `tests/bash/commands/test_feature.bats`: missing `config.yml`, unreadable `config.yml`, and an empty `teams:` catalogue each name `.specify/jira/config.yml` and state the configuration command (contracts/feature-question-contract.md §5; FR-026, research.md R5)
- [X] T036 [P] [US6] Write the failing bats test for the personal-layer gap: a catalogue exists but no team is selected ⇒ names `.specify/jira/personal.yml` and states that the selection is the operator's own and no script writes it (FR-026, research.md R5)
- [X] T037 [P] [US6] Write the failing bats tests for the boundary — the same four states with **no** mention produce output byte-identical to the Phase 1 baseline (FR-028, SC-004)
- [X] T038 [P] [US6] Write the failing bats test that neither report issues a Jira request and neither fails the host command (FR-027)
- [X] T039 [P] [US6] Write the Pester twins of T035–T038

### Implementation

- [X] T040 [US6] Implement both report variants at the four early exits in `scripts/bash/commands/feature.sh`, gated on a mention being present (contracts/feature-question-contract.md §5; FR-026, FR-027, FR-028)
- [X] T041 [US6] Mirror T040 in `scripts/powershell/commands/Feature.psm1`
- [X] T042 [P] [US6] Add conformance scenarios for both report variants and for their no-mention counterparts (FR-019)

**Checkpoint**: an operator is never met with silence after naming a ticket.

---

## Phase 6: User Stories 3 and 8 — the routed path, and every refusal's route (P2)

**Goal**: `yes` routes into 027's path (US3), and no ticket that does not fit leaves the
operator at a dead end (US8) — the unmapped type is proposed rather than refused, the
misplaced one refuses at the question, and every refusal carries the escape that always
exists.

**Independent test**: against a mock holding one parent-role and one story-role issue,
answer `yes` with both as designators and assert the resulting state is identical to
the state those designators produce today with no question involved.

### Tests first

- [X] T043 [P] [US3] Write the failing bats test that `--reuse yes` with designators produces a seeded-not-bound state identical to the same designators supplied directly, with no residue of the question (FR-012)
- [X] T044 [P] [US8] Write the failing bats test for the role-mismatch refusal: zero writes, names the issue, the type found, and the type the configured hierarchy declares for the role (FR-022)
- [X] T045 [P] [US8] Write the failing bats test that the refusal states **both** ways forward as copy-pasteable steps, including supplying a title so the missing parent is created (FR-023)
- [X] T115 [P] [US8] Write the failing bats + Pester test for **the escape every refusal must carry** (FR-037): enumerate every refusal class reachable on the reuse path — other-role type, halted status, two projects, the same issue twice, already claimed by another specification — and assert each names its cause **and** states that declining has the extension create the specification-role issue plus one story-role issue per drafted user story. The test enumerates the classes by name so a class added later fails it rather than slipping past (SC-017)
- [X] T046 [P] [US3] Write the failing bats test that a title supplied for the parent role creates it and places the reused issues beneath it in the same confirmed step — asserting the **existing** capability is reachable from this path, not building a new one (FR-024; see checklists/requirements.md, "FR-024 adds no machinery")
- [X] T047 [P] [US3] Write the failing bats test that the mentioned ticket may itself be named among the reused issues with no special case and no double resolution (US3 AC2)
- [X] T048 [P] [US3] Write the Pester twins of T043–T047

### Implementation

- [X] T049 [US3] Route the `yes`-plus-designators case into `_feat_seed_from_designators` in `scripts/bash/commands/feature.sh` without duplicating any of its work (FR-012)
- [X] T050 [US3] Compose the role-mismatch refusal from the existing `adoption_evaluate` `REF-ROLE` outcome, extending its message with the create-a-parent route (FR-022, FR-023)
- [X] T051 [US3] Mirror T049 and T050 in `scripts/powershell/commands/Feature.psm1`
- [X] T119 [US8] Extend every refusal class reachable on the reuse path with FR-037's decline-and-create-fresh line, composed once and appended by the aggregator rather than written into each class — five copies of one sentence is how the fifth ends up different (FR-037, both ports)
- [ ] T052 [P] [US3] Add conformance scenarios for the routed path and for the role-mismatch refusal (FR-019)
- [X] T120 [P] [US3] Add conformance scenarios for the proposal shapes: three detected issues with mixed roles, a `Bug` proposed as unmapped, a misplaced type refusing at the question, a story-only proposal carrying the parent routes, and one refusal carrying the FR-037 escape (FR-019, FR-035, FR-036, FR-037, FR-038)

**Checkpoint**: the answer the operator actually wanted reaches a bound specification.

---

## Phase 7: User Story 4 — An unattended run never waits (P2)

**Goal**: a caller declaring itself unattended is never asked.

**Independent test**: invoke with a mentioned key and the unattended declaration;
assert the current release's result with no question in it.

### Tests first

- [X] T053 [P] [US4] Write the failing bats test that `--accept-defaults` with a mentioned key suppresses the question and proceeds as `no` would (contracts/feature-question-contract.md §1–§2; FR-013)
- [X] T054 [P] [US4] Write the failing bats test that a suppressed question is stated in the result, naming the assumed answer, so a log distinguishes suppression from non-application (FR-014)
- [X] T055 [P] [US4] Write the failing bats test for **the trap**: with `--accept-defaults` absent and no terminal attached, the question still fires. A TTY probe would suppress it always and reduce the feature to a no-op that passes review (research.md R3)
- [X] T056 [P] [US4] Write the Pester twins of T053–T055

### Implementation

- [X] T057 [US4] Honour the existing `accept_defaults` value in the decision point of both ports — no new flag, no new mechanism (FR-013, FR-014, research.md R3)
- [X] T058 [P] [US4] Add a conformance scenario for the unattended path (FR-019)

**Checkpoint**: no pipeline can stall on this feature.

---

## Phase 8: User Story 5 — A run naming nothing is untouched (P3)

**Goal**: prove, rather than assume, that the installed base is unaffected.

**Independent test**: the existing conformance scenarios, unmodified.

- [X] T059 [P] [US5] Assert every pre-existing `tests/conformance/scenarios/us3-feature-*.json` runs unmodified with byte-identical stdout, exit code and request sequence against the Phase 1 baseline (FR-008, SC-004)
- [X] T060 [P] [US5] Assert no pre-existing feature scenario file was edited to carry the new flag — editing them destroys the evidence they exist to provide (contracts/mention-grammar.md §4)
- [X] T061 [P] [US5] Write the bats test that a leading positional which is an ordinary word — the `ticket https://…` shape — produces no question and today's bytes (contracts/mention-grammar.md §1; research.md R2)
- [X] T062 [P] [US5] Write the Pester twin of T061
- [ ] T063 [US5] Run the full three-OS matrix and record the result; a red run here is a stop, not a warning

**Checkpoint**: the guarantee everyone else depends on is measured, not asserted.

---

## Phase 9: Cross-cutting constitutional obligations

**Purpose**: these belong to no user story, so a story-driven task list drops them
and still looks complete. Each is a gate `/speckit-analyze` has flagged as CRITICAL
on a previous feature of this repository.

**And two outcome proofs** (T105–T108), which are here for the same structural reason:
SC-002 and SC-003 span the naming step *and* the reconcile, so no single story owns
them and every story could pass with both unmeasured. SC-002 is the feature's whole
point — zero duplicate parents — and until now its only witness was a human
remembering to run the dogfood.

- [X] T064 **Principle IX (privacy guard)** — the decision is already taken, so this task only pins it: `data-model.md` records that `raw` is held **for reduction only** and that messages carry the reduced `key`, never the operator's URL. Assert by test that no message class echoes a supplied URL verbatim — the question identifies each issue by key, summary, type, status and proposed role, all of which are Jira facts rather than operator input. Note in the PR body why the guard itself is not engaged: Principle IX governs the **pre-write scan**, and this feature performs no write. Recording that reasoning is the point — an unexamined non-application and a justified one look identical afterwards
- [X] T065 **Principle IV (credentials)** — record the verdict explicitly rather than skipping it: this feature touches no credential path, adds no argv-borne value, and introduces no new log line carrying a token. Add the assertion that the new messages contain no credential-shaped value at maximum verbosity
- [X] T066 **Principle II (live zero-churn)** — record the verdict: this feature adds **no new write kind** to the sink interface, so `tests/live/test_live_zero_churn.bats` needs no new assertion. State it in the PR body; an unexamined omission and a justified one look identical afterwards
- [X] T067 **The fail-closed departure** — this feature adds new exit-0 branches (a returned question, a suppressed question, a configuration report) beside an unchanged fail-closed branch. Write the test for the **changed** branches, not only the unchanged one (FR-005, FR-007, FR-027; Principle III)
- [X] T068 **Per-row conformance** — `contracts/feature-question-contract.md §2` has **eleven** decision rows (three of them argv-only usage errors) and FR-019 requires byte equality on every path introduced. Audit that each row has a scenario, adding only the ones T024/T034/T042/T052/T058/T094/T099 did not already cover; per-row unit tests do not satisfy this obligation
- [X] T101 [US9] **Principle XVI (FR-018) sweep** — no story owns it, so nothing tests it: assert that **every** message class this feature adds names the problem, the issue, and a copy-pasteable next step. The classes are the reuse question, the which-issues question, the halted warning, the extras notice, the two configuration reports, the three usage errors, and the role-mismatch refusal — eleven in total, and the test enumerates them by name so a twelfth added later fails the assertion rather than slipping past it (FR-018, FR-023, FR-026)
- [X] T105 **SC-002, the headline outcome — the chain nobody was testing.** Write the failing multi-run conformance scenario proving the reported incident cannot recur: run 1 `feature IJT-42 "…"` returns the reuse question; run 2 `feature --reuse yes --parent IJT-42 "…"` seeds; run 3 uses `runs[].before.write` to place the drafted `spec.md` in the created folder, then `reconcile … --dry-run`. Assert the run-3 plan creates **zero** parents and that `IJT-42` is the parent it reuses. The harness already supports every piece of this — `runs[]`, `before.write`, and `calls.log.N` for run 3's own request slice (`tests/conformance/run-scenario.sh:188-235`); nothing new is needed but the scenario (SC-002, FR-012)
- [X] T106 **US2 AC3 — the other half, equally untested.** The same three-run shape with `--reuse no`: assert run 3's plan creates one parent plus one issue per drafted user story and leaves `IJT-42` untouched. This is the acceptance criterion that says "reconcile behaves exactly as it does today", and it had no task of any kind (US2 AC3, FR-010)
- [X] T107 [P] Write the bats twin of T105/T106 for the Bash port, so a failure is diagnosable without reading a cross-port diff — the conformance scenario proves the two ports agree, a bats test says which assertion broke
- [X] T108 [P] **SC-003 — bounded round-trips.** Assert the three chains and their lengths: complete answer ⇒ 1 re-invocation; cross-team first, or `--reuse yes` without issues ⇒ 2; both ⇒ 3. Then assert the invariant that matters more than the ceiling: every re-invocation is preceded by a question in the previous run's output, so no silent retry exists (SC-003, FR-025, FR-029)
- [X] T069 [P] Verify the Constitution Check rows in `plan.md` each have a requirement and a task behind them — a plan-level row with neither is the tell that a gate passed on paper
- [X] T070 [P] Run `find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +` and `actionlint`; both are blocking
- [ ] T071 [P] Confirm coverage stays at or above the 80% statement gate on both ports (Principle XIII)
- [ ] T072 Push to `ci/windows-probe` and triage against the known-red baseline before attributing any failure to this work; stop after one retry

---

## Phase 10: Polish & cross-cutting concerns

**Documentation is not polish here.** This feature changes what an operator *types*
and adds a step to the ceremony, so six documents describe behaviour that stops being
true — one of them, `README.md`, states the opposite outright. T073–T075 and T123–T127
are the gate: a release whose first-read document contradicts the product has shipped a
defect, whatever the suites say (Principle XVI).

- [X] T073 [P] Update `commands/speckit.jira.feature.md`: the question and its two answers in the ordered ceremony, the fixed order against the cross-team question, and — load-bearing — that the ticket MUST be passed as the leading positional (contracts/mention-grammar.md §1)
- [X] T074 [P] Update `docs/06-feature-naming.md`: the ceremony diagram gains the question and its two answers; the mention grammar section gains the gate rule, the URL form, multi-issue detection, and the fact that the leading positional alone computes the name
- [X] T123 **`README.md` — it currently states the opposite.** The "Seeding a specification from existing Jira issues" section (≈l. 365-394) claims `--parent`/`--story` is *"the one way to tell the bridge this is an existing issue"*. After this feature that sentence is false and must go: pasting keys and answering the question is the ordinary route, and the designators are the override that skips the question. Add the question, the per-issue proposal with detected roles, and the unmapped-type case. This is the document a consumer reads **first**, and a first document that contradicts the product is worse than a missing one
- [X] T124 [P] Update `commands/speckit.jira.seed.md`: the operator now reaches this command **through the question** rather than only by typing designators from the start. State that route at the top, and that `--parent`/`--story` remain optional and normally omitted (as the doc already says) precisely because the question supplies them
- [X] T125 [P] Update `docs/08-safety-model.md`: the state diagram's `absent: no designators supplied — ordinary ceremony` is no longer the only outcome of naming nothing. Add the state this feature introduces — a question returned, nothing named, nothing written, exit 0 — and the edge out of it for each answer. A safety model that omits a reachable state is not a safety model
- [X] T126 [P] Update `docs/03-lifecycle-hooks.md`: `before_specify` gains an outcome that exits 0 while deliberately returning **no** branch name and no folder short name (FR-031). That is new for any reader who assumes the hook always names the feature
- [X] T127 [P] Sweep the remaining docs for statements this feature falsifies — `docs/VISION.md` for anything now shipped, `INSTALL.md`, `docs/01`/`02` — and fix or delete each. Grep for `mentioned`, `attached`, `designator`, `--parent`. The three documents this feature obviously touches were already planned; this task exists because the one that contradicted the product outright (`README.md`) was found by asking, not by planning
- [X] T075 [P] Reconcile the earlier warning callout in `commands/speckit.jira.feature.md` with this feature — parts of it describe the pre-029 behaviour and become wrong once the question ships
- [X] T076 [P] Add the CHANGELOG entry
- [ ] T077 Bump the version in `extension.yml` only — it is the single source of truth and CI greps to prove the literal appears nowhere else
- [ ] T078 Dogfood against a real Jira instance, replaying the reported scenario end to end, on a company-managed and a team-managed project (Principle XII). With T105/T106 in place this run **confirms** the outcome against a real instance instead of being the first and only place anyone tries it — if the dogfood surprises you, T105 was wrong and is the thing to fix
- [X] T079 [P] Re-run the full `tests/run-bash.sh`, Pester, and `ci-conformance.sh` after the documentation changes
- [X] T133 **Rewrite `quickstart.md` before T080 walks it.** It was written for the two-answer abstract question and never revised: its `--reuse yes` example still expects the "which issues?" follow-up, which is now the exception rather than the rule, and it shows no proposal, no detected roles, no unmapped type. A stale quickstart is worse than none — T080 walks it as a gate, so a checklist describing a design that was abandoned certifies the wrong thing
- [ ] T080 Walk the "Before calling it done" checklist in [quickstart.md](./quickstart.md)

---

## Dependencies

```text
Phase 1 (baseline) ──> Phase 2 (mention + flag) ──┬──> Phase 3 (US1) ──> Phase 4 (US2)
                                                   ├──> Phase 5 (US6)   [no mock needed]
                                                   ├──> Phase 6 (US3)   [needs Phase 3]
                                                   ├──> Phase 7 (US4)   [needs Phase 3]
                                                   └──> Phase 8 (US5)   [needs Phase 2]
Phases 3–8 ──> Phase 9 (constitutional sweep) ──> Phase 10 (polish)
```

- **Phase 2 blocks everything.** T014 is its gate: if the reordering or the read
  widening moved a byte on a path that does not ask, no later phase's result can be
  trusted.
- **T086–T088 (the two mocks and the fixture) block every conformance task**, in every
  phase. Until the mocks recognise the wider field set, a scenario on the question path
  resolves a different issue than the one it names and passes for the wrong reason.
  T083 is the tripwire that says so out loud.
- **US6 (Phase 5) is independent of the mock** and can proceed in parallel with
  Phase 3 once Phase 2 is done.
- **US3 (Phase 6) depends on Phase 3** only because it needs the question to exist
  in order to be answered.
- **Phase 9 must run last but must not be skipped.** It is the phase that a
  story-driven reading systematically omits.

## Parallel execution examples

- **Phase 2**: T005 ∥ T006 (different ports, different files), then T007 ∥ nothing —
  T007 and T008 touch the two ports independently and may run in parallel, but T014
  gates both.
- **Phase 3**: T015 ∥ T016 ∥ T017 ∥ T018 ∥ T019 — five test files/regions, no shared
  state. Implementation T020 and T021 are per-port and parallel; T022 follows both.
- **Phase 5**: entirely parallel with Phase 3 — different requirements, different
  code sites, and no Jira double.
- **Phase 9**: T069 ∥ T070 ∥ T071 are independent checks; T072 is wall-clock bound
  (~11 min) and should be started as soon as Phase 8 is green.

## Implementation strategy

**MVP = Phase 1 + Phase 2 + Phase 3 (US1).** That delivers the reported defect's
fix: an operator who names a ticket is asked, and cannot be silently carried past the
question. It is demonstrable on its own.

**Increment 2 = Phase 4 (US2)** — the answers. US1 without US2 is a question nobody
can answer, so these ship together in practice even though US1 is independently
testable.

**Increment 3 = Phase 5 (US6)** — schedule early despite its P2, because it needs no
mock and is the piece a partial implementation drops.

**Increment 4 = Phases 6–8** — the routed path, the unattended guarantee, and the
measured proof that nothing else moved.

**Never skip Phase 9.** Every item there is a gate that has been missed before on
this repository, by this exact command, for the same structural reason.
