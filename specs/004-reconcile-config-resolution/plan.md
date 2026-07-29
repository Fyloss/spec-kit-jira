# Implementation Plan: Reconcile Resolves Its Own Routing and Plan Context From Config

**Branch**: `004-reconcile-config-resolution` | **Date**: 2026-07-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-reconcile-config-resolution/spec.md`

## Summary

`reconcile` never reads the repository's own configuration. It takes the project key from an environment variable nothing sets, falls back to the placeholder `PROJ`, builds an empty creation context, and then assembles a creation payload that declares no project at all. Four defects sit on one failure path, and the reported symptom — Jira rejecting the creation for a missing `project` — is produced by the last of them.

The fix is wiring, not new machinery. Every piece already exists and is tested in isolation: `routing_resolve` resolves rules and the default, `config_load` merges and validates both config layers, and `config_resolved_ids_for` persists the discovered identifier table. The command layer simply never called any of them. This plan connects them at the one seam that was left open, adds the project to the creation payload from the neutral document that already carries it, and makes per-project priority availability follow the project's own create metadata instead of a site-wide list.

No new config key, no new file, no new schema field, no new network call. Both ports change together.

## Technical Context

**Language/Version**: Bash >= 4 (macOS/Linux port; enforced by `prereq_check`) and PowerShell 7+ (Windows port)

**Primary Dependencies**: `jq` (Bash port, existing runtime prerequisite); none added by this feature. `kcov` and `bats` (Bash) / `Pester` (PowerShell) remain development-time only.

**Storage**: Files only — `.specify/jira/config.yml` (committed team layer) and `.specify/jira/config.local.yml` (gitignored machine layer). This feature reads both and writes neither.

**Testing**: `bats` unit suites under `tests/bash/`, `Pester` under `tests/powershell/`, and the language-agnostic golden scenarios under `tests/conformance/scenarios/` run against both ports by `run-scenario.sh`. Coverage by `kcov` (Bash, primary gate) and Pester CodeCoverage (PowerShell), 80% statement minimum.

**Target Platform**: macOS, Linux, Windows — three-OS CI matrix, green as a merge gate.

**Project Type**: Script-native CLI extension for Spec Kit. No build step, no compiled artifact, no download.

**Performance Goals**: No new network calls. Resolution adds two local file reads (`config.yml`, `config.local.yml`) per run, both already performed by the `config` command; run duration is unchanged in practice.

**Constraints**: Byte-identical stdout, exit codes, API call sequences and post-run repository tree between the two ports. Zero writes on any unresolved run. No credential or site host in any new diagnostic.

**Scale/Scope**: Four source modules per port plus discovery, roughly 200 changed lines per port, and one new conformance fixture. No migration for existing repositories.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design — result recorded at the bottom of this section.*

| # | Principle | Gate at plan level | Status |
| --- | --- | --- | --- |
| I | The Filesystem Is the Source of Truth | The design makes the filesystem the only source of the values the mirror sends. No delete, no unwarned overwrite, no new adoption path. | PASS |
| II | Zero-Churn Idempotency | Resolution is pure and deterministic from files on disk; identical inputs resolve identically, so a second run still produces zero writes. No identity lookup is added or changed. | PASS |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Every new failure returns through the existing `_reconcile_fault`, which maps to `EXIT_CONFIG` on direct invocation and downgrades to 0 under a hook. `plan_writes` gains a guard that returns non-zero before assembling an incomplete payload. | PASS |
| IV | Credential Security | No credential is read or resolved. The diagnostics catalogue in [contracts/resolution-contract.md](./contracts/resolution-contract.md) names no host and no secret; a test asserts it. | PASS |
| V | Separation of Team Config / Local Binding / Secrets | Both layers are read in their declared roles through the existing `config_load`; neither is written. The machine layer wins on identifiers, which is the separation's own precedence. | PASS |
| VI | Portability | Both ports change in the same commit; the conformance suite asserts byte-identical stdout, exit codes, call sequence and tree. Two new scenarios cover the company-managed and team-managed paths on both ports. | PASS |
| VII | No Hard-Coded Assumptions | The design removes the `PROJ` placeholder fallback and the implicit empty context, and adds none: priority availability comes from the project's own create metadata, never from a rule keyed on project style. See [research.md](./research.md) R4. | PASS |
| VIII | Neutral Engine / Jira Sink | No engine file gains Jira knowledge. Resolution lives in the command layer, which already sources both sides; the project key reaches the payload from the neutral document's existing `routing.project_key`, so nothing new crosses the boundary. See R2. | PASS |
| IX | Two-Tier Privacy Guard | Untouched. Resolution runs strictly before the guard and adds no path around it; `apply_writes` still gates every payload. | PASS |
| X | Self-Healing Automatic Mirror | Directly advanced — this is the change that makes the mirror configure itself. Hook registration and health reporting are untouched. | PASS |
| XI | Universal Dry-Run and Auditability | Resolution happens before the dry-run branch, so prediction and real runs traverse one path. The resolved project appears in the predicted action set. | PASS |
| XII | Quality and Catalog Publication | CHANGELOG entry and version bump are release tasks; three-OS CI and lint stay blocking. No catalog surface changes. | PASS |
| XIII | TDD With a Minimum 80% Coverage | Every behaviour originates from a failing test, per the repository's bug-fix policy. `tasks.md` will order each test task before its implementation task. Critical paths here (fail-closed, payload assembly) target near-100%. | PASS |
| XIV | KISS | The design adds no abstraction: it calls functions that already exist, from the one layer that already sources both of them. The single extraction (a shared creation-fields builder) exists to satisfy FR-025 structurally rather than by convention — justified in R3. | PASS |
| XV | YAGNI | Every changed line traces to a functional requirement; no flag, key or schema field is added. The `GET /priority` call is kept rather than removed precisely because removing it would be speculative — see R4. | PASS |
| XVI | Human Readable | Each failure names one cause, the file involved, and one copy-pasteable command. The diagnostics catalogue is a contract, not scattered strings. | PASS |

**Initial gate**: PASS — no violations, Complexity Tracking not required.

**Post-Phase-1 re-check**: PASS — the design artifacts introduce no new dependency, no new abstraction beyond the one justified in R3, and no new configuration surface. Complexity Tracking remains empty.

## Project Structure

### Documentation (this feature)

```text
specs/004-reconcile-config-resolution/
├── plan.md              # This file
├── research.md          # Phase 0 output — the eight decisions this design rests on
├── data-model.md        # Phase 1 output — resolved entities and their shapes
├── quickstart.md        # Phase 1 output — how to validate the feature end to end
├── contracts/
│   ├── resolution-contract.md   # Inputs, outputs, exit codes, diagnostics catalogue
│   └── creation-payload.md      # The payload shape both creation paths must produce
├── checklists/
│   └── requirements.md  # Spec quality checklist (already complete)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/bash/
├── commands/
│   └── reconcile.sh              # CHANGED — resolves routing + plan context from config
├── sink/jira/
│   ├── plan_apply.sh             # CHANGED — creation payload declares the project
│   ├── ticket.sh                 # CHANGED — exports the shared creation-fields builder
│   └── discovery.sh              # CHANGED — priorities recorded per project
├── engine/
│   └── interchange.sh            # UNCHANGED — routing_resolve is called, not modified
└── lib/
    └── config.sh                 # UNCHANGED — config_load is called, not modified

scripts/powershell/
├── commands/Reconcile.psm1       # CHANGED — same four behaviours
└── sink/jira/
    ├── PlanApply.psm1            # CHANGED
    ├── Ticket.psm1               # CHANGED
    └── Discovery.psm1            # CHANGED

tests/bash/
├── commands/test_reconcile_routing.bats        # NEW — US1
├── commands/test_reconcile_plan_context.bats   # NEW — US2, US3
└── sink/test_plan_apply_project.bats           # NEW — US1.6, US4

tests/powershell/                               # mirrors the three suites above

tests/conformance/
├── scenarios/us8-reconcile-company-managed.json   # NEW
├── scenarios/us8-reconcile-team-managed.json      # NEW
├── fixtures/repo-with-reconcile-binding/          # NEW — config.yml + config.local.yml
└── mock-jira/fixtures/createmeta-fields-company.json  # CHANGED — priority allowedValues
```

**Structure Decision**: The existing script-native layout is kept exactly as is. The change is confined to the command layer (`commands/reconcile.sh`), which is the only layer permitted to read config and call both the engine and the sink, plus three sink modules. No engine file changes, which is what keeps Principle VIII's boundary intact. Both ports carry identical changes, and the conformance suite is the mechanism that proves it.

## Complexity Tracking

> No Constitution Check violations. This section is intentionally empty.
