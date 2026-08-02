# Contract — recorded field defaults

The normative behaviour both ports implement identically. Every clause here is asserted by a
conformance scenario, because a clause only one port satisfies is a defect (Principle VI).

Vocabulary: a **defaultable field** is one this bridge does not supply itself and whose shape can be
expressed as a recorded value; a **recorded default** is a value in `config.yml`'s managed region; an
**answer** is a value supplied for one run only.

---

## §1 Satisfiability — the one predicate both gates share

A required field of a written issue type is **satisfiable** when any of:

1. the bridge supplies it — `summary`, `description`, `issuetype`, `project`, `priority`, `reporter`,
   or `parent` where the child type's create metadata offers a parent link (unchanged from today); or
2. a recorded default exists for that project, that issue type, and that field label; or
3. an answer for it was supplied to this run.

Otherwise it is **unsatisfiable** and the gate refuses.

The predicate lives in one function. The configuration ceremony's gate and the reconcile's gate both
call it and neither carries its own copy. A change to this section is a change to one function in each
port.

**§1.1** The bridge-supplied list is a constant and is **not** extended by this feature. A field
becomes satisfiable because a human recorded a value, never because the bridge learned to invent one.

**§1.2** A field the parent type requires named `parent` is unsatisfiable regardless of any recorded
default — a parent has no parent. Unchanged from today.

---

## §2 Recording — what the ceremony asks and writes

**§2.1 Scope.** The ceremony asks about the issue types carrying the `specification` and `story` roles
and no others (FR-025). A type named through `--field-default` is additionally in scope for that run
(FR-026).

Within a type in scope, only a field Jira marks **required** produces a question (FR-002). A field
that is defaultable but optional is recorded without ever being asked about — through
`--field-default` or by writing the entry into `config.yml` by hand (FR-004) — because a written type
routinely carries dozens of optional fields and turning each into a question would make the ceremony
unusable.

**§2.2 Question order.** Per project, then per issue type in the order `specification`, `story`, then
any opted-in types in the order given; within a type, fields in the order `createmeta` reported them.
The order is fixed so two runs over one instance ask the same questions in the same sequence, on both
ports.

**§2.3 Question shape.** Every question names the field by its `logical_name`. A field with a
non-empty `allowed_values` is a **closed** question over exactly those values; anything else is an
open question for a scalar. A field with `defaultable: false` is not asked about and is reported once
with its `undefaultable_reason` (FR-010) — that report exists to explain why a field that *blocks* a
creation cannot be defaulted. A field with `required: false` is neither asked about nor reported, even
when its shape is undefaultable: an optional field the team has said nothing about is not a finding,
and listing every attachment field of every type would bury the one report that matters.

An entry recorded by hand for an optional field is validated exactly as an answered one: §2.4's
refusals apply to it in full, and §2.6 carries it forward unchanged.

**§2.4 Refusals at recording time.** Each produces zero writes to any file:

| Input | Refusal |
| --- | --- |
| empty value | names the field, states that a default may not be empty (FR-008) |
| value outside `allowed_values` | names the field and lists the accepted values (FR-003) |
| unknown issue-type name | names it and lists the types the project offers (FR-026) |
| unknown field label for that type | names it and lists the defaultable fields of that type |
| credential- or identity-shaped value | the existing `config.yml` credential scan, unchanged, naming the path and the shape but never the value (Principle IV) |

**§2.5 Where it is written.** Into the managed region of `config.yml`, spliced by the shared managed
section machinery. Bytes outside the region are preserved verbatim; the host's dominant line ending is
respected; malformed markers refuse with exit `4` and zero writes rather than being guessed at.

**§2.6 Idempotence.** A ceremony run whose answers match the recorded ones rewrites the region to the
same bytes, so the file is byte-for-byte unchanged (FR-007). An already-recorded value is presented as
the current answer and keeping it requires no input.

**§2.7 Degraded mode.** With no credentials the ceremony performs no `createmeta` read, therefore
knows no required-field set, therefore asks nothing and records nothing (FR-009).

**§2.8 Reporting.** A recorded entry naming an issue type or field the project no longer offers is
reported as orphaned (FR-008). A recorded entry for a type the bridge does not write is reported as
recorded but not yet consumed, naming the type (FR-027). Neither is an error and neither blocks.

---

## §3 Applying — what a reconcile run does

**§3.1 Resolution and precedence.** For each pending creation, for each defaultable field of its issue
type: an answer supplied to this run wins; otherwise the recorded default; otherwise the field is
absent from the payload. An answer never outlives the run that received it (FR-012).

**§3.2 Merge point.** Values are merged into the create payload by the single shared base builder, so
every creation path acquires them identically. The update payload is built by a different branch that
never calls it: **no default can reach an update** (FR-017).

**§3.3 The consolidated question.** The planning pass emits the question when the plan contains at
least one pending creation for which either

1. a **recorded default would be sent** — the team wrote a value and it is about to land on a real
   ticket; or
2. a **required field is unsatisfiable** under §1 — the run needs a value nobody has recorded;

*and* the project's `ask` switch is on, *and* `--accept-defaults` was not given. The run then stops
before any write and emits exactly one `confirmation-pending` object naming every such field once,
with its recorded value where one exists and `null` where none does. Exit code `0`; zero Jira writes;
zero file writes.

A field that is merely **defaultable** is not a trigger. A project whose written types carry optional
custom fields, with nothing recorded against them, is asked nothing at all — that is what keeps §5.1
true, and it is the reason the trigger is stated in terms of what the run would *send* rather than of
what the type *offers*.

**§3.4 Never asked.** No question is emitted when the plan contains no creation (FR-013), when `ask` is
false (FR-014), when `--accept-defaults` is given (FR-015), or when neither of §3.3's two triggers
fires — no creation would carry a recorded default and every required field is already satisfiable
(FR-028).

**§3.5 Answering.** The agent re-invokes with `--field-value KEY=Type=Label=Value` (repeatable) and/or
`--accept-defaults`. The writing pass re-plans from the same inputs and writes. An answer applies to
every creation in that run.

A **decline** — the operator dismisses the question, or the conversation ends before they answer — is
answered the same way: the agent re-invokes with `--accept-defaults`, so the recorded values apply and
a field with no default falls to §3.6. There is no decline flag and no decline signal. The bridge
receives one instruction, *proceed with what is recorded*, and §4.2 reports that reason rather than
guessing at the operator's intent.

**§3.6 The surviving refusal.** When a required field is unsatisfiable after §3.1 and no answer can be
obtained, the run refuses for that specification: zero writes, the pre-existing exit code, and a message
that names each unsatisfiable field by label and carries the copy-pasteable
`speckit.jira.config --field-default …` line that records it permanently (FR-016).

**§3.7 A rejected value.** When Jira rejects a creation because a defaulted value is invalid, the run
reports the field by label, the value it sent, and the rejection in human terms. It does not substitute
another value and does not retry (FR-019).

**§3.8 Never writes the config.** No reconcile run, hook-fired or not, modifies `config.yml`. The
summary prints the command that would record an answer permanently; adopting it is the operator's act
(FR-021).

**§3.9 Non-blocking.** Every clause of §3 is subject to the existing hook wrapper: whatever happens
here, the host spec-kit command's outcome is unchanged and the developer sees at most one warning line
(FR-020, Principle III).

**§3.10 Declaring an unreachable operator.** Whether anyone can answer is **stated by the caller**,
never inferred by the entry point (research R4: no TTY sniffing — untestable without a pty harness,
divergent between the ports, and wrong anyway, since the bridge is invoked by an agent and so never
has a TTY even when the operator is very much reachable). A caller that cannot reach an operator — a
continuous-integration pipeline, an unattended agent run, a direct script invocation — MUST pass
`--accept-defaults` on its **first** invocation; §3.4 then applies, and §4.2 names the reason.

An `after_*` hook is **not** such a caller. It fires the agent command `speckit.jira.reconcile`, so
the agent is present and conducts the conversation of §3.5. A hook-fired run therefore stops at the
question exactly as an ordinary run does, and §3.9 keeps the host command green while it waits.

---

## §4 Reporting

**§4.1** The summary names every field the run filled and attributes each value to `team-config`,
`operator-answer`, or the bridge. The raw payload is never printed (FR-022).

**§4.2** When the question was skipped, the summary states which of §3.4's reasons applied (FR-015).

**§4.3** The preview and the real run compute field values through the same code path, so a `--dry-run`
report and the subsequent run cannot disagree about any value (FR-023). The preview emits no question
and writes nothing.

---

## §5 Inertness

**§5.1** With no recorded default anywhere, every command's output is byte-identical to the release
preceding this feature: no question, no summary line, no payload field (FR-028).

**§5.2** Removing a recorded default stops the bridge sending that field on the next creation, with no
other action required. If the field is required, §3.6's refusal returns — the correct outcome, and the
reason removal is the off switch rather than a separate one (FR-029).

---

## §6 Exit codes

No new exit code. The feature narrows when the existing ones fire.

| Situation | Code | Change |
| --- | --- | --- |
| unsatisfiable required field, no default, no answer | existing config code | narrowed: fires only when §1 finds no satisfier |
| malformed managed-section markers in `config.yml` | `4` | same code the README splice already returns |
| value outside `allowed_values`, empty value, unknown type or label | existing config code | new situations, existing code |
| credential-shaped recorded value | existing credential-scan code | unchanged path |
| consolidated question pending | `0` | not a failure — the run simply has not written yet |
