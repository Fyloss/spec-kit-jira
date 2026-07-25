# Quickstart & Validation Guide: Jira Reconcile Engine

**Feature**: 001-jira-reconcile-engine | **Date**: 2026-07-23

This guide proves the feature works end-to-end. It is a **validation/run guide**, not an implementation manual — implementation detail belongs in `tasks.md`. Data shapes are in [data-model.md](./data-model.md); interfaces and codes in [contracts/](./contracts/). Every scenario below maps to a Success Criterion (SC-00x) or an Independent Test in the spec.

## Prerequisites

| Port | Runtime | Dev/test tooling |
|------|---------|------------------|
| Bash (macOS/Linux) | **bash ≥ 4** (macOS ships 3.2 — install a qualifying bash), `curl`, `jq`, `git` | `bats`, `kcov`, `shellcheck`, `shfmt` |
| PowerShell (Windows) | **pwsh 7+**, `git` | `Pester` 5, `PSScriptAnalyzer` |

Credentials (live/dogfood scenarios only) resolve via **env → OS secret manager → gitignored `.env`** (NFR-3). Never place a token in a tracked file. Most scenarios below run against the **mocked Jira double** and need no credentials.

```bash
# Bash port prerequisite check (must name macOS bash 3.2 explicitly and exit 5 if unmet — NFR-4/SC via exit code 5)
# (source-repo path; in a consuming repo the entry lives under .specify/extensions/jira/)
scripts/bash/spec-kit-jira.sh --help
```

## Scenario A — Deterministic config (US1, SC-004)

```bash
# Run the config command twice against an unchanged project (mocked double)
spec-kit-jira config
spec-kit-jira config
git diff --exit-code .specify/jira/config.yml      # expect: no diff (byte-identical, FR-003)
```
**Expected**: second run rewrites nothing; the run summary reports the three effects — discovery / hooks / README — **separately** (FR-054). Running the same on the PowerShell port yields the identical `config.yml`.

**Verify determinism of the command file**: every step in `commands/speckit.jira.config.md` is an API-read, a config-read, or a closed enumerated question — no model-judgement step (US1 Independent Test).

## Scenario B — Company-managed AND team-managed discovery (US2)

```bash
# Point routing at a company-managed fixture and a team-managed fixture
spec-kit-jira config       # answers the closed questions for each project
```
**Expected**: the company-managed project is discovered through site-level scheme endpoints; the team-managed project through project-scoped endpoints with the estimation field located by heuristic and **operator-confirmed** (never the global Story Points field). Configuring a hierarchy level above Epic on the team-managed project is **refused at config time** with the limitation named and the project style — exit code **4** (FR-007).

## Scenario C — Rich, reliable ticket content (US3, SC-002)

```bash
# Corpus includes specs WITH and WITHOUT a ## Summary section
spec-kit-jira reconcile --dry-run
```
**Expected**: every planned Story has a non-empty title from the ladder (FR-013), a non-empty structured description even without `## Summary` (FR-014), Gherkin criteria in a panel wherever the source has any (FR-015), and Figma/UX guidance in a Design section (FR-016). Estimation appears in the **create** action only; a subsequent update never re-sends it (FR-018).

## Scenario D — Committable config, secrets separated, single-sourced version (US4, SC-006)

```bash
spec-kit-jira config
grep -R --exclude-dir=.git -nE '(^|/)VERSION|v?[0-9]+\.[0-9]+\.[0-9]+' \
  . ':!extension.yml' ':!CHANGELOG.md'              # expect: no version string outside the single source (SC-006)
# Attempt a credential-shaped value in either YAML layer -> schema rejects it (exit 4, FR-023)
```
**Expected**: `config.yml` at the repo root contains zero credentials; personal overrides live in gitignored `config.local.yml`; the only version source is the manifest's `extension.version` field in `extension.yml` (FR-021/022). Reinstalling the extension destroys neither `config.yml` nor the hooks (SC-008).

## Scenario E — Managed README block, byte-exact & CRLF-safe (US5, SC-005)

```bash
# Fixtures: block present / absent / malformed / CRLF
spec-kit-jira config
git diff README.md                                  # only bytes BETWEEN markers changed
```
**Expected**: only the content strictly between the markers is replaced; every byte outside is preserved (CRLF-safe); a malformed marker pair produces **zero writes** and a located error naming line numbers (exit 4, FR-027); an absent README is created containing only the block; block content adopts the host's dominant line-ending, so the file never becomes mixed-ending (SC-005). Both ports produce byte-identical block content.

## Scenario F — Idempotency, drift & lifecycle safety (US6, SC-001)

```bash
spec-kit-jira reconcile                             # first run creates
spec-kit-jira reconcile                             # second run
```
**Expected**: the second run issues **zero** Jira writes of every kind (FR-030). A ticket advanced Jira-side raises a **named** drift warning, never a silent overwrite (FR-031). Category-aware drift: `post-scope` is never backward drift (a regression aborts the transition unless `--on-drift=proceed`); `unknown` is named with a classify suggestion; `halted` stops all writes and surfaces the orphaned spec with two remediations (FR-034/FR-035). A Flagged ticket has transitions withheld and the flag surfaced (FR-036); open blocking links are named as info without gating (FR-037). Injecting each fault (401/404/network/429-exhausted) yields zero writes for that spec and the documented exit code (2 or 3).

## Scenario G — Human content never overwritten (US7)

```bash
# On a human-origin ticket, write human text, then reconcile repeatedly
spec-kit-jira reconcile ; spec-kit-jira reconcile
```
**Expected**: bridge content is written only inside the delimited managed panel; human text above it is byte-preserved permanently, including after the human edits it (FR-038); the idempotency diff is computed on the managed section alone (FR-039). On a bridge-created ticket the whole description is the managed section with no delimiters (FR-040).

## Scenario H — Multi-project routing (US8)

```bash
# Route one spec to a company-managed project, another to a team-managed one
spec-kit-jira reconcile
```
**Expected**: each spec reconciles exclusively to its assigned project with that project's own style, discovery results, and workflow mapping (FR-041/FR-042). Re-running `config` to add a project binds only that project, leaving existing mappings untouched (FR-043). Identities are per-project scoped so two teams never collide (FR-044).

## Scenario I — Self-healing hooks (US9, SC-008)

```bash
# Fire each after_* hook with a forced bridge failure
# then delete a hook entry and re-run
spec-kit-jira config --repair-hooks
```
**Expected**: a bridge failure inside a hook surfaces **at most one** WARNING and never fails the host command (FR-046); every run reports hook health (FR-047); a missing hook is repaired in one command and reinstalled automatically by `config`; a hook the operator set `enabled: false` stays disabled through upgrade/reinstall/repair (FR-048).

## Scenario J — Mentioned-ticket editing (US10)

```bash
spec-kit-jira mention PROJ-123
```
**Expected**: the bridge fetches the ticket's content, linked Confluence pages (title + URL only), parent context, and a one-line sibling list; stamps identity; updates only that ticket; logs every mutation (FR-049/FR-050). A ticket already carrying another spec's identity ⇒ zero writes + actionable refusal (FR-051).

## Scenario K — Privacy guard BLOCK tier (US11, SC-007)

```bash
# Fixtures: a known coordinate, the ATATT prefix, a real *.atlassian.net host
spec-kit-jira reconcile
```
**Expected**: each blocks with the **dedicated exit code 9** and zero writes (FR-052); the BLOCK tier is active on every write in the P1/P2 increment (no gap). The resolved token never appears in argv, logs, errors, or traces at maximum verbosity, on either port (SC-007). *(P3: a generic email warns but does not block; an allowlisted Confluence link passes silently — FR-053.)*

## Cross-port equivalence & coverage (NFR-1, Constitution XIII)

```bash
# Conformance corpus: run each scenario on both ports and diff outputs
tests/conformance/run-scenario.sh tests/conformance/scenarios/<scenario>.json bash   /tmp/out-bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/<scenario>.json powershell /tmp/out-ps
diff -r /tmp/out-bash /tmp/out-ps                   # expect: identical (action set, exit code, summary)
```
**Expected**: byte-identical outputs across ports (SC-003). Statement coverage on the mocked unit suites ≥ 80% (kcov for Bash / Pester CodeCoverage for PowerShell), blocking; critical paths (drift, idempotency, fail-closed, privacy guard, credential resolution) near 100%.

## Engine/sink boundary (Constitution VIII)

```bash
# CI greps (must both pass): engine never imports the sink; engine contains no Atlassian identifier
tests/conformance/check-engine-boundary.sh          # expect: exit 0
```

## Done when

All scenarios A–K pass on the mocked double for both ports, the conformance corpus is byte-identical across ports, the engine/sink boundary greps pass, coverage ≥ 80%, and `git diff .specify/scripts .specify/templates` is empty after a full install + config run (SC-009).
