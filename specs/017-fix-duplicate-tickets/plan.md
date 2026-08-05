# Implementation Plan: The Mirror Only Ever Mirrors a Specification, and Every Ticket Carries the Specification It Came From

**Branch**: `017-fix-duplicate-tickets` | **Date**: 2026-08-04 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/017-fix-duplicate-tickets/spec.md`

## Summary

Three changes, in descending order of value and ascending order of cost.

**The target guard** is one comparison on the target's file name, placed in `cmd_reconcile`
immediately after the positional argument is resolved and before the not-configured notice — the
first point at which the path is known and the last point before any configuration read. A target
whose file name is not `spec.md` refuses with `EXIT_USAGE`, names the sibling `spec.md` when one
exists, and returns through the existing `_reconcile_fault` path that already downgrades a hook run
to success. Exit `1` is the one code the reconcile command document's message-discipline table does
not yet claim, which is why the new cause row can carry it — but `cmd_reconcile` already returns `1`
for a missing or unreadable argument, so the refusal is distinguished by its verbatim message, not by
the code. Roughly fifteen lines per port.

**The provenance label** needs no new engine field and no schema change: the neutral interchange
document already carries `spec_ref.spec_slug`, already validated as `^[0-9]{3}-[a-z0-9-]+$` — which
is exactly the reference the operator asked for (`001-test-page`). The sink renders it as
`speckit-<slug>` in three places: `jira_create_fields_base` (both creation roles funnel through it),
the story-update branch of `plan_writes`, the recognised-parent branch of `_plan_writes_parent`,
and — since feature 012 landed a third managed tier — the create and update branches of
`plan_writes_tasks`. The task type's own degradation decision is resolved inside `plan_writes`
beside the story's and the parent's, and the resolved token is handed to `plan_writes_tasks` as an
optional third argument, because that function returns a bare action array and has no warnings
channel of its own.
Back-fill and zero churn come for free from the existing `idempotency_field_status` comparison, on
one condition — the desired label list is the **union** of the ticket's current labels and the
provenance label, and both sides are normalised with `unique` so the comparison, which is
order-sensitive, settles. Recognition must start reading the `labels` field back, which is a
two-character change to each of its two field lists plus one map threaded through the plan context.

**The duplicate probe** (User Story 4, P3) is the only part that adds a Jira capability: a read-only
JQL search for `project = <KEY> AND labels = "speckit-<slug>"`, fired only in the window where the
run is about to create a parent it has no marker for. It is also the part that cannot deliver what
its name suggests, and the plan says so plainly: feature 005 removed search from recognition because
Jira's index is eventually consistent, and that limitation applies here unchanged. The probe
converts *some* duplications into a refusal; the marker line remains the mechanism that prevents
them. It is the slice to drop if the feature needs to shrink.

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port) and PowerShell 7+ (Windows port), per INSTALL.md's
stated minimums. No new interpreter requirement.

**Primary Dependencies**: `curl` + `jq` (bash port), native `Invoke-RestMethod` + port serializer
(PowerShell port). **No new dependency** — the duplicate probe uses the existing `jira_request`
transport, and the target guard uses no dependency at all.

**Storage**: None added. No key is written to `config.yml`, to the local binding, or to
`personal.yml`. The provenance value is derived at run time from the specification's own folder.

**Testing**: `bats` (bash), Pester (PowerShell), the shared conformance corpus under
`tests/conformance/scenarios/`, plus `shellcheck` and `actionlint`. New scenarios are added to the
corpus for every observable behaviour introduced here.

**Target Platform**: macOS, Linux, Windows — the existing three-OS matrix.

**Project Type**: CLI extension for the Spec Kit host, twin native ports.

**Performance Goals**: The target guard adds one string comparison. The label adds no request. The
duplicate probe adds **at most one** GET per run, and only on a run that is about to create a parent
— never on the settled, zero-churn re-run that is the common case.

**Constraints**: Byte-identical observable output across both ports (Constitution VI). Zero churn on
a settled mirror (Constitution II). Every message readable, naming the file, the key, and the remedy
(Constitution XVI).

**Scale/Scope**: Two command layers, three sink modules, one engine module, two agent-facing command
documents, and their tests. No module is created; no module is deleted.

## Constitution Check

*GATE: passed before Phase 0, re-checked after Phase 1 design. No violation, no Complexity Tracking
entry.*

| # | Principle | Gate result after design |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | **Pass.** The design adds no third exception. The duplicate probe issues one GET and, on a hit, refuses — `contracts/duplicate-probe.md` forbids every write on that path, including a label write, so a ticket the bridge does not already manage is never touched. |
| II | Zero-Churn Idempotency | **Pass, by construction.** The label enters the *desired* field set on both update branches, so the existing `idempotency_field_status` drop decides it. Design decision R4 (normalise both sides with `unique`) is what makes that true rather than aspirational — without it, jq's order-sensitive array equality would re-send the label forever. Conformance scenario `us2-label-second-run` asserts the second run's summary is byte-identical. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | **Pass.** The target guard is the earliest fail-closed point in the command: it precedes the base-URL read, the config load, credential resolution, and every splice. It returns through `_reconcile_fault`, which is the path that already keeps the host command green. The probe's fail-open (R7) is bounded to a *supplementary* read and is argued in research; it never permits a write the marker mechanism would have stopped. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | **Pass, unaffected.** The guard runs before credentials are resolved at all. The probe reuses `jira_request`, whose off-argv `--config` credential handling is unchanged. No new value is logged. |
| V | Separation of Team Config / Local Binding / Secrets | **Pass, unaffected.** No file in the three-tier split gains a key. The `speckit-` prefix is a sink literal, not configuration (R5). |
| VI | macOS / Linux / Windows Portability | **Pass.** Every change is mirrored port-for-port at the sites named in the Structure section, and `tasks.md` will pair each bash task with its PowerShell twin. R3 covers the one portability hazard the guard introduces: the file-name comparison must be a basename comparison, not a suffix or glob test, and must not be defeated by a Windows path separator. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | **Pass.** No status, transition, screen, or field id is assumed. `labels` is the one field name introduced, and R6 makes its absence a warning rather than a refusal. The probe assumes no JQL capability: any non-2xx is the fail-open path. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | **Pass, and cheaply.** The engine already emits `spec_ref.spec_slug`; the word "label" and the `speckit-` prefix exist only under `sink/jira/`. The one new engine function — the stray-marker scan — is pure filesystem and marker grammar, with zero tracker vocabulary, and lives beside the marker grammar it reuses. |
| IX | Two-Tier Privacy Guard, With an Allowlist | **Pass, automatically.** The privacy guard scans each action's whole `body`; the label is inside `body.fields`, so it is scanned with no change to the guard. R8 records the check that proves it. |
| X | Self-Healing Automatic Mirror | **Pass.** A missing or hand-deleted label is restored by the next ordinary run with no manual step, through the same comparison that decides every other field. The stray-marker warning turns previously silent damage into something an operator can act on. |
| XI | Universal Dry-Run and Auditability | **Pass.** The label is part of the planned action body, so `--dry-run` reports it verbatim; the refusal is computed before the dry-run branch, so a preview refuses exactly as a real run does. The probe runs in the planning pass, so a dry run predicts its refusal too. |
| XII | Quality and Catalog Publication | **Pass.** CHANGELOG entry, full suite, conformance corpus, and linters on the three-OS matrix, as usual. |
| XIII | TDD With a Minimum 80% Coverage | **Pass.** The reproduction — invoke the bridge with `plan.md` against a mock that fails the test on any request — is written first and fails without the guard. Every test observes only state it created; the mock's port and the fixture's temp directory come from the harness, never from a name-pattern scan. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | **Pass.** One comparison for the guard; one derived token for the label, in three existing payload builders; no new module for either. The rejected alternatives are recorded in research (R2 auto-redirect, R5 configurable prefix, R9 a marker-ledger file). |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | **Pass.** Nothing is built that no FR names. The probe is built because FR-022–FR-026 name it, and is marked droppable. Label-based adoption stays out. |
| XVI | Human Readable — Readable by a Human Above All | **Pass.** Every message is fixed verbatim in `contracts/`, names the file or key and the remedy, and is compared byte-for-byte by the conformance corpus rather than paraphrased per port. |

## Project Structure

### Documentation (this feature)

```text
specs/017-fix-duplicate-tickets/
├── plan.md              # This file
├── research.md          # Phase 0 — the nine decisions this design rests on
├── data-model.md        # Phase 1 — the values and shapes that change
├── quickstart.md        # Phase 1 — how to prove the feature works
├── contracts/
│   ├── target-guard.md      # the refusal: inputs, outcomes, verbatim messages
│   ├── provenance-label.md  # derivation, merge, back-fill, degradation
│   └── duplicate-probe.md   # the read-only pre-create probe
├── checklists/
│   └── requirements.md  # written by /speckit-specify
└── tasks.md             # /speckit-tasks output — NOT created here
```

### Source Code (repository root)

Every file below already exists; this feature creates none and deletes none, apart from the two
duplicate-probe modules.

```text
scripts/bash/
├── commands/reconcile.sh          # target guard (~L401-413); stray-marker warning;
│                                  #   ticket_labels + parent labels into the plan context (~L332-361);
│                                  #   probe call in the planning pass
├── engine/marker_splice.sh        # NEW FUNCTION: stray-marker scan (pure filesystem + grammar)
└── sink/jira/
    ├── ticket.sh                  # jira_create_fields_base (L64) — the one creation choke point
    ├── plan_apply.sh              # plan_writes story-update branch (L261);
    │                              #   plan_writes_tasks create + update branches (012's task tier);
    │                              #   _plan_writes_parent recognised branch (L334)
    ├── recognition.sh             # +labels on both field lists (L36, L71); labels into `current`
    └── duplicate_probe.sh         # NEW FILE (US4 only): the read-only label search

scripts/powershell/
├── commands/Reconcile.psm1        # twin of the above (positional loop at L507-512)
├── engine/MarkerSplice.psm1       # twin of the stray-marker scan
└── sink/jira/
    ├── Ticket.psm1                # Get-JiraCreateFieldsBase (L56)
    ├── PlanApply.psm1             # twin update branches, task tier included
    ├── Recognition.psm1           # +labels on both field lists (L39, L84)
    └── DuplicateProbe.psm1        # NEW FILE (US4 only)

commands/speckit.jira.reconcile.md # FR-019–FR-021: the single-target rule, the never-a-target list,
                                   #   the new cause row, the positional's documented restriction
docs/05-reconcile-flow.md          # the pipeline diagram gains a target-guard step
docs/03-lifecycle-hooks.md         # the invocation diagram's argument is the active feature's spec.md
docs/08-safety-model.md            # exit-code node E1 now covers the rejected target as well as usage
docs/02-module-architecture.md     # SinkLayer gains duplicate_probe (US4 only — drops with the slice)

tests/bash/commands/               # test_reconcile_target.bats (NEW), test_agent_doc_reconcile.bats
tests/bash/sink/                   # test_plan_apply_labels.bats (NEW), test_recognition.bats
tests/bash/engine/                 # test_marker_stray.bats (NEW)
tests/powershell/                  # the Pester twin of each of the above
tests/conformance/scenarios/       # us1-/us2-/us4-*.json (NEW) + a fixture whose feature folder
                                   #   holds plan.md
```

**Structure Decision**: The existing two-port layout is unchanged. Work lands at the sites named
above — one command layer per port, three sink modules per port, one engine module per port. The
only new files are the duplicate probe (one per port), deliberately isolated so that dropping User
Story 4 is a file deletion plus three call-site lines, not an unpicking.

## A blocking prerequisite the guard creates

The existing test corpus does not obey the rule the guard enforces. Several reconcile tests build
their specification at `${BATS_TEST_TMPDIR}/with.md`, `spec2.md`, `nosummary.md`, `priority.md`,
`a.md`, `b.md`, `reordered.md`, `before.md` — every one of which the guard refuses. Five bash files
and their PowerShell twins are affected:

```text
tests/bash/commands/test_reconcile.bats            tests/powershell/commands/Reconcile.Tests.ps1
tests/bash/commands/test_reconcile_durability.bats            …/Reconcile.Durability.Tests.ps1
tests/bash/commands/test_reconcile_idempotent.bats            …/Reconcile.Idempotent.Tests.ps1
tests/bash/commands/test_reconcile_plan_context.bats          …/Reconcile.PlanContext.Tests.ps1
tests/bash/commands/test_reconcile_zero_churn.bats            …/Reconcile.ZeroChurn.Tests.ps1
```

The migration is mechanical — each specification moves into its own temp subdirectory and is named
`spec.md` — and it is a **no-op before the guard exists**, which is why it lands in the foundational
phase rather than inside User Story 1. Doing it first keeps the suite green at every commit and
keeps the guard's own red-then-green cycle attributable to the guard.

## Phase ordering

The four slices are independent and land in priority order. Each is shippable alone:

1. **US1 — target guard.** Closes the reported defect. Depends on nothing below.
2. **US2 — provenance label.** Independent of US1; touches a disjoint set of functions.
3. **US3 — command document.** Depends on US1 only for the wording of its new cause row.
4. **US4 — duplicate probe.** Depends on US2 having labelled the estate. Droppable.

## Complexity Tracking

No Constitution violation was found at either gate, so this section is empty by design.

The one place where the design does not do exactly what a requirement's literal wording asks is
recorded in research decision **R1** (the target guard runs *after* the operator's dispatch guard,
so an event the operator disabled stays silent instead of reporting a rejected target). It is a
conflict between two requirements, resolved in favour of the older, explicitly-argued one, and it is
flagged to the operator rather than buried here.
