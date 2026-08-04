---

description: "Task list for 015 — A Recorded Field Default Is Sent in the Shape Its Field Accepts"
---

# Tasks: A Recorded Field Default Is Sent in the Shape Its Field Accepts

**Input**: Design documents from `/specs/015-fix-field-default-encoding/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/field-default-encoding.md](contracts/field-default-encoding.md)

**Tests**: Test tasks are **mandatory** here, not optional. Constitution XIII requires the failing test
first, FR-017 names the regression test explicitly, and the user's standing bug-fix policy requires a
test that is red before the fix and green after. Every implementation task below is preceded by the test
that must fail without it.

**Organization**: Tasks are grouped by user story so each can be implemented, tested, and shipped
independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel — different files, no dependency on an incomplete task
- **[Story]**: US1 / US2 / US3 / US4, mapping to the user stories in [spec.md](spec.md)

## Path Conventions

Twin native script ports, per [plan.md](plan.md):

- Bash port: `scripts/bash/**` — tests in `tests/bash/**` (`bats`)
- PowerShell port: `scripts/powershell/**` — tests in `tests/powershell/**` (Pester)
- Cross-port proof: `tests/conformance/**`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: establish the green baseline this change is measured against, and find every existing
assertion that will legitimately move.

- [X] T001 Capture the pre-change baseline in `specs/015-fix-field-default-encoding/baseline.txt`: the summary lines of `tests/run-bash.sh`, `pwsh -NoProfile -Command "Invoke-Pester tests/powershell"`, and `bash tests/conformance/ci-conformance.sh` (exit 0 and zero `conformance divergence` lines — success is silent). *(Captured retrospectively — see the note at the top of baseline.txt: the fix was already implemented and green before this task was executed.)*
- [X] T002 [P] Inventory, in `specs/015-fix-field-default-encoding/baseline.txt`, every existing test and fixture that asserts a **bare string** payload for a field whose `schema.type` is in the encoding table of [contracts/field-default-encoding.md](contracts/field-default-encoding.md) §1.3 — that is, `option` or one of the five named-entity types. Grep both `tests/bash/` and `tests/powershell/`. Each hit is an expected movement, not a regression, and must be justified in its own commit. **Note the exclusion**: `Business Owner` (`customfield_40011`, `schema.type: user`) in `tests/conformance/mock-jira/fixtures/createmeta-fields-parent-mandatory.json` is *not* on this list — FR-004 leaves user fields sending their recorded value unchanged, so every existing `user` assertion must stay exactly as it is. Record that as a deliberate finding, so a later reader does not "fix" it.
- [X] T003 [P] Confirm in `specs/015-fix-field-default-encoding/baseline.txt` that a project-keyed fault bites only the create: the fault key matches `/<key>(/|-|$)` (`tests/conformance/mock-jira/mock-server.ps1:217`, mirrored at `tests/conformance/mock-jira/curl-shim.sh:198`), and an issue path such as `/rest/api/3/issue/PM-1/...` also matches. Record which reconcile reads, if any, would be collaterally faulted — T029 depends on the answer.

**Checkpoint**: baseline green and recorded; the expected-movement list exists.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the shared test fixtures. No conformance corpus entry today carries an `option`-typed
field, so US1, US2, and US4 all need this before they can be proven.

**⚠️ Blocks US1, US2, and US4.** US3 depends only on Phase 1 and may start in parallel with this phase.

- [X] T004 [P] Add `tests/conformance/mock-jira/fixtures/createmeta-fields-fd-option.json`: `summary` (string, required), `description` (doc), a required `option`-typed custom field carrying `allowedValues`, a required `string`-typed custom field, plus one `priority`-typed field so every row of the encoding table in [contracts/field-default-encoding.md](contracts/field-default-encoding.md) §1.3 has a fixture, plus one `user`-typed field to cover the FR-004 exclusion (it must fall through unencoded). Use invented field names and option values — never a consumer's, and never a real accountId, which Principle IV bars from a fixture.
- [X] T005 [P] Add the mock config `tests/conformance/mock-jira/configs/field-defaults-option.json` binding the new fixture to **both** type ids — the specification-role and the story-role — following `configs/mandatory-field.json`. Both must serve the option field as required, so that the run T017 drives has to encode it twice, on two creations, exactly as the reported defect did.
- [X] T006 [P] Add the repository fixture `tests/conformance/fixtures/repo-with-option-field/` — `.specify/jira/config.yml` recording, for the **specification-role type**, one option default and one string default, and for the **story-role type**, the *same* option field again; `.specify/jira/config.local.yml` carrying the matching `defaultable_fields` with `schema_type` and `allowed_values` for both types; and a `specs/001-*/spec.md` with unmirrored stories. Model it on `tests/conformance/fixtures/repo-with-mandatory-field/`. **The two-role shape is load-bearing**: the reported defect had one mandatory option field on both roles, which is what made the run create zero tickets rather than degrade — a fixture with the option field on one role only would go green while still failing on a real project (SC-001).
- [X] T007 Smoke both mock ports against the new fixture with `tests/conformance/run-scenario.sh` and confirm the served `createmeta` bodies are byte-identical between `bash` and `powershell` before any scenario depends on them.

**Checkpoint**: an option-typed field is representable in both mocks; US1, US2, and US4 can begin.

---

## Phase 3: User Story 1 — A recorded default on a select-list field actually creates the ticket (Priority: P1) 🎯 MVP

**Goal**: the value is sent in the shape its field accepts, so a project with a mandatory single-select
creates its tickets instead of failing closed on the first one.

**Independent Test**: with an option default and a string default recorded on one issue type, run the
reconcile accepting the recorded values; both tickets exist, the option field carries the recorded
option, and the string field is unchanged.

### Tests for User Story 1 ⚠️ write first, confirm red

- [X] T008 [P] [US1] In `tests/bash/sink/test_plan_apply_defaults.bats`, add one case per row of the encoding table (`option`, the five named-entity types, and the fall-through), plus two cases asserting the deliberate exclusions fall through **unencoded** — a `user`-typed field (FR-004) and a cascading `option-with-child` field — plus the non-string guard, plus invariants I1–I4 of [data-model.md](data-model.md) §2 — asserting that `field_defaults` is unchanged and `field_defaults_encoded` is its encoded twin with an identical key set. Close FR-007's second clause too: for a label resolving to no field and for a field whose `schema_type` is absent or empty, assert the value is sent as recorded **and** the `unresolved` array and the existing rejection diagnostic are byte-identical to today's — the fall-through is only half of FR-007.
- [X] T009 [P] [US1] In `tests/bash/sink/test_ticket.bats`, add the FR-017 regression: one issue type carrying an option default and a string default, asserting the **exact** object `jira_create_fields_base` produces — the option field as `{"value": …}`, the string field as the bare recorded string. This is the case that must be red before T012. Add FR-008's assertion while here: drive the same recorded default through **both** creation paths — the hook-driven reconcile and the planned write — and assert the two payloads are byte-identical. `data-model.md` §3 argues this holds by construction from the single plan-context key; FR-008 is a requirement, so it needs an observation, not an argument.
- [X] T010 [P] [US1] Mirror T008 in `tests/powershell/sink/PlanApply.Defaults.Tests.ps1`, asserting the same values. Each case builds its own tree — Pester discovery order differs between hosts.
- [X] T011 [P] [US1] Mirror T009 in `tests/powershell/sink/Ticket.Tests.ps1`.

### Implementation for User Story 1

- [X] T012 [US1] In `scripts/bash/sink/jira/plan_apply.sh`, in `plan_resolve_field_defaults`: replace `fieldIdFor` with a `fieldMetaFor` that returns the whole metadata object, derive `fieldIdFor` from it, add the `encodeValue` rule of contract §1.3 with the non-string guard evaluated first, and populate `field_defaults_encoded` alongside the untouched `field_defaults`. Keep the jq literal inside its existing `kcov-excl` brackets and keep the output flowing through `json_canonical`.
- [X] T013 [US1] In `scripts/bash/commands/reconcile.sh:316`, take the plan context's `field_defaults` from `.field_defaults_encoded`. Leave `reconcile.sh:551` (`gate_resolved`) and `scripts/bash/commands/config.sh:962` reading `.field_defaults` — both use key presence only, and `config.sh` must never see an encoded value.
- [X] T014 [US1] Mirror T012 in `Get-JiraPlanResolveFieldDefault` in `scripts/powershell/sink/jira/PlanApply.psm1`, building both maps with `[ordered]@{}` and serialising through `ConvertTo-JiraJsonValue` so key order matches `json_canonical`.
- [X] T015 [US1] Mirror T013 at `scripts/powershell/commands/Reconcile.psm1:404`, leaving the gate at `:666` and `scripts/powershell/commands/Config.psm1:1105` on `.field_defaults`.
- [X] T016 [US1] Update every assertion listed by T002 to the new correct payload — an `option`-typed default now sends `{"value": …}`, a named-entity default `{"name": …}`. Leave every `user`-typed assertion untouched (FR-004). Adjust `tests/bash/**` and `tests/powershell/**` together so the ports stay in step. If T002's list came back empty, say so in the commit: it means no shipped fixture exercised an encodable type, and T009's regression is the only proof.
- [X] T017 [US1] Add `tests/conformance/scenarios/us1-field-defaults-option-encoded.json` using the Phase 2 fixtures: record the option default on both roles plus a string default on the specification role, reconcile with `--accept-defaults`, and let the corpus prove the two ports emit identical create bodies — **both** of them, parent and story. A scenario asserting only the parent would pass while the story creation still failed, which is the shape of the reported defect.
- [X] T018 [US1] Run `bash tests/conformance/ci-conformance.sh` and confirm exit 0 with zero `conformance divergence` lines.

**Checkpoint**: the defect is closed. A project with a mandatory single-select mirrors end to end, and the
string-typed field's payload is byte-identical to before (SC-002).

---

## Phase 4: User Story 2 — The confirmation question shows the value a human recorded (Priority: P2)

**Goal**: every operator-facing surface keeps speaking the operator's own words.

**Independent Test**: with an option default recorded and a creation pending, trigger the consolidated
question and confirm the field's value reads as the plain recorded option, with no trace of the wire
shape.

**Note**: decision R2 makes this hold **by construction** — the three display sites keep reading
`field_defaults`. These tasks are therefore mostly guard tests. If any test here goes red, the fix is to
point that call site back at `.field_defaults`, never to unwrap a value.

### Tests for User Story 2 ⚠️ write first, confirm they pass only for the right reason

- [X] T019 [P] [US2] In `tests/bash/commands/test_reconcile_field_defaults.bats`, assert that `plan_confirmation_fields`' `recorded_value` for an option-typed field is the plain recorded string, and that the set of fields it includes is unchanged (FR-010) — a required field with nothing to send is still listed with a null value.
- [X] T020 [P] [US2] In the same file, assert the two outputs of `_reconcile_field_default_notes`: the provenance line reads `= "<recorded value>"`, and the `--field-default` promotion command embeds the recorded value verbatim, so running the printed command re-records the same value in `config.yml`. This is the site R2 exists for.
- [X] T021 [P] [US2] Mirror T019 and T020 in `tests/powershell/commands/Reconcile.FieldDefaults.Tests.ps1`.

### Implementation for User Story 2

- [X] T022 [US2] Confirm no production change is needed: grep `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` for every read of the resolver output and check each against the table in [research.md](research.md) R2. If any display path reads `field_defaults_encoded`, repoint it at `field_defaults`. Record the outcome in the commit message — "no change required" is the expected result and is itself the deliverable.
- [X] T023 [US2] Add `tests/conformance/scenarios/us2-field-defaults-option-question.json`: the Phase 2 fixture with `ask: true` and no `--accept-defaults`, so the corpus captures the consolidated question and proves both ports render the recorded value identically.

**Checkpoint**: SC-004 holds — no operator-facing surface displays a machine shape, and the promotion
command is safe to run.

---

## Phase 5: User Story 3 — The summary counts tickets Jira actually created (Priority: P2)

**Goal**: `counts.created` reports confirmed creations, never planned ones.

**Independent Test**: force every creation to be refused; the summary reports zero created alongside the
fail-closed status and the refusal warning.

**Note**: independent of US1 and US2 — depends only on Phase 1 and may be built in parallel with Phase 2.

### Tests for User Story 3 ⚠️ write first, confirm red

- [X] T024 [P] [US3] In a **new** file `tests/bash/sink/test_plan_apply_outcome.bats` — not `test_plan_apply_defaults.bats`, which US1's T008 owns; a dedicated file is what keeps US3 genuinely parallel with US1 — assert the outcome contract of [contracts/field-default-encoding.md](contracts/field-default-encoding.md) §4.2: `{"created":[…]}` on stdout, an entry only for a create the mock confirmed, the parent first, emitted on normal completion **and** on both rejection returns, and nothing on stdout beyond it.
- [X] T025 [P] [US3] In `tests/bash/sink/test_privacy_block.bats`, assert that the two pre-write privacy-guard returns still print nothing on stdout — rule O4, and the reason those two existing cases need no edit.
- [X] T026 [P] [US3] In a **new** file `tests/bash/commands/test_reconcile_created_count.bats` — not `test_reconcile_field_defaults.bats`, which US2's T019/T020 own — assert three counts: zero created when every creation is refused, one when the parent is created and the story refused, and the unchanged value on a fully successful run (FR-013). Add a fourth asserting `--dry-run` still reports the planned count (FR-012).
- [X] T027 [P] [US3] Mirror T024 in a new `tests/powershell/sink/PlanApply.Outcome.Tests.ps1`, T026 in a new `tests/powershell/commands/Reconcile.CreatedCount.Tests.ps1`, and **T025 in the existing `tests/powershell/sink/PrivacyGuard.Block.Tests.ps1`** — rule O4 is a cross-port invariant under FR-016, and a PowerShell port that prints an outcome on the privacy path would diverge silently with no other test to catch it. Each case builds its own tree; Pester discovery order differs between hosts.

### Implementation for User Story 3

- [X] T028 [US3] In `scripts/bash/sink/jira/plan_apply.sh`, in `apply_writes_with_recognition`: accumulate each confirmed creation as `{key, role, local_id}` where the response key is already read (parent at `:631`, stories at `:674`), and print the canonical outcome through `json_canonical` at each of the three post-write exits — parent rejection, story rejection, normal end. Leave the two privacy-guard returns silent. Keep the rejection message on stderr.
- [X] T029 [US3] In `scripts/bash/commands/reconcile.sh:891`, capture the apply's stdout while letting stderr flow and preserving `|| rc=$?`, then derive `counts.created` from the captured outcome, treating empty output as `{"created":[]}`. Leave the planned-count computation at `:816` in place for the `--dry-run` path only; every other member of `counts` is untouched.
- [X] T030 [US3] Mirror T028 in `Invoke-JiraApplyWriteSetWithRecognition` in `scripts/powershell/sink/jira/PlanApply.psm1`.
- [X] T031 [US3] Mirror T029 in `scripts/powershell/commands/Reconcile.psm1`, around the counting at `:980` and the summary at `:1204`.
- [X] T032 [US3] Add `tests/conformance/scenarios/us3-created-count-refused.json` injecting a `400` fault with an `errors` body on the create, per the mechanism at `tests/conformance/mock-jira/mock-server.ps1:441` and `curl-shim.sh:368`. This is the corpus's **first** use of `faults` — verify with T003's finding that no reconcile read is collaterally faulted; if one is, extend both mocks with a method-scoped fault key as a single mirrored, additive change rather than working around it in the scenario.

**Checkpoint**: SC-003 holds — the count a reader or CI sees never exceeds the number of tickets that
exist in Jira.

---

## Phase 6: User Story 4 — A value the field cannot accept is refused when it is recorded (Priority: P3)

**Goal**: a recorded value outside its field's allowed values is refused while the operator is
configuring, not on the next hook that fires mid-task.

**Independent Test**: hand-edit a recorded default to a value outside its field's enumerated allowed
values, run the configuration ceremony, and confirm it names the field, the value's absence from the
list, and the accepted values — and writes nothing.

**Note**: this is the slice the spec marks droppable. It depends on Phase 2 only, not on US1–US3.

### Tests for User Story 4 ⚠️ write first, confirm red

- [X] T033 [P] [US4] In `tests/bash/commands/test_config_field_defaults.bats`, assert all four admission cases of [contracts/field-default-encoding.md](contracts/field-default-encoding.md) §6.2/§6.3: a recorded value outside a non-empty `allowed_values` refuses and writes nothing; an unresolvable type or label stays classified `orphaned` and does **not** block (011 FR-008 must not regress); a field with no enumerated allowed values is accepted; and refusals are batched into one pass. Add the FR-014 suppression assertion: the refusal names the label and the candidates, and the recorded value appears in neither the message nor the structured output.
- [X] T034 [P] [US4] In `tests/bash/commands/test_config_degraded.bats`, assert that a degraded-mode ceremony with no Jira read performs no allowed-value check at all and stays silent about it.
- [X] T035 [P] [US4] Mirror T033 and T034 in `tests/powershell/commands/Config.FieldDefaults.Tests.ps1` and `tests/powershell/commands/Config.Degraded.Tests.ps1`.

### Implementation for User Story 4

- [X] T036 [US4] In `scripts/bash/commands/config.sh`, extend `_config_field_default_report` (`:329`) with the `outside_allowed` member of contract §6.1, admitted only when the type resolves, the label resolves, and `allowed_values` is non-empty — reusing the `candidates` key already used by the flag path at `:279`.
- [X] T037 [US4] In `scripts/bash/commands/config.sh`, make a non-empty `outside_allowed` a refusal trigger alongside `pending`, rendered through the existing message at `:455` (`… must be one of: …`) with the existing exit code, so a refusal from the file is indistinguishable from one from a flag. The recorded value must not appear in the message or in any structured output.
- [X] T038 [US4] Mirror T036 in `Get-JiraFieldDefaultsReport` in `scripts/powershell/commands/Config.psm1:502`.
- [X] T039 [US4] Mirror T037 in `Write-JiraFieldDefaultProblemsReport` in `scripts/powershell/commands/Config.psm1:595`, reusing the `outside_allowed` branch at `:620`.
- [X] T040 [US4] Add `tests/conformance/scenarios/us4-recorded-value-outside-allowed.json` using the Phase 2 fixtures with one recorded value deliberately outside the enumerated list, proving both ports refuse identically.
- [X] T040a [US4] **PR review follow-up (defect, tests first).** The check as first written admitted an entry of *any* recorded value type, so a hand-written structured value — FR-006's escape hatch, US1 scenario 6 — was refused at configuration time: `allowed_values` enumerates option labels, which no object or array can ever match. Add the failing cases to `tests/bash/commands/test_config_field_defaults.bats` and `tests/powershell/commands/Config.FieldDefaults.Tests.ps1` (an object, an array, a number, a boolean, a null; plus a structured value passing while a genuinely wrong string beside it still refuses), then add admission rule A4 — the recorded value is a string — to `_config_field_default_report` and `Get-JiraFieldDefaultsReport`. The flag path needs no change: a `--field-default` answer is a string by construction. Contract §6.2, data-model §7 A4, research R5 rule 4, spec US4 scenario 5 and FR-015 updated to match.

**Checkpoint**: SC-005 holds — the refusal arrives while the operator is configuring.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T041 [P] Correct the block comment on `_disc_defaultable_fields` in `scripts/bash/sink/jira/discovery.sh:200-202`: the bridge no longer "sends exactly what was recorded", and `schema_type` is now consumed rather than merely captured (research R8). No behaviour change.
- [X] T042 [P] Mirror T041 on `Get-JiraDiscoveryDefaultableFields` in `scripts/powershell/sink/jira/Discovery.psm1:200`.
- [X] T043 [P] Bump the PATCH version in `extension.yml:17` (`0.10.1` → `0.10.2`) and add the matching CHANGELOG entry in `CHANGELOG.md`, moving it out of `[Unreleased]` under the new heading — naming the defect (a recorded default on a select-list field made creation impossible), the corrected `counts.created`, and the new configuration-time refusal. Both halves are Principle XII release-gate items; neither ships without the other.
- [X] T044 [P] Check whether `docs/README.md`'s module map needs a line for the resolver's new output shape; update it if the map describes function outputs, otherwise record that no change was needed.
- [X] T045 Run the full gates: `tests/run-bash.sh`, `Invoke-Pester tests/powershell`, and `bash tests/conformance/ci-conformance.sh`. Compare against `baseline.txt`; every difference must be an intended movement from T002 or T016.
- [X] T046 Run `shellcheck $(git ls-files '*.sh')`, `actionlint`, and `Invoke-ScriptAnalyzer -Path scripts/powershell -Recurse -Settings PSScriptAnalyzerSettings.psd1` — all three are blocking and must be clean.
- [ ] T047 Verify the 80% statement coverage gate on both ports, and confirm the new encoding rules sit inside the existing `kcov-excl` brackets in `scripts/bash/sink/jira/plan_apply.sh` so the exclusion stays accurate rather than generous.
- [ ] T048 Confirm the three-OS Actions matrix is green — Windows included. No Windows-only behaviour changed here, so the `ci/windows-probe` loop is not required unless the matrix reveals a divergence.
- [ ] T049 **Mandatory — Principle XII names the dogfood record as a release gate, and it is the only proof of SC-001.** Run the manual end-to-end check in [quickstart.md](quickstart.md) against a real project whose specification-role and story-role issue types each require a single-select field, and record the outcome in `specs/015-fix-field-default-encoding/quickstart-results.md` (the convention feature 014 follows). Anonymise every project key, field label, option value, and ticket key before any of it reaches that file, a commit, an issue, or a spec. **Antériorité to record, not to substitute**: the source bug report already carried an end-to-end validation of the core encoding against a real instance — two tickets created, the option field encapsulated and the string field left raw. That run predates the two-map design and exercised neither the `--field-default` promotion command (US2), nor `counts.created` (US3), nor the configuration-time refusal (US4), so it narrows what this dogfood must prove but does not replace it.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: no dependencies — start immediately.
- **Phase 2 (Foundational)**: depends on Phase 1. **Blocks US1, US2, US4.** Does **not** block US3.
- **Phase 3 (US1, P1)**: depends on Phase 2.
- **Phase 4 (US2, P2)**: depends on Phase 3 — there is no wire shape to keep out of the display until it exists.
- **Phase 5 (US3, P2)**: depends on Phase 1 only. Fully independent of US1, US2, US4.
- **Phase 6 (US4, P3)**: depends on Phase 2 only. Independent of US1, US2, US3.
- **Phase 7 (Polish)**: depends on every story that is being shipped.

### User Story Dependencies

- **US1 (P1)**: the MVP. Nothing depends on it except US2.
- **US2 (P2)**: depends on US1. It is the guard around US1's change, not a separate mechanism.
- **US3 (P2)**: independent. Shippable alone, on today's code, before US1 exists.
- **US4 (P3)**: independent. The droppable slice.

### Within Each User Story

- Tests are written and confirmed **red** before the implementation task that makes them green.
- Bash and PowerShell twins land together — a port left behind fails the conformance gate.
- The conformance scenario is the last task of each story: it proves the two ports agree, which no unit
  test can.

### Parallel Opportunities

- T002 and T003 in parallel after T001.
- All of T004, T005, T006 in parallel (three separate new files).
- All four US1 test tasks (T008–T011) in parallel.
- Within US1's implementation, the Bash pair (T012, T013) and the PowerShell pair (T014, T015) are
  independent of each other and can be split between two people.
- **US3 can be built start to finish in parallel with Phases 2–4** by a second person. Its test files
  (`test_plan_apply_outcome.bats`, `test_reconcile_created_count.bats` and their Pester twins) are its
  own, so the only files it shares with US1 and US2 are `plan_apply.sh`/`PlanApply.psm1` and
  `reconcile.sh`/`Reconcile.psm1` — and in each it touches a different function than they do. The one
  genuine overlap is `PrivacyGuard.Block.Tests.ps1` in T027, which no other task writes.
- **US4 can be built in parallel with US1 and US2** once Phase 2 is done; it shares no file with them.
- All of T041–T044 in parallel.

---

## Parallel Example: User Story 1

```bash
# Write all four failing tests together:
Task: "T008 encoding table + two-map invariants in tests/bash/sink/test_plan_apply_defaults.bats"
Task: "T009 FR-017 exact payload regression in tests/bash/sink/test_ticket.bats"
Task: "T010 Pester twin in tests/powershell/sink/PlanApply.Defaults.Tests.ps1"
Task: "T011 Pester twin in tests/powershell/sink/Ticket.Tests.ps1"

# Then split the two ports:
Task: "T012+T013 Bash encoding and plan context"
Task: "T014+T015 PowerShell twins"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 — baseline captured.
2. Phase 2 — the option-typed fixtures exist in both mocks.
3. Phase 3 — US1.
4. **STOP and VALIDATE**: a project with a mandatory single-select creates its tickets; a string-typed
   default's payload is byte-identical to before.
5. This alone closes the defect and is shippable.

### Incremental Delivery

1. Setup + Foundational → fixtures ready.
2. US1 → the mirror works (MVP).
3. US2 → the operator's words survive on all three surfaces.
4. US3 → the summary stops lying about what was created.
5. US4 → the refusal moves to configuration time.
6. Polish → comments, CHANGELOG, gates.

Each step is independently valuable; stopping after any of them leaves a coherent release.

### Parallel Team Strategy

With three people, after Phase 1:

- Person A: Phase 2 → US1 → US2 (the critical path).
- Person B: US3, immediately and independently.
- Person C: waits for Phase 2, then US4.

---

## Notes

- `[P]` means a different file and no dependency on an incomplete task.
- Confirm every test is red before writing the code that turns it green — for T009 in particular, a test
  that passes before T012 is not testing the defect.
- Both ports land in the same commit for any behavioural change; the conformance corpus is the only proof
  that FR-016 holds, and its success is **silent** (exit 0, zero `conformance divergence` lines).
- Never put `$'\r\n'` inside a glob pattern, and never call `jq` directly in the Bash port — go through
  `scripts/bash/lib/output.sh`.
- No consumer data in fixtures, tests, scenarios, or commit messages: invent project keys, field labels,
  and option values.

---

## Phase 8: Convergence

- [X] T050 [P] Assert that a **string** this-run answer on an `option`-typed field is encoded `{"value": v}`, identically to the same text recorded in `config.yml`, in `tests/bash/sink/test_plan_apply_defaults.bats` and its twin `tests/powershell/sink/PlanApply.Defaults.Tests.ps1` per US2/AC4, contract §1.3's precedence clause ("an answer and a recorded value of the same text MUST produce the same encoded value"), and the spec's edge case "an operator's this-run override of a select-list field" (partial). The behaviour is already implemented — both resolvers encode answers through the same merged entries list — but no observation exists: T008's only answers-path case (`test_plan_apply_defaults.bats`, FR-006) passes a **boolean**, so it exits at the non-string guard before reaching the table, and `tests/conformance/scenarios/us2-field-defaults-overridden.json` overrides a `user`-typed field, which falls through by design (FR-004). Both ports land together (FR-016).
