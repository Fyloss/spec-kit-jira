# Contract: Hook declaration in `extension.yml`

**Consumer**: `specify extension add` (specify_cli ≥ 0.13.0, verified against 0.13.4)
**Producer**: this repository's `extension.yml`
**Requirements**: FR-001, FR-002, FR-003, FR-004, FR-009, FR-011, FR-021

## Placement

`hooks:` is a **top-level key**, a sibling of `provides:`. A `hooks:` block
nested under `provides:` validates but is silently ignored, and the install
registers nothing — see [research.md](../research.md) R1.

## Declaration

```yaml
provides:
  commands:
    - name: speckit.jira.config
      file: commands/speckit.jira.config.md
      description: ...
    - name: speckit.jira.feature
      file: commands/speckit.jira.feature.md
      description: ...
    - name: speckit.jira.reconcile          # NEW — FR-010, FR-011
      file: commands/speckit.jira.reconcile.md
      description: ...

hooks:
  before_specify:
    command: speckit.jira.feature
    optional: false
    description: "Resolve the Jira ticket and name the feature before creation."
  after_specify:
    command: speckit.jira.reconcile
    optional: false
    description: "Mirror the updated spec-kit artifacts into Jira Cloud."
  after_clarify:    { command: speckit.jira.reconcile, optional: false, description: ... }
  after_plan:       { command: speckit.jira.reconcile, optional: false, description: ... }
  after_tasks:      { command: speckit.jira.reconcile, optional: false, description: ... }
  after_implement:  { command: speckit.jira.reconcile, optional: false, description: ... }
  after_analyze:    { command: speckit.jira.reconcile, optional: false, description: ... }
```

(The inline-mapping form above is shorthand for this document; the manifest
uses block style throughout, consistent with the rest of the file.)

## Field rules

| Field | Rule |
| --- | --- |
| `command` | Required. Must be the canonical `speckit.<ext>.<name>` form and must match a `provides.commands[].name`. A short `jira.reconcile` form is auto-lifted by the host **with a warning** — avoid it. |
| `optional` | `false` on every entry. This makes the agent perform the hook rather than offer it (FR-004). It does **not** allow a failure to fail the host command. |
| `description` | Required by this contract though optional to the host: it is what a human reads in the registry (Principle XVI). |
| `priority` | Omitted. The host default of `10` is written, and no ordering requirement exists. |
| `prompt` | Omitted. The host writes its default; it is unused while `optional: false`. |
| `condition` | **Must not be set.** A non-empty condition makes agent-driven dispatch skip the hook entirely (research.md R8). |

## Guarantees this buys

- **Registration without ceremony** (FR-001, SC-001): the install writes one
  entry per declared event into `.specify/extensions.yml`.
- **Idempotence** (FR-005, SC-004): the install purges this extension's entries
  by `extension: jira` and re-adds them, so repeated installs cannot duplicate.
- **Other extensions preserved** (FR-006): the purge matches on the ownership
  field, so entries from other extensions are never touched.
- **Self-cleaning** (R9): an event removed from this block is purged from the
  registry on the next install, leaving no orphan.

## What this contract does **not** buy

The install writes `enabled: true` unconditionally, so an operator's
`enabled: false` does **not** survive a reinstall. FR-007 is met by the disable
record described in [data-model.md](../data-model.md), not by this contract.

## Verification

- A CI check parses `extension.yml` and asserts: the seven events are declared
  at the root; every `command` matches a declared command name; every entry has
  `optional: false`; no entry declares `condition`.
- A conformance scenario performs the install into a scratch repository and
  asserts the resulting `.specify/extensions.yml` contains exactly one entry
  per event, each owned by `jira` and enabled.
