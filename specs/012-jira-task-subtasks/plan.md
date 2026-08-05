# Implementation Plan: Every Task Lands as a Sub-Task Under Its Own Story

**Branch**: `feat/handle-tasks` | **Date**: 2026-08-03 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/012-jira-task-subtasks/spec.md`

## Summary

The bridge mirrors two tiers. This feature adds the third, and the spec is right that three tiers is
not two tiers plus a loop: nothing reads `tasks.md` in either port, the neutral document is shaped
`{epic, stories[]}`, the durable-identifier machinery knows two marker grammars, and the run summary
counts one flat pair of tallies.

Four of the five mechanisms are generalisations of something already shipped, and one is genuinely
new.

1. **The durable task identifier generalises the story marker.** `engine/story_marker.sh` already
   generates an opaque 16-hex identifier, formats a three-state marker line, and splices it into a
   file byte-preservingly through `engine/marker_splice.sh` — which `engine/spec_marker.sh` already
   reuses for a *second* grammar (`spec=`). A third grammar (`task=`) in a third sibling module is
   the shape the codebase already has, not a new idea.
2. **The neutral document nests tasks under their story.** `stories[].tasks[]`, validated by the same
   `_INTERCHANGE_ERRORS_JQ` program before any write. Nesting rather than a fourth top-level array
   makes "a task attributed to a story this specification does not contain" unrepresentable in the
   document instead of a runtime check.
3. **Sub-task creation reuses the parent-key placeholder one level down.** Every story creation
   already carries `fields.parent.key = "<resolved at apply time>"`, resolved by
   `apply_writes_with_recognition` from the epic's create response. A task creation carries the same
   placeholder, resolved from its own story's create response, by the same code shape.
4. **Mandatory fields on the sub-task type reuse feature 011 whole.** `plan_resolve_field_defaults`
   is already keyed `{type_id: {field_id: value}}` and `jira_create_fields_base` already scopes the
   merge to the type being created — a third type needs no new plumbing. Only two things change: the
   configuration ceremony's question scope gains the `task` role, and the satisfiability verdict for
   the sub-task type becomes *separable* so it can withhold one tier instead of refusing a
   specification (FR-036).
5. **Completion is the new mechanism.** `plan_lifecycle` emits a transition action when the ticket
   context carries a `transition_id` — but **nothing in either port ever populates it**. It arrives
   only through the `SPEC_KIT_JIRA_LIFECYCLE` test seam, so no shipped code path has ever issued a
   transition. FR-029/FR-030 therefore need a real Jira read that does not exist today: the available
   transitions of an issue, and the one whose destination the project classifies as done. This is the
   single new endpoint of the feature and the reason User Story 5 is planned as its own phase.

The withholding of FR-036 costs almost nothing structurally because of *where* it happens: the task
tier is dropped from the plan before the lifecycle filter, before the marker splice, and before any
write. No durable identifier is recorded for a withheld task (FR-038) not because a rule says so but
because identifiers are assigned to the tasks the plan kept — which is also why recovery (FR-039)
needs no state: the next run simply plans them again.

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port) and PowerShell 7+ (Windows port). Two shipped
implementations of one behaviour; neither is a reference for the other.

**Primary Dependencies**: none added. `jq`, `curl`, `git` on the Bash side, PowerShell built-ins on
the Windows side — all already required. Every new module is a sibling of an existing one in the same
layer and uses the same primitives.

**Storage**: the repository's own files. `spec.md` (already spliced), **`tasks.md` (newly spliced —
the second tracked file the bridge writes into; see Complexity Tracking)**, `.specify/jira/config.yml`
(gains sub-task-type entries inside feature 011's existing `field_defaults` region — no new key), and
`.specify/jira/config.local.yml` (gains the sub-task type's discovered metadata through the same
discovery that already runs per type).

**Testing**: `bats` via `tests/run-bash.sh` for the Bash units, Pester for the PowerShell twins, and
the shared cross-port corpus (`bash tests/conformance/ci-conformance.sh`) for byte equivalence and
identical call sequences against the mock. Coverage: kcov (Bash) and Pester CodeCoverage
(PowerShell), gate at 80% statements, near-100% on the fail-closed and idempotency paths.

**Target Platform**: macOS, Linux, Windows. The three-OS Actions matrix is the merge gate; the
`ci/windows-probe` loop is the only admissible diagnosis for a Windows-only divergence.

**Project Type**: a Spec Kit extension shipped as twin native script ports. No build step, no compiled
artifact, no runtime download.

**Performance Goals**: an unchanged re-run adds **zero** Jira requests — the transitions read of
User Story 5 is issued only for a task that is checked in the file and whose sub-task is not already
in a done-category status, which is empty in the steady state. A first mirror of a feature costs one
POST per attributed task, plus at most one transitions read and one transition POST per task that is
already checked.

**Constraints**: byte-identical output between ports on everything crossing platforms; the `tasks.md`
splice must preserve CRLF exactly as the `spec.md` splice does; no `$'\r\n'` inside any glob pattern
(`docs/10-windows-portability.md`); no direct `jq` in the Bash port outside `lib/output.sh`; no
Atlassian identifier in any `engine/` file — the two boundary greps in `.github/workflows/boundary.yml`
are a merge gate and the two new engine modules are squarely in their scope.

**Scale/Scope**: 2 new engine modules per port and roughly 8 existing files per port touched, plus
their PowerShell twins; 2 command documents; conformance fixtures and scenarios for each user story.
**109 tasks across 9 phases** ([tasks.md](tasks.md)) — six user stories, each behaviour costing a
failing test and an implementation in each of the two ports, which is what a twin-port TDD project
costs per behaviour.

## Constitution Check

*GATE: passed before Phase 0 research; re-checked after Phase 1 design — see "Post-Design Re-Check".*

| # | Principle | Gate verdict |
| --- | --- | --- |
| I | Filesystem Is the Source of Truth | **Pass.** `tasks.md` is the reference and the sub-task tier is derived from it. No delete path is added: an orphaned sub-task is reported by key (FR-021), a re-parenting is reported not performed (FR-022), completion flows one way only (FR-033). The only new *write into the repository* is the bridge's own marker line — the same class of write the story marker already performs, and it never touches a byte a human wrote. |
| II | Zero-Churn Idempotency | **Pass, with an obligation.** Recognition is keyed on the durable identifier alone (FR-013), never on the task number, text, or position. The feature adds one genuinely new write kind to the sink — **transition** — so Constitution II's enforcement clause applies literally: the live idempotency assertion list must be extended in this same change. That is a planned task, not a note. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | **Pass.** Every refusal path decides before the write pass, which is last. FR-036's withholding is fail-closed *at the write*: the sub-task writes that cannot be formed are not issued while the correct, independently satisfiable specification and story writes still happen. `after_tasks` and `after_implement` already route through the command layer's non-blocking wrapper, unchanged. |
| IV | Credential Security | **Pass, unaffected.** No new credential surface: one more repository file read, one more issue type written through the existing authenticated client. The new transitions read goes through `jira_request` like every other call. |
| V | Separation of Team Config / Local Binding / Secrets | **Pass.** No configuration key is added. The `task` role (010) and `field_defaults` (011) both already exist in the committable layer; discovered sub-task metadata stays in the gitignored binding. A hook still never writes `config.yml` (011 FR-021). |
| VI | Portability | **Pass, with the usual hazard named.** The `tasks.md` splice is the third file the bridge edits and therefore the third place a CRLF host can diverge; `marker_splice.sh` already carries the `_ms_count_crlf` fix and is reused unchanged rather than reimplemented. Conformance gains task-tier scenarios; a Windows-only divergence is diagnosed on the probe, never emulated. |
| VII | No Hard-Coded Jira Assumptions | **Pass, and this is the principle the feature leans on hardest.** The sub-task type is whatever the team declared as the `task` role. The completion target is resolved from `statusCategory` as the project itself reports it — no status name in either port, in any spelling or language. Zero or several done-category transitions are reported, never resolved by preference. |
| VIII | Neutral Engine / Jira Sink | **Pass.** Both new modules are engine-side and carry zero Jira vocabulary: `task_marker` treats the ticket key as opaque caller text exactly as `story_marker` does, and `tasks_parse` emits ordinals and neutral content. The sub-task type, the parent link, the transition lookup and the field defaults all live in `sink/jira/`. The two boundary greps stay green. |
| IX | Two-Tier Privacy Guard | **Pass.** Sub-task bodies join the existing `privacy_guard_scan` sweep in `apply_writes_with_recognition`'s pre-write gate, before the first write of the run. Task text is the content most likely to name real paths, which is an argument for the guard, not an exemption from it. |
| X | Self-Healing Mirror | **Pass.** No hook is added, removed, or re-registered; the manifest's seven events stay the complete set. `after_tasks` already fires the reconcile this feature rides on. FR-039's recovery is stateless, which is what makes it self-healing rather than a repair command. |
| XI | Universal Dry-Run and Auditability | **Pass, structurally.** The task tier is planned by the same code in both modes; `--dry-run` shows every sub-task, its parent, its summary, its description and every transition it would perform, and writes nothing — including no marker into `tasks.md`. |
| XII | Quality and Catalog Publication | **Pass.** MINOR bump with the version raised only in `extension.yml`, CHANGELOG entry, green three-OS matrix, `shellcheck`/`PSScriptAnalyzer`/`actionlint` clean, dogfood against a real project with a sub-task type before release. |
| XIII | TDD, 80% coverage | **Pass.** Every implementation task in `tasks.md` will be preceded by its failing test in both ports. The completion path and the withholding path are fail-closed critical paths and target near-100%. Tests identify their state by recorded identity, never by pattern. |
| XIV | KISS | **Pass, with one justified addition.** Four of the five mechanisms are reuses of existing primitives; the one new capability (the transitions read) is required by FR-030 and has no simpler form. Two new engine modules rather than growing `parse.sh` is the simpler arrangement, not a richer one. |
| XV | YAGNI | **Pass.** This is feature 010's deferred Phase 8, fired by a written trigger. Nothing is built beyond the spec: no assignees, no estimates, no sprints, no issue links from dependencies, no fourth tier, no orphan deletion, no reverse direction, no configurable status name. The withheld-tier recovery deliberately persists *nothing*, so there is no state to carry that no requirement asked for. |
| XVI | Human Readable | **Pass.** FR-009 puts a task's own context into its description so a sub-task reads on its own; FR-008 guarantees no text is lost to truncation; FR-023 and FR-037 make the summary answer "what happened to every task" without a log. The marker line is an HTML comment — invisible in every markdown renderer. |

**Post-Design Re-Check (after Phase 1)**: unchanged, with one item confirmed rather than assumed. The
design added no dependency and no abstraction layer; the engine gained two modules and no Jira
knowledge; the sink gained one endpoint. Principle II's obligation (extending the live idempotency
assertion list to the transition write kind) survived design as a concrete task rather than being
absorbed. The two Complexity Tracking entries below were both identified before Phase 0 and neither
grew.

## Project Structure

### Documentation (this feature)

```text
specs/012-jira-task-subtasks/
├── plan.md              # This file
├── research.md          # Phase 0 — nine decisions and what was rejected
├── data-model.md        # Phase 1 — entities, document shapes, requirement traceability
├── quickstart.md        # Phase 1 — how to prove the feature works, suite by suite
├── contracts/
│   └── task-tier.md     # Phase 1 — marker grammar, attribution, planning, completion, withholding
├── checklists/
│   └── requirements.md  # Written by /speckit-specify
└── tasks.md             # Phase 2 — NOT created by /speckit-plan
```

### Source Code (repository root)

```text
scripts/bash/
├── engine/
│   ├── task_marker.sh          # NEW — the `task=` grammar, generation, three states, splice
│   ├── tasks_parse.sh          # NEW — tasks.md to neutral tasks, attribution, completion bit
│   ├── marker_splice.sh        # REUSED UNCHANGED — byte/line-ending/atomic-write primitives
│   ├── story_marker.sh         # REUSED UNCHANGED — the grammar the new one is modelled on
│   └── interchange.sh          # stories[].tasks[] validation rules
├── sink/jira/
│   ├── discovery.sh            # sub-task type metadata; done-category transition lookup
│   ├── hierarchy.sh            # the separable task-tier satisfiability verdict; replace the stale note
│   ├── recognition.sh          # recognise recorded sub-tasks by key, fold in the identity property
│   ├── plan_apply.sh           # plan the tasks[] actions; resolve the story-key placeholder; transitions
│   └── identity.sh             # REUSED — the identity marker, stamped with role "task"
└── commands/
    ├── config.sh               # ceremony question scope gains the task role; stale notes retired
    └── reconcile.sh            # read tasks.md, assign, plan, withhold, count per tier

scripts/powershell/             # the twin of every file above — same behaviour, same bytes out
├── engine/{TaskMarker,TasksParse}.psm1   # NEW
├── engine/Interchange.psm1
├── sink/jira/{Discovery,Hierarchy,Recognition,PlanApply}.psm1
└── commands/{Config,Reconcile}.psm1

commands/speckit.jira.reconcile.md   # the task tier, the withheld tier, the completion contract
extension.yml                        # version bump — the single source of truth

tests/
├── bash/{engine,sink,commands}/      # bats units, one per new behaviour
├── powershell/{engine,sink,commands}/# Pester twins
├── live/                             # the idempotency assertion list gains the transition kind
└── conformance/
    ├── fixtures/repo-with-tasks/                 # NEW — attributed, unattributed, dangling, checked
    ├── fixtures/repo-with-subtask-mandatory-field/ # NEW — the withheld-tier fixture
    └── scenarios/us1-*.json … us6-*.json, sc0*.json
```

**Structure Decision**: the dual-port layout is kept exactly; no directory is added to either port.
Two engine modules are created rather than growing `engine/parse.sh` (584 lines, and it owns
`spec.md`'s title ladder — a different document with different rules) or overloading
`engine/story_marker.sh` with a second grammar it would then have to branch on. Every other change
lands in a file that already exists and already owns that concern. The two new conformance fixture
directories are test data, not source.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| **A new Jira read endpoint** — `GET /rest/api/3/issue/{key}/transitions` — the first the bridge has needed since the binding discovery. | FR-029 requires a checked task to reach a status the project classifies as done, and FR-030 forbids naming a status. Nothing in either port resolves a transition id today: `plan_lifecycle` consumes `transition_id`, but the only producer is the `SPEC_KIT_JIRA_LIFECYCLE` test seam, so no shipped path has ever transitioned anything. The destination's `statusCategory` is knowable only from this endpoint. | **A configured status name** is the spec's Out of Scope and Principle VII's exact prohibition — it breaks on the consumer instance whose statuses are French. **Reusing `phase_status_map`** maps a *hook event* to a status *name* for the whole run; the task tier needs a per-issue target derived from classification, so it would import the hard-coded-name problem and answer the wrong question. **Reading the workflow scheme once at binding time** would cache a per-project answer that is per-issue in reality (a sub-task's available transitions depend on its current status) and would go stale silently. The cost is bounded to non-steady-state runs: the read is skipped for a task that is unchecked, and for a sub-task already in a done-category status (FR-031), so an unchanged re-run issues none. |
| **The bridge writes into a second tracked repository file** (`tasks.md`), where until now it only ever spliced `spec.md`. | FR-013 requires a durable identifier that is not the renumbered task number, the editable text, or the position, and FR-014 requires it recorded in `tasks.md` itself. An identifier that is not in the file cannot survive the file being regenerated by `/speckit-tasks` in a form the next run can read back. | **Keying recognition on the task number or text** is forbidden by FR-013 and by Principle II's "never on any operator-editable display name". **A mapping in the gitignored local binding** would make the mirror unshareable — a colleague's clone would re-create every sub-task — and would put the source of truth outside the tracked tree, against Principle I. **A managed region at the end of `tasks.md`** needs a stable key per task to point at, and a regenerated task list has none by design. The splice itself is not new machinery: `marker_splice.sh` performs it, already handles the CRLF host, and is reused unchanged — the addition is a second call site, not a second implementation. |
