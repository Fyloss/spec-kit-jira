# Implementation Plan: Reconcile Recognises the Tickets It Already Created

**Branch**: `fix/idempotent-reconcile` | **Date**: 2026-07-29 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-fix-reconcile-idempotency/spec.md`

## Summary

Reconcile has no step that asks which tickets already exist, and stamps nothing on the
tickets it creates. `plan_writes` decides create-versus-update from a `tickets` map that
only the `SPEC_KIT_JIRA_PLAN_CONTEXT` override ever fills, so on a normal run the map is
empty and every user story is planned as a creation — the reported duplicates. The
identity marker `identity_write` already writes is never applied on this path, and even
if it were, it records `{origin, repo, spec_slug}` with nothing to tell one story's
ticket from another's.

The fix gives each user story a durable identifier, recorded in `spec.md` on one comment
line and stamped into the ticket's identity marker, and inserts a recognition step
between parsing and planning that reads each recorded ticket back and verifies it. Two
research findings shape the design. Recognition reads **by recorded key**, never by
search: Jira's index is eventually consistent, and the reported defect happens between
two lifecycle commands seconds apart, so any search-based recognition would still
duplicate in exactly the scenario that reported the bug (R2). And the identifier must be
random rather than derived, which forces a test seam to keep the two ports byte-identical
under the conformance gate (R4).

The same recognition read supplies the current-Jira facts that `plan_lifecycle` has
always accepted and never received, so the zero-churn diff and the drift, Flagged, and
blocker rules stop being inert (R9). No new configuration key, no new credential surface,
no new dependency. One new engine module, one new sink module, one sequencing change in
the command layer, per port.

## Technical Context

**Language/Version**: Bash >= 4 (macOS/Linux port; enforced by `prereq_check`) and PowerShell 7+ (Windows port)

**Primary Dependencies**: `jq` (Bash port, existing runtime prerequisite); none added by this feature. `kcov` + `bats` (Bash) and `Pester` (PowerShell) remain development-time only.

**Storage**: Files only. The durable state this feature adds is one comment line per user story in the repository's own `spec.md`, plus one entity property per Jira ticket. No database, no cache, no new file.

**Testing**: `bats` (Bash), `Pester` (PowerShell), the language-agnostic conformance suite under `tests/conformance/scenarios/` driven by `run-scenario.sh`, and the live suite for the Constitution II double-run assertion. Coverage by kcov (Bash, primary gate) and Pester CodeCoverage (PowerShell), 80% statement minimum, near-100% on recognition.

**Target Platform**: macOS, Linux, Windows — three-OS GitHub Actions matrix.

**Project Type**: Script-native Spec Kit extension. No build step, no compiled artifact, no download.

**Performance Goals**: One `GET /rest/api/3/issue/{key}` per already-mirrored story per run, where today there are none. A twelve-story specification issues twelve reads per lifecycle command. No batching (it would reintroduce the index dependency R2 rejects), no new call on the create path beyond the existing stamp.

**Constraints**: Byte-identical stdout, exit codes, Jira call sequences, and resulting `spec.md` bytes across the two ports — which is why the identifier generator is injectable (R4). Zero Jira writes on any run whose recognition is inconclusive. No ticket created before its identifier is recorded. No credential or site host in any new diagnostic.

**Scale/Scope**: Two new modules and four changed modules per port, one changed engine parser, a stateful extension to the mock double, roughly 500 changed lines per port. Existing repositories are not migrated: their tickets carry no marker and are re-mirrored, which the spec declares Out of Scope and the CHANGELOG must state plainly.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design — result recorded in the section below the table.*

| # | Principle | Gate at plan level | Status |
| --- | --- | --- | --- |
| I | Filesystem Is the Source of Truth | The identifier lives in `spec.md`, making the filesystem authoritative about what exists. No delete is issued on any path. A ticket a marker line still names, whose stamped identifier matches no story, is surfaced and never touched; one that no marker line names is unreachable by the run and therefore never touched either ([recognition contract](./contracts/recognition-contract.md)). Every overwrite stays behind the existing named drift warning (R9). The bridge writes only its own marker line and preserves every other byte, the discipline `managed_section.sh` already enforces for the README block. | PASS |
| II | Zero-Churn Idempotency | The feature's whole purpose. Identity keys on a bridge-assigned identifier plus an entity property — never a title, summary, or path (FR-002). The zero-churn diff already exists in `idempotency.sh` and `plan_lifecycle`; recognition supplies the current state it needs. The live double-run assertion is a required task, since the principle states mocks are not sufficient. | PASS |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Every inconclusive recognition returns through `_reconcile_fault` with the existing monotonic codes; no path downgrades a failed read to "no ticket exists". An unwritable `spec.md` fails before any create (FR-012). The `SPEC_KIT_JIRA_HOOK_CONTEXT` downgrade keeps all of it non-blocking for the host command. | PASS |
| IV | Credential Security | No new credential surface: recognition reuses `jira_request`. The value added to the tracked tree is a random hex string and an issue key — neither a token, an authentication email, a site URL, nor an accountId. The diagnostics catalogue is fixed in a contract and names no host; a test asserts it. | PASS |
| V | Separation of Team Config / Local Binding / Secrets | No new config key in either layer. The identifier belongs to the specification, not to a configuration layer, and FR-017 forbids recognition from depending on machine-local state, so no new local file becomes load-bearing. | PASS |
| VI | Portability | Both ports change in the same commit. Conformance scenarios compare stdout, exit codes, call sequences, and the resulting `spec.md` bytes; `SPEC_KIT_JIRA_ID_SOURCE` (R4) is what makes a random identifier comparable at all. | PASS |
| VII | No Hard-Coded Assumptions | Recognition keys on the bridge's own marker, never on an issue type, status name, or field id. The Flagged field and the phase→status order come from the existing discovery and config resolution. | PASS |
| VIII | Neutral Engine / Jira Sink | The engine gains identifier assignment and a Markdown byte-splice, both Jira-agnostic: `story_marker.sh` takes pre-formatted lines as parameters exactly as `managed_section.sh` takes its markers. Ticket reads, marker verification, and stamping live in the sink. The command layer sequences them, as in 004. R6 records the split. | PASS |
| IX | Two-Tier Privacy Guard | Untouched. Recognition runs strictly before planning and adds no path around `privacy_guard_scan`; every write still passes it. | PASS |
| X | Self-Healing Automatic Mirror | Unchanged: hook registration, health reporting, and the permanence of an operator-disabled hook are untouched. Fixing duplication is what makes the automatic mirror safe to fire from every hook. | PASS |
| XI | Universal Dry-Run and Auditability | `--dry-run` recognises, predicts identifiers, and writes neither Jira nor `spec.md`. The summary gains `recognised` and `assigned` and finally populates `skipped`, so a reader can see an unchanged re-run did nothing. No destructive operation is added. | PASS |
| XII | Quality and Catalog Publication | CHANGELOG entry and version bump are release tasks; the three-OS matrix, lint, and the coverage gate stay blocking; the live suite carries the double-run. Dogfooding against the consuming project that reported the defect is the acceptance signal. | PASS |
| XIII | TDD With a Minimum 80% Coverage | The failing duplicate-creation test comes first, on both ports, per the repository's bug-fix policy — Step 1 of [quickstart.md](./quickstart.md) is that test. Recognition, idempotency, and the fail-closed paths are named critical paths and target near-100%. | PASS |
| XIV | KISS | No new abstraction tier: the three plan-context maps, the lifecycle context, the churn diff, the drift engine, and the byte-splice discipline all already exist and are simply fed. Two new modules, each with one job. Batching, caching, and label search were all rejected as unnecessary (R2, R3). | PASS |
| XV | YAGNI | Every changed line traces to a functional requirement. Status transitions are deliberately not implemented (R9) because no requirement asks for them and they would cost a call per ticket. The one test-only affordance, `SPEC_KIT_JIRA_ID_SOURCE`, is justified in R4 and exercised by every conformance scenario here. | PASS |
| XVI | Human Readable | The marker is a self-describing comment a developer understands on sight (FR-008). Every diagnostic names the story, the file, and a copy-pasteable remedy, catalogued in one contract rather than scattered as strings. | PASS |

**Initial gate**: PASS — no violations, Complexity Tracking not required.

**Post-Phase-1 re-check**: PASS. The design artifacts introduce no dependency, no
configuration surface, and no abstraction beyond the two single-purpose modules named
above. Three points were re-examined after the design and are recorded here because they
are where a reviewer will look:

- *Principle I, writing into a user-owned file.* This is new — no previous feature edited
  a `spec.md`. It is confined to one comment line per story, byte-preserving, CRLF-safe,
  idempotent to the point of not opening the file when nothing changed, and written
  atomically. The rules are fixed in [contracts/story-marker.md](./contracts/story-marker.md).
- *Principle XV, the test seam.* `SPEC_KIT_JIRA_ID_SOURCE` exists only because FR-007
  forbids a derivable identifier while Constitution VI demands byte-identical ports. It
  is the minimum affordance that satisfies both.
- *Principle II, the live gate.* The mock had to become stateful for any of this to be
  testable, which raises the risk of a mock that agrees with the implementation rather
  than with Jira. The live double-run of quickstart Step 11 is the control, and R2's
  assumption about property indexing is verified there explicitly rather than assumed.

Complexity Tracking remains empty.

## Project Structure

### Documentation (this feature)

```text
specs/005-fix-reconcile-idempotency/
├── plan.md                          # This file
├── research.md                      # Phase 0 — nine decisions, R2 and R4 are load-bearing
├── data-model.md                    # Phase 1 — entities, the four passed structures, state transitions
├── quickstart.md                    # Phase 1 — eleven validation steps, ending at the live gate
├── contracts/
│   ├── story-marker.md              # Grammar, placement, read rules, write rules
│   └── recognition-contract.md      # Reads, decision table, output, diagnostics, exit codes
├── checklists/
│   └── requirements.md              # Spec quality checklist (complete)
└── tasks.md                         # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/bash/
├── engine/
│   ├── parse.sh                     # CHANGED — read the marker, exclude it from every extraction
│   ├── story_marker.sh              # NEW — assign identifiers, splice marker lines, byte-preserving
│   └── managed_section.sh           # UNCHANGED — line-ending helper reused
├── sink/jira/
│   ├── identity.sh                  # CHANGED — marker gains `story`; read folded into the issue GET
│   ├── recognition.sh               # NEW — read recorded tickets, verify markers, build the result
│   └── plan_apply.sh                # CHANGED — populate `skipped`; stamp + record on each create
└── commands/
    └── reconcile.sh                 # CHANGED — sequence assign → recognise → plan → record

scripts/powershell/                  # the same six files, mirrored
├── engine/{Parse,StoryMarker,ManagedSection}.psm1
├── sink/jira/{Identity,Recognition,PlanApply}.psm1
└── commands/Reconcile.psm1

tests/bash/
├── engine/test_story_marker.bats            # NEW — grammar, placement, byte preservation, CRLF
├── engine/test_parse_marker.bats            # NEW — marker excluded from title/description/AC
├── sink/test_recognition.bats               # NEW — decision table, fault matrix
└── commands/test_reconcile_idempotent.bats  # NEW — the regression: two runs, one ticket
tests/powershell/                            # mirrors the four suites above

tests/conformance/
├── scenarios/us1-recognition-second-run.json    # NEW — the double run, both ports
├── scenarios/us1-recognition-reorder.json       # NEW — reorder/retitle never swaps tickets
├── scenarios/us2-zero-churn-unchanged.json      # NEW — zero writes, spec.md byte-identical
├── fixtures/repo-with-mirrored-spec/            # NEW — a spec whose stories carry markers
└── mock-jira/mock-server.ps1                    # CHANGED — stateful issues, properties, sequential keys

tests/live/                                      # CHANGED — the double-run assertion (Constitution II)
```

**Structure Decision**: the existing script-native layout is kept exactly as it is. The
two new modules sit on the side of the boundary their job belongs to — identifier
assignment and Markdown splicing in `engine/`, ticket reads and marker verification in
`sink/jira/` — and only `commands/reconcile.sh` sources both, the same shape 004
established. The mock double is the one piece of test infrastructure that must grow: it
is write-only today and cannot express "the ticket exists now", without which none of
this is testable.

## Scope boundaries worth stating

Three things a reader might expect to find here and will not:

1. **No status transitions.** Recognition supplies everything the drift, Flagged, and
   blocker rules evaluate, and those rules fire — but no transition request is emitted,
   exactly as today. R9 records why: no requirement asks for it, and it would cost a
   second call per ticket.
2. **No migration.** Tickets created before this fix carry no marker and cannot be
   recognised. Their specifications will be mirrored afresh, producing one duplicate
   generation on first upgrade. The spec puts this Out of Scope; the CHANGELOG must say
   so in plain words, because it is the one user-visible cost of the fix.
3. **No adoption widening.** A ticket whose marker is absent or contradictory is never
   adopted, only reported. Adoption stays the opt-in, label-gated flow of Constitution I.

## Complexity Tracking

No Constitution Check violations. This section is intentionally empty.
