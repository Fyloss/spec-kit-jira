# Research — Each Tier Advances Along Its Own Declared Workflow

Nine questions. Eight are closed against the repository as it stands on `main` at `bdf04a0`. R1 is closed by
a measurement against a live instance, specified here and scheduled before the first line of Phase C.

Every claim below that describes current behaviour was read out of the code, not inferred from a
specification. File and line references are to `main` at the time of writing.

---

## R1 — Can available transitions be read for many issues in one request, with required-field detail?

**Status: OPEN — decided by measurement M1 before Phase C begins.**

### Why it matters

Spec FR-027 forbids the availability read from growing one-for-one with the number of tickets due a move,
because 021 spent a whole feature removing exactly that shape from recognition (`prefetch.sh`, one
`POST /rest/api/3/issue/bulkfetch` per hundred keys in place of one `GET` per key) and committed to a
request count "bounded by the number of writes plus a small constant for reads" (021 SC-003).

The task tier reads availability one issue at a time:

```
sink/jira/discovery.sh:481
  jira_request GET "${api}/issue/${key}/transitions?expand=transitions.fields"
```

`expand=transitions.fields` is load-bearing and is the reason this question has two halves. It is what
returns each transition's own screen fields with their `required` flag, which
`discovery_task_transition` uses to detect a gated move (`discovery.sh:488`). Spec FR-005 (User Story 7,
P1) requires the mirror to *stand down and name the demanded value* rather than attempt the move and be
rejected. A bulk read that returns transitions **without** field detail cannot satisfy FR-005, so it is not
a usable branch: it would only relocate the per-issue read rather than remove it.

### The two branches

| Branch | Condition | Consequence |
| --- | --- | --- |
| **A** | A bulk read reports transitions *and* their required-field detail for up to ~100 issues per request. | One request per hundred tickets due a move. FR-027 met as written. `transitions.sh` chunks exactly like `prefetch.sh`. |
| **C** | It does not — either no bulk transitions at all, or transitions without field detail. | One request per ticket **due a move** (never per recorded ticket). FR-027 is amended to FR-026's bound; the Complexity Tracking entry in `plan.md` is filled in. |

Branch B — bulk candidates plus a per-issue gate check — was considered and collapses into C: in the common
case a ticket has exactly one candidate, so the gate check runs for every ticket anyway.

### Why this is not resolved from the repository

The conformance mock implements `POST /rest/api/3/issue/bulkfetch` and
`GET /rest/api/3/issue/{key}/transitions` as separate handlers (`tests/conformance/mock-jira/mock-server.ps1`,
routes at l. 407 and l. 410), and the bulk handler composes only fields and properties — it says nothing
about what the real endpoint accepts. 021's own prefetch contract records the bulkfetch request shape it
verified (`issueIdsOrKeys`, `fields`, `properties`, 100-issue chunking, `200`/`400`/`401`, id-ordered
results) and does **not** record anything about an `expand` member, so the repository holds no evidence
either way. Writing a design on an unverified capability is how a feature discovers in Phase C that its
budget requirement was never achievable.

### Measurement M1 — the deciding task

Against the dogfood instance the project already uses for Principle XII, on one issue whose workflow has a
gated transition:

1. `POST /rest/api/3/issue/bulkfetch` with `{"issueIdsOrKeys":[…], "fields":["status"], "expand":["transitions"]}`.
2. Record: the status code; whether each returned issue carries a `transitions` array; and whether each
   transition carries its screen fields with a `required` flag.
3. Repeat with the sub-expansion spelling the per-issue endpoint uses (`transitions.fields`).

**Decision rule**: all three of (2)'s answers positive → branch A. Anything else → branch C. The result is
recorded back into this file and into `contracts/transition-resolution.md` §2 before Phase C's first task.

**Cost of being wrong in either direction is bounded** because every caller of `transitions.sh` is identical
under both branches — see `contracts/transition-resolution.md` §2, which specifies one function signature
and two implementations of its request.

### What is decided regardless of the branch

- The read is issued **only for tickets a safety decision already said should advance and that are not
  already standing at the declared step** (FR-008, FR-026). This is decided *after* `drift_evaluate`, so
  the set is as small as it can be, and it is zero on a run with no event or no declared step.
- A failure of the *bulk* form falls through to the per-key form at today's cost and today's outcome —
  identical to 021 prefetch invariant P2 (`contracts/recognition-prefetch.md` §4). A failed optimisation is
  never a classification (FR-031).
- A failure of the read itself (both forms exhausted) is fail-closed for the whole specification, matching
  `discovery_task_transition`'s existing treatment (FR-034).

---

## R2 — Where in the pipeline does resolution belong?

**Decision: inside the `plan` phase, in `plan_lifecycle`'s decision loop, before it returns.**

The seam already exists and is exact. `plan_lifecycle` (`sink/jira/plan_apply.sh:1019`) takes a lifecycle
context whose per-ticket entry is documented at l. 1003–1005 as

```
{ key, current:{fields…}, status, category, target, transition_id, flagged, blockers:[…] }
```

and at l. 1140 it emits the transition action if and only if `transition_id` and `key` are both non-empty:

```
if [[ "${do_transition}" == "true" && -n "${transition_id}" && -n "${key}" ]]; then
```

So the drift decision *already* reaches a `do_transition=true` on the real path; the action is silently
dropped for want of an id. That silent drop is the whole of "this release evaluates the rules but never
moves a ticket's status", and it is also the bug to be careful about: after this feature, an unresolvable
step must produce a **warning**, never a silent drop (FR-004, FR-005, FR-007).

**Why this phase and not another**:

- It is the same computation `--dry-run` performs, so the preview predicts the move exactly (FR-036,
  Principle XI) with no second, divergent code path.
- It is after the safety decision, so no read is issued for a ticket that will not move (FR-026).
- It is inside the timing marks: `timing_phase_end "recognition"` is at `commands/reconcile.sh:1233` and
  `timing_phase_end "plan"` at l. 1624, with `plan_lifecycle` called at l. 1509. Requests issued there are
  attributed to `plan`, which today reports zero, so the per-phase counts keep summing to the run's total
  (FR-030, and 024 SC-014). No new phase is introduced — 024's report has eight and its shape is asserted.

**Rejected**: resolving during recognition (step 6). It would fold the availability read into the prefetch at
zero extra round-trips, which is attractive, but at that moment the run does not yet know any ticket's
current status, so it would ask about every recognised ticket on every run that carries an event — including
the tickets already standing at the declared step, which FR-008 explicitly exempts.

---

## R3 — How is a per-role mapping told apart from today's?

**Decision: two closed, disjoint key sets. A mapping whose keys are all events is the story role's; a
mapping whose keys are all roles is per-role; anything mixed is a config refusal.**

Both sets are closed and neither can grow without a spec:

- Lifecycle events — `after_specify`, `after_clarify`, `after_plan`, `after_tasks`, `after_implement`,
  `after_analyze` (`extension.yml`'s `hooks:` block, and `commands/speckit.jira.reconcile.md` l. 10–11;
  the manifest comment states "These seven events are the complete set… adding an eighth requires a spec").
- Hierarchy roles — `specification`, `story`, `task`, held in one place as `JIRA_ROLE_NAMES`
  (`lib/config.sh:1015`, whose comment says the set has exactly one source and both `for role_key in` loops
  consume it).

The two sets share no member, so the discrimination is total and needs no version marker, no nesting hint,
and no new key. Today's validator already asserts the values are strings
(`lib/config.sh:928–930`: "phase_status_map must be a mapping of lifecycle-event name to status name"), so
the change is to accept a second shape beside it rather than to loosen the first.

**Why the role names and not new ones**: the same project entry already spells them in its `hierarchy:`
block (`lib/config.sh:933–940`), which is what makes the file readable without documentation (FR-039,
Principle XVI) — a tech lead reads `phase_status_map.specification` next to `hierarchy.specification` and
needs no explanation.

**Back-compatibility (FR-020)** falls out for free: the legacy shape is recognised by its own key set and is
routed to the story role, which is the tier it is evaluated against today. Nothing a project already
committed changes meaning, and neither a parent nor a sub-task starts moving because of it.

---

## R4 — What does the run-state document need, and what does the change cost?

**Decision: schema 1 → 2, adding `hook_event` and `plan.md`. Byte-equality stays the matching rule.**

### What is wrong today

`run_state_compose` (`lib/run_state.sh:64–85`) hashes `spec.md`, then folds in `tasks.md`, `config.yml`,
`config.local.yml` and `personal.yml` when they exist, and records `base_url`, `email`, `on_drift`,
`field_values`. It records **no lifecycle event**, and it does not hash `plan.md`.

Both omissions bite:

- `plan.md` is read on **every** run and its `## Summary` is spliced onto the parent's description
  (`commands/reconcile.sh:861–869`). A `/speckit.plan` that touches only `plan.md` therefore leaves every
  hashed input identical, and the run short-circuits: the plan summary does not reach Jira until some other
  file changes. **This is a live defect on `main`, independent of this feature** — it costs a consumer
  mirrored content, not just a board position.
- The event is absent, so `after_analyze` (which writes nothing at all) and any repeat of a lifecycle
  sequence collapse into a state the previous run already recorded.

### Why byte-equality is kept

021's contract makes matching a byte comparison of a freshly composed document against the recorded one
(`contracts/run-state.md` §3 and `data-model.md` §1: "A match requires byte equality… There is no partial or
per-field match"). That single rule is why the short-circuit is auditable and identical between ports. Both
new members are plain document fields, so the rule survives untouched: `hook_event` is recorded verbatim in
exactly the way `on_drift` and `field_values` already are, and `plan.md` is one more `inputs` member on the
existing "present when the file exists, key omitted otherwise" rule.

### The cost, measured against the six events

The state phase runs **before** the config phase, deliberately (021 `contracts/run-state.md` §2), so the
composer cannot know whether any role declares a step for this event — only the raw event name is available
to it. A differing event therefore forces a full reconcile even where nothing is declared. Enumerated:

| Event | Changes a hashed input? | Effect of adding `hook_event` |
| --- | --- | --- |
| `after_specify` | `spec.md` | none — already invalidated |
| `after_clarify` | `spec.md` | none — already invalidated |
| `after_plan` | `plan.md` (**newly hashed**) | none — now invalidated by hash |
| `after_tasks` | `tasks.md` | none — already invalidated |
| `after_implement` | `tasks.md` (checkboxes) | none — already invalidated |
| `after_analyze` | nothing | **one full reconcile**, once per input state |

So the whole cost of the narrowing is `after_analyze`, and a repeat of the same event over unchanged inputs
still short-circuits, because the recorded `hook_event` matches. This is the entry in `plan.md`'s Complexity
Tracking, with the two rejected alternatives.

**Schema bump**: `schema: 2` invalidates every recorded document, which 021 already treats as the correct
behaviour for a change to the *set* of recorded inputs (`data-model.md` §1) and which invariant S7 makes a
guarantee for upgrades. The first run after upgrade is a full reconcile — the fail-open direction.

---

## R5 — How does the lifecycle event reach the bridge?

**Decision: the existing `SPEC_KIT_JIRA_HOOK_EVENT` environment seam, made normative in the agent
procedure. No new flag.**

`_reconcile_hook_event` (`commands/reconcile.sh:63–65`) reads that variable and nothing else; its own
comment says "The agent sets it from the hook it is performing; it is the only thing that tells the bridge
WHICH event fired." A tree-wide search finds it set by **no** shipped artefact: not `extension.yml` (whose
`hooks:` entries carry `command`, `optional` and `description`, with no environment mechanism), and not
`commands/speckit.jira.reconcile.md`, whose normative invocation at l. 45–56 is

```
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh reconcile <spec-file> --json
```

Every other occurrence is a test (`tests/bash/commands/test_reconcile_lifecycle.bats`,
`tests/conformance/scenarios/us021b-disabled-event.json`, and their Pester twins). The consequence is
stated in the spec: the declared step is always empty on the real path and drift evaluation is never
reached.

**Why not a flag.** Spec FR-025 forbids introducing one ("No other key, flag, or option is introduced").
021's reason for choosing an environment variable for the timing switch — the hooks are invoked by the host,
so a flag could never reach them — does not apply here, because the agent composes the command line; but a
second door into the same fact would be a shape this project's own KISS principle rejects, and the seam both
ports already read is the one to fill.

**What changes**: `commands/speckit.jira.reconcile.md` gains a host-command → event table and the normative
instruction to export the variable for the event being performed, in the same register as its existing
"the target is ALWAYS the active feature's own `spec.md`" rule. The disabled-event dispatch guard
(`_reconcile_is_held`, l. 78–84) already reads the event first and exits silently, and stays first
(FR-012).

**A run with no event** keeps today's behaviour exactly (FR-011): empty event → empty target → the
lifecycle context's `target` is `""` (`commands/reconcile.sh:1490`) → `plan_lifecycle`'s
`[[ -n "${target}" ]]` guard at l. 1121 is false → no drift rule evaluated, no read, no move.

---

## R6 — What must change for the specification tier?

**Decision: widen the parent recognition read; `plan_lifecycle` gains the parent alongside its stories.**

Two concrete gaps:

1. **The parent's status is not read.** `_recognition_read_parent` requests
   `summary,description,labels` (021 `contracts/recognition-prefetch.md` §5, "Field projection"), against
   the story reader's `summary,description,priority,status,issuelinks,parent,labels`. Without `status`,
   `flagged` and `issuelinks`, none of the safety rules FR-021 requires can be evaluated for a parent.
   The prefetch's requested union already contains all of them
   (`sink/jira/prefetch.sh:26` — `…,status,issuelinks,parent,labels,subtasks,Flagged`), so only the
   parent reader's projection list widens; the bulk request itself is unchanged. This matters because the
   union and the readers must agree: a field the union omits breaks its reader **only on a prefetch hit**,
   which is the healthy path and the one least likely to be exercised by a narrow test.
2. **`plan_lifecycle` walks `.stories` only.** Its decode loop is driven by
   `.stories | to_entries[]` (`plan_apply.sh:1065`) and the parent's content action is produced separately
   by `_plan_writes_parent`. The parent gains an entry in the lifecycle context keyed the way the parent's
   own local id already is, and the same per-ticket body — zero-churn drop, flagged check, `drift_evaluate`,
   transition — runs over it.

**Identical wording is a requirement, not a nicety** (FR-021): the warnings come from `drift_evaluate`
(`engine/drift.sh:61–97`), which composes them from the statuses alone and knows nothing of tiers, so a
parent and a story in the same situation produce the same sentence by construction. That is the argument for
reusing the function rather than adding a parent-aware variant.

---

## R7 — How does the task tier behave under 022's two modes?

**Decision: a task-role mapping acts only where `config_task_mirror_for` resolves to `subtask`. Elsewhere it
is inert and produces one note per run.**

`config_task_mirror_for` (`lib/config.sh:1068–1070`) returns `subtask`, `checklist`, or the empty string,
and `lib/config.sh:901` validates the accepted values. `docs/05-reconcile-flow.md` §"The two task-mirror
modes (022)" states the split: in `checklist` mode no durable identifiers are assigned into `tasks.md` and
no sub-task writes are planned — the task list rides the story's managed region. So in that mode there is no
task-tier ticket for a mapping to move, and the correct outcome is a statement, not a warning per entry
(Principle XVI, and the spec's Assumptions).

Two further rules fall out of 022:

- **An abandoned sub-task is never moved** (FR-023). 022 detects a mode switch from `tasks.md` alone: a bound
  sub-task marker still present while the project is in `checklist` mode is precisely the record of a
  sub-task the mirror has abandoned (022 FR-033/FR-034). Those keys must not enter the move set.
- **A checked task still outranks the mapping** (FR-024). The completion pass
  (`plan_lifecycle_tasks`, `plan_apply.sh:1183`) governs a sub-task whose task is checked; the declared
  mapping governs the ones still in flight. Both emit through the same `_plan_transition_action`
  (`plan_apply.sh:979`), so a sub-task can never receive two transition actions in one run — the sets are
  disjoint by construction, which is the property the test asserts.

---

## R8 — How are the request and spawn budgets asserted?

**Decision: 024's `PATH`-interposed counting stand-in, with counting runs separate from timing runs.**

024's `contracts/spawn-budget.md` §4 fixes the method: a shim earlier on `PATH` records one line per
invocation then `exec`s the real tool, working identically for `jq`, `sed`, `awk` and `curl` with no new
dependency (C4.1); and counting and timing must be **separate runs**, because the shim itself inflated the
reference run from 91 515 ms to 147 774 ms — a 61% distortion (C4.2). C4.3 makes the count the assertion
that belongs in the suite and leaves wall-clock as dogfood evidence, which is right here too: CI runners are
an order of magnitude slower than a developer laptop.

Applied to this feature:

- **Spawn** (FR-028, SC-013): the resolution loop must not spawn a process per ticket, per candidate move,
  or per role. The decode-once-then-loop shape already used by `plan_lifecycle`
  (`plan_apply.sh:1032–1076` — one `jq` call decoding eleven fields for the whole array, replacing ten per
  story) is the pattern to follow, including its `--slurpfile` temp-file spelling, which exists because a
  single `jq` argument is capped at 128 KiB on Linux independently of `ARG_MAX` and a hundred-story
  `actions` array crossed it (l. 1036–1047).
- **Requests** (FR-027, SC-012): asserted against the harness's own recorded call log, the same source 024
  SC-014 uses, rather than against the timing instrument's self-report.
- **Configuration parses** (FR-029, SC-015): the per-role mapping is resolved from the already-parsed
  configuration object that `_reconcile_phase_status_map` (`commands/reconcile.sh:1474`) is handed, so
  three declared roles cost no additional open or parse.

---

## R9 — What becomes of the test that pins today's behaviour?

**Decision: rewritten in place, in both ports, with the zero-move case preserved as its own scenario.**

The pin is a real, currently-passing test in both ports:

```
tests/bash/commands/test_reconcile_lifecycle.bats:123
  @test "zero transition requests in scenario — this release evaluates the rules but never moves a ticket's status"
tests/powershell/commands/Reconcile.Lifecycle.Tests.ps1:132
  It "zero transition requests in scenario — this release evaluates the rules but never moves a ticket's status"
```

Principle XIII's Red-Green-Refactor means the first thing written is the test that fails today: a declared
mapping, a recognised ticket one agreed step behind, a run under a genuinely dispatched event, and an
assertion that a transition request was issued. The pin is then rewritten to assert what remains true — a
project declaring **no** mapping still issues zero transition requests — rather than deleted, so the
guarantee it carries for the majority of consumers keeps a test.

`tests/conformance/scenarios/us6-dry-run.json` is worth reading before writing any of this: it already
drives a transition action end to end by supplying `transition_id` through the `SPEC_KIT_JIRA_LIFECYCLE`
override, and asserts the dry-run report equals the real action set. It is the shape every new scenario
follows, minus the override.

---

## Consolidated decisions

| # | Decision | Rationale | Alternatives rejected |
| --- | --- | --- | --- |
| D1 | Resolution lives in `plan_lifecycle`'s loop, in the `plan` phase | Same computation `--dry-run` performs; after the safety decision, so no wasted read; inside the existing timing marks | Resolving at recognition — zero extra round-trips but asks about tickets FR-008 exempts |
| D2 | `sink/jira/transitions.sh` is a new module pair | Confines R1's two branches to one file with one contract | Appending to `discovery.sh` — smaller diff, no boundary for the branch, two resolvers sharing one file |
| D3 | Selection by destination **name**; `discovery_task_transition` keeps selection by **category** | The two tiers answer different questions; FR-002 forbids a built-in status table | One shared resolver parameterised by predicate — more indirection than two callers justify |
| D4 | Per-role shape discriminated by two closed disjoint key sets | Total, needs no version marker or new key; reuses names already in `hierarchy:` | A `version:` marker, or a nested `roles:` key — both add surface FR-025 forbids |
| D5 | Run-state schema 2 with `hook_event` + `plan.md`, byte-equality kept | Preserves the one property that makes the short-circuit auditable and port-identical | Per-field matching, or moving the state phase after config — see Complexity Tracking |
| D6 | The event travels by the existing environment seam | Both ports already read it; FR-025 forbids a new flag | A `--event` flag — a second door into one fact |
| D7 | `counts.transitioned` is present only when the run carries an event and a role declares a step | FR-011 requires byte-identical output for a run with no event; 012 FR-011 set this precedent for `counts.tasks` | An always-present count — changes every existing run's JSON |
| D8 | Budgets asserted by counting stand-ins, in runs separate from timing runs | 024 C4.2 measured a 61% distortion when the two are combined | Wall-clock assertions in CI — runners are an order of magnitude slower than a laptop |
