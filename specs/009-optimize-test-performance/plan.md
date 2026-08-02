# Implementation Plan: Optimize Automated Test Performance (macOS / Linux)

**Branch**: `feat/improve-tests-2` | **Date**: 2026-07-31 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/009-optimize-test-performance/spec.md`

## Summary

The Bash test suite (macOS/Linux) is slow because 35 test files each spawn a
fresh PowerShell mock server per test, and the parallel path needs GNU `parallel`
(silently running zero tests without it). CI compounds this by reinstalling
toolchains on every job across three OSes, running the 51-scenario conformance
corpus on **all three** of them (008 promoted it from a Linux-only job to a step
of the `unit` matrix job), and running a 20–35 min kcov gate against a
`timeout-minutes: 30` ceiling.

The plan removes the per-test PowerShell cost by replacing the mock's *backend*
for the Bash port with a scripted `curl` shim (pure `bash`+`jq`, no socket, no
process) reached through the existing `mock_start`/`mock_stop`/`mock_calls`
contract — so one file change migrates all 35 test files. It adds a
dependency-free parallel runner (`xargs -P`, never GNU `parallel`, never a false
green). It cuts CI cost through caching and targeted installs. Every test still
runs, the 80% coverage floor and its denominator are untouched, and the
conformance corpus still proves byte-for-byte cross-port parity — now with the
shim continuously cross-checked against the real pwsh mock.

## Technical Context

**Language/Version**: Bash ≥ 4 (port requirement; macOS needs Homebrew bash);
PowerShell 7+ (port + conformance mock only). Test tooling: `bats` (bats-core),
`jq`.

**Primary Dependencies**: Runtime for tests — `bats`, `jq` only (Bash suite).
Conformance/coverage additionally use PowerShell 7+ and `kcov` (Linux CI).
`curl`, `git` are port prerequisites.

**Storage**: N/A (filesystem fixtures under `tests/conformance/mock-jira/`).

**Testing**: `bats` (Bash unit + conformance-bash), Pester (PowerShell),
language-agnostic conformance corpus diffed across ports, kcov (Bash coverage).

**Target Platform**: macOS + Linux (primary optimization target); Windows
(PowerShell port, must not regress). CI = GitHub Actions three-OS matrix.

**Project Type**: CLI / script-native tooling (Bash + PowerShell twin ports).

**Performance Goals** (absolute budgets — see research.md Decision 9): full Bash
suite ≤ 5 min locally (SC-001); change-scoped run ≤ 60 s (SC-001b);
`coverage-bash` ≤ 15 min (SC-004); push → merge decision ≤ 20 min (SC-005);
runner-minutes below the `21068d6` reference (SC-005b).

**Constraints**: Full Bash suite runs with only `bats`+`jq` (SC-002, Bash port
scope); never a false green (SC-003); every gate/verdict preserved (SC-006); zero
tests removed — ≥ 955 `@test`s (SC-007); coverage ≥ 80% both ports, denominator
not shrunk (SC-008); green over 5 local / 20 nightly parallel runs (SC-009);
parity detection unimpaired (SC-010); **Windows keeps Pester + all 51 conformance
scenarios, blocking (SC-011)**; **shards stay within one OS — never across
(FR-018)**.

**Scale/Scope** (measured on the 008 merge commit `21068d6`): **955** Bash
`@test`s / **115** files (**35** mock-dependent); **51** conformance scenarios,
now exercised on all three OSes; **96** PowerShell `.Tests.ps1` files (parity,
unchanged behavior).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| # | Principle | Gate verdict |
| --- | --- | --- |
| I | Filesystem source of truth | PASS — no reconcile/write behavior changes; test infra only. |
| II | Zero-Churn Idempotency | PASS — mocked idempotency/zero-churn scenarios keep running (FR-004/006); live suite untouched. |
| III | Fail-Closed on Writes | PASS — no write/hook path changes; CI "fail-open on uncertainty" applies only to skipping test work, never to writes, and never hides a regression (FR-009). |
| IV | Credential Security | PASS — the `curl` shim adds no credential to any file/log; `jira_request`'s xtrace suspension and the coverage tracer's secret handling are preserved (the token-never-traced test still runs). |
| V | Config / Binding / Secrets separation | PASS — unaffected. |
| VI | macOS/Linux/Windows Portability | PASS — three-OS matrix stays a merge gate; conformance byte-equality preserved and now cross-checks shim vs pwsh mock (FR-006/011/013). |
| VII | No hard-coded Jira workflow | PASS — non-default (team/company) fixtures preserved and served by both mock backends. |
| VIII | Neutral engine / sink | PASS — engine/sink separation and its CI greps untouched (FR-010). |
| IX | Two-tier privacy guard | PASS — privacy tests unchanged (FR-004). |
| X | Self-healing mirror | PASS — hook tests unchanged; FR-015 supplies the regression test for the zero-tests defect. |
| XI | Dry-run & auditability | PASS — dry-run tests unchanged (FR-004). |
| XII | Quality & catalog publication | PASS — mocked suites, lint, coverage stay blocking on all three OSes; live-suite fork rule untouched (FR-010/011). |
| XIII | TDD ≥ 80% coverage + isolation | PASS — floor and denominator unchanged (FR-005/SC-008); shim state isolated by recorded temp dir; green-under-parallel (FR-007/SC-009); tests-first for the runner and shim (FR-015). |
| XIV | KISS | PASS with one tracked item — a second mock implementation (the shim); see Complexity Tracking. Net complexity drops (a cross-runtime dependency and a fragile parallel path are removed). |
| XV | YAGNI | PASS — only the optimizations needed for the goals; test-tiering and prebuilt images are Out of Scope/deferred. |
| XVI | Human Readable | PASS — run-the-tests docs updated (FR-014); the runner and shim emit named, actionable failures (FR-003). |

**Initial gate: PASS** (one justified complexity item, below).
**Post-design gate: PASS** (re-evaluated after Phase 1; no new violations).

## Project Structure

### Documentation (this feature)

```text
specs/009-optimize-test-performance/
├── plan.md              # This file
├── spec.md              # Feature spec
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (test-infra interface contracts)
│   ├── mock-driver.md
│   ├── curl-shim.md
│   └── test-runner.md
└── checklists/
    └── requirements.md  # Spec quality checklist (from /speckit-specify)
```

### Source Code (repository root)

```text
tests/
├── run-bash.sh                         # NEW — dependency-free parallel runner (Decision 3)
├── conformance/
│   ├── ci-conformance.sh               # READ — CI entry point since 008; already shards via
│   │                                   #        SPEC_KIT_JIRA_SHARD_TOTAL / _INDEX
│   ├── run-scenario.sh                 # EDIT — bash port → shim; pwsh port → real server (Decision 2)
│   └── mock-jira/
│       ├── lib.sh                      # EDIT — the six public mock_* functions backed by the curl
│       │                               #        shim for the bash port (incl. mock_issue_field,
│       │                               #        which requires session state — see Open Question 1)
│       ├── curl-shim.sh                # NEW — scripted curl replacement + router over existing fixtures (Decision 1)
│       ├── mock-server.ps1             # UNCHANGED — real server for the PowerShell port
│       ├── Mock.psm1                   # UNCHANGED — pwsh driver
│       ├── configs/*.json              # UNCHANGED — reused by both backends
│       └── fixtures/*.json             # UNCHANGED — reused by both backends
├── coverage/
│   └── bash-coverage.sh                # EDIT (minimal) — exercise uses the shim path; denominator/threshold unchanged
├── bash/                               # 35 mock-driving files UNCHANGED (reach the mock only via lib.sh),
│   │                                   # incl. 008's sink/test_hierarchy.bats and
│   │                                   # commands/test_reconcile_hierarchy.bats (9 mock_issue_field calls)
│   └── ci/
│       ├── test_run_bash_runner.bats   # NEW — FR-003/FR-015 regression: runner without GNU parallel runs all tests, never 0
│       └── test_mock_shim_contract.bats# NEW — shim honors the mock-driver contract (routing, faults, call log)
└── powershell/                         # UNCHANGED (parity path, 96 .Tests.ps1 files)

.github/workflows/
├── ci.yml                              # EDIT — call run-bash.sh; cache Pester + specify-cli; targeted install; drop parallel/pwsh from bash run
├── gates.yml                           # EDIT — coverage job inherits shim speedup; caching; keep all gates/thresholds
├── boundary.yml                        # REVIEW — same avoidable reinstalls (T018)
├── windows-conformance.yml             # UNTOUCHED — manual probe (push: ci/windows-probe + workflow_dispatch), not a merge gate
└── live.yml                            # UNTOUCHED — real-Jira suite, never a fork-PR gate (Out of Scope)
```

**Structure Decision**: Script-native test infrastructure. All changes are
confined to `tests/` and `.github/workflows/`. Production code under
`scripts/bash/**` and `scripts/powershell/**` is **not touched** — the single
HTTP chokepoint `jira_request()` is exercised unchanged, guaranteeing coverage
and behavior parity are preserved by construction.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Two mock implementations (pwsh `mock-server.ps1` + Bash `curl-shim.sh`) | SC-002 requires the full Bash suite to run with only `bats`+`jq`; a real socket server needs a runtime Bash/`jq` cannot provide. The PowerShell port needs a real server regardless, so the pwsh mock must stay. | A single mock cannot satisfy both "no runtime beyond bats+jq for the Bash fast path" and "a real socket for the native pwsh port". A per-file pwsh mock still requires PowerShell (fails SC-002). The two implementations are kept honest by the conformance diff, which fails on any response divergence between them. |
