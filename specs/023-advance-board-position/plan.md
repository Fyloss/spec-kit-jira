# Implementation Plan: Each Tier Advances Along Its Own Declared Workflow

**Branch**: `feat/advance-board-position` | **Date**: 2026-08-13 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/023-advance-board-position/spec.md`

## Summary

The write path for a status move already exists and is exercised: `_plan_transition_action`
(`sink/jira/plan_apply.sh`) is a single shared POST emission site, and `plan_lifecycle` emits it for any
recognised story whose lifecycle context carries a non-empty `transition_id`. Nothing on the real path ever
fills that field, and two upstream gaps mean the decision that would fill it is never reached at all: the
lifecycle event does not travel from the host to the bridge, and — since 021 — a run whose hashed local
inputs are unchanged short-circuits before the pipeline starts.

This feature is therefore four connected pieces, in this order:

1. **Carry the event.** `SPEC_KIT_JIRA_HOOK_EVENT` is the existing seam and stays the mechanism; the
   agent-facing procedure becomes normative about setting it, with a host-command → event table. No new
   flag (spec FR-025 forbids one).
2. **Stop the run skipping an event it has not honoured.** The run-state document goes to schema 2, gaining
   `hook_event` and `plan.md` among its hashed inputs. Byte-equality stays the matching rule.
3. **Declare a workflow per hierarchy role.** `projects[].phase_status_map` accepts either today's
   event → status mapping (which keeps meaning the story role) or a role → (event → status) mapping. The two
   key sets are closed and disjoint, so the shape is discriminated without ambiguity.
4. **Resolve the declared step into a move, and emit it.** A new sink module reads the available moves for
   exactly the tickets a safety decision said should advance, and resolves them by destination *name* — the
   one rule that differs from `discovery_task_transition`, which resolves by destination *category*. The
   four outcomes (one ungated candidate, several, gated, none) are the ones the task tier already settled.

The specification tier joins the story tier in lifecycle evaluation (its recognition read must widen to
carry `status`), and the task tier's mapping applies only where `task_mirror` resolves to `subtask`.

One decision cannot be made from the repository and is deferred to a measurement, not to an assumption:
whether the tracker can report available transitions — **with required-field detail** — for many issues in
one request. Research R1 specifies both branches and confines the difference to one module.

## Technical Context

**Language/Version**: Bash ≥ 4.0 (macOS/Linux port) and PowerShell 7+ (Windows port), twin native
implementations, no compiled artefact and no build step.

**Primary Dependencies**: `curl`, `jq`, `git` (Bash port, all pre-existing prerequisites); PowerShell's
in-process JSON and HTTP for the twin. **No new dependency.**

**Storage**: `.specify/jira/config.yml` (committable team layer — the one changed surface),
`.specify/jira/config.local.yml` (gitignored binding, unchanged), `.specify/jira/state/<feature>.json`
(the run-state document, schema 1 → 2).

**Testing**: `bats` (`tests/run-bash.sh`, ~190 s), Pester (`tests/powershell`), and the shared conformance
corpus (`tests/conformance/ci-conformance.sh`) with the scripted `curl` replacement and the PowerShell mock
server. Counting stand-ins from 024 (`PATH`-interposed shim) for the spawn and request budgets, in runs
separate from any timing run (024 contract §4, C4.2).

**Target Platform**: macOS, Linux, Windows — three-OS CI matrix, green is a merge gate.

**Project Type**: CLI extension to a host (Spec Kit), invoked by lifecycle hooks and by an agent.

**Performance Goals**: inherited, not new. A run in which no ticket is due a move costs exactly today's
requests, external processes, and configuration parses (spec SC-015). A run moving N tickets issues N
transition writes plus a bounded number of availability reads (spec SC-012, and 021 SC-003). The spawn count
does not change when N doubles (spec SC-013, and 024 contract C1.2).

**Constraints**: engine keeps zero Jira knowledge (boundary greps in `.github/workflows/boundary.yml`);
every request attributed to the phase that issued it, per-phase counts summing to the run's total (024
SC-014); the Bash port never calls `jq` for multi-line output (Windows CRLF, `AGENTS.md`); paths handed to
`curl` spelled with `cygpath -m`; byte-identical output and identical call sequence between ports.

**Scale/Scope**: the reference profile is 1 parent + 60 stories; the largest realistic move set is every
recognised ticket of one role on the first event after a change. Four contracts, two new module pairs' worth
of behaviour (one new module pair), one schema bump, one config-surface change.

## Constitution Check

*GATE: passed before Phase 0. Re-checked after Phase 1 — result at the bottom of this section.*

| # | Principle | Gate result |
| --- | --- | --- |
| I | Filesystem is the source of truth | **PASS.** No new controlled exception. The only writes to the tree are the run-state document (already 021's, gitignored and self-ignoring) and the marker splices that already happen. Nothing is deleted; only recognised tickets move. |
| II | Zero-churn idempotency | **PASS.** The constitution's write-kind list already names `transitioned`; this feature makes it non-zero at two tiers, so the live double-run assertion must be extended in this same change (Principle II's enforcement test says so explicitly). Contract `transition-resolution.md` §7 states the double-run assertion. |
| III | Fail-closed on writes, non-blocking on hooks | **PASS, with one deliberate asymmetry.** The availability read fails closed for the affected specification (FR-034), matching `discovery_task_transition`. The *bulk* form of that read fails **open** to the per-key form — identical to 021's prefetch invariant P2 — because a failed optimisation must never become a classification (FR-031). Warnings stay non-blocking inside a hook. |
| IV | Credential security | **PASS.** No credential is read, written, or recorded. `hook_event` is a closed-set lifecycle constant, not a secret. The credential cache is primed once, in the main shell, before the first request-issuing phase — unchanged, and the new read sits after that priming. |
| V | Team config / local binding / secrets | **PASS.** The one configuration change lands in the committable team layer beside the mapping it extends. Nothing is added to the binding or the secrets layer. |
| VI | Portability | **PASS.** Both ports, byte-equivalent, proven by the corpus including the recorded call sequence. Windows risk is concentrated in the resolution module's structured output — routed through `lib/output.sh` in the Bash port (never a bare `jq` multi-line write). The `--json` summary gains one conditional key; its canonical form is the existing one. |
| VII | No hard-coded workflow assumptions | **PASS — this is the principle the feature serves.** Selection is by the declared destination *name* against what the project offers: no built-in status table, no ordering assumption, no default workflow. The three unresolvable shapes (several candidates, gated, unreachable) are reported, never guessed. Contract `transition-resolution.md` §3 is the normative rule and the boundary grep already forbids an Atlassian identifier in the engine. |
| VIII | Neutral engine / Jira sink | **PASS.** `engine/drift.sh` is consumed unchanged — it already takes the current status, its category, the target, the order and the drift mode, and returns one decision. The new module is `sink/jira/`; the engine gains no vocabulary. The lifecycle event is a spec-kit concept and stays on the engine side of the seam. |
| IX | Privacy guard | **PASS.** A transition body is `{transition:{id}}` — no composed text, so no new scanned surface. The guard runs before the write exactly as today; the resolution declines to supply any field value (FR-005/FR-006), so nothing new can leak. |
| X | Self-healing automatic mirror | **PASS, and partly restored.** Piece 2 is what makes "the next run" mean the next lifecycle event rather than the next file edit. Hook registration and health are untouched. |
| XI | Universal dry-run and auditability | **PASS.** Resolution happens inside the planning pass, which is the exact computation `--dry-run` performs, so the preview predicts the move and every withholding. `--dry-run` still neither reads nor writes the run-state document (021 invariant S6), so the preview cannot change what the following real run does. No destructive operation is added. |
| XII | Quality and catalog publication | **PASS.** CHANGELOG entry, full suite, corpus, linters on three OSes, and a dogfood run that must watch a real board advance on more than one tier and on a second lifecycle event that changed no file. The R1 measurement (below) is taken on that same instance. |
| XIII | TDD, 80% coverage | **PASS.** Every phase below leads with its failing test; the first one written is the currently-passing pin `"zero transition requests in scenario — this release evaluates the rules but never moves a ticket's status"` (`tests/bash/commands/test_reconcile_lifecycle.bats:123` and `Reconcile.Lifecycle.Tests.ps1:132`), which this feature rewrites rather than deletes. Drift decision is a named critical path and keeps its near-total coverage target. Budget requirements are counting assertions, in runs separate from timing runs. |
| XIV | KISS | **PASS.** No new abstraction layer. One new module pair, following `prefetch.sh`'s precedent of giving a bulk read its own home; the engine's decision function, the warning channel, the summary, the POST emission site, and the four resolution outcomes all already exist and are reused. The one genuinely new rule is name-matching in place of category-matching. |
| XV | YAGNI | **PASS, with one item argued rather than assumed.** Exactly one config-surface change; no new flag. Pieces 1 and 2 are defects of other features, and the specification argues in the open (Assumptions) that FR-001's promise is unreachable without them — a requirement may not demand an outcome it also makes impossible. Nothing is built for the roles a project does not declare. |
| XVI | Human readable | **PASS.** The per-role mapping reuses the role names already in the same project entry's `hierarchy:` block. Every non-move outcome is one sentence naming the ticket, its role, the wanted step and what stood in the way. The inert-mapping outcome is one note per run, never one per entry. |

**One deliberate departure**, carried in Complexity Tracking below: spec FR-016 — and, stating the same
promise from the cost side, SC-015 and User Story 9 AC4 — ask that a run under an event declaring no step
short-circuit *exactly* as today. The design delivers that for every event that changes a hashed input —
which, once `plan.md` is hashed, is five of the six — and costs one full reconcile for an event that changes
nothing at all (in practice `after_analyze`, once). The alternatives that would have delivered them
literally each break the byte-equality rule that makes the short-circuit trustworthy. All three are amended
in the same change.

**Post-Phase-1 re-check**: no gate changed. The four contracts introduced no dependency, no flag, and no
abstraction beyond the single new module pair already accounted for under XIV.

## Project Structure

### Documentation (this feature)

```text
specs/023-advance-board-position/
├── plan.md                              # This file
├── research.md                          # Phase 0 — R1…R9
├── data-model.md                        # Phase 1
├── quickstart.md                        # Phase 1
├── contracts/
│   ├── lifecycle-event.md               # How the event reaches the run
│   ├── run-state-v2.md                  # The schema-2 document and its decision table
│   ├── role-lifecycle-config.md         # phase_status_map, per role
│   └── transition-resolution.md         # The read, the four outcomes, the budgets
├── checklists/requirements.md           # Specify-stage quality checklist
└── tasks.md                             # /speckit-tasks output — NOT created here
```

### Source Code (repository root)

```text
commands/
└── speckit.jira.reconcile.md            # CHANGED — normative event conveyance, flag list, per-role mapping

extension.yml                            # unchanged (hooks block already declares all seven events)

scripts/bash/
├── commands/reconcile.sh                # CHANGED — event into run_state; per-role context; parent tier;
│                                        #   resolution call site inside the `plan` phase
├── engine/drift.sh                      # UNCHANGED — consumed as-is
├── lib/config.sh                        # CHANGED — per-role phase_status_map schema + resolver
├── lib/run_state.sh                     # CHANGED — schema 2: hook_event, plan.md
└── sink/jira/
    ├── transitions.sh                   # NEW — the availability read + name resolution
    ├── discovery.sh                     # UNCHANGED — discovery_task_transition keeps its category rule
    ├── prefetch.sh                      # CHANGED only under research R1 branch A
    ├── recognition.sh                   # CHANGED — the parent read carries status/flagged/links
    └── plan_apply.sh                    # CHANGED — parent tier, resolution outcomes → warnings

scripts/powershell/                      # the module-for-module twin of every line above
└── sink/jira/Transitions.psm1           # NEW

docs/
├── 05-reconcile-flow.md                 # CHANGED — where a move is decided and issued; event conveyance
├── 08-safety-model.md                   # CHANGED — the decision table's "emitted" becomes true
└── VISION.md                            # CHANGED — Part 2 item 3 moves to Shipped

tests/
├── bash/commands/test_reconcile_lifecycle.bats      # the pin is rewritten here
├── bash/sink/test_transitions.bats                  # NEW
├── powershell/…                                     # the twins
└── conformance/
    ├── scenarios/                                   # new scenarios, both branches of every outcome
    └── mock-jira/                                   # transitions in bulkfetch (R1 branch A)
```

**Structure Decision**: the existing four-layer split is kept exactly. The only new leaf is
`sink/jira/transitions.sh` and its PowerShell twin — placed in the sink because it reads the tracker and
knows what a transition is, and given its own module (rather than appended to `discovery.sh`) for the same
reason `prefetch.sh` exists: it owns a read whose bulk-versus-per-key shape is decided by one contract and
must be swappable without touching its callers.

## Phase 0 — Research

Consolidated in [research.md](./research.md). Nine questions; R1 is the only one that cannot be closed from
the repository and is closed by a named measurement task before any code in Phase C is written.

| # | Question | Outcome |
| --- | --- | --- |
| R1 | Can available transitions, **with required-field detail**, be read for many issues in one request? | **Open — decided by measurement.** Both branches specified; the difference is confined to `transitions.sh`. Branch C amends FR-027. |
| R2 | Where does resolution sit in the pipeline? | Inside the `plan` phase, before `plan_lifecycle` returns — the same computation `--dry-run` performs. |
| R3 | How is the per-role mapping discriminated from the legacy one? | Two closed, disjoint key sets. Mixed keys are a config refusal. |
| R4 | What does the run-state document need, and what does it cost? | `hook_event` + `plan.md`, schema 2, byte-equality preserved. Measured cost: one full reconcile for `after_analyze`. |
| R5 | How does the event reach the bridge? | The existing env seam, made normative in the command procedure. No new flag. |
| R6 | What must change for the specification tier? | The parent recognition read must carry `status`, `flagged`, `issuelinks`; the prefetch union already has them. |
| R7 | How does the task tier behave under 022's two modes? | `subtask` only; `checklist` and absent-tier are one note per run. |
| R8 | How are the budgets asserted? | 024's `PATH`-interposed counting stand-in, counting runs separate from timing runs. |
| R9 | What does the existing pin test become? | Rewritten in place, with a preserved scenario asserting zero moves where nothing is declared. |

## Phase 1 — Design & Contracts

Produced: [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md).

**Entities** (data-model.md): the per-role lifecycle mapping; the run-state document v2; the availability
record and the four resolution outcomes; the lifecycle context entry as it grows a role and a target; the
run summary's conditional `transitioned` count.

**Contracts**:

- `lifecycle-event.md` — the closed event set, the host-command → event table, the conveyance rule, and what
  a run with no event must do (byte-identical to today).
- `run-state-v2.md` — the schema-2 fields, the amended decision table, the invariants that survive from 021
  (every doubt fails open; `--dry-run` neither reads nor writes it), and the measured cost of the one event
  that loses its short-circuit.
- `role-lifecycle-config.md` — both accepted shapes, the discrimination rule, every validation message, the
  per-role status order and category classification, and the back-compatibility guarantee.
- `transition-resolution.md` — the read (both R1 branches), the name-matching rule, the four outcomes with
  their exact warning wording, the request and spawn budgets, and the double-run assertion.

## Implementation phases (ordering guidance for `/speckit-tasks`)

Each phase leads with its failing test; Principle XIII forbids an implementation task not preceded by its
test task. Phases A and B are prerequisites for C; D, E and F are independently testable on top of C.

- **Phase A — the event reaches the run** (FR-010…FR-012). The command procedure, the host-command → event
  table, and the assertion that each of the six events resolves its own declared step while a direct
  invocation resolves none. Delivers the read half for the first time, with no write yet.
- **Phase B — the run stops skipping an unhonoured event** (FR-013…FR-016). Run-state schema 2, `plan.md`
  hashed, the amended decision table. The failing test is two consecutive events over byte-identical files.
- **Phase C — a workflow per role, and the move itself** (FR-001…FR-009, FR-017…FR-020, FR-025…FR-031,
  FR-034, FR-035, FR-039). The config shape, `sink/jira/transitions.sh`, the four outcomes, the budgets.
  R1's measurement is taken before the first line of `transitions.sh`.
- **Phase D — the specification tier** (FR-021). Parent read widening, parent lifecycle evaluation, identical
  decisions and identical warning wording as a story.
- **Phase E — the task tier under two modes** (FR-022…FR-024). Sub-task mode advances; checklist mode is one
  note; a checkbox still outranks the mapping; an abandoned sub-task is never moved.
- **Phase F — reporting, preview, documentation, ports** (FR-030, FR-032, FR-033, FR-036…FR-041). The
  conditional `transitioned` count, timing attribution, the dry-run twin, the four documents, and the
  conformance corpus proving both ports byte-identical.

## Complexity Tracking

| Violation | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| **Spec FR-016, SC-015 and User Story 9 AC4 are narrowed**: an event that changes no hashed input costs one full reconcile the first time it fires against a given input state, instead of short-circuiting exactly as today. All three state the same promise and all three are amended in the same change. | The run-state document is matched by **byte-equality of a freshly composed document** (021 data-model §1), and it is composed *before* the config phase — deliberately, because config resolution is a meaningful fraction of the one-second budget. So the composer cannot know whether any role declares a step for this event; only the raw event name is available to it. | Two alternatives were designed and rejected. (a) *Record whether the previous run found any declared mapping, and compare the event only then* — this makes matching a per-field rule instead of byte-equality, which is the property that makes the short-circuit auditable and port-identical. (b) *Move the state phase after config* — a change to 021's contract §2 with its own regression surface, to buy back one full reconcile. The measured cost of the narrowing is bounded and small: five of the six events change a hashed input once `plan.md` is added, so only `after_analyze` pays, once per input state. |
| **New module pair** `sink/jira/transitions.sh` / `Transitions.psm1`. | Research R1's two branches differ in one function's request shape. Confining them to one module keeps every caller identical under either branch and gives the bulk-versus-per-key decision a single contract and a single test surface. | Appending to `sink/jira/discovery.sh` was the smaller diff, but it puts a category-matching resolver and a name-matching resolver in one file with one shared read path, and it gives the R1 branch no boundary. `prefetch.sh` set this precedent for exactly the same shape in 021. |

**Research R1 resolved to branch C** (2026-08-13, decided from 021's dogfood-verified `bulkfetch` shape and
the per-key endpoint's existing production use — see `research.md` §R1). The availability read grows one
round-trip per ticket due a move, so the "MUST NOT grow one-for-one" bound cannot be met and is amended to
"MUST NOT be issued for a ticket that is not due a move" (FR-026's bound, which branch C does satisfy). The
bound is stated in three places and all three are amended together: spec FR-027, SC-012, and User Story 9
AC1.
