# Phase 0 — Research

Nine decisions. Each was taken against the code as it stands, and each names what was rejected.

---

## R1 — Where the target guard sits, and the one requirement it cannot satisfy literally

**Decision**: The guard runs in `cmd_reconcile` immediately after the positional argument is
resolved (`scripts/bash/commands/reconcile.sh` L401-413), which is **after** the operator dispatch
guard at L386-399 and **before** everything else — the base-URL read, the bridge-availability check,
the config load, credential resolution, routing, and every marker splice.

**Rationale**: FR-001 requires the refusal to precede any configuration read, any network call and
any file write. That is satisfied: the only thing ahead of it is the dispatch guard, which reads the
operator's disable record and, when the event is disabled, returns `0` in silence.

That ordering means an event the operator **disabled** never reports a rejected target. FR-005 says
the guard must behave identically however the run was dispatched, so this is a literal deviation,
and it is deliberate. Feature 003's FR-020 states the opposing rule in stronger terms than FR-005
states this one: a disabled event must produce no output at all, because "a warning on every single
lifecycle command for an event the operator deliberately turned off is precisely the noise the
design forbids". A repository with a broken caller and `after_plan` disabled would see the rejection
line on *every* `/speckit.plan` — exactly that noise. A disabled event also creates nothing, so the
duplication FR-001 exists to prevent cannot occur there.

**Alternatives considered**:
- *Guard first, before the dispatch guard.* Satisfies FR-005 to the letter and breaks 003's FR-020.
  Rejected: it trades a silent, correct outcome for a recurring message about a run that was never
  going to write anything.
- *Guard first, but silent when the event is disabled.* Same outcome as the chosen order, reached
  through two coupled conditions instead of one ordering. Rejected on KISS grounds.

**Flagged to the operator**: this is the one requirement the design bends. If the disabled-event
case must also report, say so and the order flips.

---

## R2 — Refuse the wrong target, never redirect to the sibling `spec.md`

**Decision**: A target whose file name is not `spec.md` refuses. The message *names* the sibling
`spec.md` when the same folder holds one, but the run does not act on it.

**Rationale**: The reported defect is a caller that named the wrong artifact. A redirect would make
that caller's defect invisible — the mirror would silently work, the agent would keep passing
`plan.md`, and the next behaviour that depends on the target being correct would fail somewhere else
with no history. A refusal that names the correct file costs the operator one line and fixes the
caller.

**Alternatives considered**: silent redirect (rejected above); redirect with a warning (rejected —
it writes to Jira on a run whose caller is known to be wrong, and Constitution III says the write
path is the last thing that happens after every decision is already made, not something a warning
excuses); a `--force` escape hatch (rejected under YAGNI — no requirement names one, and its only
user would be the defect).

---

## R3 — The comparison is on the basename, and only the basename

**Decision**: The guard compares the **basename** of the target against the literal `spec.md`, using
each port's own path-splitting primitive (`basename` semantics in bash, `Split-Path -Leaf` in
PowerShell). It is not a suffix test, not a glob, and not a substring search.

**Rationale**: Three failure modes ruled out at once. A suffix test (`*spec.md`) accepts
`my-old-spec.md`. A glob written with `[[ == ]]` is where this repository's known Windows pattern
hazard lives — `docs/10-windows-portability.md` and the MSYS matcher note — so a plain string
equality on an already-split component avoids the class entirely. And a substring search accepts
`spec.md.bak`.

Consequences accepted deliberately: the comparison is **case-sensitive**, so `SPEC.MD` refuses. On a
case-insensitive filesystem the file `SPEC.MD` can be opened as `spec.md`, but only the spelling the
caller passed is judged — the caller is an agent following a document that spells it `spec.md`. The
edge case is in the spec and the refusal names the expected file, so the operator is never stuck.

A path carrying a Windows separator is split by the port's own primitive, so `specs\001-x\plan.md`
refuses and `specs\001-x\spec.md` passes on the port where that spelling is native.

---

## R4 — The label rides `spec_ref.spec_slug`, and both sides of the comparison are normalised

**Decision**: The provenance value is the neutral document's existing `spec_ref.spec_slug`. The sink
renders the label as `speckit-` + that value. Desired labels on an update are
`(current_labels + [provenance]) | unique`; the plan context carries the ticket's current labels
already `unique`-normalised.

**Rationale**: Two findings made this cheap.

*The engine already emits it.* `interchange_build` writes `spec_ref` into the neutral document and
`interchange_validate` already enforces `spec_ref.spec_slug` against `^[0-9]{3}-[a-z0-9-]+$` — which
is precisely the `001-test-page` shape the operator asked for. `plan_writes` already reads from the
document (`.routing.project_key`). So no schema change, no engine change, and Constitution VIII is
satisfied without inventing a neutral field.

*Zero churn is decided by a comparison that is order-sensitive.* `idempotency_field_status`
(`engine/idempotency.sh` L36) compares each desired key with `jq`'s `==`, and jq compares arrays
**by position**. If the desired list were built in one order and Jira returned another, every run
would re-send the labels forever — a churn bug hiding inside the feature meant to be free of it.
Normalising both sides with `unique` (which sorts and deduplicates) makes the settled state compare
equal. Sending a sorted list is harmless: a label set has no order.

The union is also what protects the operator's own labels. Jira's `PUT` replaces the whole `labels`
array, so sending the union is simultaneously the merge rule of FR-012 and the reason FR-013's zero
churn holds.

**Alternatives considered**: a new `provenance` field on the neutral document (rejected — a second
spelling of a value the document already carries); comparing labels set-wise inside
`idempotency_field_status` (rejected — it is a shared primitive used by every field, and teaching it
one field's semantics is exactly the coupling Constitution VIII avoids); using `basename(folder)`
instead of the slug (rejected — the slug is the document's own validated identity of the
specification, and it honours the existing `SPEC_KIT_JIRA_SPEC_SLUG` seam the tests rely on).

**Known limitation, not introduced here**: `interchange_validate` already rejects a slug that is not
`NNN-lowercase-slug`, so the host's timestamp numbering style would fail validation today, before
this feature is reached. The label inherits that constraint rather than adding one.

---

## R5 — The `speckit-` prefix is a sink literal, not configuration

**Decision**: The prefix is the fixed string `speckit-`, written in the sink.

**Rationale**: The operator asked for a label that says the ticket came from Spec Kit and names the
specification. One token carries both. A configuration key would add a fourth thing to answer in the
config ceremony, a migration for repositories that already have labelled tickets under the old
value, and a per-project resolution path through the plan context — for a need no requirement
states. Constitution XV.

**Alternatives considered**: `adoption.label_prefix`-style config key (rejected, above); two labels,
one generic and one specific (rejected — the generic one is derivable by prefix search from the
specific one).

---

## R6 — A project that cannot hold the label warns; it never refuses

**Decision**: When the routed project's create metadata does not offer `labels` for the type being
written, or the rendered token cannot be held as a label, the run mirrors everything else unchanged
and emits one named warning. It never refuses and never lets the label cost a ticket its write.

**Rationale**: Constitution VII. The bridge already refuses, loudly and before any write, for a
required field it cannot satisfy — that refusal exists because the ticket *cannot be created*
without it. A label is additive: without it the mirror is exactly as correct as it is today, minus
one piece of evidence. Turning a cosmetic capability into a hard refusal would break repositories
that work today, which is the opposite of the defect this feature closes.

**The detection is already in the binding.** `_disc_defaultable_fields`
(`sink/jira/discovery.sh` L188-205) records, per issue type, *every* field that type's create
metadata reports and the bridge does not itself supply — and it names `labels` explicitly as an
array-shaped field it marks `defaultable: false` with a readable reason. So the binding already
answers "does this type's create screen offer `labels`?" and nothing new is fetched. The rule is
three-valued:

| `defaultable_fields[<type>]` | Contains a `labels` entry | Behaviour |
| --- | --- | --- |
| recorded | yes (`defaultable: false` included — presence is the signal) | send the label |
| recorded | no | omit it, one warning (FR-014) |
| not recorded at all | — | send it — a binding that predates the metadata recording is already in a "refresh your binding" posture, and this feature must not add a second reason to refuse |

---

## R7 — The duplicate probe is best-effort by nature, and the plan says so

**Decision**: Build the probe (FR-022–FR-026), fire it only when the run is about to create a parent
for which it holds no marker, refuse on a hit, and proceed with one warning when the search cannot
be performed. Document that it reduces duplication and cannot eliminate it.

**Rationale**: `sink/jira/recognition.sh` opens with the reason recognition reads **by key and never
searches**: "Jira's index is eventually consistent, and this is the reported defect's exact window".
Feature 005 removed search from the recognition path because a lagging index reported *no such
ticket* for a ticket that existed, and the run duplicated it. That physics is unchanged here.

What differs is the direction of the error. Recognition asked the index a question whose false
negative caused a write. The probe asks a question whose false negative merely leaves today's
behaviour in place, and whose true positive prevents a write. It cannot create a duplicate; it can
only fail to prevent one. That asymmetry is what makes it defensible where search-based recognition
was not — and it is also why the marker line, not the probe, remains the mechanism SC-001 rests on.

**Fail-open, deliberately**: any non-2xx — no JQL capability on the site, no browse permission, an
endpoint that has moved — takes the warn-and-proceed path. A supplementary guard that cannot be
consulted must not block a mirror that was correct before it existed. This is bounded: it applies
only to this probe, and only to the read.

**Alternatives considered**: making the probe authoritative and refusing when the search fails
(rejected — it would break every site without search permission, turning an additive guard into an
outage); probing on every run rather than only before a parent creation (rejected — a request on
every settled run, for a question that can only matter when something is about to be created).

---

## R8 — The privacy guard and the run summary need no change

**Decision**: Neither is modified. Both are verified by test rather than assumed.

**Rationale**: `plan_apply.sh` scans each action's whole content `body` before any write, and the
label lands in `body.fields.labels`, so it is already inside the scanned region — the ordering
"guard, then write" is untouched. The run summary reports actions with their bodies, so `--dry-run`
shows the exact labels a real run would send, satisfying FR-015 with no new summary field.

Two tests pin this rather than trusting it: one asserts a BLOCK-tier string placed in a folder name
is caught in the label, and one asserts the dry-run action set is byte-identical to the real run's.

---

## R9 — The stray-marker scan is a filesystem read, not a ledger

**Decision**: FR-007's warning is produced by scanning the feature folder's top-level files for the
bridge's marker framing comment, at run time. No index, no ledger file, no state.

**Rationale**: A ledger of "files that should not carry markers" would be state to write, to keep in
sync, to gitignore or commit, and to migrate. The question — *does any sibling of this `spec.md`
carry a marker line?* — is answerable from the filesystem in one pass, every time, with no
possibility of drifting from the truth. Constitution I and XIV both point the same way.

Scope: top-level files of the feature folder, excluding `spec.md`; no recursion. The reported damage
(`plan.md`) is top-level, and every host-produced artifact that a hook could plausibly hand the
mirror is too. Recursion into `contracts/` would widen the read for no reported case.

The function lives beside the marker grammar it reuses (`engine/marker_splice.sh`, which owns the
framing comment) and carries no tracker vocabulary, so the engine/sink boundary test stays green.

**Alternatives considered**: recording stray files in the local binding (rejected, above); repairing
them automatically (rejected — the spec puts repair out of scope, and rewriting a file the mirror
does not own is precisely the defect being fixed, in the opposite direction).
