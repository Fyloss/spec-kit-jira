# Implementation Plan: Retire the .env credential file

**Branch**: `feat/improve-security` (spec dir `030-retire-env-credentials`) | **Date**: 2026-08-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/030-retire-env-credentials/spec.md`

## Summary

Cut the credential chain from three rungs to two — environment variable, then
an operator-declared retrieval command executed without a shell — deleting both
the `.specify/jira/.env` reader and the hardcoded `spec-kit-jira` secret-store
probe. Move the Jira base URL into the tracked `config.yml` (team-shared) and
the operator email into the gitignored `personal.yml` (per-operator), and have
the `config` ceremony create `personal.yml` when absent.

The technical approach turns on one measurement: `SPEC_KIT_JIRA_BASE_URL` is
read at **72 sites across 28 files** in the two ports. Rewriting those readers
is not an option. Instead a single **resolution chokepoint** at command entry
seeds the process environment from the files, and every existing reader stays
byte-for-byte unchanged. The feature therefore concentrates in five modules per
port (credentials, config, the config command, and the two entry points),
not in the twenty-eight that mention the variable.

## Technical Context

**Language/Version**: Bash 4.2+ (macOS/Linux) and PowerShell 7+ (Windows) — two
native ports, no shared runtime, proven equivalent by a conformance corpus.

**Primary Dependencies**: `curl`, `jq`, `git` (Bash port); built-in cmdlets only
(PowerShell port). This feature adds **none** — the retrieval command is a
program the operator already has.

**Storage**: YAML configuration files under `.specify/jira/` plus the OS
credential store, which the extension reads through an operator-supplied
command and never writes.

**Testing**: `bats` (Bash, `tests/run-bash.sh`), Pester (PowerShell), and
`tests/conformance/ci-conformance.sh` for cross-port byte equivalence.
`shellcheck` and `actionlint` are blocking gates.

**Target Platform**: macOS, Linux, Windows — all three are merge gates.

**Project Type**: CLI bridge invoked by Spec Kit lifecycle hooks.

**Performance Goals**: No regression against the spawn budget. Credential
resolution stays at **most one retrieval-command execution per run** (FR-010);
the two new file reads ride on config loads that already happen.

**Constraints**: The retrieval command runs where nobody can answer a prompt, so
its wait is bounded at **5 seconds** — the same literal in both ports, because
the failure message names it (FR-009, `research.md` §R3). No `jq` call may be
added to the reconcile path per item (`docs/11-process-budget.md`). No `$'\r\n'`
inside a glob pattern (`docs/10-windows-portability.md`).

**Scale/Scope**: 41 functional requirements; ~5 modules changed per port, plus
the retirement of the test artifacts that exercised the two deleted rungs. The
constitutional amendment this feature required is ratified (v2.0.0).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### ✅ GATE PASSED — via Constitution v2.0.0, ratified 2026-08-18

Constitution v1.3.0, Principle IV stated three things this feature contradicted.
The spec template is explicit that a conflict is not diluted in the Constitution
Check: *the feature is redesigned, or the constitution is amended separately.*
The constitution was amended separately — **v1.3.0 → v2.0.0 (MAJOR)**, amending
Principles IV and V. The table below records what was in conflict and how the
amendment resolved each point; nothing here is outstanding.

| # | Constitutional text (v1.3.0) | Conflicted with | Resolved in v2.0.0 by |
| --- | --- | --- | --- |
| IV-a | "No token, authentication email, real site URL, or accountId may ever enter a **tracked** file, including test fixtures." | FR-012 puts the real site URL in `config.yml`, which is tracked. | ✅ Permitting the site URL at one named key of the team config. The token, the email and the accountId prohibitions stay untouched. |
| IV-b | "Credentials MUST be resolved in this order: environment variables → OS secret manager → gitignored `.env`." | FR-001 resolves through two rungs; FR-002 deletes the `.env` rung. | ✅ Two rungs — environment variable, then operator-declared retrieval command; plus a new rule forbidding both a file rung and an undeclared probe. |
| IV-c | "The OS secret manager rung is SOFT-OPTIONAL … an absent tool or module, an unregistered or locked store, and a missing entry MUST each fall through silently to the next rung. That rung MUST NEVER … raise an error." | FR-007 fails loudly when a declared retrieval command fails, is absent, or returns nothing. | ✅ Silence applies when **nothing is declared**; once the operator declares a retrieval command, a failure is reported rather than swallowed. The no-prompt, no-hang rule is preserved and reinforced by FR-009's bound. |

**Not a conflict.** Replacing `security` / `secret-tool` / `Get-Secret` with an
operator-declared command needs no amendment: IV already says *"A platform's
mechanism MAY be replaced by another satisfying that same requirement without
amending this principle — the requirement is the rule, the mechanisms are how it
is met."* A retrieval command reading the Keychain satisfies "a store the OS
encrypts at rest and that the bridge reads at run time".

**Also not a conflict — a worry checked and dismissed.** IV's fourth bullet
mandates "a pre-write guard MUST scan the tracked tree and block … on any leak
of a known coordinate". That guard is `sink/jira/privacy_guard.sh`, and it scans
the **payload written to Jira**, not the tracked tree. A base URL in `config.yml`
therefore does not trip it, and consumers will not find every write blocked.

### Remaining principles

| # | Principle | Gate status |
| --- | --- | --- |
| I | Filesystem Is the Source of Truth | ✅ No new exception. The token leaves the filesystem; the two settings use existing surfaces. |
| II | Zero-Churn Idempotency | ✅ `personal.yml` is created once and never rewritten (FR-025/FR-028/FR-031); `config.yml` is never written (FR-015). Both ports' writers are already deterministic fixed points of their readers. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | ✅ Every new failure path refuses before a write or a network call. FR-009's bound is what keeps a hook from hanging. |
| IV | Credential Security | ✅ Satisfied under v2.0.0. See the table above for what changed and why. |
| V | Separation of Team Config / Local Binding / Secrets | ✅ Satisfied under v2.0.0, which also added `personal.yml` as a named third layer (it had shipped since feature 002 but was never listed). The secret leaves the tree and the email lands in the per-operator layer — both strengthen the separation; only the site URL moves the other way. |
| VI | macOS / Linux / Windows Portability | ✅ Mirrored change in both ports, proven by new conformance scenarios. Windows needs the documented cmdlet-vs-executable note (FR-034). |
| VII | No Hard-Coded Jira Workflow Assumptions | ✅ Unaffected. |
| VIII | Neutral Engine / Jira Sink | ✅ `lib/credentials` stays Jira-free (Basic auth is generic). The base URL and email stay on the sink side. No `engine/` file is touched — the boundary gate stays green. |
| IX | Two-Tier Privacy Guard | ✅ Untouched, and confirmed not to interact with FR-012 (above). |
| X | Self-Healing Automatic Mirror | ✅ Strengthened: FR-024 repairs a missing `personal.yml`, FR-027 stops the repaired file from becoming a new refusal. |
| XI | Universal Dry-Run and Auditability | ✅ FR-026 puts the new write behind `--dry-run`; FR-030 adds it to the effects JSON. |
| XII | Quality and Catalog Publication | ✅ Both suites, conformance, `shellcheck`, `actionlint` stay blocking. |
| XIII | TDD With ≥80% Coverage | ✅ Every acceptance scenario is executable; cross-port behaviour goes to the conformance corpus, not to per-port unit tests. |
| XIV | KISS | ✅ The chain gets shorter. The chokepoint (below) is what keeps a 72-site variable from becoming a 72-site edit. |
| XV | YAGNI | ✅ No migration, no rotation, no store provisioning, no OAuth. |
| XVI | Human Readable | ✅ The created `personal.yml` documents its own schema in comments, including the team ids on offer. |

## Key design decision — the resolution chokepoint

Measured surface of the two non-secret settings:

| Variable | References | Files |
| --- | --- | --- |
| `SPEC_KIT_JIRA_BASE_URL` | 72 | 28 |
| `JIRA_EMAIL` | 8 | 6 |
| `JIRA_API_TOKEN` | 12 | 4 |

Every one of those readers uses the same shape — `${SPEC_KIT_JIRA_BASE_URL:-}`
or `$env:SPEC_KIT_JIRA_BASE_URL`. So the file-sourced values are **exported into
the process environment once**, immediately after `config_load`, by a new
`config_resolve_connection` / `Resolve-JiraConnection`. Environment-first
ordering (FR-013, FR-017) falls out for free: the chokepoint only writes the
variable when it is unset or empty.

This is the entire reason the feature is tractable. The alternative — teaching
28 files to consult a config object — is rejected in `research.md` §R1.

## Project Structure

### Documentation (this feature)

```text
specs/030-retire-env-credentials/
├── plan.md              # This file
├── research.md          # Phase 0 — 9 decisions
├── data-model.md        # Phase 1 — entities, schemas, validation rules
├── quickstart.md        # Phase 1 — runnable validation guide
├── contracts/
│   ├── credential-resolution.md   # The two-rung contract, both ports
│   ├── connection-settings.md     # base_url / email resolution + schemas
│   └── personal-config-creation.md # The config ceremony's new effect
├── checklists/
│   └── requirements.md  # Spec quality checklist (16/16)
└── tasks.md             # /speckit-tasks output — NOT created here
```

### Source code (repository root)

```text
scripts/bash/
├── lib/
│   ├── credentials.sh          # CHANGED — two rungs; delete _cred_from_env_file
│   │                           #   and _cred_from_secret_manager; add the
│   │                           #   tokenized-exec retrieval command + timeout
│   └── config.sh               # CHANGED — base_url in the config.yml schema;
│                               #   email in the personal schema; team made
│                               #   optional-when-absent; per-key exemptions in
│                               #   _cfg_credential_errors; config_resolve_connection
├── commands/
│   └── config.sh               # CHANGED — _config_personal_effect (create +
│                               #   report), runs before the degraded return;
│                               #   AND the degraded-mode trigger, which today
│                               #   discards a declared command's failure (FR-038)
└── sink/jira/client.sh         # CHANGED — emit the credential error that the
                                #   silent `rc=auth` path swallows today

scripts/powershell/
├── lib/
│   ├── Credentials.psm1        # CHANGED — mirror of the above
│   └── Config.psm1             # CHANGED — mirror of the above
├── commands/Config.psm1        # CHANGED — ceremony effect + the same
│                               #   degraded-trigger fix (Config.psm1:1043)
└── sink/jira/Client.psm1       # CHANGED — mirror of the error emission

tests/
├── bash/lib/                   # credential + config unit tests
├── powershell/lib/             # Credentials.Tests.ps1, PersonalConfig.Tests.ps1
├── bash/helpers/               # RENAMED — the counting secret-store PATH shim
├── powershell/helpers/         #   becomes the retrieval-command shim (C7.1)
├── bash/commands/, powershell/commands/
│                               # CHANGED — the .env / probe assertions in
│                               #   test_credentials.bats, Credentials.Tests.ps1,
│                               #   test_reconcile_credential_cache.bats and the
│                               #   two gitignore test files
├── conformance/
│   ├── run-scenario.sh         # CHANGED — @MOCK_BASE_URL@ substitution (R6)
│   │                           #   and @PAT_HANG_COMMAND@ over env values (R11)
│   ├── fixtures/               # NEW — repo-with-base-url, repo-no-personal
│   └── scenarios/              # NEW — us030-*.json
└── ...

docs/                           # 07-configuration-and-secrets.md rewritten;
                                # CREDENTIALS.md new; 04-config-ceremony.md,
                                # 01-system-context.md, 03-lifecycle-hooks.md,
                                # README.md, INSTALL.md, CHANGELOG.md updated
.specify/memory/constitution.md # AMENDMENT — v1.3.0 → v2.0.0, Principle IV
```

**Structure Decision**: The existing two-port layout is kept unchanged. No new
module is introduced in either port: credential work stays in `lib/credentials`,
schema and resolution work in `lib/config`, and the ceremony effect in
`commands/config`, each alongside the code it extends. Adding a module would
split credential resolution across two files for no gain — rejected under
Constitution XIV.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| **Constitution IV-a** — the real site URL enters a tracked file | The operator's explicit decision: the base URL is identical for every team on the site, so the committed team config is where a team agrees it once, and it removes a per-developer shell-profile step that the agent's spawned shells do not reliably load. | Keeping it in `personal.yml` or `config.local.yml` (both gitignored) means every developer re-declares the same value, which is what the operator asked to eliminate. Keeping it env-only is the status quo the feature exists to replace. The URL is not a secret and grants nothing without a token. |
| **Constitution IV-b** — two rungs instead of three | The `.env` rung is the exposure the feature removes: a plaintext token in the workspace, readable by any agent and one `git add -A` from being committed. | A deprecation window ships the known exposure for another release cycle. There is exactly one user of the extension today (spec Assumptions), so the migration cost of removing it outright is one operator action. |
| **Constitution IV-c** — a declared retrieval command fails loudly | Silence here reproduces the defect the Figma extension documents: the operator is told "no token configured" for a token that is correctly stored, and debugs the wrong thing. | Falling through silently is correct only when there is no next rung to fall to. With two rungs and nothing after the command, silence means failing unauthenticated with a misleading message. |
| **Moving the gitignore effect before the degraded-mode return** | The fresh-setup case *is* degraded mode (no base URL, no token yet) — precisely when `personal.yml` must be created. Creating a gitignored file requires its ignore rule to exist. | Creating the file only in full mode means an operator needs Jira credentials to obtain the file that declares their credentials. Duplicating the gitignore logic inside the personal effect splits one rule across two call sites. See `research.md` §R5 — this changes `us2-degraded-mode`'s expected output and that scenario must be updated. |
| **A scheme exception for loopback hosts** (FR-039) | Plain `http` is refused because Basic auth would cross the network in clear text; on loopback it crosses nothing, so the reason for the rule is absent. It is also what makes the rule's own happy path testable: the conformance mock is `http://127.0.0.1:<port>`, and a rule refusing every `http` would refuse the fixture that proves a config-sourced base URL reaches a request. | Giving the mock TLS means certificates to generate and trust on three operating systems, for a corpus built to have no moving parts. Exempting the fixture from validation makes the scenario assert the opposite of shipped behaviour. Dropping the scheme check loses the protection that matters — a team config committing `http://jira.example.com`. See `research.md` §R10. |
| **The ceremony reports a declared failure but does not refuse** (FR-038) | Constitution IV requires a declared command's failure to be reported, never swallowed. It does not require it to be fatal — and refusing inside the config ceremony would withhold from the operator the very file in which they declare their settings, contradicting `personal-config-creation.md` §1. | Making it fatal breaks fresh setup, which is the case the ceremony exists to serve. Leaving it silent is the defect itself: `config` is the command an operator runs *because* credentials misbehave, and today it discards the reason on both ports. |

## Phase 0 — Research

Complete. See [research.md](./research.md): 11 decisions covering the chokepoint
(R1), the tokenized exec and its timeout (R2, R3), the per-key guard exemption
(R4), the ceremony ordering and its degraded-mode consequence (R5), conformance
testability of a config-sourced base URL (R6), the optional-`team` fix (R7), the
YAML-cache interaction (R8), the constitutional amendment (R9), the loopback
scheme exception that keeps R6's fixture loadable (R10), and how the five
credential-failure classes are staged in the corpus (R11).

No `NEEDS CLARIFICATION` remains in the Technical Context.

## Phase 1 — Design & Contracts

Complete. [data-model.md](./data-model.md) fixes the two schema additions, the
validation rules, and the resolution precedence table.
[contracts/](./contracts/) holds the three contracts the ports must both satisfy
byte-for-byte. [quickstart.md](./quickstart.md) is the runnable validation guide.

**Post-design Constitution re-check**: unchanged from above. The design
introduces no violation beyond the three the amendment covers, and the
chokepoint keeps the blast radius inside five modules per port.
