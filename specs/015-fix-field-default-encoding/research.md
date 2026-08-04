# Research — A Recorded Field Default Is Sent in the Shape Its Field Accepts

**Feature**: 015 | **Date**: 2026-08-04 | **Phase**: 0

Every decision below was taken by reading the shipped code on both ports, not by inference. Line
references are to the tree as of `f52c930`.

---

## R1 — Where the encoding happens

**Decision**: inside `plan_resolve_field_defaults` (`scripts/bash/sink/jira/plan_apply.sh:73`) and its
twin `Get-JiraPlanResolveFieldDefault` (`scripts/powershell/sink/jira/PlanApply.psm1:40`).

**Rationale**: this is the single point where the recorded value and the field's declared type are
already in the same scope. The resolver receives `defaultable_fields_by_type_json` — the very array
discovery built at `discovery.sh:215`, carrying `schema_type` and `allowed_values` next to `field_id`
— and today uses it for one thing only: to turn a label into a field id (`fieldIdFor`). The type is
one property away on an object the function already holds. No signature changes, no metadata threaded
through additional callers, and both creation paths inherit the change because both read the resolved
map rather than the recorded one.

**Alternatives considered**:

- *Encode in `jira_create_fields_base`* (`sink/jira/ticket.sh:64`), the single builder both creation
  paths share. Rejected: the builder receives only `{type_id: {field_id: value}}` and would need the
  whole `defaultable_fields` map threaded in as a fifth parameter, past two call sites in `plan_writes`
  and one in `_ticket_create_body`. Strictly more plumbing for the same payload — Principle XIV.
- *Encode at discovery time*, storing an already-shaped value in the binding. Rejected: the binding
  would then hold a wire fragment rather than the metadata it describes, and re-running discovery would
  rewrite the local layer for no observable reason (Principle II).

---

## R2 — How the operator's own words survive the encoding

**Decision**: the resolver emits **two** parallel maps. `field_defaults` keeps holding exactly what it
holds today — the value as the operator recorded it. A new sibling, `field_defaults_encoded`, holds the
same map with each value shaped for the wire. Only the plan-context assignment switches to the encoded
map; every other consumer keeps reading `field_defaults` and is not touched at all.

**Rationale**: three operator-facing surfaces read the resolver's output today, not one. The bug report
named the first; reading the code found the other two:

| Surface | Reads | What it prints |
| --- | --- | --- |
| Consolidated confirmation question | `plan_confirmation_fields` ← `gate_resolved.field_defaults` (`reconcile.sh:846`) | `recorded_value` per field |
| Provenance note | `_reconcile_field_default_notes` ← `gate_resolved` (`reconcile.sh:210`) | `… = "<value>" — sent from <source>` |
| Promotion command | same function (`reconcile.sh:212`) | `--field-default '<proj>=<Type>=<Label>=<value>'` |

The third is the decisive one. It is a command the operator is told to **run**, and it writes its
argument straight back into `config.yml`. An encoded value there would instruct the operator to record
`{"value":"…"}` as their team default — a wrong instruction that corrupts the committable config on
the next ceremony. De-encapsulating at display would have to be got right at three sites and at every
site added later.

Two maps make all three correct by construction and require no inverse transform anywhere. An encoding
you must invert to display is a lossy round trip: `{name: v}` and `{value: v}` are distinguishable, but
an operator's hand-written `{id: "10001"}` is not distinguishable from something the bridge wrapped, so
any inverse is a guess. Keeping the original costs one map and guesses nothing.

**Consumers and which map each reads** (the complete list — verified by grep):

| Call site | Map | Why |
| --- | --- | --- |
| `reconcile.sh:316` → plan context → `plan_writes` → `jira_create_fields_base` | **encoded** | the only path that reaches Jira |
| `reconcile.sh:551` `gate_resolved` → `hierarchy_mandatory_gate` | recorded | presence of a key, never the value |
| `reconcile.sh:846` `plan_confirmation_fields` | recorded | FR-009 — satisfied with zero code change |
| `reconcile.sh:982` `_reconcile_field_default_notes` | recorded | provenance + promotion command |
| `config.sh:962` → `hierarchy_mandatory_gate` | recorded | presence of a key, never the value |

So FR-009 and FR-018 are met by *not* changing those sites, and exactly one line per port moves to the
encoded map.

**Alternatives considered**:

- *The bug report's proposal*: encode in place and de-encapsulate at display with `.value // .name // .`.
  Rejected on the evidence above — it addresses one of three surfaces, and the two it misses include a
  command that writes back to the team config. An inverse transform is also the wrong shape of solution:
  it can only ever guess which key held the operator's words, and a recorded value that legitimately *is*
  an object (the escape hatch of US1 scenario 6) is indistinguishable from an encoded one.
- *Encode at the last moment inside `plan_writes`*, leaving the resolver untouched. Rejected: it puts
  Jira field-shape knowledge in a second place and re-derives metadata the resolver already joined.

---

## R3 — The encoding table, and the guard that keeps it safe

**Decision**: keyed on `schema_type` exactly as discovery recorded it.

| `schema_type` | Sent as |
| --- | --- |
| `option` | `{"value": v}` |
| `priority`, `resolution`, `version`, `component`, `group` | `{"name": v}` |
| anything else — `string`, `number`, `date`, `datetime`, `user`, `any`, empty, unknown | `v`, unchanged |

**Guard**: the rules apply only when the recorded value is a **string**. A number, a boolean, `null`,
an array, or an object passes through untouched. This is what makes the expert escape hatch of
User Story 1 scenario 6 true, and it is what stops a double-wrap if the same value is ever resolved
twice.

**Rationale**: `option` is what Jira's `createmeta` reports for a single-select; the named-entity group
is the set of `schema.type` values whose REST representation accepts `{"name": …}`. Every other
single-value shape takes the scalar.

**`option2` was in this table and was removed.** It is not a Jira `schema.type`: it appears nowhere in
the shipped ports or fixtures, and no FR names it — FR-002 says "a select list", singular. It was very
likely a slip for the cascading select, whose real type is `option-with-child`. That one is *also*
excluded, and for a stronger reason: it accepts `{"value": parent, "child": {"value": child}}`, two
values rather than one, so it is no more expressible as a single recorded scalar than the `array`
shapes `_disc_defaultable_fields` (`discovery.sh:209`) already marks non-defaultable. Confirm the exact
type string against a real `createmeta` during the T049 dogfood — that run is the only place this
project can measure Jira's own vocabulary rather than assume it.

**`user` was in this table and was removed.** Jira Cloud v3 accepts a user field only as
`{"accountId": …}` — an opaque identifier, not a display name. The value would have to come from the
committable `.specify/jira/config.yml`, and Principle IV forbids an accountId in any tracked file,
test fixtures included. Encoding a recorded *name* as `{"accountId": …}` would buy nothing either:
Jira refuses it exactly as it refuses today's bare string. Resolving a name to an account needs a
Jira lookup that this feature's Out of Scope section rules out, so `user` falls through unchanged and
FR-004 states the exclusion as a requirement rather than leaving it to the fall-through by accident.

The fall-through is deliberate and is what makes FR-005 and FR-007 the same rule:
a type the table does not name behaves exactly as it does today, so an unforeseen `schema_type` is no
worse off than before this feature and the existing rejection diagnostic still explains any refusal.

Array-shaped types never reach the table: `_disc_defaultable_fields` (`discovery.sh:203`) already marks
`array` and `issuelink` non-defaultable with a readable reason, so no default can be recorded for them.

**Alternatives considered**:

- *Resolve the recorded option to its internal option id and send `{"id": …}`*. Rejected: it needs an
  extra Jira read per field per run and buys nothing — Jira accepts the option by value. Recorded in
  the spec's Out of Scope.
- *Send `{"value": v}` and retry with `{"name": v}` on rejection*. Rejected: a retry loop against a
  destination that has already refused a write is exactly what Principle III forbids, and the spec puts
  it Out of Scope.

---

## R4 — How the confirmed-creation count is obtained

**Decision**: `apply_writes_with_recognition` prints one canonical JSON outcome on **stdout** naming
the tickets Jira confirmed; `reconcile` captures it and derives `counts.created` from it. Empty output
is read as zero created.

**Rationale**: "confirmed" is knowable only where the create response is read, and that is inside the
apply function — it already parses `.key` out of every POST response (`plan_apply.sh:631` for the
parent, `:674` for each story) in order to stamp the identity marker. Publishing what it already knows
costs one accumulator and one emission.

Stdout is free: the function is silent on it today. The rejection reporter writes to stderr
(`plan_apply.sh:498`), `identity_write` redirects its request to `/dev/null` (`identity.sh:102`),
`marker_splice_write_file` is redirected at every call, and each `jira_request` writes to a temp file.
Its one call site (`reconcile.sh:891`) does not capture stdout today, so capturing it changes nothing
for anyone else.

**Emission points**: three — after the parent's rejection return, after a story's rejection return, and
at the normal end. The two privacy-guard returns at the top are deliberately left alone: they happen
before any write, so zero is the right answer, and the caller's empty-means-zero rule covers them
without touching the two existing tests in `tests/bash/sink/test_privacy_block.bats` that assert on
that path.

**Alternatives considered**:

- *Count the planned creations that now carry a bound marker, by re-reading the spec file after apply.*
  Genuinely tempting: it needs no signature change, and the reconcile command already re-reads the spec
  file after apply for the re-routed and parent-recreated notes (`reconcile.sh:906`, `:921`). Rejected
  because it answers a different question. A ticket Jira created whose key-recording write then failed
  would be counted as *not created* while it exists in Jira — the exact class of lie this user story
  exists to remove, inverted. The spec's assumption defines a creation as confirmed when Jira accepts
  the call, and only the response can say that.
- *Return the count as the exit status.* Rejected: the exit status is the fail-closed contract.
- *Write the outcome to a path passed as a parameter.* Rejected: a temp-file protocol where stdout is
  already free and already the convention for every other JSON-producing function in the sink.

---

## R5 — Where the configuration-time allowed-value check lands

**Decision**: extend `_config_field_default_report` (`config.sh:329`) — the function that already walks
the **merged** map — with one new blocking classification, `outside_allowed`, reusing the problem kind,
the candidate list, and the rendered message that already exist for the flag path.

**Rationale**: the check is not new. `_config_field_default_answer_problems` (`config.sh:253`) already
refuses a value outside `allowed_values` — but only for a value arriving on a `--field-default` flag
this run (`config.sh:278`). A value already sitting in `config.yml`, whether hand-written or valid when
recorded and since removed from the list in Jira, is never checked. The gap is the whole of User
Story 4, and closing it means running the existing rule over the other input rather than writing a
second rule. The message at `config.sh:455` (`… must be one of: …`) is reused verbatim, so an operator
cannot tell — and should not have to — whether the refusal came from a flag or from the file.

**Scoping rules**, all three load-bearing:

1. Only entries whose type name **and** label resolve are checked. An unresolvable entry is already
   classified `orphaned` and must stay non-blocking (FR-008 from feature 011) — funnelling the recorded
   map through `_config_field_default_answer_problems` wholesale would turn every orphan into a
   refusal, a regression.
2. Only where `allowed_values` is non-empty. An absent list is not an empty one (US4 scenario 2), and
   the existing flag-path condition already spells this exact test.
3. Degraded mode is covered for free: with no Jira read there is no `defaultable_fields`, so no entry
   resolves, so rule 1 excludes everything (US4 scenario 3).

Checking the merged map rather than the recorded one means a `--field-default` answer is examined twice.
That is harmless — the answer path refuses and returns before the report runs, so by the time the report
sees it, it is known valid.

---

## R6 — Portability constraints this change must respect

**Decision**: no new portability surface is created; the existing rules are simply obeyed.

- Every jq invocation in the Bash port keeps going through `lib/output.sh` / `json_canonical`, never a
  bare `jq` on multi-line output (`docs/10-windows-portability.md`).
- No glob pattern anywhere in this change contains `$'\r\n'` — none contains a line ending at all.
- The PowerShell twins build their maps with `[ordered]@{}` and serialise through
  `ConvertTo-JiraJsonValue`, exactly as `Get-JiraPlanResolveFieldDefault` does today, so key order and
  byte shape match the Bash port's `json_canonical`.
- The one shape worth watching on Windows: `field_defaults_encoded` nests one level deeper than
  `field_defaults` (a map of maps of *objects* rather than of scalars). Canonical serialisation already
  handles arbitrary nesting — the binding's `defaultable_fields` is deeper still — so no new hazard,
  but the conformance scenarios of R7 are what prove it rather than this paragraph.

No Windows-only behaviour is being fixed here, so the probe workflow is not on the critical path; the
ordinary three-OS matrix is the gate.

---

## R7 — Test strategy

**Decision**: failing-first at three levels, in this order.

1. **The regression test FR-017 names**, written first and red against today's code: one issue type
   carrying a select-list default and a free-text default, asserting the exact payload
   `jira_create_fields_base` produces. Bash: `tests/bash/sink/test_plan_apply_defaults.bats` and
   `tests/bash/sink/test_ticket.bats`. PowerShell: `PlanApply.Defaults.Tests.ps1`, `Ticket.Tests.ps1`.
2. **Unit coverage per rule**: one case per row of R3's table plus the non-string guard, plus the
   two-map invariant of R2 (the recorded map is unchanged by the encoding). Counting: new cases in
   `tests/bash/commands/test_reconcile_field_defaults.bats` and its Pester twin for the confirmed-count
   rule. Config: new cases in `test_config_field_defaults.bats` / `Config.FieldDefaults.Tests.ps1`.
3. **Conformance scenarios** — byte equivalence is the only proof that FR-016 holds. Three new
   scenarios alongside the existing `us1-field-defaults-*` / `us2-field-defaults-*` family:
   an option-typed default that creates successfully, a refused creation whose summary reports zero
   created, and a recorded value outside its allowed values refused by the ceremony.

Every test observes only state it created (Principle XIII's isolation rule): the mock's port and the
scenario's temp tree come from the harness, and no test scans for a process or file by name pattern.

**Alternatives considered**: proving the encoding through the live integration suite alone. Rejected —
it does not run on a pull request, and a defect this cheap to reproduce with a mock does not need real
credentials to stay fixed.

---

## R8 — The stale comment that authorised the defect

**Decision**: correct the block comment on `_disc_defaultable_fields` (`discovery.sh:200-202`) and its
PowerShell twin as part of this change.

**Rationale**: it currently reads *"the bridge sends exactly what was recorded, and a shape Jira itself
then rejects is FR-019's concern, not discovery's."* That sentence is the design decision this feature
reverses, and it sits directly above the line that captures `schema_type`. Leaving it in place would
leave the next reader with a comment asserting the opposite of the code — Principle XVI, and a comment
that explains a *why* which is no longer true is worse than none. No behaviour changes with it.

---

## Open questions

None. No `NEEDS CLARIFICATION` marker was raised in the spec and none was created here.

## Discovered during research, outside the spec as written

`_reconcile_field_default_notes` renders both a provenance line and a `--field-default` promotion
command containing the resolved value (`reconcile.sh:210-212`). The spec's FR-009 names only the
confirmation question, but SC-004 ("no operator-facing surface displays a machine shape") covers this
site, and the promotion command is arguably the more serious of the two because it is written to be
executed. R2's two-map design satisfies both without a spec amendment; had the design been the report's
de-encapsulate-at-display, an amendment to FR-009 would have been required.
