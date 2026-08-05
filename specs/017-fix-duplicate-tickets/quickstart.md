# Quickstart — proving this feature works

Every command below runs from the repository root. Nothing here touches a real Jira site.

## Prerequisites

- `bats` and `jq` (bash port); PowerShell 7+ and Pester (Windows port)
- `shellcheck`, `actionlint`
- No new dependency is introduced by this feature

## 1. The failing test first (Constitution XIII)

Before writing the guard, write the reproduction and watch it fail:

```bash
bats -r tests/bash/commands/test_reconcile_target.bats
```

It builds a feature folder holding `spec.md` and `plan.md`, points the bridge at a mock that fails
the test on **any** inbound request, and invokes:

```bash
scripts/bash/spec-kit-jira.sh reconcile specs/001-test-page/plan.md --json
```

Without the guard: the mock receives requests, tickets are created, and markers appear in
`plan.md` — the reported defect, reproduced. With the guard: zero requests, exit 1, `plan.md`
byte-identical.

## 2. Inner loop while implementing

```bash
tests/run-bash.sh --since main        # change-scoped, ≤60s on a single-module diff
```

Use this, not `bats -r tests/bash` — the full suite is ~15 min serially. `-r` is load-bearing when
you do run bats directly; without it bats silently runs nothing.

## 3. Full bash suite

```bash
tests/run-bash.sh                     # ~190s, bats + jq only
```

## 4. Cross-port equivalence

```bash
bash tests/conformance/ci-conformance.sh
```

Success is silent: exit 0 and **zero** lines containing "conformance divergence". There is no pass
banner, and the temp paths it prints are harness noise.

New scenarios this feature adds under `tests/conformance/scenarios/`:

| Scenario | Proves |
| --- | --- |
| `us1-target-refusal` | the refusal message and exit are byte-identical across ports |
| `us1-stray-markers` | the stray-marker warning fires and `plan.md` is untouched |
| `us2-label-create` | both roles' creation payloads carry `speckit-<slug>` |
| `us2-label-backfill` | one update per unlabelled ticket, counted |
| `us2-label-second-run` | the run after back-fill is a byte-identical no-op |
| `us4-duplicate-probe` | the probe's refusal and its unavailable path (drop with User Story 4) |

## 5. Linters

```bash
shellcheck $(git ls-files '*.sh')
actionlint
```

## 6. Windows

A Windows-only divergence is diagnosed by **measurement on the real runner**, never by emulation:
push to `ci/windows-probe` (~11 min; results arrive as check-run annotations, not job logs). The
one hazard this feature could plausibly hit is the target guard's path splitting — see research R3,
which is why the comparison is a basename equality and not a glob.

## 7. Manual end-to-end check on a consumer repository

The defect was found by dogfooding, so close the loop the same way:

1. Install the built extension into a scratch consumer repository.
2. Run `/speckit.specify`, then `/speckit.plan`.
3. Confirm in Jira: **one** parent and **one** child per user story — not two — and that each
   carries the `speckit-<identifier>` label.
4. Confirm on disk: `plan.md` carries no `<!-- speckit-jira … -->` line.
5. Delete the label from one ticket by hand and re-run any lifecycle command: it comes back, and
   nothing else changes.
