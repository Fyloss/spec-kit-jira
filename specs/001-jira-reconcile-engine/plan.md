# Implementation Plan: Jira Reconcile Engine (Twin Bash / PowerShell Ports)

**Branch**: `001-jira-reconcile-engine` | **Date**: 2026-07-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-jira-reconcile-engine/spec.md`

**Note**: This plan is the output of `/speckit.plan`. It stops after Phase 1 design; `/speckit.tasks` produces `tasks.md`.

## Summary

spec-kit-jira mirrors a repository's spec-kit artifacts (`spec.md`, `plan.md`, `tasks.md`) into Jira Cloud as a self-healing, idempotent, fail-closed bridge. It ships as two behaviourally identical native ports — a Bash implementation for macOS/Linux and a PowerShell 7+ implementation for Windows — following spec-kit's `sh`/`ps` convention, with no build or download step.

The technical approach is a **neutral reconcile engine** (parse spec artifacts → build a schema-validated neutral interchange document → decide drift/idempotency actions) cleanly separated from a **Jira sink** (metadata discovery, ADF rendering, REST writes) behind a fixed interface (Constitution VIII). A single deterministic **`/speckit.jira.config`** command performs three reported effects in one run: per-project metadata discovery (company-managed *and* team-managed), idempotent `after_*` hook registration in `.specify/extensions.yml`, and managed-README-block management. Every write is preceded by a two-tier privacy guard (BLOCK tier ships in the first increment). Credentials resolve through env → OS secret manager → gitignored `.env` and never touch argv, logs, or traces. Both ports are proven equivalent by a shared, language-agnostic conformance corpus, with statement coverage gated at 80% (kcov for Bash, Pester CodeCoverage for PowerShell).

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port; macOS ships 3.2 and does not qualify — checked up front) and PowerShell 7+ (`pwsh`, Windows port). No third language at runtime.

**Primary Dependencies**: Bash port — `curl`, `jq`, `git` (all runtime); PowerShell port — `pwsh` 7+, `git` (`Invoke-RestMethod`, `ConvertTo-Json`/`ConvertFrom-Json` are built in). Jira Cloud REST API v3 is the sole external service. Development-time-only: `bats` + `kcov` (Bash tests/coverage), `Pester` 5 (PowerShell tests/coverage), `shellcheck`/`shfmt` (Bash lint), `PSScriptAnalyzer` (PowerShell lint). No runtime framework.

**Storage**: Filesystem only. Committable team config `.specify/jira/config.yml` (YAML, credential-free); gitignored `.specify/jira/config.local.yml` (personal overrides, resolved ids); gitignored `.specify/jira/.env` (secrets fallback). Jira is a derived mirror, never a source of truth (Constitution I). No database.

**Testing**: Per-port unit suites over a shared mocked Jira double (both project styles + 401/404/429-exhausted/network fault injection) — `bats` (Bash), `Pester` (PowerShell). A shared, language-agnostic **conformance corpus** (JSON scenarios + fixtures) run against each port asserts byte-identical outputs, exit codes, and Jira API call sequences (NFR-1, Constitution VI). An opt-in **live suite** verifies zero-churn against a real instance (Constitution II/XII). Coverage on the mocked unit suites only, so fork PRs stay gated without credentials.

**Target Platform**: macOS (Bash ≥ 4), Linux (Bash ≥ 4), Windows (PowerShell 7+). CI matrix: ubuntu / macos / windows — green three-OS matrix is a merge gate.

**Project Type**: CLI / shell-native Spec Kit extension (twin ports + one engine/sink interface). Not a library, web service, or app.

**Performance Goals**: Not latency-bound; correctness- and idempotency-bound. Target: a demo repo of 3 features across a company-managed and a team-managed project reconciles in a single run, and an immediate re-run issues 0 writes (SC-001). Jira API calls are rate-limit-aware (bounded retry with backoff on 429).

**Constraints**: Zero tokens in the tree, ever, and never in argv/logs/traces (NFR-3, eliminatory). Any repository-written output (managed README block, neutral interchange document, run summaries) MUST be byte-identical between ports (Constitution VI). The engine MUST contain zero Jira knowledge (Constitution VIII, grep-enforced). Never write under `.specify/scripts/` or `.specify/templates/` (Spec Kit core; FR-055). Jira Cloud only — no Data Center/Server.

**Scale/Scope**: Enterprise: multiple teams, multiple Jira projects per repository (mixed company-managed/team-managed), heterogeneous workflows (Scrum/Kanban/SAFe). Twelve user stories (6×P1, 4×P2, 2×P3 — US11 privacy BLOCK is P1), 55 functional requirements, 6 non-functional requirements, 9 measurable success criteria. No `NEEDS CLARIFICATION` remain (the command-name gate was operator-confirmed to `/speckit.jira.config` on 2026-07-23).

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1 design. All sixteen principles are addressed in the spec's Constitution Check; the plan-level gate below records how the design realises the mechanically-enforced ones and flags any risk.*

| # | Principle | Design realisation | Gate |
|---|-----------|--------------------|------|
| I | Filesystem is source of truth (2 exceptions) | Engine treats disk specs as reference, Jira as derived; drift named before overwrite. Only exception in scope: operator-mentioned key (US10) — logs every mutation. Adoption and re-mode prune are Out of Scope, no delete path built. | PASS |
| II | Zero-churn idempotency | Idempotency decided in the engine on the managed section / neutral doc; identity via stable entity-property marker, never title. Live zero-churn suite (opt-in). | PASS |
| III | Fail-closed writes, non-blocking hooks | Sink read failure → zero writes for that spec, monotonic exit code. `after_*` hooks wrap reconcile so host command exit is never affected; ≤1 WARNING. | PASS |
| IV | Credential security | Resolution order env → secret manager → `.env`; curl header via `--config` on stdin (never `-H` argv); PowerShell keeps token in-process. Privacy guard BLOCK tier before every write, ships increment 1. | PASS |
| V | Config / binding / secrets separation | `config.yml` (committable, credential-free) + `config.local.yml` (gitignored) + secrets never in YAML. Config lives at repo root, never in extension folder; schema rejects credential-shaped values. | PASS |
| VI | macOS/Linux/Windows portability | Two native ports, no build/download. Byte-identical repo-written output enforced by conformance corpus + canonical JSON + deliberate line-ending handling. Bash ≥ 4 prerequisite named (macOS 3.2 fails up front), documented in install docs. | PASS |
| VII | No hard-coded Jira assumptions | All workflow-varying metadata discovered via API; logical name → id resolution; no literal Atlassian default type/status/field-id in any script (grep-enforced). Non-default fixtures for both styles. | PASS |
| VIII | Neutral engine / Jira sink | Engine dir contains zero Jira identifiers and never sources/imports the sink dir (two CI greps). Neutral interchange doc schema-validated before any write. See Complexity Tracking for the one justified abstraction. | PASS |
| IX | Two-tier privacy guard + allowlist | BLOCK (exact coordinate / ATATT prefix / real `*.atlassian.net`) ships increment 1; WARN + allowlist (`.extensionignore` + `privacy.allowlist`) is P3. Allowlisted Confluence links never block or warn. | PASS |
| X | Self-healing mirror | Config command registers `after_*` hooks idempotently in `.specify/extensions.yml`; hook health checked & reported every run; one-command repair; disabled hook stays disabled forever. | PASS |
| XI | Universal dry-run & auditability | Every write-capable op has a `--dry-run` twin predicting the exact action set; every run emits a structured summary. Destructive re-mode is Out of Scope — not introduced. | PASS |
| XII | Quality & catalog publication | SemVer + CHANGELOG; three-OS CI; live suite non-blocking on fork PRs. Catalog-id verification and release gating are governance items realised in tasks. | PASS (governance in tasks) |
| XIII | TDD ≥ 80% coverage | Every implementation task preceded by its test task in `tasks.md`; statement coverage on mocked unit suites (kcov Bash PRIMARY / requirement→scenario traceability FALLBACK; Pester CodeCoverage PowerShell), 80% blocking; critical paths near 100%. | PASS (enforced in tasks ordering) |
| XIV | KISS | One engine/sink interface is the single abstraction (Principle VIII exception). No framework; `jq`/`Invoke-RestMethod` suffice. `kcov` is the one justified dev-only dependency. | PASS |
| XV | YAGNI | Every config key/flag/schema field traced to an FR and a test; anticipated features (adoption, re-mode prune, CI/headless, attachments, Xray, PI planning) stay in Out of Scope, not dead branches. | PASS |
| XVI | Human readable | Self-documenting `config.yml` with business-language keys; error messages name problem + file/ticket + copy-pasteable fix; prose summaries with `--json` opt-in; human-written ADF ticket content with named sections and formatted Gherkin. | PASS |

**Initial gate result**: PASS — no violations, no Complexity Tracking entries required beyond the constitution-blessed engine/sink interface (documented below for completeness, not as a deviation).

**Post-Phase-1 re-check**: PASS — the Phase 1 design (neutral interchange schema, sink interface contract, directory layout with grep-enforced engine/sink boundary) preserves every gate above; no new abstraction or dependency was introduced. See end of Phase 1.

## Project Structure

### Documentation (this feature)

```text
specs/001-jira-reconcile-engine/
├── plan.md              # This file (/speckit.plan output)
├── spec.md              # Feature specification
├── research.md          # Phase 0 output (/speckit.plan)
├── data-model.md        # Phase 1 output (/speckit.plan)
├── quickstart.md        # Phase 1 output (/speckit.plan)
├── contracts/           # Phase 1 output (/speckit.plan)
│   ├── neutral-interchange.schema.json   # Engine↔sink neutral document (Constitution VIII)
│   ├── config.schema.json                # Committable team config.yml schema (FR-019, FR-023)
│   ├── config.local.schema.json          # Gitignored local binding schema
│   ├── sink-interface.md                 # The fixed engine→sink contract (operations, inputs, outputs)
│   ├── jira-cloud-endpoints.md           # Discovery/read/write endpoints per project style (US2)
│   ├── cli-contract.md                   # Command surface, flags (--dry-run/--json/--on-drift), exit codes
│   └── run-summary.schema.json           # Structured summary, --json form (NFR-5)
├── checklists/
│   └── requirements.md   # Specification quality checklist (pre-existing)
└── tasks.md              # Phase 2 output (/speckit.tasks — NOT created here)
```

### Source Code (repository root)

The extension is a Spec Kit extension: its runtime scripts, templates, and version metadata live **exclusively** under `.specify/extensions/jira/` (FR-055); the only files written elsewhere are the agent command files (outside `.specify/`), the hook entries in `.specify/extensions.yml`, the team config under `.specify/jira/`, and the managed README block. The two ports mirror each other module-for-module, with a shared engine/sink separation enforced by CI greps.

```text
.specify/extensions/jira/
├── extension.yml                 # Extension metadata (id, catalog name, version) — the SINGLE source of truth for the version (FR-021/022); no other version string in the tree, grep-enforced by SC-006
├── CHANGELOG.md                  # SemVer changelog (Constitution XII)
│
├── scripts/
│   ├── bash/                     # Bash port (macOS/Linux)
│   │   ├── spec-kit-jira.sh      # Entry point / dispatcher
│   │   ├── lib/                  # Port infrastructure — NO Jira knowledge, NO engine decisions
│   │   │   ├── cli.sh            # Arg parsing, --dry-run/--json/--on-drift, exit-code table
│   │   │   ├── output.sh         # Run-summary rendering (prose + --json), WARNING channel
│   │   │   ├── config.sh         # YAML load/merge (config.yml + config.local.yml), schema validate
│   │   │   ├── credentials.sh    # env → secret manager → .env; curl --config-on-stdin header (NFR-3)
│   │   │   └── prereq.sh         # bash ≥ 4 / curl / jq / git checks; names macOS Bash 3.2 (NFR-4)
│   │   ├── engine/               # NEUTRAL — zero Jira identifiers, never sources sink/ (Constitution VIII)
│   │   │   ├── parse.sh          # spec/plan/tasks → neutral doc (title ladder, description, Gherkin, Design)
│   │   │   ├── interchange.sh    # Build + schema-validate the neutral interchange document
│   │   │   ├── drift.sh          # Status-category-aware drift classification (mapped/post-scope/halted/unknown)
│   │   │   ├── idempotency.sh    # Managed-section diff, zero-churn decision
│   │   │   └── managed_section.sh# Human-content preservation panel logic (US7) + README block edit (US5)
│   │   ├── sink/jira/            # ALL Jira knowledge lives here, behind the sink interface
│   │   │   ├── client.sh         # REST v3 transport, retry/backoff, exit-code mapping
│   │   │   ├── discovery.sh      # Style detection + per-style metadata discovery (US2), estimation heuristic
│   │   │   ├── adf.sh            # Neutral doc → ADF (panels, Gherkin, Design section)
│   │   │   ├── identity.sh       # Entity-property identity marker, per-project scope, origin record
│   │   │   ├── privacy_guard.sh  # BLOCK tier (increment 1) + WARN/allowlist (P3)
│   │   │   └── plan_apply.sh     # Resolve → plan → apply (create/update/transition/comment/link/label)
│   │   ├── commands/
│   │   │   ├── config.sh         # /speckit.jira.config: discovery + hook registration + README block
│   │   │   ├── reconcile.sh      # The reconcile run (hook-invoked and manual)
│   │   │   └── mention.sh        # Mentioned-issue-key read/edit flow (US10)
│   │   └── hooks/                # Hook-registration + README-block writers used by commands/config.sh
│   │       ├── register_hooks.sh # Idempotent after_* registration in .specify/extensions.yml (X)
│   │       └── readme_block.sh   # Version-marked managed README block writer (US5)
│   └── powershell/               # PowerShell 7+ port (Windows) — STRICT module-for-module mirror of bash/
│       ├── spec-kit-jira.ps1     # ← spec-kit-jira.sh
│       ├── lib/                  # Port infrastructure — no domain knowledge
│       │   ├── Cli.psm1          # ← cli.sh
│       │   ├── Output.psm1       # ← output.sh
│       │   ├── Config.psm1       # ← config.sh
│       │   ├── Credentials.psm1  # ← credentials.sh (token in-process, never argv — NFR-3)
│       │   └── Prereq.psm1       # ← prereq.sh (pwsh 7+ check — NFR-4)
│       ├── engine/               # NEUTRAL — zero Jira identifiers, never imports sink/ (Constitution VIII)
│       │   ├── Parse.psm1        # ← parse.sh
│       │   ├── Interchange.psm1  # ← interchange.sh
│       │   ├── Drift.psm1        # ← drift.sh
│       │   ├── Idempotency.psm1  # ← idempotency.sh
│       │   └── ManagedSection.psm1 # ← managed_section.sh
│       ├── sink/jira/            # ALL Jira knowledge lives here, behind the sink interface
│       │   ├── Client.psm1       # ← client.sh
│       │   ├── Discovery.psm1    # ← discovery.sh
│       │   ├── Adf.psm1          # ← adf.sh
│       │   ├── Identity.psm1     # ← identity.sh
│       │   ├── PrivacyGuard.psm1 # ← privacy_guard.sh
│       │   └── PlanApply.psm1    # ← plan_apply.sh
│       ├── commands/
│       │   ├── Config.psm1       # ← config.sh (/speckit.jira.config)
│       │   ├── Reconcile.psm1    # ← reconcile.sh
│       │   └── Mention.psm1      # ← mention.sh
│       └── hooks/
│           ├── RegisterHooks.psm1 # ← register_hooks.sh
│           └── ReadmeBlock.psm1   # ← readme_block.sh
│
├── templates/                    # Extension-owned templates (ADF/description templates, config.yml scaffold)
│   ├── config.yml.template       # Self-documenting scaffold with business-language keys + comments (XVI)
│   └── readme-block.template      # Managed README block body template
│
└── commands/                     # Agent command definition files, installed OUTSIDE .specify/ at add time
    └── speckit.jira.config.md    # The deterministic, model-independent command algorithm (US1)

tests/
├── bash/                         # bats unit suites over the mocked Jira double (per port)
│   ├── lib/ engine/ sink/ commands/
├── powershell/                   # Pester unit suites (per port)
│   ├── lib/ engine/ sink/ commands/
├── conformance/                  # SHARED, language-agnostic equivalence proof (NFR-1, VI)
│   ├── run-scenario.sh           # Harness: run-scenario <scenario.json> <bash|powershell> [outdir]
│   ├── scenarios/*.json          # Byte-identical golden scenarios (both styles, faults, README block)
│   ├── fixtures/                 # Shared spec corpora (with/without ## Summary, Figma, Gherkin)
│   └── mock-jira/                # Mocked Jira double: company-managed + team-managed + 401/404/429/network
└── live/                         # Opt-in live zero-churn suite (real instance, non-blocking on fork PRs)

.github/workflows/                # Three-OS matrix, engine/sink grep gates, coverage gate, version-string grep
```

**Structure Decision**: A **twin-port, single-engine/sink-interface** layout. The two ports (`scripts/bash/` and `scripts/powershell/`) mirror each other **module-for-module — same count, one `*.psm1` per `*.sh`** (22 modules + 1 entry point each) — so the conformance corpus can prove behavioural equivalence (NFR-1). No command is Bash-only (NFR-2): the PowerShell port is not a reduced subset, it is a strict mirror; the only differences are language-idiomatic (PascalCase module names, in-process token handling vs. `curl --config`). A future `git diff`-style module-parity check (same set of leaf names, modulo the `.sh`↔`.psm1` mapping) belongs in the CI gates alongside the engine/sink greps. Within each port, three concentric layers keep the constitution's boundaries mechanically greppable: `lib/` (port infrastructure, no domain knowledge), `engine/` (neutral reconcile — zero Jira identifiers, never sources/imports `sink/`), and `sink/jira/` (all Jira knowledge). The single source of truth for the version is the `version` field of `.specify/extensions/jira/extension.yml` — the metadata already shipped with the extension (FR-021), so no separate version marker is introduced; FR-022 forbids any other hand-maintained version marker, and the pre-existing `.gitignore` entry for `.specify/jira/VERSION.local` will be removed during implementation for the same reason. Everything the extension owns lives under `.specify/extensions/jira/`; Spec Kit core's `.specify/scripts/` and `.specify/templates/` are never touched (FR-055, SC-009).

## Complexity Tracking

No Constitution Check violations require justification. For completeness, the one abstraction the constitution explicitly blesses is recorded here — it is **not** a deviation:

| Abstraction | Why Needed | Why the simpler alternative is rejected |
|-------------|------------|------------------------------------------|
| Engine ↔ Jira-sink interface (neutral interchange document) | Constitution VIII mandates a neutral reconcile engine carrying zero Jira knowledge, with all Jira specifics behind a fixed interface; it has two real realisations (Bash and PowerShell sinks), satisfying Principle XIV's "no abstraction without two implementations". | Inlining Jira calls into the engine would make drift/idempotency logic untestable without a live Jira, violate the grep-enforced boundary of Principle VIII, and couple the reconcile decisions to Atlassian's schema — the exact fragility Principle VII forbids. |
| `kcov` (Bash coverage, dev-only) | No native Bash statement-coverage tool exists; Principle XIII names kcov as the PRIMARY Bash gate with a requirement→scenario traceability FALLBACK on recorded kcov unviability. | Shipping without a coverage gate would break Principle XIII's 80% blocking merge gate. kcov is never a runtime dependency of the shipped scripts. |
