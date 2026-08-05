# Quickstart — validating that the mirror stops overwriting

How to prove this feature works, from a cold checkout to a green three-OS gate. Nothing here needs a real
Jira instance except the last section.

## Prerequisites

- Bash ≥ 4 (macOS ships 3.2, which does not qualify — `brew install bash`), `bats`, `jq`.
- PowerShell 7+ and Pester, for the Windows port's suite.
- `shellcheck` and `actionlint`, both of which must stay clean.

## The failing test first

Constitution XIII requires the reproduction before the fix. The shortest one already has a home: the test
at `tests/bash/sink/test_us7_plan_apply.bats:47` asserts today's defect as if it were correct —

> `a bridge-created update (no origin) keeps the US3 whole-description behaviour`

Invert it. The new assertion is that a bridge-created update preserves a human prefix and renders a
delimited managed region below it. Run it and watch it fail:

```bash
bats tests/bash/sink/test_us7_plan_apply.bats
```

A red run here is the proof that the defect exists. Do not touch production code until you have seen it.

## The inner loop

```bash
tests/run-bash.sh --since main      # change-scoped, ≤60s on a single-module diff
tests/run-bash.sh                   # the full bash suite, ~190s
```

Use `tests/run-bash.sh`, not bare `bats -r tests/bash` — the latter is serial and ~15 minutes. If you do
reach for raw `bats`, the `-r` is load-bearing: without it bats silently runs nothing and reports success.

## Scenario 1 — a human's text survives a full lifecycle

The scenario the operator reported, run against the mock Jira rather than a real site.

```bash
bash tests/conformance/ci-conformance.sh
```

Setup, expressed as a conformance scenario under `tests/conformance/scenarios/`:

1. Mirror a specification with two user stories. Assert the parent and both stories are created, each
   description ending with the delimiter followed by the managed nodes.
2. Seed the mock's stored parent description with two human paragraphs **above** the delimiter.
3. Produce a `plan.md` with a `## Summary` section. Run again.
4. Assert: the parent's `PUT` payload begins with the two human paragraphs byte-for-byte, then the
   delimiter, then the managed nodes ending in the plan section.
5. Run a third time with nothing changed. Assert zero created, zero updated.

**Expected**: steps 4 and 5 both pass, and the two paragraphs are byte-identical to what step 2 seeded.
This is SC-001 and SC-002.

Conformance success is silent — there is no pass banner. What you are looking for is exit 0 and zero lines
containing `conformance divergence`. Temporary-path noise in the output is the harness, not a failure.

## Scenario 2 — the migration, both branches

1. Seed the mock with a ticket in the pre-release shape: a description carrying the mirror's own output and
   **no** delimiter. Run once. Assert the resulting description is `delimiter ++ managed nodes` with
   nothing above it, and that nothing is duplicated.
2. Seed a second ticket the same way but with a human paragraph prepended. Run once. Assert the paragraph
   survives above the delimiter and nothing is duplicated.
3. Seed a third whose stored description matches neither. Run once. Assert nothing is lost, one warning
   names that ticket key, and the run still completes with the host exit code unaffected.
4. Re-run all three. Assert zero writes.

**Expected**: SC-006. Step 3's duplication is the documented, warned outcome — see the plan's Complexity
Tracking.

## Scenario 3 — a rename is kept, not reverted

1. Mirror a specification. Assert the identity property now carries a `summary` field equal to what was
   sent.
2. Change the stored summary on the mock to something else. Run again.
3. Assert: the `PUT` payload carries **no** `summary` key, one warning names that ticket key and the
   summary field, and every other field still reconciles.
4. Run again with `--on-drift=proceed`. Assert exactly one summary write restoring the specification's
   title, counted as an ordinary update.
5. Run once more, unchanged. Assert zero writes — including zero entity-property writes.

**Expected**: SC-005 and, at step 5, SC-004.

## Scenario 4 — a Jira link in a human's prose does not block the run

The failure mode research R4 identified. Without the fix this refuses the whole run with exit 9.

1. Seed a bridge-created ticket's human prefix with a link to another Jira ticket on an
   `*.atlassian.net` host.
2. Run. Assert the run completes, the ticket is written, and no BLOCK is reported.
3. Now put the same host into a *specification* heading so the mirror composes it into the managed region.
   Run. Assert the run refuses with the existing block exit code and zero writes.

**Expected**: the guard still catches everything the mirror composes, and no longer fires on what it merely
echoes back.

## Cross-port equivalence

```bash
bash tests/conformance/ci-conformance.sh
shellcheck $(git ls-files '*.sh')
actionlint
```

Both ports must emit byte-identical payloads, warnings, and counts for every scenario above. This is the
gate that catches a divergence between `plan_apply.sh` and `PlanApply.psm1` — the two files where this
feature's logic is duplicated by design.

## Windows

Every value this feature manipulates is JSON, so the CRLF hazards catalogued in
`docs/10-windows-portability.md` are not reachable through the new code paths. That is a claim, not a
proof: if the three-OS matrix reports a Windows-only divergence, diagnose it by measurement on the real
runner (`ci/windows-probe`, ~11 minutes, results arrive as check-run annotations), never by emulating the
toolchain locally. Note that `main` is already red on `windows-latest` — diff this branch's annotations
against `main`'s before concluding the branch caused anything.

## Dogfooding

Constitution XII requires a real-instance run before release. The decisive one is the reported workflow:

```
/speckit.specify  →  type two paragraphs into the Epic in Jira  →  /speckit.plan  →  /speckit.tasks
```

**Expected**: the two paragraphs are still there after `/speckit.tasks`, the Epic's description ends with
an implementation-plan section, exactly one such section exists, and neither the Epic nor any Story was
renamed. Anonymise any field, option, or project name before it reaches a spec or a test fixture.
