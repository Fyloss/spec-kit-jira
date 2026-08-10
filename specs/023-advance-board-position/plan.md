# Implementation Plan: Each Tier Advances Along Its Own Declared Workflow

**Branch**: `feat/advance-board-position` | **Date**: 2026-08-10 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/023-advance-board-position/spec.md`

## Summary

The declared lifecycle mapping is read, validated, and used to classify drift — and then never moves
anything. The decision half is complete; the write half was deliberately deferred and is pinned by a test
that says so. This feature completes it, and at the same time makes the mapping **per hierarchy role**, so an
Epic, a Story and a Sub-task each advance along their own workflow rather than sharing one.

The technical approach is deliberately small, because the shapes already exist. A sibling of the sub-task
tier's transition reader selects an offered move by the **destination step's declared name** instead of its
category, returning the same four outcomes that tier already settled plus the reachable set. The per-ticket
lifecycle context gains a `role` and a resolved `move`; the planning loop is given an explicit ticket list
so the specification-tier parent can join it. The configuration accepts a role-keyed shape alongside the
existing one, with the existing shape continuing to mean the story role. The engine is untouched.

Full reasoning in [research.md](research.md); shapes in [data-model.md](data-model.md); binding behaviour in
[contracts/](contracts/).

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port) and PowerShell 7+ (Windows port) — two native
implementations, no shared runtime

**Primary Dependencies**: `curl`, `jq`, `git` for the Bash port; native cmdlets for the PowerShell port. No
new dependency is introduced by this feature.

**Storage**: N/A. Configuration is YAML on disk (committable team layer); Jira Cloud is the sink; no
database and no local state beyond the existing run state.

**Testing**: `bats` (Bash), `Pester` (PowerShell), and the shared language-agnostic conformance corpus
against both test doubles. Coverage gate 80% statement minimum — kcov for Bash, Pester CodeCoverage for
PowerShell. Drift decision is a named critical path and targets near-total coverage.

**Target Platform**: macOS, Linux, Windows — a green three-OS matrix is the merge gate.

**Project Type**: CLI extension for spec-kit, invoked directly and from lifecycle hooks.

**Performance Goals**: at most one additional read per ticket for which a move is **due** (contract §1), and
one additional write only where that read resolves to a single ungated candidate; exactly zero additional
requests for a ticket for which no move is due and for a project that declares no mapping (research R8,
SC-011, SC-003). A withheld outcome — ambiguous, gated, unreachable — and every `--dry-run` ticket cost the
read and no write. This constraint is inherited from feature 021's request-count work and must not be undone.

**Constraints**: byte-identical output *and* an identical request sequence between the ports; zero-churn
idempotency on re-runs; fail-closed on any read failure; non-blocking inside a lifecycle hook; no new
configuration key beyond the one shape change; no status name built into the product.

**Scale/Scope**: enterprise Jira — multiple projects, three hierarchy roles, heterogeneous workflows per
role, six lifecycle events (`after_specify`, `after_clarify`, `after_plan`, `after_tasks`,
`after_implement`, `after_analyze`).

**Unknowns**: none remain. All ten questions raised at Phase 0 are resolved in [research.md](research.md).

## Constitution Check

*GATE: passed before Phase 0 research; re-checked after Phase 1 design (see below).*

| # | Principle | Gate at design level | Verdict |
|---|---|---|---|
| I | Filesystem Is the Source of Truth | Only tickets already recognised as this specification's are moved; the safety rules that refuse to regress a ticket without a named warning are consumed unchanged. No delete. No third exception — nothing is written back to the repository. | PASS |
| II | Zero-Churn Idempotency | A ticket at its role's declared step triggers no read, no move, no warning (contract §9). The principle names `transitioned` among the write kinds a second run must leave at zero, and requires the live double-run assertion to be extended in the same change that adds a write kind — that extension is a planned task, not an option. | PASS |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | The availability read is issued during planning, before any action is applied, so its failure leaves the ticket untouched and the specification unwritten (contract §3). A refused move is reported and not retried (§6). Every new warning is non-blocking inside a hook. | PASS |
| IV | Credential Security | Unaffected. No credential is read, written, recorded, or reported; the new read uses the existing authenticated conduit. | PASS |
| V | Config / Local Binding / Secrets | The one configuration change lands entirely in the committable team layer, where the mapping already lives. Role names and step names are public within the organisation, so nothing credential-shaped enters either YAML layer. | PASS |
| VI | Portability | Both ports, byte-identical output and identical request sequence (contract §11). The new warnings are multi-line prose, so they are assembled through the port's output helper rather than a direct `jq` call, and no glob pattern contains a CRLF literal — both quirks are recorded in `docs/10-windows-portability.md`. A Windows probe run gates the platform claim. | PASS |
| VII | No Hard-Coded Workflow Assumptions | The principle the feature exists to honour. Selection is by the operator's declared step name against what the project offers, with no built-in table, no assumed ordering, no default workflow (contract §4). Making the mapping per-role removes an existing violation: one mapping shared by three tiers *is* an assumption about the workflow. | PASS — improves compliance |
| VIII | Neutral Engine / Jira Sink | The engine keeps deciding *whether* to advance and never learns that roles select workflows: it receives an order and a target, as today. The sink alone knows what a transition is. No new Atlassian identifier enters any engine script. | PASS |
| IX | Two-Tier Privacy Guard | Unaffected. A move carries no composed text, and where a workflow demands a value the feature declines to supply one — so no new surface is written and none needs scanning. | PASS |
| X | Self-Healing Automatic Mirror | Directly served: a board behind the specification is brought back to each tier's declared step on the next run. Hook registration and health untouched. | PASS |
| XI | Universal Dry-Run and Auditability | The preview performs the read and no move, and predicts every ticket, role, step pair and warning exactly (contract §10). A new top-level `transitioned` count makes moves auditable. No destructive operation is added. | PASS |
| XII | Quality and Catalog Publication | CHANGELOG entry, three-OS matrix, lint, coverage. Documentation is corrected in the same change (FR-027) rather than after. Dogfooding must exercise **two tiers**, otherwise it does not test the change that motivated the feature. | PASS |
| XIII | TDD With 80% Coverage | The first test written is the one that fails today. The test currently pinning "zero transition requests in every scenario" is rewritten in the change that makes it false, its intent preserved as the narrower assertion that an unmapped project issues zero moves — never deleted quietly. Tests identify state by recorded identity, per the isolation rule. | PASS |
| XIV | KISS | Nothing is invented: the mapping, the safety decision, the warning channel, the transitions endpoint, the action shape and the three roles all exist. One predicate changes (category → declared name), one existing mapping is keyed by an existing concept, and one guard is finally satisfiable. Alternatives considered and rejected are recorded per decision in research.md. | PASS |
| XV | YAGNI | Exactly one configuration change, and FR-017 forbids any other. Multi-hop walking, configuration-time discovery, per-role halted lists, and tie-break configuration are named out of scope and not built. Every new field in data-model.md traces to a functional requirement. | PASS |
| XVI | Human Readable | Every unresolvable outcome is one sentence naming the ticket, its role, the step that was wanted, and what stood in the way. The configuration names each role's workflow in the vocabulary the file already uses, so a tech lead reads three named sections without the documentation. FR-027 makes the documentation itself honest. | PASS |

**No violations. The Complexity Tracking table below is therefore empty**, as governance requires when a
Constitution Check has nothing to justify.

## Project Structure

### Documentation (this feature)

```text
specs/023-advance-board-position/
├── plan.md                              # This file
├── spec.md                              # The specification
├── research.md                          # Phase 0 — ten decisions, alternatives rejected
├── data-model.md                        # Phase 1 — config shape, ticket entry, move, counts, warnings
├── quickstart.md                        # Phase 1 — eight validation scenarios and the gates
├── contracts/
│   ├── lifecycle-transition.md          # Resolving and performing a move (11 clauses)
│   └── role-lifecycle-config.md         # The per-role configuration surface (8 clauses)
├── checklists/
│   └── requirements.md                  # Specification quality checklist
└── tasks.md                             # Phase 2 — NOT created by /speckit-plan
```

### Source code (repository root)

```text
scripts/bash/
├── lib/
│   ├── config.sh                        # CHANGED — accept + normalise the role-keyed shape,
│   │                                    #   validate it, classify/order per role (callers only:
│   │                                    #   config_classify_statuses and
│   │                                    #   config_phase_status_targets keep their signatures)
│   └── output.sh                        # CHANGED — summary_render_prose gains the `Transitioned:`
│                                        #   line, guarded by has("transitioned") so no other
│                                        #   command's prose summary moves (FR-024's prose half)
├── engine/
│   └── drift.sh                         # UNCHANGED — receives a role's order and target as today
├── sink/jira/
│   ├── discovery.sh                     # NEW reader — select an offered move by destination
│   │                                    #   step name; returns candidates/transition_id/
│   │                                    #   withheld_field/reachable. Sibling of
│   │                                    #   discovery_task_transition, which is unchanged
│   └── plan_apply.sh                    # CHANGED — plan_lifecycle takes an explicit ticket list
│                                        #   carrying local_id + role; consumes the resolved move;
│                                        #   emits via the existing _plan_transition_action.
│                                        #   plan_lifecycle_tasks UNCHANGED
└── commands/
    └── reconcile.sh                     # CHANGED — resolve the mapping per role, include the
                                         #   parent in the lifecycle ticket list, issue the
                                         #   availability read lazily, add the top-level
                                         #   transitioned count

scripts/powershell/                      # The twin of every change above
├── lib/Config.psm1
├── lib/Output.psm1
├── sink/jira/Discovery.psm1
├── sink/jira/PlanApply.psm1
└── commands/Reconcile.psm1

tests/
├── bash/
│   ├── hooks/test_hook_resilience.bats  # the availability-read fault joins the enumerated
│   │                                    #   faults at `:90`; it does not sweep, so a new
│   │                                    #   fault kind must be named to be covered
│   ├── lib/test_config.bats             # role-keyed shape: accept, reject, normalise
│   ├── sink/test_discovery.bats         # the five outcomes of contract §5
│   ├── sink/test_plan_apply*.bats       # ticket list, role routing, independence
│   └── commands/test_reconcile_lifecycle.bats
│                                        # the pinning test is REWRITTEN here (research R1)
├── powershell/                          # Pester twins of the above
└── conformance/
    ├── scenarios/                       # new scenarios: per-role advance, the three
    │                                    #   unresolvable shapes, upgrade compatibility,
    │                                    #   fail-closed, refusal, preview
    └── mock-jira/                       # fixtures gain per-role workflows; both doubles
                                         #   already serve the transitions endpoint

docs/
├── 08-safety-model.md                   # CORRECTED — the decision table's "emitted" row
├── VISION.md                            # CORRECTED — Part 1 and item 3's status
└── 07-configuration-and-secrets.md      # role-keyed shape documented with a worked example
```

**Structure Decision**: no new module and no new directory. The feature lands in the four modules that
already own its concerns — configuration, discovery, planning, and the reconcile command — plus their
PowerShell twins. The engine is deliberately untouched, which is the clearest available evidence that
Principle VIII holds: a feature about Jira workflows required no change to the code that knows nothing about
Jira.

## Phase 0 — Research

Complete. See [research.md](research.md). Ten questions resolved:

R1 where the write half breaks (one guard, a deliberate boundary with a pinning test) · R2 how a move is
found by step name (a sibling reader, four outcomes reused) · R3 the configuration shape (two shapes at one
key, structurally discriminated) · R4 per-role classification and ordering (a caller change) · R5 extending
the evaluation to the parent (an explicit ticket list) · R6 completion versus mapping on a sub-task
(completion wins) · R7 the move count (a new top-level `transitioned`) · R8 cost when inert (lazy, gated on
every condition of contract §1) · R9 refusing a multi-hop target (report the reachable set) · R10 the doubles (already
serve the endpoint; fixtures gain per-role workflows).

**No `NEEDS CLARIFICATION` remains.**

## Phase 1 — Design

Complete. Artefacts:

- **[data-model.md](data-model.md)** — the two configuration shapes and their normalised form; the lifecycle
  ticket entry with its new `role` and `move`; the move resolution with its five outcomes; the run-summary
  counts; the exact wording of the five new warnings; and the per-ticket state transition diagram.
- **[contracts/lifecycle-transition.md](contracts/lifecycle-transition.md)** — eleven clauses covering when
  a move is considered, which mapping applies, the availability read and its fail-closed behaviour,
  selection, the five outcomes, performing and refusal, task-role precedence, independence, idempotency,
  preview, and cross-port equivalence.
- **[contracts/role-lifecycle-config.md](contracts/role-lifecycle-config.md)** — eight clauses covering the
  surface, both shapes, structural discrimination, validation messages, the normalised form, the consumers,
  interaction with sub-task mirroring, and the documentation owed.
- **[quickstart.md](quickstart.md)** — the failing test to write first, then eight validation scenarios and
  the gates.

### Post-Design Re-Check

The Constitution Check above was re-evaluated against the finished design. No verdict changed. Three points
are worth recording because the design could plausibly have broken them and does not:

1. **Principle VIII survived a feature about workflows.** The engine file list is empty. The role selects
   which mapping the *caller* resolves; `drift_evaluate` still receives an order and a target and still
   knows nothing about Jira, roles, or transitions.
2. **Principle II's write-kind list is honoured rather than assumed.** The principle requires the live
   double-run assertion to be extended in the same change that adds a write kind. This feature does not add
   a kind — `transitioned` was always in the list — but it is the first to make it reachable, which is the
   same obligation in substance. It is planned as a task.
3. **Principle XV held against an easy expansion.** Per-role halted statuses, a tie-break for ambiguous
   candidates, and multi-hop walking each looked natural while designing and each is refused, named in Out
   of Scope, and traceable to no functional requirement.

One design decision remains flagged rather than settled, and is the strongest candidate for a
`/speckit-clarify` round if the operator wants one: **FR-016**, that a task's own completion outranks the
declared mapping on its own sub-task (research R6). It is the only interaction the feature invents rather
than inherits.

## Complexity Tracking

> Filled only when the Constitution Check has violations requiring justification.

None. The Constitution Check records sixteen passes, no deviation, and no new dependency, module,
abstraction, or configuration key beyond the single shape change FR-017 admits and FR-010 requires.
