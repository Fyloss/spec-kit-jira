# Contract — resolving a declared step into a move, and emitting it

Covers spec FR-001…FR-009, FR-021, FR-024, FR-026…FR-028, FR-030…FR-038. Owner:
`sink/jira/transitions.sh` / `sink/jira/Transitions.psm1`.

The governing rule: **the move is found by the name of the step it lands on, against what the project
offers.** No built-in table of status names, no assumed ordering, no default workflow, and no preference
between candidates. Where the answer is not exactly one ungated move, the mirror reports and moves nothing.

## 1. Who is asked about, and when

A ticket enters the **due set** only when every one of these holds:

| # | Condition |
| --- | --- |
| D1 | The run carries a lifecycle event (`lifecycle-event.md` §2) |
| D2 | The ticket's own role declares a step for that event (`role-lifecycle-config.md` §4) |
| D3 | The ticket is recognised — bound, not blocked, not re-routed |
| D4 | Its current step differs from the declared step (FR-008) |
| D5 | `drift_evaluate` returned `transition` — not `withhold`, not `halt` — and the ticket does not carry the impediment marker |

D4 and D5 are what make the read cheap: the availability question is asked **after** the safety decision,
so it is never spent on a ticket that will not move. A run failing D1 or D2 asks nothing at all and costs
exactly today's requests (FR-026, spec SC-015).

Placement in the pipeline: inside the `plan` phase, in `plan_lifecycle`'s decision loop, before it returns
(research R2). That is the same computation `--dry-run` performs, which is what makes the preview exact
(FR-036), and it sits between the `recognition` and `plan` timing marks, so every request it issues is
attributed to `plan` and the per-phase counts keep summing to the run's total (FR-030).

## 2. The read

One function, two implementations of its request. **Every caller is identical under either branch.**

```
transitions_load <key>…          # populates the availability map; returns 0 always
transitions_get  <key>           # one availability record (data-model.md §3), or 1 on a miss
transitions_reset                # test support
```

The shape deliberately mirrors `prefetch_load` / `prefetch_get` / `prefetch_reset`, for the same reason:
the bulk-versus-per-key decision belongs to one module and must be invisible to its callers.

| Branch | Request | Chunking | Status |
| --- | --- | --- | --- |
| A | one bulk read carrying transitions **with** required-field detail | 100 keys per request, as `prefetch.sh` | **not selected** — no measured evidence `bulkfetch` returns `transitions` at all, let alone with required-field detail (research R1) |
| **C** | `GET /rest/api/3/issue/{key}/transitions?expand=transitions.fields` — the spelling `discovery_task_transition` already uses | one per due ticket | **selected** — this is the endpoint already proven in production; spec FR-027 is amended per `plan.md`'s Complexity Tracking |

**M1's outcome (research R1): branch C.** Decided from 021's dogfood-verified `bulkfetch` shape (no `expand`
member, no `transitions` array documented) and the per-key endpoint's existing production use, rather than
from a fresh live call — no dogfood credentials are reachable from the implementation environment. Every
task gated on branch A (T008, T040b, T040c, T043, T044, T057a, T148) is skipped; `transitions.sh` implements
only the per-key form below.

Failure handling, in both branches:

| # | Rule |
| --- | --- |
| F1 | A failure of the **bulk** form falls through to the per-key form, at today's cost and today's outcome. A failed optimisation is never a classification (FR-031) — identical to 021 prefetch invariant P2. |
| F2 | A failure of the **authoritative** read (per-key, retries exhausted) is fail-closed for the whole specification: no move and no content write for it, exiting with the documented code — matching `discovery_task_transition`'s existing treatment of the same read (FR-034). |
| F3 | Results are matched back to requested keys by comparing the returned key, case-insensitively — never by position. Anything unmatched is a miss, and a miss is re-read individually. |
| F4 | Chunk boundaries are unobservable: the outcome for a key list of any length equals the outcome for the same keys read one at a time. |

## 3. The rule

Given one availability record and one declared step name, exactly one of four outcomes
(`data-model.md` §4):

```text
candidates := [ m | m ∈ record.moves, m.to == declared_step ]     # exact string equality

|candidates| == 1 and candidates[0].gated_field == null   ->  move(candidates[0].id)
|candidates| == 1 and candidates[0].gated_field != null   ->  gated(candidates[0].gated_field)
|candidates| >= 2                                          ->  ambiguous(candidates)
|candidates| == 0                                          ->  unreachable([ m.to | m ∈ record.moves ])
```

| # | Rule |
| --- | --- |
| M1 | A candidate is identified **only** by `m.to`, the name of the step it lands on. Never by the move's own name, its position in the offered set, any ordering of steps, or any list of step names built into the product (FR-002). |
| M2 | Comparison is exact string equality against the tracker's own spelling. A difference in case or spacing is a different step, reported as `unreachable` rather than silently accepted (spec Assumptions) — accepting a near miss would mean guessing which step a team meant. |
| M3 | No preference is ever invented between candidates (FR-004). |
| M4 | A value recorded as a creation-time field default is never sent to satisfy a gate (FR-006). The two are recorded for different purposes and are never substituted. |
| M5 | No intermediate move is performed to reach a step that is not reachable in one (FR-007). |
| M6 | Where a move succeeds, the mirror does not verify where the ticket came to rest. The tracker confirms without returning a position; the next run reads the real position and reports any divergence as ordinary drift. The task tier has never verified its own moves either. |

`discovery_task_transition` keeps its own rule — selection by destination **category** — unchanged. The two
tiers answer different questions, and merging them behind a predicate parameter would be more indirection
than two callers justify (research D3).

## 4. What each outcome emits

The move is emitted through `_plan_transition_action` (`sink/jira/plan_apply.sh:979`), the single shared
POST site — the same one the task tier's completion pass uses. No second emission site is created.

| Outcome | Action | Warning / note | Counted |
| --- | --- | --- | --- |
| `move` | `POST /rest/api/3/issue/{key}/transitions` with `{transition:{id}}` | a note when the ticket carries open blocking links, exactly as today | `counts.transitioned` +1 |
| `ambiguous` | none | one warning per ticket | — |
| `gated` | none | one warning per ticket | — |
| `unreachable` | none | one warning per ticket | — |

Exact wording — every message names the ticket, its role, what did not happen, and what a human can do
(FR-038, Principle XVI):

```text
ambiguous    "<ROLE> ticket <KEY> was not moved to \"<STEP>\": <N> transitions land on it
              (<NAME> (<ID>), <NAME> (<ID>)). The bridge invents no preference — perform the
              one you want by hand, or narrow the workflow."

gated        "<ROLE> ticket <KEY> was not moved to \"<STEP>\": completing that transition
              requires \"<FIELD>\", which the bridge does not hold and never guesses.
              Set it by hand, then reconcile."

unreachable  "<ROLE> ticket <KEY> was not moved to \"<STEP>\": no transition from \"<CURRENT>\"
              lands on it. Reachable from here: <A>, <B>. Move it by hand, or map this event
              to one of those."

unreachable  "<ROLE> ticket <KEY> was not moved to \"<STEP>\": no transition from \"<CURRENT>\"
 (empty set)  is available at all. Move it by hand, or map this event to a reachable step."
```

**A silent drop is a defect.** Today `plan_lifecycle` drops the transition when `transition_id` is empty
(`plan_apply.sh:1140`) and says nothing; after this feature every non-`move` outcome carries exactly one
warning naming its ticket. This is the single most important behavioural assertion in the contract.

Every warning is non-blocking inside a lifecycle hook, and a run raising one records no run state, so the
next run reconsiders the ticket (`run-state-v2.md` S10).

## 5. What is untouched

| # | Rule |
| --- | --- |
| U1 | `engine/drift.sh` is consumed unchanged. `halt`, `withhold` and `transition` keep their current meanings and their current wording; the backward pull still requires `--on-drift=proceed`. |
| U2 | A withheld, ambiguous, gated, unreachable or rejected move never suppresses the ticket's content update, and a content update is never undone because a move did not happen (FR-033). |
| U3 | One ticket's outcome never suppresses another's, including between a parent and its stories (FR-033). |
| U4 | The impediment marker withholds the move and is itself neither set nor cleared. |
| U5 | Open blocking links produce a note and the move proceeds; no link is created, changed or removed. |
| U6 | A rejected move is reported naming the ticket, and is never retried, re-asked, or substituted within the same run (FR-035). |
| U7 | The privacy guard runs before the write as today. A transition body carries no composed text, so no new surface is scanned. |
| U8 | The specification tier produces the **same decisions and the same warning wording** as a story in the same situation (FR-021) — by construction, because both go through `drift_evaluate`, which composes its sentences from statuses alone and knows nothing of tiers. |

## 6. Budgets

| # | Budget | How it is asserted |
| --- | --- | --- |
| B1 | Zero availability requests for a ticket failing any of D1–D5 | counting stand-in over the recorded call log |
| B2 | Branch A: round-trips do not grow one-for-one with the due set. Branch C: no request for a ticket outside the due set | recorded call log on a 60-story specification with every ticket due a move |
| B3 | No external process per ticket, per candidate move, or per role; the count is unchanged when the due set doubles | 024's `PATH`-interposed shim (`contracts/spawn-budget.md` §4), in a run **separate** from any timing run — C4.2 measured a 61% distortion when combined |
| B4 | Every request attributed to the `plan` phase; per-phase counts sum to the run's total | asserted against the harness's own request log, not the instrument's self-report (024 SC-014) |
| B5 | No additional configuration open or parse for a second or third declared role | counting stand-in on config opens |

The Bash port follows `plan_lifecycle`'s decode-once shape (`plan_apply.sh:1032–1076`): one structured call
decoding the whole array, then a pure shell loop. Its `--slurpfile` temp-file spelling is not optional — a
single `jq` argument is capped at 128 KiB on Linux independently of `ARG_MAX`, and a hundred-story action
array crossed it (l. 1036–1047). Structured output goes through `lib/output.sh`, never a bare `jq`
multi-line write, and any path handed to `curl` keeps its `cygpath -m` spelling.

## 7. Idempotency

| # | Assertion |
| --- | --- |
| Z1 | A ticket already standing at the declared step: zero availability requests, zero moves, zero warnings (FR-008). |
| Z2 | A second run over unchanged state under the same event: zero writes of every kind — 0 created, 0 updated, **0 transitioned**, 0 commented, 0 linked, 0 labeled. Principle II's enforcement test requires this assertion list to be extended in the same change that makes a write kind non-zero, and this is that change. |
| Z3 | The live double-run suite gains the transition dimension, at both the story and specification tiers. |
| Z4 | `--dry-run` then the real run against the same state produce identical action sets, moves included, and the preview performs none. |

## 8. Scenario coverage

| Case | Assertion |
| --- | --- |
| One ungated move onto the declared step | Ticket stands at the step; `counts.transitioned` is 1 |
| Ticket already at the declared step | Zero requests, zero moves, zero warnings |
| No mapping declared | Zero requests; no `counts.transitioned` key at all |
| Team vocabulary — steps named nothing like the tracker defaults | Resolved by name alone |
| Two moves landing on the declared step | Zero moves; one warning naming both; content still mirrored |
| The same ambiguity on a later run | The same single warning; still zero moves |
| One gated move onto the declared step | Zero moves; one warning naming the field |
| A creation-time default recorded for a field of the same name | Not sent; the gated warning is unchanged |
| Declared step reachable only through an intermediate | Zero moves; one warning naming current, declared, and the reachable set |
| Declared step absent from the workflow entirely | Same, with the empty-set wording |
| Declared step differing only in case or spacing | Reported unreachable, never accepted |
| Parent and stories on different workflows, one event | Each lands on its own step; zero cross-role evaluations |
| Parent halted / flagged / drifted | Same decision and same wording as a story in that situation |
| Ticket moved by a human between the read and the write | Rejection reported naming the ticket; no retry, no re-ask, no substitute |
| Availability read fails outright | Fail-closed for the specification; zero moves and zero content writes; documented exit code |
| Bulk form fails, per-key form succeeds | Identical outcome; only the call log differs, and only by having more entries |
| 60 stories all due a move | Budgets B2 and B3 hold |
| `--dry-run` over every case above | Predicted set equals the real set; zero moves performed |
| Both ports, every case above | Byte-identical stdout, warnings, exit code, and recorded call sequence |
