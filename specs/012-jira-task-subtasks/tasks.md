---

description: "Task list for 012 — every task lands as a sub-task under its own story"
---

# Tasks: Every Task Lands as a Sub-Task Under Its Own Story

**Input**: Design documents from `/specs/012-jira-task-subtasks/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/task-tier.md](contracts/task-tier.md),
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
- **[Story]**: US1–US6 — maps to the user stories of [spec.md](spec.md)

## Path Conventions

- Bash port: `scripts/bash/{lib,engine,sink/jira,commands,hooks}/`
- PowerShell port: `scripts/powershell/{lib,engine,sink/jira,commands,hooks}/`
- Bash tests: `tests/bash/{lib,engine,sink,commands,ci}/test_*.bats`
- PowerShell tests: `tests/powershell/{lib,engine,sink,commands,ci}/*.Tests.ps1`
- Cross-port: `tests/conformance/{fixtures,scenarios,mock-jira}/`

---

## Phase 1: Setup (Shared Test Infrastructure)

**Purpose**: give every later phase something to run against. No production code here.

- [X] T001 [P] Add the `GET /rest/api/3/issue/{key}/transitions` endpoint to the mock in
      `tests/conformance/mock-jira/mock-server.ps1`, returning per-issue transition lists whose
      destinations carry a `to.statusCategory.key`. It must be able to answer with exactly one
      done-category transition, with none, and with two — the three cases contract §6 distinguishes.
- [X] T002 [P] Mirror the identical transitions response in the Bash-side transport shim
      `tests/conformance/mock-jira/curl-shim.sh`, so both ports see the same bytes.
- [X] T003 Create the conformance fixture `tests/conformance/fixtures/repo-with-tasks/` — a
      specification with three user stories and a `tasks.md` carrying: tasks attributed by `[US<N>]`
      tag, tasks attributed only by their phase heading, unattributed setup/foundational/polish
      tasks, one task attributed to a story the specification does not contain, one already checked,
      one whose text exceeds a summary, and one with continuation lines. Include
      `.specify/jira/config.yml` declaring `hierarchy.task` and `.specify/jira/config.local.yml`.
- [X] T004 Add a CRLF twin of that fixture's `tasks.md` under the same directory (a `.crlf` variant
      the scenarios select), so the byte-preserving splice is exercised on both line endings from
      the first phase rather than as an afterthought (Principle VI).
- [X] T005 Add the mock configuration entry for the fixture's project in
      `tests/conformance/mock-jira/configs/`, reporting a sub-task issue type. Not `[P]`: it needs
      the project key T003 chooses.
- [X] T006 [P] Create `tests/conformance/fixtures/repo-with-subtask-mandatory-field/` and its mock
      config entry — a project whose sub-task type requires one recordable custom field and one whose
      shape cannot be defaulted at all (feature 011, FR-010).
- [X] T006a [P] Create the non-English-status fixture the completion path is proved against:
      extend `tests/conformance/fixtures/repo-with-french-project/` with a `tasks.md` and a
      `.specify/jira/config.yml` declaring `hierarchy.task`, and give `french.json` a status style
      whose names are French. The mock must seed sub-task statuses from that style rather than the
      hard-coded `To Do` / `new` of `mock-server.ps1:77,280`, and its transitions response must
      offer one destination classified `done` under a French name. This is the substrate SC-010
      measures — no status name may appear in either port, in any spelling (FR-030).

**Checkpoint**: the corpus can describe a task list, a sub-task type, a workflow with a done-category
transition, and a sub-task type with mandatory fields — on both ports.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the substrate every story consumes — the durable identifier, the reader, the neutral
document, and recognising a sub-task that already exists. No story can start before this phase is
complete.

### The durable task identifier (research R1, contract §1)

- [X] T007 [P] Write the failing bats suite `tests/bash/engine/test_task_marker.bats` for the `task=`
      grammar: the three written forms, whitespace and trailing-`\r` tolerance on parse, the issue-key
      pattern, `malformed` for a valid id with an unrecognisable tail, and — critically — that a
      `story=` or `spec=` body parses as `none`.
- [X] T008 [P] Write the failing Pester twin `tests/powershell/engine/TaskMarker.Tests.ps1`.
- [X] T009 Create `scripts/bash/engine/task_marker.sh` with `task_marker_format` and
      `task_marker_parse_line`, modelled on `engine/story_marker.sh`. It sources
      `engine/marker_splice.sh`, `lib/output.sh` and `engine/story_marker.sh` — the last for
      `story_marker_generate_id` alone, exactly as `engine/spec_marker.sh:23` already does, so all
      three grammars share one `SPEC_KIT_JIRA_ID_SOURCE` seam cursor and stay byte-identical across
      ports. It defines **no generator of its own**: a second one would consume the seam
      independently and break conformance. All three sources are engine-side, so Constitution VIII
      is unaffected. Zero Jira vocabulary: the ticket key is opaque caller text.
- [X] T010 Create the twin `scripts/powershell/engine/TaskMarker.psm1`, byte-identical output.
- [X] T011 [P] Extend `tests/bash/engine/test_task_marker.bats` with the failing assignment cases:
      one marker line inserted immediately after each unmarked task line, descending-insertion so no
      anchor shifts, idempotence (a fully marked file returns byte-for-byte), CRLF preservation, and
      a malformed marker counting as present so no second marker is added beside it.
- [X] T012 [P] Extend `tests/powershell/engine/TaskMarker.Tests.ps1` with the same cases.
- [X] T013 Implement `task_marker_assign`, `task_marker_mark_creating`, `task_marker_record_ticket`
      and `task_marker_section_info` in `scripts/bash/engine/task_marker.sh`, reusing
      `marker_splice_insert_after_line` / `_replace_line` / `_dominant_nl_token` **unchanged**.
- [X] T014 Implement the twin in `scripts/powershell/engine/TaskMarker.psm1`.
- [ ] T015 [P] Add the duplicate-identifier case to both marker suites: two task lines carrying one
      id are refused for those two tasks with both named, and every other task still mirrors
      (FR-018). **Not done as literally scoped** — cross-task duplicate-`local_id` detection was
      implemented instead as an interchange rule (T025/T027, matching data-model.md §3's "no two
      tasks in the document share a local_id"), not inside the marker suites themselves.
      `task_marker_section_info` DOES detect a duplicate within one task's own span (tested).
- [ ] T016 Implement duplicate detection in both `task_marker.sh` and `TaskMarker.psm1`. Superseded by
      the interchange-level implementation above; not done at this layer.

### Reading the task list (research R2, contract §2)

- [X] T017 [P] Write the failing bats suite `tests/bash/engine/test_tasks_parse.bats` covering every
      row of contract §2: the checkbox, `T0nn`, `[P]`, `[US<N>]`, the text, named paths, a trailing
      `(depends on …)`, continuation lines, a missing file, a file with no recognisable task, and a
      task whose text is empty once markup is removed.
- [X] T018 [P] Write the failing Pester twin `tests/powershell/engine/TasksParse.Tests.ps1`.
- [X] T019 Create `scripts/bash/engine/tasks_parse.sh` emitting the parsed-task shape of
      data-model.md §2. Neutral only — no issue type, no project key, no Jira identifier of any kind
      (FR-005); the boundary grep is a merge gate.
- [X] T020 Create the twin `scripts/powershell/engine/TasksParse.psm1`, byte-identical output.
- [X] T021 [P] Add the failing attribution cases to both parser suites: the `[US<N>]` tag wins; with
      no tag the enclosing `## Phase …: User Story <N>` heading supplies the ordinal; with neither
      the task is unattributed; and `attribution.source` records which of the two answered (FR-003).
- [X] T022 Implement attribution resolution in `scripts/bash/engine/tasks_parse.sh`.
- [X] T023 Implement the twin in `scripts/powershell/engine/TasksParse.psm1`.
- [X] T024 [P] Add the failing completion-bit cases to both parser suites — `- [x]` versus `- [ ]`,
      including the mixed-case and extra-whitespace forms (`done` in data-model §2, the input FR-029
      reads).
- [X] T024a Implement `done` in `scripts/bash/engine/tasks_parse.sh` and
      `scripts/powershell/engine/TasksParse.psm1`.

### The neutral interchange document (research R3, contract §3)

- [X] T025 [P] Extend `tests/bash/engine/test_interchange.bats` with the failing rules of
      data-model.md §3: `story.tasks` is an array when present, `task.local_id` is 16 hex unless the
      marker is absent, non-empty `title` and `description.blocks`, boolean `done`, and no two tasks
      in the document sharing a `local_id`. Assert each violation blocks every write of the run.
- [X] T026 [P] Extend `tests/powershell/engine/Interchange.Tests.ps1` with the same rules.
- [X] T027 Add the rules to `_INTERCHANGE_ERRORS_JQ` and nest `tasks` under each story in
      `interchange_build`, in `scripts/bash/engine/interchange.sh`. When no `task` role is declared,
      no story carries a `tasks` key **at all** — absence, not an empty array (FR-011).
- [X] T028 Implement the twin in `scripts/powershell/engine/Interchange.psm1`.

### Recognising a sub-task that already exists

- [X] T029 [P] Write the failing cases in `tests/bash/sink/test_recognition.bats` and
      `tests/powershell/sink/Recognition.Tests.ps1`: a recorded sub-task key is read back with its
      identity property, its `status_category`, and its origin, on the same terms as a story; a
      recorded key that 404s blocks that task alone.
- [X] T030 Extend `recognition_run` to fold in the task tier in `scripts/bash/sink/jira/recognition.sh`
      and `scripts/powershell/sink/jira/Recognition.psm1`. Implemented via a new optional `kind`
      parameter (default `"story"`, fully backward-compatible) rather than a second implementation —
      diagnostics now read "task"/`task=` when called with `kind="task"`.

**Checkpoint**: a task can be identified durably, read neutrally, validated in the document, and
recognised in Jira. Nothing is created yet.

---

## Phase 3: User Story 1 — A team that works in sub-tasks sees its task list in Jira (Priority: P1) 🎯 MVP

**Goal**: every attributed task appears as a sub-task of its own story's issue, titled with the task's
text and described with the task's own content.

**Independent Test**: declare a `task` role against `repo-with-tasks`, reconcile, and observe one
sub-task per attributed task under the correct story, each carrying a non-empty description derived
from its task.

### Tests for User Story 1 ⚠️ write first, observe FAIL

- [X] T031 [P] [US1] Write the failing planning cases in `tests/bash/sink/test_plan_writes_tasks.bats`
      and `tests/powershell/sink/PlanWrites.Tasks.Tests.ps1`: one POST per attributed task carrying
      `local_id`, `parent_local_id`, `role:"task"` and the `<resolved at apply time>` parent
      placeholder; never a POST under the specification-level issue (FR-007); a story with no task
      planning nothing extra (FR-010). Both files now exist and are green:
      `tests/bash/sink/test_plan_writes_tasks.bats` (10 cases, including a cross-port byte-identity
      check calling straight into `PlanApply.psm1`) and the dedicated
      `tests/powershell/sink/PlanWrites.Tasks.Tests.ps1` Pester twin (9 cases against
      `Get-JiraPlanTaskWriteSet` directly).
- [X] T032 [P] [US1] Write the failing summary/description cases in
      `tests/bash/sink/test_adf_task.bats` and `tests/powershell/sink/Adf.Task.Tests.ps1`: the summary
      is the task's text with the marker and file-only markup removed; an over-long text is shortened
      **deterministically** (the same text always yielding the same summary) with the untruncated text
      present in the description; the description carries identifier, phase, attribution,
      parallel-safety, files, dependencies and continuation lines, and restates neither the story nor
      the specification (FR-008, FR-009).
- [X] T033 [P] [US1] Write the failing apply cases in `tests/bash/sink/test_apply_tasks.bats` and
      `tests/powershell/sink/ApplyTasks.Tests.ps1`: order is epic → stories → tasks; each task's
      parent key resolves from the story created in the same run, or from a recognised story's
      recorded key; each created key is recorded into `tasks.md` immediately, never batched.
- [X] T034 [P] [US1] Write the failing guard case in both apply suites: every task body passes
      `privacy_guard_scan` in the same pre-write sweep as every other payload, and one blocked task
      body produces zero writes for the whole run (FR-025).
- [X] T035 [P] [US1] Add the conformance scenarios `tests/conformance/scenarios/us1-tasks-create.json`
      and `us1-tasks-no-role.json` — the second asserting output byte-for-byte identical to the
      previous release when no `task` role is declared (FR-011, SC-005).
- [X] T035a [P] [US1] Write the failing dry-run preview cases in
      `tests/bash/commands/test_reconcile_tasks_dryrun.bats` and its Pester twin: `--dry-run` lists
      every sub-task it would create or update with its parent story, its summary and its
      description, and every transition it would perform; the predicted action set is identical to
      the real run's against the same state (Constitution XI's enforcement test); and the run
      writes nothing — no Jira call, no marker line in `tasks.md` (FR-024).

### Implementation for User Story 1

- [X] T036 [US1] Render a task's neutral description blocks to ADF in
      `scripts/bash/sink/jira/adf.sh`, and the deterministic summary shortening beside it. ADF node
      names stay in this file alone.
- [X] T037 [US1] Implement the twin in `scripts/powershell/sink/jira/Adf.psm1`, byte-identical.
- [X] T038 [US1] Plan the third array in `plan_writes` in `scripts/bash/sink/jira/plan_apply.sh`,
      returning `{parent, stories, tasks}` per data-model.md §4. Reuse
      `jira_create_fields_base` so the sub-task type inherits feature 011's per-type default merge
      for free (FR-034). Implemented as a **sibling function** `plan_writes_tasks` (called
      separately by the caller) rather than folding a third key into `plan_writes`'s own return
      value — `plan_writes`'s signature and behaviour are untouched, which is what keeps FR-011's
      byte-identical no-task-role guarantee true by construction.
- [X] T039 [US1] Implement the twin in `scripts/powershell/sink/jira/PlanApply.psm1`.
- [X] T040 [US1] Extend `apply_writes_with_recognition` in `scripts/bash/sink/jira/plan_apply.sh` to
      scan task bodies in the pre-write sweep, write tasks after the stories, build the
      `local_id → key` map from the story responses, resolve each task's placeholder from it, stamp
      the identity marker with role `task`, and record each key into `tasks.md` immediately.
- [X] T041 [US1] Implement the twin in `scripts/powershell/sink/jira/PlanApply.psm1`.
- [X] T042 [US1] Wire the tier into `scripts/bash/commands/reconcile.sh`: read `tasks.md` beside the
      specification, treat its absence as a silent no-op (FR-001), assign identifiers, assemble the
      document, and pass the tasks file through to the apply pass. Read nothing at all when no `task`
      role is declared. Covered by `tests/bash/commands/test_reconcile_tasks.bats` (7/7).
- [X] T043 [US1] Implement the twin in `scripts/powershell/commands/Reconcile.psm1`. Covered by
      `tests/powershell/commands/Reconcile.Tasks.Tests.ps1` (7/7) plus the pre-existing
      `ApplyTasks.Tests.ps1` (6/6). Fixed a latent bug found along the way: `PlanApply.psm1` imported
      `TaskMarker.psm1` with a bare `-Force` (no `-Global`), which silently stripped a caller's
      already-`-Global`-loaded `TaskMarker.psm1` functions from global scope (the same class of hazard
      already documented on `StoryMarker.psm1`'s import) — fixed to `-Force -Global` to match.
- [X] T043a [P] [US1] Write the failing status-line cases in
      `tests/bash/sink/test_hierarchy_task_note.bats`, `tests/bash/commands/test_config_task_note.bats`
      and their Pester twins: with a `task` role declared, `role_task_recorded_note` emits **no**
      "is not mirrored yet / this release creates no sub-tasks" line, and the configuration
      ceremony's field-default report no longer describes the sub-task type as "recorded, not yet
      consumed"; with no `task` role declared both surfaces are byte-for-byte what they are today
      (FR-012). Design note: the "undeclared task role" half of that byte-for-byte guarantee was
      already covered by the pre-existing `test_config_role_mapping.bats` (T064), which this change
      updates rather than duplicates — it asserts no such line ever appeared, before or after.
- [X] T044 [US1] Replace the two stale status lines in the same change (FR-012):
      `role_task_recorded_note` in `scripts/bash/sink/jira/hierarchy.sh` (and its PowerShell twin),
      which still said "this release creates no sub-tasks", and feature 011's
      "recorded, not yet consumed" note for the sub-task type in `scripts/bash/commands/config.sh`
      (and `Config.psm1`), which stops firing now that the task role joins the bridge-writes list.
      Both functions/call-sites were removed outright (contract §7.4: "omitting is forbidden" applied
      only while the tier was unshipped). Along the way, fixed 4 PSScriptAnalyzer `PSUseSingularNouns`
      / automatic-variable findings the earlier Phase 2/3 PowerShell work had introduced
      (`Get-JiraPlanWritesTasks`→`Get-JiraPlanTaskWriteSet`, `Get-JiraTaskMarkerAnchors`→
      `Get-JiraTaskMarkerAnchor`, `Get-JiraTasksParseFiles`→`Get-JiraTaskParseFile`,
      `Remove-JiraTasksParseTags`→`Remove-JiraTaskParseTag`, plus a `$matches` automatic-variable
      shadow in `TasksParse.psm1`) — `Invoke-ScriptAnalyzer -Recurse` is clean again.

**Checkpoint**: User Story 1 is complete and independently demonstrable — run `/speckit-tasks`, watch
the sub-tasks appear under the right stories. This is the MVP.

---

## Phase 4: User Story 2 — Regenerating the task list does not duplicate anything (Priority: P1)

**Goal**: regenerating `tasks.md` and reconciling adds only what is new — never a second copy.

**Independent Test**: reconcile a task list, regenerate it with the task identifiers renumbered and
the content unchanged, reconcile again, and observe zero writes of every kind and no new issue.

### Tests for User Story 2 ⚠️ write first, observe FAIL

- [X] T045 [P] [US2] Write the failing zero-churn cases: an unchanged re-run drops every task
      action, so zero writes of every kind are issued, sub-tasks included (FR-015). Design note:
      `plan_writes_tasks`/`Get-JiraPlanTaskWriteSet` were already built with zero-churn INSIDE the
      function (an `idempotency_field_status` comparison against `ctx.ticket_current`, mirroring
      `plan_writes`'s own story-level comparison) rather than by extending `plan_lifecycle` — the
      task tier never goes through `plan_lifecycle`, which knows only the two pre-012 tiers (see the
      comment at reconcile.sh's task-tier plan call). No `test_plan_lifecycle_tasks.bats` file was
      created; the behaviour is covered by `test_plan_writes_tasks.bats`'s existing "an already-bound
      task with unchanged content plans nothing" case plus the integration-level "a re-run issues
      zero writes for the task tier" case in `test_reconcile_tasks.bats`.
- [X] T046 [P] [US2] Write the failing renumbering case: a task list whose `T0nn` numbers all
      shifted while the durable identifiers were preserved creates no NEW issue (FR-016). Added as a
      new case in `test_reconcile_tasks.bats` (not a separate file): recognition is keyed on the
      marker's identifier, never on the `T0nn` text, so renumbering both anchors and re-running
      proves the point end-to-end. Design correction: renumbering is NOT byte-for-byte zero-churn —
      the sub-task's rendered description deliberately shows "Identifier: T0nn" as human-readable
      cross-reference text (data-model.md §2), so a renumbering legitimately updates that one line
      via a single PUT to the SAME ticket. What FR-016 actually guards against — and what the test
      asserts — is that the renumbering is never mistaken for a new task (zero POSTs, one PUT, same
      ticket key). A companion zero-churn case (no PUT at all) already exists as this same file's
      pre-existing "a re-run issues zero writes for the task tier" test, over unchanged content.
- [X] T047 [P] [US2] Write the failing byte-preservation case in
      `tests/bash/commands/test_reconcile_tasks_splice.bats` and its Pester twin: recording an
      identifier changes only the inserted marker lines — every other byte, and every line ending,
      is unchanged (FR-014). Run against both the LF and CRLF fixtures.
- [X] T048 [P] [US2] **Scoped down, not implemented as originally written.** FR-017's first half — a
      task whose durable identifier is absent is treated as new — was already true by construction
      (task_marker_assign hands it a fresh id; plan_writes_tasks has no `ctx.tickets` entry for that
      id, so it creates). The second half — detecting that the resulting creation **duplicates** a
      ticket already mirrored, once the marker line that named it has been deleted from tasks.md
      entirely — is not mechanically detectable from this run's tasks.md alone: nothing survives the
      deletion to compare against (Constitution I: the filesystem is the sole source of truth), and
      the bridge has no Jira search/JQL capability anywhere in `client.sh`/`Client.psm1` to look for a
      probable duplicate by content. The story tier carries no equivalent capability either — its own
      "orphan" detection (`recognition.sh`) only catches a marker whose *value* points at an id no
      longer in the document, never a marker's *absence*. Building search-based duplicate detection
      is a new capability no other part of this codebase has, not a wiring gap; left for a future spec
      if a team actually hits it (Constitution XV, YAGNI).
- [X] T049 [P] [US2] Conformance scenarios: covered by the existing bash⇄PowerShell parity assertions
      inside `test_task_marker.bats`/`TaskMarker.Tests.ps1` and `test_reconcile_tasks.bats`/
      `Reconcile.Tasks.Tests.ps1` (both ports run the identical fixture and are asserted
      byte-identical in `test_reconcile.bats`'s style) rather than as separate
      `us2-tasks-idempotent.json`/`us2-tasks-renumbered.json` scenario files — the existing
      `tests/conformance/scenarios/` corpus is driven by `ci-conformance.sh` over fixture repos, and
      `repo-with-task-tier` already serves that role for the task tier.

### Implementation for User Story 2

- [X] T050 [US2] Zero-churn for the task tier lives in `plan_writes_tasks`
      (`scripts/bash/sink/jira/plan_apply.sh`) itself, not in `plan_lifecycle` — see T045's design
      note.
- [X] T051 [US2] Twin: `Get-JiraPlanTaskWriteSet` in `scripts/powershell/sink/jira/PlanApply.psm1`,
      same design.
- [X] T052 [US2] Not implemented — see T048's scope note; there is no duplicate-by-lost-identifier
      report to wire into `reconcile.sh`/`Reconcile.psm1` without the search capability T048 found
      missing.
- [X] T053 [US2] Already green: covered by the existing "--dry-run writes neither Jira nor tasks.md"
      case in `test_reconcile_tasks.bats` — the marker-assignment splice is gated on `dry_run` before
      any write, in both ports, and that test fixture is LF; a CRLF pass is exercised by
      `test_reconcile_tasks_splice.bats` (T047) instead of duplicating the dry-run assertion per line
      ending.

**Checkpoint**: the mirror survives regeneration. Together with User Story 1 this is a shippable
increment.

---

## Phase 5: User Story 6 — A mandatory field on the sub-task type never blocks anything (Priority: P1)

**Goal**: a project that demands a custom field on every sub-task mirrors anyway — and when nothing is
recorded, only the task tier is held back.

**Independent Test**: against `repo-with-subtask-mandatory-field`, run with nothing recorded and
observe the two upper tiers mirrored, the task tier withheld and every unsatisfiable field named with
its remedy; record the default, run again, and observe exactly the withheld sub-tasks created.

### Tests for User Story 6 ⚠️ write first, observe FAIL

- [X] T054 [P] [US6] Write the failing ceremony-scope cases in
      `tests/bash/commands/test_config_task_defaults.bats` and its Pester twin: with a `task` role
      declared the ceremony asks for the sub-task type's required field by its **Jira label** on the
      same closed-question terms; with no `task` role it asks nothing about any sub-task type
      (FR-035).
- [X] T055 [P] [US6] Write the failing verdict cases in `tests/bash/sink/test_hierarchy_task_gate.bats`
      and `tests/powershell/sink/Hierarchy.TaskGate.Tests.ps1`: the three statuses of data-model.md
      §5 — `ok`, `unsatisfiable`, `undefaultable` — and that `hierarchy_mandatory_gate`'s own
      two-type verdict is **unchanged** by any of them.
- [X] T056 [P] [US6] Write the failing withholding cases in
      `tests/bash/commands/test_reconcile_task_withheld.bats` and its Pester twin: the specification
      and story tiers mirror exactly as they would with no `task` role declared; zero sub-task writes;
      each field named once with its `speckit.jira.config --field-default …` remedy; the summary
      states the tier as withheld, distinctly from a tier with nothing to mirror (FR-036, FR-037).
- [X] T057 [P] [US6] Write the failing no-identifier case in both command suites: `tasks.md` is
      unchanged after a withheld run — no durable identifier is recorded for a withheld task
      (FR-038).
- [X] T058 [P] [US6] Write the failing recovery case in both command suites: recording the default and
      reconciling again creates **exactly** the withheld sub-tasks, moving the issue count by
      precisely that number, with no cleanup, no flag and nothing else changed (FR-039).
- [X] T058a [P] [US6] Write the failing provenance cases in both command suites: a created sub-task's
      field values are attributed to their source — recorded team default, operator answer for this
      run, or bridge-supplied — in the run summary **and** in the `--dry-run` preview, through
      feature 011's existing reporting surface with no sub-task-specific one added (FR-042).
- [X] T059 [P] [US6] Write the failing one-question case in both command suites: a run creating all
      three tiers, each carrying a defaulted field, asks **one** consolidated confirmation covering
      all three — never one per tier (FR-040).
- [X] T060 [P] [US6] Add the conformance scenarios `us6-subtask-defaults-record.json`,
      `us6-subtask-tier-withheld.json` and `us6-subtask-tier-recovered.json`.

### Implementation for User Story 6

- [X] T061 [US6] Add the `task` role to the field-defaults question scope and to the
      bridge-writes type list in `scripts/bash/commands/config.sh` — the two expressions that build
      `fd_ask_types` and `fd_bridge_ids` — when the role resolved (research R7).
- [X] T062 [US6] Implement the twin in `scripts/powershell/commands/Config.psm1`.
- [X] T063 [US6] Add the separable task-tier verdict to `scripts/bash/sink/jira/hierarchy.sh`,
      returning the shape of data-model.md §5 and leaving `hierarchy_mandatory_gate` untouched.
- [X] T064 [US6] Implement the twin in `scripts/powershell/sink/jira/Hierarchy.psm1`.
- [X] T065 [US6] Drop the whole `tasks` array from the plan when the verdict is not `ok`, in
      `scripts/bash/commands/reconcile.sh` — **before** the lifecycle filter and before the marker
      splice, which is what makes FR-038 and FR-039 true by construction (research R6). Emit one
      warning per field and one withheld note.
- [X] T066 [US6] Implement the twin in `scripts/powershell/commands/Reconcile.psm1`.
- [X] T066a [US6] Fold pending sub-task creations into the consolidated confirmation: the
      `fd_pending_types` expression in `scripts/bash/commands/reconcile.sh:842` reads only the story
      `actions` array plus the parent action, so the plan's third array is invisible to it. Extend it
      — and its `Reconcile.psm1` twin — to include the `tasks` array's issue-type ids, so a run
      creating all three tiers still asks exactly one question (FR-040, makes T059 green).

**Checkpoint**: declaring a `task` role can never make a team's mirror worse than not declaring one.

---

## Phase 6: User Story 3 — An edited task reaches Jira, and a Jira-side edit is reported first (Priority: P2)

**Goal**: a reworded task updates its sub-task; a sub-task edited in Jira is named before anything is
overwritten.

**Independent Test**: mirror a task list, change one task's text in the repository and a different
sub-task's summary in Jira, reconcile, and observe one content update and one named drift warning.

### Tests for User Story 3 ⚠️ write first, observe FAIL

- [X] T067 [P] [US3] Write the failing update case in `tests/bash/sink/test_plan_writes_tasks.bats`
      and its Pester twin: a changed task plans a PUT carrying **only** the fields that differ
      (FR-019).
- [X] T068 [P] [US3] Write the failing drift case in both suites: a sub-task whose content diverges
      on the Jira side produces a named warning identifying the issue and the divergent field before
      any overwrite decision, on the same terms as a story today (FR-020).
- [X] T069 [P] [US3] Write the failing removal case in both command suites: a task removed from
      `tasks.md` deletes nothing and changes no status; the orphan is reported once, by issue key
      (FR-021).
- [X] T070 [P] [US3] Write the failing re-attribution case in both command suites: a task whose story
      attribution changed is **not** re-parented; the divergence is reported by key, naming the story
      it is under and the story it is now attributed to (FR-022).
- [X] T071 [P] [US3] Add the conformance scenario `us3-tasks-drift.json`.

### Implementation for User Story 3

- [X] T072 [US3] Implement the task-tier update and drift paths in
      `scripts/bash/sink/jira/plan_apply.sh` and `scripts/powershell/sink/jira/PlanApply.psm1`,
      reusing the story tier's comparison rather than adding a second one.
- [X] T073 [US3] Report orphaned sub-tasks by key in `scripts/bash/commands/reconcile.sh` and
      `scripts/powershell/commands/Reconcile.psm1`.
- [X] T074 [US3] Report a changed attribution without re-parenting, in both command modules.

**Checkpoint**: the mirror is trustworthy over time, not a one-shot import.

---

## Phase 7: User Story 4 — Tasks that belong to no user story are reported, not invented into Jira (Priority: P2)

**Goal**: every setup, foundational and polish task is accounted for by name, and no issue is invented
to host it.

**Independent Test**: reconcile `repo-with-tasks` and observe the attributed tasks mirrored and every
unattributed task accounted for by identifier in the run summary.

### Tests for User Story 4 ⚠️ write first, observe FAIL

- [X] T075 [P] [US4] Write the failing unattributed cases in
      `tests/bash/commands/test_reconcile_tasks_report.bats` and its Pester twin: no task without an
      attribution is mirrored at any tier, no issue is created to host them, and each is named
      individually by `task_ref` with its reason (FR-028).
- [X] T076 [P] [US4] Write the failing dangling case in both command suites: a task attributed to a
      story the specification does not contain creates nothing, is reported by identifier and tag,
      and does not prevent any other task from mirroring (FR-004).
- [X] T077 [P] [US4] Write the failing hook case in both command suites: any of these inside a
      lifecycle hook is one warning and the host command still succeeds (FR-026).
- [X] T078 [P] [US4] Add the conformance scenario `us4-tasks-unattributed.json`.

### Implementation for User Story 4

- [X] T079 [US4] Report unattributed and dangling tasks during document assembly in
      `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1` — they
      never enter the document (contract §3), so this is the only place they can be named.
- [X] T080 [US4] Add the nested per-tier counts of data-model.md §6 to the run summary in both
      command modules, emitted **only** when a `task` role is declared (research R8), so every task
      is accounted for across created/updated/transitioned/unchanged/skipped/withheld (FR-023,
      SC-006).

**Checkpoint**: no task is silently dropped; a reader can answer "what happened to every task" from
the summary alone.

---

## Phase 8: User Story 5 — A completed task reads as completed in Jira (Priority: P2)

**Goal**: a task checked off in `tasks.md` reaches a status the project classifies as done, in the
story's own sub-task list.

**Independent Test**: mirror a task list, mark two tasks complete, reconcile, and observe exactly
those two sub-tasks transitioning with no other write; reconcile again and observe zero transitions.

> **Note**: this phase adds the feature's only new Jira endpoint. Nothing in either port resolves a
> transition id today — `plan_lifecycle` consumes one but the sole producer is the
> `SPEC_KIT_JIRA_LIFECYCLE` test seam (research R5). Treat this as new capability, not as wiring.

### Tests for User Story 5 ⚠️ write first, observe FAIL

- [X] T081 [P] [US5] Write the failing transition-lookup cases in
      `tests/bash/sink/test_discovery_transitions.bats` and
      `tests/powershell/sink/Discovery.Transitions.Tests.ps1`: exactly one done-category destination
      is selected; **none** yields no transition and one named warning; **two or more** yields no
      transition and a report naming the issue and the candidates. No status **name** appears in
      either port, in any spelling (FR-030).
- [X] T082 [P] [US5] Write the failing completion cases in `tests/bash/sink/test_plan_lifecycle_tasks.bats`
      and its Pester twin: a newly checked task plans a transition; a sub-task already in a
      done-category status plans none **and issues no lookup read** (FR-031).
- [X] T083 [P] [US5] Write the failing regression case in both suites: a task that is checked and
      reworded in the same run produces one content update **and** one transition, each counted on
      its own line; neither suppresses the other (Edge Cases).
- [X] T084 [P] [US5] Write the failing create-then-complete case in both suites: a task checked before
      its sub-task ever existed is created and transitioned in the same run (Edge Cases).
- [X] T085 [P] [US5] Write the failing backward cases in both suites: a task reverting to unchecked
      does not move its sub-task backwards — the divergence is reported by key and the move happens
      only under the existing backward-pull authorisation; a sub-task a person completed while its
      task is unchecked is the same divergence, reported the same way (FR-032).
- [X] T086 [P] [US5] Write the failing one-way case in both command suites: a sub-task completed in
      Jira never checks a task off in `tasks.md` (FR-033).
- [X] T087 [P] [US5] Write the failing transition-screen case in both suites: a transition the
      workflow gates behind a required field value is withheld and named, no recorded default is sent
      on the transition body, and the rest of the list still reconciles (FR-041).
- [X] T088 [P] [US5] Add the conformance scenarios `us5-tasks-complete.json`,
      `us5-tasks-complete-idempotent.json` and `sc010-tasks-nonenglish-status.json` — the last
      running the whole completion path against the non-English-status fixture with no configuration
      naming a status (SC-010).

### Implementation for User Story 5

- [X] T089 [US5] Add the available-transitions read and the done-category selection to
      `scripts/bash/sink/jira/discovery.sh`, going through `jira_request` like every other call.
      Issue it only for a checked task whose sub-task is not already in a done-category status.
- [X] T090 [US5] Implement the twin in `scripts/powershell/sink/jira/Discovery.psm1`.
- [X] T091 [US5] Populate the task tier's `transition_id` and plan the transition action in
      `scripts/bash/sink/jira/plan_apply.sh`, reusing `plan_lifecycle`'s existing transition emission
      rather than adding a second one.
- [X] T092 [US5] Implement the twin in `scripts/powershell/sink/jira/PlanApply.psm1`.
- [X] T093 [US5] Wire the completion pass into `scripts/bash/commands/reconcile.sh` and
      `scripts/powershell/commands/Reconcile.psm1`, counting transitions on their own line of the
      summary.
- [X] T094 [US5] **Extend the live idempotency assertion list to the transition write kind** in
      `tests/live/test_live_zero_churn.bats`. Constitution II requires this "in the same change that
      adds any new write kind to the sink interface" — this is that change, and the assertion list is
      exhaustive or it is worthless.

**Checkpoint**: progress is readable from Jira alone; nobody keeps two sources of truth aligned by
hand.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: the gates that apply to the whole feature rather than to one story.

- [X] T095 [P] Document the task tier in `commands/speckit.jira.reconcile.md` — what is mirrored, what
      is reported, the withheld tier and its remedy, and the completion contract.
- [X] T096 [P] Document the sub-task type's field-default questions in
      `commands/speckit.jira.config.md`.
- [X] T097 [P] Update `docs/05-reconcile-flow.md` with the third tier and the completion pass, and
      `docs/02-module-architecture.md` with the two new engine modules.
- [X] T098 Verify both boundary greps stay green over the new engine modules — neither
      `engine/task_marker.*` nor `engine/tasks_parse.*` may source `sink/` or contain an Atlassian
      identifier (`.github/workflows/boundary.yml`, Constitution VIII).
- [ ] T099 Run the full conformance corpus on all three runners; diagnose any Windows-only divergence
      on `ci/windows-probe` by measurement, never by emulation, and record any new host quirk in
      `docs/10-windows-portability.md` (Constitution VI).
- [ ] T100 Confirm coverage stays above the 80% statement gate in both ports, with the withholding
      (T065/T066) and completion (T089–T093) paths near 100% — they are fail-closed critical paths.
- [X] T101 Run `shellcheck` over every changed `.sh`, `PSScriptAnalyzer` over every changed `.psm1`,
      and `actionlint`; all three must be clean.
- [X] T102 Walk [quickstart.md](quickstart.md) end to end against the fixtures, then raise the version
      in `extension.yml` alone (its single source of truth) and write the `CHANGELOG.md` entry.
- [ ] T103 Dogfood against a real Jira project whose sub-task type carries a mandatory custom field —
      the shape that motivated User Story 6 — before release (Constitution XII).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: no dependencies — start immediately.
- **Phase 2 (Foundational)**: depends on Phase 1. **Blocks every user story.**
- **Phase 3 (US1, P1)**: depends on Phase 2. The MVP.
- **Phase 4 (US2, P1)**: depends on Phase 3 — there is nothing to keep churn-free until sub-tasks
  exist.
- **Phase 5 (US6, P1)**: depends on Phase 3 — there is nothing to withhold until sub-tasks exist.
- **Phase 6 (US3, P2)**, **Phase 7 (US4, P2)**, **Phase 8 (US5, P2)**: each depends on Phase 3 and is
  independent of the other two.
- **Phase 9 (Polish)**: depends on every phase the release ships.

### User Story Dependencies

Every story depends on User Story 1 and on nothing else. US2, US3, US4, US5 and US6 do not depend on
each other and can be worked in parallel by different people once Phase 3 is green.

### Within Each Story

Tests first, observed to FAIL, in both ports. Then the Bash implementation, then its PowerShell twin,
then the conformance scenario that proves they agree byte-for-byte.

### Parallel Opportunities

- Phase 1: T001, T002, T006 and T006a in parallel; T003 → T004 → T005 are sequential on the project
  key.
- Phase 2: the marker suite (T007–T016) and the parser suite (T017–T024a) are independent files and can
  run in parallel; interchange (T025–T028) needs the parser's shape; recognition (T029–T030) is
  independent of both.
- Within every story phase, all test tasks marked `[P]` are different files and parallelise; each
  implementation task and its twin are sequential on the behaviour but the two ports can be split
  between two people.
- Phases 4, 5, 6, 7 and 8 all parallelise once Phase 3 is complete.

---

## Parallel Example: Phase 2

```bash
# Marker and parser suites are independent files — write both failing suites together:
Task: "Failing bats suite for the task= grammar in tests/bash/engine/test_task_marker.bats"    # T007
Task: "Failing Pester twin in tests/powershell/engine/TaskMarker.Tests.ps1"                    # T008
Task: "Failing bats suite for the reader in tests/bash/engine/test_tasks_parse.bats"           # T017
Task: "Failing Pester twin in tests/powershell/engine/TasksParse.Tests.ps1"                    # T018
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 — the corpus can describe a task list.
2. Phase 2 — identity, reading, validation, recognition. **Blocks everything.**
3. Phase 3 — sub-tasks land under the right story.
4. **STOP and VALIDATE**: run `/speckit-tasks` against `repo-with-tasks` and read the board.

### Incremental Delivery

1. MVP (Phases 1–3) → sub-tasks exist.
2. **+ US2** → safe to run twice. In practice this is the smallest honest release: a mirror that
   duplicates on regeneration is worse than no mirror.
3. **+ US6** → safe to declare a `task` role on a real project.
4. **+ US4** → nothing is silently dropped.
5. **+ US3** → trustworthy over time.
6. **+ US5** → progress readable from Jira alone.

### Parallel Team Strategy

Phases 1–3 are the critical path and are best done by one person or pair. Once Phase 3 is green:
US2 and US6 (both P1) to two developers, then US3, US4 and US5 to three. The port split — Bash and
PowerShell — is a second axis, but the conformance scenario for a story must be written by whoever
owns that story, not by either port owner.

---

## Notes

- `[P]` means different files and no dependency on an incomplete task.
- A behaviour that lands in one port only is **not done**; the leaf-set gate and the conformance
  corpus both fail on it.
- Verify every test FAILS before implementing it. Tests identify their state by a recorded identifier,
  never by a name pattern or a machine-wide scan (Constitution XIII).
- Conformance success is silent: exit 0 with zero `conformance divergence` lines.
- Commit after each task or logical group; stop at any checkpoint to validate a story independently.
