# Implementation Plan: A Recorded Field Default Is Sent in the Shape Its Field Accepts

**Branch**: `fix/field-default-encoding` | **Date**: 2026-08-04 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/015-fix-field-default-encoding/spec.md`

## Summary

Discovery records a defaultable field's declared type next to its identifier. The resolver that joins a
recorded label to that identifier reads the identifier and drops the type, so every recorded default
reaches Jira as the bare scalar the operator typed. For a free-text field that is right. For a
single-select field Jira refuses it, and since the refusal happens on the first creation, a project with
one mandatory single-select creates nothing at all.

The fix is one lookup at the join. `plan_resolve_field_defaults` already receives the whole
`defaultable_fields` array and already reaches into it for `field_id`; `schema_type` is one property
further on the same object.

Three decisions shape the work, all in [research.md](research.md):

1. **Encode at the resolver, not at the payload builder.** The type and the value are in scope together
   exactly once, and both creation paths read the resolver's output, so one change covers both.
2. **Emit a second map rather than transform the first.** Three operator-facing surfaces read the
   resolver's output today — the confirmation question, the provenance note, and a `--field-default`
   promotion command the operator is told to *run*, which writes its argument back into `config.yml`.
   Keeping `field_defaults` as recorded and adding `field_defaults_encoded` for the wire makes all three
   correct without a single display change and without an inverse transform that could only ever guess.
   Exactly one line per port moves to the new map.
3. **Count what Jira confirmed, from where the response is read.** `apply_writes_with_recognition`
   already parses the key out of every create response in order to stamp the identity marker; it now
   publishes what it knows on stdout, which it does not otherwise use. The alternative — recounting from
   the spec file after the fact — answers a different question and would under-report a ticket that
   exists.

The configuration-time check of User Story 4 is not a new rule: `--field-default` values are already
refused when they fall outside `allowed_values`. The same rule simply never ran over values already
sitting in `config.yml`. Running it there, with orphans still non-blocking, is the whole slice.

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port) and PowerShell 7+ (Windows port). Both are shipped
implementations of the same behaviour; neither is a reference for the other.

**Primary Dependencies**: none added. `jq`, `curl`, `git` on the Bash side; PowerShell built-ins on the
Windows side. No new module, no new file, no new external tool.

**Storage**: none touched. `.specify/jira/config.yml` keeps holding plain recorded values;
`.specify/jira/config.local.yml` keeps holding the `schema_type` and `allowed_values` this feature reads.
Neither gains a key. Every new shape is in-memory for one run.

**Testing**: `bats` (`tests/run-bash.sh`), Pester (`tests/powershell`), and the shared conformance corpus
(`bash tests/conformance/ci-conformance.sh`) for byte equivalence. Coverage by kcov and Pester
CodeCoverage, gate at 80% statements.

**Target Platform**: macOS, Linux, Windows — the three-OS Actions matrix is the merge gate. No Windows-only
behaviour is being changed, so the `ci/windows-probe` loop is not on the critical path.

**Project Type**: a Spec Kit extension shipped as twin native script ports; no build step, no compiled
artifact, no download at runtime.

**Performance Goals**: zero additional Jira requests, on every path. The encoding is a lookup against a
map already in memory; the confirmed count is read from responses already parsed; the configuration check
runs over metadata already fetched.

**Constraints**: byte-identical output between the ports; no `$'\r\n'` inside any glob pattern; no bare
`jq` on multi-line output in the Bash port (`lib/output.sh` only); the resolver's jq literal stays inside
its existing `kcov-excl` brackets.

**Scale/Scope**: 4 Bash files and their 4 PowerShell twins, of which 2 per port are comment-only or
one-line changes; plus test files and 3 conformance scenarios. No new module in either port.

## Constitution Check

*GATE: passed before Phase 0 research; re-checked after Phase 1 design — see "Post-Design Re-Check".*

| # | Principle | Gate verdict |
| --- | --- | --- |
| I | Filesystem Is the Source of Truth | **Pass.** No new read, write target, or delete path. `config.yml` and `config.local.yml` gain no key. The feature is what lets the spec file's `creating` markers resolve to real keys instead of stalling forever. |
| II | Zero-Churn Idempotency | **Pass.** Encoding happens downstream of every write to `config.yml`, so an unchanged ceremony re-run still rewrites the file byte-for-byte. The non-string guard makes the encoding idempotent by construction, and a fully successful run's summary is byte-identical (FR-013). |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | **Pass.** A value the bridge cannot shape is still sent as recorded and still fails closed with the existing diagnostic. The new configuration refusal writes nothing. The hook wrapper's exit downgrade is untouched, so the host command's outcome cannot move. |
| IV | Credential Security | **Pass.** No credential is read, written, or logged. The new refusal names the label, the type, and the candidates — never the recorded value — following the credential-shaped refusal already in place. |
| V | Separation of Team Config / Local Binding / Secrets | **Pass, and it is the point.** The committable layer keeps business language; the wire shape is derived at run time from the machine-owned layer and never written back. Decision R2 exists precisely to stop an encoded value reaching `config.yml` through the promotion command. |
| VI | Portability | **Pass.** Both ports implement every FR; three conformance scenarios prove byte equivalence. No new glob, no new line-ending surface, no bare `jq`. |
| VII | No Hard-Coded Jira Assumptions | **Pass, and it is the principle the defect violated.** The shape is derived from the type Jira reported for that field at discovery time. No field id, type name, or project name is hard-coded, and an unrecognised `schema_type` falls through to today's behaviour. |
| VIII | Neutral Engine / Jira Sink | **Pass.** Every change lands in `sink/jira/` and `commands/`. The engine gains nothing — no field type, no option shape, no payload structure. The boundary greps stay green. |
| IX | Two-Tier Privacy Guard | **Pass.** The same values are sent, differently spelled, through the same pre-write scan. The two privacy-guard return paths in the apply function are deliberately left untouched (data-model §5, rule O4). |
| X | Self-Healing Mirror | **Pass, and directly served.** Today an affected project's mirror cannot heal at all; after this change the next ordinary run completes it with no manual step. |
| XI | Universal Dry-Run and Auditability | **Pass.** FR-011 repairs an auditability defect this principle names: a summary that reports work that did not happen is not usable by CI. Dry-run equivalence is preserved — the predicted *action set* is unchanged; only the post-run tally becomes confirmation-based, and `--dry-run` has no confirmations to read. |
| XII | Quality and Catalog Publication | **Pass.** PATCH bump, CHANGELOG entry, three-OS green, lint clean. |
| XIII | TDD, 80% coverage | **Pass.** Step 0 of [quickstart.md](quickstart.md) is the failing-first regression FR-017 demands, red before the fix by construction. Every user story carries an independent test. No test scans for a process, file, or port by name pattern. |
| XIV | KISS | **Pass, no new complexity.** No new module, file, dependency, abstraction, or function signature. The one added output shape (the apply outcome) replaces a temp-file protocol that would have been worse. Complexity Tracking is empty. |
| XV | YAGNI | **Pass.** §8 of [data-model.md](data-model.md) maps every shape to an FR and every FR to a test. `field_defaults_encoded` is demanded by FR-001 and FR-009 jointly; `outside_allowed` by FR-014. The encoding table stops at the types Jira reports for a single-value field — no speculative row. |
| XVI | Human Readable | **Pass.** Decision R2 keeps the operator's own words on all three surfaces they read; R8 corrects a comment that now asserts the opposite of the code; the new refusal reuses the existing wording verbatim, so an operator cannot tell whether a refusal came from a flag or from the file — and should not have to. |

**Post-Design Re-Check (after Phase 1)**: unchanged, and one item improved. Phase 0 began with the bug
report's de-encapsulate-at-display approach, which would have touched three display sites and required an
inverse transform. Reading the code found the third site — the `--field-default` promotion command — and
the two-map design removed the inversion entirely. The design ends with fewer changed sites and less
logic than it started with. No dependency, no abstraction layer, and no engine-side Jira knowledge was
added.

## Project Structure

### Documentation (this feature)

```text
specs/015-fix-field-default-encoding/
├── plan.md              # This file
├── research.md          # Phase 0 — eight decisions and what was rejected
├── data-model.md        # Phase 1 — shapes, invariants, requirement traceability
├── quickstart.md        # Phase 1 — how to prove it works, suite by suite
├── contracts/
│   └── field-default-encoding.md   # Phase 1 — the binding cross-port contract
├── checklists/
│   └── requirements.md  # Written by /speckit-specify
└── tasks.md             # Phase 2 — NOT created by /speckit-plan
```

### Source Code (repository root)

```text
scripts/bash/
├── sink/jira/
│   ├── plan_apply.sh          # encode in plan_resolve_field_defaults; emit the
│   │                          #   created-outcome in apply_writes_with_recognition
│   └── discovery.sh           # comment correction only (R8) — no behaviour change
└── commands/
    ├── reconcile.sh           # plan context reads field_defaults_encoded (1 line);
    │                          #   counts.created from the apply outcome
    └── config.sh              # outside_allowed over the merged recorded map

scripts/powershell/
├── sink/jira/
│   ├── PlanApply.psm1         # twin of both plan_apply.sh changes
│   └── Discovery.psm1         # twin comment correction
└── commands/
    ├── Reconcile.psm1         # twin of both reconcile.sh changes
    └── Config.psm1            # twin of the config.sh change

tests/
├── bash/
│   ├── sink/test_plan_apply_defaults.bats           # US1 — encoding rules, two-map invariants
│   ├── sink/test_ticket.bats                        # US1 — exact payload shape (FR-017)
│   ├── sink/test_plan_apply_outcome.bats            # US3 — NEW, apply outcome contract
│   ├── sink/test_privacy_block.bats                 # US3 — rule O4, stdout stays silent
│   ├── commands/test_reconcile_field_defaults.bats  # US2 — question and promotion command
│   ├── commands/test_reconcile_created_count.bats   # US3 — NEW, confirmed-count rule
│   └── commands/test_config_field_defaults.bats     # US4 — recorded-value refusal
├── powershell/
│   ├── sink/PlanApply.Defaults.Tests.ps1            # US1
│   ├── sink/Ticket.Tests.ps1                        # US1
│   ├── sink/PlanApply.Outcome.Tests.ps1             # US3 — NEW
│   ├── sink/PrivacyGuard.Block.Tests.ps1            # US3 — rule O4 twin
│   ├── commands/Reconcile.FieldDefaults.Tests.ps1   # US2
│   ├── commands/Reconcile.CreatedCount.Tests.ps1    # US3 — NEW
│   └── commands/Config.FieldDefaults.Tests.ps1      # US4
└── conformance/scenarios/                           # 3 new scenarios (contract §8)
```

**Structure Decision**: the existing twin-port layout is kept exactly as it is. No file is created in
either `scripts/` tree; every change lands in a function that already exists, in the module that already
owns that concern. The only new files in the repository are tests: four test files giving User Story 3
its own home in both ports — which is what keeps it buildable in parallel with US1 and US2 rather than
contending for their files — and three conformance scenarios.

## Complexity Tracking

Empty — the Constitution Check records no violation to justify. No new project, module, dependency,
abstraction, or function signature is introduced, and the one new output shape (the apply outcome)
replaces the temp-file protocol that the alternative would have required.
