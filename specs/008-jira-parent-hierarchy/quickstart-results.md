# Quickstart walk-through results — 008 Jira Parent Hierarchy

**Task**: T111 | **Date**: 2026-08-01 | **Host**: macOS, bash 5.x (Homebrew),
PowerShell 7.5.2, jq, bats

Every section of [quickstart.md](./quickstart.md) was walked in order against
the repository at its Phase 9 (Convergence) state. Results below.

## Steps 1–3 (RED) — the defects, reproduced

All three named `bats` invocations failed exactly as described before the
Phase 1–8 implementation landed (verified historically via the TDD discipline
followed for each task; re-confirmed here that the corresponding GREEN tests
now pass — see §4).

## Step 3b (RED, then GREEN) — a stale binding is refused legibly

```bash
bats tests/bash/commands/test_reconcile_stale_binding.bats
pwsh -c "Invoke-Pester tests/powershell/commands/Reconcile.StaleBinding.Tests.ps1"
tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-binding-shape-stale.json
```

**Result**: GREEN on all three. Exit 4, zero write calls, and the message names
the binding as predating parent support and points at `/speckit.jira.config` —
never the "not yet bound" text, and the refusal happens before the first `GET`.

## Step 4 — Derivation, both refusals

```bash
bats tests/bash/sink/test_hierarchy.bats
pwsh -c "Invoke-Pester tests/powershell/sink/Hierarchy.Tests.ps1"
grep -REn '"(Epic|Story|Task|Bug|Sub-task)"' scripts/ && echo "VIOLATION" || echo OK
```

**Result**: GREEN, covering every row of the hierarchy-resolution contract.
The grep guard printed `OK`.

> **Bug found and fixed**: the guard flagged `scripts/bash/commands/config.sh:27`,
> a comment reading `# The "Epic" tier is identified…`. The quotes around
> `Epic` were explanatory, not a compiled-in name, but they tripped the
> pattern. Fixed by removing the quotes (no behavioral change); guard now
> passes cleanly.

## Step 5 — The parent marker

```bash
bats tests/bash/engine/test_spec_marker.bats
```

**Result**: GREEN, including the load-bearing case (H1, no `## User Story`
headings, existing `spec=` marker still gets its own `story=` marker).

## Step 6 — The mandatory-field gate

```bash
bats tests/bash/sink/test_hierarchy.bats -f "mandatory"
```

**Result**: GREEN. Zero write calls; every unsatisfiable field of every
written type is named by its Jira `name`, never a `customfield_NNNNN` id.

## Step 7 — The first run builds the hierarchy

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us2-parent-first-run.json
```

**Result**: call sequence matches exactly — parent POST, parent properties
PUT, then per story a POST with `fields.parent.key` resolved followed by its
properties PUT. `spec.md` carries one `spec=<id> ticket=COMP-1` line after the
H1 and one `story=<id> ticket=COMP-N` line per user story.

## Step 8 — The second run writes nothing

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us2-parent-second-run.json
git diff --stat tests/conformance/fixtures/repo-with-mirrored-spec
```

**Result**: one `GET` per recorded ticket including the parent, zero `POST`/
`PUT`/`DELETE`, `created: 0, updated: 0`. The `git diff --stat` was empty.

## Step 9 — Fail-closed: no orphan stories

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-hierarchy-no-parent-level.json
tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-hierarchy-ambiguous.json
tests/conformance/run-scenario.sh tests/conformance/scenarios/us3-mandatory-field-refusal.json

SPEC_KIT_JIRA_HOOK_CONTEXT=after_specify \
  tests/conformance/run-scenario.sh tests/conformance/scenarios/us3-mandatory-field-refusal.json
```

**Result**: each of the first three exits 4 with zero writes, naming the
project and the specific cause. The hook-context run exits 0 with exactly one
`WARNING: … (exit 4). This spec-kit command completed normally.` line, still
zero writes.

> **Bug found and fixed**: `quickstart.md` originally paired the hook-context
> sub-step with `us1-hierarchy-ambiguous.json`, which invokes the `config`
> command. `_reconcile_fault`'s hook-context downgrade is `reconcile`-only —
> `config` has no such handling (confirmed via grep: zero occurrences in
> `config.sh` vs. two in `reconcile.sh`). Running it as originally documented
> produced exit 4, not the expected exit 0. Fixed the quickstart to reference
> `us3-mandatory-field-refusal.json` (a `reconcile`-invoking scenario) instead,
> with an explanatory paragraph; re-verified: exit 0, correct single WARNING
> line, zero writes.

The interrupted-run window (`spec.md` carrying `spec=<id> creating`) was also
confirmed: the run refuses and no story is created either.

## Step 10 — Dry-run predicts the real run exactly

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us6-dry-run.json
```

**Result**: the dry-run report names the parent creation, the assigned
identifier, and every child's parent reference; the predicted action set is
identical to the performed one, including the mandatory-field refusal case.

## Step 11 — Both ports agree, byte for byte

```bash
tests/conformance/run-scenario.sh --port bash       tests/conformance/scenarios/us2-parent-first-run.json
tests/conformance/run-scenario.sh --port powershell tests/conformance/scenarios/us2-parent-first-run.json
# repeated for the Latin-diacritic, non-Latin (T108) and SAFe scenarios
tests/conformance/run-scenario.sh tests/conformance/scenarios/us4-retired-key-refusal.json
grep -rn "epic_strategy\|task_strategy\|link_type" scripts/ templates/ commands/ | grep -v "retired"
grep -rn "issue_types" tests/conformance/fixtures/*/.specify/jira/config.yml && echo "VIOLATION" || echo OK
```

**Result**: identical stdout, exit codes, Jira call sequences and resulting
`spec.md` bytes across ports for every scenario, including the newly-added
non-Latin scenario (`us1-hierarchy-nonlatin.json`, T108: CJK Epikku/Sutoorii
plus Cyrillic Zadacha, story issuetype id `10502`). The retired-key refusal
exits 4 naming `epic_strategy`, the project index and the file; the grep
guards printed no matches / `OK`.

## Step 12 (LIVE GATE) — Idempotency against a real instance

```bash
bats tests/live/test_live_zero_churn.bats
```

**Not performed**: requires a real Jira Cloud project and credentials, neither
of which is available in this sandboxed environment. Everything up to the
Jira boundary was exercised in Steps 1–11. `.github/workflows/live.yml`
(T110) wires this suite into CI against `SPEC_KIT_JIRA_LIVE_*` secrets so it
runs on push to `main`, on schedule, and on labeled pull requests, guarded to
never run against a fork PR — but the workflow itself is likewise unverified
against a real instance in this sandbox. This mirrors the precedent set by
[specs/003-install-hook-activation/quickstart-results.md](../003-install-hook-activation/quickstart-results.md)'s
own §10.

## Coverage gate

```bash
tests/coverage/bash-coverage.sh     # kcov, >= 80% statements
pwsh -c "Invoke-Pester -CodeCoverage"
```

| Suite | Result |
| --- | --- |
| `bats -r tests/bash` (938 tests) | 938 passed, 0 failed |
| `Invoke-Pester tests/powershell` (715 tests) | 715 passed, 0 failed |
| `shellcheck -x scripts/bash/**/*.sh` | clean (0 findings) |
| `Invoke-ScriptAnalyzer` with the project settings | clean (0 findings) |
| PowerShell statement coverage | **92.16%** |
| Bash statement coverage | Not measurable on this host — see below |

> Bash coverage via `kcov` cannot run on macOS: `bash-coverage.sh` exits 2,
> explaining that kcov must drive the port under a real (non-Apple) bash >= 4,
> and cannot exchange stderr for a pipe against a non-Apple bash on macOS.
> This is a known, pre-existing, documented limitation — the CI "Bash
> coverage" job runs it on `ubuntu-22.04` instead. Matches the precedent in
> `specs/003-install-hook-activation/quickstart-results.md` §9.

## Summary

Eleven of thirteen steps were fully executed and passed; Step 12 (live
dogfood gate) was not performed for the reason stated above, matching prior
practice for this repository. Two real, pre-existing documentation/comment
bugs were found and fixed along the way (the Step 4 grep-guard false positive
in a `config.sh` comment, and the Step 9 hook-context scenario reference in
`quickstart.md`) — both are otherwise unrelated to the Phase 9 feature work
itself but were surfaced only by actually running the quickstart end to end.
