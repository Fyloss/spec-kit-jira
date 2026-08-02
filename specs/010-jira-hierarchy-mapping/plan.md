# Implementation Plan: The Operator Declares Which Issue Types Carry the Mirror

**Branch**: `feat/handle-multiple-epics` | **Date**: 2026-08-02 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/010-jira-hierarchy-mapping/spec.md`

## Summary

A consumer's Jira reports two issue types above its story tier, so
`hierarchy_derive` returns `parent-level-ambiguous` and the configuration
ceremony exits `4` before the story tier is even examined. There is no flag, no
key and no question that lets the operator say which one to use. This plan adds
that answer channel.

The mechanism is a per-project `hierarchy` mapping in the **committed**
`config.yml`, keyed by the repository's own vocabulary — `specification`,
`story`, `task` — rather than by Jira's internal level numbers. One resolver
handles all three roles with the precedence *declared → answered → derived*,
records provenance beside the existing `style_source`, and refuses every
impossible mapping before a ticket exists.

The change is deliberately confined to the configuration layer. The binding is
**dual-written**: `roles.*` is the new authoritative record, while the existing
`child_type` / `parent_type` keys are written in lockstep and remain what the
reconcile path reads. That keeps `plan_writes`, `plan_apply`, `recognition`,
`identity` and the stale-binding detector untouched for User Stories 1–4, which
is what makes FR-004's "nothing changes without a mapping" enforceable rather
than merely intended.

The task tier (User Story 5, P3) is planned as a separate stage behind its own
gate. Its declaration and validation ship with everything else — a role that
silently does nothing would be worse than no role at all — but nothing parses
`tasks.md` in either port today, so building it is an engine feature roughly the
size of 008 and would delay the unblock by its own length.

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux) and PowerShell 7+ (Windows) — twin
native ports, no shared runtime, proven equivalent by a conformance corpus.

**Primary Dependencies**: `jq`, `curl`, `git` (bash port); built-in cmdlets
(PowerShell port). No new dependency is introduced.

**Storage**: Three YAML files under `.specify/jira/` — the committed
`config.yml`, the gitignored machine-owned `config.local.yml`, the gitignored
`.env`. Parsed by the repository's own YAML subset reader/writer
(`lib/config.sh`, `lib/Config.psm1`), which is a documented fixed point: what
the writer emits, the reader reads back.

**Testing**: `bats` (bash), `Pester` (PowerShell), the cross-port byte-equivalence
corpus (`tests/conformance/ci-conformance.sh`) against a mock Jira, plus a live
run against the real instance. `tests/run-bash.sh --since <ref>` is the inner
loop; the full bash suite is ~190 s.

**Target Platform**: macOS, Linux, Windows (PowerShell 7+, MSYS bash under
Git for Windows).

**Project Type**: CLI extension for Spec Kit — a set of shell entry points fired
by lifecycle hooks.

**Performance Goals**: No change. This feature adds no Jira call: every input it
needs (`issue_types` with levels and sub-task flags) is already in the discovery
payload.

**Constraints**:
- Both ports change in the same commit and stay byte-identical (Constitution VI).
- Multi-line JSON must go through the port's output module — the Windows `jq`
  build emits CRLF on multi-line output.
- Never put `$'\r\n'` inside a glob pattern (`docs/10-windows-portability.md`).
- Every refusal: zero Jira writes, exit `4` direct, one WARNING and exit `0`
  under a hook.
- No Atlassian default type name may appear in `scripts/` — mechanically
  checkable (`contracts/role-mapping.md` header).

**Scale/Scope**: ~2 100 lines across the four bash files most affected and their
PowerShell twins; the consumer instance has 17 issue types across 3 levels. The
committed configuration format gains exactly one optional key.

## Constitution Check

*GATE: passed before Phase 0. Re-checked after Phase 1 design — see the
re-evaluation below.*

| # | Principle | Gate | Verdict |
| --- | --- | --- | --- |
| I | Filesystem is source of truth | Does any Jira state become authoritative? | **PASS** — the declaration is on disk; the binding is a re-derivable mirror, reproducible by deleting it and re-running. No ticket is adopted, re-typed or re-parented by a mapping change. |
| II | Zero-churn idempotency | Does a second run write? | **PASS** — contract §5.2 (byte-identical YAML) and FR-025 (zero Jira writes at every tier). FR-007's supersession is a one-time convergence, then unchanged. |
| III | Fail-closed on writes, non-blocking on hooks | Can an impossible mapping reach a write? | **PASS** — contract §4 runs before any write and §6 gives each refusal exit `4`, zero writes, and the hook downgrade. §8 re-validates at reconcile time. |
| IV | Credential security | New credential surface? | **PASS** — none. The existing scan already covers the new key (research R3); asserted by test rather than assumed. |
| V | Team config / local binding / secrets | Is the boundary respected? | **PASS** — this is the principle the design is organised around. Names (a team decision) go in the committed layer; ids, levels and provenance (machine-owned) stay in the gitignored binding. |
| VI | macOS / Linux / Windows portability | Both ports, same commit, byte-identical? | **PASS with a named hazard** — FR-029 plus research R10. The `unresolved_roles` block is multi-line JSON and must go through the output module; the consumer's names are non-ASCII. Proven by the probe (quickstart step 11), not by reading. |
| VII | No hard-coded Jira assumptions | Any compiled-in type name or level assumption? | **PASS** — every candidate list comes from the project's metadata. Contract §4.1 explicitly refuses to infer sub-task-ness from a level or to require adjacency. The template's worked example is documentation, never a fallback. |
| VIII | Neutral engine / Jira sink | Does a Jira fact cross into the engine? | **PASS** — roles are neutral vocabulary; types, levels, flags and parent references stay in the sink. The neutral document is unchanged for US1–US4. |
| IX | Two-tier privacy guard | Any payload bypasses the guard? | **PASS** — unchanged for US1–US4 (no new payload). A task tier would route its payloads through the same pre-write scan. |
| X | Self-healing automatic mirror | Can a new refusal fail a host command? | **PASS** — contract §6's hook downgrade, and FR-004 means an installed mirror sees no behaviour change at all. |
| XI | Universal dry-run and auditability | Does the dry run predict everything? | **PASS** — FR-026 (resolved type per tier, every refusal) and contract §7.1 (per-role provenance audit). |
| XII | Quality and catalog publication | Release discipline? | **PASS** — CHANGELOG entry, version bump `0.8.0 → 0.9.0` (additive committed-format key, so minor), three-OS suite, live dogfood. |
| XIII | TDD with ≥80% coverage | Tests before code? | **PASS** — quickstart steps 1–2 are RED and named; step 3 is the standing regression guard. Resolution precedence and idempotency target near-100%. |
| XIV | KISS | Simplest thing that works? | **CONDITIONAL** — one dual-written pair of keys is carried (`child_type` / `parent_type` alongside `roles`). Justified and given a removal trigger in Complexity Tracking. |
| XV | YAGNI | Anything built before a spec requires it? | **PASS** — both keys were deferred by 008 with written triggers, and both have fired. The `task` role's validation ships without its tier, which contract §7.4 makes honest rather than silent. |
| XVI | Human readable | Would a reader understand the failure? | **PASS** — contract §6 gives every refusal the role, the type, the level, the candidates *and* the exact remedy. That last part is the specific failure of today's `parent-level-ambiguous` message. |

### Post-Phase-1 re-evaluation

Two things changed during design and neither breaks a gate:

1. **The closed question is not a prompt.** Research R7 found that FR-008 and
   FR-009 would read as contradictory if "ask" meant "prompt". They are one code
   path — refuse with the enumeration, let the agent ask, re-invoke with the
   answer — which is exactly how the project-key question already works. This
   *strengthens* III, VI and X: no interactive path means no way to hang a hook.
2. **The dual-write is new since Phase 0.** It is the only Constitution XIV
   tension in the design and is recorded in Complexity Tracking rather than
   waved through.

No gate moved from PASS to FAIL. No complexity is added that Phase 0 did not
already justify.

## Project Structure

### Documentation (this feature)

```text
specs/010-jira-hierarchy-mapping/
├── plan.md                      # This file
├── research.md                  # Phase 0 output — R1..R11
├── data-model.md                # Phase 1 output
├── quickstart.md                # Phase 1 output — 12 validation steps
├── contracts/
│   └── role-mapping.md          # Phase 1 output — the normative contract
├── checklists/
│   └── requirements.md          # From /speckit-specify
└── tasks.md                     # Phase 2 — NOT created by /speckit-plan
```

### Source Code (repository root)

Twin ports, file-for-file. Every bash file below has a PowerShell twin that
changes in the same commit.

```text
scripts/bash/                                scripts/powershell/
├── lib/
│   ├── config.sh          MODIFIED          ├── lib/Config.psm1           MODIFIED
│   │   • JIRA_ROLE_NAMES closed set         │
│   │   • hierarchy shape in team schema     │
│   │   • roles shape in local schema        │
│   └── cli.sh             MODIFIED          ├── lib/Cli.psm1              MODIFIED
│       • --issue-type KEY=role=name         │
│       • --child-type kept as alias         │
├── sink/jira/
│   └── hierarchy.sh       MODIFIED          ├── sink/jira/Hierarchy.psm1  MODIFIED
│       • role_candidates                    │
│       • role_resolve (declared/answered/   │
│         derived, one pass, all roles)      │
│       • role_validate (contract §4)        │
│       • the §6 refusal messages            │
├── commands/
│   ├── config.sh          MODIFIED          ├── commands/Config.psm1      MODIFIED
│   │   • call the resolver once per project │
│   │   • persist roles + dual-write         │
│   │   • §7 notes and per-role audit        │
│   └── reconcile.sh       MODIFIED          ├── commands/Reconcile.psm1   MODIFIED
│       • §8 re-validation only              │
└── engine/                UNCHANGED (US1–US4)
    └── parse.sh, interchange.sh, *_marker.sh — Stage F only

templates/config.yml.template  MODIFIED   # the documented worked example
commands/speckit.jira.config.md MODIFIED  # the agent's instruction to ask
docs/04-config-ceremony.md      MODIFIED  # step 8 replaced
docs/07-configuration-and-secrets.md MODIFIED
extension.yml                   MODIFIED  # 0.8.0 → 0.9.0
CHANGELOG.md                    MODIFIED
```

```text
tests/
├── bash/
│   ├── commands/test_config_role_mapping.bats      NEW
│   ├── sink/test_role_mapping.bats                 NEW  (one case per §6 refusal)
│   ├── commands/test_config_child_type.bats        MODIFIED (alias still works)
│   ├── commands/test_reconcile_hierarchy.bats      MODIFIED
│   ├── commands/test_config_determinism.bats       MODIFIED (roles round-trip)
│   ├── lib/test_config.bats                        MODIFIED (schema + credential scan)
│   ├── lib/test_config_binding_shape.bats          MODIFIED (dual-write equality)
│   └── lib/test_cli.bats                           MODIFIED (--issue-type)
├── powershell/                                     mirrored 1:1
└── conformance/
    ├── mock-jira/fixtures/
    │   └── createmeta-issuetypes-consumer.json     NEW  (2 / 13 / 2, real names)
    ├── mock-jira/configs/consumer-hierarchy.json   NEW
    ├── fixtures/repo-with-declared-hierarchy/      NEW
    └── scenarios/us1-role-*.json                   NEW  (6 scenarios)
```

**Structure Decision**: no new module. The resolver lives in
`sink/jira/hierarchy.sh`, which already owns level arithmetic and the refusal
prose, and the ceremony calls it once per project in place of today's two
separate calls (`hierarchy_derive` at `commands/config.sh:527` and
`_config_resolve_child_type` at `:533`). Adding a module would split logic that
is already one concern across two files in each of two ports.

## Implementation stages

Each stage is independently shippable and leaves the tree green. The numbering
here is **by layer**; `tasks.md` numbers its phases **by user story**, and
`tasks.md` is authoritative for ordering. The last column maps between the two
so neither document has to be read through the other's numbering.

| Stage | Delivers | Gate | `tasks.md` phase |
| --- | --- | --- | --- |
| **A · Red** | The two failing tests of quickstart steps 1–2, plus the consumer fixture and its conformance scenario | Both fail for the documented reason; the rest of the suite is green | Phase 1 |
| **B · Schema** | `hierarchy` in the committed schema, `roles` in the local schema, the role set as a single constant per port, `--issue-type` + the `--child-type` alias | Unknown role refused by name; credential scan asserted on the new key; step 3 still green | Phase 2 |
| **C · Resolver** | `role_candidates` / `role_resolve` / `role_validate` and every §6 message, both ports | Step 5 green: one test per refusal, each asserting zero writes and exact prose | Phase 3 (T017–T024), Phase 4 (T029–T035), Phase 6 (T044–T050) |
| **D · Ceremony** | One resolver call per project, `roles` persisted, dual-write, §7 notes and per-role audit | Steps 1, 2, 4, 6 green — the consumer instance configures | Phase 3 (T025–T028), Phase 4 (T036–T037), Phase 5 |
| **E · Reconcile + release** | §8 re-validation, docs, template, CHANGELOG, version bump, conformance scenarios, Windows probe, live dogfood | Steps 7–12 green; SC-001 through SC-007 demonstrated | Phase 6 (T052–T053a), Phase 7 |
| **F · Task tier (US5, deferred)** | `tasks.md` parsing, a third durable-identifier tier, sub-task creation, recognition and drift | Step 9's last assertion inverted; not required for the unblock | Phase 8 (T066–T071) |

Stages A–E are the deliverable. Stage F has its own gate and may ship in a later
release without invalidating anything above it.

## Scope boundaries worth stating

- **Reconcile does not re-read the project's metadata.** Contract §8 re-validates
  the binding's internal consistency; the ceremony is what detects a mapping gone
  stale against Jira. Making reconcile re-discover would put a Jira read on the
  hook path for a check the ceremony already owns.
- **`config.yml` is never rewritten by the ceremony.** Unchanged from today. FR-011
  *reports* the declaration to commit; the human commits it.
- **No migration of existing mirrors.** A changed mapping applies to issues
  created after it. Existing tickets are recognised by their recorded ids and
  are not re-typed, re-parented, or reported as drift on the basis of type.
- **No per-specification type routing.** One mapping per project entry. Choosing
  `Service Category` for some specifications and `Epic` for others is a routing
  feature nobody has asked for.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Two keys carry the same value: `roles.story` / `child_type` and `roles.specification` / `parent_type` are dual-written (contract §5.1) | Keeps `_reconcile_plan_context`, `hierarchy_mandatory_gate`, the stale-binding codes (`return 6` / `return 7`) and both ports' write-path tests untouched, so FR-004's "no mapping ⇒ nothing changes" is enforceable rather than intended. Also keeps a binding written by this release readable by a colleague's not-yet-upgraded checkout. | Migrating reconcile to read `roles.story.id` and dropping the legacy keys makes **every existing local binding stale on upgrade** — turning a configuration-layer feature into a forced re-run for every installation, and dragging the mandatory gate, the plan context and both ports' reconcile suites into a change whose purpose is to let an operator answer a question. **Removal trigger**: the release after the task tier ships, when the plan context has to grow a third tier anyway and the migration is no longer gratuitous. |
| The `task` role is validated and persisted in stage C but mirrors nothing until stage F | A role that silently does nothing is worse than no role: a team commits `hierarchy.task`, sees no error, and concludes sub-tasks are being created. Contract §7.4 makes the gap explicit in the run summary. | Refusing the `task` key until the tier exists would mean a second edit to every consumer's committed file at rollout — the exact cost 008 recorded when it deferred the child-type switch. Shipping the tier now would delay the unblock by an engine feature the size of 008. |
