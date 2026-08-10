# Implementation Plan: A Story Carries Its Task List as a Checklist, Instead of a Sub-Task Each

**Branch**: `feat/handle-checklist` (spec directory `022-story-task-checklist`) | **Date**: 2026-08-09 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/022-story-task-checklist/spec.md`

## Summary

A per-project setting, `task_mirror`, chooses how the task tier reaches Jira: `subtask` (what feature
012 ships) or `checklist` (one checklist section inside each story's description, one entry per task,
ticked from `tasks.md`). The setting lives in a managed region of the committed team config, is offered
by the configuration ceremony as a closed question answered through `--task-mirror KEY=<value>`, and is
hand-editable afterwards.

The technical shape of the work is smaller than the specification's 42 requirements suggest, because the
neutral interchange document **already carries everything a checklist needs**. Feature 012 nests
`stories[].tasks[]` with each task's `title`, `done`, `phase` and `attribution`; that is neutral
checklist content by construction. So the engine gains no new structure and no new reader — Constitution
VIII is satisfied without touching a single engine file's vocabulary. The work concentrates in four
places per port:

1. **config** — one new top-level key, its validation, its managed region, its ceremony question and its
   `--task-mirror` flag;
2. **adf** — one new renderer, `_adf_checklist_nodes`, appended to the story's managed nodes;
3. **plan_apply** — mode-gating of `plan_writes_tasks`, the checklist drift record, the switch report;
4. **reconcile** — splitting one gate in two: *read `tasks.md`* and *assign durable task identifiers*
   are the same condition today and must stop being so.

One decision was carried into planning unresolved — whether Jira Cloud renders an interactive checkbox
(`taskList`/`taskItem`) inside an issue description, or whether a glyph list is what ships — and
[research.md](./research.md) §1 has since **decided it: the glyph list**. `taskList`/`taskItem` are
undocumented (the ADF node reference 404s), every primary source that drove them through the REST API got
`HTTP 400 INVALID_INPUT`, and official support is an unresolved suggestion. The design isolates the
rendering inside one function per port, so the decision changed one file rather than the plan — and it
dissolved the plan's single largest technical risk, because the node that ships carries no `localId`.

## Technical Context

**Language/Version**: Bash 4.0+ (macOS needs a Homebrew Bash — the OS-shipped 3.2 does not qualify) and
PowerShell 7+. Two native ports, no shared runtime.

**Primary Dependencies**: `jq` (never called directly in the bash port — always through
`lib/output.sh`, per `docs/10-windows-portability.md`), `curl`, `git` (`hash-object` for content
hashing, already the run-state cache's primitive). No new dependency is introduced.

**Storage**: Files only. `.specify/jira/config.yml` (committed, gains the `task_mirror` region),
`tasks.md` (read; **not written** in checklist mode), Jira entity properties (the identity record gains
one field), `.specify/jira/state/<feature>.json` (unchanged — it already hashes `config.yml`, so a mode
edit invalidates the short-circuit for free).

**Testing**: `bats` for the bash port (`tests/run-bash.sh`, ~190s), Pester for PowerShell, the shared
conformance corpus for cross-port byte equivalence (`bash tests/conformance/ci-conformance.sh`), plus
`shellcheck -x` and `actionlint`.

**Target Platform**: macOS, Linux, Windows — all three gated in CI, byte-identical output required.

**Project Type**: CLI extension to spec-kit, script-native (no build step, no download at runtime —
Constitution VI).

**Performance Goals**: No regression against feature 021's budget. Checklist mode is strictly *cheaper*
than sub-task mode: it issues no `POST /issue` per task, no per-sub-task transition lookup and no
recognition read for the task tier. The one added cost is rendering, which is local.

**Constraints**: Zero writes on an unchanged re-run (Constitution II) — the binding constraint on this
feature, and the source of its single largest technical risk (research §2, ADF `localId` echo).
Descriptions have a practical size ceiling, so a very long checklist must degrade per story rather than
fail the run (FR-041).

**Scale/Scope**: A `tasks.md` of 60–150 entries across 3–8 stories is the normal case; 100+ entries in
one story is the stress case for FR-041.

## Constitution Check

*GATE: passed before Phase 0, re-checked after Phase 1 design — see "Post-Design Re-Check" below.*

The specification carries the full 16-row proof table; this section records only what the **design**
adds or puts at risk, which is what a plan-level gate is for.

| # | Principle | Design-level verdict |
| --- | --- | --- |
| I | Filesystem is the source of truth | **Pass.** No new write to the tree: checklist mode writes `tasks.md` never at all (FR-031), which is strictly less than sub-task mode does. The switch report (FR-034) hands the operator a query instead of performing a deletion. |
| II | Zero-churn idempotency | **Pass, and the risk is now closed.** The comparison path (`plan_managed_description_status`) must not see a difference Jira itself introduced. The shipped rendering (research §1) uses `bulletList`/`listItem`, which carry no identity attribute, so there is nothing for Jira to regenerate; the comparison-only normalisation ships as a defensive no-op on the precedent of `_summary_normalise`. The live double-run (T001) remains a pre-release check, no longer a gate. |
| III | Fail-closed on writes, non-blocking on hooks | **Pass.** The new key is validated in `_cfg_schema_errors`, so an invalid value refuses at config-read time with `EXIT_CONFIG` before any Jira call. The ceremony stays non-interactive, so no prompt can hang a hook. |
| IV | Credential security | **Unaffected.** No new credential path, no new transport shape, no new logged value. |
| V | Three config layers | **Pass.** `task_mirror` is a team decision and goes in the committed layer. Nothing is added to `config.local.yml` or `.env`. |
| VI | Portability | **At risk by volume, not by kind.** Every change is mirrored in both ports, and the checklist is rendered through the same canonical-JSON path every other ADF node uses. No new glob, no new pattern match on line endings, so `docs/10-windows-portability.md`'s two hazards are not touched. The conformance corpus grows by the scenarios in FR-040. |
| VII | No hard-coded Jira workflow assumptions | **Strengthened.** Checklist mode resolves no status and needs no issue type. ADF node names remain confined to `sink/jira/adf.sh` and `Adf.psm1`. |
| VIII | Neutral engine / Jira sink | **Pass, and cheaply.** The neutral document is unchanged — `stories[].tasks[]` already *is* the neutral checklist content. The engine learns nothing new; the sink reads what it is already handed. |
| IX | Privacy guard | **Pass.** The checklist rides inside the story's `description` field, which `apply_writes` already sweeps before the first write. No new payload channel is created, so no new guard call site is needed. |
| X | Self-healing mirror | **Pass.** One edited line converges on the next ordinary reconcile. The run-state cache invalidates itself because it already hashes `config.yml`. |
| XI | Dry run and auditability | **Pass.** The checklist is part of the story's planned `description`, which `--dry-run` already prints; FR-037's per-entry display is a reporting addition, not a second code path. |
| XII | Quality and catalog | **Pass.** Four documentation surfaces updated in the same change (FR-042); `shellcheck`/`actionlint` gates unchanged. |
| XIII | TDD, 80% coverage | **Pass.** Every FR maps to an observable outcome; the task ordering below puts each failing test before its implementation. The live-only risk (research §2) gets a live test, because a mock cannot reproduce what Jira echoes back. |
| XIV | KISS | **Pass, and it is the reason for three of the four rejections in research.** No new engine module, no new interchange field, no second defaults surface, no dual-mode write path. |
| XV | YAGNI | **Pass.** Every artifact traces to an FR: `task_mirror` → FR-001, `--task-mirror` → FR-008, the managed region → FR-010, `_adf_checklist_nodes` → FR-014…FR-018, the identity `checklist` digest → FR-027, the switch report → FR-034, the counts → FR-036. Nothing else is added. |
| XVI | Human readable | **Pass.** `task_mirror: checklist` is business vocabulary; the region carries its own explanatory comment as `field_defaults` does; the refusal and the switch report both name values and give a copy-pasteable remedy. |

**No Complexity Tracking entries.** The design introduces no abstraction, no dependency and no
speculative extension point, so the section is omitted rather than filled with "none".

## Project Structure

### Documentation (this feature)

```text
specs/022-story-task-checklist/
├── plan.md                          # This file
├── research.md                      # Phase 0 — the five decisions and the one probe
├── data-model.md                    # Phase 1 — the setting, the checklist, the drift record
├── quickstart.md                    # Phase 1 — how to prove it works
├── contracts/
│   ├── task-mirror-config.md        # the config key, its grammar, its region, its flag
│   └── checklist-rendering.md       # neutral tasks -> checklist nodes, and the drift rule
├── checklists/requirements.md       # from /speckit-specify — all green
└── tasks.md                         # Phase 2 — /speckit-tasks, NOT created here
```

### Source code (repository root)

Every path below already exists; this feature adds no file to either port.

```text
scripts/bash/                                scripts/powershell/
├── lib/
│   ├── config.sh          # schema key + reader     lib/Config.psm1
│   └── cli.sh             # --task-mirror           lib/Cli.psm1
├── commands/
│   ├── config.sh          # question + region       commands/Config.psm1
│   └── reconcile.sh       # split the tier gate     commands/Reconcile.psm1
└── sink/jira/
    ├── adf.sh             # _adf_checklist_nodes    sink/jira/Adf.psm1
    ├── plan_apply.sh      # mode gate, drift, report sink/jira/PlanApply.psm1
    └── identity.sh        # the checklist digest    sink/jira/Identity.psm1

tests/
├── bash/{lib,commands,sink}/…       # bats, one file per module touched
├── powershell/…                     # Pester mirrors
├── conformance/
│   ├── fixtures/repo-with-checklist-mode/     # new fixture
│   └── scenarios/                             # FR-040's four scenarios
└── live/                            # the zero-churn probe (research §2)

docs/04-config-ceremony.md · docs/05-reconcile-flow.md · docs/07-configuration-and-secrets.md · README.md
```

**Structure Decision**: unchanged. Both ports keep their existing module map (`docs/README.md`); the
feature is an extension of six modules per port, not a new layer. The one structural rule it must respect
is the engine/sink boundary: `_adf_checklist_nodes` renders ADF and therefore belongs in `sink/jira/`,
never in `engine/`, and the CI boundary grep enforces it.

## Phase 0 — Research

Complete. See [research.md](./research.md). Six decisions taken: config key shape, checklist placement,
drift record, mode gating, switch detection, and — settled after the plan was first written, from
Atlassian's published sources rather than a live probe — the ADF node shape.

## Phase 1 — Design

Complete:

- [data-model.md](./data-model.md) — the `task_mirror` setting, the rendered checklist, the drift record,
  and the two summary counts, each with its validation rules and its FR.
- [contracts/task-mirror-config.md](./contracts/task-mirror-config.md) — the key's grammar, its managed
  region's bytes, the `--task-mirror` flag, the ceremony's report lines, and the refusal.
- [contracts/checklist-rendering.md](./contracts/checklist-rendering.md) — the total function from a
  story's neutral tasks to its checklist nodes, the ordering and grouping rule, the comparison
  normalisation, and the drift decision table.
- [quickstart.md](./quickstart.md) — the runnable scenarios that prove each user story, including the
  live zero-churn check a mock cannot perform.

### Post-Design Re-Check

Re-evaluated after the contracts were written. No principle moved from pass to fail. Two notes carried
into Phase 2:

- **Constitution II** was the gate that could fail late, and research §1's decision closed it.
  `plan_managed_description_status` compares the *managed region* of the current and new descriptions;
  the checklist is inside that region, so a single byte Jira rewrites (a regenerated `localId`, a
  normalised attribute order) would turn every reconcile into a PUT. The shipped rendering carries no
  `localId` at all, so the specific hazard cannot occur; the normalisation in
  `contracts/checklist-rendering.md` §5 ships as a defensive no-op. The live double-run stays on the
  pre-release checklist rather than ahead of the renderer.
- **Constitution XIV** was applied against one spec-reading ambiguity rather than around it: FR-014
  ("exactly one checklist") and FR-018 ("grouped under phase") are reconciled by reading FR-014 as *one
  checklist **section***, which may hold one list per phase. The reading is stated in
  `contracts/checklist-rendering.md` §2 so no downstream task has to guess, and FR-014 itself was
  subsequently amended to carry it, so the shipped spec and the shipped design now agree in words.
