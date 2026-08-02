---

description: "Task list for 011 — recorded field defaults so a mandatory field never blocks a mirror"
---

# Tasks: Recorded Field Defaults So a Mandatory Field Never Blocks a Mirror

**Input**: Design documents from `/specs/011-jira-field-defaults/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/field-defaults.md](contracts/field-defaults.md),
[quickstart.md](quickstart.md)

**Tests**: MANDATORY, not optional. Constitution Principle XIII makes this project strictly
Red-Green-Refactor and states that "no implementation task may be planned without its test task
preceding it in `tasks.md`". Every implementation task below is preceded by the test task that must
be observed to FAIL first. A task that skips that step is a review rejection, not a shortcut.

**Organization**: grouped by user story. Every behaviour ships in **both** ports — the Bash port for
macOS/Linux and the PowerShell 7+ port for Windows — and is proven equivalent by the shared
conformance corpus (Principle VI). A task that lands in one port only is not done.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel — different files, no dependency on an incomplete task
- **[Story]**: US1, US2, US3 — maps to the user stories of [spec.md](spec.md)

## Path Conventions

- Bash port: `scripts/bash/{lib,engine,sink/jira,commands,hooks}/`
- PowerShell port: `scripts/powershell/{lib,engine,sink/jira,commands,hooks}/`
- Bash tests: `tests/bash/{lib,engine,sink,commands,ci}/test_*.bats`
- PowerShell tests: `tests/powershell/{lib,engine,sink,commands,ci}/*.Tests.ps1`
- Cross-port: `tests/conformance/{fixtures,scenarios,mock-jira}/`

---

## Phase 1: Setup (Shared Test Infrastructure)

**Purpose**: give every later phase something to run against. No production code here.

- [ ] T001 [P] Extend the mock's `createmeta` responses to carry `allowedValues`, `schema.type`, and a
      non-defaultable field shape, in `tests/conformance/mock-jira/mock-server.ps1`
- [ ] T002 [P] Mirror the same `createmeta` shape in the Bash-side transport shim in
      `tests/conformance/mock-jira/curl-shim.sh`, so both ports see identical bytes
- [ ] T003 Create the conformance fixture `tests/conformance/fixtures/repo-with-field-defaults/` — a
      company-managed project whose specification type requires one free-text and one enumerated
      custom field, with `.specify/jira/config.yml` and `.specify/jira/config.local.yml`
- [ ] T004 [P] Add the mock configuration entry for that fixture's project in
      `tests/conformance/mock-jira/configs/`

**Checkpoint**: the corpus can describe a project with mandatory custom fields on both ports.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the substrate all three stories consume — discovering what a field is, reading what the
team recorded, resolving one to the other, and letting a recorded value satisfy the gate.

**⚠️ CRITICAL**: no user story work can begin until this phase is complete.

### Discovery — learning what a field is (research R3)

- [ ] T005 [P] Write the failing test for defaultable-field extraction in
      `tests/bash/sink/test_discovery_defaultable.bats`: given a `createmeta` type payload, assert the
      output carries `logical_name`, `field_id`, `schema_type`, `required`, `defaultable`, and
      `allowed_values` for required AND optional fields, and `undefaultable_reason` for a shape that
      cannot be expressed as a recorded value. Observe it FAIL.
- [ ] T006 [P] Write the PowerShell twin of T005 in `tests/powershell/sink/Discovery.Defaultable.Tests.ps1`.
      Observe it FAIL.
- [ ] T007 Implement `_disc_defaultable_fields` beside the existing `_disc_required_fields` in
      `scripts/bash/sink/jira/discovery.sh`, and emit `defaultable_fields` from `discover_binding` and
      `discovery_type_metadata`. Leave `required_fields` exactly as it is — the pre-011 gate and every
      existing binding still read it.
- [ ] T008 Implement the twin in `scripts/powershell/sink/jira/Discovery.psm1`, byte-identical output.

### Persistence — the machine-owned layer

- [ ] T009 [P] Write the failing test for binding persistence in
      `tests/bash/lib/test_config_binding_shape.bats`: `defaultable_fields` survives the round trip
      keyed by issue-type id, a second write is byte-identical, and a binding written before 011 (no
      such key) still loads. Observe it FAIL.
- [ ] T010 [P] Write the PowerShell twin in `tests/powershell/lib/Config.BindingShape.Tests.ps1`.
      Observe it FAIL.
- [ ] T011 Carry `defaultable_fields` through `config_resolved_ids_for` in
      `scripts/bash/commands/config.sh`, omitted rather than emitted empty — the same treatment
      `required_fields` already gets.
- [ ] T012 Implement the twin in `scripts/powershell/commands/Config.psm1`.

### Reading the team's answers — the committable layer

- [ ] T013 [P] Write the failing test for reading and validating `field_defaults` in
      `tests/bash/lib/test_config_field_defaults.bats`: the key parses; `ask` defaults to `true` when
      absent; an undeclared project key, an empty value, and a non-scalar value each produce a named
      refusal with zero writes; and a credential-shaped value is still caught by the existing
      credential scan (it must NOT be exempted the way `privacy.*` is — research R7). Observe it FAIL.
- [ ] T014 [P] Write the PowerShell twin in `tests/powershell/lib/Config.FieldDefaults.Tests.ps1`.
      Observe it FAIL.
- [ ] T015 Add `field_defaults` to the top-level key allowlist and the schema checks in
      `_cfg_schema_errors`, plus a reader, in `scripts/bash/lib/config.sh`.
- [ ] T016 Implement the twin in `scripts/powershell/lib/Config.psm1`.

### CLI surface

- [ ] T017 [P] Write the failing test for the three new flags in `tests/bash/lib/test_cli.bats`:
      `--field-default KEY=Type=Label=Value` and `--field-value KEY=Type=Label=Value` are repeatable
      and reject a malformed value with the same message shape `--issue-type` already uses;
      `--accept-defaults` is a boolean. Observe it FAIL.
- [ ] T018 [P] Write the PowerShell twin in `tests/powershell/lib/Cli.Tests.ps1`. Observe it FAIL.
- [ ] T019 Implement the three flags in `scripts/bash/lib/cli.sh`, following the existing
      `--issue-type` parsing shape. A value may contain `=`; split on the first three separators only.
- [ ] T020 Implement the twin in `scripts/powershell/lib/Cli.psm1`.

### Satisfiability — one predicate, both gates (research R5)

- [ ] T021 [P] Write the failing test in `tests/bash/sink/test_hierarchy.bats`: a required field with a
      recorded default is satisfiable; without one it is not; a required `parent` on the PARENT type
      stays unsatisfiable whatever is recorded (contract §1.2); the bridge-supplied list is unchanged.
      Observe it FAIL.
- [ ] T022 [P] Write the PowerShell twin in `tests/powershell/sink/Hierarchy.Tests.ps1`. Observe it FAIL.
- [ ] T023 Give `hierarchy_unsatisfiable_fields` a recorded-defaults input and thread it through
      `hierarchy_mandatory_gate` in `scripts/bash/sink/jira/hierarchy.sh`. Do not change either call
      site's logic — both gates must inherit the behaviour from this one function.
- [ ] T024 Implement the twin in `scripts/powershell/sink/jira/Hierarchy.psm1`.

### Resolution and payload merge (research R2)

- [ ] T025 [P] Write the failing test for label→id resolution in
      `tests/bash/sink/test_plan_apply_defaults.bats`: recorded labels resolve to field ids through the
      binding's `defaultable_fields`; an unresolvable label is reported, not silently dropped; the
      result is keyed issue-type id → field id → value with a parallel source map. Observe it FAIL.
- [ ] T026 [P] Write the PowerShell twin in `tests/powershell/sink/PlanApply.Defaults.Tests.ps1`.
      Observe it FAIL.
- [ ] T027 Write the failing test proving no default can reach an update, in the same file as T025,
      `tests/bash/sink/test_plan_apply_defaults.bats`: a ticket that already exists is updated with a
      payload carrying no defaulted field, even when defaults are recorded and have changed. Observe
      it FAIL — T033 is what turns it green. Not `[P]`: same file as T025.
- [ ] T028 Write the PowerShell twin in `tests/powershell/sink/PlanApply.Defaults.Tests.ps1`. Observe
      it FAIL. Not `[P]`: same file as T026.
- [ ] T029 [P] Write the failing test for the payload merge in `tests/bash/sink/test_ticket.bats`:
      `jira_create_fields_base` merges the defaults for the type being created, and merges nothing when
      the map is empty (FR-028). Observe it FAIL.
- [ ] T030 [P] Write the PowerShell twin in `tests/powershell/sink/Ticket.Tests.ps1`. Observe it FAIL.
- [ ] T029a Write the failing privacy-guard test in `tests/bash/sink/test_ticket.bats` (FR-024,
      Principle IX, research R7): the body handed to `privacy_guard_scan` **contains** the defaulted
      value — proving the merge happens at plan time, before the scan, not after it; a defaulted value
      the guard blocks produces zero Jira writes and a message naming where such a value belongs
      instead; an allowlisted one passes silently. No exemption for defaulted fields exists, and the
      test fails if one is introduced. Observe it FAIL. Not `[P]`: same file as T029.
- [ ] T030a Write the PowerShell twin in `tests/powershell/sink/Ticket.Tests.ps1`. Observe it FAIL.
      Not `[P]`: same file as T030.
- [ ] T031 Implement the merge in `jira_create_fields_base` in `scripts/bash/sink/jira/ticket.sh`, so
      both creation paths acquire it from the one builder they already share.
- [ ] T032 Implement the twin in `scripts/powershell/sink/jira/Ticket.psm1`. Import the config
      dependency **without** `-Force`: a `-Force` import inside a sink module re-initialises the
      module in the caller's scope and clobbers state the command layer already loaded.
- [ ] T033 Resolve the defaults into the plan context and pass them to the create branch in
      `scripts/bash/sink/jira/plan_apply.sh`. The UPDATE branch must remain untouched — that is what
      makes create-only (FR-017) structural rather than a rule someone has to remember. Turns T027 and
      T028 green.
- [ ] T034 Implement the twin in `scripts/powershell/sink/jira/PlanApply.psm1`.

**Checkpoint**: a recorded default can be read, resolved, judged satisfiable, and sent — but nothing
yet writes one, asks about one, or explains one.

---

## Phase 3: User Story 1 — Record the answers once, during the config ceremony (Priority: P1) 🎯 MVP

**Goal**: an operator runs the ceremony against a project with mandatory custom fields, answers one
question per field, and the answers land in the committable config — after which the previously
refused reconcile creates its tickets.

**Independent Test**: run the ceremony against `repo-with-mandatory-field`, record the two fields,
confirm `config.yml` carries them with every surrounding comment intact, confirm a second run changes
no byte, and confirm the reconcile that used to refuse now mirrors.

### Tests for User Story 1 ⚠️ write first, observe FAIL

- [ ] T035 [P] [US1] Write the failing conformance scenario
      `tests/conformance/scenarios/us1-field-defaults-record.json` — the ceremony invoked with two
      `--field-default` flags against `repo-with-field-defaults`, expecting the managed region written
      and the run summary reporting it. Observe it FAIL.
- [ ] T036 [P] [US1] Write the failing conformance scenario
      `tests/conformance/scenarios/us1-field-defaults-idempotent.json` — the same invocation twice,
      asserting the second run leaves `config.yml` byte-for-byte identical (FR-007). Observe it FAIL.
- [ ] T037 [P] [US1] Write the failing scenario
      `tests/conformance/scenarios/us1-mandatory-field-satisfied.json` — the counterpart of the shipped
      `us3-mandatory-field-refusal.json`: the same fixture, the two fields recorded, expecting a
      completed mirror instead of a refusal. **This is the feature's red test** — it proves the
      blocking refusal was the defect. Observe it FAIL.
- [ ] T038 [P] [US1] Write the failing Bash command tests in
      `tests/bash/commands/test_config_field_defaults.bats`: the ceremony asks about the specification
      and story types only (FR-025); it asks about **required** fields only — an optional defaultable
      field on a written type produces no question, while a default recorded for it by flag or by hand
      is still validated and carried forward (FR-002/FR-004); an opted-in third type is accepted and
      reported as not yet consumed (FR-026/FR-027); an unknown type lists the discovered types; a
      value outside
      `allowed_values` lists the accepted values (FR-003); an empty value is refused (FR-008); an
      orphaned entry is reported (FR-008); degraded mode asks nothing and writes nothing (FR-009);
      and a field that already carries a recorded value is presented with that value as the current
      answer, so an operator who keeps it supplies no input and the resulting file is byte-identical
      (FR-007, US1 acceptance scenario 3, contract §2.6). Observe them FAIL.
- [ ] T039 [P] [US1] Write the PowerShell twin in
      `tests/powershell/commands/Config.FieldDefaults.Tests.ps1`. Observe it FAIL.
- [ ] T040 [US1] Write the failing test for the managed region write in
      `tests/bash/commands/test_config_field_defaults.bats`: comments and keys outside the region are
      byte-preserved; the host's dominant line ending is respected; malformed markers refuse with exit
      `4` and zero writes; the region is appended once when absent. Observe it FAIL. Not `[P]`: same
      file as T038.
- [ ] T041 [US1] Write the PowerShell twin in
      `tests/powershell/commands/Config.FieldDefaults.Tests.ps1`. Observe it FAIL. Not `[P]`: same
      file as T039.
- [ ] T041a [US1] Write the failing test for the record-time credential refusal in
      `tests/bash/commands/test_config_field_defaults.bats` (FR-024, Principle IV, contract §2.4
      row 5): a `--field-default` whose value carries an Atlassian token prefix, a vendor host, or an
      email address is refused **before** any splice — `config.yml` is byte-for-byte unchanged, the
      message names the path and the shape and never the value, and the existing credential exit code
      is returned. The test fails if the value reaches the file and is caught only on the next read.
      Observe it FAIL. Not `[P]`: same file as T038.
- [ ] T041b [US1] Write the PowerShell twin in
      `tests/powershell/commands/Config.FieldDefaults.Tests.ps1`. Observe it FAIL. Not `[P]`: same
      file as T039.
- [ ] T041c [US1] Write the failing carry-forward test in
      `tests/bash/commands/test_config_field_defaults.bats` (FR-004, contract §2.6): hand-write an
      entry for an **optional** field and an entry for an opted-in type inside the managed region, run
      the ceremony answering only the required fields of the written types, and assert both
      hand-written entries survive byte-for-byte; assert an entry written **outside** the region is
      refused as a duplicate top-level key with zero writes. Observe it FAIL. Not `[P]`: same file as
      T038.
- [ ] T041d [US1] Write the PowerShell twin in
      `tests/powershell/commands/Config.FieldDefaults.Tests.ps1`. Observe it FAIL. Not `[P]`: same
      file as T039.

### Implementation for User Story 1

- [ ] T042 [US1] Emit the canonical `field_defaults` YAML block in `scripts/bash/lib/config.sh` from
      the **union** of the entries already present in the managed region and the answers given on this
      run, the run's answers winning per project/type/label (contract §2.6). An entry the ceremony
      never asked about — an optional field, an opted-in type not named this run, a hand-written line —
      is carried forward unchanged. Include the explanatory comment header, which states that the
      region is machine-written and that a hand-written entry belongs inside it (Principle XVI).
- [ ] T043 [US1] Implement the twin in `scripts/powershell/lib/Config.psm1`, byte-identical output.
- [ ] T044 [US1] Splice that block into `.specify/jira/config.yml` through the existing
      `managed_section_splice` in `scripts/bash/commands/config.sh`. Reuse `engine/managed_section.sh`
      unchanged — it must learn nothing about Jira or about YAML.
- [ ] T045 [US1] Implement the twin in `scripts/powershell/commands/Config.psm1` using
      `ManagedSection.psm1` unchanged.
- [ ] T046 [US1] Add the field-default questions to the ceremony in `scripts/bash/commands/config.sh`,
      in the fixed order of contract §2.2, over the specification and story types plus any type named
      by `--field-default`. Only a field discovery marked `required: true` produces a question
      (contract §2.1); an optional defaultable field is recorded through the flag or by hand and asked
      about never. Each question is a closed question when `allowed_values` is non-empty. A field with
      an entry already in the managed region carries that entry as its current answer, and an empty
      response keeps it — the one case where §2.4's empty-value refusal does not fire, because nothing
      is being recorded (FR-007).
- [ ] T047 [US1] Implement the twin in `scripts/powershell/commands/Config.psm1`.
- [ ] T048 [US1] Implement the recording-time refusals of contract §2.4 in
      `scripts/bash/commands/config.sh` — empty value, value outside the allowed list, unknown type,
      unknown label, **and credential- or identity-shaped value** — each naming the offending item and
      producing zero file writes. The credential check runs on the candidate value before
      `managed_section_splice` is called, reusing the shapes `_cfg_credential_errors` already
      recognises: a value refused on read must never have been written. Turns T041a green.
- [ ] T049 [US1] Implement the twin in `scripts/powershell/commands/Config.psm1`. Turns T041b green.
- [ ] T050 [US1] Report orphaned entries and not-yet-consumed entries in the ceremony's run summary
      (FR-008, FR-027) in `scripts/bash/commands/config.sh`, as reports rather than errors.
- [ ] T051 [US1] Implement the twin in `scripts/powershell/commands/Config.psm1`.
- [ ] T052 [US1] Ensure the degraded path returns before any field-default question or write in
      `scripts/bash/commands/config.sh` (FR-009).
- [ ] T053 [US1] Implement the twin in `scripts/powershell/commands/Config.psm1`.

**Checkpoint**: User Story 1 is complete and independently demonstrable — record the answers, watch
the previously refused mirror succeed. This is the MVP.

---

## Phase 4: User Story 2 — A hook creation asks before it commits to a default (Priority: P1)

**Goal**: before creating a ticket that carries recorded defaults, the operator is asked once,
consolidated, and can keep or override — without the bridge ever reading stdin and without the host
command's outcome moving.

**Independent Test**: with defaults recorded, run a reconcile with creations pending; assert one
`confirmation-pending` object and zero writes; re-invoke with `--accept-defaults` and with
`--field-value`, asserting the created payloads and that `config.yml` was not touched.

### Tests for User Story 2 ⚠️ write first, observe FAIL

- [ ] T054 [P] [US2] Write the failing scenario
      `tests/conformance/scenarios/us2-field-defaults-question.json` — creations pending that would
      carry a recorded default, with `ask` on, expecting one `confirmation-pending` object, exit `0`,
      and zero Jira writes. Observe it FAIL.
- [ ] T055 [P] [US2] Write the failing scenario
      `tests/conformance/scenarios/us2-field-defaults-accepted.json` — the same state re-invoked with
      `--accept-defaults`, expecting the tickets created carrying the recorded values; **and** the same
      flag given on a *first* invocation with no preceding planning pass — the continuous-integration
      shape of contract §3.10 — writing directly and naming the skip reason in the summary. Observe it
      FAIL.
- [ ] T056 [P] [US2] Write the failing scenario
      `tests/conformance/scenarios/us2-field-defaults-overridden.json` — re-invoked with
      `--field-value`, expecting the overridden value in the payload and `config.yml` unmodified
      (FR-021). Observe it FAIL.
- [ ] T057 [P] [US2] Write the failing Bash tests in
      `tests/bash/commands/test_reconcile_field_defaults.bats`: no question when the plan creates
      nothing (FR-013); no question when `ask` is false (FR-014); no question with `--accept-defaults`
      (FR-015); **no question when creations are pending and `ask` is on but neither trigger of
      contract §3.3 fires** — the written type carries optional defaultable fields, nothing is recorded
      against them, and every required field is already satisfiable (FR-028); one question naming each
      field once however many creations are pending (FR-011); an answer applies to every creation in
      the run (FR-012); a decline resumed with `--accept-defaults` is indistinguishable from an
      acceptance and the summary gives that one reason (FR-015). Observe them FAIL.
- [ ] T058 [P] [US2] Write the PowerShell twin in
      `tests/powershell/commands/Reconcile.FieldDefaults.Tests.ps1`. Observe it FAIL.
- [ ] T059 [US2] Write the failing test for summary provenance in
      `tests/bash/commands/test_reconcile_field_defaults.bats`: every filled field is named with its
      source — `team-config`, `operator-answer`, or bridge — and the raw payload is never printed
      (FR-022). Observe it FAIL. Not `[P]`: same file as T057.
- [ ] T060 [US2] Write the PowerShell twin in
      `tests/powershell/commands/Reconcile.FieldDefaults.Tests.ps1`. Observe it FAIL. Not `[P]`: same
      file as T058.
- [ ] T061 [P] [US2] Write the failing dry-run agreement test in
      `tests/bash/commands/test_reconcile_dry_run.bats`: the preview predicts every defaulted value and
      its source, asks no question, and writes nothing (FR-023). Observe it FAIL.
- [ ] T062 [P] [US2] Write the PowerShell twin in `tests/powershell/commands/Reconcile.DryRun.Tests.ps1`.
      Observe it FAIL.
- [ ] T063 [US2] Write the failing non-blocking test in
      `tests/bash/commands/test_reconcile_field_defaults.bats`: a hook-fired run that stops for the
      question, and one that fails while applying a default, both leave the host command's outcome
      unchanged and emit at most one warning line (FR-020). Observe it FAIL. Not `[P]`: same file as
      T057.
- [ ] T064 [US2] Write the PowerShell twin in
      `tests/powershell/commands/Reconcile.FieldDefaults.Tests.ps1`. Observe it FAIL. Not `[P]`: same
      file as T058.

### Implementation for User Story 2

- [ ] T065 [US2] Stop the run after planning and before any write when contract §3.3's conditions hold,
      in `scripts/bash/commands/reconcile.sh`. The trigger is what the run would **send** — a recorded
      default about to land, or a required field left unsatisfiable — never what the issue type merely
      offers; keying it on defaultability would make the feature visible to teams that recorded
      nothing and break FR-028. The planning pass is the existing `--dry-run` computation — do not add
      a second planning path, or the preview and the run can disagree.
- [ ] T066 [US2] Implement the twin in `scripts/powershell/commands/Reconcile.psm1`.
- [ ] T067 [US2] Emit the `confirmation-pending` object of `data-model.md` §4 — one per run, each field
      once, with its recorded value and `resume_with` — in `scripts/bash/commands/reconcile.sh`.
- [ ] T068 [US2] Implement the twin in `scripts/powershell/commands/Reconcile.psm1`.
- [ ] T069 [US2] Apply `--field-value` answers with precedence over recorded defaults, for this run
      only, in `scripts/bash/commands/reconcile.sh` (FR-012).
- [ ] T070 [US2] Implement the twin in `scripts/powershell/commands/Reconcile.psm1`.
- [ ] T071 [US2] Honour the per-project `ask` switch and `--accept-defaults` in
      `scripts/bash/commands/reconcile.sh` (FR-014, FR-015), recording in the summary which of contract
      §3.4's reasons applied.
- [ ] T072 [US2] Implement the twin in `scripts/powershell/commands/Reconcile.psm1`.
- [ ] T073 [US2] Add the field/source lines and the `config --field-default …` promotion line to the run
      summary in `scripts/bash/commands/reconcile.sh` (FR-022, FR-021).
- [ ] T074 [US2] Implement the twin in `scripts/powershell/commands/Reconcile.psm1`.

**Checkpoint**: User Stories 1 and 2 both work independently. The mirror is confirmable, overridable,
and silent when the team has settled.

---

## Phase 5: User Story 3 — Nothing recorded: a refusal that hands back a remedy (Priority: P2)

**Goal**: when nothing is recorded, the run either asks for the missing value or refuses with a
message that names the fields and carries the command that fixes it forever.

**Independent Test**: against a repository with no recorded defaults, run the reconcile with
`--accept-defaults`; assert zero writes, the pre-existing exit code, and a message whose remedy
command, when run, makes the Phase 3 scenario pass.

### Tests for User Story 3 ⚠️ write first, observe FAIL

- [ ] T075 [US3] Write the failing Bash tests in
      `tests/bash/commands/test_reconcile_field_defaults.bats`: with no default and no answer, the run
      refuses for that specification with zero writes and the pre-existing exit code, and the message
      names each field by its Jira label and carries a copy-pasteable
      `config --field-default …` line (FR-016). Observe them FAIL. Not `[P]`: same file as T057,
      which Phase 4 created.
- [ ] T076 [US3] Write the PowerShell twin in
      `tests/powershell/commands/Reconcile.FieldDefaults.Tests.ps1`. Observe it FAIL. Not `[P]`: same
      file as T058.
- [ ] T077 [P] [US3] Write the failing test for a non-defaultable field in
      `tests/bash/sink/test_hierarchy.bats`: it is reported with its reason, by label, and the
      pre-existing refusal path is unchanged (FR-010). Observe it FAIL.
- [ ] T078 [P] [US3] Write the PowerShell twin in `tests/powershell/sink/Hierarchy.Tests.ps1`.
      Observe it FAIL.
- [ ] T079 [US3] Write the failing test for a rejected value in
      `tests/bash/commands/test_reconcile_field_defaults.bats`: when Jira rejects a creation over a
      defaulted value, the run names the field by label and the value it sent, explains the rejection
      in human terms rather than relaying the API body, substitutes nothing, and does not retry
      (FR-019). Observe it FAIL. Not `[P]`: same file as T057.
- [ ] T080 [US3] Write the PowerShell twin in
      `tests/powershell/commands/Reconcile.FieldDefaults.Tests.ps1`. Observe it FAIL. Not `[P]`: same
      file as T058.
- [ ] T081 [P] [US3] Write the failing scenario
      `tests/conformance/scenarios/us3-field-defaults-remedy.json` — the mandatory-field fixture with
      nothing recorded and `--accept-defaults`, expecting the refusal and the remedy line. Observe it
      FAIL.
- [ ] T081a [US3] Reconcile the shipped `tests/conformance/scenarios/us3-mandatory-field-refusal.json`
      with §3.3's second trigger. Run 1 (`--dry-run`) is unchanged — §4.3 keeps the preview on the
      refusal path. Run 2 currently invokes `reconcile --json` with no flag and will now emit
      `confirmation-pending` with exit `0`. Give run 2 that expectation and add a third run —
      `["reconcile", "--json", "--accept-defaults", "specs/001-reporting/spec.md"]` — carrying the
      refusal assertion the scenario was named for, so both halves of the changed behaviour are
      covered on the very fixture the defect came from. Not `[P]`: it edits a shipped scenario the
      other US3 scenarios are validated alongside.

### Implementation for User Story 3

- [ ] T082 [US3] Extend the refusal message with the per-field remedy command in
      `scripts/bash/sink/jira/hierarchy.sh`, keeping the exit code and the zero-writes guarantee
      exactly as they are.
- [ ] T083 [US3] Implement the twin in `scripts/powershell/sink/jira/Hierarchy.psm1`.
- [ ] T084 [US3] Report a non-defaultable field with its reason, by label, in
      `scripts/bash/sink/jira/hierarchy.sh` and `scripts/bash/commands/config.sh` (FR-010).
- [ ] T085 [US3] Implement the twins in `scripts/powershell/sink/jira/Hierarchy.psm1` and
      `scripts/powershell/commands/Config.psm1`.
- [ ] T086 [US3] Translate a Jira field-validation rejection into the human message of FR-019 in
      `scripts/bash/commands/reconcile.sh`, without substituting a value and without retrying.
- [ ] T087 [US3] Implement the twin in `scripts/powershell/commands/Reconcile.psm1`.

**Checkpoint**: all three stories are independently functional. The only surviving refusal carries its
own cure.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T088 [P] Write and run the inertness scenario
      `tests/conformance/scenarios/sc010-no-defaults-untouched.json`, modelled on the shipped
      `sc009-core-untouched.json`: with nothing recorded, every command's output is byte-identical to
      the pre-feature release (FR-028, SC-010). The fixture's written types MUST carry at least one
      **optional** defaultable custom field and MUST have creations pending, so the scenario actually
      proves the §3.3 trigger is keyed on what the run would send rather than on what the type offers
      — without that, the scenario passes vacuously. Every **required** field of those types MUST
      already be satisfiable by the bridge, or §3.3's second trigger fires and the scenario asserts
      the opposite of what it claims.
- [ ] T089 [P] Document `field_defaults`, the `ask` switch, and the managed region in
      `templates/config.yml.template`, self-documenting enough that a tech lead needs no other page
      (Principle XVI).
- [ ] T090 [P] Add the new closed questions and the `--field-default` flag, normatively, to
      `commands/speckit.jira.config.md` — including that the entry point never prompts, that only
      required fields are asked about, and that an optional field's default is stated through the flag
      or written into `config.yml` by hand (FR-004).
- [ ] T091 [P] Add the consolidated question, the re-invocation with `--accept-defaults` /
      `--field-value`, and the non-interactive instruction to `commands/speckit.jira.reconcile.md`.
      State normatively what the agent does when the operator **declines** or the conversation ends
      without an answer: re-invoke with `--accept-defaults`, never leave the run half-finished. There
      is no decline flag, and the agent must not invent one (FR-015, contract §3.5).
- [ ] T091a [P] State the unreachable-operator contract of §3.10 in
      `commands/speckit.jira.reconcile.md`: a caller that cannot reach an operator — continuous
      integration, an unattended run, a direct script invocation — passes `--accept-defaults` on its
      **first** invocation; the entry point never infers reachability and never sniffs a TTY; a
      hook-fired run is **not** such a caller, because it fires the agent command and the agent is
      there to ask (FR-015, research R4).
- [ ] T092 [P] Document the mechanism in `docs/04-config-ceremony.md` (recording) and
      `docs/05-reconcile-flow.md` (applying), with the Mermaid diagrams those files use.
- [ ] T093 [P] Move the field-defaults entry in `docs/VISION.md` from the Part 3 backlog to Part 1,
      per its own Part 4 rule for how an item leaves that document.
- [ ] T094 [P] Add the CHANGELOG entry for the MINOR version bump in `CHANGELOG.md`.
- [ ] T095 Run `bash tests/conformance/ci-conformance.sh` and resolve every cross-port divergence.
      A divergence that appears only on Windows is diagnosed by pushing to `ci/windows-probe` and
      reading the annotations — never by emulating the toolchain locally (Principle VI).
- [ ] T096 Verify coverage ≥ 80% statements on both ports, with the critical paths — satisfiability,
      resolution precedence, the surviving refusal — near 100% (Principle XIII).
- [ ] T097 [P] Run `shellcheck $(git ls-files '*.sh')`, `actionlint`, and PSScriptAnalyzer clean.
- [ ] T098 Confirm the engine/sink boundary greps stay green: no new Jira identifier in
      `scripts/*/engine/`, and `managed_section` still knows nothing about what it splices.
- [ ] T099 Walk every scenario of [quickstart.md](quickstart.md) end to end on macOS, Linux, and
      Windows.
- [ ] T100 Dogfood against a real Jira project whose written types carry mandatory custom fields —
      the instance shape that produced the defect — and record the result (Principle XII).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: no dependencies.
- **Phase 2 (Foundational)**: depends on Phase 1 for its fixtures. **Blocks all three stories.**
- **Phase 3 (US1)**: depends on Phase 2. Independently shippable — this is the MVP.
- **Phase 4 (US2)**: depends on Phase 2. Does **not** depend on Phase 3 in code, but is far easier to
  demonstrate once US1 can record a default, so schedule it after unless staffing says otherwise.
- **Phase 5 (US3)**: depends on Phase 2 only for its code. Genuinely independent of US1 and US2 — it
  is about what happens when nothing was recorded. One file-level caveat: T075 and T079 append to the
  test file T057 creates in Phase 4. Taking US3 before US2 means that file does not exist yet — create
  it in T075 and let T057 extend it instead.
- **Phase 6 (Polish)**: depends on every story that is being shipped.

### Within Each Phase

- The test task always precedes its implementation task. Observe the failure; a test that passes
  before the implementation is testing the wrong thing.
- Bash and PowerShell implementations of one behaviour are siblings, not sequential: either may go
  first, but the phase is not complete until both exist and the conformance scenario is green.
- Discovery (T005–T008) precedes persistence (T009–T012), which precedes resolution (T025–T028).
- The satisfiability change (T021–T024) is independent of the payload merge (T029–T032); they can
  proceed in parallel.

### Parallel Opportunities

- T001, T002, T004 — different files.
- Every `[P]`-marked test pair (Bash + PowerShell) — always different files. Two test tasks writing
  the **same** file are never both `[P]`, however different their assertions:
  `test_config_field_defaults.bats` is written by T038 then extended by T040, T041a, T041c;
  `test_reconcile_field_defaults.bats` is written by T057 then extended by T059, T063, T075, T079.
- Within Phase 2: the discovery track (T005–T008), the CLI track (T017–T020), and the satisfiability
  track (T021–T024) touch disjoint files and can run concurrently.
- Within Phase 3: T035, T036, T037 are three independent scenario files.
- Phase 6: T088–T094 and T097 are all independent.

---

## Parallel Example: Phase 2 foundational tracks

```bash
# Three developers, three disjoint tracks, after Phase 1:
Track A: "Discovery defaultable fields — T005, T006, T007, T008"
Track B: "CLI flags — T017, T018, T019, T020"
Track C: "Satisfiability predicate — T021, T022, T023, T024"

# Then, still parallel:
Track A: "Persistence — T009 … T012" then "Resolution — T025 … T028, T033, T034"
Track B: "Config read and schema — T013 … T016"
Track C: "Payload merge — T029 … T032"
```

## Parallel Example: User Story 1 tests

```bash
# All five test tasks are different files — launch together, watch all five fail:
Task: "us1-field-defaults-record.json scenario — T035"
Task: "us1-field-defaults-idempotent.json scenario — T036"
Task: "us1-mandatory-field-satisfied.json scenario — T037"
Task: "test_config_field_defaults.bats — T038"
Task: "Config.FieldDefaults.Tests.ps1 — T039"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 — Setup.
2. Phase 2 — Foundational. Nothing ships without it.
3. Phase 3 — User Story 1.
4. **STOP and VALIDATE**: run T037's scenario. A project that could not be mirrored at all is now
   mirrored, with no Jira administration change and no ticket created by hand. That is SC-001, and it
   is the whole point of the feature.
5. This is a shippable release on its own: the blocking defect is closed. The operator is not yet
   asked to confirm at creation time — defaults simply apply, which is the behaviour User Story 2's
   `ask: false` setting produces anyway.

### Incremental Delivery

1. Setup + Foundational → substrate ready.
2. + User Story 1 → the defect is closed. **Ship.**
3. + User Story 2 → the developer confirms or overrides at creation time. **Ship.**
4. + User Story 3 → the remaining refusal carries its own remedy. **Ship.**
5. + Polish → documentation, the inertness proof, the three-OS run, the dogfood.

Each increment leaves the extension in a state where a team that records nothing sees no change at all
(FR-028) — so shipping partway is safe at every step.

### Parallel Team Strategy

Phase 2 is the only serialising constraint, and it splits cleanly into three tracks (see the parallel
example above). Once it lands, US1, US2, and US3 can be taken by three people; the stories share
files only in `commands/reconcile.sh` (US2 and US3), which is worth coordinating or sequencing.

---

## Notes

- Every behaviour ships in both ports. "Done in Bash" is half a task.
- Verify each test fails before implementing it. Principle XIII is not advisory.
- Never put `$'\r\n'` inside a glob pattern, and never call `jq` directly in the Bash port — go
  through `scripts/bash/lib/output.sh` (see `docs/10-windows-portability.md`).
- Tests must identify processes, files, and ports by an identifier they recorded themselves, never by
  a name pattern or a machine-wide scan — the suites run in parallel.
- The full Bash suite takes about 3m10s via `tests/run-bash.sh`; use `--since <ref>` for the inner
  loop. Continuous-integration runners are roughly 6–8× slower than a local machine — size any
  timeout from real Actions timings, not from local wall clocks.
- Commit after each task or logical pair (a behaviour and its twin).
