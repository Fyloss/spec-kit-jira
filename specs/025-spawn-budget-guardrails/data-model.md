# Phase 1 Data Model: The Process Budget Outlives the Feature That Measured It

This feature introduces no persistent state and no wire format. Its "entities" are the
measurement concepts the assertions and the durable document are written in terms of. They are
recorded here because getting one of them wrong is how a budget assertion becomes either vacuous
or flaky.

---

## Process count

The number of external programs a run causes to be executed, as observed by PATH interposition.

| Attribute | Value |
| --- | --- |
| Observed tools | `jq`, `sed`, `awk`, `curl` — the set `spawn_count.bash` shims today |
| Unit | one line appended per invocation, to a count file |
| Read as | total (`helper_spawn_count_total`) or per-tool (`helper_spawn_count_for`) |

**Composition.** A run's count decomposes into three parts, and conflating them is the principal
hazard this feature designs around:

- **fixed** — per-process setup that happens once regardless of input (a module's load-time
  probe). Must not be mistaken for growth.
- **per-request** — processes caused by talking to Jira. Includes `curl` itself **and**, under the
  Bash port's mock, the mock's own internal `jq` usage, because the mock is a Bash script reached
  through the same `PATH`. Grows with request count, legitimately.
- **per-item** — processes caused by local work over stories, tasks, and configuration lines.
  **This is the only part the budget governs**, and the only part that must not grow.

**Validation rule**: an assertion that does not hold the per-request part constant is not
measuring the per-item part. (research R1)

---

## Item count

The number of things a specification contains that the reconcile path loops over: user stories,
tasks, acceptance-criteria scenarios, and configuration lines.

**Validation rule**: the budget is expressed as a comparison between two item counts, never as an
absolute total. Doubling is the operation; equality of the resulting counts is the assertion.
(FR-012)

---

## Request count

The number of Jira requests a run issues, already instrumented by feature 024 and reported
per-phase by the timing report.

**Validation rule**: in the whole-run scenario this is a **premise, not an output** — the two runs
being compared must issue the same number, and the assertion verifies that before comparing
process counts. Prefetch chunks recorded keys at 100 per bulk fetch, so an already-bound,
unchanged specification of 10 and one of 20 both cost exactly one. (research R1, D2)

---

## Argument length

The byte length of a single element of a program's argument vector.

| Attribute | Value |
| --- | --- |
| Threshold | 128 KiB — Linux `MAX_ARG_STRLEN`, 32 pages |
| Distinct from | total `ARG_MAX`, which is far larger and is *not* the limit that bites |
| Applies on | every host, deliberately, including those with no such limit |

**Validation rule**: the threshold is a property of the rule, not of the host running the check. A
macOS run asserts the Linux limit because the code under test ships to Linux. (research R3, D4)

**State transition** — the lifecycle this feature exists to interrupt:

```text
per-item loop  --consolidated into one call-->  single large value
                                                      |
                                    passed through argv|  routed through a temp file
                                                      v                 v
                                          E2BIG on Linux only      correct everywhere
                                          (invisible on macOS)
```

The left branch is what "batch your calls" produces when stated alone. The two rules are one rule.

---

## Budget authority

Which document a reader must obey when two disagree.

| Attribute | Value |
| --- | --- |
| Authoritative | `docs/11-process-budget.md` |
| Historical record | `specs/024-reconcile-local-performance/contracts/spawn-budget.md` |
| Entry point | `AGENTS.md`, loaded automatically every session |

**Validation rule**: exactly one document may claim authority (SC-006). The historical record
keeps its measurements and derivation intact and cedes only the claim (FR-005).
