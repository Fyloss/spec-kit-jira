# Implementation Plan: A pass-through says which state produced it

**Branch**: `fix/diagnose-inactive-team-selection` | **Date**: 2026-08-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/031-diagnose-team-resolution/spec.md`

## Summary

The feature command emits `active: false` from several distinct states and, with
no ticket mentioned, all of them are byte-identical and silent. Two mislead: an
unloadable `config.yml` is reported as though no configuration existed — its
located diagnostic is computed and then discarded by one redirection — and the
configuration directory is resolved against the process working directory, so a
run started anywhere but the project root consults a path that does not exist.

The approach is subtraction, not addition. Nothing new is computed: the loader
already produces the located reason, the host already defines how to find a
project root without git, and the argument parser already accepts `--verbose`
and hands it to a command that never reads it. Three wires exist and are cut;
this feature connects them.

## Technical Context

**Language/Version**: Bash 3.2+ (macOS/Linux port), PowerShell 7+ (Windows port)

**Primary Dependencies**: `jq` and `curl` for the Bash port; none added here.
**No git dependency is introduced** — see research D1.

**Storage**: files only — `.specify/jira/{config.yml,personal.yml,state/}`. This
feature writes none of them.

**Testing**: `bats` (`tests/run-bash.sh`), Pester, and the cross-port
conformance corpus (`tests/conformance/ci-conformance.sh`)

**Target Platform**: macOS, Linux, Windows — byte-identical behaviour required

**Project Type**: CLI extension to a host tool, dispatched as a lifecycle hook

**Performance Goals**: no regression. Every path here is local filesystem work
on the already-measured naming path; the upward walk is bounded by directory
depth and costs no process spawn (`docs/11-process-budget.md`).

**Constraints**: zero Jira requests on every path this feature touches; zero
process spawns added per item; two shipped conformance scenarios must pass
unmodified.

**Scale/Scope**: one command (`feature`), two library functions
(`config_load` / `config_personal_load` call sites), both ports.

## Constitution Check

*GATE: passed before Phase 0, re-evaluated after Phase 1. Unchanged by the
design.*

The specification carries the full sixteen-principle table. Post-design, three
warrant restating because the design touched them:

| # | Principle | Post-design status |
| --- | --- | --- |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | **Closed.** Research D3's conflict between FR-013 and spec 030's contract C6.2 was escalated, decided, and closed by amending C6.2 itself (new clause C6.2a, 2026-08-24), which scopes it to paths that can reach the network. Contract C3.3 is now in force, and C3.4 obliges a test proving the refusal C6.2 still governs survives — without which the amendment would be a hole. Every clause is non-blocking by construction. |
| VI | Portability | The design's whole risk surface. Path resolution and absolute-path spelling are where the two hosts diverge, so C1.1/C1.2/C1.4 are assigned to conformance scenarios rather than per-port unit tests (contract §5.2). |
| XIV / XV | KISS / YAGNI | No new flag, no new configuration key, no new file, no new dependency. Each artifact traces to an observed defect, and the three mechanisms reused all pre-exist. |

**Gate result**: pass. The one conflict this design surfaced was escalated, put
to the decision it needed, and closed by amending the contract out loud rather
than by reinterpreting it in passing. Nothing is carried into implementation
unresolved.

## Project Structure

### Documentation (this feature)

```text
specs/031-diagnose-team-resolution/
├── plan.md              # This file
├── spec.md              # 17 FR, clarified 2026-08-24
├── research.md          # Phase 0 — D1..D4, D3 escalated
├── data-model.md        # Phase 1 — resolution state, consulted path, load failure
├── quickstart.md        # Phase 1 — five runnable validation scenarios
├── contracts/
│   └── pass-through-diagnosis.md
└── checklists/requirements.md
```

### Source Code (repository root)

```text
scripts/bash/
├── commands/feature.sh        # the two silencing call sites; --verbose consumption
└── lib/config.sh              # directory resolution; the personal-load call site

scripts/powershell/
├── Commands/Feature.ps1       # same, second port
└── Lib/Config.ps1             # same, second port

tests/
├── bash/commands/             # per-port unit tests
├── powershell/Commands/       # per-port unit tests
└── conformance/scenarios/     # C1.1, C1.2, C1.4, and the two that must NOT move
```

**Structure Decision**: no new module. The change lives at existing call sites
in the two ports' `feature` command and configuration library, matching the
engine/sink separation already in place (Principle VIII is untouched —
configuration resolution is neither).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Directory-resolution rule duplicated in both ports rather than imported from the host | The host's own resolver is Bash-only; importing it would leave the PowerShell port without one and break port symmetry, and would couple this extension to host script internals across the full `speckit_version >=0.13.0` range | Sourcing `.specify/scripts/bash/common.sh` — rejected in research D1. The rule is ~10 lines per port; importing ~29 KB of unrelated machinery to avoid 10 lines is the more complex option, not the simpler one |
