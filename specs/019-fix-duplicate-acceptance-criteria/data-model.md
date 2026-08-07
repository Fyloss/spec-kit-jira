# Phase 1 Data Model: A Ticket the Mirror Created Is the Mirror's to Replace

**Feature**: 019-fix-duplicate-acceptance-criteria | **Date**: 2026-08-06

No persisted structure is added. Every value below already exists and is already read on every run; this
feature routes one of them to a decision that currently ignores it.

---

## §1 Recorded origin (existing, unchanged on disk and on the wire)

The `origin` field of the identity marker, stored as a Jira **entity property** under the key
`spec-kit-jira` — not a label, not a summary, not anything an operator can edit in the UI.

| Value | Meaning | Written by |
| --- | --- | --- |
| `bridge` | The mirror created this ticket. Every byte of its description is the mirror's. | `ticket.sh:160` on creation; every update path re-stamps the recorded value |
| `human` | A human created it and handed it over. Its description may contain their writing. | `mention.sh:103` on adoption |

**Invariants**

- Written on every creation and every adoption; never absent on a shipping path.
- Preserved, never recomputed, across updates (`plan_apply.sh:391`, `:548`, and the task equivalent).
- Survives a spec-folder rename — identity resolves the stored marker, not the path.

**Carried into the plan context as** (all pre-existing keys):

| Tier | Context key | Populated at |
| --- | --- | --- |
| Story | `ticket_origins[<local_id>]` | `reconcile.sh:348` |
| Sub-task | `ticket_origins[<task_id>]` | `reconcile.sh:397` |
| Parent | `parent_origin` | `reconcile.sh:1020` |

---

## §2 Ownership (new, in-memory only)

The neutral engine's own vocabulary for "whose text is this". It exists so the engine can make the decision
without learning what a `bridge` is.

| Value | Sink maps from | Meaning to the engine |
| --- | --- | --- |
| `self` | `origin == "bridge"` | The caller wrote everything here; nothing outside the region needs protecting |
| `other` | `origin == "human"` | Someone else may have written here; identify conservatively or preserve |
| `unknown` | any other value, including empty | Authorship undeterminable; preserve everything and say so |

**Invariants**

- Exactly one of three values; the translation is total (no input yields nothing).
- Never persisted, never sent to the tracker, never written to a specification.
- Contains no tracker vocabulary, so it may cross into the engine (Constitution VIII).

---

## §3 Region split result (existing shape, one new producer)

`{ prefix: <node array>, status: "ok" | "malformed" | "migrated-warned" }`, consumed unchanged by
`_plan_apply_managed_field` and its PowerShell twin.

| Status | Written to the ticket | Warning |
| --- | --- | --- |
| `ok` | `prefix ++ marker ++ freshly rendered region` | none |
| `migrated-warned` | same, and the whole prior content is inside `prefix` | existing "previous mirrored content could not be identified" |
| `malformed` | **nothing** — the description key is omitted from the payload entirely | existing "carries more than one boundary marker" |

**Invariant, and the point of the feature**: for `status == "ok"`, the rendered region appears exactly once
in the resulting document, and `prefix` never contains a copy of it.

---

## §4 State transitions of one description

```
                    ┌──────────────────────────────────────────────┐
   creation ───────▶│ delimited: prefix? ++ marker ++ region        │◀────┐
                    └──────────────────────────────────────────────┘     │
                                     ▲                                   │
    marker_count == 1 ───────────────┘                                   │
                                                                         │
   undelimited ──┬── ownership self    ──▶ region replaced wholesale ────┤
   (marker_count │                          prefix := []                 │
    == 0)        ├── ownership other   ──▶ suffix split (unchanged) ─────┤
                 └── ownership unknown ──▶ whole content preserved ──────┘
                                           + named warning

   marker_count > 1 ──▶ nothing written, ticket named in a warning (terminal for this run)
```

Only the `self` edge is new. Once a description is delimited it never returns to the undelimited state
except by human deletion of the marker, which re-enters at the same fork.

---

## §5 What is deliberately not modelled

- No record of "this ticket was repaired" — repair is out of scope (spec, Out of Scope).
- No fingerprint, checksum, or prior-render cache. The origin makes content comparison unnecessary, and
  storing what was last rendered would be a second source of truth for the specification (Principle I).
- No new configuration key, no new context key, no new warning string.
