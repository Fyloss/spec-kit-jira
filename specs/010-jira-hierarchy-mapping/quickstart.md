# Quickstart: Validating the Role Mapping

Twelve steps that prove this feature works, in the order they should be run.
Steps 1–2 are the Red half of Red-Green-Refactor and MUST fail before any
implementation exists. Step 3 is the regression guard for every existing
installation. Step 11 is the Windows gate `AGENTS.md` requires; step 12 is the
live gate Constitution II demands, because mocks are explicitly not sufficient
for idempotency.

Run everything from the repository root.

## Prerequisites

```bash
bash --version        # >= 4; macOS ships 3.2, which does not qualify
pwsh --version        # >= 7
jq --version
bats --version
```

Live steps additionally need credentials resolved by Principle IV — environment
variables, the OS secret manager, or a gitignored `.env`. No token ever enters
the tree.

Design details are in `data-model.md` and `contracts/role-mapping.md`; this file
does not repeat them.

---

## Step 1 (RED) — The consumer's instance cannot be configured

The defect, reproduced from the real instance that motivated the feature.

```bash
bats tests/bash/commands/test_config_role_mapping.bats -f "configures the consumer hierarchy"
```

**Expect**: FAIL. The run exits `4` with `parent-level-ambiguous`, naming the two
level-1 candidates, and never reaches the story tier at all.

This is the failing test the repository's bug-fix policy requires before the fix.

## Step 2 (RED) — Two ambiguous tiers are reported one per run

```bash
bats tests/bash/commands/test_config_role_mapping.bats -f "reports every unresolved role in one run"
```

**Expect**: FAIL. Today the specification tier's refusal aborts before the story
tier is examined (research R1), so only one of the two is named.

## Step 3 (GREEN, and it must stay green throughout) — No mapping ⇒ nothing changes

The regression guard for every existing installation. Run it before the fix, and
after every commit of it.

```bash
tests/run-bash.sh --since main
pwsh -c 'Invoke-Pester tests/powershell'
bash tests/conformance/ci-conformance.sh
```

**Expect**: PASS at every point. FR-004 and contract §9.1 make this the invariant
the whole feature is built around — a repository with no `hierarchy` key behaves
byte-identically to the pre-010 release.

---

## Step 4 — The declaration resolves the ambiguity

```bash
bats tests/bash/commands/test_config_role_mapping.bats
```

**Expect**: PASS. Covers, per `contracts/role-mapping.md` §3:

- a declared `specification` resolves an otherwise ambiguous level (§3, `declared`)
- a declared `story` resolves a 13-candidate level
- a `--issue-type KEY=story=NAME` answer resolves without a declaration (`operator`)
- `--child-type KEY=NAME` still works as the alias (§2.2)
- an unambiguous level with nothing declared still derives (`derived`)
- the declaration outranks a conflicting recorded answer, and the note names both (§7.2)

## Step 5 — Every refusal, one test each

```bash
bats tests/bash/sink/test_role_mapping.bats
```

**Expect**: PASS. One case per refusal in contract §6 — unknown role, unresolved
role, unknown type, duplicate name, sub-task misuse in both directions, ordering
— each asserting exit `4`, zero `POST`/`PUT` calls, and the exact message
including its candidate list.

Two negative assertions belong here and are easy to forget:

- `level(specification)` may exceed `level(story)` by more than one (§4.1)
- a sub-task type at level `0` is caught by the flag, not by the level (§4.1)

## Step 6 — The binding round-trips

```bash
bats tests/bash/commands/test_config_determinism.bats
bats tests/bash/lib/test_config_binding_shape.bats
```

**Expect**: PASS. `hierarchy_level` survives as a string and compares numerically
(§4); `roles.story` ≡ `child_type` and `roles.specification` ≡ `parent_type` on
every fixture (§5.1, §9.2); a second run writes byte-identical YAML (§5.2).

## Step 7 — Reconcile mirrors into the declared types

```bash
bats tests/bash/commands/test_reconcile_hierarchy.bats
bats tests/bash/commands/test_reconcile_zero_churn.bats
bats tests/bash/commands/test_reconcile_dry_run.bats
```

**Expect**: PASS. A two-story specification against the consumer fixture produces
exactly one issue of the declared specification type and two of the declared
story type, each naming the parent; a second run issues zero writes of every
kind.

The third file is FR-026 and Constitution XI's enforcement test: a dry run names
the resolved type at every tier, predicts every §6 refusal byte for byte, and
its predicted action set equals the real run's over the same state. Nothing else
in this feature exercises `--dry-run` outside the live step.

## Step 8 — The credential and schema gates hold on the new key

```bash
bats tests/bash/lib/test_config.bats -f "hierarchy"
bats tests/bash/lib/test_token_leak.bats
```

**Expect**: PASS. A token-shaped or host-shaped value under `hierarchy` is
refused with exit `4` and **never echoed** — this rides on the existing scan
(`_cfg_credential_errors`) and is asserted rather than assumed. An unknown role
name is refused by name (§6.1), which matters because unknown *project* keys are
still tolerated by design.

## Step 9 — The task role is honest about not being mirrored

```bash
bats tests/bash/commands/test_config_role_mapping.bats -f "task role"
```

**Expect**: PASS. A declared `task` role validates (§6.6 refuses a non-sub-task
type), persists, reports `recorded, not yet mirrored` (§7.4), and **creates no
sub-task** (§9.6). An **undeclared** `task` role is the other half: absent rather
than unresolved, so it produces no `roles.task`, no note and no refusal (§3.4,
§9.7). Get that one wrong and every project without a task tier stops
configuring.

Delete this step's zero-sub-tasks assertion only when the task tier actually
ships; the §3.4 assertion stands forever.

---

## Step 10 — Cross-port byte equivalence

```bash
bash tests/conformance/ci-conformance.sh
shellcheck $(git ls-files '*.sh')
actionlint
pwsh -c 'Invoke-ScriptAnalyzer -Path scripts/powershell -Recurse -Settings PSScriptAnalyzerSettings.psd1'
```

**Expect**: clean. New scenarios in the corpus:

| Scenario | Proves |
| --- | --- |
| `us1-role-declared` | the consumer instance configures with a declaration |
| `us1-role-unresolved-both` | both unresolved roles reported in one refusal |
| `us1-role-operator-answer` | `--issue-type` resolves and is persisted with provenance |
| `us1-role-supersession` | the declaration outranks the local answer |
| `us1-role-ordering-refusal` | inverted levels refuse, zero writes |
| `us1-role-declared-dry-run` | the dry run predicts a resolved type per tier, zero writes |
| `us1-hierarchy-ambiguous` | **unchanged** — still refuses with nothing declared (§6.2) |

That last row is the point: FR-008 and FR-009 share a code path, so the
pre-existing refusal scenario is the guard proving the closed question did not
quietly become a prompt.

## Step 11 — Windows

```bash
git push origin HEAD:ci/windows-probe
```

**Expect**: green, ~11 min, results as annotations (`docs/10-windows-portability.md`).

Two things are specifically under test and neither can be checked by reading:

- the `unresolved_roles` block is multi-line JSON and MUST go through the output
  module, not a bare `jq` — the Windows `jq` build emits CRLF on multi-line
  output
- every message interpolating `Tâche` / `Sous-tâche` / `Récit` is byte-identical
  across ports

A Windows claim is unproven without this run, in either direction.

## Step 12 — Live, against the instance that motivated the feature

```bash
export SPEC_KIT_JIRA_BASE_URL=…        # never committed
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh config --json
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh reconcile specs/…/spec.md --dry-run --json
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh reconcile specs/…/spec.md --json
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh reconcile specs/…/spec.md --json
```

**Expect**:

1. config exits `0` and the summary audits three roles with their provenance
2. the dry run predicts the resolved type of every issue (FR-026)
3. the first reconcile creates one parent and its stories, of the declared types
4. the second reconcile reports `created: 0`, `updated: 0`, `skipped` equal to
   the story count — the correct signature of an idempotent re-run

Step 12 is **SC-001**. It is the only place the seventeen-type hierarchy, the
non-ASCII names and the two-ambiguous-tiers case are exercised together against
a real Jira, and mocks are explicitly not sufficient for the idempotency claim.
