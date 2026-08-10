# Quickstart — Validating that each tier advances along its own workflow

**Feature**: `specs/023-advance-board-position` | **Date**: 2026-08-10

How to prove this feature works, end to end, without a real Jira instance. Details of behaviour live in
[`contracts/lifecycle-transition.md`](contracts/lifecycle-transition.md) and
[`contracts/role-lifecycle-config.md`](contracts/role-lifecycle-config.md); shapes live in
[`data-model.md`](data-model.md).

---

## Prerequisites

- Bash ≥ 4 (macOS's system Bash 3.2 does not qualify), `jq`, `curl`, `git`
- `bats` for the Bash suite; PowerShell 7+ and `Pester` for the other port
- `shellcheck` and `actionlint`
- No credentials: every scenario below runs against the repository's own test doubles

---

## The failing test first

Per Principle XIII, the first thing to run is the assertion that fails today.

```bash
bats -r tests/bash/commands/test_reconcile_lifecycle.bats
```

The file currently contains the assertion that pins the gap:

> `zero transition requests in every scenario — this release evaluates the rules but never moves a ticket's status`

That test is **rewritten, not deleted**, in the same change that makes it false (research R1). Its intent
survives as the narrower assertion that a project declaring no mapping issues zero moves. The new failing
test to add beside it: a declared mapping, a recognised story one step behind, a run under the matching
event, and an assertion that exactly one transition POST was issued.

---

## Scenario 1 — A story advances (FR-001, FR-003, US1)

```yaml
# .specify/jira/config.yml — the routed project
phase_status_map:
  after_specify: "To Do"
  after_plan:    "In Progress"
```

```bash
SPEC_KIT_JIRA_HOOK_EVENT=after_plan \
  scripts/bash/spec-kit-jira.sh reconcile specs/001-billing-invoices/spec.md --json
```

**Expected**: the story's ticket stands at "In Progress"; the summary reports `transitioned: 1`; the mock's
call log shows exactly one `GET …/transitions?expand=transitions.fields` followed by one
`POST …/transitions`.

**Then run it again, unchanged.** Expected: `transitioned: 0`, and **no** availability read at all — the
ticket already stands at the declared step (§9 of the transition contract, FR-008).

---

## Scenario 2 — Two workflows, one project (FR-010, FR-011, US2)

```yaml
phase_status_map:
  specification:
    after_plan: "Building"
  story:
    after_plan: "In Progress"
```

**Expected**: the parent stands at "Building", every story at "In Progress", and no ticket was ever
evaluated against the other role's step name. The call log shows one read and one write per moved ticket and
nothing else.

**Variant — the story role only.** Remove the `specification:` block. Expected: stories advance, the parent
is not moved, and **no warning is raised about the parent** — an undeclared role is silent, not withheld
(FR-012).

---

## Scenario 3 — Upgrading a configuration written before roles existed (FR-013, SC-004)

Use the role-blind shape of Scenario 1 unchanged, on a project that has a parent and sub-tasks.

**Expected**: stories advance; `0` parents moved; `0` sub-tasks moved. This is the regression that protects
every team already running the extension, and it is worth asserting on the call log rather than only on the
summary — the summary would look identical if the parent had been moved by a second mapping.

---

## Scenario 4 — The three unresolvable workflows (FR-004, FR-005, FR-007, US4/US5/US6)

Configure the mock's project with, in turn:

| Fixture | Expected |
|---|---|
| two offered moves both landing on "In Progress" | `transitioned: 0`, exactly one warning naming both candidates |
| one move onto "In Progress" whose screen requires a field | `transitioned: 0`, one warning naming the field; **assert the recorded creation-time default was not sent** (FR-006) |
| no move onto "Done" from "To Do", only "In Review" | `transitioned: 0`, one warning naming "To Do", "Done", and the reachable set |

In all three: the content PUT still happens (FR-019). Assert that too — a withheld move suppressing content
would be the most damaging regression this feature could introduce.

---

## Scenario 5 — Every existing protection (FR-018, US3)

Run the existing safety corpus unchanged:

```bash
tests/run-bash.sh --since HEAD~1
```

**Expected**: every drift, halt, flagged and blocker scenario produces the same decision and the **same
warning wording** as before. The only permitted difference is that a decision of `transition` now also emits
a move. Any change to an existing warning string is a regression, not an improvement.

Then repeat the corpus against a parent ticket (FR-014): same decisions, same wording.

---

## Scenario 6 — Sub-task precedence (FR-016, §7)

Enable sub-task mirroring, declare a `task` workflow, and check one task in `tasks.md`.

**Expected**: the checked task's sub-task is moved by the completion pass exactly as it is today — one move,
its existing wording. The declared mapping does **not** also act on it. Sub-tasks whose tasks are unchecked
follow the declared mapping.

**Variant — the tier is off.** Declare a `task` workflow with sub-task mirroring disabled. Expected: no
sub-task created or moved, and one note that the declaration has no effect. Exit code unchanged (FR-015).

---

## Scenario 7 — Fail-closed and refusal (FR-020, FR-021)

| Fault injected | Expected |
|---|---|
| the availability read returns 401 / 403 / 5xx | no move **and no content write** for that specification; documented non-zero exit; nothing on stdout from the reader |
| the move POST is refused (the ticket was moved meanwhile) | the refusal is reported naming the ticket; **no retry**, no second availability read, no other candidate attempted |

Assert the call log, not just the exit code: "did not retry" is only provable from the request sequence.

---

## Scenario 8 — The preview (FR-023, US7)

```bash
SPEC_KIT_JIRA_HOOK_EVENT=after_plan \
  scripts/bash/spec-kit-jira.sh reconcile specs/001-billing-invoices/spec.md --dry-run --json
```

**Expected**: the predicted moves and warnings are identical to a real run against the same state — same
tickets, same roles, same step pairs, same wording — and the call log contains the availability reads but
**zero** `POST …/transitions`.

---

## Cross-port equivalence

```bash
bash tests/conformance/ci-conformance.sh
```

**Expected**: exit 0 and zero lines containing `conformance divergence`. There is no success banner; silence
is the pass. Every scenario above has a corpus twin asserting byte-identical output **and an identical
request sequence** between the ports.

---

## Gates before the change is done

```bash
tests/run-bash.sh                              # full Bash suite
bash tests/conformance/ci-conformance.sh       # cross-port equivalence
find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +
actionlint
```

Plus, on the PowerShell side, the Pester suite, and — because this feature touches line-ending-sensitive
prose assembly — a green run of the Windows conformance probe (`ci/windows-probe`) before the platform
behaviour is claimed. Principle VI: a model of Windows is not Windows.

---

## Dogfooding

Principle XII requires a real instance before release. For this feature that means watching a real board
advance on **more than one tier**: declare two workflows, run the lifecycle, and confirm the Epic and its
stories each land on their own declared step. A single-tier dogfood would not exercise the change that
motivated the feature.
