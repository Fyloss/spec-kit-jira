# Quickstart — proving the task tier works

How to validate this feature, suite by suite. Shapes live in [data-model.md](data-model.md); the
normative rules live in [contracts/task-tier.md](contracts/task-tier.md). Nothing here is
implementation code.

## Prerequisites

- Bash ≥ 4 with `bats` and `jq`; PowerShell 7+ with Pester for the twin suites.
- No Jira credentials are needed for anything below except the live checks in §6 — the conformance
  corpus drives the mock endpoint.

## Inner loop

```bash
tests/run-bash.sh --since main        # change-scoped, ≤60s on a single-module diff
tests/run-bash.sh                     # full bash suite, ~190s
bash tests/conformance/ci-conformance.sh   # cross-port byte equivalence
shellcheck $(git ls-files '*.sh') && actionlint
```

Conformance success is silent: exit 0 and zero `conformance divergence` lines is the pass signal.

---

## 1. User Story 1 — tasks land as sub-tasks under the right story

**Fixture**: `tests/conformance/fixtures/repo-with-tasks/` — a specification with three user stories
and a `tasks.md` carrying attributed tasks (both by `[US<N>]` tag and by phase heading), unattributed
setup and polish tasks, one dangling task, one already checked, and one whose text exceeds a summary.

**Expect**

- one sub-task per attributed task, each under the story its task names and under no other parent;
- every sub-task's description carrying the task's identifier, phase, files and dependencies;
- the long task's summary shortened deterministically, its full text present in the description;
- a story with no task mirrored exactly as before, with no placeholder sub-task;
- the same fixture reconciled with **no `task` role declared** producing output byte-for-byte
  identical to the previous release — this is SC-005 and it is a conformance scenario, not an
  inspection.

**Run**: `bats -r tests/bash/engine` for the parser and marker units, then the `us1-tasks-*` scenarios.

---

## 2. User Story 2 — regeneration does not duplicate

**Expect**

- a second reconcile of an unchanged repository issuing **zero writes of every kind**, sub-tasks
  included;
- the task list regenerated with `T0nn` numbers shifted and durable identifiers preserved producing
  zero writes and no new issue;
- a first mirror recording each identifier into `tasks.md` as a byte-preserving edit — diff the file
  and confirm only the inserted marker lines differ, line endings included;
- a task whose identifier was lost treated as new, with the resulting duplication **reported** in the
  summary rather than silent.

Run the CRLF variant of the fixture too: it is the portability hazard of this feature.

---

## 3. User Story 3 — edits reach Jira, Jira-side edits are reported first

**Expect**: one content update for the task edited in the repository, one named drift warning for the
sub-task edited in Jira, naming the issue and the field, before any overwrite decision; a removed task
deleting nothing and reporting its orphan once by key; a re-attributed task not re-parented, its
divergence reported naming both stories.

---

## 4. User Story 4 — unattributed tasks are reported, not invented

**Expect**: every setup, foundational and polish task named individually in the summary by
`task_ref` with its reason; no issue created to host them at any tier; the dangling task reported by
identifier and tag while every other task still mirrors; inside a hook, one warning and a successful
host command.

---

## 5. User Story 5 — a completed task reads as completed

The one path with a new Jira call. Drive it through the mock's transitions endpoint.

**Expect**

- exactly the newly checked tasks transitioning to a status the project **classifies** as done, with
  no other write;
- a second reconcile issuing **zero** transitions — and zero transitions *reads*, since a sub-task
  already in a done-category status is never queried;
- a workflow offering no done-category transition producing no transition, one named warning, and
  every other task still reconciled;
- a workflow offering two producing no transition and a report naming the candidates;
- a task reverting to unchecked not moving its sub-task backwards;
- a task checked before its sub-task existed created and transitioned in the same run.

**SC-010**: run the whole of §5 against the non-English-status fixture with no configuration naming a
status. It must behave identically — that is the proof no status name is assumed.

---

## 6. User Story 6 — a mandatory field never blocks

**Fixture**: `tests/conformance/fixtures/repo-with-subtask-mandatory-field/`.

**Expect**

- the configuration ceremony asking for the sub-task type's required field by its **Jira label**
  when a `task` role is declared, and asking nothing about any sub-task type when none is;
- with the default recorded: every sub-task created carrying it, and the summary attributing the
  value to its source;
- with **nothing** recorded: the specification and story tiers mirrored exactly as they would be with
  no `task` role, zero sub-task writes, each field named once with its
  `speckit.jira.config --field-default …` remedy, and the summary stating the tier as withheld;
- `tasks.md` unchanged — no durable identifier recorded for a withheld task;
- recording the default and reconciling again creating **exactly** the withheld sub-tasks, moving the
  issue count by precisely that number, with no cleanup and no flag;
- a required field whose shape cannot be defaulted at all behaving the same way, run after run, never
  degrading the two upper tiers;
- one consolidated confirmation per run covering all three tiers, never one per tier.

---

## 7. Cross-cutting gates

| Gate | How |
| --- | --- |
| Dry-run equals the real run | `--dry-run` then the real run against the same state; the action sets must be identical, and the dry run must leave `tasks.md` untouched |
| Privacy guard | a task naming a real coordinate blocks with zero writes; an allowlisted link passes silently |
| Engine boundary | `.github/workflows/boundary.yml` — neither new engine module may source `sink/` or contain an Atlassian identifier |
| Byte equivalence | the full conformance corpus on all three runners; a Windows-only divergence is diagnosed on `ci/windows-probe`, never emulated |
| Idempotency assertion list | the live suite's list **must** gain the transition write kind in this same change (Constitution II) |
| Coverage | ≥80% statements per port; the withholding and completion paths are fail-closed critical paths and target near-100% |

## Done when

Both ports green on all three runners, conformance silent, lint clean, coverage above the gate, the
CHANGELOG entry written, the version raised in `extension.yml` alone, and one dogfood run against a
real project whose sub-task type carries a mandatory custom field — the shape that motivated User
Story 6.
