# Phase 0 — Research

Seven decisions. Each one was taken by reading the shipped code rather than by choosing an approach
in the abstract, because in every case the project already contains a mechanism that solves most of
the problem, and the cheapest correct design is the one that extends it.

Line references are to the state of `main` at 2c2e481.

---

## R1 — Where recorded defaults live, and who writes them

**Decision.** A top-level `field_defaults:` mapping in `.specify/jira/config.yml`, inside a
marker-delimited region written by the entry point through the existing
`managed_section_splice` (`scripts/bash/engine/managed_section.sh:92`, `ManagedSection.psm1`).
Keyed project → issue-type name → field label → value.

**Rationale.**

The spec pins three things that together leave exactly one option. FR-005 puts the defaults in the
*committable* layer, because they are a team decision reviewable in a pull request (Principle V).
SC-002 says the operator records them "with no manual editing of the configuration file". FR-007
requires a re-run over an unchanged project to leave that file byte-for-byte identical.

The committable layer has never been machine-written. Everything the ceremony resolves today lands in
the gitignored `config.local.yml`, and where the operator must change `config.yml`, the bridge prints
the YAML and the human pastes it — `role_promotion_note` (`sink/jira/hierarchy.sh:315`) is the shipped
example, and `commands/speckit.jira.config.md` instructs the *agent* to persist the project key the
same way. That idiom cannot satisfy SC-002, and an agent-written file cannot satisfy FR-007: byte
identity is not a property a model can be relied on to produce.

Writing the file therefore falls to the entry point. A whole-file round trip is available and would be
faithful to the data — `config_yaml_to_json` (`lib/config.sh:426`) then `config_to_yaml`
(`lib/config.sh:532`) — but it reconstructs the document from its parsed JSON and so erases every
comment in it. `templates/config.yml.template` is 88 lines of which roughly 60 are explanatory
comments, and Principle XVI requires exactly that: "a tech lead must be able to review their team's
config without opening the documentation". Destroying those comments on the first ceremony run is not
an acceptable cost.

`managed_section_splice` resolves the tension and is already in the tree. It replaces only the bytes
between two markers, preserves every byte outside them verbatim, re-renders the block with the host's
dominant line ending, appends the region once when the markers are absent, and refuses with exit 4 and
zero output when the markers are malformed. It is already used to splice the extension's block into a
consumer's `README.md`, is already exercised on the Windows probe, and is in `engine/` precisely
because it knows nothing about what it is splicing.

**Why top-level rather than under `projects[]`.** `priority_map` and `hierarchy` live under
`projects[]`, and matching them would read better. But a managed region has to be a contiguous byte
range, and the entries of a YAML sequence are not: placing the region inside one `projects[]` item
means the bridge either owns that item's other keys or writes a region that is not contiguous. A
top-level mapping keyed by project key gives the same scoping with a region the splice can express.
The schema's top-level key allowlist (`lib/config.sh:628`) gains one entry.

**Alternatives considered.**

- *Print-only, operator pastes* — the shipped idiom. Rejected: fails SC-002.
- *The agent writes it* — the shipped idiom for the project key. Rejected: makes FR-007 unachievable
  and moves a correctness guarantee into the model, against the ceremony's stated
  model-independence.
- *Whole-file round trip* — rejected: destroys the operator's comments (Principle XVI).
- *Store in `config.local.yml`* — trivially writable, already canonical. Rejected: the defaults would
  stop being a team decision, contradicting FR-005 and Principle V's layering.

---

## R2 — How a recorded default reaches the create payload

**Decision.** Resolve the defaults to `{issue-type-id: {field-id: value}}` when the plan context is
built, and merge them in `jira_create_fields_base` (`sink/jira/ticket.sh:56`), the single builder both
creation paths already share. The UPDATE branch of `plan_writes` is not touched.

**Rationale.**

The estimation field is the same problem, already solved, and its solution is three lines. The plan
context carries `estimation_field_id`; `plan_writes` merges it into the create payload with
`. + {($fid): $v}` and never re-sends it on update (`sink/jira/plan_apply.sh:120`, and the comment at
line 137: "the estimation is NEVER re-sent (FR-018)"). A recorded default is the generalisation of
that: a config-derived field id and a config-derived value, applied on creation only.

Putting the merge in `jira_create_fields_base` rather than in each caller matters. That function's own
comment says it exists so `_ticket_create_body` and `plan_writes` "cannot drift apart again" — a
defect that has already happened once in this codebase. One merge point means the story creation, the
parent creation, and the standalone ticket creation all acquire defaults together or not at all.

Create-only (FR-017) is then true by construction rather than by discipline: the update branch builds
its `fields` object from scratch and never calls the base builder, so there is no code path by which a
default could reach an update. The spec's assumption that defaults follow "the create-only convention
the estimation field already ships under" is not an analogy — it is the same branch of the same
function.

**Alternatives considered.**

- *Merge in `apply_writes`* — rejected: too late for FR-023. The preview must predict the exact value,
  and the privacy guard scans the assembled body before the POST; both need the value present at plan
  time.
- *Merge in each caller* — rejected: reintroduces the drift the shared builder was written to prevent.

---

## R3 — Resolving a human label to a field id, and knowing a field's allowed values

**Decision.** Extend the per-type metadata discovery persists, from
`{logical_name, field_id}` to `{logical_name, field_id, schema_type, required, allowed_values}`, and
persist it per issue-type id in `config.local.yml` under `defaultable_fields`. `config.yml` is keyed
by label; the id is resolved through this map at plan time.

**Rationale.**

`config.yml` must speak in labels — Principle XVI forbids "opaque ids when a logical name exists", and
FR-002 and FR-016 require every message to name a field the way Jira does. The payload must speak in
ids. Something has to hold the correspondence, and it belongs in the gitignored machine-owned layer
where every other resolved id already lives.

Three of the spec's requirements need more than today's two keys.

- FR-003 asks a *closed* question over Jira's allowed values, and FR-019 must explain a rejection in
  terms of a value that no longer exists. Both need `allowedValues` from `createmeta`, which
  `_disc_required_fields` (`sink/jira/discovery.sh:182`) currently discards.
- FR-004 records defaults for fields Jira does *not* require, which that same function filters out by
  `select(.required == true)`.
- FR-010 decides whether a field's shape can be expressed as a recorded value at all, which needs
  `schema.type`.

The project-wide `fields` catalogue from `GET /field` is already fetched and already shaped as
`{logical_name, id, schema_type, custom}` in the discovery output (`discovery.sh:315`), but it is
dropped by `config_resolved_ids_for` (`commands/config.sh:102`) and is project-wide rather than
per-type — it cannot answer "is this field required *on this issue type*" or "what may it hold *on
this screen*". The per-type createmeta read is the only source that can, and the ceremony already
performs it for every role it resolves (`commands/config.sh:589`). No new request is added; the
existing response is simply not thrown away.

**Size note.** `allowed_values` on a large single-select can be long. The file is gitignored,
machine-owned, and already carries the full status and priority catalogues, so this is consistent with
what the layer holds today. It is persisted rather than re-fetched because FR-019 must explain a
rejection during a reconcile run, which performs no createmeta read.

---

## R4 — Asking a question without making the bridge interactive

**Decision.** Neither port ever reads stdin. The entry point emits what it needs as structured output
and the agent re-invokes it with the answer, exactly as the ceremony already does for the project key,
the project style, and the role mapping. Whether the operator is reachable is stated by the caller
through `--accept-defaults`, never sniffed from a TTY.

**Rationale.**

Every "closed question" the ceremony asks today is asked by the *agent*, not by the script. The
mechanism is visible in `role_unresolved_message` and `ConvertTo-JiraRoleUnresolvedJson`
(`sink/jira/hierarchy.sh`, `Hierarchy.psm1:249`): the entry point refuses, prints one closed question
per unresolved role, and the agent re-invokes with `--issue-type KEY=role=name`. The command document
is explicit that "the entry point does **not** prompt".

This is not a stylistic preference. A script that blocks on stdin cannot run under
`tests/conformance/run-scenario.sh`, cannot run in CI, and cannot be driven by an agent. Byte
equivalence between the ports (Principle VI) is asserted by capturing stdout; an interactive prompt has
no stable bytes to capture.

TTY detection was considered for FR-015's non-interactive case and rejected. It is untestable without
a pty harness, it differs between Bash and PowerShell, and it would answer the wrong question anyway:
the bridge is invoked by an agent, so it never has a TTY even when the operator is very much reachable.
An explicit flag states the caller's situation, is trivially testable, and is byte-identical across
ports.

---

## R5 — Making both existing gates defaults-aware with one change

**Decision.** Give `hierarchy_unsatisfiable_fields` (`sink/jira/hierarchy.sh:361`) a third input — the
recorded defaults for the type being checked — and treat a field with a recorded default as
satisfiable. Do not touch either call site's logic.

**Rationale.**

The refusal the feature exists to remove is produced in exactly one place. `hierarchy_mandatory_gate`
(`hierarchy.sh:393`) calls `hierarchy_unsatisfiable_fields` for the parent type and the child type, and
that gate is called from two places: the configuration ceremony (`commands/config.sh:604`) and the
reconcile (`commands/reconcile.sh:524`). Making the *field-level* predicate defaults-aware makes both
gates defaults-aware, in both ports, with no change to either caller.

This is worth stating because the obvious alternative — teach the reconcile to skip the gate when
defaults exist — would leave the configuration ceremony still refusing, and the ceremony is precisely
where the operator is standing when they record the answers. It would also duplicate the satisfiability
rule in a second place, which is how the two creation paths drifted apart before.

The existing satisfiable-by-the-bridge list stays a constant and is not extended: the bridge does not
learn to supply new fields, it learns that the team supplied one.

---

## R6 — Proving the feature is invisible when unused

**Decision.** Absence is the off switch at every layer: no `field_defaults` key ⇒ no resolved map in
the plan context ⇒ `jira_create_fields_base` merges nothing ⇒ the payload is byte-identical to today.
Prove it with a conformance scenario modelled on the existing `sc009-core-untouched.json`.

**Rationale.**

FR-028 and SC-010 are the strongest claims in the spec — every command's output byte-identical to the
release before the feature — and they are the ones a reviewer is least able to verify by reading. The
corpus already contains the pattern for asserting exactly this: `sc009-core-untouched.json` exists to
prove an earlier feature changed nothing for repositories that did not use it. Reusing that shape is
both cheaper and more convincing than an argument.

The design makes the claim structural rather than aspirational. There is no "defaults disabled" branch
to get wrong; the map is empty and the merge is a no-op.

---

## R7 — What the privacy and credential guards need (almost nothing)

**Decision.** Add no guard. Verify by test that both existing guards already cover recorded values, and
that `field_defaults` is not accidentally exempted.

**Rationale.**

Two guards already stand between a recorded value and Jira, and a defaulted value walks into both
without being invited.

- `_cfg_credential_errors` (`lib/config.sh:554`) scans every scalar in the parsed `config.yml` for an
  Atlassian token prefix, a vendor host, or an email address, and excludes exactly one subtree:
  `privacy.*`. A top-level `field_defaults` is scanned with no change, which is what FR-024 and the
  spec's identity-shaped-value edge case require. The plan must ensure no exemption is added.
- `privacy_guard_scan` (`sink/jira/ticket.sh:86`) runs over the assembled create body before the POST.
  Because R2 merges defaults at plan time, a defaulted value is inside that body and is scanned like
  any other field.

The only work is the test that proves it, and the discipline of not adding an exemption. Recorded as a
decision because "we added nothing here" is exactly the kind of claim that needs a written reason.
