# Implementation Plan: Label-Based Adoption of Pre-Existing Jira Tickets

**Branch**: `003-label-based-adoption` | **Date**: 2026-07-27 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-label-based-adoption/spec.md`

## Summary

Build the constitution's **second controlled exception** to "the filesystem is
the source of truth": a deliberate, one-time, operator-confirmed adoption that
binds an already-populated Jira backlog to the spec artifacts already on disk,
writing nothing but the identity marker.

The shape is a new twin-ported `adopt` command, strictly two-phase:

1. **Discovery (read-only)** — for each spec folder in scope, derive the exact
   adoption labels it implies from the operator-declared prefix, resolve its
   routed Jira project through the existing `routing_resolve`, and run one
   paginated JQL label search per project. Read each candidate's identity marker
   to detect claims. Classify every target as a *binding* (with the reason:
   label match or explicit `--bind`) or a *refusal* (one of eight named classes,
   each with a copy-pasteable remediation). Print the plan. Zero writes so far,
   always.
2. **Apply (after confirmation)** — the only action set built is
   `PUT /issue/{key}/properties/spec-kit-jira` with origin `human`, one per
   adopted ticket, executed through the existing `apply_writes` so the pre-write
   privacy guard, the fail-closed abort ladder, and the dry-run action-set
   prediction all come for free.

Everything downstream is already built: stamping origin `human` selects the
managed-panel splice and the managed-section-only churn diff that `adf.sh` and
`plan_apply.sh` have implemented since feature 001 US7. That is why US3's
byte-preservation promise costs no new preservation code — only the tests that
prove it end to end.

Two new committable configuration keys (`adoption.enabled`, defaulting to
`false`, and `adoption.label_prefix`, defaulting to `speckit-adopt:`), three new
flags (`--bind`, `--spec`, `--yes`), no new exit code, no new marker field, no
new runtime dependency.

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS 3.2 explicitly disqualified) and
PowerShell 7+ — twin native ports, no new language introduced

**Primary Dependencies**: none new. Bash port: `bash`, `curl`, `jq`, `git`
(already declared); PowerShell port: `pwsh` 7+, `git` (already declared).
Dev-only: bats-core, Pester, kcov, shellcheck, PSScriptAnalyzer — all already in
the tree

**Storage**: `.specify/jira/config.yml` (committable team config — gains an
`adoption:` section). No new file is created, read, or written by this feature;
adoption writes nothing into the repository tree at all (FR-028)

**Testing**: bats (Bash) + Pester (PowerShell) mocked unit suites, the shared
language-agnostic conformance corpus against the pwsh mock Jira server
(`tests/conformance/`), 80% statement coverage gate (kcov on Linux / Pester
CodeCoverage)

**Target Platform**: macOS, Linux, Windows CLIs — the three-OS CI matrix is the
merge gate

**Project Type**: CLI — spec-kit extension, twin script ports

**Performance Goals**: interactive-CLI latency; no success criterion depends on a
latency threshold. Discovery costs one paginated
JQL search per distinct routed project plus one identity read per candidate;
apply costs exactly one `PUT` per adopted ticket. No per-spec-folder search

**Constraints**: zero writes before confirmation, always; the only write kind
adoption may ever emit is the identity property stamp; byte-identical plans and
`--json` summaries across both ports; no credential and no site host in any
output at any verbosity; discovery bounded by the spec folders in scope and
paginated so no candidate list truncates silently

**Scale/Scope**: an enterprise repository with tens of spec folders routed
across several Jira projects, adopted against a backlog of thousands of issues

All `NEEDS CLARIFICATION` items raised while filling this section are resolved in
[research.md](./research.md) — endpoint and pagination (§1, §2), label grammar
and validation (§3), the wire value of the identity origin (§4), the detectable
scope of the collision-free rule (§5), confirmation semantics and exit codes
(§6), reuse of the write path (§7), the engine/sink split against the boundary
greps (§8), flag surface and validation placement (§9), refusal classes (§10),
the mock-server work required (§11), and coverage measurement (§12).

## Constitution Check

*GATE: evaluated before Phase 0; re-evaluated after Phase 1 design — **PASS**,
one documented limitation tracked below, no principle violated.*

| # | Principle | Compliance in this design |
|---|-----------|---------------------------|
| I | Filesystem is the source of truth, two controlled exceptions | This feature *is* the second exception, implemented to its three literal conditions: `adoption.enabled` defaults to `false` in the committable config (FR-001); the label must **name** a spec, and discovery searches only label values derived from the folders in scope, so a bare prefix is structurally undiscoverable rather than merely rejected (FR-003, research §3); every collision refuses per binding with zero writes and a named message (FR-011, refusal classes `already-claimed` and `spec-owns-bridge-ticket`). Adoption is one-time, logged in the run summary (FR-024), stamps origin `human` (FR-007), and FR-017 restates that an adopted ticket is never hard-deleted. **Documented limitation**: "the spec already owns a bridge-created ticket" is detectable through the candidate only (research §5) — recorded in Complexity Tracking, not silently assumed away. |
| II | Zero-churn idempotency | Re-running adoption on an adopted corpus produces zero writes of every kind: an already-stamped ticket is recognised by its marker and skipped, never re-stamped (FR-019, FR-027, SC-004, SC-007). Binding is keyed on labels and entity properties — stable, non-display fields — and FR-012 forbids *any* title/summary similarity path from existing at all, which is stricter than the principle requires. |
| III | Fail-closed on writes, non-blocking on hooks | Any unreliable read during discovery aborts the whole run before the first write with the mapped code (FR-008), inherited from `jira_request` and `apply_writes`. Every ambiguity fails closed per binding with zero writes for that binding (FR-009…FR-015), and FR-013 makes the highest applicable code win. Adoption registers no hook and is never fired by one (FR-029), so the non-blocking rule is untouched. |
| IV | Credential security — zero tokens in the tree | Credential resolution is unchanged (`lib/credentials.sh`); no new credential path exists. The BLOCK-tier guard runs before every stamp with no exemption, because the stamps go through `apply_writes` (research §7, FR-028). No plan line, summary, warning, or error carries a credential or a site host — issue keys, project keys, folder names only (FR-025). |
| V | Team config / local binding / secrets | The two new keys live in layer 1 (`.specify/jira/config.yml`), are credential-free, use business language, and are self-documented in `templates/config.yml.template` (FR-001, FR-002). Nothing is written to `config.local.yml`, `personal.yml`, or the extension folder. |
| VI | macOS / Linux / Windows portability | Every new module ships as a Bash/PowerShell twin; the plan, the `--json` summary, and the exit codes are asserted byte-identically by new conformance scenarios (NFR-1, SC-008). No build step, no download, no new runtime dependency (NFR-2). |
| VII | No hard-coded Jira workflow assumptions | Adoption reads labels, project, parent, and the identity property, and writes only the identity property. It asserts nothing about issue types, statuses, transitions, priorities, or custom fields, and therefore works over both project styles without a style branch (NFR-5). The label prefix is operator-declared, never a literal in a script (FR-002). |
| VIII | Neutral engine / Jira sink | Label derivation, scope resolution, and the whole ambiguity classification live in `engine/adoption.sh` / `Adoption.psm1`, which receives candidates as opaque JSON and carries **no issue-key-shaped literal, not even in a comment** — the `boundary.yml` grep scans comments too (research §8). JQL search, pagination, and the stamp live in the sink. Issue-key shape validation for `--bind` is deliberately placed in the sink, not the CLI parser, to keep every key-shaped literal on the sink side (research §9). |
| IX | Two-tier privacy guard with an allowlist | Unchanged: no new tier, no new exemption, no allowlist semantic change. Adoption inherits the existing guard by routing its writes through `apply_writes` (FR-028). |
| X | Self-healing automatic mirror | Unaffected. Adoption registers no hook and disables none (FR-029); hook health reporting on every run is untouched. |
| XI | Universal dry-run and auditability | `adopt --dry-run` reports the same action set the real run performs, because the action set *is* the prediction (FR-023, SC-003, research §7). Every run emits the structured summary listing applied bindings with their reason and refused bindings with their remediation (FR-024), prose by default and `--json` on opt-in. The guarded re-mode prune stays out of scope; FR-017 only restates the human-origin deletion protection. |
| XII | Quality and catalog publication | MINOR SemVer bump (new command, new config keys) in `extension.yml`'s single-sourced version, a CHANGELOG entry, green three-OS matrix, and a dogfood run against a real instance before release. |
| XIII | TDD with ≥80% coverage | `tasks.md` will order every test task before its implementation task. The critical paths here — ambiguity refusal, the zero-write guarantee, human-content preservation, the confirmation gate, and the privacy guard — target coverage close to 100%. jq literals in the new engine module carry the established `kcov-excl` markers (research §12). |
| XIV | KISS | One command, two config keys, three flags, two new modules per port. No new exit code, no new marker field, no new summary schema version, no new persisted artifact. The write path, the guard, the abort ladder, the routing resolver, and the managed-panel splice are all *reused*, not re-implemented. |
| XV | YAGNI | Every key and flag traces to an FR and will be exercised by a named test (FR-031). Everything anticipated but not required — the destructive prune, ticket create/delete during adoption, project migration, claim release, cross-repository bulk adoption, task-level adoption, CI/headless execution — stays in Out of Scope and is not built as a dead branch. |
| XVI | Human readable | The plan and summary are prose by default; every refusal names the spec folder, every issue key involved, and a copy-pasteable `--bind` command (research §10); the two config keys are self-documented in the template; `--bind`/`--spec`/`--yes` reuse the spec's own vocabulary. |

## Project Structure

### Documentation (this feature)

```text
specs/003-label-based-adoption/
├── plan.md                          # This file
├── research.md                      # Phase 0 — decisions §1–§12
├── data-model.md                    # Phase 1 — entities, validation, state
├── quickstart.md                    # Phase 1 — end-to-end validation guide
├── contracts/                       # Phase 1
│   ├── adopt-cli-contract.md        # The adopt command: flags, phases, exit codes, messages
│   ├── adoption-config.schema.json  # config.yml `adoption:` section
│   ├── adoption-plan.schema.json    # The adoption plan / summary block
│   └── jira-endpoints-delta.md      # New sink reads; the single write kind
├── checklists/
│   └── requirements.md              # (existing)
└── tasks.md                         # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/bash/
├── engine/
│   └── adoption.sh              # NEW — label derivation, scope, ambiguity classification (pure)
├── sink/jira/
│   └── adoption.sh              # NEW — paginated JQL label search, candidate context reads
├── lib/
│   ├── cli.sh                   # MODIFIED — `adopt` command, --bind/--spec/--yes
│   └── config.sh                # MODIFIED — `adoption` top-level key + schema rules
├── commands/
│   └── adopt.sh                 # NEW — cmd_adopt: two phases, confirmation, summary
└── spec-kit-jira.sh             # MODIFIED — usage block gains `adopt`

scripts/powershell/              # twin of every file above
├── engine/Adoption.psm1         # NEW
├── sink/jira/Adoption.psm1      # NEW
├── lib/Cli.psm1                 # MODIFIED
├── lib/Config.psm1              # MODIFIED
├── commands/Adopt.psm1          # NEW
└── spec-kit-jira.ps1            # MODIFIED

templates/
└── config.yml.template           # MODIFIED — self-documented `adoption:` section

tests/
├── bash/engine/test_adoption_labels.bats       # NEW — label grammar, short-number ambiguity
├── bash/engine/test_adoption_classify.bats     # NEW — the eight refusal classes, pure
├── bash/commands/test_adopt.bats               # NEW — phases, confirmation, exit codes
├── bash/sink/test_adoption_search.bats         # NEW — pagination, project scoping
├── bash/lib/test_config.bats                   # MODIFIED — adoption schema rules
├── powershell/…                                # twin suites
└── conformance/
    ├── mock-jira/mock-server.ps1               # MODIFIED — JQL-aware /search/jql handler
    └── scenarios/us1-adopt-*.json …            # NEW — one per story + one per refusal class
```

**Structure Decision**: no new top-level directory. The feature slots into the
existing four-layer script layout (`engine/` neutral, `sink/jira/` Jira-aware,
`lib/` port infrastructure, `commands/` orchestration) with exactly one new
module per port per layer that needs one, mirroring how feature 002 added
`engine/naming.sh` + `sink/jira/ticket.sh` + `commands/feature.sh`.

## Complexity Tracking

> Filled because the Constitution Check records one documented limitation rather
> than an unconditional guarantee. No principle is violated; the entry exists so
> review sees the trade-off explicitly instead of discovering it in the code.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| FR-011's "spec already owns a bridge-created ticket" is enforced only when that ticket is itself the labelled candidate | Jira Cloud cannot search entity properties without an app registration (research §1), and no spec→ticket index exists in the tree (research §5). Widening the check needs one of the two. | *Registering a Connect/Forge app* would introduce a deployment artifact and break Principle VI's no-build/no-download rule. *Committing a `bindings.yml` spec→ticket index* would add a fourth configuration artifact that can itself drift from Jira, contradicting Principle I — and the reconcile drift path already reports the two-parent situation this check would pre-empt. The limitation is stated in the CLI contract's refusal table so no reader assumes a stronger guarantee. |
