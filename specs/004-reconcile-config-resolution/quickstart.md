# Quickstart: Validating Reconcile Config Resolution

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Contracts**: [resolution](./contracts/resolution-contract.md), [payload](./contracts/creation-payload.md)

This guide proves the feature works end to end. The important property: **every acceptance check below runs without a Jira instance and without credentials**, because `--dry-run` emits exactly the payloads a real run would send. That is what makes the reported defect reproducible as a unit test.

---

## Prerequisites

| Requirement | Check |
| --- | --- |
| Bash >= 4 (macOS ships 3.2 — install a newer one) | `bash --version` |
| `jq` | `jq --version` |
| `bats` | `bats --version` |
| PowerShell 7+ and Pester (for port parity) | `pwsh --version` |
| `kcov` (coverage gate only) | `kcov --version` |

---

## Step 1 — Reproduce the defect before fixing it

Constitution XIII and the repository's bug-fix policy both require the failing test first. Run this against the current tree:

```sh
cd /Users/sebastienthibaud/DevTemp/spec-kit-jira
export JIRA_CONFIG_DIR="tests/conformance/fixtures/repo-with-config/.specify/jira"
export SPEC_KIT_JIRA_BASE_URL="https://example.invalid"
env -u SPEC_KIT_JIRA_PROJECT_KEY -u SPEC_KIT_JIRA_PLAN_CONTEXT \
  ./scripts/bash/spec-kit-jira.sh reconcile specs/004-reconcile-config-resolution/spec.md --dry-run --json \
  | jq '.actions[0].body.fields'
```

**Expected before the fix** — verified against the tree at the time of writing, output reduced to its essentials:

```json
{"fields_present":["description","summary"],"n_creates":4,"summary_has_project":false}
```

All three defects in one line: four creations planned, each declaring **only** `description` and `summary`. No `project`, no `issuetype`, no `priority` — and the resolved project appears nowhere in the summary either, because nothing downstream ever received it. This is the reported rejection, reproduced with no Jira instance and no credentials.

**Expected after the fix**: `fields_present` includes `project` and `issuetype`; `fields.project.key == "COMP"` (the fixture's configured project, never `PROJ`).

---

## Step 2 — Routing resolves from config alone (US1)

With **no** extension environment variables set beyond the base URL:

```sh
env -u SPEC_KIT_JIRA_PROJECT_KEY -u SPEC_KIT_JIRA_EPIC_STRATEGY \
  ./scripts/bash/spec-kit-jira.sh reconcile <spec-file> --dry-run --json | jq -r '.actions[].body.fields.project.key'
```

| Fixture condition | Expected |
| --- | --- |
| A `routing[]` rule matches the spec folder prefix | Every action names that rule's project |
| No rule matches, `routing_default` set | Every action names the default |
| No rule, no default | Zero actions; `routing-unresolved` on stderr |
| Config still carries the placeholder key | Zero actions; `placeholder-binding` on stderr |

Then confirm prediction equals reality (FR-020) — run once with `--dry-run` and once against the mock, and diff the action sets.

---

## Step 3 — The creation context builds itself (US2)

```sh
env -u SPEC_KIT_JIRA_PLAN_CONTEXT \
  ./scripts/bash/spec-kit-jira.sh reconcile <spec-file> --dry-run --json \
  | jq '.actions[] | select(.method=="POST") | .body.fields | {issuetype, priority}'
```

Expect the issue-type id the binding recorded for the resolved project, and the priority id reached through the two-step map (`priority_map` → `resolved_ids.priorities`). Confirm the estimation appears on `POST` bodies and never on `PUT` bodies.

---

## Step 4 — Diagnostics and hook safety (US3)

Each of the five causes in the [resolution contract](./contracts/resolution-contract.md) must produce its own message. For each one, verify all three properties:

```sh
# Direct invocation: fails closed with the configuration code
./scripts/bash/spec-kit-jira.sh reconcile <spec-file>; echo "exit=$?"          # expect 4

# Hook context: never fails the host command
SPEC_KIT_JIRA_HOOK_CONTEXT=1 ./scripts/bash/spec-kit-jira.sh reconcile <spec-file>; echo "exit=$?"   # expect 0

# No credential and no site host leaks into the message
./scripts/bash/spec-kit-jira.sh reconcile <spec-file> 2>&1 >/dev/null | grep -Ei 'atlassian\.net|token|@' && echo LEAK
```

The last command must print nothing.

---

## Step 5 — Both project styles (US4)

The mock fixtures already encode the case that matters: `createmeta-fields-company.json` declares a `priority` field and `createmeta-fields-team.json` does not.

```sh
tests/conformance/run-scenario.sh tests/conformance/scenarios/us8-reconcile-team-managed.json bash out-team/
jq '.actions[].body.fields | has("priority")' out-team/stdout
```

Expect `false` throughout: the team-managed project does not accept a priority, so none is declared and the run still completes normally. Against the company-managed scenario, expect a priority to be present.

Also assert no identifier crosses between projects when both are bound (SC-013).

---

## Step 6 — Port parity (Principle VI)

```sh
for s in us8-reconcile-company-managed us8-reconcile-team-managed; do
  tests/conformance/run-scenario.sh tests/conformance/scenarios/$s.json bash       out-bash/
  tests/conformance/run-scenario.sh tests/conformance/scenarios/$s.json powershell out-ps/
  diff -r out-bash/workdir out-ps/workdir && diff out-bash/stdout out-ps/stdout \
    && diff out-bash/calls.log out-ps/calls.log && diff out-bash/exit out-ps/exit
done
```

Every diff must be empty. A divergence is a failing gate, not a documented quirk.

---

## Step 7 — Full suite and coverage gate

```sh
bats tests/bash/commands tests/bash/sink tests/bash/engine
pwsh -c "Invoke-Pester tests/powershell"
```

Coverage must stay at or above 80% statement coverage, with the fail-closed and payload-assembly paths near 100%.

---

## Acceptance summary

The feature is done when all of these hold:

- [X] `fields.project.key` present in 100% of planned creations (SC-009) —
      `tests/bash/sink/test_plan_apply_project.bats` (T010) asserts every
      `POST …/issue` body carries a non-empty `fields.project.key`; confirmed
      live in `us8-reconcile-real` (`fields.project.key == "COMP"`).
- [X] `fields.issuetype.id` present in 100% of planned creations (SC-003) —
      same suite and scenario; the assembly guard in `plan_writes` (T017)
      returns non-zero before emitting a creation missing either field.
- [X] `PROJ` appears in zero payloads (SC-002) — the placeholder fallback is
      removed (T013) and an override equal to it is refused
      (`test_reconcile.bats`, "an override equal to the shipped placeholder
      is refused, zero writes").
- [X] Zero writes on every unresolved run (SC-005) —
      `tests/bash/commands/test_reconcile_diagnostics.bats` (T031) asserts an
      empty `mock_calls` log for every one of the five diagnostic causes.
- [X] Prediction and real runs byte-identical (SC-006) —
      `tests/bash/conformance/test_us8_reconcile_real.bats` (T058) diffs the
      `us8-reconcile-company-managed` dry-run report against the
      `us8-reconcile-real` scenario's `calls.log`, on both ports.
- [X] Both ports byte-identical (SC-007) — `us8-reconcile-company-managed`
      and `us8-reconcile-team-managed` golden scenarios (T020, T046); the
      full bats (597) and Pester (505) suites are green.
- [X] No lifecycle command fails due to a resolution failure (SC-008) — every
      new fault routes through `_reconcile_fault`, downgraded to exit 0 under
      `SPEC_KIT_JIRA_HOOK_CONTEXT` (`test_reconcile_diagnostics.bats`).
- [X] Both creation paths share the same base attribute set (SC-010) — the
      shared `jira_create_fields_base` builder (T004–T008) both
      `_ticket_create_body` and `plan_writes` wrap.
- [X] Both project styles produce a valid creation (SC-011) —
      `us8-reconcile-team-managed` scenario and
      `tests/bash/commands/test_reconcile_styles.bats` (T041).
- [X] Zero payloads declare an attribute the project does not accept
      (SC-012) — the team-managed payload declares no `priority`
      (`test_reconcile_styles.bats`, T041); the mock's `createmetaFields`
      route selection is exercised end to end by
      `tests/bash/conformance/test_us8_priority_allowed.bats` (T061).
- [X] Zero cross-project identifiers (SC-013) — the dual-style fixture
      `repo-with-two-styles` (T045) gives each project its own `resolved_ids`
      entry; `test_reconcile_styles.bats` asserts no payload carries the
      other project's issue type.
- [X] The R8 verification item closed against vendor documentation —
      `research.md` R8, closed at T001 against Atlassian's Cloud REST API
      reference (no live Jira access in this session).
