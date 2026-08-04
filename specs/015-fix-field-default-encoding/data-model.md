# Data Model — A Recorded Field Default Is Sent in the Shape Its Field Accepts

**Feature**: 015 | **Date**: 2026-08-04 | **Phase**: 1

Nothing here is persisted. Every shape below lives in memory for the duration of one run, except where
a section says otherwise — and the two sections that name a file both say **unchanged**.

---

## §1 — Persisted shapes: both unchanged

### §1.1 `.specify/jira/config.yml` — the committable team layer

```yaml
"field_defaults":
  "<PROJECT>":
    "<Type>":
      "<Field label>": "<value the operator typed>"
    "ask": true
```

**Unchanged by this feature.** The operator keeps recording a plain business value; the wire shape is
derived at run time and never written back. This is what keeps the promotion command of §4.3 correct
and what makes an unchanged ceremony re-run byte-identical (Principle II).

### §1.2 `.specify/jira/config.local.yml` — the machine-owned binding

```yaml
resolved_ids:
  <PROJECT>:
    defaultable_fields:
      "<type_id>":
        - logical_name: "<Field label>"
          field_id: "<field id>"
          schema_type: "<declared type>"
          required: true|false
          defaultable: true|false
          allowed_values: ["…"]
```

**Unchanged by this feature.** `schema_type` and `allowed_values` are already written here by
`_disc_defaultable_fields`. This feature is the first consumer of `schema_type`, and the second of
`allowed_values`. No key is added, renamed, or removed.

---

## §2 — `plan_resolve_field_defaults` output — one new sibling map

**Today**:

```json
{ "field_defaults":        { "<type_id>": { "<field_id>": <recorded value> } },
  "field_default_sources": { "<type_id>": { "<field_id>": "team-config"|"operator-answer" } },
  "unresolved":            [ { "type": "…", "label": "…", "reason": "…" } ] }
```

**After**:

```json
{ "field_defaults":         { "<type_id>": { "<field_id>": <recorded value> } },
  "field_defaults_encoded": { "<type_id>": { "<field_id>": <value shaped for the wire> } },
  "field_default_sources":  { "<type_id>": { "<field_id>": "team-config"|"operator-answer" } },
  "unresolved":             [ { "type": "…", "label": "…", "reason": "…" } ] }
```

**Invariants** — each is a test:

| # | Invariant |
| --- | --- |
| I1 | `field_defaults` is byte-identical to what today's code produces for the same inputs. The encoding adds a map; it never mutates the existing one. |
| I2 | `field_defaults` and `field_defaults_encoded` have identical key sets at both levels. |
| I3 | For a field whose declared type has no rule, or whose recorded value is not a string, the two maps hold the same value. |
| I4 | With nothing recorded and no answer, both maps are `{}` and the whole output is byte-identical to today's — absence stays the off switch (011 FR-028). |
| I5 | Key order is canonical on both ports, so the two serialisations match byte for byte. |

### §2.1 The encoding function

Pure, total, and defined on `(schema_type, value)`:

```text
encode(meta, v) =
  v                       if v is not a string
  {value: v}              if meta.schema_type = option
  {name: v}               if meta.schema_type ∈ {priority, resolution, version, component, group}
  v                       otherwise  (string, number, date, datetime, user, any, empty, unknown, absent meta)
```

The non-string branch is first and is the guard: it makes `encode(meta, encode(meta, v)) = encode(meta, v)`
for every input, so the function is idempotent and a value can never be wrapped twice.

---

## §3 — Plan context — one key changes its source, not its name

```text
plan_context.field_defaults  ←  resolver output .field_defaults_encoded
```

`plan_writes` and `jira_create_fields_base` read `plan_context.field_defaults` exactly as they do today
and are not modified. The key keeps its name because the plan context is the *sending* side: from
`plan_writes`' point of view a field default has always meant "the thing to put in the payload", and
that meaning is unchanged.

---

## §4 — Read-only consumers of the resolver output

All four keep reading `field_defaults` — the recorded values — and none is modified.

| § | Consumer | Uses | Effect of this feature |
| --- | --- | --- | --- |
| 4.1 | `hierarchy_mandatory_gate`, from `reconcile.sh` and `config.sh` | key presence only | none |
| 4.2 | `plan_confirmation_fields` → `recorded_value` | the value, displayed | none — FR-009 holds by construction |
| 4.3 | `_reconcile_field_default_notes` → provenance line and `--field-default` promotion command | the value, displayed and embedded in a runnable command | none — FR-018 and SC-004 hold by construction |

§4.3 is why §2 adds a map instead of transforming one: the promotion command is written to be executed,
and executing it writes its argument back into §1.1.

---

## §5 — `apply_writes_with_recognition` outcome — new output, no new parameter

Printed on stdout, canonical, once per invocation:

```json
{ "created": [ { "key": "<issue key>", "role": "parent"|"story", "local_id": "<marker id>" } ] }
```

**Rules**:

| # | Rule |
| --- | --- |
| O1 | An entry appears only after Jira returned a key for that creation. A planned creation never attempted, or attempted and refused, has no entry. |
| O2 | The parent, when created, is the first entry — the write order is the report order. |
| O3 | Emitted on all three post-write exit paths: normal completion, parent rejection, story rejection. |
| O4 | Not emitted on the two pre-write privacy-guard returns. The caller reads empty output as `{"created": []}`, so zero is still reported and the existing privacy tests are untouched. |
| O5 | An update (`PUT`) and a transition never produce an entry — this is the created tally, and a transition is a POST that is not a creation. |

---

## §6 — Run summary

```text
counts.created  =  length of §5's created array        (real run)
counts.created  =  count of planned creations          (--dry-run, unchanged)
```

`counts.updated`, `counts.skipped`, `counts.recognised`, `counts.assigned`, `counts.warnings`, and
`counts.errors` are untouched, as are `actions`, `warnings`, `notes`, `hook_health`, and `exit_code`.
A fully successful run's summary is therefore byte-identical to today's (FR-013): every planned
creation is confirmed, so the two definitions of the count coincide.

Under `--dry-run` nothing is applied, so there is no outcome to read and the planned count stands —
which is what keeps the dry-run report a prediction of the *action set* (FR-012, Principle XI).

---

## §7 — Configuration-time refusal — one new problem, no new vocabulary

`_config_field_default_report` gains a fifth member alongside `orphaned`, `not_yet_consumed`,
`undefaultable_required`, and `pending`:

```json
"outside_allowed": [ { "type": "<Type>", "label": "<Field label>", "candidates": ["…"] } ]
```

The member reuses the `outside_allowed` problem kind, the `candidates` key, and the rendered message
that the `--field-default` flag path already produces, so the two inputs are indistinguishable to the
operator. It is a **refusal trigger**, like `pending`.

**Admission rules** (all four must hold for an entry to be examined):

| # | Rule | Why |
| --- | --- | --- |
| A1 | The recorded type name resolves to a discovered issue type. | An unresolvable type is `orphaned` and stays non-blocking (011 FR-008). |
| A2 | The recorded label resolves to a defaultable field of that type. | Same. |
| A3 | That field's `allowed_values` is non-empty. | An absent list is not an empty one (FR-015). |
| A4 | The recorded value is a string. | `allowed_values` enumerates option *labels*, so a hand-written object or array can never be a member of it; checking it would refuse the very value FR-006 passes through untouched. A recorded number, boolean, or null is exempt for the same reason — the encoding rules apply to recorded text only. |

A3 also makes degraded mode a no-op without a special case: with no Jira read there is no
`defaultable_fields`, A1/A2 exclude every entry, and nothing is checked.

A4 is what keeps the check from closing FR-006's expert escape hatch. The refusal exists to catch a
*typo* in a recorded label-shaped value; an operator who wrote a structure did so deliberately, to reach
a field shape the bridge does not derive, and the config ceremony has no business second-guessing it.

**Never a refusal**: the value itself is not echoed into any structured output beyond the label and the
candidate list — the credential-shaped refusal already in place suppresses values on purpose
(Principle IV), and this member follows it.

---

## §8 — Requirement traceability

| FR | Where it lives | Proven by |
| --- | --- | --- |
| FR-001 | §2.1 `encode`, called from the resolver | I1–I5 |
| FR-002 | §2.1 row `option` | US1 scenario 1 |
| FR-003 | §2.1 row `priority`/`resolution`/`version`/`component`/`group` | US1 scenario 4 |
| FR-004 | §2.1 fall-through — `user` has no row, by exclusion | US1 scenario 5 |
| FR-005 | §2.1 fall-through | US1 scenario 2 |
| FR-006 | §2.1 non-string guard | US1 scenario 6 |
| FR-007 | §2.1 fall-through on absent meta; `unresolved` unchanged | US1 scenario 7 |
| FR-008 | §3 — one plan-context key, both creation paths downstream of it | US1 scenario 3 |
| FR-009 | §4.2 — consumer unchanged | US2 scenarios 1–2 |
| FR-010 | §4.2 — inclusion logic untouched | US2 scenario 3 |
| FR-011 | §5, §6 | US3 scenarios 1–2 |
| FR-012 | §6 dry-run row | US3 scenario 4 |
| FR-013 | §6 | US3 scenario 3 |
| FR-014 | §7 | US4 scenario 1 |
| FR-015 | §7 rule A3 and rules A1/A2 | US4 scenarios 2–3 |
| FR-016 | §2 I5, §5, §6, §7 on both ports | conformance scenarios |
| FR-017 | §2, §3 end to end | the failing-first regression test |
| FR-018 | §4.2, §4.3, §7 — every message keyed on `logical_name` | US2 scenario 1, US4 scenario 1 |

Nothing in this document exists without an FR in that table (Principle XV).
