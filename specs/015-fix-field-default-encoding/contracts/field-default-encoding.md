# Contract — Field-Default Encoding, Confirmed Counts, and the Recorded-Value Check

**Feature**: 015 | **Date**: 2026-08-04 | **Phase**: 1

This contract binds the two ports. Where it says MUST, a divergence between
`scripts/bash/**` and `scripts/powershell/**` is a conformance failure, not a
preference.

---

## §1 — `plan_resolve_field_defaults` / `Get-JiraPlanResolveFieldDefault`

### §1.1 Signature

Unchanged. Four inputs, in this order: issue types, defaultable fields by type,
the project's recorded `field_defaults` entry, this run's answers.

### §1.2 Output

```json
{ "field_defaults":         { "<type_id>": { "<field_id>": <recorded> } },
  "field_defaults_encoded": { "<type_id>": { "<field_id>": <encoded> } },
  "field_default_sources":  { "<type_id>": { "<field_id>": "team-config"|"operator-answer" } },
  "unresolved":             [ { "type": …, "label": …, "reason": … } ] }
```

- `field_defaults` MUST be byte-identical to the map today's code produces for
  the same inputs.
- `field_defaults_encoded` MUST have the same key set as `field_defaults` at both
  levels.
- Both maps MUST be canonically ordered and MUST serialise identically on both
  ports.
- With no recorded default and no answer, both maps MUST be `{}` and the whole
  object MUST be byte-identical to today's output.

### §1.3 The encoding rule

Given the field's metadata `m` (the `defaultable_fields` entry the label resolved
through) and the recorded value `v`:

| Condition, evaluated in this order | Result |
| --- | --- |
| `v` is not a string | `v` |
| `m.schema_type` = `option` | `{"value": v}` |
| `m.schema_type` ∈ {`priority`, `resolution`, `version`, `component`, `group`} | `{"name": v}` |
| otherwise, including `user`, absent `m`, and empty `schema_type` | `v` |

The cascading select (`option-with-child`) is deliberately absent and MUST fall
through unchanged. It accepts `{"value": parent, "child": {"value": child}}`, which
is two values, not one — it is not expressible as a single recorded scalar, exactly
like the `array` shapes `discovery.sh` already marks non-defaultable. Supporting it
is a new capability needing its own requirement, not a row here.

`user` is deliberately absent from the table and MUST fall through unchanged. Jira
accepts a user field only as `{"accountId": …}`, and an accountId is not something
an operator may record: `.specify/jira/config.yml` is committable, and Principle IV
forbids an accountId in any tracked file, fixtures included. Deriving the shape
without the identifier would send a display name under an `accountId` key, which
Jira refuses exactly as it refuses the bare string today. See spec.md FR-004.

The order is normative: the non-string guard MUST be evaluated first, so the rule
is idempotent and no value is ever wrapped twice.

Precedence between a recorded default and a this-run answer is unchanged — the
answer wins — and the winning value is the one that is encoded. An answer and a
recorded value of the same text MUST produce the same encoded value.

---

## §2 — Plan context

```text
plan_context.field_defaults  MUST be set from  .field_defaults_encoded
```

`plan_writes` / `Get-JiraPlanWriteSet` and `jira_create_fields_base` /
`Get-JiraCreateFieldsBase` MUST NOT change. The payload they produce for a type
with no recorded default MUST be byte-identical to today's.

---

## §3 — Consumers that MUST keep reading the recorded map

| Consumer | Reads |
| --- | --- |
| `hierarchy_mandatory_gate` (both call sites, both ports) | `.field_defaults` |
| `plan_confirmation_fields` / `Get-JiraPlanConfirmationField` | `.field_defaults` |
| `_reconcile_field_default_notes` / its PowerShell twin | `.field_defaults` |

No operator-facing string may contain a value produced by §1.3. In particular the
`--field-default` promotion command MUST embed the value exactly as it appears in
`config.yml`, so that running the command as printed re-records the same value.

---

## §4 — `apply_writes_with_recognition` / `Invoke-JiraApplyWriteSetWithRecognition`

### §4.1 Signature

Unchanged. Six parameters, same order, same defaults.

### §4.2 Outcome on stdout

```json
{ "created": [ { "key": "…", "role": "parent"|"story", "local_id": "…" } ] }
```

- An entry MUST appear only after the destination returned a key for that
  creation.
- The parent's entry, when present, MUST be first.
- The outcome MUST be printed before returning on each of: normal completion,
  parent rejection, story rejection.
- The outcome MUST NOT be printed on the pre-write privacy-guard returns.
- Nothing else may be written to stdout by this function. The rejection message
  stays on stderr.
- The exit status is unchanged: the worst transport code, `9` on a privacy block.

### §4.3 Caller obligation

The caller MUST capture stdout, MUST leave stderr flowing, and MUST treat empty
output as `{"created": []}`.

---

## §5 — Run summary

- `counts.created` on a real run MUST equal the length of §4.2's `created` array.
- `counts.created` under `--dry-run` MUST remain the count of planned creations.
- Every other member of `counts`, and every other key of the summary, MUST be
  unchanged.
- A run in which every planned creation is confirmed MUST produce a summary
  byte-identical to today's.

---

## §6 — Configuration-time recorded-value check

### §6.1 New member

`_config_field_default_report` / its PowerShell twin MUST return a fifth member:

```json
"outside_allowed": [ { "type": "<Type>", "label": "<Field label>", "candidates": ["…"] } ]
```

### §6.2 Admission

An entry of the merged map is examined only when all four hold:

1. its type name resolves to a discovered issue type;
2. its label resolves to a defaultable field of that type;
3. that field's `allowed_values` is non-empty;
4. its recorded value is a string.

An entry failing 1 or 2 MUST remain classified `orphaned` and MUST NOT block.

Condition 4 is FR-006's escape hatch, enforced here rather than only on the wire:
`allowed_values` enumerates option *labels*, so a value an operator wrote as an
object or an array — the shape the bridge does not derive, obeyed literally — can
never be a member of it, and checking one against the other would refuse exactly
the value FR-006 promises to pass through untouched. The same exemption covers a
recorded number, boolean, or null, per the edge case that the encoding rules apply
to recorded text only.

### §6.3 Refusal

A non-empty `outside_allowed` MUST refuse the ceremony with the exit code the
existing `--field-default` refusal uses, MUST write nothing, and MUST render the
message the flag path already renders:

```text
config: project <PROJECT>: <Field label> (<Type>) must be one of: <candidates>
```

The recorded value MUST NOT appear in the message or in any structured output —
only the label, the type, and the candidates.

Refusals MUST be batched: every offending entry is reported in one pass, never one
refusal per entry.

---

## §7 — Discovery

No behaviour change. The block comment on `_disc_defaultable_fields` and its
PowerShell twin MUST be corrected: the bridge no longer "sends exactly what was
recorded", and `schema_type` is no longer captured for a future reader but
consumed by §1.3.

---

## §8 — Conformance scenarios

Three scenarios MUST be added and MUST produce byte-identical output on all three
operating systems:

| Scenario | Proves |
| --- | --- |
| an option-typed default and a string-typed default on one type, creation succeeds | §1.3, §2, and that the string field is untouched |
| every planned creation refused | §4.2, §5 — `counts.created` is `0` |
| a recorded value outside its field's allowed values | §6 |
