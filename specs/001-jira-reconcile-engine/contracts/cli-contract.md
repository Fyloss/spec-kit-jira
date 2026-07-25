# Contract: CLI Surface, Flags, and Exit Codes

**Feature**: 001-jira-reconcile-engine | **Parity**: NFR-1 (both ports identical)

The command surface, flags, and exit-code table below are **identical** on both ports (Bash `spec-kit-jira.sh`, PowerShell `spec-kit-jira.ps1`). Every value here is asserted byte-identically by the conformance corpus; a divergence is a failing test (NFR-1), not a documented quirk.

## Commands

| Command | Purpose | Story |
|---------|---------|-------|
| `config` | The single installation ceremony: metadata discovery **+** idempotent `after_*` hook registration **+** managed-README-block management, reported as three separate effects (FR-054). Deterministic and model-independent (US1); byte-identical re-run (FR-003). Invoked by the agent command `/speckit.jira.config`. | US1, US2, US4, US5, US9 |
| `reconcile` | Mirror the spec corpus (or one spec) into Jira. Hook-invoked and manually runnable. Idempotent (FR-030), drift-aware (FR-031/FR-034), fail-closed (FR-032). | US3, US6, US7, US8 |
| `mention` | Read/edit a specific mentioned issue key: stamp identity, update only that ticket, log mutations (US10). | US10 |

## Global flags (every write-capable command)

| Flag | Effect | FR / Principle |
|------|--------|----------------|
| `--dry-run` | Produce the exact action set the real run would perform; no Jira mutation. The report equals the real run's actions. | FR-033, XI |
| `--json` | Emit the run summary as JSON (`run-summary.schema.json`) instead of the default prose. | NFR-5, XVI |
| `--on-drift=<abort\|proceed>` | `abort` (default) refuses to pull a ticket backward from a `post-scope` status; `proceed` (or an explicit confirmation) allows it. | FR-035 |
| `--verbose` | Extra diagnostics. The resolved token NEVER appears, even here (NFR-3, SC-007). | NFR-3 |
| `--help` | Usage; exits `0`. | XVI |

`config` additionally accepts `--repair-hooks` (one-command hook repair, FR-047). `mention` requires an issue key argument (`mention PROJ-123`).

## Exit-code table (monotonically escalating — Constitution III)

A more severe failure never maps to a lower code. The table is shared by both ports and asserted by the conformance corpus.

| Code | Meaning | Trigger | FR / Principle |
|------|---------|---------|----------------|
| `0` | Success | Run completed; includes a zero-write idempotent re-run. | FR-030 |
| `1` | Usage / generic error | Bad flag, missing argument, unreadable config. | XVI |
| `2` | Per-spec fail-closed (unreliable read) | Network error, 404, or 429 after exhausted retries — zero writes for the affected spec. | FR-032, III |
| `3` | Authentication failure | 401/403. Zero writes. | FR-032, III |
| `4` | Configuration / capability refusal | e.g. a team-managed mapping requiring a level above Epic — refused at config time (FR-007); malformed README markers (FR-027); credential-shaped value in YAML (FR-023). Zero writes. | FR-007, FR-023, FR-027 |
| `5` | Prerequisite failure | Bash < 4 (macOS 3.2 named explicitly), missing `curl`/`jq`/`git`, or `pwsh` < 7 — fails **before** any Jira interaction. | NFR-4, VI |
| `9` | **Privacy BLOCK** (dedicated, highest) | The pre-write guard matched a known coordinate / ATATT prefix / real `*.atlassian.net` host. Zero writes. | FR-052, IV, IX |

**Hook context override (Constitution III / FR-046)**: when `reconcile` runs from an `after_*` hook, any non-zero condition is downgraded to a **single actionable WARNING** and the hook returns success to the host command — the host command's exit code is never affected. The underlying code is still recorded in the run summary for diagnostics.

## Determinism & parity guarantees

- `config` run twice on an unchanged project ⇒ byte-identical `config.yml` (FR-003, SC-004); same on either port.
- Any repository-written output (managed README block, neutral interchange document, `--json` summary) is byte-identical between ports (Constitution VI, SC-003/SC-005).
- Every operator decision in `config` is a closed, enumerated question; no step is left to model judgement (US1, FR-001).
