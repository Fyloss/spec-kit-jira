# Implementation Plan: Seed a Specification From Existing Jira Issues

**Branch**: `feat/brownfield-support-2` | **Date**: 2026-08-15 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/027-seed-spec-from-jira/spec.md`

## Summary

Almost every mechanism this feature needs already ships. The identity marker
carries `origin: human` and a `role` of `parent`/`story`; the managed-panel
splice already preserves a human's prose forever on a human-origin ticket; the
story and parent markers already give a specification durable, rename-proof
identity on disk; `bulkfetch` already reads a hundred keys in one request; and
the feature ceremony already validates one mentioned key before naming anything.

What is missing is the *set*: designators for several issues at once, a
deterministic pinning between them and the drafted user stories, a confirmation
gate, and a parent resolution that can adopt or create.

One constraint reorganises everything else. **The confirmation gate cannot live
in a hook.** Constitution IV states in as many words that the bridge runs inside
lifecycle hooks "where there is nobody to answer a prompt and a wait is
indistinguishable from a hang", and Principle III forbids an `after_*` hook from
failing its host — while FR-035 requires every refusal to exit non-zero. So the
feature splits into two moments:

1. **`before_specify`**, inside today's `speckit.jira.feature`: parse the
   designators, issue one bulk read, evaluate every refusal that depends on Jira
   state, compute the slug, record the seeded-not-bound state, hand the agent its
   seed material. Zero mutations.
2. **`speckit.jira.seed`**, a new agent-invoked command bound to no hook event:
   validate the pinning markers against `spec.md` as it now stands, recompute the
   write plan from that file, confirm, then bind, create, and re-parent.

The second constraint is the one the clarification sessions spent most effort on.
`REF-DECOMP` cannot be a drafting judgement, because a non-deterministic
judgement makes FR-046 (port equivalence) and FR-039 (a conformance scenario per
refusal class) unprovable. So the agent writes an explicit **pinning marker**
`<!-- speckit-jira pin=KEY -->` beside each seeded user story, and a script
validates the file on four mechanical properties, reading those markers and
nothing else. FR-015 — "the human content is the primary source material" — is
reclassified as a drafting instruction, because no deterministic check can judge
prose, and the plan says where it lives instead rather than pretending otherwise.

Six module pairs change or appear. No new dependency, no new exit code, no new
abstraction layer.

## Technical Context

**Language/Version**: Bash ≥ 4.0 (macOS/Linux port) and PowerShell 7+ (Windows
port) — twin native implementations, no compiled artefact, no build step.

**Primary Dependencies**: `curl`, `jq`, `git` for the Bash port; PowerShell's
in-process JSON and HTTP for the twin. All pre-existing. **No new dependency.**

**Storage**: `.specify/jira/config.yml` (committable team layer — read only,
unchanged); `.specify/jira/personal.yml` (human-owned selection, unchanged);
`.specify/jira/state/<feature-dir>.seed.json` (**new**, gitignored, schema 1);
`specs/<feature>/spec.md` (the pinning markers, then the story markers).

**Testing**: `bats` via `tests/run-bash.sh` (~190 s full, ≤60 s with `--since`),
Pester under `tests/powershell`, and the shared conformance corpus
`tests/conformance/ci-conformance.sh` against the scripted `curl` replacement and
the PowerShell mock server. Budget assertions use 024's `PATH`-interposed
counting stand-ins, in runs separate from any timing run.

**Target Platform**: macOS, Linux, Windows — three-OS CI matrix, green is a merge
gate.

**Project Type**: CLI extension to a host (Spec Kit), invoked by lifecycle hooks
and by an agent.

**Performance Goals**: `ceil(N / B)` reads for N designators, never one per
issue, and the ceiling is stated **per run** with a resume counted as one
(FR-043). A run naming nothing issues exactly zero additional requests and is
byte-identical to the current release (FR-048). No loop spawns a process per
designator or per marker.

**Constraints**: the engine keeps zero Jira knowledge (boundary greps in CI —
this is what puts designator parsing in the sink and the pinning marker in the
engine); the Bash port never calls `jq` directly for multi-line output (Windows
CRLF); no `$'\r\n'` inside any glob pattern; paths handed to `curl` spelled with
`cygpath -m`; batched payloads travel by temp file, never through a growable
argv; byte-identical output and identical call sequence between ports.

**Scale/Scope**: expected working range is 1 parent + 3–20 stories; the ceiling
proven by test is 101 designators (two batches). Four contracts, three new module
pairs, two extended module pairs, one new agent-facing command definition, one
`extension.yml` entry, one new state document, one new refusal class.

## Constitution Check

*GATE: passed before Phase 0. Re-checked after Phase 1 — result at the bottom.*

| # | Principle | Gate result |
| --- | --- | --- |
| I | Filesystem is the source of truth, with two controlled exceptions | **PASS — this feature *is* the first exception, widened from one issue to a named set, and the spec's Constitution Check justifies it on all four properties.** The plan keeps them structural rather than aspirational: *operator-declared* — designators come only from argv, and no code path in the design issues a search of any kind (research R2, R9 both note the absence deliberately); *named explicitly* — a designator reduces to exactly one key or is refused, before any request; *read exactly once* — the resume re-reads placement and status, never content, and Scenario 2 of quickstart asserts `spec.md` is byte-identical after a Jira-side edit; *confirmed before any Jira mutation* — moment 2 exists solely to make that gate possible outside a hook. Human-origin protection comes free: adopted issues carry `origin: human`, which is already 018's splice trigger and already excludes them from hard deletion. |
| II | Zero-churn idempotency | **PASS.** FR-040's second-run-writes-nothing is asserted by C-13; identity keys on the entity property and the on-disk marker, never a summary. R13 explicitly rejects the OD-4 option that would have added a write to every adopted issue for a cosmetic distinction. FR-052 keeps the free-text title out of the churn loop entirely — it seeds the summary once and is never re-applied, so a human rename produces no write on any later run. |
| III | Fail-closed on writes, non-blocking on hooks | **PASS, and it is the principle that shaped the architecture.** The confirmation gate is not a hook precisely because a refusing, prompting hook is forbidden here — research R1. One deliberate asymmetry, argued rather than smuggled: with designators supplied, an unreliable read exits `EXIT_FAILCLOSED` instead of taking `_feat_fallback`'s `{active:false}` + warning (FR-038), because degrading manufactures the duplicates the feature exists to prevent. Without designators the fallback is untouched, asserted by C-6. |
| IV | Credential security | **PASS.** No credential is read or written by any new module. `REF-HOST` is a credential guard as much as a correctness one: the host check fires **before any request**, so the configured token can never be sent to an unconfigured host (contract §4, test D5). No new value reaches argv; the batched body travels by temp file for a different reason but with the same effect. |
| V | Team config / local binding / secrets | **PASS.** Hierarchy roles, routing, and the site base URL are read from the existing three layers. The one new document is machine state under `.specify/jira/state/`, gitignored, beside 021's — not configuration, and not inside the extension folder. |
| VI | Portability | **PASS, with the risk concentrated and named.** Both ports, byte-equivalent, proven by the corpus. This feature's Windows surface is unusually exposed — URL reduction is glob-pattern work, and the plan, provenance report and seed material are all multi-line output. R11 fixes the three countermeasures in the contracts rather than leaving them to implementation, and quickstart Scenario 7 requires a probe run, with the standing red baseline triaged first. |
| VII | No hard-coded workflow assumptions | **PASS.** Roles resolve from `hierarchy` (FR-012); `REF-TERMINAL` is evaluated against the configuration's declared statuses, never a default Atlassian status name; FR-014 requires a non-default hierarchy fixture. The pin marker carries an opaque key and the pin module never validates its shape, so no type name or key pattern enters the engine. |
| VIII | Neutral engine / Jira sink | **PASS — the seam decided two module placements, in opposite directions.** Designator parsing goes to the **sink** (R2), because an issue-key regex and a `selectedIssue` parameter are exactly what the boundary grep forbids in an engine script. The pinning marker goes to the **engine** (R3), because it handles an opaque string under the same rule `story_marker.sh` already states for `ticket=`. `engine/naming.sh` gains zero lines (R9), keeping its no-key-shaped-literal property intact. |
| IX | Privacy guard | **PASS, and the surface is deliberately minimised.** Seeded content lands in `spec.md`, a tracked file, so every seeded byte passes the existing pre-write guard at both tiers with the existing allowlist — **as FR-065 requires**. That requirement was added by the cross-artifact analysis: this row previously asserted the obligation while no requirement demanded it and no task tested it, which is exactly the shape of a gate that passes on paper. FR-065 also fixes *when*: over the seed material before the drafting agent sees it, not only over the finished file. FR-020's decision not to request comment bodies is load-bearing here, not merely a cost decision: the comment thread is the likeliest place for a pasted coordinate, and the read never asks for it. |
| X | Self-healing automatic mirror | **PASS.** No hook is added, no registration changes, no disabled hook can be re-enabled. `speckit.jira.seed` is declared under `provides.commands` and bound to **no** event. |
| XI | Universal dry-run and auditability | **PASS.** `--dry-run` predicts the identical action set and writes nothing at all, including the seed record — mirroring 021's invariant that a preview can never change what a following real run does (C-16, seed-record §5). The write plan is that prediction made mandatory outside dry-run. Every adoption, create and re-parent appears in the run summary. No destructive operation is added; adopted issues carry `origin: human` and are therefore already excluded from the guarded re-mode's hard deletion. |
| XII | Quality and catalog publication | **PASS.** CHANGELOG entry, SemVer bump in `extension.yml` only, full suite plus corpus plus linters on three OSes. Dogfood is not optional here and must cover a company-managed **and** a team-managed project: the three URL shapes, `bulkfetch`'s treatment of an invisible issue, and the parent link on a company-managed project are all things a mock can be made to agree with while a real instance disagrees. |
| XIII | TDD, 80% coverage | **PASS, and the C1 decision is what makes it reachable.** Both decomposition refusals are emitted by a deterministic file validation, so both ports compute them identically and the corpus can exercise them — a drafting judgement could not have been tested at all. Every phase below leads with its failing test; the first written is quickstart Scenario 2, the byte-identity regression for FR-010. Tests identify state by identifiers they create — the mock's recorded port, generated fixture paths, keys the test itself seeded — never a machine-wide scan. FR-015's untestability is stated in the spec's own table and relocated by R12 rather than left as a silent gap. |
| XIV | KISS | **PASS.** No new abstraction layer, no framework, no dependency. Three new module pairs, each with a stated precedent: `designator.sh` beside the other sink readers, `pin_marker.sh` extending `marker_splice.sh` exactly as `spec_marker.sh` did, `seed_state.sh` beside `run_state.sh`. The confirmation payload reuses `feature.sh`'s existing `confirmation_required` shape rather than inventing a second idiom (R7). |
| XV | YAGNI | **PASS.** Every module traces to a requirement. R5 requests six fields and the identity property — no more — and names the requirement each one serves. R13 declines to build OD-4's visible marker because no acceptance scenario asks for it. Deliberately not built: label discovery, any search, retro-seeding, two-way sync, attachment reading, comment reading. |
| XVI | Human readable | **PASS.** Refusals are reported **together**, not one per run (C-4). Every refusal names the offending designator and carries a copy-pasteable remediation. FR-051's re-parenting line is typographically distinct because a plan whose riskiest entry reads like its safest is unreadable in the only sense that matters. `REF-DRAFT-EDIT` exists as a separate class precisely so the message does not blame the agent for the operator's own edit. |

**No violation requires justification**, so Complexity Tracking below is empty.
The one deliberate asymmetry — fail-closed with designators, non-blocking without
— is argued under Principle III above and required in terms by FR-038.

**Post-Phase-1 re-check**: no gate changed. The four contracts introduced no
dependency, no new exit code, no new flag beyond the three FR-001 and FR-033
already require, and no abstraction beyond the three module pairs already
accounted for under XIV.

## Project Structure

### Documentation (this feature)

```text
specs/027-seed-spec-from-jira/
├── plan.md                          # This file
├── research.md                      # Phase 0 — R1…R14
├── data-model.md                    # Phase 1 — six entities
├── quickstart.md                    # Phase 1 — seven validation scenarios
├── contracts/
│   ├── designator-grammar.md        # Key grammar, URL reduction, host check, order
│   ├── pin-marker.md                # pin= grammar, the four-property validation
│   ├── seed-cli-contract.md         # The two moments, flags, gate, budgets, exit codes
│   └── seed-record.md               # The seeded-not-bound document
├── checklists/
│   └── requirements.md              # Written by /speckit-specify, updated by /speckit-clarify
└── tasks.md                         # Phase 2 — NOT created by /speckit-plan
```

### Source code (repository root)

```text
scripts/bash/                                scripts/powershell/
├── commands/                                ├── commands/
│   ├── feature.sh          EXTENDED  ←→     │   ├── Feature.psm1        EXTENDED
│   └── seed.sh             NEW       ←→     │   └── Seed.psm1           NEW
├── engine/                                  ├── engine/
│   ├── pin_marker.sh       NEW       ←→     │   ├── PinMarker.psm1      NEW
│   ├── marker_splice.sh    reused           │   ├── MarkerSplice.psm1   reused
│   ├── story_marker.sh     reused           │   ├── StoryMarker.psm1    reused
│   └── naming.sh           UNCHANGED        │   └── Naming.psm1         UNCHANGED
├── lib/                                     ├── lib/
│   ├── cli.sh              EXTENDED  ←→     │   ├── Cli.psm1            EXTENDED
│   ├── seed_state.sh       NEW       ←→     │   ├── SeedState.psm1      NEW
│   └── output.sh           reused           │   └── Output.psm1         reused
└── sink/jira/                               └── sink/jira/
    ├── designator.sh       NEW       ←→         ├── Designator.psm1     NEW
    ├── adoption.sh         NEW       ←→         ├── Adoption.psm1       NEW
    ├── identity.sh         reused               ├── Identity.psm1       reused
    └── prefetch.sh         UNCHANGED            └── Prefetch.psm1       UNCHANGED

commands/
└── speckit.jira.seed.md    NEW      # agent-facing definition; carries FR-015 (R12)
extension.yml               EXTENDED # provides.commands += speckit.jira.seed

tests/
├── bash/commands/test_seed.bats                      NEW
├── bash/commands/test_seed_gate.bats                 NEW
├── bash/commands/test_seed_oneway.bats               NEW
├── bash/commands/test_seed_parent.bats               NEW
├── bash/commands/test_seed_privacy.bats              NEW
├── bash/commands/test_seed_refusals.bats             NEW
├── bash/commands/test_feature_designators.bats       NEW
├── bash/engine/test_pin_marker.bats                  NEW
├── bash/lib/test_seed_state.bats                     NEW
├── bash/lib/test_cli_designators.bats                NEW
├── bash/sink/test_designator.bats                    NEW
├── bash/sink/test_adoption.bats                      NEW
├── bash/packaging/test_manifest.bats                 NEW   # manifest reachability
├── bash/ci/                                          EXTENDED  # budget stand-ins
├── live/test_live_zero_churn.bats                    EXTENDED  # Principle II, Bash only
├── powershell/…                                      NEW (twins of each, except live)
└── conformance/scenarios/us027-*.json                NEW (≈25 — 11 behavioural + 14 refusal classes)
```

`tests/live/` has **no PowerShell twin** in this repository. Principle II's
double-run assertion is therefore extended on the Bash side only, and that
asymmetry is stated in the CHANGELOG rather than quietly accepted.

**Structure Decision**: the existing four-layer split is kept exactly —
`commands/` orchestrates, `engine/` stays tracker-agnostic, `sink/jira/` holds
every Atlassian fact, `lib/` is port infrastructure with no Jira knowledge. The
only genuinely new architectural element is the second command, and research R1
shows it is forced by the constitution rather than chosen.

`prefetch.sh` is listed as **UNCHANGED** deliberately: R4 explains why the
adoption read is a separate module rather than a mode on that one, and R5 shows
that its field union lacks `issuetype` and `project` — reusing it would have made
`REF-ROLE` and `REF-ROUTING` cost a second request.

## Implementation phases

Ordered so that the P1 slice — pure adoption, no irreversible write — is
demonstrable before anything can mutate a board nobody named. This is the
priority change the second clarification session made, and the phase order is
where it becomes real.

The phases below are **work packages**, numbered 0–8. `tasks.md` numbers its own
phases 1–10, because it inserts a Setup phase ahead of them and splits the
user-story work by story rather than by module. The last column maps one onto the
other so a reader moving between the two documents is never guessing.

| Phase | Delivers | Leading failing test | `tasks.md` |
| --- | --- | --- | --- |
| 0 | `designator.sh` / `Designator.psm1`: grammar, URL reduction, host check, order, de-dup | D1–D10 | Ph. 2, T007–T018 |
| 1 | `cli.sh` flags, `parent_seen`, `\x1f` streams | C-1 (no designators → byte-identical) | Ph. 2, T019–T024 |
| 2 | `adoption.sh`: fail-closed bulk read, the field union, refusal classes | C-2, C-3, C-5, C-6 | Ph. 2, T025–T036 |
| 3 | `pin_marker.sh`: grammar, non-collision, four-property validation | P-1…P-6, P-9 | Ph. 2, T037–T047 |
| 4 | `seed_state.sh`, slug rule in `feature.sh`, moment 1 end to end | S-1…S-9, C-14, C-15 | Ph. 2, T048–T055; Ph. 4, T070–T078 |
| 5 | `seed.sh`: plan, gate, binding, consumption — **P1 slice complete** | C-7…C-9, C-13, C-16 | Ph. 2, T056–T059; Ph. 4–6, T079–T106 |
| 6 | Resume: re-read, re-validate, delta | C-10…C-12, P-7, P-8 | Ph. 7, T107–T119 |
| 7 | Parent create and re-parent — **the P2 slice** | C-17, C-18 | Ph. 8–9, T120–T139 |
| 8 | `extension.yml`, `commands/speckit.jira.seed.md`, docs, CHANGELOG | reachability check | Ph. 2, T060–T063; Ph. 10, T140–T157 |

Two obligations sit outside this module view because they belong to no module and
to no user story — the credential guard (`tasks.md` T064–T065, Principle IV) and
the privacy guard over seeded content (T077–T078, FR-065). Both were added by the
cross-artifact analysis; see the note at the end of `tasks.md`.

Phase 8 is not paperwork. `mention` has been implemented, tested and green in
both ports since 001 and remains unreachable because it was never declared in
the manifest. A feature that ships without its declaration has not shipped.

## Complexity Tracking

*No Constitution Check violation requires justification. This section is
intentionally empty.*

## Open items carried into tasks

| Item | Status |
| --- | --- |
| **OD-4** — adopted versus created, visible to a human? | **Closed in spec.md** (third clarification pass), on R13: origin field only (`human` versus `bridge`). FR-031 states it as a requirement. |
| **OD-5** — a run that failed part-way through binding | **Closed in spec.md** (third clarification pass), on R14: resume, never roll back — forced by Principle I and FR-040. FR-042 and US2 AC7 state it; T137/T138 implement it. The residual question (a distinct warning class for a partially bound state) remains a tasks-phase decision and changes no requirement. |
| Agent conveyance of moment 2 | Named in R1. Mitigated by the command definition and by a fail-safe design: a forgotten invocation leaves a resumable seeded-not-bound state, never a duplicate. |
