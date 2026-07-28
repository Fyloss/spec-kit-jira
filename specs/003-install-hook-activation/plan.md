# Implementation Plan: Hooks Active From Installation

**Branch**: `003-install-hook-activation` | **Date**: 2026-07-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-install-hook-activation/spec.md`

## Summary

The official install registers no lifecycle hook, because `extension.yml` has no
`hooks:` block at all. The configuration ceremony registers them instead, with
`optional: true` — which the host reads as "offer this to the operator", not
"perform it" — pointing at `speckit.jira.reconcile`, a command that does not
exist, through command procedures that invoke a bare `spec-kit-jira` executable
the install never provides. Four independent breaks, each sufficient on its own
to make the extension inert. That is what the consuming project reported.

The plan closes all four along one seam: **the manifest becomes the single
declaration of hooks, the host install becomes the single writer of the
registry, and this extension becomes a reader of it.** Concretely — declare the
seven events at the manifest root with `optional: false`; add the missing
reconcile command and declare it; rewrite the two existing command procedures to
invoke the bridge by repository-relative path, per port; and **delete the
registrar's writer**, leaving the ceremony to read, classify and report.

That last point is the largest change from the first draft of this plan, and it
came from a direct question about the consuming project's file: does the
ceremony overwrite `.specify/extensions.yml`? Today it does — the current
`register_hooks_write` re-serialises and `mv`s the whole file. The earlier
design narrowed that to "write only when an entry is genuinely missing", which
is better but keeps two writers on one shared file and still destroys the
operator's comments on every write it does perform, because this extension's
YAML reader drops comments and models only a restricted subset of the language
(research.md R3). With registration owned by the manifest, the writer has no
remaining job. It is removed rather than guarded — less code, and a guarantee
that holds unconditionally instead of one with exempted states (FR-022, FR-023,
SC-007, SC-011, SC-012).

One upstream behaviour still forces extra work: `specify extension add`
re-enables hooks unconditionally, so an operator's `enabled: false` does not
survive a reinstall. Constitution X does not allow that, so the operator's
decision is recorded in the gitignored local binding and honoured at dispatch.
It is **not** re-applied to the registry — that would be a write — so the
ceremony reports the divergence instead. See [research.md](./research.md) R5.

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port) and PowerShell 7+ (Windows
port). No compiled artifact, no build step, no download step.

**Primary Dependencies**: runtime — `jq`, `curl`, `git` on the Bash port;
none beyond PowerShell 7 on the Windows port. Development only — `bats`,
`Pester`, `kcov`, `shellcheck`, `PSScriptAnalyzer`. This feature adds no
dependency of either kind.

**Storage**: files in the consuming repository. `.specify/extensions.yml` (the
shared hook registry, owned by the host and edited by several extensions),
`.specify/jira/config.yml` (committable team config) and
`.specify/jira/config.local.yml` (gitignored local binding). The extension's own
tree at `.specify/extensions/jira/` is install-owned and holds no configuration.

**Testing**: `bats` for the Bash port, `Pester` for the PowerShell port, the
shared conformance suite for cross-port equivalence, and the live integration
suite for behaviour against a real Jira. Hook behaviour is fully coverable by
the mocked suites; no live credentials are needed for anything in this feature.

**Target Platform**: macOS, Linux and Windows, verified on the three-OS GitHub
Actions matrix.

**Project Type**: Spec Kit extension — twin native script ports behind one
manifest, installed by `specify extension add` into a consuming repository.

**Performance Goals**: a hook fired in a repository that is not configured must
short-circuit before any network call; the operator perceives no delay on
lifecycle commands. No throughput target applies.

**Constraints**: install side effects confined to the consuming repository — no
machine-wide executable, no `PATH` change, no shell profile edit (FR-008). The
consuming repository's hook registry is **read-only to this extension** in every
state and from every command, comments included (FR-022, FR-023, SC-011,
SC-012). Files that cross platforms are byte-identical between ports
(Constitution VI).

**Scale/Scope**: seven lifecycle events, three agent-invocable commands, one
shared registry file co-owned with other extensions.

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1.*

| # | Principle | Compliance |
| --- | --- | --- |
| I | Filesystem is source of truth | Unaffected — this feature changes when the bridge runs, never what it mirrors or which tickets it may touch. |
| II | Zero-churn idempotency | Directly reinforced, and taken further than "zero churn": the registrar's writer is deleted, so the extension performs zero registry writes in every state, not merely on an unchanged one (R3). FR-022/FR-023/SC-007/SC-011 are the gate. No new Jira write kind is introduced, so the live idempotency assertion list is unchanged. |
| III | Fail-closed on writes, non-blocking on hooks | Preserved exactly. `optional: false` changes dispatch only, never propagation (R4); the existing hook-resilience suites keep asserting the host command's exit code is unaffected. |
| IV | Zero tokens in the tree | Unaffected — no credential path is touched. Hook entries and manifest carry no credential-shaped value. |
| V | Team config / local binding / secrets separated | Respected and relied upon: the operator's disable record goes in the gitignored local binding precisely because it must survive a reinstall of the extension folder. |
| VI | macOS / Linux / Windows portability | Every change lands on both ports. The registry content written by either port is identical; the conformance suite gains hook-registration and port-selection scenarios. |
| VII | No hard-coded Jira workflow assumptions | Unaffected — no issue type, status or field id is involved. |
| VIII | Neutral engine / Jira sink | Respected. All work is in the hooks and commands layers, which already own the hook vocabulary; no engine file is touched, so neither CI grep can regress. |
| IX | Two-tier privacy guard | Unaffected. |
| X | Self-healing automatic mirror | Registration becomes idempotent and reinstall-resilient by moving to the manifest; health is reported on every run and extended to all seven events. Two tracked deviations, both below: the disabled-forever guarantee is honoured at dispatch rather than in the registry, and the leftover-entry case has no one-command repair because repairing it would mean writing a file FR-022 puts out of reach. |
| XI | Universal dry-run and auditability | Preserved and simplified. The only registry write there was is gone, so nothing about the registry needs predicting; hook health stays in the structured run summary, and the disable record — the extension's own file — keeps its dry-run prediction. Computing health writes nothing at all. |
| XII | Quality and catalog publication | CHANGELOG entry, version bump and three-OS green are release gates as usual. The install path documented in `INSTALL.md` is corrected by FR-027. |
| XIII | TDD, 80% coverage | Every change below is stated as a failing test first. The reported defect gets its regression test before the fix, per the project's bug-fix rule. |
| XIV | KISS | The design removes code rather than adding layers: the registrar loses its writer entirely, and the manifest replaces imperative registration. One added affordance is justified below. |
| XV | YAGNI | Exactly the seven events the spec names — no `before_*` or checklist events, though the host offers them (R9). The one new config key and one new flag both trace to FR-007/FR-029. Out of Scope forbids re-adding a registry writer behind a future flag. |
| XVI | Human readable | Hook entries carry real descriptions; the ceremony reports `healthy`/`incomplete`/`held disabled`/`duplicated`/`unreadable` in prose, each naming what the operator should run or edit; every message literal is runnable as written (FR-018), verified mechanically. The operator's own comments in the registry survive every run (SC-012), which is what makes a hand-maintained shared file readable at all. |

**Gate result (pre-Phase 0)**: PASS with one tracked deviation (Principle X /
Principle XV — see Complexity Tracking).

**Gate result (post-Phase 1)**: PASS with two tracked deviations, both against
Principle X and both recorded below. The Phase 1 design added no abstraction,
no dependency, and no configuration surface beyond the single recorded key
already justified below — and removed one component, the registrar's writer.

## Project Structure

### Documentation (this feature)

```text
specs/003-install-hook-activation/
├── plan.md              # This file
├── research.md          # Phase 0 — upstream contract, verified against specify_cli 0.13.4
├── data-model.md        # Phase 1 — hook entry, health, disable record
├── quickstart.md        # Phase 1 — how to validate the feature end to end
├── contracts/
│   ├── extension-manifest-hooks.md   # what extension.yml must declare
│   ├── hook-registry-entry.md        # the canonical entry, field by field
│   └── reconcile-command.md          # the new agent-invocable command
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 — created by /speckit-tasks, not here
```

### Source Code (repository root)

```text
extension.yml                          # + top-level hooks: block; + reconcile command

commands/
├── speckit.jira.config.md             # invocation by repo-relative path; hook effect reworded
├── speckit.jira.feature.md            # invocation by repo-relative path; now non-optional
└── speckit.jira.reconcile.md          # NEW — the command every after_* hook names

scripts/bash/
├── hooks/register_hooks.sh            # READER ONLY — writer deleted; health incl. duplicated/unreadable
├── commands/config.sh                 # reports healthy/incomplete/held-disabled/duplicated/unreadable
├── commands/reconcile.sh              # inert exit for a recorded-disabled event; --repair-hooks removed
└── lib/config.sh                      # local-binding read/write for the disable record

scripts/powershell/
├── hooks/RegisterHooks.psm1           # twin of register_hooks.sh
├── commands/Config.psm1               # twin of config.sh
├── commands/Reconcile.psm1            # twin of reconcile.sh
└── lib/Config.psm1                    # twin of lib/config.sh

tests/
├── bash/hooks/test_register_hooks.bats        # rewritten around the canonical shape
├── bash/hooks/test_hook_resilience.bats       # non-blocking still holds under optional:false
├── bash/commands/test_hook_health.bats        # all seven events, held-disabled reporting
├── powershell/hooks/RegisterHooks.Tests.ps1   # twin
├── powershell/hooks/HookResilience.Tests.ps1  # twin
├── conformance/scenarios/                     # + manifest-install and port-selection scenarios
└── ci/                                        # + manifest↔registry and message↔command checks

INSTALL.md                             # corrected sequence (FR-026, FR-027)
README.md / templates/readme-block.template   # managed block reflects the new sequence
CHANGELOG.md                           # release entry
```

**Structure Decision**: the existing twin-port layout is kept unchanged — there
is no new module, no new directory, and no new abstraction. Work concentrates in
four places: the manifest (`extension.yml`), the commands layer
(`commands/*.md`), the hooks layer (`scripts/*/hooks/`), and the documentation
that describes the install sequence. The engine and sink directories are not
touched at all, which is what keeps Principle VIII's two CI greps green by
construction.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --- | --- | --- |
| A recorded set of operator-disabled events in the local binding, plus a flag on the configuration command to clear it | `specify extension add` writes `enabled: true` unconditionally on every install and upgrade (research.md R5), so the registry alone cannot carry the operator's decision. FR-007, SC-005 and Constitution X all require that decision to survive. The record lives in the gitignored local binding, which Principle V already guarantees survives a reinstall. | *Inheriting the install's behaviour and documenting the limitation* — rejected: Constitution X is non-negotiable and Governance states the principle wins over an inherited behaviour. *Restoring the state at ceremony time only* — rejected: it leaves a window between the install and the next ceremony in which the bridge mirrors to Jira against an explicit instruction not to. *Inferring an operator's re-enable from the registry* — rejected: the extension cannot distinguish an operator's edit from the install's rewrite, and guessing here would silently discard a deliberate choice; one explicit flag, named in the ceremony's report, is the honest mechanism. |
| **Deviation from Principle X**: the leftover-entry case (FR-028) is repaired by a manual operator edit, not by a one-command repair. Principle X requires the extension to "offer a one-command repair" for hook health. | FR-022 makes the registry read-only to this extension, so it cannot remove the leftover entry itself. The host cannot either: its purge matches on the `extension` field these entries do not have (research.md R2). No one command exists that can perform this repair, so none can honestly be offered. The report instead names the exact events and the exact edit. The ordinary repair — a genuinely missing entry — *does* keep a one-command remedy, `specify extension add --force`, so the principle holds everywhere it can be satisfied. | *Keeping a narrow writer just for leftover entries* — rejected: it reintroduces a second writer on a shared file for one migration case, and every such write still destroys the operator's comments (research.md R3). The whole point of FR-022 is that no state is exempt; an exemption for the rarest state would be the one nobody tests. *Silently ignoring leftover entries* — rejected: they cause a duplicate hook per event, so the operator must be told, precisely, in the run they can act on. *Shipping a separate migration script* — rejected as a new surface (Principle XV) for a case a three-line instruction resolves. |

No other deviation. The feature otherwise removes behaviour — the registrar's
writer in full — rather than adding it.
