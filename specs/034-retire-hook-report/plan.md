# Implementation Plan: Retire the hook registry report

**Branch**: `034-retire-hook-report` | **Date**: 2026-08-30 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/034-retire-hook-report/spec.md`

## Summary

Delete the extension's reader of `.specify/extensions.yml`, and everything that
existed only to serve it: one module per port, one ceremony effect, one reconcile
summary object, five effect-status values, one CLI flag, one local-binding key,
one environment override, and reconcile's silent dispatch hold for a hand-disabled
event. Nothing is built. The manifest keeps declaring all seven lifecycle events,
the hooks keep firing, and a bridge failure in hook context keeps surfacing exactly
one warning without failing the host command.

The approach is a **guard-first deletion**. The widened absence guard (FR-010) is
written and proven red against the pre-change port *before* a line is deleted;
after that, the deletion is mechanical and the guard is what proves it complete.
The one place judgement is required is the manifest ⟷ port event-set check, which
is re-pointed rather than retired because its declaration site survives and a
different feature depends on it (research R1).

## Technical Context

**Language/Version**: Bash 3.2+ (macOS system bash) and PowerShell 7+ — two native
ports, no shared runtime.

**Primary Dependencies**: `jq` (bash port, always through `lib/output.sh` — never
called directly, its Windows build emits CRLF on multi-line output); no new
dependency is introduced, and one is dropped in effect — the restricted YAML reader
loses its registry caller.

**Storage**: files only. `.specify/jira/config.yml` (team, committed),
`.specify/jira/config.local.yml` (per-operator, gitignored — loses one key),
`.specify/jira/personal.yml`. `.specify/extensions.yml` stops being read.

**Testing**: `bats` (`tests/run-bash.sh`, ~190 s locally; `-r` is load-bearing when
invoking `bats` directly), Pester 7 (`tests/powershell`), and the cross-port byte
conformance corpus (`tests/conformance/ci-conformance.sh`, 254 scenarios).
`shellcheck -x -P scripts/bash` and `actionlint` gate the build.

**Target Platform**: macOS, Linux, Windows (PowerShell 7+ / MSYS bash). The
tightest command-line cap across hosts binds: Windows ≈32 767 bytes.

**Project Type**: CLI extension for spec-kit — two native ports proven equivalent
by a shared conformance corpus.

**Performance Goals**: no regression. The change is strictly subtractive on the
reconcile path: it removes one YAML parse of the registry and one local-binding
read per run. No loop on the reconcile path gains a per-item process spawn — none
is added at all.

**Constraints**: no new external process on the reconcile path; no `$'\r\n'` inside
a glob pattern; byte-identical output from both ports for every scenario (FR-012);
`specs/**` and `CHANGELOG.md` are historical record and are not rewritten.

**Scale/Scope**: ~2 modules deleted, ~6 library functions removed per port, 4
contract files amended, ~10 documentation files swept, ~12 test files deleted and
~6 re-pointed, 1 conformance scenario retired and 1 re-pointed. Net line count is
strongly negative.

## Constitution Check

*GATE: passed before Phase 0; re-evaluated after Phase 1 — see below.*

Assessed against constitution **4.0.0**. This feature is not permitted by an
exception to Principle X; it is **required by its current text**. The spec's own
Constitution Check table is the authority and is not restated here. The three
gates that could have failed a design, and did not:

| Gate | Verdict | Evidence from Phase 1 |
| --- | --- | --- |
| **X — no registry read or write, in any state** | PASS | FR-001 is implemented as total absence of the path tokens from `scripts/`, not as a narrowed reader. Enforced by the widened guard, proven red first (quickstart §0). |
| **XIII — TDD, no vacuous green** | PASS | Every retired test is deleted with its behaviour or re-pointed (data-model §10, quickstart §8). The guard-red step is scheduled ahead of the deletion, not after it. |
| **XV — YAGNI** | PASS | Nothing is built. FR-005's refusal is obtained by deleting one token from an accepted-key list; the located message and the exit code already exist (research R4). The retired-key rule first drafted for it stays withdrawn. |

**Post-Phase-1 re-evaluation**: no new violation. Phase 1 surfaced one item the
specification does not name in an FR — reconcile's silent dispatch hold (research
R3) — and it is authorised by the same constitutional amendment in as many words,
so it does not enter Complexity Tracking. It does enter the plan's scope, and
FR-011's documentation obligation covers it.

**One adjacent repair, taken deliberately rather than deferred**:
`run-summary.schema.json` was **seven items behind both ports** — the
`effects.personal` object (030), `effects.field_defaults` and
`effects.task_mirror` (011), the `would_create` and `inert` statuses, and the
top-level `provisional` and `rerun_guidance` (030). Under
`additionalProperties: false` that made **every** ceremony summary invalid against
its own published contract, on every run, for several features.

The drift predates this feature and is outside its stated scope. It was repaired
anyway, on one ground: 034 rewrites that exact object and that exact enum, and
removing a sibling property with great care while leaving seven known-false
neighbours untouched would not survive review. The repair is additive — it
declares what already ships — and changes no behaviour.

**Why it survived**: the schema was named in four source comments and **zero
assertions**. Three new suites close that class, and each was proven red before
being accepted:

| File | Covers |
| --- | --- |
| `tests/bash/helpers/summary_schema.bash` | the shared reading of the contract — one jq program, so the two suites cannot disagree about it |
| `tests/bash/ci/test_summary_schema_helper.bats` | the helper itself, against summaries with a known violation of each detected class |
| `tests/bash/commands/test_run_summary_schema.bats` | the config ceremony — main, `--dry-run`, and the separately-assembled degraded path |
| `tests/bash/commands/test_reconcile_summary_schema.bats` | reconcile — planning, confirmed-creation, and fail-closed |

The guard is targeted rather than a full JSON Schema validator — undeclared
top-level key, undeclared effect, out-of-enum status — so it needs `jq` only and
adds no dependency (Principle XIV).

**It also guards this feature directly.** The reconcile suite was verified to fail
on a schema with `hook_health` deleted while the code still emits it — which is
precisely the half-applied state T023/T024 and T026 could leave behind. The
detection runs in the direction that matters here: emitted-but-undeclared. A field
declared but no longer emitted is *not* flagged, so T026 still has to be done by
hand — the guard cannot tell you the contract is now too generous.

**One deviation from the specification's own wording, stated rather than
absorbed**: Constitution XII, as quoted in the spec, calls for a "major version
bump". This is a `0.x` line, where the minor position carries breaking changes, and
the three preceding breaking features on `main` (#57, #58, #59) each took a minor
bump. The plan follows that convention: `0.24.0`, marked BREAKING (research R8). If
the intent was literally `1.0.0`, that is a one-line change to a task.

## Project Structure

### Documentation (this feature)

```text
specs/034-retire-hook-report/
├── plan.md                              # This file
├── research.md                          # Phase 0 — R1..R10
├── data-model.md                        # Phase 1 — what falls, what narrows
├── quickstart.md                        # Phase 1 — runnable validation
├── contracts/
│   ├── summary-fields-removed.md        # amends run-summary.schema.json
│   └── retired-cli-and-config.md        # amends config-cli-contract.md + config.local.schema.json
├── checklists/                          # pre-existing
├── spec.md
└── tasks.md                             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/
├── bash/
│   ├── hooks/
│   │   ├── register_hooks.sh            # DELETED
│   │   └── readme_block.sh              # untouched
│   ├── commands/
│   │   ├── config.sh                    # hooks effect + --enable-hook removed
│   │   └── reconcile.sh                 # hook_health + dispatch hold removed
│   └── lib/
│       ├── config.sh                    # hooks.disabled key + 3 fns removed; event-set comment rewritten
│       └── cli.sh                       # --enable-hook removed from the option table
└── powershell/
    ├── hooks/
    │   ├── RegisterHooks.psm1           # DELETED (trace Get-CfgUnsupportedConstruct first)
    │   └── ReadmeBlock.psm1             # untouched
    ├── commands/
    │   ├── Config.psm1                  # mirror of config.sh
    │   └── Reconcile.psm1               # mirror of reconcile.sh
    └── lib/
        ├── Config.psm1                  # mirror of lib/config.sh
        └── Cli.psm1                     # mirror of lib/cli.sh

extension.yml                            # version 0.23.0 → 0.24.0; hooks: block UNTOUCHED
CHANGELOG.md                             # BREAKING entry
templates/readme-block.template          # managed-block text rewritten
commands/speckit.jira-mirror.config.md   # hooks section, status table, flag, description
commands/speckit.jira-mirror.reconcile.md
INSTALL.md, README.md, docs/01..05, docs/README.md

specs/001-jira-reconcile-engine/contracts/run-summary.schema.json      # amended
specs/001-jira-reconcile-engine/contracts/config.local.schema.json     # amended
specs/002-config-discovery-team-prefix/contracts/config-cli-contract.md
specs/003-install-hook-activation/contracts/hook-registry-entry.md     # marked superseded

tests/
├── bash/ci/test_no_registry_write.bats          # WIDENED (proven red first)
├── bash/ci/test_manifest_hooks.bats             # RE-POINTED at lib/config.sh
├── bash/hooks/test_register_hooks.bats          # DELETED
├── bash/commands/test_hook_health.bats          # DELETED
├── bash/commands/test_config_reenable.bats      # DELETED
├── bash/commands/test_config_three_effects.bats # RE-POINTED: its "three" is
│                                                # discovery/hooks/readme (gitignore
│                                                # arrived later); membership becomes
│                                                # discovery/readme/gitignore
├── bash/hooks/test_hook_resilience.bats         # UNMODIFIED — must stay green
└── powershell/…                                 # the Pester mirror of each of the above

tests/conformance/scenarios/
├── us9-hook-registration.json                   # RETIRED
├── us021b-disabled-event.json                   # RE-POINTED at the exit-4 refusal
└── us4-port-selection.json                      # description reworded
```

**Structure Decision**: unchanged — the existing two-port layout with a shared
conformance corpus. The only structural movement is that `hooks/` loses one of its
two modules in each port; the directory stays for `readme_block`.

## Execution order

The order is load-bearing in two places and free everywhere else.

1. **Guard first.** Write the widened absence guard for both ports and prove it red
   against the pre-change tree (quickstart §0). Verify the instrument reads
   anything at all before trusting a red — an inert guard and a passing guard are
   indistinguishable from the outside.
2. **Delete the readers**, then their callers, then the record and the flag, then
   the dispatch hold. Ports in lockstep; a port left half-deleted diverges on every
   conformance scenario and hides which change caused it.
3. **Amend the contracts** and rewrite the managed README block template. This does
   *not* break conformance — the corpus compares the two ports to each other, not
   to a golden capture — but it does touch the two consumer-docs CI scans
   (research R7).
4. **Sweep the documentation** against research R10's enumerated list — not against
   an ad-hoc grep. A previous feature in this repository shipped with `README.md`
   stating the opposite of the feature because the task list covered only the
   code's own docs.
5. **Bump and changelog** last.

## Risks

| Risk | Why it is plausible here | Mitigation |
| --- | --- | --- |
| The widened guard ships inert | Two of three guards shipped in a previous feature were inert; the failure is invisible | quickstart §0 proves it red against `git archive HEAD` and separately proves the search root is non-empty |
| The doc sweep misses a file | The claim appears in 10 files across four categories, including a *template* that writes into consumer repositories | research R10 enumerates every file and what changes in it; SC-006 is a single `git grep` |
| A conformance fixture breaks for an unrelated reason | `repo-with-disabled-event` becomes an exit-4 fixture; three fixtures carry a tracked `.specify/extensions.yml` | Those three stay — a guard proving "we never open it" is only meaningful where the file exists |
| `Get-CfgUnsupportedConstruct` disappears with its module | It is defined inside `RegisterHooks.psm1` under a `Get-Cfg*` name that reads as belonging to the config lib | data-model §10 flags it; trace its callers before deleting the module |
| Windows-only divergence | The bash port's registry read used the restricted YAML reader; deleting a reader cannot introduce a CRLF or path defect, but the doc/template rewrite touches written bytes | Standard conformance run; escalate to `ci/windows-probe` only if a divergence appears — budget ~2 h, and one retry maximum |

## Complexity Tracking

No Constitution Check violation requires justification. The table is intentionally
empty: this feature removes machinery rather than adding it, and the two
alternatives that would have added some — teaching the classifier the pre-rename
names, and a dedicated retired-key rule with a bespoke message — are recorded as
rejected in the constitution's amendment report and in the spec's Assumptions
respectively.
