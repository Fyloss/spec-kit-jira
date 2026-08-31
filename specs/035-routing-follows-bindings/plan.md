# Implementation Plan: routing follows a specification's own bindings

**Branch**: `035-routing-follows-bindings` | **Date**: 2026-08-31 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/035-routing-follows-bindings/spec.md`

## Summary

A bound specification currently re-routes to `routing_default`, because 033's
ping-pong guard suppresses the rank that placed it without ever reading the
record it cited as its justification. The repair is one rank inserted into an
existing chain — the project the specification's own markers carry — plus one
pre-check that makes a project mismatch a refusal instead of a silent
re-creation, evaluated before any Jira read so both refusals are free by
construction. Three sink-side surfaces that implemented the old behaviour are
retired rather than left contradicting the new one.

Everything reduces to one derived value: the SET of distinct project prefixes a
document's bound markers carry. Empty means unbound and today's resolution
applies untouched; one element is the new rank and the value every tier is
compared against; more than one is a refusal. See
[research.md §R2](research.md) for why one value answers three requirements.

## Technical Context

**Language/Version**: Bash 3.2+ (macOS system bash) and PowerShell 7+, the two
native ports this repository maintains in parity.

**Primary Dependencies**: `jq` (bash port, reached only through
`scripts/bash/lib/output.sh`), `curl`. No new dependency.

**Storage**: none added. No key enters `config.yml`, `personal.yml`, or
`config.local.yml`; nothing new is written to disk.

**Testing**: `bats` + `jq` for the bash port (`tests/run-bash.sh`), Pester for
PowerShell, and `tests/conformance/ci-conformance.sh` for cross-port byte
equivalence. `shellcheck` and `actionlint` are blocking.

**Target Platform**: macOS, Linux, Windows. Windows is exercised on the real
runner via `ci/windows-probe`, never by emulation.

**Project Type**: CLI bridge — two native ports proven equivalent by a shared
conformance corpus.

**Performance Goals**: the new scan adds one pass over a document already read
into memory, spawning nothing per line, per marker, or per story
(contract C1.5). The resolver keeps its one-process budget (C2.7).

**Constraints**: no loop on the reconcile path may spawn an external process per
item, and no batched payload may travel through a command-line argument that
grows with input. The new scan touches neither: it is shell-native and its
output is a short sorted list.

**Scale/Scope**: two ports; one engine module changed; one resolver signature
extended; one command layer gaining a pre-check; three sink surfaces retired.

## Constitution Check

*GATE: passed before Phase 0, re-checked after Phase 1 design.*

| # | Principle | Gate result |
| --- | --- | --- |
| I | Filesystem is the source of truth | **PASS, and applied.** The record was always on disk; the defect was that routing ignored it. No new state store, no registry read, no controlled exception widened. |
| II | Zero-Churn Idempotency | **PASS.** The defect is the largest possible churn violation — a full duplicate ticket set on the second run. FR-021 pins the zero-write assertion in exactly that shape. Ticket identity stays in the server-side entity property. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | **PASS.** Both new refusals are evaluated before any Jira read, so zero writes is structural rather than asserted. The feature changes the fail-closed posture in BOTH directions — it adds two refusals and removes one (a bound spec no rank could place is now placed) — so each direction gets its own test rather than inheriting the unchanged branch's. |
| IV | Credential security | **PASS, unaffected.** No key read or written can hold a credential; no added message carries one; fixtures carry project keys and marker identifiers only. |
| V | Separation of config layers | **PASS.** No key added to any layer. The per-operator layer's influence over routing is NARROWED, not widened. The committed layer keeps both its rule and its default, and C2.3 keeps both ahead of the marker. |
| VI | macOS / Linux / Windows portability | **PASS.** C6.1 requires byte-identical behaviour; C1.7 pins the CRLF hazard and forbids a line ending inside a glob pattern. The conformance corpus gains six scenarios. |
| VII | No hard-coded Jira workflow assumptions | **PASS, unaffected.** Resolves a project key and compares project prefixes; asserts nothing about statuses, types, or transitions. |
| VIII | Neutral engine / Jira sink | **PASS.** C2.7 keeps resolution pure. The bound project set is engine-side data reaching the sink as a parameter, exactly as the routed project does. C5 removes a decision from the sink rather than adding one. |
| IX | Two-tier privacy guard | **PASS, unaffected.** No specification content is newly transmitted; nothing from Jira is newly written into a tracked file. Project and issue keys already appear in existing messages. |
| X | Self-healing mirror within its boundary | **PASS.** Neither reads nor reports the hook registry, which constitution 4.0.0 forbids outright. |
| XI | Universal dry-run and auditability | **PASS, and repaired.** This is the principle the feature found violated. C3.4 forbids conditioning any outcome on the run being real; FR-016 restates the principle's own enforcement test; C5.2 removes the report that only ever spoke outside `--dry-run`. |
| XII | Quality and catalog publication | **PASS.** Version bump and CHANGELOG entry accompany the change. FR-001 changes the resolved project for a configuration valid today and C5 retires shipped behaviour, so the bump is **MAJOR**. FR-024 keeps shipped documentation from describing the old chain. Dogfooding against the instance that produced the report is the acceptance evidence (quickstart §5). |
| XIII | TDD with ≥80% coverage | **PASS.** Every behaviour gets its failing test first, in both ports, per the repository's bug-fix policy. C6.2 requires conformance scenarios per outcome class, which per-port unit tests do not satisfy. Routing resolution and the two refusals are critical paths and target coverage close to 100%. |
| XIV | KISS | **PASS.** One rank inserted, one value computed once, one pre-check, four surfaces deleted. The design removes more code than it adds. Alternatives that would have added machinery — a rank-reporting resolver (R6), a per-tier comparison (R2) — were rejected in research with their reasons recorded. |
| XV | YAGNI | **PASS.** Every requirement traces to one observed incident. Nothing anticipatory: no opt-in flag is built for the whole-specification move that Q2 declined to perform, because no spec asks for one yet. |
| XVI | Human readable | **PASS.** FR-017 requires every added message to name the ticket, project and specification and to say what to do next. The refusal this feature inherits is itself the cautionary example: it names the right answer and acts on none of it. |

**No violations. Complexity Tracking is therefore empty and omitted.**

## Project Structure

### Documentation (this feature)

```text
specs/035-routing-follows-bindings/
├── plan.md                       # This file
├── spec.md                       # Requirements, resolved decisions
├── research.md                   # R1–R8, including the measured blast radius
├── data-model.md                 # The derived value, the amended chain, what is retired
├── quickstart.md                 # Runnable validation
├── contracts/
│   └── marker-routing.md         # C1–C6, binding on both ports
├── checklists/
│   └── requirements.md
└── tasks.md                      # /speckit-tasks output
```

### Source code

```text
scripts/bash/
├── engine/
│   ├── story_marker.sh           # story_marker_any_bound -> marker_bound_projects (C1)
│   └── interchange.sh            # routing_resolve gains input 5 (C2)
├── commands/
│   └── reconcile.sh              # pre-check + two refusals (C3), task-tier check (C4)
└── sink/jira/
    └── recognition.sh            # retire the rerouted branch and channel (C5.1)

scripts/powershell/
├── engine/
│   ├── StoryMarker.psm1          # Test-JiraStoryMarkerAnyBound -> Get-JiraMarkerBoundProjects (C1)
│   └── Interchange.psm1          # Resolve-JiraInterchangeRouting gains -MarkerProject (C2)
├── commands/
│   └── Reconcile.psm1            # pre-check + two refusals (C3), task-tier check (C4)
└── sink/jira/
    └── Recognition.psm1          # retire the rerouted branch and channel (C5.1)

tests/
├── bash/engine/                  # C1 scan, C2 chain
├── bash/commands/                # C3 refusals, C4 task tier, hook downgrade
├── powershell/                   # per-port twins of the above
└── conformance/
    ├── scenarios/us035-*.json    # C6.2, six scenarios
    └── fixtures/repo-035-*/      # bound specs against a contradicting default

docs/                             # resolution order wherever it is stated (FR-024)
templates/config.yml.template     # its commentary states the chain
CHANGELOG.md
```

**Structure Decision**: no new directory and no new module file. The scan
replaces a function in the module that already owns the marker grammar; the rank
is added to the resolver that already owns the chain; both refusals live in the
command layer beside the routing resolution they guard. The feature's net effect
on the tree is one changed function per port, one extended signature per port,
one enlarged command-layer block per port, and four deleted surfaces.

## Phase sequencing

The three user stories are independently deliverable and are implemented in
priority order, each red-first:

1. **US1 (P1)** — C1 scan, C2 rank, and the FR-007 marker-aware variant of the
   undeclared-project refusal. Delivers the fix on its own.
2. **US2 (P2)** — C3.1 and C3.2 refusals, C4 task tier, C5.1 retirement of the
   recognition branch. Makes the remaining mismatch paths safe.
3. **US3 (P3)** — C3.4 dry-run equivalence and C5.2 retirement of the withheld
   note. Makes every outcome legible in the mode that predicts.

Cross-cutting obligations that belong to no story — cross-port equivalence, the
conformance corpus, the zero-churn assertion, the hook-context downgrade in both
its changed directions, the documentation sweep, and the version/CHANGELOG entry
— are carried as their own tasks rather than left to be inferred from a per-story
reading.
