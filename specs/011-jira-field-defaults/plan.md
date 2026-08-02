# Implementation Plan: Recorded Field Defaults So a Mandatory Field Never Blocks a Mirror

**Branch**: `011-jira-field-defaults` | **Date**: 2026-08-02 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/011-jira-field-defaults/spec.md`

## Summary

Today a project whose written issue types require custom fields the bridge cannot supply is refused
twice — once at configuration time and once at reconcile time — by the same function,
`hierarchy_unsatisfiable_fields`, which classifies a required field as satisfiable only if the
bridge itself produces it (`summary`, `description`, `issuetype`, `project`, `priority`, `reporter`,
and `parent` where the child type offers a parent link). Everything else is unsatisfiable and the
mirror never starts.

The feature adds one source of satisfiability: a value the team recorded. Three mechanisms carry it,
and each is a small extension of something already shipped rather than a new subsystem.

1. **A recorded default makes a field satisfiable.** `hierarchy_unsatisfiable_fields` gains the
   recorded defaults as an input. Both existing call sites — the configuration ceremony's gate and
   the reconcile gate — inherit the change from one function.
2. **A recorded default reaches the payload the way the estimation field already does.** The plan
   context carries a resolved map, and `jira_create_fields_base` — the single builder both creation
   paths share, written precisely so the two could not drift apart — merges it. The update path is
   untouched, which is what makes create-only (FR-017) true by construction rather than by
   discipline.
3. **The ceremony writes the answers into `config.yml` through a marker-delimited managed region**,
   spliced by the existing `managed_section_splice` — the same byte-preserving, line-ending-aware
   splice the README block already uses. Every byte the operator wrote outside the region survives.

The consolidated question of User Story 2 needs no new interaction machinery either. The bridge stays
non-interactive on both ports: it plans the run (the work `--dry-run` already does), and when that
plan contains a creation carrying recorded defaults it stops before writing and emits the question as
structured output. The agent asks, then re-invokes with the answer — exactly the round trip the
ceremony already performs for the project key, the project style, and the role mapping.

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port) and PowerShell 7+ (Windows port). Both are shipped
implementations of the same behaviour; neither is a reference for the other.

**Primary Dependencies**: none added. `jq`, `curl`, `git` on the Bash side and PowerShell built-ins on
the Windows side, all already required. No new runtime or development dependency — the plan reuses
`engine/managed_section.sh` / `ManagedSection.psm1`, `lib/config.sh` / `Config.psm1`, and
`sink/jira/*` modules that already exist.

**Storage**: three existing files, no new one.
`.specify/jira/config.yml` (committable, gains a machine-written managed region),
`.specify/jira/config.local.yml` (gitignored, machine-owned, gains richer per-type field metadata),
and no state anywhere else.

**Testing**: `bats` for the Bash unit suites (`tests/run-bash.sh`), Pester for the PowerShell suites,
and the shared cross-port conformance corpus (`tests/conformance/`, driven by
`bash tests/conformance/ci-conformance.sh`) for byte equivalence. Coverage by kcov (Bash) and Pester
CodeCoverage (PowerShell), gate at 80% statements.

**Target Platform**: macOS, Linux, Windows — the three-OS GitHub Actions matrix is the merge gate.

**Project Type**: a Spec Kit extension shipped as twin native script ports; no build step, no
compiled artifact, no download at runtime.

**Performance Goals**: no new Jira request per reconcile run. The configuration ceremony issues at
most one additional `createmeta` read per issue type it questions, and only for types it was already
going to read. A reconcile that needs the consolidated question costs one extra entry-point
invocation (planning pass, then writing pass) and zero extra Jira writes.

**Constraints**: every output crossing platforms must be byte-identical between the ports; the
persisted binding and the managed config region must re-serialise identically on an unchanged input;
no `$'\r\n'` inside any glob pattern (see `docs/10-windows-portability.md`); no direct `jq` call in
the Bash port outside `lib/output.sh`.

**Scale/Scope**: roughly 12 Bash files and their 12 PowerShell twins, 2 templates, 2 command
documents, plus fixtures and scenarios. No new module is created in either port.

## Constitution Check

*GATE: passed before Phase 0 research; re-checked after Phase 1 design — see "Post-Design Re-Check".*

| # | Principle | Gate verdict |
| --- | --- | --- |
| I | Filesystem Is the Source of Truth | **Pass.** No new ticket read, no new write target, no delete path. Defaults enter only creations of tickets the bridge owns; a human's later edit remains drift on the existing path. |
| II | Zero-Churn Idempotency | **Pass.** Defaults are merged in the CREATE branch of `plan_writes` only; the UPDATE branch is not touched, so an unchanged re-run still produces zero writes. The managed region is written through the same canonical serialiser as the local binding, so an unchanged ceremony re-run rewrites `config.yml` byte-for-byte. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | **Pass.** The pre-existing refusal survives with its exit code for the no-default case; the planning pass performs zero writes; the reconcile command layer's existing non-blocking wrapper is unchanged, so the host command's outcome cannot move. |
| IV | Credential Security | **Pass, and largely free.** `_cfg_credential_errors` already scans every scalar in `config.yml` except `privacy.*`; a `field_defaults` value is scanned with no change. Values never reach argv — the flag carries them, but the token never does. |
| V | Separation of Team Config / Local Binding / Secrets | **Pass, with a noted first.** Defaults are a team decision in the committable layer; discovered field metadata stays in the gitignored layer. This is the first machine write to `config.yml` — recorded in Complexity Tracking, and bounded to a marked region. |
| VI | Portability | **Pass.** Both ports implement every requirement; the conformance corpus gains the scenarios listed in `quickstart.md`. The managed splice already handles the CRLF host correctly and is covered by the Windows probe. |
| VII | No Hard-Coded Jira Assumptions | **Pass.** Field labels, ids, allowed values, and requiredness all come from `createmeta`. The satisfiable-by-the-bridge list is a pre-existing constant in the sink and is not extended. |
| VIII | Neutral Engine / Jira Sink | **Pass.** Every new identifier — field ids, allowed values, createmeta shapes — lives in `sink/jira/` and `commands/`. `engine/` gains nothing but a caller of the existing `managed_section_splice`, which is parameterised by its markers and learns no Jira vocabulary. The boundary greps stay green. |
| IX | Two-Tier Privacy Guard | **Pass.** A defaulted value lands inside the create body that `ticket_create` already passes to `privacy_guard_scan` before the POST. No new guard, no exemption. |
| X | Self-Healing Mirror | **Pass.** Hook registration, health, and repair are untouched; a disabled event still exits silently before any of this runs. |
| XI | Universal Dry-Run and Auditability | **Pass, and structurally so.** The question-producing pass *is* the planning pass, so the preview and the real run cannot disagree about a defaulted value — they are computed by the same code. |
| XII | Quality and Catalog Publication | **Pass.** MINOR bump, CHANGELOG entry, three-OS green, lint clean, dogfood against a project with mandatory custom fields. |
| XIII | TDD, 80% coverage | **Pass.** Every task in `tasks.md` will be preceded by its failing test; `us3-mandatory-field-refusal` gains its green counterpart; the original defect gets its regression scenario first. |
| XIV | KISS | **Pass, with two justified items.** Three reuses, no new module, no new dependency. The managed region in `config.yml` and the two-pass confirmation are the only added complexity and are justified below. |
| XV | YAGNI | **Pass.** Each new key, flag, and persisted field traces to a requirement — the traceability table lives in `data-model.md`. Nothing is persisted "for later"; `allowed_values` is persisted because FR-003 and FR-019 consume it. |
| XVI | Human Readable | **Pass.** The managed region carries its own explanatory comment header; every message names a field by its Jira label; the question is one prose list. |

**Post-Design Re-Check (after Phase 1)**: unchanged. The design added no dependency, no abstraction
layer, and no engine-side Jira knowledge. The two Complexity Tracking entries below were both
identified before Phase 0 and neither grew during design.

## Project Structure

### Documentation (this feature)

```text
specs/011-jira-field-defaults/
├── plan.md              # This file
├── research.md          # Phase 0 — the seven decisions and what was rejected
├── data-model.md        # Phase 1 — entities, config shapes, requirement traceability
├── quickstart.md        # Phase 1 — how to prove the feature works, suite by suite
├── contracts/
│   └── field-defaults.md   # Phase 1 — the resolution, question, and write contract
├── checklists/
│   └── requirements.md  # Written by /speckit-specify
└── tasks.md             # Phase 2 — NOT created by /speckit-plan
```

### Source Code (repository root)

```text
scripts/bash/
├── lib/
│   ├── config.sh              # read field_defaults; schema-validate it; emit the managed region
│   └── cli.sh                 # --field-default, --field-value, --accept-defaults
├── engine/
│   └── managed_section.sh     # REUSED UNCHANGED — the config.yml region splice
├── sink/jira/
│   ├── discovery.sh           # per-type defaultable-field metadata (label, id, shape, allowed values)
│   ├── hierarchy.sh           # unsatisfiable-fields becomes defaults-aware (one function, two gates)
│   ├── plan_apply.sh          # carry resolved defaults into the CREATE branch only
│   └── ticket.sh              # jira_create_fields_base merges the defaults
└── commands/
    ├── config.sh              # ask, validate, persist; report not-yet-consumed entries
    └── reconcile.sh           # planning pass → consolidated question → writing pass

scripts/powershell/            # the twin of every file above, same behaviour, same bytes out
├── lib/{Config,Cli}.psm1
├── engine/ManagedSection.psm1 # REUSED UNCHANGED
├── sink/jira/{Discovery,Hierarchy,PlanApply,Ticket}.psm1
└── commands/{Config,Reconcile}.psm1

templates/config.yml.template  # document field_defaults and the ask switch
commands/speckit.jira.config.md      # the new closed questions, normatively
commands/speckit.jira.reconcile.md   # the consolidated question and the re-invocation

tests/
├── bash/{lib,sink,commands}/         # bats units, one per new behaviour
├── powershell/{lib,sink,commands}/   # Pester twins
└── conformance/
    ├── fixtures/repo-with-field-defaults/       # new
    ├── fixtures/repo-with-mandatory-field/      # existing — gains the green counterpart
    └── scenarios/us1-*.json, us2-*.json, us3-*.json, sc010-*.json
```

**Structure Decision**: the existing dual-port layout is kept exactly. No directory is added in
either port, and no module is created — every change lands in a file that already exists and already
owns that concern. The one structural addition is a conformance fixture directory, which is test
data rather than source.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| **The entry point writes `config.yml` for the first time** (a marker-delimited managed region). Until now the bridge only ever *read* the committable layer and printed YAML for a human to paste, as `role_promotion_note` does. | SC-002 requires the operator to record every default "with no manual editing of the configuration file", and the ceremony's headline property is that it is deterministic and model-independent. Something has to write the file, and it cannot be the agent without making the result model-dependent and breaking FR-007's byte-identical guarantee. | **Print-only, operator pastes** (today's `role_promotion_note` idiom) fails SC-002 outright. **The agent writes it** makes a byte-identical re-run unachievable and moves a correctness guarantee into the model. **Whole-file round trip** through `config_yaml_to_json` → `config_to_yaml` would rewrite the file faithfully but destroy every comment in it, which Principle XVI's self-documenting requirement forbids. The managed region is the only option that writes deterministically *and* preserves the operator's prose — and it is not new machinery: `managed_section_splice` already does exactly this for the README block, including the CRLF host. |
| **A creating reconcile run takes two entry-point passes** when the consolidated question is due: a planning pass that writes nothing and emits the question, then a writing pass carrying the answer. | FR-011 requires the operator to be asked *before* the creation, and the bridge must stay non-interactive on both ports — a script that blocks on stdin cannot run under an agent, in CI, or in the conformance harness, and TTY sniffing would be untestable and would diverge between the ports. | **The bridge prompts on stdin** breaks the harness, CI, and Principle VI's byte-equivalence testing. **Ask after creating** is not a confirmation at all. **A separate "plan only" code path** would duplicate the writing path and put FR-023's preview/run agreement at risk; instead the planning pass *is* the existing `--dry-run` computation, so the preview and the real run agree because they are the same code. The cost is one extra process invocation on runs that create tickets and have the question enabled — zero extra Jira reads, zero extra writes. |
