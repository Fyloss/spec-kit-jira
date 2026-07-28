# Contract: Reconcile Resolution

**Feature**: [../spec.md](../spec.md) | **Interface**: the `reconcile` command of the `spec-kit-jira` CLI

This contract governs what `reconcile` reads before it plans anything, what it produces, and what it says when it cannot proceed. It is a CLI contract: the observable surface is the command's arguments, environment, exit code, stderr diagnostics and the `--json` run summary.

---

## Invocation

```text
spec-kit-jira reconcile <spec-file> [--dry-run] [--json] [--on-drift=abort|proceed] [--verbose]
```

`<spec-file>` is the first positional argument and must be a readable file. Its **parent directory's basename** is the routing input.

---

## Inputs

| Source | Read | Required |
| --- | --- | --- |
| `<spec-file>` parent directory basename | Routing key for `folder_prefix` rules | Yes |
| Spec's declared labels | Routing key for `spec_label` rules; `[]` when none | No |
| `.specify/jira/config.yml` | Projects, routing rules, `routing_default`, priority maps, epic strategy | Only when a value is not supplied by an explicit override. Absent → the `not-configured` notice (exit 0, zero writes); present but invalid → `EXIT_CONFIG`, as today |
| `.specify/jira/config.local.yml` | Per-project resolved identifiers | Yes, for any creation |
| `SPEC_KIT_JIRA_BASE_URL` | Site base URL | Yes — absent means "not configured", exit 0 with a notice |
| `SPEC_KIT_JIRA_PROJECT_KEY` | Explicit project override | No |
| `SPEC_KIT_JIRA_EPIC_STRATEGY` | Explicit strategy override | No |
| `SPEC_KIT_JIRA_PLAN_CONTEXT` | Explicit creation-context override | No |
| `SPEC_KIT_JIRA_HOOK_CONTEXT` | Marks a lifecycle-hook run | No |

**Configuration directory** resolves through the existing `JIRA_CONFIG_DIR` (default `.specify/jira`), overridable for tests.

**Ordering guarantee**: all resolution completes before the first network call (FR-019). A run that cannot resolve makes zero requests.

---

## Precedence

Applied per value, independently:

```text
explicit non-empty environment variable  >  value derived from config  >  refuse
```

There is no built-in fallback value. The former `PROJ` placeholder default is removed; a resolved key equal to the shipped placeholder is refused, not used.

Because precedence is applied per value *before* config is consulted, a run whose
project key, epic strategy and creation context are all supplied by explicit
overrides completes without reading `config.yml` at all. The placeholder refusal
is the one rule that outranks the override: a key equal to the shipped
placeholder is refused whatever produced it, because it can never name a real
project.

---

## Outputs

**Run summary** (`--json`), unchanged in shape. The resolved project appears in every planned action's payload, and the summary's action set is byte-identical between `--dry-run` and a real run on the same inputs (FR-020).

**Success postconditions**:

- Exactly one project key was resolved for the run.
- Every planned creation declares that project and an issue type.
- No attribute the resolved project does not accept appears in any payload.

---

## Diagnostics catalogue

Five named causes. Each emits exactly one message naming the cause, the file or rule involved, and one copy-pasteable remedy. No message contains a Jira site host or any credential (FR-018).

| # | Cause | Condition | Remedy named |
| --- | --- | --- | --- |
| 1 | `not-configured` | No base URL — a fresh install | `/speckit.jira.config` |
| 2 | `routing-unresolved` | No rule matched, no team route, no `routing_default` | Add `routing_default` to `config.yml` |
| 3 | `placeholder-binding` | Resolved key equals the shipped placeholder | `/speckit.jira.config` |
| 4 | `unknown-project` | A routing rule names a project `projects[]` does not declare | Correct the rule in `config.yml` |
| 5 | `project-not-bound` | No `resolved_ids` entry for the resolved project | `/speckit.jira.config` |

Cause 1 keeps its existing behaviour: a notice, zero writes, **exit 0** in every context — it is the normal state of a fresh install, not a fault.

Causes 2 to 5 are faults and route through `_reconcile_fault`.

---

## Exit codes

No new exit code is introduced.

| Context | Causes 2–5 | Rationale |
| --- | --- | --- |
| Direct invocation | `EXIT_CONFIG` (4) | Fail closed (FR-016, Principle III) |
| Lifecycle hook (`SPEC_KIT_JIRA_HOOK_CONTEXT` set) | `0`, with exactly one WARNING on stderr | A hook must never fail its host command (FR-015, Principle III) |

**Write guarantee**: for every cause, in every context, the number of Jira write requests issued is **zero** (FR-017).

---

## Conformance

Both ports must produce byte-identical stdout, exit code, API call sequence and post-run repository tree for identical inputs (FR-021, Principle VI). Enforced by:

- `tests/conformance/scenarios/us8-reconcile-company-managed.json`
- `tests/conformance/scenarios/us8-reconcile-team-managed.json`

---

## Backward compatibility

- Repositories that override every resolved value keep their exact current behaviour and never read `config.yml`. Repositories that override only some values now require a readable `config.yml` for the remainder; its absence is the existing `not-configured` notice, not a new fault.
- Overriding the project key with the shipped placeholder is refused rather than honoured — the one intentional behaviour change for override users. It could never have produced a successful write.
- Repositories with no configuration keep their current notice and exit 0.
- No configuration file format changes; no migration is required.
- The only removed behaviour is the `PROJ` placeholder fallback, which could never have produced a successful write.
