# Implementation Plan: The routing fallback follows the developer's team

**Branch**: `033-routing-follows-team` | **Date**: 2026-08-30 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/033-routing-follows-team/spec.md`

## Summary

Insert the operator's selected team into routing resolution as a third rank — behind the committed `routing:` rules and the committed team route, ahead of `routing_default` — and relieve `routing_default` of being a required key. The rank is bounded by FR-004: it applies only to a specification none of whose stories is already bound, so a per-operator input can never reroute a shared artifact.

Phase 0 found that two of the three moving parts are already in place. The personal team is **already loaded and validated on the reconcile path** — `config_resolve_connection` calls `config_personal_load` and discards the result (`config.sh:1836`), so capturing it costs zero additional process spawns and FR-005's fail-closed behaviour already exists by construction. And the PowerShell port already reads `routing_default` through `Get-JiraInterchangeProp` (`Interchange.psm1:386`), so making the key optional needs no StrictMode repair there.

What is genuinely new is small: one lookup folded into a jq program that already runs, one presence check on the schema, one marker scan, and one reordering of an existing file read.

## Technical Context

**Language/Version**: Bash 3.2+ (macOS system bash) and PowerShell 7+ — two native ports held byte-equivalent by a shared conformance corpus

**Primary Dependencies**: `jq` (bash port, only via `lib/output.sh`), `curl`; no new dependency introduced by this feature

**Storage**: YAML configuration files under `.specify/jira/` — `config.yml` (committed, `routing`/`teams`/`routing_default`), `personal.yml` (gitignored, the `team` selection); plus the specification's own bound markers, which are the authority FR-004 rests on

**Testing**: `bats` (bash), `Pester` (PowerShell), and `tests/conformance/` for cross-port byte equivalence — the last is the primary gate, because FR-012 makes byte equivalence part of the requirement

**Target Platform**: macOS, Linux, Windows (git-bash/MSYS for the bash port, native pwsh for the PowerShell port)

**Project Type**: CLI tool distributed as a spec-kit extension, invoked directly and from lifecycle hooks

**Performance Goals**: zero additional process spawns. The rank-3 lookup folds into the single `jq` invocation `routing_resolve` already makes; the personal load is already paid for; the boundness scan is fork-free and reuses a file read that already happens (`docs/11-process-budget.md`)

**Constraints**: routing resolution stays PURE — no Jira read, no file opened inside the engine (Constitution VIII); the boundness scan must not spawn per story; no `$'\r\n'` inside a glob; every message and exit code byte-identical across ports

**Scale/Scope**: 4 modules per port (2 engine — the resolver and the marker predicate — 1 lib, 1 command) plus 2 templates and 2 documents; routing has exactly two call sites in the whole tree (`reconcile.sh:128`, `Reconcile.psm1:144`), so the blast radius is bounded by construction

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Initial evaluation — all sixteen gates pass. No amendment is required and none is sought.**

| Gate | Verdict |
| --- | --- |
| I, II, III, IV, VI–XVI | Pass — see the spec's Constitution Check table for the per-principle proof |
| V | Pass, and it is the principle to watch. The per-operator layer gains influence over routing through the key it already owns; no key is added to it, nothing leaves the committed layer, and the rank order keeps both committed sources ahead of it. |
| VIII | Pass, and it constrains the design. The resolver must not open `personal.yml` itself; the selected team reaches it as data, decided in R1. |

Assessed against constitution **4.0.0**. The 2026-08-30 amendment touched Principle X only (the hook registry) and is orthogonal to this feature — 033 neither reads nor reports the registry.

**Post-design re-evaluation** (after Phase 1): no new violation introduced. The design adds no configuration key, no file, no external process, no exit code, and no dependency. XIV is served by folding the rank-3 lookup into an existing jq program rather than adding a second one; XV is served by FR-005 turning out to need a test rather than code (R4), and by the explicit refusal to add a `routing_default` key to `personal.yml`.

## Project Structure

### Documentation (this feature)

```text
specs/033-routing-follows-team/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── routing-resolution.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/bash/
├── engine/
│   ├── interchange.sh       # routing_resolve: 4th parameter, rank 3 in the jq program
│   └── story_marker.sh      # NEW predicate — "is any story already bound", fork-free
├── lib/
│   └── config.sh            # routing_default presence rule dropped; personal team exposed
│                            # from config_resolve_connection (the _CFG_PIN_STATUS pattern)
└── commands/
    └── reconcile.sh         # spec read moved ahead of routing; team + boundness passed;
                             # the four-finding refusal message

scripts/powershell/
├── engine/
│   ├── Interchange.psm1     # twin of routing_resolve
│   └── StoryMarker.psm1     # twin of the boundness predicate
├── lib/
│   └── Config.psm1          # twin of both config.sh changes
└── commands/
    └── Reconcile.psm1       # twin of the reconcile changes

templates/
├── config.yml.template      # routing_default presented as optional + precedence note
└── personal.yml.template    # `team:` now also governs routing

docs/
├── 06-feature-naming.md              # `team:` now governs routing too, not only naming
└── 07-configuration-and-secrets.md   # the four-rank chain
tests/
├── conformance/scenarios/   # NEW — one per rank, one per refusal state
├── bash/{engine,lib,commands}/
└── powershell/{engine,lib,commands}/
```

**Structure Decision**: no new module and no new directory. The one new function per port is a predicate on marker grammar, and it goes where that grammar already lives (`engine/story_marker.sh`, whose bound form is defined at line 80) rather than into the command that consumes it — Constitution VIII keeps marker vocabulary in the neutral engine.

## Implementation Phases

**Phase A — The schema relaxation (independent, shippable alone).** Drop the presence half of the `routing_default` rule in both ports (`config.sh:875`, `Config.psm1:767`), keep the shape half. This is US2 in full and touches nothing else. Failing tests first: a config with no `routing_default` validates; one with a malformed `routing_default` still refuses.

**Phase B — The boundness predicate.** The fork-free "any story already bound" scan in `story_marker.sh` / `StoryMarker.psm1`, against the marker form at `story_marker.sh:80`. Proven on its own before any caller exists, including the three shapes that must NOT count as bound (`creating`, bare, and absent).

**Phase C — Rank 3 in the resolver.** `routing_resolve` gains a fourth parameter carrying the selected team id, and its existing jq program gains one lookup between the team route and the default. The parameter is threaded but not yet supplied by anything — the port's existing corpus proves rank order 1, 2 and 4 unchanged.

**Phase D — Wiring, and the reordering.** Expose the personal load's result from `config_resolve_connection` through a module-scoped variable, on the `_CFG_PIN_STATUS` precedent already used by this same call site. Move the raw spec read ahead of the routing block in both ports. Supply rank 3 from those two, gated on the predicate.

**Phase E — The refusal.** The four-finding message replacing `reconcile.sh:737`, and its twin. This is where FR-007, FR-008 and Constitution XVI land.

**Phase F — Corpus and documentation.** The conformance scenarios (one per rank, one per refusal state, one proving FR-009's untouched legacy behaviour), the two templates, and the configuration document.

## Complexity Tracking

> Constitution Check records no violation. This table records the two decisions that cost the most explanation, so a reviewer does not have to re-derive them.

| Decision | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Moving the raw spec read ahead of routing resolution | FR-004 needs "was any story bound before this run", and routing resolves ~155 lines before the file is first read (`reconcile.sh:736` vs `:891`; `Reconcile.psm1:861` vs `:1024`) | Moving routing resolution *after* the parse instead — rejected, `project_key` feeds the placeholder check, the unknown-project check, the phase→status map, the halted list, the local binding and the mandatory-field gate, all between the two points. Reading the file twice — rejected on the process budget for no gain, the read has no side effect and nothing writes the spec until after the parse |
| Threading the team **id**, not the resolved project, into `routing_resolve` | The resolver's existing jq program can look the project up for free, and `config_personal_load` has already proven the id is in the catalogue (`config.sh:1385`) | Resolving the project in the caller — one extra `jq` per run to duplicate a lookup the resolver gets for nothing. Letting the resolver read `personal.yml` — Constitution VIII forbids the engine opening configuration, and it would make a pure function stateful |
