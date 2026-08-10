# Contract — Resolving and performing a lifecycle move

**Feature**: `specs/023-advance-board-position` | **Date**: 2026-08-10

This contract governs the sink's new availability reader and the planning rule that consumes it. It is
binding on **both ports**, and every numbered clause is asserted by at least one conformance scenario.

---

## §1 — When a move is considered at all

A move is considered for a recognised ticket when **all** of the following hold. The conditions are
evaluated in this order and the first failure ends the evaluation for that ticket, silently.

1. The run carries a lifecycle event.
2. The ticket's hierarchy role declares a step for that event (§2).
3. The ticket's current step differs from the declared step.
4. The safety decision for the ticket is `transition` — not `withhold`, not `halt`.
5. The ticket does not carry the impediment marker.
6. If the ticket is a sub-task, its task produced no completion outcome in this run (§7).

**No request is made to the tracker for a ticket that fails any condition.** A project declaring no mapping
therefore issues exactly the requests it issues today (FR-022, SC-003).

---

## §2 — Which mapping applies

The mapping is resolved **by the ticket's own hierarchy role**: `specification`, `story`, or `task`.

- A step name declared for one role never participates in another role's resolution, classification,
  warning, or order (FR-011).
- A role that declares nothing is never moved and produces no warning about not being moved (FR-012).
- The drift order and the status classification are derived from the same role's mapping, then handed to
  the engine unchanged — the engine remains unaware that roles exist.
- The halted designation stays project-wide and applies to every role.

---

## §3 — The availability read

One request per ticket for which §1 passed:

```text
GET {base}/rest/api/3/issue/{key}/transitions?expand=transitions.fields
```

This is the same request the sub-task completion pass already issues. It returns, for the current
credentials and the ticket's current step, every offered move with its destination name, its destination
category, and its transition screen's fields.

**Failure is fail-closed** (FR-020, Principle III): on any non-success outcome the reader emits nothing on
stdout and returns the transport's mapped exit code; the caller performs no move **and no content write**
for the affected specification and exits with the documented code. The read is issued during planning,
before any action is applied, so a failure leaves the ticket untouched.

---

## §4 — Selection

A candidate is an offered move whose **destination step name equals the declared step name**, compared
byte-for-byte.

- Selection is never by the move's own name, its position in the offered set, its destination category, or
  any step name built into the product (FR-002, Principle VII).
- A near miss — a difference of letter case or surrounding space — is **not** a match, and the step is
  reported unreachable rather than silently accepted.

---

## §5 — The five outcomes

| # | Condition | Action | Report | FR |
|---|---|---|---|---|
| 1 | Exactly one candidate, no required field on its screen | perform the move | counted as transitioned | FR-003 |
| 2 | Exactly one candidate, its screen requires a field | perform nothing | one warning naming the ticket, role, step, and field | FR-005 |
| 3 | Two or more candidates | perform nothing | one warning naming the ticket, role, step, and every candidate | FR-004 |
| 4 | No candidate | perform nothing | one warning naming the ticket, role, current step, declared step, and the reachable set | FR-007 |
| 5 | The read failed | perform nothing, write nothing for the specification | the documented fail-closed error | FR-020 |

**No preference is ever invented** in outcome 3, by any rule — not a naming convention, not an ordering, not
an operator tie-break (that would be a configuration key, which FR-017 forbids).

**No value is ever supplied** in outcome 2. In particular a value the team recorded as a creation-time
default for a field of the same name is not sent (FR-006): the two are recorded for different purposes.

**No intermediate move is ever performed** in outcome 4 to reach the declared step (FR-007). The reachable
set is reported so a human can act.

---

## §6 — Performing the move

```text
POST {base}/rest/api/3/issue/{key}/transitions
{ "transition": { "id": "<transition_id>" } }
```

Nothing accompanies the move — no field values, no comment, no resolution.

**If the tracker refuses the move** (typically because a human changed the ticket's step between §3 and §6),
the mirror reports the refusal naming the ticket and role, and **does not** retry it, re-issue the
availability read, or attempt another candidate within the same run (FR-021). The next run reconsiders from
wherever the ticket then stands.

**If the move succeeds but a workflow rule lands the ticket elsewhere**, the mirror reports where the ticket
actually stands. The next run classifies that position normally; nothing special is done about it.

---

## §7 — Precedence at the task role

Where sub-task mirroring is enabled and a workflow is declared for the `task` role:

- A sub-task whose task produced a completion outcome in this run — forward or backward — is governed by
  that outcome alone. The declared mapping does not also act on it (FR-016).
- A sub-task with no completion outcome is evaluated by this contract like any other ticket.
- The completion pass itself is unchanged. Its own selection remains by destination **category**, its own
  warnings keep their current wording, and no clause of this contract alters it.

Where sub-task mirroring is **disabled**, a `task` declaration is inert: no sub-task is created or moved,
and the mirror reports once that the declaration has no effect (FR-015). This is a note, not a failure.

---

## §8 — Independence

- One ticket's outcome never suppresses another's, in either direction, including between a parent and its
  own stories (FR-019).
- A withheld, ambiguous, gated, unreachable, or refused move never suppresses the ticket's content update,
  and a content update is never undone because a move did not happen (FR-019).
- Only a `halt` decision suppresses content, and it does so for its own ticket alone — unchanged behaviour
  (FR-018).

---

## §9 — Idempotency

- A ticket already standing at its role's declared step triggers no availability read, no move, and no
  warning (FR-008).
- A run over unchanged state performs zero moves, on every re-run (FR-009).
- Principle II names `transitioned` among the write kinds a second run must leave at zero; this feature is
  the first to make that count reachable, so the live double-run assertion is extended in the same change.

---

## §10 — Preview

Under `--dry-run` the availability read is still performed — it is a read, and the prediction is worthless
without it — and no move is issued. The predicted set names each ticket, its role, its current step and the
declared step, and reproduces every warning of §5 exactly as the real run would (FR-023, Principle XI).

---

## §11 — Both ports

Both implementations produce byte-identical output **and an identical request sequence** for every scenario
in this contract (FR-028). The sequence is where a divergence surfaces first, since this feature adds one
read and one write per moved ticket.

Windows watch-items carried from `docs/10-windows-portability.md`: the §5 warnings are multi-line prose
assembled from tracker data, so they are built through the port's output helper rather than a direct `jq`
call, and no glob pattern in the new code contains a CRLF literal.
