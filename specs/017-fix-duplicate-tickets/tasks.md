---
description: "Task list for 017 — the mirror only ever mirrors a specification, and every ticket carries the specification it came from"
---

# Tasks: The Mirror Only Ever Mirrors a Specification, and Every Ticket Carries the Specification It Came From

**Input**: Design documents in `/specs/017-fix-duplicate-tickets/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: **REQUIRED, and written first.** Constitution Principle XIII mandates Red-Green-Refactor
with an 80% floor, and the reported defect is a bug — its reproduction must fail before the fix
exists. Every port's change is paired with its twin, and every observable behaviour gains a
conformance scenario (Principle VI).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelisable — different files, no dependency on an incomplete task
- **[Story]**: the user story the task serves (US1–US4)

A bash task and its PowerShell twin are **always** parallelisable with each other, marked `[P]` or
not: they touch different ports and share no state. The marker is reserved for parallelism *within*
one port, which is the case that needs checking. This is why the worked example below runs T012
beside T013 although neither carries `[P]`.

## Path conventions

Twin native ports: `scripts/bash/**` and `scripts/powershell/**`, proven equivalent by
`tests/conformance/`. Every implementation task names its exact file; every bash task has a
PowerShell twin, and the two must not be merged into one task.

---

## Phase 1: Setup

**Purpose**: establish an attributable baseline and the shared fixture.

- [X] T001 Run `tests/run-bash.sh` and `bash tests/conformance/ci-conformance.sh` and record the result in the working notes, so any later red is attributable to this feature. Conformance success is silent: exit 0 and zero lines containing "conformance divergence".
- [X] T002 [P] Create the conformance fixture `tests/conformance/fixtures/repo-with-plan-artifact/` — a bound repository whose feature folder `specs/001-test-page/` holds both `spec.md` and a `plan.md`, with `plan.md` carrying two stray `<!-- speckit-jira … -->` marker lines (the exact damage the reported defect produced). Model it on the existing `tests/conformance/fixtures/repo-with-plan/`.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: bring the existing test corpus into line with the rule User Story 1 will enforce. This
migration is a **no-op today** and mandatory once the guard exists — doing it first keeps every
commit green and keeps the guard's own red-then-green attributable.

**⚠️ CRITICAL**: no user story may start until T005 is green.

- [X] T003 Migrate the bash reconcile tests off ad-hoc specification file names: in `tests/bash/commands/test_reconcile.bats`, `test_reconcile_durability.bats`, `test_reconcile_idempotent.bats`, `test_reconcile_plan_context.bats` and `test_reconcile_zero_churn.bats`, move each specification into its own subdirectory of `${BATS_TEST_TMPDIR}` and name it `spec.md` (`with.md`, `nosummary.md`, `spec2.md`, `spec3.md`, `spec4.md`, `priority.md`, `reordered.md`, `a.md`, `b.md`, `before.md`, `before-any-run.md`). Keep each file's existing `SPEC_KIT_JIRA_SPEC_SLUG` export — routing must not start depending on the new directory name. While you are in `test_reconcile.bats`, correct the comment at L132 ("FR-017 lists six causes"): T042 makes it seven.
- [X] T004 [P] Apply the identical migration to the PowerShell twins: `tests/powershell/commands/Reconcile.Tests.ps1`, `Reconcile.Durability.Tests.ps1`, `Reconcile.Idempotent.Tests.ps1`, `Reconcile.PlanContext.Tests.ps1`, `Reconcile.ZeroChurn.Tests.ps1`. Pester discovery order differs by host, so assert on state each test created rather than on the order files appear in.
- [X] T005 Re-run `tests/run-bash.sh` and the Pester suite: both must be green with **no** behaviour change, proving the migration is inert.

**Checkpoint**: the corpus now obeys the rule the guard will enforce. User stories may begin.

---

## Phase 3: User Story 1 — a run aimed at anything but a specification refuses (Priority: P1) 🎯 MVP

**Goal**: a target whose file name is not `spec.md` refuses before any configuration read, any
network call and any file write; and a valid run reports stray markers found in sibling artifacts.

**Independent Test**: invoke the bridge with `plan.md` against a mock that fails the test on any
inbound request — zero requests, exit 1, `plan.md` byte-identical, one named cause.

**Contract**: [contracts/target-guard.md](./contracts/target-guard.md)

### Tests for User Story 1 (write first — they MUST fail)

- [X] T006 [P] [US1] Write `tests/bash/commands/test_reconcile_target.bats` covering contract §5 T1–T6 and T10–T12: zero requests reached the mock; exit 1; the §3 message verbatim in both its forms; the rejected file byte-identical; `tasks.md`/`research.md`/`data-model.md`/`quickstart.md`/`contracts/api.md`/`spec.md.bak`/`my-spec.md`/`SPEC.MD` each refuse; with the event disabled the run is silent and returns 0 (research R1); `--dry-run plan.md` refuses identically.
  Two additions the contract's later rows carry. (a) **The six events (SC-001)**: loop `SPEC_KIT_JIRA_HOOK_CONTEXT` over `after_specify`, `after_clarify`, `after_plan`, `after_tasks`, `after_analyze`, `after_implement` and assert the refusal returns 0 and wraps identically for each. All six share one entry point and one guard, so this exercises one code path six times — that is the point: SC-001 claims the outcome holds "in every combination", and this is what makes the claim checkable rather than asserted. (b) **Path shapes (§5 T11–T12)**: a directory and a non-existent path keep today's readability message; a symlink whose own name is not `spec.md` refuses even though it resolves to one, while a symlink *named* `spec.md` passes; a path with trailing whitespace refuses; and the relative spelling `./specs/001-test-page/spec.md` **passes** — that last one is a positive assertion, and getting it wrong would refuse every correct caller.
- [X] T007 [P] [US1] Write the Pester twin `tests/powershell/commands/Reconcile.Target.Tests.ps1` with the same assertions, the six hook contexts and the §5 T11–T12 path shapes included. This port carries one case the bash twin cannot: the native separator spelling `specs\001-test-page\spec.md` must **pass** and `specs\001-test-page\plan.md` must refuse (research R3). Pester discovery order differs by host, so assert on state each test created.
- [X] T008 [P] [US1] Write `tests/bash/engine/test_marker_stray.bats` for the stray-marker scan: finds marker-bearing siblings, excludes `spec.md`, ignores subdirectories, returns sorted bare file names, opens nothing for writing, and returns empty for a clean folder.
- [X] T009 [P] [US1] Write the Pester twin `tests/powershell/engine/MarkerStray.Tests.ps1`.
- [X] T010 [P] [US1] Add conformance scenarios `tests/conformance/scenarios/us1-target-refusal.json` (refusal bytes identical across ports) and `us1-stray-markers.json` (warning fires, `plan.md` untouched), both against the T002 fixture. The corpus README documents the prefix as the **user story** number, not the feature number — `us1-` here is this feature's User Story 1, and neither name collides with the 74 existing scenarios.
- [X] T011 [US1] Run the four new test files and confirm every one of them **fails** for the right reason. Do not proceed until the red is understood.

### Implementation for User Story 1

- [X] T012 [US1] Add the target guard to `scripts/bash/commands/reconcile.sh`, immediately after the positional-argument resolution (~L401-413) and after the existing readability check: compare `basename` against the literal `spec.md` with byte equality — never a glob, a suffix test or a substring search (research R3; the MSYS pattern hazard in `docs/10-windows-portability.md` is why). Refuse through `_reconcile_fault` with `$(cli_exit_code usage)` and the contract §3 message, naming the sibling `spec.md` when one exists.
- [X] T013 [US1] Add the twin guard to `scripts/powershell/commands/Reconcile.psm1` at the positional loop (~L507-512), using `Split-Path -Leaf`, emitting byte-identical text and the same code.
- [X] T014 [P] [US1] Add the stray-marker scan to `scripts/bash/engine/marker_splice.sh` — the module that already owns the marker framing comment. Pure filesystem plus grammar, zero tracker vocabulary: top-level files of the given folder, excluding `spec.md`, no recursion, sorted bare names. Then run the repository's existing engine/sink boundary assertion and confirm it is still green — FR-016's guarantee is that no tracker vocabulary crosses into `engine/`, and this task is the one that could break it. Name the assertion you ran in the working notes.
- [X] T015 [P] [US1] Add the twin scan to `scripts/powershell/engine/MarkerSplice.psm1`.
- [X] T016 [US1] Wire the scan into `scripts/bash/commands/reconcile.sh` on the valid path, after routing, emitting the contract §4 warning into the run summary's existing `warnings` array — one entry naming every match, nothing when there is no match, no exit-code change, on the dry-run path too. (Depends on T014.)
- [X] T017 [US1] Wire the twin into `scripts/powershell/commands/Reconcile.psm1`. (Depends on T015.)
- [X] T018 [US1] Re-run T006–T010: all green. Then run `tests/run-bash.sh` in full — no pre-existing test may have turned red.

**Checkpoint**: the reported defect is closed. The feature is shippable here.

---

## Phase 4: User Story 2 — every ticket names its specification folder (Priority: P1)

**Goal**: every ticket the mirror creates or manages carries `speckit-<spec-slug>`, back-filled once
on tickets that predate the release, merged with operator labels, and free of churn.

**Independent Test**: mirror a specification and assert every created payload carries the label;
re-run unchanged and assert zero writes; strip the label on the mock and assert exactly one update
restores it and nothing else changes.

**Contract**: [contracts/provenance-label.md](./contracts/provenance-label.md) ·
**Shapes**: [data-model.md §3](./data-model.md)

### Tests for User Story 2 (write first — they MUST fail)

- [X] T019 [P] [US2] Write `tests/bash/sink/test_plan_apply_labels.bats` covering contract §6 T1, T2, T3, T5, T6, T8, T9: both creation roles carry the label; a recorded `labels` field default survives alongside it; a recognised ticket missing the label is updated **exactly once** and `counts.updated` reflects it (T3 — the conformance scenario of T025 proves the bytes, this proves the count); operator labels are preserved; a current label list in a different order still compares `unchanged` (the research R4 regression); a halted ticket is neither labelled nor written; `--dry-run` bodies equal the real run's. Add contract §6 T14: a ticket adopted from a human author through `mention` gains the label on its next ordinary update **additively** — the human's own labels survive and no field they wrote is altered. This is the spec's adopted-ticket edge case and the path Principle I guards most tightly, so it is asserted rather than inferred from the shared update branch.
- [X] T020 [P] [US2] Write the Pester twin `tests/powershell/sink/PlanApply.Labels.Tests.ps1`, contract §6 T14 included.
- [X] T021 [P] [US2] Extend `tests/bash/sink/test_recognition.bats` and `test_recognition_parent.bats`: both reads request `labels`, and the returned `current.labels` is `unique`-normalised.
- [X] T022 [P] [US2] Extend the Pester twins `tests/powershell/sink/Recognition.Tests.ps1` and `Recognition.Parent.Tests.ps1`.
- [X] T023 [P] [US2] Write `tests/bash/sink/test_plan_apply_labels_degraded.bats` for both of contract §4's degradation triggers. (a) The three-valued `defaultable_fields` rule (contract §6 T7): `labels` recorded in the type's entry → sent; recorded without it → omitted plus one warning, every ticket still mirrored, exit unchanged; not recorded at all → sent. The fixture's recorded entry MUST carry `defaultable: false` — the shape discovery actually writes for an array-shaped field — so an implementation that reads "present" as `defaultable: true` fails this test instead of silently omitting the label everywhere. (b) The length rule (contract §6 T13): a slug pushing `speckit-<slug>` past `JIRA_LABEL_MAX_LENGTH` → no `labels` key in any payload, every ticket still created, one warning naming the measured length and the limit, exit unchanged, and **nothing truncated** — assert no payload carries a label that is a prefix of the full one.
- [X] T024 [P] [US2] Write the Pester twin of T023.
- [X] T024b [P] [US2] Extend `tests/bash/sink/test_ticket.bats` and its Pester twin `tests/powershell/sink/Ticket.Tests.ps1` for contract §6 T12: a feature-ceremony creation through `_ticket_create_body` / `Get-JiraTicketCreateBody` carries **no** `labels` key — in particular never `speckit-spec` — while the rest of its base stays byte-identical to the mirror's. Both files already exercise these builders, so this extends an existing Describe rather than adding a file.
- [X] T025 [P] [US2] Add conformance scenarios `us2-label-create.json`, `us2-label-backfill.json` (one update per unlabelled ticket, counted) and `us2-label-second-run.json` (the run after back-fill is a byte-identical no-op).
- [X] T026 [P] [US2] Add `tests/bash/sink/test_privacy_block.bats` coverage for contract §6 T10: a BLOCK-tier string reaching the label is caught by the pre-write guard (research R8 — pinned, not assumed).
- [X] T027 [US2] Run T019–T026 (T024b included) and confirm every one **fails** for the right reason.

### Implementation for User Story 2

- [X] T028 [P] [US2] `scripts/bash/sink/jira/recognition.sh`: add `labels` to the `fields=` list in `_recognition_read` (L36) and `_recognition_read_parent` (L71), and include `labels: ((.labels // []) | unique)` in both `current` objects (L175, L360). The `unique` is load-bearing — see research R4.
- [X] T029 [P] [US2] Apply the twin change to `scripts/powershell/sink/jira/Recognition.psm1` (L39, L84), sorting with the port's ordinal comparer so both ports produce the same order.
- [X] T030 [US2] `scripts/bash/commands/reconcile.sh` `_reconcile_plan_context` (L332-361): derive `ticket_labels` from `recog.bound[*].current.labels` and thread it into the context, omitted when empty exactly like its neighbours; `parent_current` gains `labels` from the parent recognition read. (Depends on T028.)
- [X] T031 [US2] Apply the twin change to `scripts/powershell/commands/Reconcile.psm1`. (Depends on T029.)
- [X] T032 [US2] `scripts/bash/sink/jira/ticket.sh` `jira_create_fields_base` (L64): add an **optional fifth parameter** carrying the provenance label, and when it is non-empty merge `labels: ((<defaults labels> + [provenance]) | unique)` **after** the field-defaults spread, so a recorded `labels` default is preserved rather than overwritten. When it is empty, produce no `labels` key at all. The label is `"speckit-" + <spec_ref.spec_slug>`; the prefix literal lives here, in the sink, never in the engine. Update the function's header comment — it currently documents four parameters and names both callers.
  In the same file, leave `_ticket_create_body` (L103) passing **no** provenance argument, so the feature ceremony's single-item creation stays unlabelled (contract §2). This is not an oversight to fix later: `commands/feature.sh` L214 builds `spec_ref.spec_slug` as the literal fallback `"spec"` in the normal `before_specify` state, so passing it through would stamp `speckit-spec` onto every ceremony ticket. Say so in the header comment, beside the FR-025 shared-builder note that explains why the two callers otherwise share one base.
- [X] T033 [US2] Apply both twin changes to `scripts/powershell/sink/jira/Ticket.psm1`: `Get-JiraCreateFieldsBase` (L56) gains the optional provenance parameter, and `Get-JiraTicketCreateBody` does not pass it.
- [X] T034 [US2] `scripts/bash/sink/jira/plan_apply.sh`: add the desired `labels` union to the story-update branch of `plan_writes` (~L261) and to the recognised-parent branch of `_plan_writes_parent` (~L334), reading the current list from `ctx.ticket_labels[sid]` and `ctx.parent_current.labels`. Do **not** modify `idempotency_field_status` — the zero-churn drop must keep working through the shared primitive unchanged. (Depends on T030.)
- [X] T035 [US2] Apply the twin change to `scripts/powershell/sink/jira/PlanApply.psm1`. (Depends on T031.)
- [X] T036 [US2] Implement contract §4's **two** degradation triggers in `scripts/bash/sink/jira/plan_apply.sh`, each emitting its own §4 warning once per run, neither ever refusing or failing a write. (a) *The type cannot hold labels*: consult the binding's per-type `defaultable_fields` for a `labels` entry — recorded and offering none ⇒ omit plus warning; not recorded at all ⇒ send. Test for the key's **presence** only, never for its `defaultable` flag: discovery records `labels` with `defaultable: false` for every type that offers it (contract §4), so keying on the flag would omit the label on every project. (b) *The label is too long*: define the sink constant `JIRA_LABEL_MAX_LENGTH=255` and omit the label — never truncate it — when `speckit-<slug>` exceeds it. The slug regex bounds the alphabet, not the length, so this is FR-014's second branch and the only way it fires; sending an over-long label would have Jira reject the whole **creation**, costing a ticket its write for a cosmetic field.
- [X] T037 [US2] Apply the twin change to `scripts/powershell/sink/jira/PlanApply.psm1`, including the twin constant, so both ports omit at the same boundary and emit byte-identical warnings.
- [X] T038 [US2] Re-run T019–T026 (T024b included): all green. Then `tests/run-bash.sh` in full plus `bash tests/conformance/ci-conformance.sh`.

**Checkpoint**: every ticket the mirror manages is searchable by its specification folder.

---

## Phase 5: User Story 3 — the lifecycle procedure names one target (Priority: P2)

**Goal**: the agent-facing procedure states, once for all six `after_*` events, that the target is
the active feature's `spec.md` and never the artifact the host command just produced.

**Independent Test**: the agent-document contract tests assert the rule, the never-a-target list,
the new cause row, and the positional's documented restriction.

### Tests for User Story 3 (write first — they MUST fail)

- [X] T039 [P] [US3] Extend `tests/bash/commands/test_agent_doc_reconcile.bats` (FR-019–FR-021): the document states the single-target rule once for all six events; names plan, tasks, research, data-model, quickstart, contracts and analysis output as never targets; carries the rejected-target cause row with its exit signal and its one reported line; and documents the positional as accepting a feature specification file only. Assert too that the section heading's stated cause count matches the number of table rows, so the "six distinguished causes" heading cannot be left behind.
- [X] T040 [P] [US3] Extend the Pester twin under `tests/powershell/commands/` if one asserts on the same document; otherwise record in the task notes that the bash file is the single source of that assertion.
- [X] T041 [US3] Run T039 and confirm it fails.

### Implementation for User Story 3

- [X] T042 [US3] Update `commands/speckit.jira.reconcile.md`: state the single-target rule in the ordered procedure step 1, add the never-a-target list, add the rejected-target row to the message-discipline table (exit `1`, the one code that table does not yet claim), and restrict the `<SPEC-FILE>` positional's documented meaning in the Flags section. The section heading at L71 reads "Message discipline — the six distinguished causes" and becomes **seven**; update it in the same edit.
- [X] T043 [P] [US3] Update `docs/05-reconcile-flow.md`: add the target guard to the pipeline diagram ahead of the routing step, and note the stray-marker warning in the run-summary section.
- [X] T044 [P] [US3] Update `docs/03-lifecycle-hooks.md` where it shows the agent invoking the bridge, so the diagram's argument is unambiguously the active feature's `spec.md`. Also update the heading at L110 ("The six distinguished causes of a degraded run") to seven, and its cause list if it enumerates them.
- [X] T044b [P] [US3] Update the exit-code section of `docs/08-safety-model.md` (L173-190): node `E1` is labelled `usage` and is now also the rejected-target refusal's code. Broaden the label so the two causes are both visible, and note that the message distinguishes them — FR-003 forbids reporting the refusal *as* a usage error, not reusing the code. The two causes claiming `1` are the missing-or-unreadable argument and the rejected target; say plainly that the message, not the code, distinguishes them. The monotonic ordering is unchanged.
- [X] T045 [US3] Re-run T039: green.

**Checkpoint**: the caller is told, in the document it follows, what the guard enforces.

---

## Phase 6: User Story 4 — a specification whose tickets already exist is never mirrored twice (Priority: P3, droppable)

**Goal**: before creating a parent it holds no marker for, the mirror looks for tickets already
carrying that specification's provenance label and refuses rather than duplicating.

**Independent Test**: a mock holding a labelled parent and child, and a specification with its
markers stripped — zero writes, exit 4, both keys named, the found tickets untouched.

**Contract**: [contracts/duplicate-probe.md](./contracts/duplicate-probe.md)

> **Read contract §1 before starting.** This probe queries the same eventually-consistent index that
> feature 005 removed from recognition. Its false negative leaves today's behaviour in place and its
> true positive prevents a write, so it can only fail to help — but it is a mitigation, not a
> guarantee, and SC-001 rests on the marker line. **This is the slice to drop if the feature must
> shrink**: delete the two modules and the three call-site lines.

### Tests for User Story 4 (write first — they MUST fail)

- [X] T046 [P] [US4] Write `tests/bash/sink/test_duplicate_probe.bats` covering contract §6 T1–T7 and T9: hit → zero writes, exit 4, the §4 message with sorted keys, and **no run summary** (the refusal returns early); the found tickets byte-identical on the mock afterwards; markers present → no request at all; 400/403/404 → the run completes as it does with the probe absent plus one warning in the summary; no labelled ticket → no extra output; a settled re-run issues no probe request; `--dry-run` predicts the refusal; under `SPEC_KIT_JIRA_HOOK_CONTEXT` the same refusal returns **0** wrapped in the standard WARNING form (T9, SC-005).
- [X] T047 [P] [US4] Write the Pester twin `tests/powershell/sink/DuplicateProbe.Tests.ps1` with the same assertions, T9's hook downgrade included.
- [X] T048 [P] [US4] Add the conformance scenario `us4-duplicate-probe.json` covering the hit and the unavailable path.
- [X] T049 [US4] Run T046–T048 and confirm they fail.

### Implementation for User Story 4

- [X] T050 [P] [US4] Create `scripts/bash/sink/jira/duplicate_probe.sh`: one `GET <base>/rest/api/3/search/jql?jql=…&fields=key&maxResults=50` through the existing `jira_request` transport, with `jql` = `project = "<KEY>" AND labels = "<label>"`. Return `clear` / `hit` (with sorted keys) / `unavailable` (any non-2xx). Read-only: this module issues no other method, ever.
- [X] T051 [P] [US4] Create the twin `scripts/powershell/sink/jira/DuplicateProbe.psm1`.
- [X] T052 [US4] Call the probe from `scripts/bash/commands/reconcile.sh` in the planning pass, gated on all three conditions of contract §2 (about to create a parent, no parent marker recorded, not already refusing) — at most one request per run. On `hit` refuse with `_reconcile_fault "${EXIT_CONFIG}" "<§4 message>"` followed by `return $?`, the same shape the parent- and story-recognition refusals a few lines above already use: the `return $?` propagates the fault helper's value, which is what downgrades the run to 0 under a hook (Constitution III, SC-005). Returning the raw `EXIT_CONFIG` instead would fail the host command — that regression is exactly what `_reconcile_fault`'s header comment records as already fixed once. On `unavailable` proceed with the §4 warning in the summary. (Depends on T050.)
- [X] T053 [US4] Call the twin from `scripts/powershell/commands/Reconcile.psm1`. (Depends on T051.)
- [X] T053b [P] [US4] Add `duplicate_probe` to the `SinkLayer` subgraph of `docs/02-module-architecture.md` (L30-41, beside `plan_apply` and `recognition`) — the module map is the architecture reference `AGENTS.md` points agents at, and two new modules that never appear in it are two modules nobody finds. Drop this task with US4 if the slice is dropped.
- [X] T054 [US4] Re-run T046–T048: green.

**Checkpoint**: all four stories delivered.

---

## Phase 7: Polish & cross-cutting

- [X] T055 Add the CHANGELOG entry under the unreleased heading, naming the defect (a lifecycle hook mirroring `plan.md` created duplicate tickets), the guard, the provenance label, and the back-fill an existing consumer will see on its next run.
- [X] T056 [P] Update `README.md` where it describes what the mirror writes, so the provenance label is documented for the operator who will see it on their board.
- [X] T057 [P] Update `INSTALL.md` if the one-time back-fill needs an upgrade note — an existing consumer's next run reports updates it did not ask for, and that should not be a surprise.
- [X] T058 Run `shellcheck $(git ls-files '*.sh')` and `actionlint`; both must be clean.
- [X] T059 Run the full `tests/run-bash.sh`, the full Pester suite, and `bash tests/conformance/ci-conformance.sh`. Confirm the coverage floor still holds.
- [ ] T060 Push to `ci/windows-probe` and read the check-run annotations (~11 min; the token cannot read job logs). A platform fix is unproven without a green run there — the target guard's path splitting is the one change with a plausible Windows-only failure mode.
- [ ] T061 Walk `quickstart.md` §7 end to end on a scratch consumer repository: one parent and one child per story, each labelled, `plan.md` free of markers, and a hand-deleted label restored by the next run.
- [ ] T062 Extend `tests/live/test_live_zero_churn.bats` with the provenance label's live zero-churn proof — Constitution II states mocks are **not** sufficient, and this is the one assertion in the feature they genuinely cannot carry. Against the scratch project, in one test: (a) reconcile once and assert every created ticket carries `speckit-<slug>`; (b) add an operator label to the parent through the API, re-run, and assert `counts.updated` is `0` and `.actions | length` is `0` — a real Jira returns the `labels` array in **its own** order, which is exactly the order-sensitive `jq ==` regression research R4 identifies and the one thing a mock cannot reproduce, because a mock returns the order it was handed; (c) delete the provenance label through the API, re-run, and assert exactly one update restores it (FR-011) while the operator's label survives (FR-012); (d) with every ticket labelled, search the project through the API for `labels = "speckit-<slug>"` and assert the result is exactly the parent plus one child per story, with no ticket from another specification — SC-003 is the one criterion only a real, populated index can answer, and it is also the read the User Story 4 probe depends on. Runs with the same `SPEC_KIT_JIRA_LIVE=1` credentials as T061.

---

## Dependencies & execution order

### Phase dependencies

- **Phase 1 (Setup)**: no dependencies.
- **Phase 2 (Foundational)**: depends on Phase 1. **Blocks every user story** — the guard turns the
  un-migrated corpus red.
- **Phase 3 (US1)**: depends on Phase 2. Independent of US2 and US3.
- **Phase 4 (US2)**: depends on Phase 2. Independent of US1 — disjoint functions.
- **Phase 5 (US3)**: depends on Phase 2; needs US1's message wording (T012) for its cause row.
- **Phase 6 (US4)**: depends on US2 having labelled the estate (T032–T037).
- **Phase 7 (Polish)**: depends on every story that is being shipped.

### Within each story

Tests are written and seen to fail (T011, T027, T041, T049) before any implementation task in that
story starts. Within implementation: the sink's data source first (recognition), then the plan
context that carries it, then the payload builders that consume it.

### Parallel opportunities

- T002 alongside T001.
- T004 alongside T003 (different ports, different files).
- All of T006–T010 together; all of T019–T026 (T024b included) together; T046–T048 together.
- Within an implementation phase, the `[P]` pairs are the bash task and its PowerShell twin —
  different files, no shared state.
- **US1 and US2 can be built by two people simultaneously** once Phase 2 is green: they touch
  disjoint functions in the same two command files, so only the final integration run is shared.

## Parallel example — User Story 1

```bash
# Write all four test files together, then run them and watch them fail:
Task: "tests/bash/commands/test_reconcile_target.bats"          # T006
Task: "tests/powershell/commands/Reconcile.Target.Tests.ps1"    # T007
Task: "tests/bash/engine/test_marker_stray.bats"                # T008
Task: "tests/powershell/engine/MarkerStray.Tests.ps1"           # T009

# Then the two ports' guards, in parallel:
Task: "scripts/bash/commands/reconcile.sh — target guard"       # T012
Task: "scripts/powershell/commands/Reconcile.psm1 — twin"       # T013
```

## Implementation strategy

### MVP — User Story 1 only

Phases 1, 2, 3, then stop and validate. That closes the reported defect: no lifecycle hook can
duplicate a specification's tickets by naming the wrong artifact, and an operator already damaged by
the defect is told which files carry stray markers. Shippable on its own.

### Incremental delivery

1. Setup + Foundational → the corpus obeys the rule, nothing has changed yet.
2. US1 → the defect is closed → ship.
3. US2 → every ticket is searchable by specification → ship.
4. US3 → the caller is documented → ship.
5. US4 → the second, best-effort guard → ship, or drop.

### Notes

- Every `[P]` pair that spans ports must be finished together; a port left behind fails the
  conformance corpus, which is the gate for Principle VI.
- Conformance success is silent — exit 0 and zero "conformance divergence" lines. The temp paths it
  prints are harness noise.
- `tests/run-bash.sh --since <ref>` is the inner loop (≤60s on a single-module diff); the full
  serial `bats -r` run is ~15 minutes and is not the everyday tool.
