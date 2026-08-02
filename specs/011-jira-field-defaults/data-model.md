# Phase 1 — Data Model

Four entities, three of which are new shapes inside files that already exist. Nothing here introduces
a store, a schema file, or a persistence mechanism that is not already in the tree.

---

## 1. Field default — the team's recorded answer

**Lives in**: `.specify/jira/config.yml`, top level, inside the managed region (research R1).
**Written by**: the configuration ceremony. **Read by**: the ceremony's gate and the reconcile's plan
context. **Never written by**: a hook (FR-021).

```yaml
# >>> spec-kit-jira: field defaults (managed) >>>
# Values this bridge sends when it CREATES a ticket of the named type. Recorded
# by /speckit.jira.config; edit through that command so the block stays canonical.
# Removing an entry stops the bridge sending that field (FR-029).
field_defaults:
  CONSUMER:
    ask: true                       # confirm at creation time? (FR-014)
    Epic:
      Business Owner: "Platform Team"
      Program Increment: "PI-2026-Q3"
    Story:
      Team: "Payments"
# <<< spec-kit-jira: field defaults (managed) <<<
```

| Field | Type | Rules |
| --- | --- | --- |
| project key | map key | Must be a declared `projects[].key`. Same `^[A-Z][A-Z0-9_]+$` shape the schema already enforces. |
| `ask` | boolean | Optional, default `true`. The per-project question switch (FR-014). |
| issue-type name | map key | Must match a discovered issue type by exact name (FR-026). Never a role name — defaults are recorded against the type (spec Assumptions). |
| field label | map key | The Jira `name` a human sees. Never a `customfield_NNNNN` id (Principle XVI). |
| value | scalar | Non-empty (FR-008). Must be one of `allowed_values` when the field enumerates them (FR-003). Credential- and identity-shaped values are refused by the existing `_cfg_credential_errors` scan (research R7). |

**Validation** (added to `_cfg_schema_errors`): unknown top-level key check gains `field_defaults`;
each project key must be declared; each value must be a non-empty scalar. Issue-type and field-label
existence are *not* schema checks — they require the discovered binding and are validated by the
ceremony, which reports an entry naming something the project no longer offers (FR-008) and an entry
for a type the bridge does not write (FR-027).

---

## 2. Defaultable field — what discovery learned about one field of one type

**Lives in**: `.specify/jira/config.local.yml`, under `resolved_ids.<KEY>.defaultable_fields`,
gitignored and machine-owned. **Written by**: the ceremony, from the `createmeta` read it already
performs. **Read by**: the ceremony (to ask), the gate (to judge satisfiability), the plan context (to
resolve a label to an id).

```yaml
defaultable_fields:
  "10101":                                   # issue-type id
    - logical_name: "Business Owner"
      field_id: "customfield_40011"
      schema_type: "string"
      required: true
      defaultable: true
      allowed_values: []
    - logical_name: "Program Increment"
      field_id: "customfield_40012"
      schema_type: "option"
      required: true
      defaultable: true
      allowed_values: ["PI-2026-Q2", "PI-2026-Q3"]
    - logical_name: "Attachment"
      field_id: "attachment"
      schema_type: "array"
      required: true
      defaultable: false
      undefaultable_reason: "attachments cannot be expressed as a recorded value"
```

| Field | Source | Purpose |
| --- | --- | --- |
| `logical_name` | createmeta `.name` | The key `config.yml` uses and every message prints. |
| `field_id` | createmeta `.fieldId` | What the payload carries. Never printed to a human. |
| `schema_type` | createmeta `.schema.type` | Decides defaultability (FR-010) and how the value is serialised into the payload. |
| `required` | createmeta `.required` | Whether omitting it blocks a creation. |
| `defaultable` | derived | `false` for shapes a one-line config value cannot express. |
| `undefaultable_reason` | derived | The human reason FR-010 requires. Present only when `defaultable` is false. |
| `allowed_values` | createmeta `.allowedValues[].value`/`.name` | The closed question of FR-003 and the rejection explanation of FR-019. Empty array when the field enumerates nothing. |

**Relationship to `required_fields`**: `defaultable_fields` is a superset — it carries the optional
fields too (FR-004) and the extra keys above. `required_fields` stays exactly as it is, because
`hierarchy_mandatory_gate` and the pre-011 bindings both read it; a binding written before this
feature keeps working and simply offers no defaultable-field metadata until the ceremony is re-run.

**Serialisation**: through the existing canonical writer, so an unchanged re-run rewrites the file
byte-for-byte (FR-007).

---

## 3. Resolved defaults — the plan context's view

**Lives in**: memory only, inside the reconcile's plan context, beside `estimation_field_id` and
`priority_ids`. **Built by**: the sink, by joining entity 1 (labels) to entity 2 (ids). **Consumed
by**: `jira_create_fields_base`.

```json
{ "field_defaults": { "10101": { "customfield_40011": "Platform Team" },
                      "10102": { "customfield_40200": "Payments" } },
  "field_default_sources": { "10101": { "customfield_40011": "team-config" } } }
```

Keyed by issue-type id then field id, so the merge is a plain object union at the point the payload is
assembled. `field_default_sources` carries the provenance FR-022 reports — `team-config`,
`operator-answer`, or absent for a field the bridge supplies itself — and never leaves the summary.

**Absence is the off switch**: when no default is recorded the key is absent, the merge is a no-op, and
the payload is byte-identical to today (FR-028, research R6).

---

## 4. Consolidated question — what the planning pass emits when it stops

**Lives in**: the run summary of a planning pass, in memory and on stdout. **Never persisted.**

```json
{ "status": "confirmation-pending",
  "project": "CONSUMER",
  "fields": [
    { "issue_type": "Epic", "label": "Business Owner",
      "recorded_value": "Platform Team", "required": true, "allowed_values": [] },
    { "issue_type": "Epic", "label": "Program Increment",
      "recorded_value": null, "required": true,
      "allowed_values": ["PI-2026-Q2", "PI-2026-Q3"] }
  ],
  "creations_pending": 4,
  "resume_with": "… reconcile spec.md --accept-defaults" }
```

One object per run, never one per creation (FR-011). `recorded_value: null` marks a field with no
default — the case where the answer is required rather than confirmed (US3). `resume_with` is the
copy-pasteable re-invocation, and its sibling for permanent recording is the
`speckit.jira.config --field-default …` line FR-021 requires in the summary.

**State transitions of one run**

```text
planning pass ──no creation pending──────────────────────────────► write nothing, ask nothing (FR-013)
      │
      ├─creations pending, nothing recorded, all required satisfiable─► write (unchanged behaviour)
      │
      ├─creations pending, ask=false or --accept-defaults────────► apply recorded defaults, write (FR-014/FR-015)
      │
      ├─creations pending, ask=true, defaults recorded───────────► emit question, exit 0, ZERO writes
      │                                                             └─agent answers─► writing pass
      │
      └─creations pending, a required field has no default───────► emit question if the operator is reachable
                                                                    else refuse: zero writes, existing exit code,
                                                                    message + remedy command (FR-016)
```

---

## Requirement traceability

Principle XV requires every shipped key and flag to point at the requirement that demands it and the
test that exercises it. The middle column is that pointer; the test column is filled by `tasks.md`.

| Artifact | Demanded by | Entity |
| --- | --- | --- |
| `field_defaults.<KEY>.<Type>.<Label>` in `config.yml` | FR-005, FR-004, FR-018 | 1 |
| `field_defaults.<KEY>.ask` | FR-014 | 1 |
| the managed region markers | FR-007, Principle XVI | 1 |
| `defaultable_fields[typeId][]` in `config.local.yml` | FR-001, FR-002, FR-004 | 2 |
| `.allowed_values` | FR-003, FR-019 | 2 |
| `.defaultable` / `.undefaultable_reason` | FR-010 | 2 |
| `--field-default KEY=Type=Label=Value` | FR-006, FR-026 | 1 |
| `--field-value KEY=Type=Label=Value` | FR-012 | 3 |
| `--accept-defaults` | FR-015 | 4 |
| plan-context `field_defaults` | FR-011, FR-017, FR-023 | 3 |
| plan-context `field_default_sources` | FR-022 | 3 |
| the `confirmation-pending` summary object | FR-011, FR-013, FR-021 | 4 |
| defaults-aware `hierarchy_unsatisfiable_fields` | FR-016, FR-029 | — |

Nothing else is added. In particular there is no per-developer override layer, no wildcard issue type,
no retro-fill flag, and no computed default — each was named out of scope by the spec and none has a
requirement here.
