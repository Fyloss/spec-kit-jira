# Contract: the run summaries after the hook report is retired

**Feature**: `034-retire-hook-report` | **Status**: normative

This contract amends `specs/001-jira-reconcile-engine/contracts/run-summary.schema.json`.
That file is the schema of record and is edited in place by this feature; the
sections below state what changes and why, so a reviewer can check the diff
against an intent rather than against nothing.

Removing a field from a published contract is **breaking**. It is released as such
(research R8), not softened by emitting an empty object.

---

## §1 — `effects.hooks` is removed

**Before**

```json
"effects": {
  "additionalProperties": false,
  "properties": {
    "discovery": { "$ref": "#/$defs/effect" },
    "hooks":     { "$ref": "#/$defs/effect" },
    "readme":    { "$ref": "#/$defs/effect" },
    "gitignore":      { "$ref": "#/$defs/effect" },
    "personal":       { "$ref": "#/$defs/effect" },
    "field_defaults": { "$ref": "#/$defs/effect" },
    "task_mirror":    { "$ref": "#/$defs/effect" }
  }
}
```

**After** — six properties; `discovery`, `readme`, `gitignore`, `personal`,
`field_defaults`, `task_mirror`.

> **Note on the four non-`hooks` properties.** `personal` (030),
> `field_defaults` and `task_mirror` (011) have been emitted by both ports for
> several features, and the schema declared none of them — with
> `additionalProperties: false`, that made **every** ceremony summary invalid
> against its own published contract for that whole period. The drift was not
> introduced by this feature; it was found while planning it and repaired in the
> same commit as this contract, because 034 edits this exact object and leaving
> known-false neighbours in place while carefully removing a sibling would be
> indefensible. All four are therefore present in both the before and after
> states above, and none is removed by this feature.
>
> The gap survived because nothing checked it: the schema was named in four
> comments and zero assertions. It is now guarded for both commands —
> `test_run_summary_schema.bats` (config: main, dry-run, degraded) and
> `test_reconcile_summary_schema.bats` (reconcile: planning, confirmed,
> fail-closed), sharing one reading of the contract through
> `tests/bash/helpers/summary_schema.bash`. Each was proven red before acceptance.

`additionalProperties: false` is already set, so a summary still emitting
`effects.hooks` is **invalid**, not merely unexpected. No consumer needs to
tolerate an optional field, because there is no optional field.

---

## §2 — `hook_health` is removed

The top-level `hook_health` object and all seven of its properties — `present`,
`missing`, `disabled`, `held_disabled`, `duplicated`, `unreadable`, `repair_hint` —
are deleted from the schema.

Reconcile's hard-coded fallback

```bash
[[ -z "${hooks_health}" ]] && hooks_health='{"disabled":[],…,"unreadable":false}'
```

is deleted with it. Emitting an empty object would satisfy a schema while
asserting nothing about a fact the extension cannot establish — the same defect in
a quieter form.

---

## §3 — `$defs/effect.status` loses five values

**Before** — thirteen values, described as eight write outcomes plus "the READ-ONLY
verification vocabulary of the hooks effect".

**After** — eight values:

```json
"enum": ["written", "unchanged", "created", "would_create",
         "repaired", "refused", "skipped", "inert"]
```

`healthy`, `incomplete`, `held_disabled`, `duplicated` and `unreadable` are removed.
Each had exactly one producer and it was the hooks effect (research R2). The
description's partition sentence is rewritten: every remaining value is a write
outcome, because every remaining effect writes a file this extension owns.

> **Note on `would_create` and `inert`.** `would_create` is the dry-run twin of
> `created`, emitted by the `personal` effect (`config.sh:877`, `Config.psm1:992`)
> when `--dry-run` predicts a file it does not write. `inert` means the managed
> region exists but the run had nothing to put in it (`config.sh:646`, `:724`).
> Both were undeclared and both were added in the same repair. **Do not remove
> either** when applying the deletion above: each has live producers in both
> ports, and both are write outcomes rather than part of the hooks vocabulary.

---

## §4 — What does not change

| Field | Status |
| --- | --- |
| `effects.discovery`, `effects.readme`, `effects.gitignore` | unchanged, including their reported shape (US1 AC4) |
| `warnings`, `notes`, `drift`, `flags`, `blockers`, `mutations`, `exit_code` | unchanged |
| every counter and action list | unchanged |

**Reconcile in hook context** keeps emitting exactly one actionable warning on
bridge failure and keeps returning 0 to the host command (FR-007). Nothing in this
contract touches that path.

---

## §5 — Conformance obligation

Both ports MUST produce byte-identical summaries for every scenario this feature
defines (FR-012). The three registry states of SC-001 — correct, absent, malformed
— MUST produce ceremony summaries that are identical in hook-related content, which
after this feature means: containing none.
