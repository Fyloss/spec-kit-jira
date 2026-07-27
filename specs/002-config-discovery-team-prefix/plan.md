# Implementation Plan: Reliable Automatic Jira Discovery & Team-Based Feature Prefix

**Branch**: `002-config-discovery-team-prefix` | **Date**: 2026-07-26 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-config-discovery-team-prefix/spec.md`

## Summary

Fix two configuration-ceremony defects and add one enhancement, all inside the
existing twin-port (Bash + PowerShell 7+) extension:

1. **Style detection (US1)** — `_disc_style` / its PowerShell twin currently
   fall back to `company_managed` when the `GET /project/{key}` payload carries
   no style signal (`scripts/bash/sink/jira/discovery.sh:61-72`). The fix makes
   an absent or contradictory signal an explicit *ambiguous* outcome: the
   ceremony asks a closed two-value question in interactive (agent-driven) mode
   or fails closed (exit 4) unattended, and the persisted local binding records
   the style **with its provenance** (`api` vs `operator`).
2. **Jira-first key discovery (US2)** — in a connected run the project key may
   come only from the command argument, the committed team config, or a closed
   question over the projects listed by a new `GET /project/search` sink read;
   the template placeholder `PROJ` counts as unset; git state is never a
   source (the agent command definition is rewritten to say so explicitly).
   When connection parameters are *undefined* (never on auth/network failure),
   the ceremony runs a loudly-announced degraded mode: branch-scan proposals
   marked provisional, zero writes to the authoritative resolved-id binding,
   and explicit re-run guidance.
3. **Team conventions (US3)** — a committed `teams:` catalogue in
   `config.yml` (id, Jira project, folder prefix, branch pattern) plus a
   personal gitignored `.specify/jira/personal.yml` selecting the developer's
   team. A new deterministic `feature` command (both ports), registered as a
   non-blocking `before_specify` hook, resolves the Jira ticket first
   (validate a mentioned key, otherwise create one in the team's project) and
   emits the branch name (team pattern, ticket number stripped of the project
   key) and the flat folder short-name (team prefix, never duplicated). No
   selection ⇒ byte-for-byte today's behaviour.

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port) and PowerShell 7+ (Windows port) — twin native implementations, no build or download step (Constitution VI)

**Primary Dependencies**: Runtime: `curl`, `jq`, `git` (Bash port); PowerShell built-ins (Windows port). Dev-only: bats-core + kcov (coverage), Pester, shellcheck, PSScriptAnalyzer. **No new dependency is introduced by this feature.**

**Storage**: Files only — `.specify/jira/config.yml` (committed team config, gains the `teams:` catalogue), `.specify/jira/config.local.yml` (machine-owned local binding, gains per-project `style` + `style_source`), `.specify/jira/personal.yml` (**new**, human-owned, gitignored personal team selection), `.specify/extensions.yml` (hook registration, gains `before_specify`), repository `.gitignore` (new managed coverage check)

**Testing**: bats (Bash) + Pester (PowerShell) mocked unit suites, language-agnostic conformance scenarios against the mock Jira server (`tests/conformance/`), 80% statement coverage gate (kcov / Pester CodeCoverage)

**Target Platform**: macOS, Linux, Windows CLIs (three-OS CI matrix is a merge gate)

**Project Type**: CLI — spec-kit extension with twin script ports

**Performance Goals**: Interactive-CLI latency; discovery adds at most one paginated `GET /project/search` sequence to the existing fixed 6-read discovery; feature creation adds at most two Jira calls (one read or one guarded create)

**Constraints**: Byte-identical persisted output and identical exit codes across both ports (FR-020); zero-churn idempotent re-runs; fail-closed on writes, non-blocking on hooks; no credential ever in tree, argv, or logs

**Scale/Scope**: Enterprise repositories — multiple teams sharing one clone-family, multiple Jira projects, heterogeneous workflows

## Constitution Check

*GATE: evaluated before Phase 0; re-evaluated after Phase 1 design — PASS, no violations.*

| # | Principle | Compliance in this design |
|---|-----------|---------------------------|
| I | Filesystem is source of truth | Feature-time ticket creation produces a bridge-created artifact (identity-stamped, logged in the feature output); a *mentioned* ticket is read/attached under the first controlled exception (operator-named key) and the mutation is reported. No delete paths are added. |
| II | Zero-churn idempotency | Re-running the ceremony on an unchanged project rewrites a byte-identical `config.local.yml` including the new `style`/`style_source` keys (canonical serialiser reused). The degraded mode writes nothing at all. Ticket identity still relies on the entity-property marker, never names. |
| III | Fail-closed writes / non-blocking hooks | Ambiguous style unattended ⇒ exit 4, zero writes. Unknown/unresolvable key ⇒ fail-closed transport code, no substitution. The `before_specify` feature hook is registered `optional: true` and internally degrades to default naming with one warning when Jira is unreachable (FR-016) — the host command never fails. |
| IV | Zero credentials in tree | The personal file schema reuses the credential-shape refusal (value never echoed). The degraded mode is triggered by *absence* of connection parameters and touches no credential. No new token path. |
| V | Team config / local binding / secrets | Catalogue ⇒ committed `config.yml` (layer 1). Style provenance ⇒ machine-owned `config.local.yml` (layer 2). Personal selection ⇒ a **human-owned** gitignored file in layer 2 (`personal.yml`), deliberately separate from the machine-rewritten local binding (see research §5). Nothing lands in the extension folder. |
| VI | Three-OS portability, twin ports | Every new behaviour ships in both ports with conformance scenarios asserting identical stdout, exit codes, call sequences, and written bytes. Prerequisite gates unchanged. |
| VII | No hard-coded Jira workflow assumptions | Style comes exclusively from the API payload or the operator; the accessible-project list is discovered; ticket creation uses the *resolved* story type id from the binding, never a literal type name. |
| VIII | Neutral engine / Jira sink | The new naming logic (`engine/naming.sh` / `Naming.psm1`) is pure: pattern expansion, prefix dedup, folder-safety — the ticket number arrives as an opaque string. Project listing and ticket read/create live in the sink. Engine files carry no issue-key-shaped text (boundary grep). |
| IX | Two-tier privacy guard | The ticket-create payload passes the existing PASS-1 guard before any POST (guard-then-write invariant preserved). No new scanning tier. |
| X | Self-healing mirror | `before_specify` registration extends the existing set-not-append merge; an operator-disabled hook stays disabled; reinstall/upgrade resilience tests extended to the new event. |
| XI | Universal dry-run / auditability | `config --dry-run` covers the new effects (style provenance, gitignore coverage); `feature --dry-run` predicts the ticket action and names without writing; both summaries stay structured prose with `--json` option. |
| XII | Quality & catalog publication | MINOR SemVer bump + CHANGELOG entry; mocked suites gate fork PRs; live dogfood before release. |
| XIII | TDD ≥ 80% | Both reported defects get failing regression tests *before* the fix (style default; agent-doc branch-inference latitude via conformance/doc assertions); every implementation task will be preceded by its test task in tasks.md. |
| XIV | KISS | No new abstraction layer, no new dependency. Branch scanning reuses `git` (already required). The one new engine module exists because naming must be pure and twin-ported, not for genericity. |
| XV | YAGNI | Every new schema field (`teams[]`, `personal.yml` keys, `style_source`, summary `provisional`) maps to a named FR and a test; no speculative options. |
| XVI | Human readable | Errors name the file/project and a copy-pasteable remediation (e.g. the exact re-run command after defining env vars); `config.yml.template` documents the catalogue in comments; summaries stay prose-first. |

## Project Structure

### Documentation (this feature)

```text
specs/002-config-discovery-team-prefix/
├── plan.md              # This file
├── research.md          # Phase 0 output — decisions §1–§8
├── data-model.md        # Phase 1 output — entities & validation rules
├── quickstart.md        # Phase 1 output — end-to-end validation guide
├── contracts/           # Phase 1 output
│   ├── teams-catalogue.schema.json    # config.yml `teams:` section
│   ├── personal-config.schema.json    # .specify/jira/personal.yml
│   ├── config-cli-contract.md         # config command deltas (flags, exit codes, summary)
│   ├── feature-cli-contract.md        # new feature command (both ports)
│   └── jira-endpoints-delta.md        # new sink reads/writes
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
scripts/bash/
├── engine/
│   └── naming.sh                  # NEW — pure pattern expansion, prefix dedup, team validation
├── sink/jira/
│   ├── discovery.sh               # MODIFIED — _disc_style ambiguity; NEW discovery_list_projects
│   └── ticket.sh                  # NEW — ticket_validate (read), ticket_create (guarded write)
├── lib/
│   └── config.sh                  # MODIFIED — teams schema, personal-file loader, placeholder-key rule
├── commands/
│   ├── config.sh                  # MODIFIED — style provenance, key argument, degraded mode, gitignore effect
│   └── feature.sh                 # NEW — cmd_feature (ticket-first naming)
└── hooks/
    └── register_hooks.sh          # MODIFIED — before_specify feature hook

scripts/powershell/                # twin of every file above
├── engine/Naming.psm1             # NEW
├── sink/jira/Discovery.psm1       # MODIFIED
├── sink/jira/Ticket.psm1          # NEW
├── lib/Config.psm1                # MODIFIED
├── commands/Config.psm1           # MODIFIED
├── commands/Feature.psm1          # NEW
└── hooks/RegisterHooks.psm1       # MODIFIED

commands/
├── speckit.jira.config.md         # REWRITTEN — forbids git-state inference, documents degraded mode
└── speckit.jira.feature.md        # NEW — agent-facing feature-naming ceremony

templates/
├── config.yml.template            # MODIFIED — teams section, style line becomes a comment
└── personal.yml.template          # NEW — commented personal-selection template

extension.yml                      # MODIFIED — provides speckit.jira.feature

tests/
├── bash/{engine,sink,lib,commands,hooks}/   # new bats suites per module
├── powershell/…                             # Pester twins
└── conformance/
    ├── scenarios/                 # NEW: style-ambiguity refusal, list-projects, degraded mode,
    │                              #      feature naming (attach/create/none), gitignore effect
    └── fixtures/                  # NEW: repo-with-teams, ambiguous-style project payloads
```

**Structure Decision**: single-project layout, unchanged from 001 — the feature
only adds/modifies leaves inside the established twin-port tree
(`scripts/bash/**` mirrored by `scripts/powershell/**`, module-parity gate
already normalises multi-word names).

## Complexity Tracking

No Constitution Check violations — no entries.
