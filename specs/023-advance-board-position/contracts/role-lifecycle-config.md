# Contract — A workflow per hierarchy role in the team configuration

**Feature**: `specs/023-advance-board-position` | **Date**: 2026-08-10

This contract governs the one configuration change the feature makes (FR-010, FR-013, FR-017, FR-026). It
is binding on both ports, which must accept, reject, and normalise identically, with identical messages.

---

## §1 — The surface

One key changes: `phase_status_map`, per project, in the committable team config. Nothing is added to the
local binding, nothing to the secrets layer, and no other key, flag, or option is introduced.

A project that declares nothing sees no behaviour change of any kind.

---

## §2 — Two accepted shapes

### Shape A — role-blind

```yaml
projects:
  - key: COMP
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
```

**Meaning: the story role.** This is what ships today, and reading it as anything broader would start moving
parents and sub-tasks for teams that never asked (FR-013).

### Shape B — a workflow per role

```yaml
projects:
  - key: COMP
    phase_status_map:
      specification:            # the Epic / Feature tier's own workflow
        after_specify: "Funnel"
        after_plan:    "Building"
      story:                    # the Story tier's own workflow
        after_specify: "To Do"
        after_plan:    "In Progress"
      task:                     # only where sub-task mirroring is enabled
        after_implement: "In Progress"
```

The role names are the three the project already uses for its hierarchy. A tech lead meets no new
vocabulary (Principle XVI).

---

## §3 — Discrimination

Structural, never positional and never by a marker key:

| Every value is… | Read as |
|---|---|
| a string | shape A |
| an object whose own values are strings, keyed by a known role | shape B |
| a mixture | a validation error (§4) |

An empty mapping (`phase_status_map: {}`) is shape-neutral and means "nothing declared".

---

## §4 — Validation

Each error names the project index and the offending key, in the style the existing validator already uses.
All are refusals at configuration-load time — zero Jira reads, zero writes.

| Condition | Message names |
|---|---|
| Shape A value is not a string | the project index, the event key |
| Shape B role key is not one of `specification`, `story`, `task` | the project index, the unknown role, the three accepted names |
| Shape B role value is not an object | the project index, the role |
| Shape B step name is not a string | the project index, the role, the event key |
| The two shapes are mixed | the project index, one event key and one role key, and which shape to pick |

**An event key the host does not emit is not an error.** A declaration for an unknown event is inert, which
is exactly how an unmapped event behaves today. Silently accepting it costs nothing; rejecting it would
break a config the moment the host renames an event.

---

## §5 — Normalised form

Both shapes normalise, before any consumer reads them, to:

```json
{ "specification": { "<event>": "<step>" },
  "story":         { "<event>": "<step>" },
  "task":          { "<event>": "<step>" } }
```

A role that declared nothing is **absent**, not an empty object, so "declared nothing" stays distinguishable
from "declared an empty workflow" (FR-012).

Shape A normalises to `{ "story": { … } }` and nothing else.

---

## §6 — Consumers

| Consumer | Change |
|---|---|
| status classification | called once per role, with that role's mapping |
| phase order (drift) | derived per role, from that role's mapping |
| the halted designation | unchanged — project-wide, applies to every role |
| every other project key | unchanged |

Both classification helpers already take the mapping as an argument, so this is a caller change: no
signature moves, and the engine stays unaware that roles exist (research R4).

---

## §7 — Interaction with sub-task mirroring

A `task` declaration takes effect only where the project has enabled sub-task mirroring. Where the tier is
disabled the declaration is **inert and reported once** as having no effect — a note, never a failure
(FR-015). Rejecting it at load time was considered and refused: a team that switches the tier off for a
sprint should not have its configuration become invalid.

---

## §8 — Documentation

Shipped in the same change (FR-026, FR-027):

- The configuration reference gains shape B with a worked example showing two different workflows, and
  states plainly that shape A means the story role.
- `docs/08-safety-model.md` — the decision table's `transition` row currently reads "emitted", which the
  code does not do. It becomes accurate, and the section gains the five outcomes of the sibling contract.
- `docs/VISION.md` — Part 1 currently claims the bridge "advances the ticket on the board", and item 3 is
  marked *Shipped*. Both are corrected to describe what ships once this feature lands, and item 3's
  remaining envisioned half (proposing the mapping at configuration time) is restated as the follow-up it
  now is — one mapping per role, three to propose.
