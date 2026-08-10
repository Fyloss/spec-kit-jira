# Phase 0 — Research: Each Tier Advances Along Its Own Declared Workflow

**Feature**: `specs/023-advance-board-position` | **Date**: 2026-08-10

Every unknown in the Technical Context is resolved below. Each entry records what was decided, why, and
what was rejected. Nothing here authorises work the specification does not require.

---

## R1 — Where the write half is missing, measured rather than assumed

**Question**: the specification asserts that no specification- or story-tier ticket is ever moved. Where
exactly does the chain break, and is the break a defect or a deliberate scope boundary?

**Finding**. The chain breaks at one guard. `plan_lifecycle` (`scripts/bash/sink/jira/plan_apply.sh:1081`)
emits the transition action only under `do_transition == "true" && -n "${transition_id}"`. The decision half
is complete — `drift_evaluate` returns `transition` correctly — but nothing populates `transition_id` for a
story. The wired lifecycle context (`scripts/bash/commands/reconcile.sh:1450-1465`) builds each ticket entry
with `key`, `current`, `blockers`, `status`, `category`, `target`, `flagged` and `origin`, and no transition
id. The only other source is the `SPEC_KIT_JIRA_LIFECYCLE` environment override, which
`reconcile.sh:1419` documents as a test override.

The one real producer is `discovery_task_transition` (`scripts/bash/sink/jira/discovery.sh:472`), added by
feature 012 for the sub-task tier. It selects candidates by `statusCategory` (done / not done), never by a
status name.

**It is a deliberate boundary, not a defect.** `tests/bash/commands/test_reconcile_lifecycle.bats:123` pins
it by name: *"zero transition requests in every scenario — this release evaluates the rules but never moves
a ticket's status"*, and the file header cites "research R9" of the original feature as the authority.

**Decision**: treat this as completing a deliberately deferred half, not as fixing a bug. Consequence for
the task ordering: the pinning test is **rewritten in the same change that makes it false**, with its
intent preserved as a narrower assertion (zero moves where no mapping is declared), never deleted quietly.

**Alternatives considered**: leaving the pinning test and adding transitions behind a flag — rejected, it
contradicts FR-017 (no new flag) and would leave the documentation still lying.

---

## R2 — How a move is found on a workflow the bridge may not assume

**Question**: given a declared step *name*, which of the tracker's offered transitions is the right one, on
a workflow discovered at run time?

**Decision**: a sibling of `discovery_task_transition` that selects by the **destination status name**
instead of the destination's category, returning the same shape plus the reachable set:

```text
{ candidates: [{id, name, to}], transition_id, withheld_field, reachable: [status_name, ...] }
```

The four outcomes are taken verbatim from the task tier's contract, because the question is identical:

| Situation | Outcome |
|---|---|
| No candidate lands on the declared step | `transition_id: null`, `reachable` names what is | 
| Exactly one, ungated | `transition_id` set | 
| Exactly one, but its transition screen has a required field | `transition_id: null`, `withheld_field` names it |
| Two or more | `transition_id: null`, `candidates` lists them, no preference invented |

**Rationale**: the tracker's `GET /issue/{key}/transitions?expand=transitions.fields` already returns
`to.name`, `to.statusCategory` and the per-transition required fields in one response — the same response
the task tier reads. Selecting on `to.name` rather than `to.statusCategory.key` is a one-predicate change to
a proven reader, and it keeps Principle VII intact: no status name is ever built into the product, only
compared against what the operator declared.

**Alternatives considered**:
- *Reuse `discovery_task_transition` with a mode parameter.* Rejected: the two selectors differ in what they
  return (`reachable` is meaningless for the category selector) and the task tier's contract is shipped and
  tested. Two small readers beat one reader with a mode switch (Principle XIV).
- *Resolve the target status to an id first, then match transitions by `to.id`.* Rejected: it requires a
  second discovery read per project for no gain — the transitions response already carries the name, and
  the operator declared a name.

---

## R3 — The configuration shape for a workflow per hierarchy role

**Question**: how does a team declare three workflows without breaking the one mapping that ships today?

**Decision**: the mapping accepts **two shapes at the same key**, discriminated structurally.

```yaml
# Shape A — what ships today. Unchanged meaning: the story role.
phase_status_map:
  after_specify: "To Do"
  after_plan: "In Progress"

# Shape B — a workflow per role. Roles are the three the project already names.
phase_status_map:
  specification:
    after_specify: "Funnel"
    after_plan: "Building"
  story:
    after_specify: "To Do"
    after_plan: "In Progress"
  task:
    after_implement: "In Progress"
```

Discrimination is by the type of the values: every value a string means shape A; every value an object whose
own values are strings, keyed by a known role name, means shape B. A mixture is a validation error naming
both the project and the offending key.

**Rationale**:
- FR-013 requires an existing role-blind mapping to keep meaning exactly the story role. Reading shape A as
  `{story: {...}}` satisfies that with no migration, no second key, and no deprecation cycle.
- The role names are the ones the project already uses for the hierarchy (`specification` / `story` /
  `task`), so a tech lead meets no new vocabulary (Principle XVI, FR-026).
- A second key (`phase_status_map_by_role`) was rejected: two keys governing one concept is precisely the
  configuration surface Principle XV tells us not to grow, and it would leave every reader asking which wins.

**Validation** (both ports, same messages): unknown role name; a role mapped to a non-object in shape B; a
non-string step name; a mixture of the two shapes. Each names the project index and the key, matching the
existing message style at `scripts/bash/lib/config.sh:753` and `scripts/powershell/lib/Config.psm1:872`.

**Alternatives considered**: nesting under the existing hierarchy-role configuration block instead of under
the mapping key — rejected, it would scatter one team decision across two places in the file.

---

## R4 — Per-role classification and ordering

**Question**: `config_classify_statuses` and `config_phase_status_targets` derive the drift category and the
phase order from *the* mapping. With three mappings, which one applies?

**Decision**: the ticket's own role's mapping, and only that one. Both helpers already take the map as an
argument (`scripts/bash/lib/config.sh:639` and `:659`), so this is a **caller** change: resolve the map for
the role, then call the existing helper. No signature changes, no engine changes.

Consequence for `drift_evaluate`: its `order` input becomes the role's own order. The engine stays pure and
unaware of roles — it receives an order and a target, exactly as today.

**The halted designation stays project-wide.** A status name only matches a ticket that actually stands at
it, so one list covering all three workflows classifies correctly. Splitting it per role would add a
configuration surface no requirement asks for (Principle XV); it is recorded in the spec's Assumptions and
its Out of Scope.

---

## R5 — Extending the safety evaluation to the specification tier

**Question**: FR-014 requires the parent to be evaluated exactly as a story. What does that cost?

**Finding**. `plan_lifecycle` iterates `doc.stories` and keys its context by each story's `local_id`. The
parent is planned on a separate path and carries its own `local_id` with `role:"parent"` on the emitted
action (`scripts/bash/sink/jira/plan_apply.sh:619`). The recognition result's `bound` map already contains
the parent's entry — the same `key`, `current`, `status`, `flagged`, `origin` fields a story's entry has.

**Decision**: give `plan_lifecycle` an explicit, ordered list of the tickets it must evaluate — each entry
naming its `local_id` and its `role` — rather than deriving that list from `doc.stories`. The parent is one
more entry in that list. Every rule inside the loop is unchanged.

**Rationale**: this is the smallest change that satisfies FR-014 and FR-011 together — the loop needs the
role anyway, to pick the right mapping, so passing the role is not extra machinery. It also removes the
loop's hidden assumption that the ticket list and the story list are the same thing, which is the assumption
that made the parent unreachable in the first place.

**Alternatives considered**: a second function `plan_lifecycle_parent` mirroring the story one — rejected,
it would duplicate every safety rule and guarantee the two copies drift (the exact failure Principle XIV
exists to prevent).

---

## R6 — Precedence between task completion and a declared task-role mapping

**Question**: once the task role is mappable, two authorities can move one sub-task — the checked box in
`tasks.md` (feature 012's completion pass) and the lifecycle mapping.

**Decision**: FR-016 — the task's own completion wins on its own sub-task. Concretely, the declared mapping
is evaluated for a sub-task **only when that sub-task has no completion outcome in the same run**; a checked
task's sub-task is left to `plan_lifecycle_tasks` exactly as today.

**Rationale**: the checkbox is the more specific statement — it is about *that* task — while the mapping is
a statement about every ticket of the role. It also preserves Principle I: the checkbox is the filesystem
speaking about one unit of work, and the filesystem is the source of truth. `plan_lifecycle_tasks` is
untouched, so feature 012's shipped behaviour carries no regression risk.

**This is the one interaction decided rather than inherited**, and the specification says so in its
Assumptions. If it is revisited, the change is confined to which sub-tasks the new evaluation is offered.

**Alternatives considered**: letting the mapping win — rejected, it would let a project-wide statement
override a per-task fact from disk. Letting both act — rejected, two moves on one ticket in one run is
indefensible under zero-churn.

---

## R7 — Where the move count belongs in the run summary

**Finding**. The top-level summary counts are `{created, updated, skipped, warnings, errors, recognised,
assigned}` plus an optional nested `tasks` object and an optional `checklists` object
(`scripts/bash/commands/reconcile.sh:1875`). The nested `tasks` object already carries `transitioned`
(computed at `:1848` by counting POSTs whose URL ends in `/transitions`). **There is no top-level
transitioned count.**

**Decision**: add `transitioned` to the top-level counts, computed the same way the task tier computes its
own — by counting the emitted transition actions, not by a separate tally that could disagree with the
actions list. The nested `tasks.transitioned` keeps its current meaning, so a reader can tell a sub-task
completion from a lifecycle move.

**Constitution note**: Principle II names `0 transitioned` in its list of write kinds, and the live
double-run assertion must be extended in the same change that makes the count non-zero — the principle says
so explicitly. That extension is a task, not an option.

---

## R8 — Cost when the machinery is inert

**Question**: FR-022 and SC-003 require zero additional requests when nothing is mapped. Feature 021 spent
real effort on request count; this feature must not undo it.

**Decision**: the availability read is issued **per ticket, lazily**, and only when every condition of
`contracts/lifecycle-transition.md` §1 holds — the four request-cost conditions this section reasons about
(a lifecycle event, a declared step for the role, a current step that differs, a `transition` decision) plus
the two safety conditions the contract adds (no impediment marker, and no completion outcome on a sub-task).
The contract is the authority; this list is not a second one. A batched up-front read for every recognised
ticket was rejected — the tracker offers no bulk transitions endpoint, so a batch would be N requests issued
eagerly instead of N requests issued only where a move is actually due.

**Ordering constraint from Principle III**: the availability read must precede the ticket's write, so that a
failed read leaves the ticket untouched (FR-020). This places the read inside the planning pass, before any
action is applied — the same position `discovery_task_transition` occupies for the task tier.

---

## R9 — Refusing a multi-step path, and what to say instead

**Decision**: FR-007 — when no offered transition lands on the declared step, perform nothing and name the
current step, the declared step, and the reachable set. The reachable set comes free from the same response
(`[.transitions[].to.name]`), so the useful message costs no extra request.

**Rationale for refusing rather than walking**: a path would mean performing transitions the team never
declared, each carrying workflow post-functions the mirror cannot see, in an order the mirror inferred. That
is a different promise from "perform the move the team declared". Recorded in the spec's Out of Scope, and
explicitly not ruled out for a future feature.

---

## R10 — Conformance and the two doubles

**Finding**. Both doubles already serve the transitions endpoint, because the task tier uses it: the Bash
port's scripted `curl` replacement (`tests/conformance/mock-jira/curl-shim.sh`) and the PowerShell port's
mock server (`tests/conformance/mock-jira/mock-server.ps1`). No new double is needed.

**Decision**: extend the mock's project configuration with per-role workflows so one scenario can express
"the Epic offers Funnel→Building while the Story offers To Do→In Progress", plus the three unresolvable
shapes (two candidates, a gated screen, an unreachable target). Scenarios assert the **request sequence**,
which is where a port divergence would surface first, since this feature adds one read and one write per
moved ticket.

**Portability watch-items carried from `docs/10-windows-portability.md`**: the new warnings are multi-line
prose assembled from tracker data, so they must be built through `scripts/bash/lib/output.sh` rather than a
direct `jq` call (the Windows `jq` build emits CRLF on multi-line output), and no glob pattern in the new
code may contain `$'\r\n'`.

---

## Resolved unknowns

| Unknown | Resolution |
|---|---|
| Where the write half is missing | R1 — one guard in `plan_lifecycle`; a deliberate boundary with a pinning test |
| How to find a move by step name | R2 — a sibling reader selecting on the destination name, four outcomes reused |
| Config shape for three workflows | R3 — two shapes at one key, discriminated structurally, shape A means the story role |
| Which mapping classifies a ticket | R4 — its own role's; both helpers already take the map as an argument |
| Cost of evaluating the parent | R5 — an explicit ticket list carrying `local_id` and role; rules unchanged |
| Completion versus mapping on a sub-task | R6 — completion wins; the mapping governs sub-tasks with no completion outcome |
| Where the move count lives | R7 — a new top-level `transitioned`; the nested task count keeps its meaning |
| Request cost when inert | R8 — lazy per-ticket read, gated on every condition of contract §1; zero when unmapped |
| What to do about a multi-hop target | R9 — refuse and name the reachable set, which the same response already carries |
| Test doubles | R10 — both already serve the endpoint; extend fixtures with per-role workflows |
