# Implementation Plan: Pin the Jira Destination Host

**Branch**: `032-pin-jira-host` | **Date**: 2026-08-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/032-pin-jira-host/spec.md`

## Summary

Bind a checkout to the Jira origin its binding ceremony actually reached, and refuse — before the first request, with zero writes — when the committed team config later declares a different one. The record goes to a new `bound_site` key of the gitignored local layer; the comparison lives in the single connection chokepoint every command already calls before it can reach the transport; accepting a changed origin requires naming it, so following the refusal's own instruction is not sufficient.

Two pieces of groundwork come first, both established by Phase 0 rather than assumed: a Constitution IV/V amendment admitting the new key as a third narrow, key-scoped exemption (without it the credential-shape guard makes every hosted-Jira configuration permanently unloadable), and the repair of two measured cross-port divergences in the origin primitive this feature reuses.

## Technical Context

**Language/Version**: Bash 3.2+ (macOS system bash) and PowerShell 7+ — two native ports held byte-equivalent by a shared conformance corpus

**Primary Dependencies**: `jq` (bash port, only via `lib/output.sh`), `curl`; no new dependency introduced by this feature

**Storage**: YAML configuration files under `.specify/jira/` — `config.yml` (committed), `config.local.yml` (gitignored, the record's home), `personal.yml` (gitignored)

**Testing**: `bats` (bash), `Pester` (PowerShell), and `tests/conformance/` for cross-port byte equivalence — the last is the primary gate here, because FR-009 makes byte equivalence part of the requirement

**Target Platform**: macOS, Linux, Windows (git-bash/MSYS for the bash port, native pwsh for the PowerShell port)

**Project Type**: CLI tool distributed as a spec-kit extension, invoked directly and from lifecycle hooks

**Performance Goals**: no measurable change — the gate runs once per run and spawns zero external processes (`docs/11-process-budget.md`)

**Constraints**: origin extraction MUST NOT spawn a process or call `jq`; no `$'\r\n'` inside a glob; `[System.Uri]` is forbidden (seven normalisations the bash port cannot reproduce); every message and exit code byte-identical across ports

**Scale/Scope**: 2 library modules, 5 command entry points (4 of which only inherit the gate), 1 shared parser, ~4 new conformance scenarios, ~5 existing tests to update

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Initial evaluation — one gate fails, and is escalated rather than diluted.**

| Gate | Verdict |
| --- | --- |
| I, II, III, VI-XVI | Pass — see the spec's Constitution Check table for the per-principle proof |
| **IV, V** | **FAIL as the constitution stands.** Recording a real origin at a local-layer key is forbidden by IV (`.specify/memory/constitution.md:396-399`) and by V's two-exemption enforcement test (`:470-475`). |

Per the spec template's own rule, a principle this feature conflicts with is not diluted in the spec — the feature is redesigned or the constitution is amended separately. Both were considered:

- *Redesign*: store a digest rather than the origin. Rejected in Phase 0 (R3) — the only digest primitive is file-based, a stdin-fed hash reintroduces a known cross-port newline divergence and a process spawn, and it costs FR-004's message and Constitution XVI's readability.
- *Amend*: add a third narrow, key-scoped exemption for `bound_site` in the gitignored local layer. Adopted, with direct precedent — v2.0.0 was amended for exactly this reason to unblock 030.

**The amendment is task T001 and blocks everything else.** If it is not accepted, the feature does not proceed.

**Post-design re-evaluation** (after Phase 1): no new violation introduced. The design adds no configuration surface beyond the one key, no external process, no new exit code, and no new dependency. XIV is served by reusing an existing comparison primitive rather than writing a third one; XV is served by the explicit exclusion of the merged-document revalidation.

## Project Structure

### Documentation (this feature)

```text
specs/032-pin-jira-host/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── origin-pinning.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/bash/
├── lib/
│   ├── url_origin.sh        # NEW — origin parse + compare, lifted out of the sink
│   ├── config.sh            # chokepoint gate; bound_site read, schema, credential exemption
│   ├── cli.sh               # --accept-site flag
│   └── credentials.sh       # FR-008 refusal at the credential producer
├── commands/
│   ├── config.sh            # record the origin; --accept-site; opt out of its own gate
│   └── reconcile.sh         # relay the gate's status through _reconcile_fault
└── sink/jira/
    └── designator.sh        # re-expressed on lib/url_origin.sh

scripts/powershell/
├── lib/
│   ├── UrlOrigin.psm1       # NEW — twin of url_origin.sh
│   ├── Config.psm1
│   ├── Cli.psm1
│   └── Credentials.psm1
├── commands/
│   ├── Config.psm1
│   └── Reconcile.psm1
└── sink/jira/
    └── Designator.psm1

tests/
├── conformance/
│   ├── scenarios/           # NEW — 4 scenarios + 2 divergence-repair cases
│   ├── fixtures/            # NEW — repo fixtures (git add -f required)
│   └── run-scenario.sh      # @MOCK_ORIGIN@ substitution into config.local.yml
├── bash/lib/                # url_origin + config gate suites
└── powershell/lib/          # twins

.specify/memory/constitution.md   # T001 amendment (IV, V)
```

**Structure Decision**: the feature follows the repository's existing two-port layout with no new directory. The one new module per port, `lib/url_origin.sh` / `lib/UrlOrigin.psm1`, exists because Constitution VIII forbids `lib/` from depending on `sink/`: the comparison primitive lives in the sink today (`sink/jira/designator.sh`) but a URL origin carries no Jira knowledge, so it is lifted to `lib/` and the designator is re-expressed on top of it. That keeps one implementation rather than a fourth grammar.

## Implementation Phases

**Phase A — Prerequisites (blocking).** The constitutional amendment (T001), then the two divergence repairs in the origin primitive (trailing-dot arity, ASCII case fold) and bracketed-IPv6 parsing, each proven by its own failing cross-port case before the repair. These are pre-existing defects; 032 must not be built on them.

**Phase B — The primitive.** Lift origin parse/compare into `lib/url_origin.sh` / `lib/UrlOrigin.psm1`, re-express the designator on it, and prove the sink's behaviour unchanged by the existing corpus.

**Phase C — The record.** `bound_site` in the local schema and its shape validator; the key-scoped credential exemption; the ceremony's write, folded into the existing single serialize-and-write so no partial state is possible; the `--accept-site` flag in the shared parser; the ceremony's refusal when the origin changed and was not named.

**Phase D — The gate.** The comparison in the chokepoint, returning a distinguishable status; the ceremony's explicit opt-out; reconcile relaying the status through `_reconcile_fault` so FR-004's message survives the hook path; the absent- and malformed-record refusals.

**Phase E — Defence in depth.** FR-008 at the credential producer, using process-scoped pinned state rather than re-parsing.

**Phase F — Corpus and documentation.** The four conformance scenarios, the `@MOCK_ORIGIN@` harness extension, the five existing tests the gate legitimately changes, and the documentation sweep.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Constitution IV/V amendment (third narrow exemption) | The record must live where a pull request cannot reach it; every such layer is covered by the guard that IV/V mandate | Storing a digest avoids the amendment but needs a stdin-fed hash — a process spawn plus the known PowerShell-appends-a-newline divergence this project has already been bitten by — and forfeits FR-004's message and XVI's readability |
| New module `lib/url_origin.sh` per port | Constitution VIII forbids `lib/` depending on `sink/`, and the only origin primitive lives in `sink/jira/designator.sh` | Duplicating the parser in `lib/` would make a fourth origin grammar in the tree; calling into the sink from `lib/` would invert the dependency the constitution draws |
| Repairing two pre-existing divergences before the feature | The gate's correctness rests on the primitive, and one divergence (Unicode fold) is reachable by exactly the attacker-chosen input this feature exists to catch | Building on top and repairing later would ship a security control whose comparison is known to differ between ports |
