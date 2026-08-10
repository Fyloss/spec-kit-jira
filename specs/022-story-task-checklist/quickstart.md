# Quickstart: proving the checklist mode works

**Feature**: 022-story-task-checklist | **Date**: 2026-08-09

Validation scenarios, in the order they should be run. Each names the user story or requirement it
proves. This is a run guide — the implementation lives in `tasks.md` and the code.

## Prerequisites

- Bash 4.0+ (macOS: a Homebrew Bash; the OS-shipped 3.2 does not qualify), `jq`, `bats`
- PowerShell 7+ and Pester, for the second port
- For §6 only, and §6 is optional: a real Jira Cloud project and `JIRA_API_TOKEN` — a mock cannot answer
  what §6 asks. Every other section runs against the mock, with no instance and no credentials

## 1. The suites

```sh
tests/run-bash.sh                      # full bash suite, ~190s
tests/run-bash.sh --since main         # change-scoped inner loop, ≤60s
bash tests/conformance/ci-conformance.sh   # cross-port byte equivalence
shellcheck -x -P scripts/bash $(find scripts/bash -name '*.sh')
```

Conformance success is silent: exit 0 with no `conformance divergence` line is the pass. The temp paths
it prints are harness noise.

## 2. The setting round-trips (US3 — FR-008…FR-013)

```sh
# Nothing recorded: the question is reported, config.yml is not touched
speckit.jira.config CONSUMER
#   expect: "how should tasks be mirrored — choose one of: subtask, checklist"
#   expect: config.yml has no task_mirror region  (outcome: inert)

# Answer it
speckit.jira.config CONSUMER --task-mirror 'CONSUMER=checklist'
#   expect: the managed region appears, "Task mirror: CONSUMER — checklist (recorded)"

# Re-run: nothing re-asked, file byte-identical
cp .specify/jira/config.yml /tmp/before.yml
speckit.jira.config CONSUMER
cmp /tmp/before.yml .specify/jira/config.yml     # must be silent
```

**Refusal** — hand-edit the value to `checklists` (plural) and run any command that reads the config:
expect exit 4, zero writes, and a message naming the setting, the project, the offending value and both
accepted values.

**Retired key** — add `task_strategy: per_story` and expect the pre-existing retired-key refusal,
unchanged (FR-006).

## 3. A hundred tasks, six issues (US1 — FR-014…FR-024, SC-001)

Fixture: 5 stories, 100 attributed tasks across 3 phases.

```sh
speckit.jira.reconcile specs/NNN-fixture --dry-run
```

Expect: 1 specification + 5 story writes, **zero task-tier creations**, and each story's planned
description showing a `Tasks` section with its own entries grouped by phase, each with its state.

Then reconcile for real and assert:

- the Jira project gained 6 issues, not 106;
- each story's checklist holds exactly its own tasks, in `tasks.md` order;
- a story with no attributed task has **no** `Tasks` section at all;
- every unattributed task is named individually in the summary, by task identifier, with its reason;
- `tasks.md` is byte-for-byte unchanged — no durable identifier was assigned (FR-031).

## 4. Completion follows the file (US2 — FR-025…FR-029)

```sh
# check three boxes in tasks.md, then
speckit.jira.reconcile specs/NNN-fixture
```

Expect exactly those three entries complete, `entries.completed: 3`, and no issue's **status** changed —
not the story's, not the specification's (FR-029).

Uncheck one and reconcile: it renders incomplete again (FR-026 — the checklist follows the file in both
directions, unlike a sub-task's status).

**Drift**: edit an entry by hand in Jira, then reconcile. Expect one named warning identifying the story
*before* the rewrite, the checklist rewritten from the file, and `tasks.md` untouched (FR-027, FR-028).

## 5. Zero churn (SC-003, Constitution II)

```sh
speckit.jira.reconcile specs/NNN-fixture     # run 1
speckit.jira.reconcile specs/NNN-fixture     # run 2
```

Run 2 must report `0 created / 0 updated / 0 transitioned` and `checklists.unchanged` equal to the story
count.

Then the case FR-017 exists for: regenerate `tasks.md` with every `T0xx` reference renumbered, the text
and order unchanged. Reconcile. **Still zero writes** — nothing an entry carries can change under a
renumber.

## 6. The live probe — the one a mock cannot answer (research §1, §2)

**Optional, pre-release.** The ADF node shape is decided (research §1: `bulletList` with a ☑/☐ glyph,
because `taskList`/`taskItem` are undocumented and publicly unsupported), so nothing waits on this. What
remains is one assertion a mock structurally cannot make — a mock echoes back exactly what it was sent,
and Jira may not.

```sh
# against a real instance, not the mock — the repo's live tests are bats files
bats tests/live/test_live_checklist_probe.bats
```

It PUTs a description containing the shipped checklist nodes, GETs the same issue, and asserts the
returned `description` is byte-identical after `json_canonical`. The shipped nodes carry no identity
attribute, so the expectation is a clean round trip; a divergence would mean Jira normalises something
the design did not anticipate, and would make the no-op normalisation in
`contracts/checklist-rendering.md` §5 load-bearing after all.

Then the assertion that matters most for this feature:

```sh
# twice against the live instance
speckit.jira.reconcile specs/NNN-fixture && speckit.jira.reconcile specs/NNN-fixture
```

The second run must issue zero writes of every kind. A mock cannot prove this, because a mock echoes back
exactly what it was sent and Jira may not.

## 7. Switching modes destroys nothing (US4 — FR-033…FR-035, SC-006)

```sh
# start in subtask mode, reconcile, count the issues
speckit.jira.reconcile specs/NNN-fixture
# switch
speckit.jira.config CONSUMER --task-mirror 'CONSUMER=checklist'
speckit.jira.reconcile specs/NNN-fixture
```

Expect: the issue count did **not** fall; no sub-task was deleted, closed, transitioned or updated; the
checklist now carries the task list; and one report line naming the stories, the count, and a
copy-pasteable `issue in (PROJ-41, PROJ-42, …)` query listing exactly the abandoned sub-tasks.

Switch back and reconcile: the `Tasks` section disappears from each story's managed region with every
byte above the boundary intact, and the sub-tasks are **re-bound by their preserved durable identifiers**
rather than duplicated (FR-035).

## 8. A project with no sub-task type (US5 — FR-005, SC-007)

Point the bridge at a fixture project reporting no sub-task issue type and no declared `task` role, in
checklist mode. Expect the full task list mirrored, no refusal, and no mention of a missing type — the
case that produces no task tier at all today.

## 9. Windows

```sh
git push origin HEAD:ci/windows-probe     # ~11 min, results arrive as annotations
```

`main` is currently red on `windows-latest` for unrelated reasons: diff this branch's annotations against
`main`'s before reading a red run as a regression. One retry maximum on a `windows-latest` flake, then
hand the result back.

## Validation record (T120)

Walked end to end against the mock on 2026-08-10:

- **§1** (suites): `tests/run-bash.sh --since main` and the full Pester suite both green (1842 and
  1489 tests respectively, no regression beyond the pre-existing, unrelated
  `test_fixtures_are_tracked.bats` fixture-tracking gap). `ci-conformance.sh` exits 0 with zero
  `conformance divergence` lines across the full 139-scenario corpus. `shellcheck`/`actionlint` clean.
- **§2** (setting round-trip): confirmed through the real `spec-kit-jira.sh config` entry point — the
  question fires with `config.yml` byte-for-byte untouched (`inert`), the answer records and reports
  the effect line, a re-run neither re-asks nor rewrites the file, and a malformed value refuses with
  exit 4 naming the setting, project, offending value and both accepted values.
- **§3–§5** (task tier mechanics, completion, drift, zero churn): covered by the Phase 3/4 test suites
  (`test_adf_checklist.bats`, `test_plan_apply_checklist.bats`, `test_plan_apply_checklist_drift.bats`
  and their Pester mirrors) and the `us022-checklist-two-phases`, `us022-checklist-unchanged-rerun`,
  `us022-checklist-entry-completed` and `us022-checklist-crlf` conformance scenarios — all
  byte-identical across ports.
- **§6** (live probe): skipped — optional, pre-release, requires a real Jira Cloud instance.
- **§7** (switching modes): confirmed through the real `spec-kit-jira.sh reconcile` entry point — the
  issue count did not fall, no sub-task was written to, the switch report named the story, the
  abandoned count and the exact `issue in (…)` query, and switching back removed the `Tasks` section
  and re-bound the sub-task by its preserved identifier rather than duplicating it.
- **§8** (no sub-task type): confirmed through the real dispatcher — the full task list mirrored as a
  checklist with no refusal and no mention of a missing type.
- **§9** (Windows probe): deferred — pushing to `ci/windows-probe` is a remote, shared-state action and
  needs an explicit go-ahead before this run pushes anything.

**Noted, out of scope**: the `repo-with-task-tier` conformance fixture's `config.local.yml` fails the
`config` command silently (exit 2, no message) even for an unrelated flag — reconcile against the same
fixture is unaffected. Not chased further here; §2 and §7's config-ceremony assertions above used
`repo-with-config` and a direct `config.yml` edit respectively to route around it.
