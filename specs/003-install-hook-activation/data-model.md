# Phase 1 Data Model: Hooks Active From Installation

**Feature**: 003-install-hook-activation | **Date**: 2026-07-28

This feature owns no Jira data. Its entities are the four records that decide
whether, and how, a lifecycle hook fires. Three of them already exist in some
form; the fourth is new and is the deviation justified in the plan.

---

## Lifecycle event

The named point in the spec-kit workflow at which this extension participates.
A closed set of seven — adding to it requires a new spec (Principle XV).

| Event | Command it fires | Purpose |
| --- | --- | --- |
| `before_specify` | `speckit.jira.feature` | Resolve the ticket and name the feature before creation |
| `after_specify` | `speckit.jira.reconcile` | Mirror the new specification |
| `after_clarify` | `speckit.jira.reconcile` | Mirror clarifications |
| `after_plan` | `speckit.jira.reconcile` | Mirror the plan |
| `after_tasks` | `speckit.jira.reconcile` | Mirror the tasks |
| `after_implement` | `speckit.jira.reconcile` | Mirror implementation outcomes |
| `after_analyze` | `speckit.jira.reconcile` | Mirror analysis outcomes |

**Validation**: the set declared in `extension.yml` and the set the health check
covers must be identical. A CI check compares them, so an event added to one
and forgotten in the other fails the build rather than shipping half-wired.

---

## Hook entry

One record in the consuming repository's registry (`.specify/extensions.yml`),
under `hooks.<event>`, binding an event to a command. The registry is shared:
other extensions and the operator write entries beside ours.

| Field | Value for this extension | Notes |
| --- | --- | --- |
| `extension` | `jira` | **Ownership key.** The install matches on it to purge and re-add. An entry without it is orphaned and duplicated on the next install. |
| `command` | `speckit.jira.feature` or `speckit.jira.reconcile` | Must name a command declared in `provides.commands`. |
| `enabled` | `true` at registration | The operator may set `false`; see the disable record below. |
| `optional` | `false` | Dispatch flag: the agent performs the hook instead of offering it. Not a blocking flag. |
| `priority` | `10` | The host default. No ordering requirement exists between this extension and others. |
| `prompt` | Host default (`Execute {command}?`) | Never shown while `optional` is `false`; kept because the install always writes the field. |
| `description` | A sentence naming what the step does | Read by humans in the registry and by the agent when reporting. |
| `condition` | `null` | Must stay unset — a non-empty condition makes agent-driven dispatch skip the hook (research.md R8). |

**Validation rules**

- All eight fields are present on every entry the install writes. This
  extension asserts that shape when reading and reports a deviation; it never
  corrects one.
- `command` resolves to a declared command. Enforced by a CI check over the
  manifest, not by runtime discovery.
- **Every entry in this file is read-only to us** — ours and other extensions'
  alike. Never modified, never reordered, never removed, never reformatted
  (FR-022). The `extension` field is how we *recognise* our entries, not a
  licence to edit them.

**State**: an entry is *present* (ours, `enabled: true`), *disabled* (ours,
`enabled: false`), *missing* (no entry of ours under that event), or *leftover*
(ours by command, but written before manifest-declared hooks and carrying no
`extension` field — see Hook health `duplicated`). An unreadable registry is a
property of the file, not of an entry.

---

## Hook health

The read-only classification of all seven events, already emitted in the run
summary under `hook_health`. This feature extends its meaning, not its shape.

```text
{
  present:       [event...]   # our entry exists and is enabled
  missing:       [event...]   # no entry of ours
  disabled:      [event...]   # our entry exists with enabled: false
  held_disabled: [event...]   # recorded as disabled by the operator (new)
  duplicated:    [event...]   # a leftover pre-manifest entry of ours (new)
  unreadable:    boolean      # the registry could not be read at all (new)
  repair_hint:   string?      # present only when something is not `present`
}
```

**Rules**

- `present`, `missing` and `disabled` partition the seven events **only when
  `unreadable` is false**. `held_disabled` and `duplicated` are cross-cutting
  annotations, not further partitions: an event may be `disabled` and
  `held_disabled` (the normal case), or `present` and `held_disabled` (an
  install re-enabled it and the operator has not released it), or `present` and
  `duplicated` (the canonical entry exists beside a leftover one).
- An unreadable registry sets `unreadable: true`, leaves the three partition
  lists **empty**, and returns the config exit code. It MUST NOT report the
  events as `missing`: the extension has no evidence either way, and saying
  "your hooks are missing" about a file it merely failed to parse is exactly
  the kind of false, expensive guidance FR-024 forbids.
- A registry that is valid YAML but uses a construct outside the reader's
  supported subset is reported as unreadable **with the construct named**, and
  distinguished in prose from a genuinely broken file (spec.md Edge Cases).
- `repair_hint` names the remedy for whatever is not `present`, literally:
  the official install command for `missing`, the release flag for
  `held_disabled`, the manual edit for `duplicated`. Every literal it contains
  is covered by the message↔command CI check (FR-018).

**Health never writes.** This object is a pure function of the registry's
content. Computing it opens the registry read-only and writes nothing, to the
registry or anywhere else — the operator disable record is written by the
ceremony, not by the classification (research.md R5 step 1). And the registry
itself is never written by this extension at all, in any state, by any command
(FR-022). That is what makes FR-023, SC-007, SC-011 and SC-012 hold
unconditionally, with no exempted case to test around.

---

## Operator disable record

**New.** The set of events the operator disabled, stored in the gitignored local
binding `.specify/jira/config.local.yml`:

```yaml
hooks:
  disabled:
    - after_implement
```

**Why it exists**: `specify extension add` writes `enabled: true`
unconditionally, so the registry cannot remember the operator's decision across
an install or upgrade (research.md R5). The local binding is outside
`.specify/extensions/` and therefore survives, by Principle V.

**Lifecycle**

| Transition | Trigger |
| --- | --- |
| Event added to the set | The configuration ceremony reads our entry for that event with `enabled: false`. The health classification observes it; the ceremony records it |
| Event honoured | The reconcile entry point exits inert for that event — no Jira call, no warning (FR-020) — regardless of what the registry currently says |
| Divergence reported | When the record holds an event the registry now shows as enabled, the ceremony names the event, states that no bridge step will run for it, and names the command that releases it. **The registry is not edited to match** (FR-022) |
| Event removed from the set | Only by explicit operator action through the configuration command's release flag |

The record is never inferred away. The extension cannot distinguish an
operator's re-enable from the install's rewrite, so it does not guess: the
ceremony reports every held event and names the flag that releases it.

**Capture window.** The record can only be populated when the extension reads
the registry. An operator who sets `enabled: false` and reinstalls before the
ceremony has run once has not been observed, and the reinstall's `enabled: true`
stands. This is stated in spec.md Assumptions rather than engineered around:
closing it would require watching a file we do not own.

**Validation**: entries are event names from the closed set of seven; an
unknown name is reported and ignored rather than failing the run, because the
file is human-editable and a typo must not break mirroring.

---

## Relationships

```text
Lifecycle event ──1:1── Hook entry (ours) ──belongs to── Hook registry (shared)
       │                      │
       │                      └── classified by ── Hook health
       │
       └── may appear in ── Operator disable record ── overrides ── dispatch
```

The manifest declares events and their entries; the install writes them into
the registry; health reads the registry; the disable record overrides both at
dispatch time and is re-applied into the registry by the ceremony.
